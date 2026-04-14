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
```
---

## 3. Code Lambda

### 3.1. lambda/order_api_handler.py

Lambda nhận POST /orders, validate input, gửi message vào SQS và trả orderId.
```python
import json
import os
import uuid
import boto3
from datetime import datetime, timezone

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["ORDER_QUEUE_URL"]


def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"message": "Invalid JSON"})

    user_id = body.get("userId")
    items = body.get("items")

    if not user_id or not items:
        return _response(400, {"message": "userId and items are required"})

    order_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    message = {
        "orderId": order_id,
        "userId": user_id,
        "items": items,
        "createdAt": now,
    }

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
    )

    return _response(202, {"orderId": order_id, "status": "ACCEPTED"})


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }

```
