###############################################################################
# LAB 2-4: MCP server remote trên AWS Serverless
#
#   Client MCP --(Streamable HTTP + Bearer)--> API Gateway HTTP API
#                                                |  JWT authorizer (Cognito)
#                                                v
#                                        Lambda  mcp-server
#                                          |            |
#                                    DynamoDB          SQS ---> Lambda job-worker
#                                    (Orders/Jobs)      |                |
#                                                      DLQ         DynamoDB
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name       = var.project_name
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Scope OAuth đầy đủ mà token M2M phải có: "<resource server id>/<scope>"
  required_scope = "${aws_cognito_resource_server.mcp.identifier}/invoke"

  tags = {
    Project   = local.name
    ManagedBy = "terraform"
    Lab       = "mcp-on-aws-serverless"
  }
}

###############################################################################
# 1. Lưu trữ: DynamoDB
###############################################################################

resource "aws_dynamodb_table" "orders" {
  name         = "${local.name}-orders"
  billing_mode = "PAY_PER_REQUEST" # lab: không tốn tiền khi không dùng
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "S"
  }

  # Tool list_orders(status=...) query trên GSI này thay vì Scan.
  global_secondary_index {
    name            = "status-createdAt-index"
    hash_key        = "status"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  tags = local.tags
}

resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "jobId"

  attribute {
    name = "jobId"
    type = "S"
  }

  # Job tự dọn sau 24h — không cần viết cleanup job.
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = local.tags
}

###############################################################################
# 2. Hàng đợi cho tool chạy lâu
###############################################################################

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${local.name}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 ngày
  tags                      = local.tags
}

resource "aws_sqs_queue" "jobs" {
  name = "${local.name}-jobs"

  # Quy tắc: visibility timeout >= 6x timeout của Lambda consumer.
  visibility_timeout_seconds = 180

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.tags
}

###############################################################################
# 3. Đóng gói Lambda
###############################################################################

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/lambda.zip"
}

###############################################################################
# 4. IAM
###############################################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- Role cho MCP server -----------------------------------------------------

resource "aws_iam_role" "mcp_server" {
  name               = "${local.name}-mcp-server-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "mcp_server" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.mcp_server.arn}:*"]
  }

  # Least privilege: chỉ đúng 2 bảng + 1 index của lab này.
  statement {
    sid     = "OrdersRead"
    actions = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
    resources = [
      aws_dynamodb_table.orders.arn,
      "${aws_dynamodb_table.orders.arn}/index/*",
    ]
  }

  statement {
    sid       = "JobsReadWrite"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.jobs.arn]
  }

  statement {
    sid       = "EnqueueJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # Tool tail_lambda_logs: chỉ đọc được log group của chính project này,
  # không phải toàn bộ log của tài khoản.
  statement {
    sid       = "ReadOwnLogs"
    actions   = ["logs:FilterLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name}-*:*"]
  }
}

resource "aws_iam_role_policy" "mcp_server" {
  name   = "${local.name}-mcp-server-policy"
  role   = aws_iam_role.mcp_server.id
  policy = data.aws_iam_policy_document.mcp_server.json
}

# --- Role cho job worker -----------------------------------------------------

resource "aws_iam_role" "job_worker" {
  name               = "${local.name}-job-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "job_worker" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.job_worker.arn}:*"]
  }

  statement {
    sid       = "WriteOrders"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    sid       = "UpdateJobs"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.jobs.arn]
  }

  statement {
    sid = "ConsumeQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.jobs.arn]
  }
}

resource "aws_iam_role_policy" "job_worker" {
  name   = "${local.name}-job-worker-policy"
  role   = aws_iam_role.job_worker.id
  policy = data.aws_iam_policy_document.job_worker.json
}

###############################################################################
# 5. Lambda functions
###############################################################################

resource "aws_cloudwatch_log_group" "mcp_server" {
  name              = "/aws/lambda/${local.name}-mcp-server"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "mcp_server" {
  function_name = "${local.name}-mcp-server"
  role          = aws_iam_role.mcp_server.arn
  handler       = "mcp_server.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"] # rẻ hơn x86 khoảng 20%

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  # Phải nhỏ hơn timeout của API Gateway (~29s) để client nhận được lỗi tử tế.
  timeout     = 25
  memory_size = 512

  environment {
    variables = {
      ORDERS_TABLE   = aws_dynamodb_table.orders.name
      JOBS_TABLE     = aws_dynamodb_table.jobs.name
      QUEUE_URL      = aws_sqs_queue.jobs.url
      COGNITO_ISSUER = local.cognito_issuer
      REQUIRED_SCOPE = local.required_scope
    }
  }

  depends_on = [aws_cloudwatch_log_group.mcp_server]
  tags       = local.tags
}

resource "aws_cloudwatch_log_group" "job_worker" {
  name              = "/aws/lambda/${local.name}-job-worker"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "job_worker" {
  function_name = "${local.name}-job-worker"
  role          = aws_iam_role.job_worker.arn
  handler       = "job_worker.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  timeout     = 30 # visibility_timeout của queue = 180s = 6x
  memory_size = 256

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
      JOBS_TABLE   = aws_dynamodb_table.jobs.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.job_worker]
  tags       = local.tags
}

