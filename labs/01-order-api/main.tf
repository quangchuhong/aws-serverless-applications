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
  region = var.region
}

variable "region" {
  description = "AWS region để deploy lab"
  type        = string
  default     = "ap-southeast-1"
}

variable "alert_email" {
  description = "Email nhận alert khi có message vào DLQ. Để trống thì bỏ qua subscription."
  type        = string
  default     = ""
}

locals {
  # Visibility timeout = 6 x Lambda timeout, theo khuyến nghị của AWS
  # cho event source mapping.
  processor_timeout  = 10
  visibility_timeout = 60
}

########################
# SQS Queues (main + DLQ)
########################

resource "aws_sqs_queue" "order_queue" {
  name                       = "order-queue"
  visibility_timeout_seconds = local.visibility_timeout
  message_retention_seconds  = 345600 # 4 ngày (mặc định)
  receive_wait_time_seconds  = 20     # long polling, giảm empty receive
}

resource "aws_sqs_queue" "order_dlq" {
  name = "order-dlq"

  # DLQ giữ lâu hơn queue chính: message chỉ vào đây khi đã lỗi nhiều lần,
  # cần đủ thời gian để điều tra rồi redrive.
  message_retention_seconds = 1209600 # 14 ngày (tối đa)
}

resource "aws_sqs_queue_redrive_policy" "order_queue_redrive" {
  queue_url = aws_sqs_queue.order_queue.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 5
  })
}

########################
# DynamoDB
########################

resource "aws_dynamodb_table" "orders_table" {
  name         = "OrdersTable"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }
}

########################
# SNS Topic for alerts
########################

resource "aws_sns_topic" "order_dlq_alerts" {
  name = "order-dlq-alerts"
}

resource "aws_sns_topic_subscription" "order_dlq_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.order_dlq_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

########################
# IAM
########################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- order_api_handler: chỉ gửi SQS ---

resource "aws_iam_role" "order_api_lambda_role" {
  name               = "order-api-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "order_api_lambda_policy" {
  name = "order-api-lambda-policy"
  role = aws_iam_role.order_api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.order_api.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.order_queue.arn
      }
    ]
  })
}

# --- order_processor: đọc SQS, ghi DynamoDB ---

resource "aws_iam_role" "order_processor_lambda_role" {
  name               = "order-processor-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "order_processor_lambda_policy" {
  name = "order-processor-lambda-policy"
  role = aws_iam_role.order_processor_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.order_processor.arn}:*"
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
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.orders_table.arn
      }
    ]
  })
}

# --- get_order_handler: CHỈ đọc DynamoDB (least privilege) ---

resource "aws_iam_role" "get_order_lambda_role" {
  name               = "get-order-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "get_order_lambda_policy" {
  name = "get-order-lambda-policy"
  role = aws_iam_role.get_order_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.get_order.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.orders_table.arn
      }
    ]
  })
}

########################
# CloudWatch Log Groups
########################

# Tạo tường minh để set retention. Nếu để Lambda tự tạo, log group giữ log
# vĩnh viễn.
resource "aws_cloudwatch_log_group" "order_api" {
  name              = "/aws/lambda/order-api-handler"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "order_processor" {
  name              = "/aws/lambda/order-processor"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "get_order" {
  name              = "/aws/lambda/get-order-handler"
  retention_in_days = 14
}

########################
# Lambda code packaging
########################

data "archive_file" "order_api_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/order_api_handler.py"
  output_path = "${path.module}/build/order_api_handler.zip"
}

data "archive_file" "order_processor_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/order_processor.py"
  output_path = "${path.module}/build/order_processor.zip"
}

data "archive_file" "get_order_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/get_order_handler.py"
  output_path = "${path.module}/build/get_order_handler.zip"
}

########################
# Lambda Functions
########################

resource "aws_lambda_function" "order_api_handler" {
  function_name = "order-api-handler"
  role          = aws_iam_role.order_api_lambda_role.arn
  handler       = "order_api_handler.lambda_handler"
  runtime       = "python3.12"
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.order_api_zip.output_path
  source_code_hash = data.archive_file.order_api_zip.output_base64sha256

  environment {
    variables = {
      ORDER_QUEUE_URL = aws_sqs_queue.order_queue.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.order_api]
}

resource "aws_lambda_function" "order_processor" {
  function_name = "order-processor"
  role          = aws_iam_role.order_processor_lambda_role.arn
  handler       = "order_processor.lambda_handler"
  runtime       = "python3.12"
  memory_size   = 256
  timeout       = local.processor_timeout

  filename         = data.archive_file.order_processor_zip.output_path
  source_code_hash = data.archive_file.order_processor_zip.output_base64sha256

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders_table.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.order_processor]
}

resource "aws_lambda_function" "get_order_handler" {
  function_name = "get-order-handler"
  role          = aws_iam_role.get_order_lambda_role.arn
  handler       = "get_order_handler.lambda_handler"
  runtime       = "python3.12"
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.get_order_zip.output_path
  source_code_hash = data.archive_file.get_order_zip.output_base64sha256

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders_table.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.get_order]
}

########################
# Event Source Mapping
########################

resource "aws_lambda_event_source_mapping" "sqs_to_order_processor" {
  event_source_arn = aws_sqs_queue.order_queue.arn
  function_name    = aws_lambda_function.order_processor.arn
  batch_size       = 5
  enabled          = true

  # Chỉ retry message thực sự lỗi, không kéo cả batch.
  function_response_types = ["ReportBatchItemFailures"]
}

########################
# Alarm cho DLQ
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

resource "aws_cloudwatch_log_group" "http_api_access" {
  name              = "/aws/apigateway/orders-http-api-access"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.http_api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }
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
  integration_method     = "POST" # luôn POST với AWS_PROXY, bất kể method của route
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_order_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /orders/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.get_order_integration.id}"
}

# Permissions cho API -> Lambda
resource "aws_lambda_permission" "apigw_invoke_order_api" {
  statement_id  = "AllowAPIGatewayInvokePostOrders"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order_api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/POST/orders"
}

resource "aws_lambda_permission" "apigw_invoke_get_order" {
  statement_id  = "AllowAPIGatewayInvokeGetOrder"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_order_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/GET/orders/*"
}

########################
# Outputs
########################

output "http_api_endpoint" {
  description = "Base URL của API"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}

output "order_queue_url" {
  value = aws_sqs_queue.order_queue.id
}

output "order_dlq_url" {
  value = aws_sqs_queue.order_dlq.id
}
