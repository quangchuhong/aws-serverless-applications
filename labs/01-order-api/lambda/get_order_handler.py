"""GET /orders/{id} — đọc một order từ DynamoDB."""

import json
import os
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["ORDERS_TABLE_NAME"])


class DecimalEncoder(json.JSONEncoder):
    """DynamoDB trả số dạng Decimal, json.dumps không serialize được."""

    def default(self, o):
        if isinstance(o, Decimal):
            # Giữ nguyên số nguyên là int để "qty": 2 không thành "qty": 2.0
            return int(o) if o == o.to_integral_value() else float(o)
        return super().default(o)


def lambda_handler(event, context):
    # Không dùng event.get("pathParameters", {}).get("id"): khi key tồn tại
    # nhưng giá trị là None, .get() trả None -> AttributeError.
    order_id = (event.get("pathParameters") or {}).get("id")
    if not order_id:
        return _response(400, {"message": "Missing path parameter: id"})

    try:
        resp = table.get_item(Key={"orderId": order_id})
    except ClientError as e:
        return _response(
            500,
            {"message": f"DynamoDB error: {e.response['Error']['Message']}"},
        )

    item = resp.get("Item")
    if not item:
        return _response(404, {"message": "Order not found"})

    return _response(200, item)


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, cls=DecimalEncoder),
    }