resource "aws_lambda_event_source_mapping" "jobs" {
  event_source_arn = aws_sqs_queue.jobs.arn
  function_name    = aws_lambda_function.job_worker.arn
  batch_size       = 5

  # Chỉ retry message lỗi, không retry cả batch.
  function_response_types = ["ReportBatchItemFailures"]
}

###############################################################################
# 6. Cognito — Authorization Server (OAuth 2.0 client_credentials, M2M)
###############################################################################

resource "aws_cognito_user_pool" "mcp" {
  name = "${local.name}-pool"
  tags = local.tags
}

resource "aws_cognito_user_pool_domain" "mcp" {
  domain       = "${local.name}-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.mcp.id
}

# Resource server = định nghĩa "API được bảo vệ" và các scope của nó.
resource "aws_cognito_resource_server" "mcp" {
  identifier   = "mcp-api"
  name         = "${local.name}-resource-server"
  user_pool_id = aws_cognito_user_pool.mcp.id

  scope {
    scope_name        = "invoke"
    scope_description = "Được phép gọi MCP server"
  }
}

# App client machine-to-machine: dùng client_credentials, không có người dùng.
resource "aws_cognito_user_pool_client" "m2m" {
  name         = "${local.name}-m2m-client"
  user_pool_id = aws_cognito_user_pool.mcp.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = [local.required_scope]
  supported_identity_providers         = ["COGNITO"]

  access_token_validity = 60
  token_validity_units {
    access_token = "minutes"
  }

  depends_on = [aws_cognito_user_pool_domain.mcp]
}

locals {
  cognito_issuer   = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.mcp.id}"
  cognito_token_ep = "https://${aws_cognito_user_pool_domain.mcp.domain}.auth.${local.region}.amazoncognito.com/oauth2/token"
}

###############################################################################
# 7. API Gateway HTTP API — transport Streamable HTTP
###############################################################################

resource "aws_apigatewayv2_api" "mcp" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
  description   = "MCP server (Streamable HTTP transport)"
  tags          = local.tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.mcp.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationErr = "$context.integrationErrorMessage"
      authorizerErr  = "$context.authorizer.error"
      # Ai gọi tool nào — cực kỳ hữu ích khi audit hành vi agent.
      clientId = "$context.authorizer.claims.client_id"
    })
  }

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "mcp" {
  api_id                 = aws_apigatewayv2_api.mcp.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.mcp_server.invoke_arn
  payload_format_version = "2.0"
}

# GOTCHA quan trọng: token client_credentials của Cognito KHÔNG có claim `aud`,
# nó có `client_id`. API Gateway HTTP API chấp nhận cả hai — nên `audience`
# phải đặt bằng chính App Client ID.
resource "aws_apigatewayv2_authorizer" "jwt" {
  count = var.enable_auth ? 1 : 0

  api_id           = aws_apigatewayv2_api.mcp.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name}-cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.m2m.id]
    issuer   = local.cognito_issuer
  }
}

resource "aws_apigatewayv2_route" "mcp_post" {
  api_id    = aws_apigatewayv2_api.mcp.id
  route_key = "POST /mcp"
  target    = "integrations/${aws_apigatewayv2_integration.mcp.id}"

  authorization_type   = var.enable_auth ? "JWT" : "NONE"
  authorizer_id        = var.enable_auth ? aws_apigatewayv2_authorizer.jwt[0].id : null
  authorization_scopes = var.enable_auth ? [local.required_scope] : null
}

resource "aws_apigatewayv2_route" "mcp_get" {
  api_id    = aws_apigatewayv2_api.mcp.id
  route_key = "GET /mcp"
  target    = "integrations/${aws_apigatewayv2_integration.mcp.id}"

  authorization_type   = var.enable_auth ? "JWT" : "NONE"
  authorizer_id        = var.enable_auth ? aws_apigatewayv2_authorizer.jwt[0].id : null
  authorization_scopes = var.enable_auth ? [local.required_scope] : null
}

# RFC 9728 — PHẢI để public: client chưa có token mới đọc được nó để biết
# đường đi xin token.
resource "aws_apigatewayv2_route" "prm" {
  api_id             = aws_apigatewayv2_api.mcp.id
  route_key          = "GET /.well-known/oauth-protected-resource"
  target             = "integrations/${aws_apigatewayv2_integration.mcp.id}"
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp_server.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.mcp.execution_arn}/*/*"
}

###############################################################################
# 8. Cảnh báo tối thiểu
###############################################################################

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.name}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Có job vào DLQ — worker đang lỗi liên tục."
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.jobs_dlq.name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "mcp_errors" {
  alarm_name          = "${local.name}-mcp-server-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "MCP server Lambda đang throw exception."
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.mcp_server.function_name
  }

  tags = local.tags
}
