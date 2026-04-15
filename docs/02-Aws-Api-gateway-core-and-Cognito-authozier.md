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


- Resource (REST API)  

   - Đại diện cho một path trong URL, ví dụ:
      - /orders
      - /orders/{id}
      - /orders/{id}/notify
   - Trong Terraform: aws_api_gateway_resource.
     
- Method (REST API)  

   - HTTP method trên một resource:
      - GET /orders/{id}
      - POST /orders
      - POST /orders/{id}/notify
   - Trong Terraform: aws_api_gateway_method.
   - Option chính:
      - http_method: GET, POST, PUT, DELETE,…
      - authorization: NONE, AWS_IAM, CUSTOM, COGNITO_USER_POOLS.
      - api_key_required: true/false (có yêu cầu API key hay không).
      - request_parameters: định nghĩa query/path/header param cần có.
        
- Route (HTTP & WebSocket APIs)  

   - Khái niệm tương tự trong HTTP API/WebSocket:
      - HTTP APIs: GET /orders/{id} là một route.
      - WebSocket APIs: $connect, $disconnect, $default, custom routes.
        
Trong LAB:  

- Ta sử dụng REST Resource + Method:
   - Resource: /orders, /orders/{id}, /orders/{id}/notify.
   - Method: POST, GET với các options auth, api_key_required.

### 6.3. Integration types

Integration là cách API Gateway “nối” đến backend:

#### 1. Lambda Integration  

   - API Gateway gọi AWS Lambda.
   - 2 kiểu:
      - Lambda proxy (event = full request context).
      - Lambda non-proxy (dùng mapping template như LAB).
   - LAB: POST /orders → non-proxy Lambda để demo mapping template.
     
#### 2. HTTP / HTTP Proxy Integration  

   - Gọi đến HTTP/HTTPS backend:
      - Internal service, public API, microservice, v.v.
   - HTTP proxy integration:
      - Pass-through hầu hết request/response.
   - Non-proxy:
      - Tùy biến header, query, body bằng mapping template & request parameters.
   - LAB: GET /orders/{id} → HTTP integration đến https://httpbin.org/get.
     
#### 3. AWS Service Integration  

   - Gọi trực tiếp AWS services không cần Lambda:
      - SNS (Publish), SQS (SendMessage), DynamoDB (GetItem/PutItem), Step Functions (StartExecution), v.v.
   - Cần IAM role (credentials) cho phép API Gateway gọi service đó.
   - LAB: POST /orders/{id}/notify → SNS Publish.
     
#### 4. MOCK Integration  

   - Không gọi backend.
   - API Gateway trả response giả theo mapping template.
   - Dùng để test, stub, health check, hoặc quick demo.

### 6.4. Mapping Templates (VTL)

Mapping Template cho phép:

   - Biến đổi Request trước khi gửi đến backend.
   - Biến đổi Response từ backend trước khi trả cho client.
     
Sử dụng:

   - REST API → request_templates, response_templates.
   - Ngôn ngữ: Velocity Template Language (VTL).
     
Trong LAB:

   - Request mapping POST /orders:
        - Client gửi:
```json
     {
     "customer": { "id": "u-123", "name": "Alice" },
     "items": [
       { "sku": "SKU-1", "qty": 2 },
       { "sku": "SKU-2", "qty": 1 }
     ],
     "meta": { "source": "mobile", "campaign": "SPRING" }
   }

```

     - Mapping template tạo payload cho Lambda:
```json
     {
     "orderId": "<requestId>",
     "customerId": "u-123",
     "items": [
       { "sku": "SKU-1", "quantity": 2 },
       { "sku": "SKU-2", "quantity": 1 }
     ],
     "source": "mobile",
     "campaign": "SPRING",
     "requestContext": { ... }
   }
```
     
   - Response mapping POST /orders:

      - Lambda trả:
```json
   {
     "ok": true,
     "order": { "id": "ord-xxx", "total": 199.5 },
     "debug": { "received": {...} }
   }

```
   - Template trả cho client:
```json
{
  "orderId": "ord-xxx",
  "total": 199.5,
  "status": "CREATED",
  "debug": { ... }
}

```

- **Request mapping POST /orders/{id}/notify:**

   - Input: { "type": "EMAIL", "to": "user@example.com" }.

   - Output cho SNS Publish:
```json
{
  "TopicArn": "...",
  "Message": "{\"orderId\": \"ord-123\", ... }"
}

```

