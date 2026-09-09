# Serverless Order API – AWS (API Gateway + Lambda + SQS + DynamoDB + DLQ + SNS)

Ví dụ 01: Kiến trúc serverless theo kiểu **event-driven**, dùng:

- **API Gateway HTTP API**
- **AWS Lambda**
- **Amazon SQS** (+ **DLQ**)
- **Amazon DynamoDB**
- **Amazon SNS** + **CloudWatch Alarm** (alert khi có message vào DLQ)
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
   → **CloudWatch Alarm** trên metric `ApproximateNumberOfMessagesVisible`  
   → gửi alert lên SNS topic `order-dlq-alerts` (có thể subscribe email).  
   → Message **vẫn nằm nguyên trong DLQ** để điều tra và redrive lại sau.

> **Tại sao không dùng Lambda poll DLQ để gửi alert?**
>
> Một anti-pattern hay gặp là gắn event source mapping từ DLQ sang một Lambda
> "alert handler". Vấn đề: khi Lambda đó chạy thành công, event source mapping
> sẽ **xoá message khỏi DLQ**. Kết quả là bạn nhận được email, nhưng message lỗi
> đã biến mất — không còn gì để phân tích hay redrive lại.
>
> DLQ nên được coi là **nơi lưu trữ**, không phải nơi để consume. Alert lấy từ
> **metric** (CloudWatch Alarm), còn việc xử lý lại dùng **redrive**
> (`StartMessageMoveTask` hoặc nút "Start DLQ redrive" trên Console).

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
  README.md
```

> Code chạy được của lab này nằm ở [`labs/01-order-api/`](../labs/01-order-api/).
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

Handler trả về `batchItemFailures` để chỉ những message thực sự lỗi mới bị
retry — nếu không, một message hỏng sẽ kéo cả batch 5 message quay lại queue
và các message đã ghi thành công bị xử lý lại lần nữa.
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
    failures = []

    for record in event.get("Records", []):
        message_id = record["messageId"]

        try:
            msg = json.loads(record["body"])

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

            orders_table.put_item(
                Item={
                    "orderId": order_id,
                    "userId": user_id,
                    "items": items,
                    "createdAt": created_at,
                }
            )
        except (ClientError, json.JSONDecodeError, KeyError) as e:
            logger.exception("Failed to process message %s: %s", message_id, e)
            # Chỉ message này bị trả lại queue để retry.
            # Quá maxReceiveCount (5) → chuyển sang DLQ.
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}

```

> **Lưu ý về kiểu số của DynamoDB:** `boto3` resource API không nhận `float`.
> Nếu `items` chứa giá tiền dạng `19.99`, `put_item` sẽ raise `TypeError`.
> Cần convert sang `decimal.Decimal` trước khi ghi (thường dùng
> `json.loads(record["body"], parse_float=Decimal)`).

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
    # Không dùng event.get("pathParameters", {}).get("id"):
    # khi key tồn tại nhưng giá trị là None, .get() trả về None → AttributeError.
    order_id = (event.get("pathParameters") or {}).get("id")
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

### 3.4. Xử lý message trong DLQ

Không cần viết Lambda cho phần này. Alert do **CloudWatch Alarm** đảm nhiệm
(xem Terraform ở mục 4), còn khi muốn xử lý lại message sau khi đã fix bug:

```bash
# Redrive toàn bộ message từ DLQ về lại queue chính
aws sqs start-message-move-task \
  --source-arn "$(aws sqs get-queue-attributes \
      --queue-url "$DLQ_URL" \
      --attribute-names QueueArn \
      --query 'Attributes.QueueArn' --output text)"
```

Message được đưa về `order-queue` và `order-processor` xử lý lại như bình thường.

---

## 4. Terraform – main.tf

