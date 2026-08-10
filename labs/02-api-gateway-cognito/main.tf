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

variable "callback_url" {
  description = "Callback URL đăng ký với Cognito app client"
  type        = string
  default     = "http://localhost:3000/callback"
}

variable "http_backend_url" {
  description = <<-EOT
    Backend HTTP demo cho GET /orders/{id}.
    httpbin.org hay trả 503 do bị dùng quá tải. Nếu gặp, thử:
      -var="http_backend_url=https://postman-echo.com/get"
  EOT
  type        = string
  default     = "https://httpbin.org/get"
}

resource "random_id" "suffix" {
  byte_length = 4
}

########################
# Lambda
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

resource "aws_iam_role" "lambda_role" {
  name               = "create-order-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_create_order.py"
  output_path = "${path.module}/build/lambda_create_order.zip"
}

resource "aws_cloudwatch_log_group" "create_order" {
  name              = "/aws/lambda/create_order_function"
  retention_in_days = 14
}

resource "aws_lambda_function" "create_order" {
  function_name = "create_order_function"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_create_order.handler"
  runtime       = "python3.12"
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.create_order]
}

########################
# SNS
########################

resource "aws_sns_topic" "order_notifications" {
  name = "order-notifications"
}

########################
# Cognito
########################

resource "aws_cognito_user_pool" "orders" {
  name = "orders-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_pool_domain" "orders" {
  domain       = "orders-lab-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.orders.id
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "orders-web-client"
  user_pool_id = aws_cognito_user_pool.orders.id

  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"] # authorization code + PKCE
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [var.callback_url]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  refresh_token_validity = 30
  access_token_validity  = 1
  id_token_validity      = 1

  token_validity_units {
    refresh_token = "days"
    access_token  = "hours"
    id_token      = "hours"
  }
}

########################
# REST API & Resources
########################

resource "aws_api_gateway_rest_api" "order_api" {
  name        = "OrderServiceAPI"
  description = "REST API for orders (Lambda + SNS + usage plan + Cognito)"
}

resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_rest_api.order_api.root_resource_id
  path_part   = "orders"
}

resource "aws_api_gateway_resource" "order_id" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_resource.orders.id
  path_part   = "{id}"
}

resource "aws_api_gateway_resource" "order_id_notify" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_resource.order_id.id
  path_part   = "notify"
}

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.order_api.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.orders.arn]
  identity_source = "method.request.header.Authorization"
}

########################
# POST /orders -> Lambda (non-proxy, mapping template)
########################

resource "aws_api_gateway_method" "post_orders" {
  rest_api_id      = aws_api_gateway_rest_api.order_api.id
  resource_id      = aws_api_gateway_resource.orders.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_orders_integration" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.orders.id
  http_method = aws_api_gateway_method.post_orders.http_method

  # Với integration type AWS/AWS_PROXY, integration_http_method LUÔN là POST
  # (đó là method của Lambda Invoke API), không liên quan tới method của client.
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = aws_lambda_function.create_order.invoke_arn

  request_templates = {
    "application/json" = <<-EOF
      #set($inputRoot = $input.path('$'))
      {
        "orderId": "$context.requestId",
        "customerId": "$inputRoot.customer.id",
        "items": [
          #foreach($item in $inputRoot.items)
            {
              "sku": "$item.sku",
              "quantity": $item.qty
            }#if($foreach.hasNext),#end
          #end
        ],
        "source": "$inputRoot.meta.source",
        "campaign": "$inputRoot.meta.campaign",
        "requestContext": {
          "ip": "$context.identity.sourceIp",
          "userAgent": "$context.identity.userAgent",
          "stage": "$context.stage",
          "requestTime": "$context.requestTime"
        }
      }
    EOF
  }
}

resource "aws_lambda_permission" "api_gw_invoke_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.order_api.execution_arn}/*/POST/orders"
}

resource "aws_api_gateway_method_response" "post_orders_200" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.orders.id
  http_method = aws_api_gateway_method.post_orders.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "post_orders_400" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.orders.id
  http_method = aws_api_gateway_method.post_orders.http_method
  status_code = "400"

  response_models = {
    "application/json" = "Empty"
  }
}

