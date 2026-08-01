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

Cách nhanh nhất để đẩy message vào DLQ: gỡ quyền ghi DynamoDB của processor,
gửi vài order, đợi ~5 phút (5 lần retry × visibility timeout 60s).

```bash
aws iam delete-role-policy \
  --role-name order-processor-lambda-role \
  --policy-name order-processor-lambda-policy

curl -X POST "$ENDPOINT/orders" -H "Content-Type: application/json" \
  -d '{"userId":"U-1","items":[{"sku":"BAD","qty":1}]}'

# Theo dõi
watch -n 10 'aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw order_dlq_url) \
  --attribute-names ApproximateNumberOfMessages'
```

Message vào DLQ → alarm `order-dlq-not-empty` chuyển ALARM → SNS gửi mail.
**Message vẫn nằm trong DLQ** — đó là điểm chính của lab.

Xử lý lại sau khi đã fix (chạy `terraform apply` để khôi phục policy):

```bash
DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$(terraform output -raw order_dlq_url)" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

aws sqs start-message-move-task --source-arn "$DLQ_ARN"
```

## Dọn dẹp

```bash
terraform destroy
```

## Chi phí

Toàn bộ tài nguyên đều PAY_PER_REQUEST hoặc trong free tier. Với vài chục
request test, chi phí gần như bằng 0. Không có tài nguyên nào tính tiền theo
giờ khi idle.