File này tạo toàn bộ resource: SQS, DLQ, DynamoDB, SNS, Lambda, API Gateway, event source mapping.
```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

########################
# SQS Queues (main + DLQ)
########################

resource "aws_sqs_queue" "order_queue" {
  name                       = "order-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
}

resource "aws_sqs_queue" "order_dlq" {
  name = "order-dlq"
}

resource "aws_sqs_queue_redrive_policy" "order_queue_redrive" {
  queue_url = aws_sqs_queue.order_queue.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 5
  })
}

########################
# DynamoDB OrdersTable
########################

resource "aws_dynamodb_table" "orders_table" {
  name         = "OrdersTable"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }
}

########################
# SNS Topic for DLQ Alerts
########################

resource "aws_sns_topic" "order_dlq_alerts" {
  name = "order-dlq-alerts"
}

# Optional: email subscription
resource "aws_sns_topic_subscription" "order_dlq_email" {
  topic_arn = aws_sns_topic.order_dlq_alerts.arn
  protocol  = "email"
  endpoint  = "your-email@example.com" # đổi email
}

########################
# IAM Roles & Policies
########################

# Role cho order_api_handler
resource "aws_iam_role" "order_api_lambda_role" {
  name = "order-api-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "order_api_lambda_policy" {
  name = "order-api-lambda-policy"
  role = aws_iam_role.order_api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.order_queue.arn
      }
    ]
  })
}

# Role cho order_processor (đọc SQS + ghi DynamoDB)
resource "aws_iam_role" "order_processor_lambda_role" {
  name = "order-processor-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "order_processor_lambda_policy" {
  name = "order-processor-lambda-policy"
  role = aws_iam_role.order_processor_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.order_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.orders_table.arn
      }
    ]
  })
}

# Role riêng cho get_order_handler – chỉ đọc DynamoDB (least privilege)
resource "aws_iam_role" "get_order_lambda_role" {
  name = "get-order-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "get_order_lambda_policy" {
  name = "get-order-lambda-policy"
  role = aws_iam_role.get_order_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.orders_table.arn
      }
    ]
  })
}

########################
# Archive Lambda code
########################

data "archive_file" "order_api_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/order_api_handler.py"
  output_path = "${path.module}/lambda/order_api_handler.zip"
}

data "archive_file" "order_processor_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/order_processor.py"
  output_path = "${path.module}/lambda/order_processor.zip"
}

data "archive_file" "get_order_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/get_order_handler.py"
  output_path = "${path.module}/lambda/get_order_handler.zip"
}

########################
# Lambda Functions
########################

resource "aws_lambda_function" "order_api_handler" {
  function_name = "order-api-handler"
  role          = aws_iam_role.order_api_lambda_role.arn
  handler       = "order_api_handler.lambda_handler"
  runtime       = "python3.12"

  memory_size = 256
  timeout     = 10

  filename         = data.archive_file.order_api_zip.output_path
  source_code_hash = data.archive_file.order_api_zip.output_base64sha256

  environment {
    variables = {
      ORDER_QUEUE_URL = aws_sqs_queue.order_queue.id
    }
  }
}

resource "aws_lambda_function" "order_processor" {
  function_name = "order-processor"
  role          = aws_iam_role.order_processor_lambda_role.arn
  handler       = "order_processor.lambda_handler"
  runtime       = "python3.12"

  memory_size = 256

  # Visibility timeout của order-queue (60s) = 6 × timeout này,
  # đúng khuyến nghị của AWS cho event source mapping.
  timeout = 10

  filename         = data.archive_file.order_processor_zip.output_path
  source_code_hash = data.archive_file.order_processor_zip.output_base64sha256

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders_table.name
    }
  }
}

resource "aws_lambda_function" "get_order_handler" {
  function_name = "get-order-handler"
  role          = aws_iam_role.get_order_lambda_role.arn
  handler       = "get_order_handler.lambda_handler"
  runtime       = "python3.12"

  memory_size = 256
  timeout     = 10

  filename         = data.archive_file.get_order_zip.output_path
  source_code_hash = data.archive_file.get_order_zip.output_base64sha256

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders_table.name
    }
  }
}

########################
# CloudWatch Log Groups
########################

# Tạo tường minh để set retention. Nếu để Lambda tự tạo,
# log group mặc định giữ log VĨNH VIỄN → tốn tiền theo thời gian.
resource "aws_cloudwatch_log_group" "lambda_logs" {
  for_each = toset([
    aws_lambda_function.order_api_handler.function_name,
    aws_lambda_function.order_processor.function_name,
    aws_lambda_function.get_order_handler.function_name,
  ])

  name              = "/aws/lambda/${each.value}"
  retention_in_days = 14
}

########################
# Event Source Mapping
########################

resource "aws_lambda_event_source_mapping" "sqs_to_order_processor" {
  event_source_arn = aws_sqs_queue.order_queue.arn
  function_name    = aws_lambda_function.order_processor.arn
  batch_size       = 5
  enabled          = true

  # Chỉ trả lại message thực sự lỗi, thay vì retry cả batch 5 message.
  # Handler phải trả về {"batchItemFailures": [{"itemIdentifier": "<messageId>"}]}.
  function_response_types = ["ReportBatchItemFailures"]
}

########################
# CloudWatch Alarm cho DLQ
########################

resource "aws_cloudwatch_metric_alarm" "order_dlq_not_empty" {
  alarm_name          = "order-dlq-not-empty"
  alarm_description   = "Có message trong order-dlq — order-processor đang fail liên tục"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.order_dlq.name
  }

  alarm_actions = [aws_sns_topic.order_dlq_alerts.arn]
  ok_actions    = [aws_sns_topic.order_dlq_alerts.arn]
}

########################
# HTTP API Gateway
########################

resource "aws_apigatewayv2_api" "http_api" {
  name          = "orders-http-api"
  protocol_type = "HTTP"
}

# POST /orders
resource "aws_apigatewayv2_integration" "orders_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.order_api_handler.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "orders_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /orders"
  target    = "integrations/${aws_apigatewayv2_integration.orders_integration.id}"
}

# GET /orders/{id}
resource "aws_apigatewayv2_integration" "get_order_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_order_handler.arn
  integration_method     = "GET"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_order_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /orders/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.get_order_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# Permissions cho API → Lambda
resource "aws_lambda_permission" "apigw_invoke_order_api" {
  statement_id  = "AllowAPIGatewayInvokePostOrders"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order_api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_invoke_get_order" {
  statement_id  = "AllowAPIGatewayInvokeGetOrder"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_order_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

########################
# Outputs
########################

output "http_api_endpoint" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

```
---