# Nhánh default: KHÔNG có selection_pattern
resource "aws_api_gateway_integration_response" "post_orders_200" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.orders.id
  http_method = aws_api_gateway_method.post_orders.http_method
  status_code = aws_api_gateway_method_response.post_orders_200.status_code

  response_templates = {
    "application/json" = <<-EOF
      #set($inputRoot = $input.path('$'))
      {
        "orderId": "$inputRoot.order.id",
        "total": $inputRoot.order.total,
        "status": "CREATED",
        "debug": $input.json('$.debug')
      }
    EOF
  }

  depends_on = [
    aws_api_gateway_integration.post_orders_integration,
    aws_api_gateway_method_response.post_orders_200,
  ]
}

# Với LAMBDA integration, selection_pattern khớp với ERROR MESSAGE mà function
# ném ra — khác hẳn HTTP integration (khớp status code của backend).
# Lambda ném "[400] Missing customerId or items", regex dưới bắt tiền tố đó.
resource "aws_api_gateway_integration_response" "post_orders_400" {
  rest_api_id       = aws_api_gateway_rest_api.order_api.id
  resource_id       = aws_api_gateway_resource.orders.id
  http_method       = aws_api_gateway_method.post_orders.http_method
  status_code       = aws_api_gateway_method_response.post_orders_400.status_code
  selection_pattern = ".*\\[400\\].*"

  response_templates = {
    "application/json" = <<-EOF
      #set($msg = $input.path('$.errorMessage'))
      {
        "message": "$msg.replaceAll("\[400\] ", "")",
        "errorCode": "INVALID_ORDER"
      }
    EOF
  }

  depends_on = [
    aws_api_gateway_integration.post_orders_integration,
    aws_api_gateway_method_response.post_orders_400,
  ]
}

########################
# POST /orders/{id}/notify -> SNS
########################

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api_gw_sns_role" {
  name               = "api-gw-sns-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json
}

resource "aws_iam_role_policy" "api_gw_sns_policy" {
  name = "api-gw-sns-policy"
  role = aws_iam_role.api_gw_sns_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = aws_sns_topic.order_notifications.arn
    }]
  })
}

resource "aws_api_gateway_method" "post_notify" {
  rest_api_id      = aws_api_gateway_rest_api.order_api.id
  resource_id      = aws_api_gateway_resource.order_id_notify.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "post_notify_integration" {
  rest_api_id             = aws_api_gateway_rest_api.order_api.id
  resource_id             = aws_api_gateway_resource.order_id_notify.id
  http_method             = aws_api_gateway_method.post_notify.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.region}:sns:action/Publish"
  credentials             = aws_iam_role.api_gw_sns_role.arn

  # SNS là Query-protocol API: chỉ đọc form-urlencoded, KHÔNG đọc JSON body.
  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  # Trong VTL, escape dấu nháy kép bằng cách nhân đôi ("").
  request_templates = {
    "application/json" = <<-EOF
      #set($inputRoot = $input.path('$'))
      #set($payload = "{""orderId"":""$input.params('id')"",""notificationType"":""$inputRoot.type"",""target"":""$inputRoot.to"",""timestamp"":$context.requestTimeEpoch}")
      Action=Publish&TopicArn=$util.urlEncode('${aws_sns_topic.order_notifications.arn}')&Message=$util.urlEncode($payload)
    EOF
  }
}

resource "aws_api_gateway_method_response" "post_notify_200" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id_notify.id
  http_method = aws_api_gateway_method.post_notify.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "post_notify_500" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id_notify.id
  http_method = aws_api_gateway_method.post_notify.http_method
  status_code = "500"

  response_models = {
    "application/json" = "Empty"
  }
}

# Nhánh default: KHÔNG có selection_pattern.
#
# Đây từng là integration response DUY NHẤT của endpoint này, nên mọi lỗi từ
# SNS (400 MissingParameter, 403 AuthorizationError) đều bị viết lại thành
# 200 + "Notification queued". Client không có cách nào biết notification
# chưa từng được gửi.
resource "aws_api_gateway_integration_response" "post_notify_200" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id_notify.id
  http_method = aws_api_gateway_method.post_notify.http_method
  status_code = aws_api_gateway_method_response.post_notify_200.status_code

  response_templates = {
    "application/json" = <<-EOF
      {
        "message": "Notification queued"
      }
    EOF
  }

  depends_on = [
    aws_api_gateway_integration.post_notify_integration,
    aws_api_gateway_method_response.post_notify_200,
  ]
}

