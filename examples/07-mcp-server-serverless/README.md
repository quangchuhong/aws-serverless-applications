# MCP Server trên AWS Serverless — Lab deploy được

Kèm theo `docs/07-MCP-tren-AWS-Serverless-Hands-on.md`.

Một MCP server thật, chạy trên **API Gateway HTTP API + Lambda + DynamoDB + SQS**,
bảo vệ bằng **Cognito OAuth 2.0 (client_credentials)**.

## Yêu cầu

- Terraform >= 1.5
- AWS CLI đã cấu hình credential (`aws sts get-caller-identity` chạy được)
- `python3`, `curl`
- (tuỳ chọn) Node.js để chạy MCP Inspector

## Cấu trúc

```text
examples/07-mcp-server-serverless/
├── main.tf / variables.tf / outputs.tf / versions.tf
├── lambda/
│   ├── mcp_server.py     # MCP server: JSON-RPC 2.0 viết tay, Streamable HTTP
│   └── job_worker.py     # consumer SQS cho tool chạy lâu
├── local/
│   ├── stdio_server.py   # LAB 1: MCP server local qua stdio, bọc boto3
│   └── requirements.txt
└── scripts/
    ├── get-token.sh      # lấy access token từ Cognito
    └── smoke-test.sh     # đi hết một phiên MCP bằng curl
```

## Lab 1 — Chạy local trước (5 phút, không deploy gì)

```bash
cd local
pip install -r requirements.txt
npx @modelcontextprotocol/inspector python stdio_server.py
```

Mở Inspector trong trình duyệt → tab **Tools** → **List Tools** → gọi thử
`list_s3_buckets`. Bạn sẽ thấy đúng cặp `tools/list` / `tools/call` đi qua dây.

Dùng một AWS profile **read-only** khi chạy lab này.

## Lab 2-4 — Deploy remote server

```bash
terraform init
terraform apply

# In ra khối lệnh sẵn sàng copy
terraform output next_steps
```

Sau đó:

```bash
export MCP_URL=$(terraform output -raw mcp_endpoint)
export TOKEN_URL=$(terraform output -raw cognito_token_endpoint)
export CLIENT_ID=$(terraform output -raw cognito_client_id)
export CLIENT_SECRET=$(terraform output -raw cognito_client_secret)
export SCOPE=$(terraform output -raw oauth_scope)

chmod +x scripts/*.sh
export ACCESS_TOKEN=$(./scripts/get-token.sh)
./scripts/smoke-test.sh
```

`smoke-test.sh` in ra cả request lẫn response của từng bước: `initialize` →
`notifications/initialized` → `tools/list` → `tools/call` → hai kiểu lỗi khác nhau.

### Kiểm tra auth có thật sự chặn không

```bash
curl -i -X POST "$MCP_URL" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
# -> HTTP/2 401
```

## Gắn vào MCP client

Tạo `.mcp.json` ở thư mục project:

```json
{
  "mcpServers": {
    "aws-orders": {
      "type": "http",
      "url": "https://XXXX.execute-api.ap-southeast-1.amazonaws.com/mcp",
      "headers": { "Authorization": "Bearer <ACCESS_TOKEN>" }
    }
  }
}
```

Token M2M hết hạn sau 60 phút — với client tương tác thật thì cần một
Authorization Server hỗ trợ Dynamic Client Registration (Cognito **không** hỗ
trợ RFC 7591). Xem mục "Giới hạn" trong doc `07`.

## Dọn dẹp

```bash
terraform destroy
```

## Chi phí

Toàn bộ lab dùng PAY_PER_REQUEST / on-demand. Chạy vài chục request để học thì
chi phí gần như bằng 0; khoản đáng kể duy nhất là **Cognito M2M tính phí theo
số token request** — script chỉ lấy 1 token cho mỗi 60 phút. Nhớ `terraform destroy`.
