output "mcp_endpoint" {
  description = "URL để cấu hình vào MCP client (transport: http)."
  value       = "${aws_apigatewayv2_api.mcp.api_endpoint}/mcp"
}

output "protected_resource_metadata_url" {
  description = "RFC 9728 metadata — mở bằng trình duyệt cũng được, route này public."
  value       = "${aws_apigatewayv2_api.mcp.api_endpoint}/.well-known/oauth-protected-resource"
}

output "cognito_token_endpoint" {
  description = "Nơi đổi client_id + client_secret lấy access token."
  value       = local.cognito_token_ep
}

output "cognito_client_id" {
  description = "App client ID (M2M)."
  value       = aws_cognito_user_pool_client.m2m.id
}

output "cognito_client_secret" {
  description = "App client secret (M2M). Đừng commit giá trị này."
  value       = aws_cognito_user_pool_client.m2m.client_secret
  sensitive   = true
}

output "oauth_scope" {
  description = "Scope phải xin khi lấy token."
  value       = local.required_scope
}

output "orders_table" {
  value = aws_dynamodb_table.orders.name
}

output "jobs_queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "next_steps" {
  description = "Copy nguyên khối này ra terminal để bắt đầu test."
  value       = <<-EOT

    # 1. Xuất biến môi trường
    export MCP_URL="${aws_apigatewayv2_api.mcp.api_endpoint}/mcp"
    export TOKEN_URL="${local.cognito_token_ep}"
    export CLIENT_ID="${aws_cognito_user_pool_client.m2m.id}"
    export CLIENT_SECRET="$(terraform output -raw cognito_client_secret)"
    export SCOPE="${local.required_scope}"

    # 2. Lấy access token (hết hạn sau 60 phút)
    export ACCESS_TOKEN=$(./scripts/get-token.sh)

    # 3. Chạy smoke test toàn bộ vòng đời MCP
    ./scripts/smoke-test.sh

  EOT
}