# SNS trả 4xx khi request sai (template hỏng, thiếu tham số) — đó là lỗi của
# CHÚNG TA, không phải của client, nên trả 500 chứ không phải 400.
# SNS trả 5xx khi chính nó gặp sự cố -> 500 luôn cho gọn.
resource "aws_api_gateway_integration_response" "post_notify_500" {
  rest_api_id       = aws_api_gateway_rest_api.order_api.id
  resource_id       = aws_api_gateway_resource.order_id_notify.id
  http_method       = aws_api_gateway_method.post_notify.http_method
  status_code       = aws_api_gateway_method_response.post_notify_500.status_code
  selection_pattern = "[45]\\d{2}"

  response_templates = {
    "application/json" = jsonencode({
      message = "Failed to queue notification"
    })
  }

  depends_on = [
    aws_api_gateway_integration.post_notify_integration,
    aws_api_gateway_method_response.post_notify_500,
  ]
}

########################
# GET /orders/{id} -> HTTP backend, bảo vệ bằng Cognito JWT
########################

resource "aws_api_gateway_method" "get_order" {
  rest_api_id      = aws_api_gateway_rest_api.order_api.id
  resource_id      = aws_api_gateway_resource.order_id.id
  http_method      = "GET"
  api_key_required = true

  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "get_order_integration" {
  rest_api_id             = aws_api_gateway_rest_api.order_api.id
  resource_id             = aws_api_gateway_resource.order_id.id
  http_method             = aws_api_gateway_method.get_order.http_method
  integration_http_method = "GET"
  type                    = "HTTP"
  uri                     = var.http_backend_url

  request_parameters = {
    "integration.request.querystring.order_id" = "method.request.path.id"
  }
}


# Với non-proxy integration, mỗi status code muốn trả về client phải được khai
# tường minh. Nếu chỉ khai 200, mọi response từ backend (kể cả 503) đều bị viết
# lại thành 200 và client không có cách nào biết backend đã chết.

resource "aws_api_gateway_method_response" "get_order_200" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id.id
  http_method = aws_api_gateway_method.get_order.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "get_order_502" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id.id
  http_method = aws_api_gateway_method.get_order.http_method
  status_code = "502"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "get_order_404" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id.id
  http_method = aws_api_gateway_method.get_order.http_method
  status_code = "404"

  response_models = {
    "application/json" = "Empty"
  }
}

# Nhánh default: KHÔNG có selection_pattern. Bắt mọi response không khớp
# pattern nào bên dưới — tức là các mã 2xx/3xx.
resource "aws_api_gateway_integration_response" "get_order_200" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  resource_id = aws_api_gateway_resource.order_id.id
  http_method = aws_api_gateway_method.get_order.http_method
  status_code = aws_api_gateway_method_response.get_order_200.status_code

  depends_on = [
    aws_api_gateway_integration.get_order_integration,
    aws_api_gateway_method_response.get_order_200,
  ]
}

# Với HTTP integration, selection_pattern là regex khớp với STATUS CODE của
# backend (khác Lambda integration, nơi nó khớp với error message).
resource "aws_api_gateway_integration_response" "get_order_502" {
  rest_api_id       = aws_api_gateway_rest_api.order_api.id
  resource_id       = aws_api_gateway_resource.order_id.id
  http_method       = aws_api_gateway_method.get_order.http_method
  status_code       = aws_api_gateway_method_response.get_order_502.status_code
  selection_pattern = "5\\d{2}"

  # Không trả nguyên body lỗi của backend cho client — nó có thể là HTML,
  # stack trace, hoặc lộ thông tin nội bộ.
  response_templates = {
    "application/json" = jsonencode({
      message = "Upstream service unavailable"
    })
  }

  depends_on = [
    aws_api_gateway_integration.get_order_integration,
    aws_api_gateway_method_response.get_order_502,
  ]
}

