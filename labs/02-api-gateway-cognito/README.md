# Lab 02 – API Gateway REST + Cognito

REST API với 3 kiểu integration khác nhau, usage plan + API key, và Cognito JWT
authorizer.

Lý thuyết đầy đủ: [`docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md`](../../docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md)

## Ba kiểu integration

| Endpoint | Integration | Bảo vệ bằng |
|----------|-------------|-------------|
| `POST /orders` | Lambda non-proxy + mapping template VTL | API key |
| `POST /orders/{id}/notify` | AWS service → SNS Publish | API key |
| `GET /orders/{id}` | HTTP backend (httpbin.org) | API key + Cognito JWT |

## Deploy

```bash
terraform init
terraform apply
```

> **Lưu ý:** `aws_api_gateway_account` là cấu hình cấp **account + region**,
> không phải cấp API. Nếu account của bạn đã có CloudWatch role cho API
> Gateway, apply lab này sẽ ghi đè lên nó. Trên account production, hãy comment
> resource đó lại.

## Test

```bash
API_URL=$(terraform output -raw api_invoke_url)
API_KEY=$(terraform output -raw api_key_mobile)
```

### POST /orders → Lambda

```bash
curl -X POST "$API_URL/orders" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "customer": { "id": "u-123", "name": "Alice" },
    "items": [{ "sku": "SKU-1", "qty": 2 }, { "sku": "SKU-2", "qty": 1 }],
    "meta": { "source": "mobile", "campaign": "SPRING" }
  }'
```

Quan sát mapping template đã biến đổi payload: `customer.id` → `customerId`,
`qty` → `quantity`, thêm `orderId` từ `$context.requestId`.

### POST /orders/{id}/notify → SNS

```bash
# Subscribe email trước để thấy message (nhớ confirm trong hộp thư)
aws sns subscribe \
  --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --protocol email \
  --notification-endpoint you@example.com

curl -X POST "$API_URL/orders/ord-123/notify" \
  -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"type":"EMAIL","to":"user@example.com"}'
# -> {"message": "Notification queued"}
```

### GET /orders/{id} → cần JWT

```bash
# 1. Mở Hosted UI, đăng ký tài khoản rồi đăng nhập
terraform output -raw cognito_hosted_ui_url

# 2. Sau khi login, browser redirect về
#    http://localhost:3000/callback?code=XXXX  (trang sẽ lỗi, không sao)
#    Copy giá trị code
CODE="XXXX"

# 3. Đổi code lấy token
ID_TOKEN=$(curl -s -X POST \
  "https://$(terraform output -raw cognito_domain)/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "client_id=$(terraform output -raw cognito_client_id)" \
  -d "code=$CODE" \
  -d "redirect_uri=http://localhost:3000/callback" | jq -r .id_token)

# 4. Gọi API
curl "$API_URL/orders/ord-999?fields=items" \
  -H "x-api-key: $API_KEY" \
  -H "Authorization: $ID_TOKEN"
```

Kiểm tra từng lớp bảo vệ:

| Bỏ đi | Kết quả |
|-------|---------|
| `x-api-key` | `403 Forbidden` |
| `Authorization` | `401 Unauthorized` |
| Cả hai | `401 Unauthorized` |

> Cognito authorizer mặc định nhận token **không có** tiền tố `Bearer `.

## Dọn dẹp

```bash
terraform destroy
```

Cognito user pool domain phải unique toàn cầu; lab dùng suffix ngẫu nhiên nên
destroy rồi apply lại sẽ tạo domain khác.

## Chi phí

Free tier phủ hết. Cognito free tier 50.000 MAU. Không có tài nguyên tính tiền
theo giờ.
