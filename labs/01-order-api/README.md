# Lab 01 – Serverless Order API

Kiến trúc event-driven: API Gateway HTTP API → Lambda → SQS → Lambda → DynamoDB,
kèm DLQ và CloudWatch Alarm.

Lý thuyết đầy đủ: [`docs/01-Example-Aws-Serverless-Order-API.md`](../../docs/01-Example-Aws-Serverless-Order-API.md)

## Luồng

```text
POST /orders  ─→ order-api-handler ─→ order-queue ─→ order-processor ─→ OrdersTable
                                           │
                                           └─(5 lần fail)→ order-dlq → Alarm → SNS

GET /orders/{id} ─→ get-order-handler ─→ OrdersTable
```

## Deploy

```bash
terraform init
terraform apply
```

Nhận alert qua email khi có message vào DLQ:

```bash
terraform apply -var="alert_email=you@example.com"
# Sau đó check mail và bấm link confirm subscription
```

## Test

```bash
ENDPOINT=$(terraform output -raw http_api_endpoint)

# Tạo order
curl -X POST "$ENDPOINT/orders" \
  -H "Content-Type: application/json" \
  -d '{"userId":"U-1","items":[{"sku":"SKU-1","qty":2}]}'
# -> {"orderId":"...","status":"ACCEPTED"}

# Đọc order (chờ 1-2s cho processor chạy xong)
curl "$ENDPOINT/orders/<orderId>"
```

**Validation lỗi:**

```bash
curl -X POST "$ENDPOINT/orders" \
  -H "Content-Type: application/json" -d '{"userId":"U-1"}'
# -> 400 {"message":"userId and items are required"}
```

## Thử nghiệm DLQ

Cách nhanh và sạch nhất: gửi thẳng vào SQS một message thiếu `orderId`.
`order_processor` sẽ ném `KeyError`, đưa message vào `batchItemFailures`,
và message bị retry cho tới khi chạm `maxReceiveCount = 5`.

```bash
aws sqs send-message \
  --queue-url "$(terraform output -raw order_queue_url)" \
  --message-body '{"userId":"U-BAD"}'
```

Theo dõi cả hai queue:

```bash
watch -n 10 'aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw order_queue_url)" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible;
aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw order_dlq_url)" \
  --attribute-names ApproximateNumberOfMessages'
```

Diễn biến mong đợi (~5 phút):

```text
T=0s    nhận lần 1 → KeyError → invisible 60s   NotVisible=1
T=60s   nhận lần 2 ...
T=180s  nhận lần 4 ...
T=240s  nhận lần 5 ← chạm maxReceiveCount
T=300s  SQS chuyển message sang DLQ             DLQ=1
```

`ApproximateNumberOfMessagesNotVisible = 1` là dấu hiệu vòng retry đang chạy
đúng. Đếm số lần retry qua log — mỗi dòng là một lần nhận:

```bash
aws logs tail /aws/lambda/order-processor --since 10m --format short | grep -i keyerror
```

> Đừng dùng `aws sqs receive-message` để soi `ApproximateReceiveCount` giữa
> chừng — chính lệnh đó cũng tính là một lần nhận và làm sai lệch thí nghiệm.

Message vào DLQ → alarm `order-dlq-not-empty` chuyển ALARM (chậm thêm ~5 phút
vì metric SQS phát 5 phút/lần) → SNS gửi mail.
**Message vẫn nằm nguyên trong DLQ** — đó là điểm chính của lab. Xem nội dung
mà không xoá:

```bash
aws sqs receive-message \
  --queue-url "$(terraform output -raw order_dlq_url)" \
  --attribute-names All \
  --query 'Messages[0].[Body,Attributes.ApproximateReceiveCount]'
```

### Redrive

```bash
DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw order_dlq_url)" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

aws sqs start-message-move-task --source-arn "$DLQ_ARN"
```

Message quay lại `order-queue`, nhưng nó **vẫn thiếu `orderId`** nên lại fail
và về DLQ sau 5 phút nữa — đúng thực tế: redrive chỉ có ý nghĩa **sau khi đã
sửa nguyên nhân gốc**. Muốn thấy nó chạy trót lọt thì purge DLQ rồi gửi một
order hợp lệ qua API.

### Biến thể: gỡ quyền ghi DynamoDB

Cách này gần với sự cố thật hơn (Lambda chạy được nhưng không ghi được DB).
Phải **thay** inline policy, **không được xoá**:

```bash
QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw order_queue_url)" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

aws iam put-role-policy \
  --role-name order-processor-lambda-role \
  --policy-name order-processor-lambda-policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:*:*:*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\",\"sqs:ChangeMessageVisibility\"],\"Resource\":\"$QUEUE_ARN\"}
    ]}"

curl -X POST "$ENDPOINT/orders" -H "Content-Type: application/json" \
  -d '{"userId":"U-1","items":[{"sku":"BAD","qty":1}]}'
```

`put_item` trả `AccessDeniedException` → `ClientError` → vào DLQ như trên.
Xong thì `terraform apply` để khôi phục policy.

> **Đừng dùng `aws iam delete-role-policy`.** Nó xoá cả inline policy, tức là
> mất luôn `sqs:ReceiveMessage`. Event source mapping poll SQS **bằng execution
> role của Lambda**, nên mất quyền đó thì ESM ngừng poll hẳn: Lambda không hề
> được gọi, `ReceiveCount` không tăng, message không bao giờ tới DLQ. Hàng đợi
> chỉ đứng im chứ không báo lỗi gì — rất dễ tưởng là "chưa tới lượt". Kiểm tra
> bằng:
>
> ```bash
> aws lambda list-event-source-mappings --function-name order-processor \
>   --query 'EventSourceMappings[0].[State,LastProcessingResult]'
> ```

## Dọn dẹp

```bash
terraform destroy
```

## Chi phí

Toàn bộ tài nguyên đều PAY_PER_REQUEST hoặc trong free tier. Với vài chục
request test, chi phí gần như bằng 0. Không có tài nguyên nào tính tiền theo
giờ khi idle.