**Option quan trọng:**

   - $input.path('$'), $input.json('$') – truy cập body JSON.
   - $context.* – truy cập thông tin request (requestId, stage, identity, headers,…).
   - $util.toJson, $util.escapeJavaScript – format JSON string cho các service như SNS.


### 6.5. Usage Plan & API Key

**API Key:**

   - Chuỗi bí mật client gửi trong header x-api-key (hoặc query).
   - Không thay thế JWT/OAuth – chủ yếu để:
      - Kiểm soát sử dụng (usage tracking).
      - Giới hạn rate/quota.
      - Gate-keeping đơn giản cho các client trusted.
        
**Usage Plan:**

   - Gắn API key với:
      - Một hoặc nhiều API/stage.
        
   - Thiết lập:
      - Throttling (burst/rate).
      - Quota (tổng request trong chu kỳ).
        
   - Giúp:
      - Phân tầng khách hàng: Free / Pro / Enterprise.
      - Chia băng thông, bảo vệ backend.
        
Trong LAB:

   - MobilePlan:
      - rate_limit = 100 req/s, burst_limit = 200.
      - quota = 100000 req/ngày.
   - mobile-app-key gắn vào MobilePlan.
   - Tất cả method (POST /orders, POST /orders/{id}/notify, GET /orders/{id}) đều api_key_required = true.


### 6.6. Bảo mật (Authorization & Authentication)

Các option chính của API Gateway:

   1. IAM Authorization (AWS_IAM)  

      - Dùng SigV4 signing.
      - Phù hợp cho client là AWS service (Lambda, EC2, backend internal).
      - Policy IAM kiểm soát ai được gọi method nào.
        
   2. Lambda Authorizer (Custom Authorizer)  

      - Lambda tự viết, xử lý:
         - JWT từ IdP custom.
         - API token, header, cookie, v.v.
      - Trả về IAM policy cho phép/từ chối truy cập.
      - Flexibile, nhưng phải tự maintain code Lambda.
        
   3. Cognito User Pools Authorizer  

      - API Gateway validate JWT token phát hành bởi Amazon Cognito.
      - Tích hợp tốt với mobile/web app.
      - Đỡ phải tự viết logic validate token.
        
   4. API Key + Usage Plan (đang dùng trong LAB)  

      - Không phải auth mạnh (không biết user cuối là ai).
      - Phù hợp:
         - Throttle & quota.
         - Quy định “chỉ những client nào được cấp key mới dùng API”.
      - Nên kết hợp thêm: IAM/Lambda/Cognito authorizer cho security production.
        
Trong LAB:

   - Dùng authorization = "NONE" + api_key_required = true.
   - Bảo mật ở mức:
      - Chỉ client có API key mới gọi được.
      - Có rate/quota để tránh abuse.


### 6.7. Logging, Monitoring & Observability

**Logging**:

   - Access Logs:

      - Log ở level stage, mỗi request 1 dòng (JSON).
      - Chứa:
         - IP, method, path, status, latency, requestId, errors, v.v.
      - Trong LAB:
         - Log group: /aws/apigateway/OrderServiceAPI-access.
         - Format JSON tùy biến.
           
**Execution Logs**:

   - Log chi tiết per-method trong API Gateway.
   - Gồm:
      - Request mapping, integration, response, error từ integration, v.v.
   - Bật qua aws_api_gateway_method_settings:
      - logging_level: OFF | ERROR | INFO.
      - data_trace_enabled: true/false (log full body – cẩn thận với dữ liệu nhạy cảm).
        
**Lambda Logs**:

   - Mặc định Lambda log ra CloudWatch log group:
      - /aws/lambda/<function_name>.
        
**Monitoring (Metrics)**:

   - API Gateway:
      - Count, 4XXError, 5XXError, Latency, IntegrationLatency, CacheHit/MissCount,…
   - Lambda:
      - Invocations, Errors, Duration, Throttles, v.v.
   - SNS:
      - NumberOfMessagesPublished, NumberOfNotificationsDelivered,…
        
Trong thực tế:

   - Kết hợp metrics + logs:
      - Alarms (CloudWatch Alarms) khi:
         - 5XX tăng cao.
         - Latency tăng bất thường.
         - Throttling nhiều.
      - Dashboards để quan sát traffic theo thời gian.

### 6.8. Throttling & Quota