## 5. Deploy
   
Trong thư mục project:
```bash
terraform init
terraform plan
terraform apply

```

Terraform sẽ in ra:
```text
http_api_endpoint = "https://xxxxx.execute-api.<region>.amazonaws.com"

```
---

## 6. Test

### 6.1. Tạo order (POST /orders)
```bash
ENDPOINT="https://xxxxx.execute-api.ap-southeast-1.amazonaws.com"

curl -X POST \
  "$ENDPOINT/orders" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "U-1",
    "items": [
      { "sku": "SKU-1", "qty": 2 },
      { "sku": "SKU-2", "qty": 1 }
    ]
  }'

```
Response mẫu:
```text
{
  "orderId": "6fe428b2-f182-4e23-abb3-f8de223a5df9",
  "status": "ACCEPTED"
}

```

### 6.2. Lấy order (GET /orders/{id})
```bash
curl "$ENDPOINT/orders/6fe428b2-f182-4e23-abb3-f8de223a5df9"

```
Response:
```json
{
  "createdAt": "2026-04-13T14:48:22.289168+00:00",
  "items": [
    { "sku": "SKU-1", "qty": 2.0 },
    { "sku": "SKU-2", "qty": 1.0 }
  ],
  "orderId": "6fe428b2-f182-4e23-abb3-f8de223a5df9",
  "userId": "U-1"
}

```

### 6.3. Kiểm tra trên AWS Console

   - DynamoDB → OrdersTable → xem các item.
   - SQS → order-queue & order-dlq.
   - Lambda logs → CloudWatch Logs:
      - /aws/lambda/order-api-handler
      - /aws/lambda/order-processor
      - /aws/lambda/get-order-handler
   - CloudWatch → Alarms → order-dlq-not-empty.
   - SNS → topic order-dlq-alerts → check email (nếu đã subscribe).

---

## 7. Hướng mở rộng

   - Thêm GET /orders?userId=... với DynamoDB GSI.
   - Thêm trạng thái đơn hàng status (NEW, PAID, SHIPPED, …).
   - Phát OrderCreated lên SNS hoặc EventBridge để tích hợp hệ thống khác.
   - Thêm CloudWatch Alarms cho Lambda `Errors`, `Throttles`, và
     `ApproximateAgeOfOldestMessage` của `order-queue` (phát hiện backlog).
   - Thêm authorizer (Cognito JWT) cho các endpoint — xem doc 02.
