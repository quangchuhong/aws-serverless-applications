"""MCP server (Streamable HTTP, stateless) chạy trên AWS Lambda + API Gateway HTTP API.

Ở đây JSON-RPC 2.0 được implement thủ công (không dùng SDK) để bạn nhìn thấy
chính xác từng message đi qua dây. Khi đã hiểu, hãy chuyển sang SDK chính thức
cho code production.

Endpoint:
    POST /mcp                                    -> JSON-RPC (cần Bearer token)
    GET  /mcp                                    -> 405 (server stateless, không mở SSE stream)
    GET  /.well-known/oauth-protected-resource   -> RFC 9728 metadata (public)

Vì sao stateless: Lambda có thể bị recycle bất cứ lúc nào, nên server không giữ
session trong bộ nhớ. Spec cho phép: `Mcp-Session-Id` là OPTIONAL.
"""

import json
import logging
import os
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Khởi tạo client ở scope module -> tái sử dụng giữa các invocation, giảm cold start.
_ddb = boto3.resource("dynamodb")
_sqs = boto3.client("sqs")
_logs = boto3.client("logs")

ORDERS_TABLE = os.environ["ORDERS_TABLE"]
JOBS_TABLE = os.environ["JOBS_TABLE"]
QUEUE_URL = os.environ["QUEUE_URL"]
COGNITO_ISSUER = os.environ.get("COGNITO_ISSUER", "")
REQUIRED_SCOPE = os.environ.get("REQUIRED_SCOPE", "")

SERVER_NAME = "aws-orders-mcp"
SERVER_VERSION = "1.0.0"

# Các revision spec server này hiểu. Phần tử đầu là mặc định/mới nhất.
SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

orders = _ddb.Table(ORDERS_TABLE)
jobs = _ddb.Table(JOBS_TABLE)


# --------------------------------------------------------------------------
# Tiện ích
# --------------------------------------------------------------------------


class DecimalEncoder(json.JSONEncoder):
    """DynamoDB trả số dưới dạng Decimal -> json.dumps không serialize được."""

    def default(self, o):
        if isinstance(o, Decimal):
            return int(o) if o % 1 == 0 else float(o)
        return super().default(o)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _http(status: int, body=None, headers=None):
    """Dựng response cho API Gateway HTTP API payload v2.0."""
    resp = {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **(headers or {})},
    }
    if body is not None:
        resp["body"] = json.dumps(body, cls=DecimalEncoder)
    else:
        resp["body"] = ""
    return resp


def _rpc_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _rpc_error(req_id, code: int, message: str, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": req_id, "error": err}


# JSON-RPC error codes chuẩn
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


# --------------------------------------------------------------------------
# Tool registry
# --------------------------------------------------------------------------

TOOLS: dict = {}


def tool(name: str, title: str, description: str, input_schema: dict, read_only: bool = True):
    """Đăng ký một tool.

    LƯU Ý QUAN TRỌNG: `description` và `input_schema` chính là prompt mà model đọc
    để quyết định gọi tool nào với tham số gì. Viết mô tả mơ hồ = model gọi sai.
    """

    def decorator(fn):
        TOOLS[name] = {
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": input_schema,
            "annotations": {
                "title": title,
                "readOnlyHint": read_only,
                "destructiveHint": False,
                "idempotentHint": read_only,
                "openWorldHint": False,
            },
            "handler": fn,
        }
        return fn

    return decorator


@tool(
    name="get_order",
    title="Lấy chi tiết một order",
    description=(
        "Lấy toàn bộ thông tin của MỘT order theo orderId chính xác. "
        "Dùng khi người dùng đã cung cấp mã đơn hàng. "
        "Nếu chỉ biết trạng thái hoặc muốn xem nhiều đơn, dùng list_orders thay vì tool này."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "order_id": {
                "type": "string",
                "description": "Mã đơn hàng, ví dụ 'ord-8f3a2b1c'.",
            }
        },
        "required": ["order_id"],
        "additionalProperties": False,
    },
)
def get_order(order_id: str):
    item = orders.get_item(Key={"orderId": order_id}).get("Item")
    if not item:
        return {"found": False, "orderId": order_id}
    return {"found": True, **item}