**Throttling**:

   - Bảo vệ backend khỏi bị “ngập” request.
   - 2 cấp:
      - Account-level throttling (mặc định trên toàn bộ API Gateway account).
      - Usage Plan throttling:
         - rate_limit (requests/second trung bình).
         - burst_limit (burst tối đa trong thời gian ngắn).
   - Nếu vượt limit:
      - API Gateway trả 429 Too Many Requests.
        
**Quota**:

   - Giới hạn tổng số request trong một chu kỳ:
      - limit: số lượng request.
      - period: DAY | WEEK | MONTH.
      - offset: offset tính chu kỳ.
   - Nếu client vượt quota:
      - API Gateway từ chối request đến khi chu kỳ mới bắt đầu.
        
Trong LAB:

   - MobilePlan:
      - rate_limit = 100, burst_limit = 200.
      - limit = 100000 / DAY.


### 6.9. Caching (REST API)

_"LAB này chưa bật cache, nhưng đây là feature quan trọng của REST API."_

- **API Gateway Cache:**

   - Cho phép cache response ở level method.
   - Giảm số lần gọi backend, giảm latency.
   - Có cost riêng (GB/hour).
- Config chính:
   - Bật cache trên Stage hoặc Method:
      - caching_enabled = true.
      - cache_ttl_in_seconds.
   - Xác định key:
      - Query params, headers, request body (tùy chọn).
- Use case:
   - GET dữ liệu ít thay đổi.
   - Public data có thể cache (product list, metadata, v.v.).

---

## 7. Monitoring & Logging trong thực tế

Thực hành tốt (best practices):

   - Bật Access Logs:

      - Sử dụng format JSON để dễ filter & phân tích.
      - Dùng trường như requestId, status, integrationError, ip, userAgent.
        
   - Bật Execution Logs có chọn lọc:

      - Môi trường dev/stage: logging_level = INFO, data_trace_enabled = true để debug.
      - Prod: logging_level = ERROR, tắt data_trace hoặc chỉ bật cho một số method vì lý do bảo mật & chi phí.
        
   - Đặt Alarms:

      - 5XX tăng → có vấn đề backend.
      - 4XX tăng → client dùng sai / invalid auth / vượt quota.
      - Latency tăng → hiệu năng backend kém.
        
   - Trace:

      - Có thể bật AWS X-Ray để trace end-to-end qua API Gateway → Lambda → backend khác.
---

## 8. Bảo mật trong thực tế

Một số patterns:

   - Public API:
      - Tối thiểu: API key + usage plan → rate/quota.
      - Tốt hơn: JWT (Cognito) + API key (cho billing/usage).
   - Internal API (microservices):
      - AWS_IAM (SigV4) + VPC, private endpoint.
   - B2B / Partner API:
      - OAuth2/JWT/Lambda Authorizer.
      - Mỗi partner một usage plan + API key riêng.
        
Các điểm cần chú ý:

   - Không log thông tin nhạy cảm (PII, secrets) trong CloudWatch (data_trace).
   - Rotate API key định kỳ.
   - Hạn chế IP (nếu phù hợp) bằng WAF + resource policy.

---

## 9. Hướng mở rộng LAB

Một số hướng bạn có thể phát triển thêm:

   1. Thêm Auth:

      - Cognito User Pools + JWT authorizer.
      - Hoặc Lambda authorizer đơn giản.
        
   2. Thêm CORS:

      - Cho phép frontend SPA (React/Vue/Angular) gọi API.

   3. Thêm DynamoDB integration:

      - GET /orders/{id} đọc thẳng từ DynamoDB (AWS Service integration).
      - Không cần Lambda cho read.
        
   4. Custom Domain + ACM:

      - Gắn domain đẹp: https://api.example.com/orders.
        
   5. CI/CD:

      - Dùng GitHub Actions / CodePipeline để apply Terraform.
     
---

# Phần mở rộng: Cognito – Authentication & Security (Lý thuyết)

Phần này bổ sung **kiến thức lý thuyết** về Authentication & Security của **Amazon Cognito**, để bạn ghép chung với tài liệu LAB API Gateway/Cognito.

---

## 10. Lý thuyết: Cognito Authentication vs Security

### 10.1. Cognito giải quyết vấn đề gì?

Amazon Cognito có 2 “mảng” lớn:

1. **User Pools** – Authentication & Identity  
   - Đăng ký, đăng nhập, quản lý user (email/username/password, social login).
   - Phát hành **JWT token** (ID token, Access token, Refresh token).
   - Là nguồn “sự thật” về user (identity store) cho ứng dụng.

