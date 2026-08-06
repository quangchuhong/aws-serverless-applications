"""LAB 1 — MCP server chạy local qua stdio, bọc quanh AWS SDK (boto3).

Đây là cách nhanh nhất để cảm nhận MCP: không cần deploy gì, không cần auth,
dùng luôn credential AWS trên máy bạn (~/.aws/credentials hoặc env var).

Chạy thử bằng MCP Inspector:
    uv run --with mcp --with boto3 mcp dev stdio_server.py
hoặc:
    pip install -r requirements.txt
    npx @modelcontextprotocol/inspector python stdio_server.py

Gắn vào Claude Code:
    claude mcp add aws-local -- python /duong/dan/tuyet/doi/stdio_server.py

CẢNH BÁO: server này chạy với TOÀN BỘ quyền của AWS profile bạn đang dùng.
Hãy dùng một profile read-only khi thử nghiệm.
"""

import os

import boto3
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("aws-local")

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")

s3 = boto3.client("s3", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
lambda_client = boto3.client("lambda", region_name=REGION)
ce = boto3.client("ce", region_name="us-east-1")  # Cost Explorer chỉ có ở us-east-1


@mcp.tool()
def list_s3_buckets() -> list[dict]:
    """Liệt kê toàn bộ S3 bucket trong tài khoản AWS hiện tại, kèm ngày tạo."""
    resp = s3.list_buckets()
    return [
        {"name": b["Name"], "createdAt": b["CreationDate"].isoformat()}
        for b in resp.get("Buckets", [])
    ]


@mcp.tool()
def describe_dynamodb_table(table_name: str) -> dict:
    """Mô tả cấu trúc một bảng DynamoDB: khóa, index, chế độ billing, số item ước tính.

    Args:
        table_name: Tên bảng DynamoDB chính xác.
    """
    t = ddb.describe_table(TableName=table_name)["Table"]
    return {
        "name": t["TableName"],
        "status": t["TableStatus"],
        "keySchema": t["KeySchema"],
        "billingMode": t.get("BillingModeSummary", {}).get("BillingMode", "PROVISIONED"),
        "itemCount": t.get("ItemCount"),
        "sizeBytes": t.get("TableSizeBytes"),
        "globalSecondaryIndexes": [i["IndexName"] for i in t.get("GlobalSecondaryIndexes", [])],
    }


@mcp.tool()
def list_lambda_functions(max_items: int = 20) -> list[dict]:
    """Liệt kê các Lambda function trong region hiện tại kèm runtime, memory, timeout.

    Args:
        max_items: Số function tối đa trả về (1-50).
    """
    max_items = max(1, min(max_items, 50))
    resp = lambda_client.list_functions(MaxItems=max_items)
    return [
        {
            "name": f["FunctionName"],
            "runtime": f.get("Runtime"),
            "memoryMB": f.get("MemorySize"),
            "timeoutSec": f.get("Timeout"),
            "lastModified": f.get("LastModified"),
        }
        for f in resp.get("Functions", [])
    ]


@mcp.tool()
def get_cost_last_7_days() -> dict:
    """Lấy chi phí AWS 7 ngày gần nhất, tách theo service (unblended cost, USD).

    Cần quyền ce:GetCostAndUsage. Cost Explorer tính phí ~0.01 USD mỗi API call.
    """
    from datetime import date, timedelta

    end = date.today()
    start = end - timedelta(days=7)
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    totals: dict[str, float] = {}
    for day in resp["ResultsByTime"]:
        for group in day["Groups"]:
            svc = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            totals[svc] = round(totals.get(svc, 0.0) + amount, 4)
    ranked = dict(sorted(totals.items(), key=lambda kv: kv[1], reverse=True))
    return {"period": f"{start} .. {end}", "currency": "USD", "byService": ranked}


@mcp.resource("aws://identity")
def caller_identity() -> str:
    """Tài khoản/role AWS mà server này đang chạy dưới quyền — kiểm tra trước khi làm gì."""
    ident = boto3.client("sts", region_name=REGION).get_caller_identity()
    return f"Account: {ident['Account']}\nArn: {ident['Arn']}\nRegion: {REGION}"


@mcp.prompt()
def audit_serverless_stack() -> str:
    """Rà soát nhanh stack serverless hiện tại."""
    return (
        "Hãy rà soát stack serverless trong tài khoản AWS này:\n"
        "1. Đọc resource aws://identity để biết đang làm việc trên account nào.\n"
        "2. Dùng list_lambda_functions để liệt kê function.\n"
        "3. Chỉ ra function nào có timeout > 30s nhưng đứng sau API Gateway "
        "(sẽ luôn bị gateway cắt ở ~29s).\n"
        "4. Chỉ ra function nào memory <= 128MB — thường là nguyên nhân chạy chậm.\n"
        "5. Tóm tắt thành bảng, kèm khuyến nghị. Chỉ ĐỌC, không thay đổi gì."
    )


if __name__ == "__main__":
    mcp.run()
