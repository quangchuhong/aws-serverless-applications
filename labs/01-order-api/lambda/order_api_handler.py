"""POST /orders — nhận request, validate, đẩy vào SQS, trả 202."""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["ORDER_QUEUE_URL"]


def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"message": "Invalid JSON"})

    user_id = body.get("userId")
    items = body.get("items")

    if not user_id or not items:
        return _response(400, {"message": "userId and items are required"})

    order_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    message = {
        "orderId": order_id,
        "userId": user_id,
        "items": items,
        "createdAt": now,
    }

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
    )

    return _response(202, {"orderId": order_id, "status": "ACCEPTED"})


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
