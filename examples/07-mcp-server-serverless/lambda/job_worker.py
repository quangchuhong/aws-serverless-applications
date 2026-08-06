"""Worker xử lý job bất đồng bộ do MCP tool `create_order` submit qua SQS.

Vì sao cần tách ra: API Gateway HTTP API timeout ~29-30s. Tool nào có thể chạy lâu
hơn thì KHÔNG được xử lý inline trong request MCP — trả jobId ngay rồi để worker làm.

Trả về `batchItemFailures` (partial batch response) để chỉ những message lỗi mới
bị retry, thay vì retry cả batch. Event source mapping phải bật
function_response_types = ["ReportBatchItemFailures"].
"""

import json
import logging
import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_ddb = boto3.resource("dynamodb")
orders = _ddb.Table(os.environ["ORDERS_TABLE"])
jobs = _ddb.Table(os.environ["JOBS_TABLE"])

VALID_STATUSES = {"NEW", "PAID", "SHIPPED", "CANCELLED"}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def process(payload: dict) -> None:
    job_id = payload["jobId"]
    order_id = payload["orderId"]
    items = payload["items"]

    total = sum(Decimal(str(i.get("price", 0))) * int(i["qty"]) for i in items)

    orders.put_item(
        Item={
            "orderId": order_id,
            "customerId": payload["customerId"],
            "status": "NEW",
            "items": [
                {"sku": i["sku"], "qty": int(i["qty"]), "price": Decimal(str(i.get("price", 0)))}
                for i in items
            ],
            "total": total,
            "createdAt": _now_iso(),
        }
    )

    jobs.update_item(
        Key={"jobId": job_id},
        UpdateExpression="SET #s = :s, finishedAt = :f, #r = :r",
        ExpressionAttributeNames={"#s": "status", "#r": "result"},
        ExpressionAttributeValues={
            ":s": "DONE",
            ":f": _now_iso(),
            ":r": {"orderId": order_id, "total": total},
        },
    )
    logger.info("Job %s xong, tạo order %s", job_id, order_id)


def mark_failed(payload: dict, error: str) -> None:
    job_id = payload.get("jobId")
    if not job_id:
        return
    try:
        jobs.update_item(
            Key={"jobId": job_id},
            UpdateExpression="SET #s = :s, #e = :e, finishedAt = :f, expiresAt = :t",
            ExpressionAttributeNames={"#s": "status", "#e": "error"},
            ExpressionAttributeValues={
                ":s": "FAILED",
                ":e": error[:500],
                ":f": _now_iso(),
                ":t": int(time.time()) + 24 * 3600,
            },
        )
    except Exception:
        logger.exception("Không cập nhật được job %s sang FAILED", job_id)


def lambda_handler(event, context):
    failures = []
    for record in event.get("Records", []):
        payload = {}
        try:
            payload = json.loads(record["body"])
            process(payload)
        except Exception as exc:
            logger.exception("Xử lý message %s thất bại", record.get("messageId"))
            mark_failed(payload, str(exc))
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}
