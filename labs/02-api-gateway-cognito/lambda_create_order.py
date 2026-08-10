"""Lambda non-proxy: nhận payload đã qua mapping template của API Gateway.

Khác với AWS_PROXY, event ở đây KHÔNG phải HTTP request gốc mà là JSON do
request template dựng ra — xem request_templates trong main.tf.
"""

import json


def handler(event, context):
    print("Received event:", json.dumps(event))

    # Với non-proxy integration, function KHÔNG tự đặt được HTTP status.
    # Cách duy nhất báo lỗi là ném exception, và API Gateway khớp
    # selection_pattern với CHUỖI error message — nên phải gắn nhãn vào đó.
    #
    # Trả về {"ok": False} như bản cũ là sai: nó là một invocation thành công,
    # nên client nhận HTTP 200 dù đơn hàng bị từ chối.
    if not event.get("customerId") or not event.get("items"):
        raise Exception("[400] Missing customerId or items")

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