2. **Federation / Identity Pools (không dùng trong LAB)**  
   - Map user đã xác thực (qua Cognito hoặc IdP khác) thành **AWS credentials tạm thời** (STS) để gọi trực tiếp các dịch vụ AWS (S3, DynamoDB,…).
   - Không chi tiết ở đây vì LAB tập trung vào User Pools + API Gateway.

Trong LAB của bạn, chúng ta dùng **User Pool** để làm:

- Authentication: xác thực user login.
- Security ở mức API: cấp JWT token, dùng ở API Gateway.

---

### 10.2. Authentication trong Cognito (User Pools)

**Authentication = khẳng định user là ai.**

Cognito User Pool hỗ trợ:

1. **User/Password** truyền thống:
   - Đăng ký (sign-up): email/username + password.
   - Xác thực email (optional).
   - Đăng nhập (sign-in): email/username + password.

2. **Password policy**:
   - Độ dài tối thiểu.
   - Bắt buộc có số, chữ hoa, chữ thường, ký tự đặc biệt.
   - Expiration (nếu cần).

3. **MFA (Multi-Factor Authentication)** (tùy chọn):
   - SMS OTP, TOTP (Google Authenticator, Authy,…).
   - Có thể buộc tất cả user dùng MFA hoặc chỉ bắt buộc trong trường hợp rủi ro cao.

4. **Social login / Enterprise SSO**:
   - OIDC: Google, Auth0, Keycloak, v.v.
   - SAML: IdP công ty, ADFS, Okta.
   - Cognito sẽ federate các IdP này vào 1 User Pool.

5. **Hosted UI**:
   - Cung cấp sẵn trang login/sign-up/forgot password.
   - Hỗ trợ cả social login/SSO.
   - Có thể custom logo, màu sắc, text, và gắn custom domain (`auth.company.com`).

6. **Token-based Authentication**:
   - Sau khi login thành công, Cognito phát hành:
     - `id_token`: chứa thông tin user (claims).
     - `access_token`: dùng để bảo vệ API.
     - `refresh_token`: dùng để lấy token mới mà không login lại.

**Trong LAB**:
- Bạn dùng Hosted UI (classic) + username/password.
- Sau login, Cognito trả `id_token` + `access_token` trên URL (implicit flow).
- Bạn lấy JWT từ URL và dùng để gọi API Gateway.

---

### 10.3. JWT Tokens của Cognito & cách dùng

Cognito phát hành 3 loại token (OIDC compliant):

1. **ID Token**:
   - Dành cho client/front-end.
   - Chứa profile user:
     - `sub`, `email`, `email_verified`, `cognito:username`, custom claims.
   - Dùng khi bạn muốn app biết “user này là ai”.

2. **Access Token**:
   - Dùng để bảo vệ API/backends.
   - Chứa:
     - Scope (permissions).
     - Client ID, username, groups,…
   - Khi gửi đến API Gateway, thường dùng format:
     - `Authorization: Bearer <access_token>` (hoặc `id_token` trong 1 số flow).

3. **Refresh Token**:
   - Dùng để **lấy token mới** mà không cần user login lại.
   - Không nên gửi refresh token qua API Gateway; chỉ dùng giữa client ↔ Cognito.

**Đặc điểm chung của JWT Cognito**:

- Ký bằng RSA (`RS256`) với key riêng của User Pool.
- Có tiêu chuẩn:
  - `iss` – issuer (URL của User Pool).
  - `aud` – audience (client_id).
  - `exp` – thời điểm hết hạn.
- Verifiable bằng public keys (`JWKS`) tại:
  - `https://cognito-idp.<region>.amazonaws.com/<user_pool_id>/.well-known/jwks.json`

**Trong LAB**:

- Bạn lấy token từ Hosted UI, gắn vào header:
  - `Authorization: Bearer <id_token>` (demo).
- API Gateway (qua Cognito authorizer hoặc Lambda authorizer) validate token trước khi cho phép vào API.

---

### 10.4. Security trong Cognito – Chính sách & bảo vệ tài khoản

Cognito hỗ trợ nhiều feature “security” xoay quanh user:

1. **Password Policy** (đã dùng):
   - Độ mạnh, pattern password.
   - Giảm nguy cơ bị brute force / password yếu.

2. **MFA**:
   - Yêu cầu user nhập thêm OTP (SMS, TOTP).
   - Bảo vệ chống stolen password.

