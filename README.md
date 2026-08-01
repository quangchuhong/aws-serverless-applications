# AWS Serverless Applications

Tài liệu nghiên cứu và lab thực hành về AWS serverless: API Gateway, Lambda,
SQS, DynamoDB, SNS, Cognito — kèm Terraform chạy được.

Nội dung viết bằng tiếng Việt, thiên về **giải thích tại sao** chứ không chỉ
liệt kê cấu hình.

---

## Bắt đầu từ đâu

| Bạn muốn | Đọc |
|----------|-----|
| Hiểu bức tranh API Gateway nói chung, so sánh các cloud | [Doc 00](docs/00-API-Gateway-Summary.md) |
| Dựng một API serverless hoàn chỉnh trong ~30 phút | [Doc 01](docs/01-Example-Aws-Serverless-Order-API.md) → [`labs/01-order-api/`](labs/01-order-api/) |
| Nắm sâu API Gateway REST + bảo mật bằng Cognito | [Doc 02](docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md) |
| Hiểu Lambda scale/throttle/version như thế nào | [Doc 04](docs/04-Aws-lambda-function.md) |
| Chọn Standard hay FIFO, tính chi phí SQS | [Doc 05](docs/05-Aws-sqs-queue.md) |

---

## Tài liệu

### [00 – API Gateway & Kiến trúc API](docs/00-API-Gateway-Summary.md)

Tổng quan và so sánh AWS API Gateway, GCP API Gateway, Apigee, Azure APIM,
Kong, MuleSoft. Mô hình public/private gateway, kiến trúc API trong ngân hàng
và e-commerce, vai trò của ESB.

*Lý thuyết, không có lab.*

### [01 – Serverless Order API](docs/01-Example-Aws-Serverless-Order-API.md)

Lab đầy đủ: API Gateway HTTP API → Lambda → SQS → Lambda → DynamoDB, kèm DLQ
và CloudWatch Alarm. Có Terraform và code Lambda chạy được.

**Khái niệm:** event-driven, async processing, decoupling, DLQ, partial batch
failure, least privilege IAM.

→ Code: [`labs/01-order-api/`](labs/01-order-api/)

### [02 – API Gateway REST & Cognito Authorizer](docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md)

Lab REST API với 3 kiểu integration (Lambda non-proxy, AWS service → SNS, HTTP
backend), mapping template VTL, usage plan + API key, access/execution logs,
Cognito User Pool + JWT authorizer.

**Khái niệm:** resource/method/integration, VTL, throttling & quota,
authorization vs authentication, WAF trong bức tranh tổng thể.

→ Code: [`labs/02-api-gateway-cognito/`](labs/02-api-gateway-cognito/)

### [03 – Amazon AppFlow & Backup dữ liệu SaaS](docs/03-Amazon-AppFlow-Backup-du-lieu-SaaS.md)

AppFlow làm được gì và **không** làm được gì cho bài toán backup. Ví dụ backup
dữ liệu GitLab về S3.

*Lý thuyết, không có lab.*

### [04 – Lambda Concurrency & Invocations](docs/04-Aws-lambda-function.md)

Lab về concurrency: sync Lambda (API Gateway), async Lambda (S3 → Event
Destination), reserved vs provisioned concurrency, version & alias, rollback.

**Khái niệm:** 3 kiểu invocation, throttle, retry behavior theo từng nguồn,
DLQ vs Event Destinations, deploy bằng SDK vs Terraform.

→ Code: [`labs/04-lambda-concurrency/`](labs/04-lambda-concurrency/)

### [05 – Amazon SQS](docs/05-Aws-sqs-queue.md)

Lý thuyết SQS đầy đủ: Standard vs FIFO (kèm high throughput mode), visibility
timeout, retention, redrive policy, cách tính chi phí thực tế, monitoring.

**Có gì đáng đọc:** danh sách use case cụ thể cho từng loại queue, và phần tính
chi phí có tính tới quy tắc 64 KB = 1 request mà nhiều người bỏ sót.

*Lý thuyết, không có lab.*

### [Phụ lục – Jira Service Management automation](docs/jirasm-automation-draft.md)

Bản nháp sơ đồ luồng JSM → Jenkins → GitLab → deploy. Không thuộc chủ đề AWS
serverless, giữ lại để tham khảo.

---

## Lab

Mỗi thư mục trong `labs/` là một Terraform project độc lập, chạy được:

```bash
cd labs/01-order-api
terraform init
terraform plan
terraform apply
```

**Trước khi chạy:**

- AWS credentials đã cấu hình (`aws sts get-caller-identity` chạy được).
- Terraform >= 1.5.
- Region mặc định `ap-southeast-1` — đổi qua biến `region` nếu cần.

**Sau khi thử xong, nhớ dọn:**

```bash
terraform destroy
```

> Các lab đều dùng tài nguyên trong phạm vi free tier hoặc chi phí rất thấp,
> **trừ** provisioned concurrency ở lab 04 — cái này tính tiền theo giờ kể cả
> khi không có request nào. Đừng để chạy qua đêm.

---

## Ghi chú

- Tài liệu mô tả AWS ở thời điểm 2026. Giới hạn quota, giá và danh sách runtime
  thay đổi theo thời gian — luôn đối chiếu với AWS docs chính thức trước khi
  đưa vào production.
- Các con số chi phí trong doc 05 là **ví dụ minh hoạ cách tính**, không phải
  giá thật.
