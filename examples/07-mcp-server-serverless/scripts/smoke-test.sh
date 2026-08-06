#!/usr/bin/env bash
# Đi qua trọn vẹn một phiên MCP bằng curl, để bạn NHÌN THẤY từng message JSON-RPC.
#
#   export MCP_URL=...   ACCESS_TOKEN=$(./scripts/get-token.sh)
#   ./scripts/smoke-test.sh
set -euo pipefail

: "${MCP_URL:?Chưa set MCP_URL (terraform output mcp_endpoint)}"
AUTH_HEADER=()
if [[ -n "${ACCESS_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${ACCESS_TOKEN}")
fi

PROTOCOL_VERSION="2025-06-18"

pretty() { python3 -m json.tool 2>/dev/null || cat; }

rpc() {
  local label="$1" payload="$2"
  echo
  echo "=============================================================="
  echo ">>> $label"
  echo "--- request ---"
  printf '%s\n' "$payload" | pretty
  echo "--- response ---"
  curl -sS -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "MCP-Protocol-Version: ${PROTOCOL_VERSION}" \
    "${AUTH_HEADER[@]}" \
    -d "$payload" | pretty
}

# --- 0. Metadata công khai (không cần token) ---------------------------------
echo "=============================================================="
echo ">>> GET /.well-known/oauth-protected-resource  (public, RFC 9728)"
curl -sS "${MCP_URL%/mcp}/.well-known/oauth-protected-resource" | pretty

# --- 1. Handshake ------------------------------------------------------------
rpc "initialize — thoả thuận version + capabilities" '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "smoke-test", "version": "1.0.0"}
  }
}'

echo
echo ">>> notifications/initialized — server phải trả 202, body rỗng"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: ${PROTOCOL_VERSION}" \
  "${AUTH_HEADER[@]}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# --- 2. Khám phá -------------------------------------------------------------
rpc "tools/list — đây chính là thứ model đọc để chọn tool" \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

rpc "resources/list" '{"jsonrpc":"2.0","id":3,"method":"resources/list"}'

rpc "prompts/list" '{"jsonrpc":"2.0","id":4,"method":"prompts/list"}'

# --- 3. Gọi tool -------------------------------------------------------------
rpc "tools/call create_order — ghi dữ liệu, chạy async qua SQS" '{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "create_order",
    "arguments": {
      "customer_id": "cust-001",
      "items": [
        {"sku": "SKU-A", "qty": 2, "price": 19.99},
        {"sku": "SKU-B", "qty": 1, "price": 5.5}
      ]
    }
  }
}'

echo
echo ">>> Chờ 5s cho worker xử lý message trong SQS..."
sleep 5

rpc "tools/call list_orders — kiểm tra worker đã ghi chưa" '{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "tools/call",
  "params": {"name": "list_orders", "arguments": {"status": "NEW", "limit": 5}}
}'

rpc "resources/read orders://schema" '{
  "jsonrpc":"2.0","id":7,"method":"resources/read",
  "params":{"uri":"orders://schema"}
}'

# --- 4. Đường lỗi ------------------------------------------------------------
rpc "tools/call tool không tồn tại -> JSON-RPC error (lỗi PROTOCOL)" '{
  "jsonrpc":"2.0","id":8,"method":"tools/call",
  "params":{"name":"khong_ton_tai","arguments":{}}
}'

rpc "tools/call get_order với id không có -> result bình thường, found=false" '{
  "jsonrpc":"2.0","id":9,"method":"tools/call",
  "params":{"name":"get_order","arguments":{"order_id":"ord-khong-co-that"}}
}'

echo
echo "=============================================================="
echo "Xong. Hai kiểu lỗi ở bước 4 khác nhau có chủ đích:"
echo "  - Sai PROTOCOL (tool không tồn tại) -> JSON-RPC error, model không thấy."
echo "  - Sai NGHIỆP VỤ (không tìm thấy đơn) -> result thường, model đọc và tự xử lý."