resource "aws_api_gateway_integration_response" "get_order_404" {
  rest_api_id       = aws_api_gateway_rest_api.order_api.id
  resource_id       = aws_api_gateway_resource.order_id.id
  http_method       = aws_api_gateway_method.get_order.http_method
  status_code       = aws_api_gateway_method_response.get_order_404.status_code
  selection_pattern = "4\\d{2}"

  response_templates = {
    "application/json" = jsonencode({
      message = "Order not found"
    })
  }

  depends_on = [
    aws_api_gateway_integration.get_order_integration,
    aws_api_gateway_method_response.get_order_404,
  ]
}

########################
# Gateway Responses
########################

# TẦNG THỨ BA, tách biệt với integration response.
#
# Khi API Gateway chưa hề nhận được response từ backend (timeout, DNS lỗi,
# authorizer từ chối, request không khớp route nào), nó tự sinh response.
# Lúc đó không có status code nào của backend để khớp, nên selection_pattern
# hoàn toàn không được xét — integration response bị bỏ qua.
#
# Quan sát được trong lab: backend treo -> client nhận
# 504 {"message": "Endpoint request timed out"} — câu của AWS, không phải
# của template nào trong file này.

resource "aws_api_gateway_gateway_response" "integration_timeout" {
  rest_api_id   = aws_api_gateway_rest_api.order_api.id
  response_type = "INTEGRATION_TIMEOUT"
  status_code   = "504"

  response_templates = {
    "application/json" = jsonencode({
      message = "Upstream service did not respond in time"
    })
  }
}

resource "aws_api_gateway_gateway_response" "integration_failure" {
  rest_api_id   = aws_api_gateway_rest_api.order_api.id
  response_type = "INTEGRATION_FAILURE"
  status_code   = "502"

  response_templates = {
    "application/json" = jsonencode({
      message = "Upstream service unreachable"
    })
  }
}

# Mặc định API Gateway trả body rỗng cho 401/403 của authorizer.
resource "aws_api_gateway_gateway_response" "unauthorized" {
  rest_api_id   = aws_api_gateway_rest_api.order_api.id
  response_type = "UNAUTHORIZED"
  status_code   = "401"

  response_templates = {
    "application/json" = jsonencode({
      message = "Missing or invalid authentication token"
    })
  }
}

########################
# Deployment & Stage
########################

resource "aws_api_gateway_deployment" "order_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id

  # KHÔNG dùng timestamp(): sẽ tạo deployment mới mỗi lần apply kể cả khi
  # không có gì thay đổi.
  triggers = {
    # Phải liệt kê CẢ integration_response và method_response. Thiếu chúng thì
    # sửa mapping response sẽ được apply lên API nhưng không bao giờ được
    # deploy sang stage — bạn sửa xong mà endpoint vẫn trả kết quả cũ.
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.orders,
      aws_api_gateway_resource.order_id,
      aws_api_gateway_resource.order_id_notify,
      aws_api_gateway_method.post_orders,
      aws_api_gateway_method.post_notify,
      aws_api_gateway_method.get_order,
      aws_api_gateway_integration.post_orders_integration,
      aws_api_gateway_integration.post_notify_integration,
      aws_api_gateway_integration.get_order_integration,
      aws_api_gateway_integration_response.post_orders_200,
      aws_api_gateway_integration_response.post_orders_400,
      aws_api_gateway_integration_response.post_notify_200,
      aws_api_gateway_integration_response.post_notify_500,
      aws_api_gateway_integration_response.get_order_200,
      aws_api_gateway_integration_response.get_order_502,
      aws_api_gateway_integration_response.get_order_404,
      aws_api_gateway_method_response.post_orders_200,
      aws_api_gateway_method_response.post_orders_400,
      aws_api_gateway_method_response.post_notify_200,
      aws_api_gateway_method_response.post_notify_500,
      aws_api_gateway_method_response.get_order_200,
      aws_api_gateway_method_response.get_order_502,
      aws_api_gateway_method_response.get_order_404,
      aws_api_gateway_gateway_response.integration_timeout,
      aws_api_gateway_gateway_response.integration_failure,
      aws_api_gateway_gateway_response.unauthorized,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  # Đưa vào triggers là CHƯA ĐỦ. Khi một integration response được sửa
  # TẠI CHỖ (in-place update), Terraform không đảm bảo nó được apply xong
  # trước khi deployment mới được tạo. Deployment chụp snapshot cấu hình tại
  # thời điểm tạo, nên nếu chạy trước thì nó chụp phải cấu hình CŨ.
  #
  # Triệu chứng: apply thành công, Console hiển thị template mới, nhưng
  # endpoint vẫn trả kết quả cũ. Lambda code và gateway response thì lại đổi
  # ngay (chúng không cần deployment) — nên bạn thấy trạng thái nửa cũ nửa mới,
  # rất khó đoán.
  #
  # depends_on tường minh mới ép được thứ tự.
  depends_on = [
    aws_api_gateway_integration.post_orders_integration,
    aws_api_gateway_integration.post_notify_integration,
    aws_api_gateway_integration.get_order_integration,
    aws_api_gateway_integration_response.post_orders_200,
    aws_api_gateway_integration_response.post_orders_400,
    aws_api_gateway_integration_response.post_notify_200,
    aws_api_gateway_integration_response.post_notify_500,
    aws_api_gateway_integration_response.get_order_200,
    aws_api_gateway_integration_response.get_order_502,
    aws_api_gateway_integration_response.get_order_404,
    aws_api_gateway_gateway_response.integration_timeout,
    aws_api_gateway_gateway_response.integration_failure,
    aws_api_gateway_gateway_response.unauthorized,
  ]
}

