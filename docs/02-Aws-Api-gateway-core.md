  # OrderServiceAPI – Amazon API Gateway REST API (Terraform Lab)

Tài liệu này tổng hợp toàn bộ phần chúng ta đã trao đổi và triển khai về **AWS API Gateway (REST API)** với Terraform, kèm test case, logging/monitoring và bảo mật cơ bản. Bạn có thể dùng làm README cho repo GitHub.

---

## 1. Mục tiêu

Demo một API “Order Service” dùng **Amazon API Gateway REST API** với các tính năng:

- REST API với nhiều kiểu **integration nâng cao**:
  - `POST /orders` → **Lambda** (mapping template phức tạp)
  - `POST /orders/{id}/notify` → **SNS** (AWS Service integration)
  - `GET /orders/{id}` → **HTTP backend** (httpbin.org)
- **Mapping templates** (VTL) phức tạp cho request/response.
- **Usage Plan + API Key** để:
  - Bắt buộc client dùng API key.
  - Hạn chế tốc độ (rate limit, burst).
  - Hạn chế quota (số request/ngày).
- **Logging & Monitoring**:
  - CloudWatch Logs (access log + execution log).
  - Metrics mặc định của API Gateway.
- Cấu hình bằng **Terraform**.

---

## 2. Kiến trúc tổng quan

### 2.1. Thành phần chính

- **API Gateway REST API** – `OrderServiceAPI`
  - Stage: `prod`
- **Lambda Function** – `create_order_function`
  - Runtime: Python
  - Dùng để xử lý `POST /orders`.
- **SNS Topic** – `order-notifications`
  - Nhận message từ `POST /orders/{id}/notify`.
- **HTTP Backend** – `https://httpbin.org/get`
  - Dùng làm service mock cho `GET /orders/{id}`.
- **Usage Plan + API Key**
  - `MobilePlan` + `mobile-app-key`
- **CloudWatch Logs**
  - Access log: `/aws/apigateway/OrderServiceAPI-access`
  - Execution logs: nhóm log API Gateway + Lambda.

### 2.2. Luồng chính

1. **POST /orders**
   - Client gửi JSON order + `x-api-key`.
   - API Gateway kiểm tra API key + usage plan.
   - Mapping template chuyển payload → format nội bộ.
   - Gọi Lambda `create_order_function`.
   - Lambda trả kết quả.
   - Response mapping template rút gọn/trang điểm response trước khi trả cho client.

2. **POST /orders/{id}/notify**
   - Client gửi JSON notify (type, to) + `x-api-key`.
   - API Gateway kiểm tra API key + usage plan.
   - Mapping template build payload `sns:Publish` (TopicArn + Message).
   - API Gateway gọi SNS với IAM role `api-gw-sns-role`.
   - SNS nhận message, fanout tới subscribers (email/SQS/Lambda… nếu cấu hình).
   - API Gateway trả `"Notification queued"` cho client.

3. **GET /orders/{id}**
   - Client gọi `GET /orders/{id}?fields=...` + `x-api-key`.
   - API Gateway kiểm tra API key + usage plan.
   - Mapping `path param {id}` → query `order_id`, gọi `https://httpbin.org/get?order_id={id}`.
   - Trả nguyên response từ httpbin.org về client.

---

## 3. Cấu trúc repo (gợi ý)

```text
.
├── main.tf               # Terraform – định nghĩa toàn bộ infra
└── lambda_create_order.py # Code Lambda create order
