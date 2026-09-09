# Amazon SQS — Concepts, Configuration and Cost

Vietnamese version: [`docs/05-Aws-sqs-queue.md`](../docs/05-Aws-sqs-queue.md)

---

## 1. Queue types

### 1.1. Standard queues

- Nearly unlimited throughput.
- **Best-effort ordering** — SQS tries to preserve order but occasionally
  delivers messages out of sequence.
- **At-least-once delivery** — a message may be delivered more than once.

Use a standard queue when you do not need strict ordering and duplicates
either cannot damage anything or your consumer is idempotent.

### 1.2. FIFO queues (`*.fifo`)

- **Strict ordering** within each `MessageGroupId`.
- **Exactly-once processing** at the queue level — SQS will not introduce
  duplicates if deduplication is configured correctly.
- Lower throughput than standard, though higher than most people assume.

**High throughput mode** (available since 2021) changes the numbers
substantially:

| Mode | Without batching | With batches of 10 |
|------|------------------|--------------------|
| FIFO, default | 300 msg/s | 3,000 msg/s |
| FIFO, high throughput | ~9,000 msg/s | ~70,000 msg/s |

(Exact limits vary by Region — check the current service quotas page.)

Enabled with two attributes:

```hcl
resource "aws_sqs_queue" "orders_fifo" {
  name       = "orders.fifo"
  fifo_queue = true

  deduplication_scope   = "messageGroup" # instead of "queue"
  fifo_throughput_limit = "perMessageGroupId"
}
```

There is a catch: high throughput only helps if you have **many distinct
message group IDs**. If every message shares one group ID, you are back to the
original limit — ordering within a group is inherently sequential. Choose a
high-cardinality group key (`orderId`, `accountId`), never a constant.

> The figure "FIFO only does 300 messages per second" is repeated constantly
> and it rules FIFO out of designs where it would have been fine. It describes
> the default mode only.

---

## 2. The configuration that matters

### 2.1. Visibility timeout

When a consumer receives a message, that message becomes **invisible** to other
consumers for the duration of the visibility timeout.

- If the consumer finishes and calls `DeleteMessage` in time, the message is
  gone.
- If the consumer crashes, times out, or simply takes too long, the message
  **becomes visible again** and is redelivered.

Defaults and limits: 30 seconds by default, 12 hours maximum.

**How to choose it:**

For a consumer that polls the queue itself (EC2, ECS), set it above your
worst-case processing time.

For a **Lambda event source mapping**, AWS recommends **at least six times the
function timeout**. The event source mapping needs headroom for internal
retries and for recovering from a failed poller. Function timeout of 10 seconds
means a visibility timeout of 60.

Setting it too low is worse than setting it too high. A message that is
redelivered while the first consumer is still working gets processed twice, and
its receive count climbs — which pushes it into the dead-letter queue even
though nothing is actually broken.

### 2.2. Message retention period

How long a message can stay in the queue before SQS deletes it automatically.

- Minimum 60 seconds, **default 4 days**, maximum 14 days.

> Give a **dead-letter queue a longer retention than the main queue** —
> usually the full 14 days. Messages only land there after repeated failures,
> and you need time to investigate before redriving them. Note that retention
> is counted from when the message entered the **original** queue, not from
> when it arrived in the DLQ.

### 2.3. Delivery delay

Postpones the moment a message becomes visible.

- Range 0–**900 seconds (15 minutes)**. That ceiling is hard; for longer delays
  use EventBridge Scheduler or Step Functions.
- Configurable per queue, or per message on standard queues.
- **FIFO queues do not support per-message delay** — queue level only.

Useful for "retry in five minutes" flows without introducing a scheduler.

### 2.4. Maximum message size

256 KB. For larger payloads, store the body in S3 and put only the key and
metadata in the message. (There is also the SQS Extended Client library, which
does this for you but adds complexity.)

This limit has a cost consequence — see §4.

### 2.5. Long polling

When a consumer calls `ReceiveMessage` on an empty queue, long polling lets the
call **wait** up to 20 seconds for a message to arrive instead of returning
empty immediately.

Set `ReceiveMessageWaitTimeSeconds` between 0 and 20 at the queue level, or
override it per request.

Turn it on almost always. It reduces empty receives, which reduces both cost
and noise.

### 2.6. Redrive policy and dead-letter queues

When a message is received repeatedly but never deleted — meaning processing
keeps failing — you do not want it stuck in the queue forever.

The redrive policy takes two settings:

- `deadLetterTargetArn` — the DLQ, itself an ordinary SQS queue.
- `maxReceiveCount` — how many times a message may be received without being
  deleted before SQS moves it aside.

With `maxReceiveCount = 5`: the message is handed to a consumer five times; on
the sixth attempt SQS moves it to the DLQ instead.

> **Treat a DLQ as storage, not as a queue to consume.** A common mistake is
> attaching a Lambda to the DLQ to send alerts. When that Lambda succeeds, the
> event source mapping deletes the message — so you get the alert but lose the
> evidence. Alert from the **metric** (a CloudWatch alarm on
> `ApproximateNumberOfMessagesVisible`) and reprocess with **redrive**
> (`StartMessageMoveTask`).