@tool(
    name="list_orders",
    title="Liệt kê order",
    description=(
        "Liệt kê các order, có thể lọc theo trạng thái. "
        "Trả về tối đa `limit` đơn, mới nhất trước. "
        "Trạng thái hợp lệ: NEW, PAID, SHIPPED, CANCELLED."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "status": {
                "type": "string",
                "enum": ["NEW", "PAID", "SHIPPED", "CANCELLED"],
                "description": "Lọc theo trạng thái. Bỏ trống để lấy tất cả.",
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 50,
                "default": 10,
                "description": "Số order tối đa trả về.",
            },
        },
        "additionalProperties": False,
    },
)
def list_orders(status: str = None, limit: int = 10):
    limit = max(1, min(int(limit or 10), 50))
    if status:
        resp = orders.query(
            IndexName="status-createdAt-index",
            KeyConditionExpression=Key("status").eq(status),
            ScanIndexForward=False,  # mới nhất trước
            Limit=limit,
        )
    else:
        # Scan chỉ chấp nhận được vì đây là bảng demo nhỏ.
        # Bảng thật: luôn dùng Query trên GSI.
        resp = orders.scan(Limit=limit)
    items = resp.get("Items", [])
    return {"count": len(items), "orders": items}


@tool(
    name="create_order",
    title="Tạo order (bất đồng bộ)",
    description=(
        "Tạo một order mới. Đây là thao tác GHI DỮ LIỆU và chạy bất đồng bộ: "
        "tool trả về ngay một jobId, việc ghi thật diễn ra ở worker phía sau. "
        "Sau khi gọi, dùng get_job_status với jobId để kiểm tra kết quả. "
        "Luôn xác nhận với người dùng trước khi gọi tool này."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "customer_id": {"type": "string", "description": "Mã khách hàng."},
            "items": {
                "type": "array",
                "minItems": 1,
                "description": "Danh sách sản phẩm trong đơn.",
                "items": {
                    "type": "object",
                    "properties": {
                        "sku": {"type": "string"},
                        "qty": {"type": "integer", "minimum": 1},
                        "price": {"type": "number", "minimum": 0},
                    },
                    "required": ["sku", "qty"],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["customer_id", "items"],
        "additionalProperties": False,
    },
    read_only=False,
)
def create_order(customer_id: str, items: list):
    job_id = f"job-{uuid.uuid4().hex[:12]}"
    order_id = f"ord-{uuid.uuid4().hex[:8]}"

    jobs.put_item(
        Item={
            "jobId": job_id,
            "status": "PENDING",
            "orderId": order_id,
            "createdAt": _now_iso(),
            # TTL: job tự dọn sau 24h, khỏi phải viết job cleanup.
            "expiresAt": int(time.time()) + 24 * 3600,
        }
    )

    _sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(
            {
                "jobId": job_id,
                "orderId": order_id,
                "customerId": customer_id,
                "items": items,
            }
        ),
    )

    return {
        "jobId": job_id,
        "orderId": order_id,
        "status": "PENDING",
        "hint": "Gọi get_job_status với jobId này để xem kết quả.",
    }


@tool(
    name="get_job_status",
    title="Kiểm tra trạng thái job",
    description=(
        "Kiểm tra kết quả của một thao tác bất đồng bộ đã submit trước đó (ví dụ create_order). "
        "Trạng thái: PENDING (đang chờ), DONE (thành công), FAILED (lỗi)."
    ),
    input_schema={
        "type": "object",
        "properties": {"job_id": {"type": "string", "description": "jobId nhận được khi submit."}},
        "required": ["job_id"],
        "additionalProperties": False,
    },
)
def get_job_status(job_id: str):
    item = jobs.get_item(Key={"jobId": job_id}).get("Item")
    if not item:
        return {"found": False, "jobId": job_id}
    return {"found": True, **item}


@tool(
    name="tail_lambda_logs",
    title="Đọc log Lambda gần đây",
    description=(
        "Đọc các dòng log gần đây của một Lambda function trong hệ thống này, "
        "dùng để chẩn đoán lỗi. Chỉ truy cập được log group của chính project này."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "function_name": {
                "type": "string",
                "description": "Tên Lambda function, ví dụ 'mcp-lab-job-worker'.",
            },
            "minutes": {
                "type": "integer",
                "minimum": 1,
                "maximum": 180,
                "default": 15,
                "description": "Nhìn lại bao nhiêu phút.",
            },
            "filter_pattern": {
                "type": "string",
                "default": "",
                "description": "CloudWatch filter pattern, ví dụ 'ERROR'. Bỏ trống để lấy tất cả.",
            },
        },
        "required": ["function_name"],
        "additionalProperties": False,
    },
)
def tail_lambda_logs(function_name: str, minutes: int = 15, filter_pattern: str = ""):
    start = int((datetime.now(timezone.utc) - timedelta(minutes=int(minutes or 15))).timestamp() * 1000)
    try:
        resp = _logs.filter_log_events(
            logGroupName=f"/aws/lambda/{function_name}",
            startTime=start,
            filterPattern=filter_pattern or "",
            limit=50,
        )
    except _logs.exceptions.ResourceNotFoundException:
        return {"found": False, "reason": f"Không có log group /aws/lambda/{function_name}"}

    events = [
        {
            "timestamp": datetime.fromtimestamp(e["timestamp"] / 1000, tz=timezone.utc).isoformat(),
            "message": e["message"].rstrip(),
        }
        for e in resp.get("events", [])
    ]
    return {"found": True, "count": len(events), "events": events}


