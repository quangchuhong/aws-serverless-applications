"""SQS -> DynamoDB.

Trả về batchItemFailures để chỉ message thực sự lỗi mới bị retry — nếu trả
lỗi cho cả invocation, toàn bộ batch quay lại queue và những message đã ghi
thành công sẽ bị xử lý lại.
"""

import json
import logging
import os
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
orders_table = dynamodb.Table(os.environ["ORDERS_TABLE_NAME"])


def lambda_handler(event, context):
    failures = []

    for record in event.get("Records", []):
        message_id = record["messageId"]

        try:
            # parse_float=Decimal: boto3 resource API không nhận float,
            # giá tiền dạng 19.99 sẽ làm put_item raise TypeError.
            msg = json.loads(record["body"], parse_float=Decimal)

            order_id = msg["orderId"]
            user_id = msg["userId"]
            items = msg["items"]
            created_at = msg["createdAt"]

            logger.info(
                "Processing order: orderId=%s userId=%s createdAt=%s",
                order_id,
                user_id,
                created_at,
            )

            orders_table.put_item(
                Item={
                    "orderId": order_id,
                    "userId": user_id,
                    "items": items,
                    "createdAt": created_at,
                }
            )
        except (ClientError, json.JSONDecodeError, KeyError, TypeError) as e:
            logger.exception("Failed to process message %s: %s", message_id, e)
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
