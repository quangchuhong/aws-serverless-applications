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

### 3.2. lambda/order_processor.py

Lambda đọc message từ SQS, ghi order vào DynamoDB OrdersTable.
```python
import json
import logging
import os
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
table_name = os.environ["ORDERS_TABLE_NAME"]
orders_table = dynamodb.Table(table_name)


def lambda_handler(event, context):
    records = event.get("Records", [])

    for record in records:
        body = record["body"]
        msg = json.loads(body)

        order_id = msg.get("orderId")
        user_id = msg.get("userId")
        items = msg.get("items")
        created_at = msg.get("createdAt")

        logger.info(
            "Processing order: orderId=%s userId=%s createdAt=%s",
            order_id,
            user_id,
            created_at,
        )

        try:
            orders_table.put_item(
                Item={
                    "orderId": order_id,
                    "userId": user_id,
                    "items": items,
                    "createdAt": created_at,
                }
            )
        except ClientError as e:
            logger.error("Failed to write order %s to DynamoDB: %s", order_id, e)
            # Raise để SQS/Lambda retry, quá maxReceiveCount → vào DLQ
            raise

    return {"status": "ok"}

```

### 3.3. lambda/get_order_handler.py

Lambda đọc một order từ DynamoDB theo orderId và trả JSON.
Có custom encoder để serialize Decimal từ DynamoDB.
```python
import os
import json
import boto3
from botocore.exceptions import ClientError
from decimal import Decimal

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["ORDERS_TABLE_NAME"])


class DecimalEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal):
            # tuỳ bạn: float hoặc int; ở đây dùng float
            return float(o)
        return super(DecimalEncoder, self).default(o)


def lambda_handler(event, context):
    order_id = event.get("pathParameters", {}).get("id")
    if not order_id:
        return _response(400, {"message": "Missing path parameter: id"})

    try:
        resp = table.get_item(Key={"orderId": order_id})
    except ClientError as e:
        return _response(
            500,
            {"message": f"DynamoDB error: {e.response['Error']['Message']}"},
        )

    item = resp.get("Item")
    if not item:
        return _response(404, {"message": "Order not found"})

    return _response(200, item)


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, cls=DecimalEncoder),
    }

```
