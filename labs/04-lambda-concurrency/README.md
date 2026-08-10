# Lab 04 – Lambda Concurrency & Invocations

Quan sát Lambda scale, throttle và retry trong thực tế.

Lý thuyết đầy đủ: [`docs/04-Aws-lambda-function.md`](../../docs/04-Aws-lambda-function.md)

## Hai Lambda, hai kiểu invoke

| | Lambda A | Lambda B |
|---|----------|----------|
| Tên | `sync-api-lambda` | `async-s3-lambda` |
| Kiểu invoke | Synchronous (API Gateway) | Asynchronous (S3 event) |
| Retry | Không (client tự lo) | 2 lần, rồi vào SQS destination |
| Đặc điểm | Alias `prod`, reserved/provisioned concurrency | `on_failure` destination |

## ⚠️ Chi phí

`provisioned_concurrency` **tính tiền theo giờ kể cả khi không có request nào**.
Mặc định lab đặt `0` (tắt). Chỉ bật khi đang thử nghiệm, và nhớ tắt sau đó:

```bash
terraform apply -var="provisioned_concurrency=5"   # bật để thử
terraform apply -var="provisioned_concurrency=0"   # tắt khi xong
```

Các tài nguyên còn lại đều trong free tier hoặc tính theo request.

## Deploy

```bash
terraform init
terraform apply
```

## Thử nghiệm 1 – Concurrency & throttle (Lambda A)

Lambda A sleep 2s mỗi request, `reserved_concurrency` mặc định 5.

```bash
export API_URL=$(terraform output -raw sync_api_url)

# 1 request -> ~2s
curl -w "\n%{time_total}s\n" "$API_URL"

# 20 request song song -> chỉ 5 chạy cùng lúc, phần còn lại bị throttle
python3 test_concurrency.py --requests 20 --concurrency 20
```

Đối chiếu CloudWatch → Metrics → Lambda:

- `ConcurrentExecutions` chạm trần 5.
- `Throttles` > 0.

Nới giới hạn rồi chạy lại để thấy khác biệt:

```bash
terraform apply -var="reserved_concurrency=20"
python3 test_concurrency.py --requests 20 --concurrency 20
```

Trong output, để ý `logStream`: nhiều request chung một `logStream` nghĩa là
cùng execution environment xử lý (warm reuse); `logStream` khác nhau nghĩa là
Lambda đã tạo instance mới.

## Thử nghiệm 2 – Cold start & provisioned concurrency

```bash
# Không có provisioned concurrency: request đầu chậm hơn hẳn (cold start)
terraform apply -var="provisioned_concurrency=0"
curl -w "\n%{time_total}s\n" "$API_URL"

# Có 5 instance giữ ấm: request đầu nhanh như request thứ N
terraform apply -var="provisioned_concurrency=5"
curl -w "\n%{time_total}s\n" "$API_URL"

terraform apply -var="provisioned_concurrency=0"   # nhớ tắt
```

## Thử nghiệm 3 – Async retry & Event Destination (Lambda B)

Luồng thành công:

```bash
BUCKET=$(terraform output -raw s3_bucket)
echo "hello" > /tmp/file_ok.txt
aws s3 cp /tmp/file_ok.txt "s3://$BUCKET/"

aws logs tail /aws/lambda/async-s3-lambda --since 2m
```

Luồng lỗi → destination:

```bash
terraform apply -var="simulate_async_failure=true"

echo "boom" > /tmp/file_fail.txt
aws s3 cp /tmp/file_fail.txt "s3://$BUCKET/"

# Đợi ~1-2 phút cho 2 lần retry chạy xong
aws sqs receive-message \
  --queue-url "$(terraform output -raw async_dlq_url)" \
  --max-number-of-messages 1
```

Message trong queue **không phải** event S3 gốc, mà là payload của Event
Destination — có `requestContext.condition = "RetriesExhausted"`,
`responsePayload.errorMessage`, và `requestPayload` là event gốc. Đây là điểm
khác biệt so với `dead_letter_config` kiểu cũ (chỉ gửi event gốc, không kèm lỗi).

Tắt chế độ lỗi:

```bash
terraform apply -var="simulate_async_failure=false"
```

## Thử nghiệm 4 – Version & alias rollback

```bash
# Sửa lambda_sync.mjs (ví dụ đổi message thành "v2")
terraform apply          # publish = true -> tạo version mới, alias prod trỏ sang

aws lambda list-versions-by-function --function-name sync-api-lambda \
  --query 'Versions[].Version'

# Rollback: trỏ alias về version cũ
aws lambda update-alias --function-name sync-api-lambda \
  --name prod --function-version 1
```

API Gateway gọi qua alias nên rollback có hiệu lực ngay, không cần redeploy API.

> Sau khi rollback bằng CLI, lần `terraform apply` tiếp theo sẽ kéo alias về
> version mới nhất. Rollback bằng CLI chỉ là biện pháp khẩn cấp — cách đúng là
> revert code trong Git rồi apply lại.

## Dọn dẹp

```bash
terraform destroy
```

`force_destroy = true` trên S3 bucket nên các file test sẽ bị xoá cùng.