# --------------------------------------------------------------------------
# Resources (dữ liệu chỉ đọc, do ứng dụng chọn đưa vào context)
# --------------------------------------------------------------------------

RESOURCES = [
    {
        "uri": "orders://recent",
        "name": "recent_orders",
        "title": "20 order gần nhất",
        "description": "Snapshot dạng text của 20 order mới nhất.",
        "mimeType": "text/plain",
    },
    {
        "uri": "orders://schema",
        "name": "orders_schema",
        "title": "Schema bảng Orders",
        "description": "Mô tả cấu trúc dữ liệu order để model hiểu các field.",
        "mimeType": "text/markdown",
    },
]


def read_resource(uri: str) -> dict:
    if uri == "orders://recent":
        items = orders.scan(Limit=20).get("Items", [])
        lines = [
            f"{i.get('orderId')}\t{i.get('status')}\t{i.get('customerId')}\t{i.get('createdAt')}"
            for i in items
        ]
        text = "orderId\tstatus\tcustomerId\tcreatedAt\n" + "\n".join(lines)
        return {"uri": uri, "mimeType": "text/plain", "text": text}

    if uri == "orders://schema":
        text = (
            "# Bảng Orders\n\n"
            "| Field | Kiểu | Ý nghĩa |\n"
            "|---|---|---|\n"
            "| orderId | string | Khóa chính, dạng `ord-xxxxxxxx` |\n"
            "| customerId | string | Mã khách hàng |\n"
            "| status | string | NEW / PAID / SHIPPED / CANCELLED |\n"
            "| items | list | Mỗi phần tử: sku, qty, price |\n"
            "| total | number | Tổng tiền |\n"
            "| createdAt | string | ISO-8601 UTC |\n"
        )
        return {"uri": uri, "mimeType": "text/markdown", "text": text}

    raise KeyError(uri)


# --------------------------------------------------------------------------
# Prompts (workflow dựng sẵn, do NGƯỜI DÙNG chọn từ menu)
# --------------------------------------------------------------------------

PROMPTS = [
    {
        "name": "triage_order",
        "title": "Chẩn đoán một order",
        "description": "Điều tra tình trạng một order và đề xuất bước xử lý tiếp theo.",
        "arguments": [
            {"name": "order_id", "description": "Mã đơn hàng cần điều tra", "required": True}
        ],
    }
]


