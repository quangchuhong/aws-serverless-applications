# Serverless Order API – AWS (API Gateway + Lambda + SQS + DynamoDB + DLQ + SNS)

Ví dụ 01: Kiến trúc serverless theo kiểu **event-driven**, dùng:

- **API Gateway HTTP API**
- **AWS Lambda**
- **Amazon SQS** (+ **DLQ**)
- **Amazon DynamoDB**
- **Amazon SNS** (alert khi có message vào DLQ)
- IaC với **Terraform**

---

## 1. Kiến trúc tổng quan

Luồng chính:

1. `POST /orders`  
   → API Gateway (HTTP API)  
   → Lambda `order-api-handler`  
   → gửi message vào SQS `order-queue`  
   → trả về `202 ACCEPTED` + `orderId`.

2. SQS `order-queue`  
   → Lambda `order-processor` (event source mapping)  
   → ghi item vào DynamoDB `OrdersTable`.  
   → Nếu Lambda lỗi nhiều lần, message sẽ chuyển vào DLQ `order-dlq`.

3. `GET /orders/{id}`  
   → API Gateway  
   → Lambda `get-order-handler`  
   → đọc dữ liệu từ DynamoDB `OrdersTable` và trả JSON.

4. DLQ `order-dlq`  
   → Lambda `order-dlq-alert-handler`  
   → gửi nội dung lỗi lên SNS topic `order-dlq-alerts` (có thể subscribe email).

Kiến trúc này minh họa:

- **Async processing** với SQS + Lambda.
- **Decoupling** giữa API (nhận request) và backend xử lý.
- **DLQ + alert** để không mất message và dễ quan sát lỗi.

---

## 2. Cấu trúc thư mục

```text
project-root/
  main.tf
  lambda/
    order_api_handler.py
    order_processor.py
    get_order_handler.py
    dlq_alert_handler.py
  README.md
