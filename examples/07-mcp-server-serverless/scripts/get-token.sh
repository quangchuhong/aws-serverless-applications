#!/usr/bin/env bash
# Đổi client_id + client_secret lấy access token qua OAuth 2.0 client_credentials.
# In ra stdout đúng token, để dùng được: export ACCESS_TOKEN=$(./scripts/get-token.sh)
set -euo pipefail

: "${TOKEN_URL:?Chưa set TOKEN_URL (xem: terraform output cognito_token_endpoint)}"
: "${CLIENT_ID:?Chưa set CLIENT_ID}"
: "${CLIENT_SECRET:?Chưa set CLIENT_SECRET (terraform output -raw cognito_client_secret)}"
: "${SCOPE:?Chưa set SCOPE (terraform output oauth_scope)}"

response=$(curl -sS -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  -d "grant_type=client_credentials" \
  --data-urlencode "scope=${SCOPE}")

token=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')

if [[ -z "$token" ]]; then
  echo "Lấy token thất bại. Cognito trả về:" >&2
  printf '%s\n' "$response" >&2
  exit 1
fi

printf '%s' "$token"