def get_prompt(name: str, arguments: dict) -> dict:
    if name != "triage_order":
        raise KeyError(name)
    order_id = (arguments or {}).get("order_id", "")
    return {
        "description": f"Chẩn đoán order {order_id}",
        "messages": [
            {
                "role": "user",
                "content": {
                    "type": "text",
                    "text": (
                        f"Hãy điều tra order `{order_id}`:\n"
                        "1. Dùng get_order để lấy trạng thái hiện tại.\n"
                        "2. Nếu không tìm thấy, dùng list_orders để kiểm tra xem có order "
                        "nào của cùng khách hàng gần đây không.\n"
                        "3. Nếu order ở trạng thái bất thường, dùng tail_lambda_logs trên "
                        "'job-worker' để tìm lỗi liên quan.\n"
                        "4. Tóm tắt phát hiện và đề xuất bước xử lý. KHÔNG tự ý thay đổi dữ liệu."
                    ),
                },
            }
        ],
    }


# --------------------------------------------------------------------------
# JSON-RPC dispatch
# --------------------------------------------------------------------------


def handle_rpc(message: dict):
    """Xử lý một JSON-RPC message. Trả None nếu là notification (không cần response)."""
    req_id = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}
    is_notification = "id" not in message

    if message.get("jsonrpc") != "2.0" or not method:
        return None if is_notification else _rpc_error(req_id, INVALID_REQUEST, "Invalid JSON-RPC request")

    # --- Notifications: server không được trả response ---
    if is_notification:
        logger.info("notification: %s", method)
        return None

    try:
        if method == "initialize":
            requested = params.get("protocolVersion")
            negotiated = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else SUPPORTED_PROTOCOL_VERSIONS[0]
            return _rpc_result(
                req_id,
                {
                    "protocolVersion": negotiated,
                    "capabilities": {
                        "tools": {"listChanged": False},
                        "resources": {"subscribe": False, "listChanged": False},
                        "prompts": {"listChanged": False},
                    },
                    "serverInfo": {
                        "name": SERVER_NAME,
                        "title": "AWS Orders MCP",
                        "version": SERVER_VERSION,
                    },
                    "instructions": (
                        "Server này quản lý đơn hàng demo trên DynamoDB. "
                        "Các tool đọc dữ liệu có thể gọi tự do. "
                        "create_order ghi dữ liệu và chạy bất đồng bộ — "
                        "luôn xác nhận với người dùng trước khi gọi."
                    ),
                },
            )

        if method == "ping":
            return _rpc_result(req_id, {})

        if method == "tools/list":
            return _rpc_result(
                req_id,
                {"tools": [{k: v for k, v in t.items() if k != "handler"} for t in TOOLS.values()]},
            )

        if method == "tools/call":
            return handle_tool_call(req_id, params)

        if method == "resources/list":
            return _rpc_result(req_id, {"resources": RESOURCES})

        if method == "resources/read":
            uri = params.get("uri")
            try:
                return _rpc_result(req_id, {"contents": [read_resource(uri)]})
            except KeyError:
                return _rpc_error(req_id, INVALID_PARAMS, f"Unknown resource URI: {uri}")

        if method == "prompts/list":
            return _rpc_result(req_id, {"prompts": PROMPTS})

        if method == "prompts/get":
            try:
                return _rpc_result(req_id, get_prompt(params.get("name"), params.get("arguments")))
            except KeyError:
                return _rpc_error(req_id, INVALID_PARAMS, f"Unknown prompt: {params.get('name')}")

        return _rpc_error(req_id, METHOD_NOT_FOUND, f"Method not found: {method}")

    except Exception as exc:  # lỗi protocol-level ngoài dự kiến
        logger.exception("Lỗi khi xử lý %s", method)
        return _rpc_error(req_id, INTERNAL_ERROR, str(exc))


