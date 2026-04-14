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
```

---

## 4. Triển khai bằng Terraform

Dưới đây là tóm tắt các phần chính; trong repo bạn nên giữ full main.tf như đã áp dụng thành công.

### 4.1. Lambda

lambda_create_order.py:
```python
import json

def handler(event, context):
    print("Received event:", json.dumps(event))

    if not event.get("customerId") or not event.get("items"):
        return {
            "ok": False,
            "errorCode": "INVALID_ORDER",
            "message": "Missing customerId or items"
        }

    return {
        "ok": True,
        "order": {
            "id": f"ord-{event['orderId']}",
            "total": 199.5
        },
        "debug": {
            "received": event
        }
    }

```

Terraform (tóm tắt):
```hcl
terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  default = "ap-southeast-1"
}

provider "aws" {
  region = var.region
}

resource "aws_iam_role" "lambda_role" { ... }
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" { ... }

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_create_order.py"
  output_path = "${path.module}/lambda_create_order.zip"
}

resource "aws_lambda_function" "create_order" {
  function_name = "create_order_function"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_create_order.handler"
  runtime       = "python3.11"
  filename      = data.archive_file.lambda_zip.output_path
}

```

### 4.2. SNS Topic
```hcl
resource "aws_sns_topic" "order_notifications" {
  name = "order-notifications"
}
```

### 4.3. API Gateway REST API & Resources

```hcl
resource "aws_api_gateway_rest_api" "order_api" {
  name        = "OrderServiceAPI"
  description = "REST API for orders (Lambda + SNS + usage plan)"
}

# /orders
resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_rest_api.order_api.root_resource_id
  path_part   = "orders"
}

# /orders/{id}
resource "aws_api_gateway_resource" "order_id" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_resource.orders.id
  path_part   = "{id}"
}

# /orders/{id}/notify
resource "aws_api_gateway_resource" "order_id_notify" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_resource.order_id.id
  path_part   = "notify"
}

```

### 4.4. Các endpoint & integration

a. POST /orders → Lambda + mapping template

Method:
```hcl
resource "aws_api_gateway_method" "post_orders" {
  rest_api_id     = aws_api_gateway_rest_api.order_api.id
  resource_id     = aws_api_gateway_resource.orders.id
  http_method     = "POST"
  authorization   = "NONE"
  api_key_required = true
}

```

Integration + request mapping:
```hcl
resource "aws_api_gateway_integration" "post_orders_integration" {
  rest_api_id             = aws_api_gateway_rest_api.order_api.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.post_orders.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = aws_lambda_function.create_order.invoke_arn

  request_templates = {
    "application/json" = <<EOF
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
    "apiKey": "$context.identity.apiKey",
    "stage": "$context.stage",
    "requestTime": "$context.requestTime"
  }
}
EOF
  }
}

```

Lambda permission:

```hcl
resource "aws_lambda_permission" "api_gw_invoke_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create_order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.order_api.execution_arn}/*/POST/orders"
}

```

Response mapping:

```hcl
resource "aws_api_gateway_method_response" "post_orders_200" { ... }

resource "aws_api_gateway_integration_response" "post_orders_200" {
  ...
  response_templates = {
    "application/json" = <<EOF
#set($inputRoot = $input.path('$'))

#if($inputRoot.ok == true)
{
  "orderId": "$inputRoot.order.id",
  "total": $inputRoot.order.total,
  "status": "CREATED",
  "debug": $inputRoot.debug
}
#else
{
  "message": "Order creation failed",
  "errorCode": "$inputRoot.errorCode",
  "details": "$inputRoot.message"
}
#end
EOF
  }

  depends_on = [
    aws_api_gateway_integration.post_orders_integration,
    aws_api_gateway_method_response.post_orders_200
  ]
}

```

### b. POST /orders/{id}/notify → SNS

IAM role + policy cho API Gateway gọi SNS:
```hcl
resource "aws_iam_role" "api_gw_sns_role" { ... }

resource "aws_iam_role_policy" "api_gw_sns_policy" {
  ...
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["sns:Publish"],
      Resource = aws_sns_topic.order_notifications.arn
    }]
  })
}

```

Method + Integration:

```hcl
resource "aws_api_gateway_method" "post_notify" {
  rest_api_id     = aws_api_gateway_rest_api.order_api.id
  resource_id     = aws_api_gateway_resource.order_id_notify.id
  http_method     = "POST"
  authorization   = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_notify_integration" {
  rest_api_id             = aws_api_gateway_rest_api.order_api.id
  resource_id             = aws_api_gateway_resource.order_id_notify.id
  http_method             = aws_api_gateway_method.post_notify.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.region}:sns:action/Publish"
  credentials             = aws_iam_role.api_gw_sns_role.arn

  request_templates = {
    "application/json" = <<EOF
#set($inputRoot = $input.path('$'))

{
  "TopicArn": "${aws_sns_topic.order_notifications.arn}",
  "Message": "$util.escapeJavaScript($util.toJson({
    "orderId": $input.params('id'),
    "notificationType": $inputRoot.type,
    "target": $inputRoot.to,
    "timestamp": $context.requestTimeEpoch
  }))"
}
EOF
  }
}

