# Serverless Order API

*API Gateway HTTP API + Lambda + SQS + DynamoDB + DLQ + SNS*

Vietnamese version: [`docs/01-Example-Aws-Serverless-Order-API.md`](../docs/01-Example-Aws-Serverless-Order-API.md)
Runnable lab: [`labs/01-order-api/`](../labs/01-order-api/)

---

## 1. What this builds

An event-driven ordering API. The write path accepts a request, puts it on a
queue, and returns immediately; a separate function drains the queue and
persists to DynamoDB. The read path goes straight to the table.

```text
POST /orders  →  order-api-handler  →  order-queue  →  order-processor  →  OrdersTable
                                            │
                                            └─(5 failures)→ order-dlq → alarm → SNS

GET /orders/{id}  →  get-order-handler  →  OrdersTable
```

### The request flow, step by step

1. A client posts an order. The API handler validates the payload, generates an
   order ID, sends a message to SQS, and returns **`202 Accepted`** with that
   ID. The order has not been stored yet, and the response says so.

2. The event source mapping polls `order-queue` and invokes `order-processor`
   with batches of up to five messages. The processor writes each order to
   DynamoDB.

3. If a message fails five times, SQS moves it to `order-dlq`. A CloudWatch
   alarm on the DLQ's depth fires and publishes to an SNS topic.

4. `GET /orders/{id}` reads the item directly from DynamoDB.

### Why decouple at all?

The obvious alternative is to write to DynamoDB directly from the API handler
and return `201 Created`. That is simpler and for many systems it is the right
answer.

The queue buys you three things:

- **Absorbing spikes.** A traffic surge fills the queue instead of overwhelming
  the database or exhausting Lambda concurrency.
- **Isolating failures.** If DynamoDB is throttling, the API keeps accepting
  orders. Nothing is lost; processing simply lags.
- **Somewhere for failures to go.** A write that fails repeatedly ends up in a
  dead-letter queue where a human can look at it, rather than becoming a 500
  the customer sees.

The cost is **eventual consistency**, and it is a real cost. A client that
posts an order and immediately reads it back may get a 404. Your API contract
has to be honest about that — which is why the response is `202 Accepted`, not
`201 Created`. If your consumers cannot tolerate that, do not add the queue.

---

## 2. The write path

```python
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

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({
            "orderId": order_id,
            "userId": user_id,
            "items": items,
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }),
    )

    return _response(202, {"orderId": order_id, "status": "ACCEPTED"})
```

The ID is generated **before** the message is sent, so the client gets
something to poll with even though nothing has been persisted.

Full source: [`labs/01-order-api/lambda/order_api_handler.py`](../labs/01-order-api/lambda/order_api_handler.py)

---

## 3. The processor, and partial batch failures

With `batch_size = 5`, an unhandled exception sends **the whole batch** back to
the queue — including the four messages that succeeded. They get written again.
`put_item` is idempotent on the same key so nothing corrupts here, but the
receive count climbs on messages that never failed, and they can reach the DLQ
for no reason.

The fix is to report failures per message:

```python
def lambda_handler(event, context):
    failures = []

    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            msg = json.loads(record["body"], parse_float=Decimal)
            orders_table.put_item(Item={...})
        except (ClientError, json.JSONDecodeError, KeyError, TypeError) as e:
            logger.exception("Failed to process message %s: %s", message_id, e)
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
```

paired with the event source mapping setting:

```hcl
function_response_types = ["ReportBatchItemFailures"]
```

Both halves are required. Returning `batchItemFailures` without configuring the
mapping does nothing at all — Lambda simply ignores the return value, the
invocation counts as a success, and **failed messages are silently deleted**.
That failure mode is quiet and expensive.

### The `Decimal` trap

`boto3`'s DynamoDB resource API refuses Python floats. A price of `19.99` in
the payload makes `put_item` raise `TypeError`. Parse with
`json.loads(body, parse_float=Decimal)`.

Coming back the other way, `json.dumps` cannot serialise `Decimal`, so the read
handler needs a custom encoder. Convert whole numbers to `int` so a quantity of
`2` does not come back as `2.0`.

---

## 4. Dead-letter queue and alerting

### The anti-pattern

A tempting design is to attach a Lambda to the DLQ that sends an alert. It
works — you get the email — but it is wrong.

When that Lambda returns successfully, the event source mapping **deletes the
message from the DLQ**. You have been notified that something failed, and in
the same moment you have destroyed the evidence. There is nothing left to
inspect and nothing left to redrive.

### The right shape

Alert from the **metric**, leave the messages alone:

```hcl
resource "aws_cloudwatch_metric_alarm" "order_dlq_not_empty" {
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions    = { QueueName = aws_sqs_queue.order_dlq.name }
  alarm_actions = [aws_sns_topic.order_dlq_alerts.arn]
  ok_actions    = [aws_sns_topic.order_dlq_alerts.arn]
}
```

Once the bug is fixed, move the messages back with a redrive:

```bash
aws sqs start-message-move-task --source-arn "$DLQ_ARN"
```

The general principle: **a dead-letter queue is storage, not a queue you
consume**. Alert on the metric, reprocess with redrive.

---

## 5. Details in the Terraform worth explaining

Full configuration: [`labs/01-order-api/main.tf`](../labs/01-order-api/main.tf)