def handle_tool_call(req_id, params: dict):
    """tools/call có quy ước riêng về lỗi — xem comment bên dưới."""
    name = params.get("name")
    args = params.get("arguments") or {}

    spec = TOOLS.get(name)
    if not spec:
        # Tool không tồn tại = lỗi PROTOCOL -> JSON-RPC error.
        return _rpc_error(req_id, INVALID_PARAMS, f"Unknown tool: {name}")

    logger.info("tools/call name=%s args=%s", name, json.dumps(args, cls=DecimalEncoder))

    try:
        output = spec["handler"](**args)
    except TypeError as exc:
        return _rpc_error(req_id, INVALID_PARAMS, f"Sai tham số cho tool {name}: {exc}")
    except Exception as exc:
        # Tool CHẠY nhưng THẤT BẠI = lỗi nghiệp vụ -> KHÔNG dùng JSON-RPC error,
        # mà trả result với isError=true để model đọc được và tự xử lý/thử lại.
        logger.exception("Tool %s thất bại", name)
        return _rpc_result(
            req_id,
            {
                "content": [{"type": "text", "text": f"Tool thất bại: {exc}"}],
                "isError": True,
            },
        )

    text = json.dumps(output, ensure_ascii=False, indent=2, cls=DecimalEncoder)
    result = {"content": [{"type": "text", "text": text}], "isError": False}
    if isinstance(output, dict):
        # structuredContent cho client hiểu JSON; text ở trên giữ tương thích ngược.
        result["structuredContent"] = json.loads(text)
    return _rpc_result(req_id, result)


# --------------------------------------------------------------------------
# HTTP layer (API Gateway HTTP API payload v2.0)
# --------------------------------------------------------------------------


def protected_resource_metadata(host: str) -> dict:
    """RFC 9728 — client chưa có token sẽ đọc file này để biết phải xin token ở đâu."""
    resource = f"https://{host}/mcp"
    meta = {
        "resource": resource,
        "authorization_servers": [COGNITO_ISSUER] if COGNITO_ISSUER else [],
        "bearer_methods_supported": ["header"],
        "resource_name": "AWS Orders MCP Server",
    }
    if REQUIRED_SCOPE:
        meta["scopes_supported"] = [REQUIRED_SCOPE]
    return meta


def lambda_handler(event, context):
    req_ctx = event.get("requestContext", {})
    method = req_ctx.get("http", {}).get("method", "")
    path = event.get("rawPath", "")
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    host = headers.get("host", "")

    # --- Metadata công khai, không cần token ---
    if path.endswith("/.well-known/oauth-protected-resource"):
        return _http(200, protected_resource_metadata(host))

    if not path.endswith("/mcp"):
        return _http(404, {"error": "not_found"})

    # --- GET /mcp: server stateless nên không mở SSE stream do server khởi xướng ---
    if method == "GET":
        return _http(405, {"error": "method_not_allowed", "detail": "Server stateless, không hỗ trợ SSE stream."})

    # --- DELETE /mcp: không có session để xóa ---
    if method == "DELETE":
        return _http(405, {"error": "method_not_allowed", "detail": "Server không dùng session."})

    if method != "POST":
        return _http(405, {"error": "method_not_allowed"})

    # Ai đang gọi? API Gateway JWT authorizer đã verify chữ ký + iss + aud + scope,
    # ở đây chỉ đọc claim ra để ghi audit log.
    claims = (req_ctx.get("authorizer") or {}).get("jwt", {}).get("claims", {})
    caller = claims.get("client_id") or claims.get("sub") or "anonymous"
    logger.info("caller=%s path=%s", caller, path)

    # Spec yêu cầu client gửi Accept: application/json, text/event-stream.
    # Server này chỉ log để bạn dễ test bằng curl, không reject.
    if "text/event-stream" not in (headers.get("accept") or ""):
        logger.info("Client không gửi Accept: text/event-stream (curl thì bình thường)")

    try:
        message = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _http(400, _rpc_error(None, PARSE_ERROR, "Parse error"))

    # JSON-RPC batching đã bị GỠ BỎ khỏi spec từ revision 2025-06-18.
    if isinstance(message, list):
        return _http(400, _rpc_error(None, INVALID_REQUEST, "Batching không được hỗ trợ"))

    response = handle_rpc(message)

    if response is None:
        # Notification -> spec yêu cầu 202 Accepted, body rỗng.
        return {"statusCode": 202, "headers": {}, "body": ""}

    return _http(200, response)