resource "aws_cloudwatch_log_group" "api_gw_access_logs" {
  name              = "/aws/apigateway/OrderServiceAPI-access"
  retention_in_days = 14
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.order_api.id
  deployment_id = aws_api_gateway_deployment.order_api_deployment.id
  stage_name    = "prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw_access_logs.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      caller           = "$context.identity.caller"
      user             = "$context.identity.user"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      resourcePath     = "$context.resourcePath"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  depends_on = [aws_api_gateway_account.account]
}

resource "aws_api_gateway_method_settings" "all_methods_logging" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"

    # data_trace ghi FULL request/response body vào CloudWatch.
    # Chỉ bật ở dev/stage, không bật ở prod (PII + chi phí log).
    data_trace_enabled = false
  }
}

########################
# API Gateway -> CloudWatch (account-level)
########################

data "aws_iam_policy_document" "apigw_cloudwatch" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api_gw_cloudwatch_role" {
  name               = "api-gw-cloudwatch-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_cloudwatch.json
}

resource "aws_iam_role_policy_attachment" "api_gw_cloudwatch" {
  role       = aws_iam_role.api_gw_cloudwatch_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# LƯU Ý: đây là cấu hình cấp ACCOUNT + REGION, không phải cấp API.
# Nếu account đã có role khác, apply lab này sẽ ghi đè lên nó.
resource "aws_api_gateway_account" "account" {
  cloudwatch_role_arn = aws_iam_role.api_gw_cloudwatch_role.arn
}

########################
# Usage Plan & API Key
########################

resource "aws_api_gateway_api_key" "mobile_key" {
  name    = "mobile-app-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "mobile_plan" {
  name = "MobilePlan"

  api_stages {
    api_id = aws_api_gateway_rest_api.order_api.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {
    burst_limit = 200
    rate_limit  = 100
  }

  quota_settings {
    limit  = 100000
    offset = 0
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "mobile_plan_key" {
  key_id        = aws_api_gateway_api_key.mobile_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.mobile_plan.id
}

########################
# Outputs
########################

output "api_invoke_url" {
  value = aws_api_gateway_stage.prod.invoke_url
}

output "sns_topic_arn" {
  value = aws_sns_topic.order_notifications.arn
}

output "api_key_mobile" {
  value     = aws_api_gateway_api_key.mobile_key.value
  sensitive = true
}

output "cognito_domain" {
  value = "${aws_cognito_user_pool_domain.orders.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_hosted_ui_url" {
  description = "Mở URL này để đăng nhập và lấy authorization code"
  value = join("", [
    "https://${aws_cognito_user_pool_domain.orders.domain}",
    ".auth.${var.region}.amazoncognito.com/login",
    "?client_id=${aws_cognito_user_pool_client.web.id}",
    "&response_type=code",
    "&scope=openid+email+profile",
    "&redirect_uri=${var.callback_url}",
  ])
}