**Visibility timeout is six times the function timeout.** The processor has a
10-second timeout, the queue a 60-second visibility timeout. This is AWS's
recommendation for event source mappings — the mapping needs headroom beyond
the function's own runtime.

**Three IAM roles, not one.** It is tempting to share a role between the
processor and the read handler since both touch the same table. Don't. The read
handler would inherit `sqs:DeleteMessage` and `dynamodb:PutItem`, neither of
which it needs. A read-only endpoint that holds write permissions is exactly
the thing an audit flags.

**Log groups are declared explicitly.** Log groups that Lambda creates
implicitly **never expire**. Declaring them with `retention_in_days` is a
one-line change that stops the bill growing forever.

**The DLQ retains for 14 days, the main queue for 4.** Messages only reach the
DLQ after repeated failures, and you need time to investigate. Note that
retention counts from when the message entered the **original** queue.

---

## 6. Testing it

```bash
ENDPOINT=$(terraform output -raw http_api_endpoint)

curl -X POST "$ENDPOINT/orders" \
  -H "Content-Type: application/json" \
  -d '{"userId":"U-1","items":[{"sku":"SKU-1","qty":2}]}'
# → {"orderId":"6fe428b2-...","status":"ACCEPTED"}

curl "$ENDPOINT/orders/6fe428b2-..."
```

To exercise the DLQ path deliberately, strip the processor's DynamoDB
permission, post an order, and wait for the five retries. Full walkthrough in
the [lab README](../labs/01-order-api/README.md).

---

## 7. Where to take it next

- `GET /orders?userId=...` backed by a global secondary index.
- An order `status` field and the state transitions that go with it.
- Publish `OrderCreated` to EventBridge so other systems can subscribe without
  the order service knowing about them.
- Alarms on Lambda `Errors`, `Throttles`, and the queue's
  `ApproximateAgeOfOldestMessage`.
- An authorizer on the endpoints — see [doc 02](02-api-gateway-and-cognito-authorizer.md).

---

## Practice

### Read

| Page title | URL |
|------------|-----|
| *Using Lambda with Amazon SQS* | https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html |
| *Amazon SQS dead-letter queues* | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html |
| *Working with AWS Lambda proxy integrations* | https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html |

Read the SQS section on partial batch responses carefully. It is the part of
this design most often implemented incorrectly.

### Key phrases

This document is about **describing a flow end to end** — the thing you do at a
whiteboard, and one of the highest-value skills to have in English.

| Phrase | Used like this |
|--------|----------------|
| **the write path / the read path** | "The write path goes through the queue; the read path hits the table directly." |
| **upstream / downstream** | "The downstream database was throttling." |
| **to hit** a service | "The read handler hits DynamoDB directly." |
| **to land in** | "Failed messages land in the dead-letter queue." |
| **to absorb a spike** | "The queue absorbs traffic spikes." |
| **to lag** | "Processing lags, but nothing is lost." |
| **to be eventually consistent** | "The API is eventually consistent — a read straight after a write may 404." |
| **to tolerate** | "If your consumers can't tolerate that, don't add the queue." |
| **to be honest about** | "Your API contract has to be honest about the delay." |
| **to inherit permissions** | "The read handler would inherit write permissions it doesn't need." |
| **to flag** something | "That's exactly what an audit would flag." |
| **to strip a permission** | "Strip the DynamoDB permission to force a failure." |
| **to exercise a path** | "To exercise the DLQ path deliberately…" |
| **a failure mode** | "That failure mode is quiet and expensive." |
| **to silently drop / silently delete** | "Failed messages are silently deleted." |

Note the article in **"the write path"** — a specific known path in *this*
system, so it takes *the*. Vietnamese has no articles and this is one of the
most persistent sources of non-native-sounding English. When you name a
component of a system you are describing, it is almost always *the*.

### Write

Write **5–8 sentences**, using **at least 3** phrases from the table.

Prompt: *Explain to a frontend developer why `POST /orders` returns `202` and
an ID rather than the created order, and what that means for their UI.*

Write it as you would actually send it — to a colleague, not to an examiner. It
should be usable as a real Slack message. The test of success: would they know
what to build after reading it?

### Speak

**Drill A — 2-minute explainer.** Walk through **the whole architecture** as if
at a whiteboard. Client to response, then the failure path.

Two minutes covers this only if you are disciplined. Practise the transitions —
"from there", "at that point", "meanwhile", "if that fails" — because those are
what make a walkthrough sound fluent rather than like a list.

Then answer this without preparing it first: *"Why not just write to DynamoDB
directly?"* You should be able to give the trade-off in both directions.

**Drill B — elimination.**

> A Lambda function consumes an SQS queue with `batch_size = 10`. When one
> message in a batch fails, all ten are reprocessed. Which change fixes this
> with the least disruption?
>
> A. Set `batch_size = 1`
> B. Configure `ReportBatchItemFailures` and return `batchItemFailures`
> C. Catch all exceptions in the handler so the invocation never fails
> D. Increase `maxReceiveCount` so messages get more attempts

Option C is the interesting one — it "works" in that the symptom disappears.
Say out loud exactly what it breaks. That is the answer a reviewer wants to
hear.

Model answers: [`practice/elimination-drills.md`](practice/elimination-drills.md)