```

Response:
```hcl
resource "aws_api_gateway_method_response" "post_notify_200" { ... }

resource "aws_api_gateway_integration_response" "post_notify_200" {
  ...
  response_templates = {
    "application/json" = <<EOF
{
  "message": "Notification queued"
}
EOF
  }

  depends_on = [
    aws_api_gateway_integration.post_notify_integration,
    aws_api_gateway_method_response.post_notify_200
  ]
}

```

c. GET /orders/{id} → HTTP (httpbin.org)
```hcl
resource "aws_api_gateway_method" "get_order" {
  rest_api_id     = aws_api_gateway_rest_api.order_api.id
  resource_id     = aws_api_gateway_resource.order_id.id
  http_method     = "GET"
  authorization   = "NONE"
  api_key_required = true

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
  uri                     = "https://httpbin.org/get"

  request_parameters = {
    "integration.request.querystring.order_id" = "method.request.path.id"
  }

  request_templates = {
    "application/json" = <<EOF
#set($allParams = $input.params())
{
  "note": "Request forwarded to httpbin.org/get",
  "pathId": "$input.params('id')",
  "originalQueryString": {
    #foreach($param in $allParams.get('querystring').keySet())
      "$param": "$util.escapeJavaScript($allParams.get('querystring').get($param))"
      #if($foreach.hasNext),#end
    #end
  }
}
EOF
  }
}

resource "aws_api_gateway_method_response" "get_order_200" { ... }

resource "aws_api_gateway_integration_response" "get_order_200" {
  ...
  response_templates = {
    "application/json" = <<EOF
$input.body
EOF
  }

  depends_on = [
    aws_api_gateway_integration.get_order_integration,
    aws_api_gateway_method_response.get_order_200
  ]
}

```

### 4.5. Deployment & Stage
```hcl
resource "aws_api_gateway_deployment" "order_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id

  triggers = {
    redeploy = timestamp()
  }

  depends_on = [
    aws_api_gateway_integration.post_orders_integration,
    aws_api_gateway_integration.post_notify_integration,
    aws_api_gateway_integration.get_order_integration
  ]
}

```

### 4.6. Usage Plan & API Key
```hcl
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

```

### 4.7. Logging & Monitoring

IAM + Account:
```hcl
resource "aws_cloudwatch_log_group" "api_gw_access_logs" {
  name              = "/aws/apigateway/OrderServiceAPI-access"
  retention_in_days = 14
}

resource "aws_iam_role" "api_gw_cloudwatch_role" { ... }
resource "aws_iam_role_policy" "api_gw_cloudwatch_policy" { ... }

resource "aws_api_gateway_account" "account" {
  cloudwatch_role_arn = aws_iam_role.api_gw_cloudwatch_role.arn
}

```

Stage + access logs:

```hcl
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

  depends_on = [
    aws_api_gateway_account.account
  ]
}

```

Execution logs:

```hcl
resource "aws_api_gateway_method_settings" "all_methods_logging" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name

  method_path = "*/*"

  settings {
    metrics_enabled    = true
    logging_level      = "INFO"
    data_trace_enabled = true
  }
}

```
---

## 5. Test Cases

Sau khi terraform apply:
```bash
API_URL=$(terraform output -raw api_invoke_url)
API_KEY=$(terraform output -raw api_key_mobile)

```

### 5.1. POST /orders → Lambda
```bash
curl -X POST "$API_URL/orders" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "customer": { "id": "u-123", "name": "Alice" },
    "items": [
      { "sku": "SKU-1", "qty": 2 },
      { "sku": "SKU-2", "qty": 1 }
    ],
    "meta": { "source": "mobile", "campaign": "SPRING" }
  }'

```

### 5.2. POST /orders/{id}/notify → SNS
```bash
curl -X POST "$API_URL/orders/ord-123/notify" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "EMAIL",
    "to": "user@example.com"
  }'

```

### 5.3. GET /orders/{id} → httpbin.org
```bash
curl "$API_URL/orders/ord-999?fields=items,customer" \
  -H "x-api-key: $API_KEY"

```
---

## 6. Lý thuyết: Các khái niệm & options trong API Gateway

### 6.1. Loại API (REST, HTTP, WebSocket)

   - REST API (v1)  

      - Cũ hơn nhưng nhiều tính năng nâng cao.
      - Hỗ trợ mapping template, usage plan, API key, caching, request/response transformation, request validation, v.v.
      - Phù hợp với use case cần customize sâu – như LAB này.
        
   - HTTP API (v2)
     
      - Mới hơn, rẻ hơn, latency thấp hơn.
      - Thiết kế hiện đại, cấu hình đơn giản.
      - Tốt cho phần lớn use case mới: front cho Lambda/HTTP backend với JWT authorizer.
      - Ít tính năng hơn REST (ít hoặc không có usage plan, mapping phức tạp ở thời điểm đầu).
        
   - WebSocket API  

      - Hỗ trợ kết nối 2 chiều, lâu dài (stateful).
      - Dùng cho chat, game real-time, notification push, dashboard live, v.v.
        
Trong LAB, ta chọn REST API để demo: mapping template phức tạp, usage plan + API key, nhiều loại integration.

### 6.2. Resource, Method, Route