### 2.7. Message groups and deduplication (FIFO only)

**`MessageGroupId`** groups related messages. SQS guarantees ordering within a
group; different groups are processed in parallel. Set it to the entity whose
timeline must be preserved — `userId`, `orderId`, `accountId`.

**Deduplication** prevents the same message being enqueued twice within a
5-minute deduplication interval. Either let SQS hash the body
(`ContentBasedDeduplication = true`) or supply your own
`MessageDeduplicationId`.

### 2.8. Encryption

SQS supports KMS encryption at rest, using either an AWS-managed key or a
customer-managed key. It is transparent to application code — the SDK handles
it — but a customer-managed key adds KMS request charges. Reduce those with
`kms_data_key_reuse_period_seconds` (up to 24 hours), which lets SQS cache the
data key instead of calling KMS per message.

---

## 3. Choosing between standard and FIFO

### 3.1. Workloads that tolerate duplicates → standard

**Notifications** (email, SMS, push). A duplicate is mildly annoying, not
destructive.

**Idempotent background jobs** — thumbnail generation, transcoding, PDF export,
search reindexing. Running the job twice overwrites the same output, so
reprocessing is harmless by nature.

**Logs, metrics, analytics events.** A duplicated event adds a row. Either
accept the small error or deduplicate downstream on `eventId`.

**Anything you have made idempotent at the application layer.** Each message
carries a unique `eventId` or `transactionId`; the consumer checks whether it
has already processed that ID before acting. The queue may deliver a message
several times, but the system counts it once.

### 3.2. Workloads that require ordering → FIFO

**Order and payment flows.** `ORDER_CREATED → PAYMENT_AUTHORIZED →
PAYMENT_CAPTURED → SHIPPED`. You must not ship before capturing payment, and
you must not charge twice. Group by `orderId`.

**Financial transactions.** Deposits, withdrawals and transfers have to be
applied in order for the balance to be correct. Group by `accountId`.

**Booking and inventory.** Seat and stock updates applied out of order lead to
overbooking. Group by `resourceId`.

**Event sourcing.** `CREATED → UPDATED → DELETED` for one entity must follow
the real timeline. Applying an update after a delete corrupts state. Group by
`entityId`.

**Device or session commands.** Never "stop" before "start". Group by
`deviceId`.

### 3.3. The decision in one line

If a duplicate would cause a double charge, double stock deduction, or a wrong
order status — and making the consumer strictly idempotent is hard — use FIFO.
Otherwise use standard and invest the effort in idempotency instead.

---

## 4. Cost

### 4.1. What you are billed for

**Requests.** Every API operation counts: `SendMessage`, `SendMessageBatch`,
`ReceiveMessage`, `DeleteMessage`, `DeleteMessageBatch`, and management calls.
Priced per million requests.

**Queue type.** FIFO costs more per million than standard.

**Payload size — this is the part people get wrong.** Billing is *not* purely
per API call. AWS bills **each 64 KB chunk of a payload as one request**:

| Message size | Requests billed |
|--------------|-----------------|
| 1 KB | 1 |
| 64 KB | 1 |
| 65 KB | 2 |
| 256 KB | 4 |

A 256 KB `SendMessage` therefore costs four times a 10 KB one — and since the
message is also received and deleted, the multiplier applies three times over.

This is the real reason the "store the payload in S3, send only the key"
pattern saves money, beyond simply staying under the 256 KB ceiling.

**Free tier:** one million requests per month, applying to standard and FIFO
alike. (FIFO does not get a smaller free tier — a common misconception.)

### 4.2. Batching

`SendMessageBatch` sends up to 10 messages as one request; `ReceiveMessage`
with `MaxNumberOfMessages = 10` retrieves up to 10; `DeleteMessageBatch`
deletes several at once.

> Batching only helps when messages are **small**. The 64 KB rule still
> applies: a batch has a 256 KB total limit, so a full batch of large messages
> is billed as 4 requests, not 1. Ten 2 KB messages in one batch = 1 request
> (a 10× saving). Four 64 KB messages in one batch = 4 requests (no saving at
> all).

### 4.3. Worked estimate

Standard queue, small messages, no batching, 10 million messages per month:

- Send 10M + Receive 10M + Delete 10M = **30M requests**
- Minus 1M free tier = 29M billable
- At an illustrative $0.40 per million → **≈ $11.60/month**

With batches of 10:

- 1M + 1M + 1M = 3M requests, minus free tier = 2M billable
- → **≈ $0.80/month**

*(Figures illustrate the arithmetic. Check the pricing page for real rates.)*

### 4.4. Commonly forgotten costs

**Retries.** Every failed processing attempt means another receive and
eventually another delete. A buggy consumer inflates the bill.

**The DLQ.** Moving a message to the DLQ is an extra send, and reading the DLQ
costs receives and deletes of its own.

**Customer-managed KMS keys.** Encrypt and decrypt calls add up at volume.

**Payload size.** Check `SentMessageSize` in CloudWatch to see what your
messages actually weigh before assuming one request per operation.

