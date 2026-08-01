"""Lambda non-proxy: nhận payload đã qua mapping template của API Gateway.

Khác với AWS_PROXY, event ở đây KHÔNG phải HTTP request gốc mà là JSON do
request template dựng ra — xem request_templates trong main.tf.
"""

import json


def handler(event, context):
    print("Received event:", json.dumps(event))

    if not event.get("customerId") or not event.get("items"):
        return {
            "ok": False,
            "errorCode": "INVALID_ORDER",
            "message": "Missing customerId or items",
        }

    return {
        "ok": True,
        "order": {
            "id": f"ord-{event.get('orderId', 'unknown')}",
            "total": 199.5,
        },
        "debug": {
            "received": event,
        },
    }
