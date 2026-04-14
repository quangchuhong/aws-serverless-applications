# AWS API Gateway – OrderServiceAPI LAB (Terraform + Theory)

Tài liệu này tổng hợp toàn bộ phần LAB chúng ta đã triển khai **AWS API Gateway REST API** bằng Terraform, kèm phần **lý thuyết giải thích các khái niệm và options chính trong API Gateway**.

Bạn có thể dùng làm README cho repo GitHub hoặc tài liệu học.

---

## Mục lục

1. [Mục tiêu LAB](#mục-tiêu-lab)  
2. [Kiến trúc tổng quan LAB](#kiến-trúc-tổng-quan-lab)  
3. [Cấu trúc project](#cấu-trúc-project)  
4. [Triển khai bằng Terraform](#triển-khai-bằng-terraform)  
   - 4.1. Lambda  
   - 4.2. SNS Topic  
   - 4.3. API Gateway REST API & Resources  
   - 4.4. Các endpoint & integration  
   - 4.5. Deployment & Stage  
   - 4.6. Usage Plan & API Key  
   - 4.7. Logging & Monitoring  
5. [Test cases](#test-cases)  
6. [Lý thuyết: Các khái niệm & options trong API Gateway](#lý-thuyết-các-khái-niệm--options-trong-api-gateway)  
   - 6.1. Loại API (REST, HTTP, WebSocket)  
   - 6.2. Resource, Method, Route  
   - 6.3. Integration types  
   - 6.4. Mapping Templates (VTL)  
   - 6.5. Usage Plan & API Key  
   - 6.6. Bảo mật (Authorization & Authentication)  
   - 6.7. Logging, Monitoring & Observability  
   - 6.8. Throttling & Quota  
   - 6.9. Caching (REST API)  

---

## 1. Mục tiêu LAB

Xây dựng một API “Order Service” bằng **Amazon API Gateway REST API**, với:

- **REST API** có 3 endpoint:
  - `POST /orders` → **Lambda** (mapping template phức tạp, response mapping)
  - `POST /orders/{id}/notify` → **SNS** (AWS Service integration)
  - `GET /orders/{id}` → **HTTP backend** (httpbin.org)
- **Usage Plan + API Key**:
  - Bắt buộc dùng API key.
  - Giới hạn rate & quota.
- **CloudWatch Logs**:
  - Access logs & execution logs cho API Gateway.
  - Logs cho Lambda.
- Dùng **Terraform** để khai báo hạ tầng (IaC).

---

## 2. Kiến trúc tổng quan LAB

### Thành phần chính

- **API Gateway REST API** – `OrderServiceAPI`, stage `prod`
- **Lambda Function** – `create_order_function`
- **SNS Topic** – `order-notifications`
- **HTTP Backend Demo** – `https://httpbin.org/get`
- **Usage Plan** – `MobilePlan`
- **API Key** – `mobile-app-key`
- **CloudWatch Logs**:
  - `/aws/apigateway/OrderServiceAPI-access`
  - `API-Gateway-Execution-Logs_<rest_api_id>/prod`
  - `/aws/lambda/create_order_function`

### Luồng chính

1. `POST /orders`
   - Client gửi JSON order + header `x-api-key`.
   - API Gateway kiểm tra API key theo Usage Plan.
   - Request mapping template → chuyển payload thành format nội bộ cho Lambda.
   - Lambda xử lý & trả về kết quả.
   - Response mapping template → chuẩn hóa JSON trả cho client.

2. `POST /orders/{id}/notify`
   - Client gửi JSON notify (type, to) + `x-api-key`.
   - API Gateway build payload `sns:Publish` (TopicArn + Message JSON string).
   - Dùng IAM role `api-gw-sns-role` để gọi SNS.
   - SNS nhận message, fanout theo subscription (email/SQS/Lambda…).
   - API Gateway trả `"Notification queued"`.

3. `GET /orders/{id}`
   - Client gọi `GET /orders/{id}?fields=...` + `x-api-key`.
   - API Gateway map path param `{id}` → query `order_id`.
   - Gửi request tới `https://httpbin.org/get?order_id={id}`.
   - Trả nguyên response body từ httpbin.org cho client.

---

## 3. Cấu trúc project

```text
.
├── main.tf               # Terraform: định nghĩa Lambda, SNS, API Gateway, Usage Plan, Logging...
└── lambda_create_order.py # Code Lambda đơn giản để test mapping template
