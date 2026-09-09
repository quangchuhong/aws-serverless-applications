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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "provisioned_concurrency" {
  description = <<-EOT
    Số instance giữ ấm cho alias prod của Lambda A.
    CẢNH BÁO: provisioned concurrency tính tiền theo GIỜ kể cả khi không có
    request nào. Đặt 0 để tắt hoàn toàn khi không cần thử nghiệm.
  EOT
  type        = number
  default     = 0
}

variable "reserved_concurrency" {
  description = "Giới hạn concurrency tối đa của Lambda A. -1 = không giới hạn."
  type        = number
  default     = 5
}

variable "simulate_async_failure" {
  description = "Cho Lambda B luôn throw, để quan sát retry + on_failure destination"
  type        = bool
  default     = false
}

resource "random_id" "suffix" {
  byte_length = 4
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

resource "aws_iam_role" "lambda_exec_role" {
  name               = "demo-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Cho phép Lambda B gửi event thất bại sang SQS destination
resource "aws_iam_role_policy" "lambda_destination" {
  name = "lambda-on-failure-destination"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.async_dlq.arn
    }]
  })
}

########################
# Lambda A – sync, qua HTTP API
########################

data "archive_file" "lambda_sync_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_sync.mjs"
  output_path = "${path.module}/build/lambda_sync.zip"
}

resource "aws_cloudwatch_log_group" "sync" {
  name              = "/aws/lambda/sync-api-lambda"
  retention_in_days = 7
}

resource "aws_lambda_function" "sync_api_lambda" {
  function_name = "sync-api-lambda"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_sync.handler"
  runtime       = "nodejs22.x"
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.lambda_sync_zip.output_path
  source_code_hash = data.archive_file.lambda_sync_zip.output_base64sha256

  reserved_concurrent_executions = var.reserved_concurrency

  # Bắt buộc để tạo version bất biến, alias mới trỏ vào được.
  publish = true

  depends_on = [aws_cloudwatch_log_group.sync]
}

resource "aws_lambda_alias" "prod" {
  name             = "prod"
  function_name    = aws_lambda_function.sync_api_lambda.function_name
  function_version = aws_lambda_function.sync_api_lambda.version
}

# Provisioned concurrency gắn vào ALIAS, không gắn được vào $LATEST.
resource "aws_lambda_provisioned_concurrency_config" "prod" {
  count = var.provisioned_concurrency > 0 ? 1 : 0

  function_name                     = aws_lambda_function.sync_api_lambda.function_name
  qualifier                         = aws_lambda_alias.prod.name
  provisioned_concurrent_executions = var.provisioned_concurrency
}

########################
# HTTP API Gateway -> alias prod
########################

resource "aws_apigatewayv2_api" "demo_sync_api" {
  name          = "demo-sync-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "sync_integration" {
  api_id                 = aws_apigatewayv2_api.demo_sync_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.prod.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "test_route" {
  api_id    = aws_apigatewayv2_api.demo_sync_api.id
  route_key = "GET /test"
  target    = "integrations/${aws_apigatewayv2_integration.sync_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.demo_sync_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke_sync" {
  statement_id  = "AllowAPIGatewayInvokeSync"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync_api_lambda.function_name
  qualifier     = aws_lambda_alias.prod.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.demo_sync_api.execution_arn}/*/GET/test"
}

########################
# Lambda B – async từ S3
########################

data "archive_file" "lambda_async_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_async.mjs"
  output_path = "${path.module}/build/lambda_async.zip"
}

resource "aws_cloudwatch_log_group" "async" {
  name              = "/aws/lambda/async-s3-lambda"
  retention_in_days = 7
}

resource "aws_lambda_function" "async_s3_lambda" {
  function_name = "async-s3-lambda"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_async.handler"
  runtime       = "nodejs22.x"
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.lambda_async_zip.output_path
  source_code_hash = data.archive_file.lambda_async_zip.output_base64sha256

  environment {
    variables = {
      SIMULATE_FAILURE = tostring(var.simulate_async_failure)
    }
  }

  depends_on = [aws_cloudwatch_log_group.async]
}

resource "aws_sqs_queue" "async_dlq" {
  name                      = "async-s3-lambda-dlq"
  message_retention_seconds = 1209600 # 14 ngày
}

# Đây là EVENT DESTINATION (function_event_invoke_config), không phải
# dead_letter_config. Payload gửi đi kèm cả request/response context và
# error message — debug dễ hơn DLQ kiểu cũ.
resource "aws_lambda_function_event_invoke_config" "async_s3" {
  function_name = aws_lambda_function.async_s3_lambda.function_name

  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = aws_sqs_queue.async_dlq.arn
    }
  }
}

########################
# S3 bucket + trigger
########################

resource "aws_s3_bucket" "demo" {
  bucket        = "demo-lambda-concurrency-${random_id.suffix.hex}"
  force_destroy = true # cho phép terraform destroy dù bucket còn object
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.async_s3_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.demo.arn
}

resource "aws_s3_bucket_notification" "demo" {
  bucket = aws_s3_bucket.demo.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.async_s3_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

########################
# Outputs
########################

output "sync_api_url" {
  description = "Gọi GET {url}/test để test sync Lambda"
  value       = "${aws_apigatewayv2_api.demo_sync_api.api_endpoint}/test"
}

output "s3_bucket" {
  description = "Upload file vào bucket này để trigger async Lambda"
  value       = aws_s3_bucket.demo.bucket
}

output "async_dlq_url" {
  value = aws_sqs_queue.async_dlq.id
}