---

## 5. Monitoring

### 5.1. Queue metrics

| Metric | What it tells you |
|--------|-------------------|
| `NumberOfMessagesSent` | Input load |
| `NumberOfMessagesReceived` | Includes redeliveries — a gap versus deleted means failures |
| `NumberOfMessagesDeleted` | Successful processing |
| `ApproximateNumberOfMessagesVisible` | Backlog. Rising steadily = the consumer cannot keep up |
| `ApproximateNumberOfMessagesNotVisible` | Messages currently in flight |
| `ApproximateAgeOfOldestMessage` | How stale the backlog is — often the best single health signal |

### 5.2. Consumer metrics (Lambda)

`Invocations`, `Errors`, `Throttles`, `Duration`, `ConcurrentExecutions`.

Read them together with the queue metrics. Concurrency pinned at its ceiling
while the backlog keeps growing means you need to scale out, not optimise code.

### 5.3. Alarms worth having

- `ApproximateAgeOfOldestMessage` above a threshold (say 300s) — processing has
  fallen behind.
- Anything at all in the DLQ — `ApproximateNumberOfMessagesVisible > 0`.
- Lambda `Throttles > 0` — insufficient concurrency.
- Lambda `Errors` rising — messages are heading for the DLQ.

---

## Practice

### Read

Read these in English. Do not translate.

| Page title | URL |
|------------|-----|
| *What is Amazon Simple Queue Service?* | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html |
| *Amazon SQS visibility timeout* | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html |
| *Amazon SQS short and long polling* | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html |
| *Amazon SQS dead-letter queues* | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html |
| *Amazon SQS FIFO queues* | https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues.html |

Start with the visibility timeout page. It is short and it is the concept most
often explained badly.

### Key phrases

Collocations, not vocabulary. The noun is easy; the verb that goes with it is
the thing to learn.

| Phrase | Used like this |
|--------|----------------|
| **to poll a queue** | "The consumer polls the queue every few seconds." |
| **a message is redelivered** | "If the consumer crashes, the message is redelivered after the visibility timeout expires." |
| **to fall behind** | "The consumer is falling behind — the backlog has been growing for an hour." |
| **to keep up with** | "One worker cannot keep up with this traffic." |
| **to drain a queue** | "We drained the queue before the migration." |
| **in flight** | "Messages currently in flight are invisible to other consumers." |
| **to scale out** | "We scaled out to twenty consumers." (out = more instances; **up** = bigger instances) |
| **to tolerate duplicates** | "This workload tolerates duplicates, so a standard queue is fine." |
| **at-least-once delivery** | "Standard queues give you at-least-once delivery." |
| **to preserve ordering** | "FIFO preserves ordering within a message group." |
| **to introduce a duplicate** | "SQS will not introduce duplicates if deduplication is configured." |
| **headroom** | "The visibility timeout needs headroom for retries." |
| **to be billed as** | "Each 64 KB chunk is billed as one request." |
| **to rule something out** | "That number rules FIFO out of designs where it would have worked." |
| **a ceiling / a hard limit** | "Fifteen minutes is a hard ceiling on delivery delay." |

Two that trip people up:

- **"backlog"** is uncountable in this sense. *"The backlog is growing"*, never
  *"the backlogs are growing"*.
- **"scale out"** vs **"scale up"** are different. Out = more instances. Up =
  bigger instances. Saying the wrong one in a design review is noticed.

### Write

Write **5–8 sentences**, using **at least 3** phrases from the table.

Prompt: *Your team runs a payment service on a standard SQS queue. Duplicate
messages have caused two double charges this month. Write a short summary of
the problem and your recommendation.*

Do not define SQS. Assume your reader knows it. Argue for a decision and say
what it costs you.

A strong answer will mention: why standard queues deliver at least once, what
FIFO would change, what group key you would choose and why, and what you give
up (throughput, or the work of making the consumer idempotent instead).

### Speak

**Drill A — 2-minute explainer.** Explain **the visibility timeout** to a
colleague who has used SQS but never tuned it.

Hit all four beats:
1. What problem it solves
2. How it works
3. What surprises people — the six-times-function-timeout rule, and *why*
4. When the default is fine

The trap to prepare for: someone asks "why not just set it to 12 hours and stop
worrying?" Have the answer ready. (A genuinely failed message stays invisible
for 12 hours before anyone can retry it.)

**Drill B — elimination.**

> An application processes orders from an SQS standard queue with a Lambda
> consumer. Customers occasionally report being charged twice. The team needs
> to prevent duplicate charges **with the least operational overhead**.
>
> A. Switch to a FIFO queue with `MessageGroupId = orderId`
> B. Increase the visibility timeout to 12 hours
> C. Store a processed `transactionId` in DynamoDB and check it before charging
> D. Reduce `maxReceiveCount` to 1 so failed messages go straight to the DLQ

Say out loud why each wrong option fails, in full sentences, **before** picking
one. Note that A and C are both defensible — the phrase *least operational
overhead* is doing the work. Say why.

Model answers: [`practice/elimination-drills.md`](practice/elimination-drills.md)