3. **Account Status & Lockout**:
   - Bạn có thể:
     - Disable user.
     - Force password reset.
   - Kết hợp với app logic để lock user khi bị nghi ngờ tấn công.

4. **Advanced Security / Adaptive Authentication** (nếu bật, có phí):
   - Phân tích hành vi đăng nhập:
     - Địa điểm mới / thiết bị lạ.
     - Nhiều lần login fail, login lạ.
   - Phân loại: low / medium / high risk.
   - Tùy policy:
     - Allow, require MFA, hoặc Deny login.
   - Đây là “threat protection” ở mức **tài khoản**.

---

### 10.5. Cognito + API Gateway trong Security tổng thể

Cognito tự nó **không chặn các kiểu tấn công HTTP** (SQLi, XSS, DDoS nhỏ,...); phần đó thuộc về:

- **AWS WAF** (Web Application Firewall)  
- **API Gateway features** (throttling, resource policy, usage plan)

Tuy nhiên, Cognito là mảnh ghép quan trọng trong **API security**:

1. **Authentication**:  
   - User login → nhận JWT.

2. **Authorization ở API layer (bảo vệ API)**:
   - **Cognito Authorizer**:
     - API Gateway tự validate JWT.
   - **Lambda Authorizer** (nếu bạn tự code):
     - Tự validate JWT & thêm logic role/permission.

3. **Kết hợp**:
   - JWT (Cognito) + API Key (Usage Plan):
     - JWT = biết “user là ai”.
     - API key = phân biệt “client/app nào” + rate/quota.
   - JWT + WAF:
     - WAF chặn bot/tấn công HTTP trước khi đụng đến Cognito/API.
   - JWT + backend:
     - Backend (Lambda / HTTP services) có thể đọc claims từ JWT (email, groups, custom:role,…) để phân quyền sâu hơn.

**Trong LAB**:

- JWT Cognito + API Key bắt buộc cho `GET /orders/{id}`.
- Bạn có thể mở rộng:
  - Backend đọc `email`, `cognito:username` từ JWT để log/audit.
  - Chỉ cho phép `role=admin` gọi một số endpoint.

---

### 10.6. Khi nào dùng Cognito authorizer, khi nào dùng Lambda authorizer?

**Cognito authorizer**:

- Ưu:
  - Không phải viết code validate JWT.
  - Cấu hình đơn giản.
  - An toàn, chuẩn AWS.
- Nhược:
  - Logic cố định (chủ yếu chỉ check signature/iss/aud/exp).
  - Khó kết hợp với hệ thống role/DB custom phức tạp.

**Lambda authorizer (trên JWT Cognito)**:

- Ưu:
  - Toàn quyền viết logic:
    - Chỉ cho phép email `@company.com`.
    - Check user trong DB nội bộ (trạng thái active/banned).
    - Áp chính sách tuỳ tenant / organization.
  - Có thể validate token từ nhiều nguồn (Cognito + IdP khác).
- Nhược:
  - Phải tự code và bảo trì.
  - Nếu code sai phần security, có thể tạo lỗ hổng.

**Chiến lược thực tế**:

- 80% use case: **Cognito User Pool + Cognito authorizer** là đủ.
- Khi cần rule đặc biệt hoặc multi-IdP phức tạp:
  - Chuyển sang **Lambda authorizer** (nhưng vẫn dùng Cognito làm IdP).

---

### 10.7. Tóm tắt: Authentication vs Security trong Cognito (theo LAB)

- **Authentication (Cognito)**:
  - Ai đang login?  
  - Xác thực user bằng password, MFA, social login.  
  - Phát hành JWT chuẩn (ID/Access/Refresh token).

- **Security (Cognito + API Gateway + WAF)**:
  - Cognito:
    - Chính sách password, MFA, adaptive authentication.
    - Bảo vệ từng user account.
  - API Gateway:
    - Cognito/Lambda authorizer – validate JWT, allow/deny API.
    - Usage Plan + API key – rate/quota & client-level control.
  - WAF (optional, ngoài LAB):
    - Chặn bot, SQLi, XSS, brute force HTTP trước khi vào API.

Trong LAB OrderServiceAPI, bạn đã ghép:

- Cognito User Pool → Hosted UI → JWT.  
- JWT → API Gateway Cognito/Lambda authorizer → bảo vệ `GET /orders/{id}`.  
- JWT + API Key → security ở cả **user** và **client/app**.

---

