# Elimination Drills

Read the question. **Before choosing an answer, say out loud why each wrong
option is wrong** — in full sentences.

The target pattern is:

> **"B is wrong because Y, so it doesn't Z."**

Not "no, wrong, this one." The full sentence is the exercise. It is the same
sentence you need in a design review, and drilling it on exam questions is
cheap practice for a conversation where fumbling is expensive.

**Work through the drill before reading the model answer.** Reading first
turns this into comprehension practice, which you do not need.

---

## Drill 1 — Duplicate charges (doc 05)

> An application processes orders from an SQS standard queue with a Lambda
> consumer. Customers occasionally report being charged twice. The team needs
> to prevent duplicate charges **with the least operational overhead**.
>
> A. Switch to a FIFO queue with `MessageGroupId = orderId`
> B. Increase the visibility timeout to 12 hours
> C. Store a processed `transactionId` in DynamoDB and check it before charging
> D. Reduce `maxReceiveCount` to 1 so failed messages go straight to the DLQ

<details>
<summary>Model answer</summary>

**Answer: C.**

**B is wrong because** a longer visibility timeout only changes *when* a
message is redelivered, not *whether* it is. It also makes things worse: a
genuinely failed message would now sit invisible for twelve hours before anyone
could retry it.

**D is wrong because** `maxReceiveCount` controls how many failures are
tolerated before a message is set aside. It does nothing about a message that
is processed *successfully* twice, and setting it to 1 means any transient
error sends the order to the dead-letter queue immediately.

**A is the interesting one.** It looks correct, and this is the trap. FIFO's
exactly-once guarantee is about **deduplicating sends** within a five-minute
window — it stops the same message being *enqueued* twice. It does not stop a
message being *redelivered* to the consumer after a visibility timeout expires
mid-processing, which is the more likely cause of a double charge here. So A
addresses a different failure than the one described, and it costs you a queue
migration and lower throughput.

**C is correct because** it makes the charge itself idempotent. The consumer
records the transaction ID before charging and checks it first, so however many
times the message arrives, the customer is charged once. It is the only option
that survives redelivery, and redelivery in a standard queue is guaranteed
behaviour, not a bug you can configure away.

**The phrase that does the work:** *least operational overhead* is a distractor
here — the real reason A loses is that it doesn't solve the problem, not that
it's more work.
</details>

---

## Drill 2 — Latency tail (doc 04)

> A synchronous API backed by Lambda has a p99 latency of 3 seconds, while p50
> is 80 ms. Traffic is steady during business hours and near zero overnight.
> Which change best addresses the p99, at the lowest cost?
>
> A. Increase the function's memory from 512 MB to 3008 MB
> B. Enable provisioned concurrency on the `prod` alias, always on
> C. Enable provisioned concurrency with scheduled scaling for business hours
> D. Increase reserved concurrency

<details>
<summary>Model answer</summary>

**Answer: C.**

**Name the cause first:** a p50 of 80 ms with a p99 of 3 seconds is a
bimodal distribution, not a slow function. Most requests are fast; a few pay a
large fixed penalty. That is the signature of **cold starts**. Anything that
does not address initialisation is not addressing this problem.

**A is wrong because** more memory reduces *execution* time — it does not
remove the cold start. The p50 would improve slightly, which is not what was
asked, and you would pay more for every single invocation to fix the 1% of
requests that are slow.

**D is wrong because** reserved concurrency is a **cap**, not a warm pool. It
limits how many executions may run at once and reserves that capacity from the
account. It has no effect on initialisation latency whatsoever.

**B is wrong because** it works but wastes money. Provisioned concurrency is
billed hourly whether or not the function is invoked, so "always on" means
paying full price overnight when traffic is near zero. The question explicitly
asks for the lowest cost.

**C is correct because** it eliminates cold starts during the hours that have
traffic and stops paying during the hours that do not. It directly matches the
traffic pattern described.

**Pattern to reuse:** when a question gives you both p50 and p99, the gap is
the question. Say what the gap means before evaluating any option.
</details>

---

## Drill 3 — Gateway choice (doc 00)

> A company needs a public API with per-customer usage quotas, request payload
> validation, and response caching. Which is most appropriate?
>
> A. HTTP API with a Lambda authorizer
> B. REST API with usage plans and API keys
> C. HTTP API with a JWT authorizer and CloudFront in front
> D. Application Load Balancer with Lambda targets

<details>
<summary>Model answer</summary>

**Answer: B.**

**Count the requirements first:** three of them — quotas, validation, caching.
An option has to satisfy all three.

**A is wrong because** HTTP APIs have no usage plans and no API keys, so
per-customer quotas are impossible. They also lack request validation. A Lambda
authorizer handles authorization, which was not one of the three requirements.

**C is wrong because** it satisfies exactly one requirement. CloudFront does
give you response caching. It does not give you per-customer quotas, and it
does not validate request payloads — it is a CDN, not an API gateway. This is
the option worth dwelling on, because it is partially right, and partially
right is how these questions are built.

**D is wrong because** an ALB provides none of the three. It routes traffic. It
has no concept of a usage plan, a request model, or a response cache.

**B is correct because** REST APIs are the only option that supports all three
natively: usage plans with quotas and throttling, request validation against a
model, and a per-stage cache with per-method TTL.

**Say this at the end:** "and the trade-off is that REST APIs cost more and add
latency compared to HTTP APIs — but the requirements rule HTTP API out." Naming
what you gave up is what makes it sound like a real recommendation.
</details>

---

## Drill 4 — Batch reprocessing (doc 01)

> A Lambda function consumes an SQS queue with `batch_size = 10`. When one
> message in a batch fails, all ten are reprocessed. Which change fixes this
> with the least disruption?
>
> A. Set `batch_size = 1`
> B. Configure `ReportBatchItemFailures` and return `batchItemFailures`
> C. Catch all exceptions in the handler so the invocation never fails
> D. Increase `maxReceiveCount` so messages get more attempts

<details>
<summary>Model answer</summary>

**Answer: B.**

**C is wrong, and it is the dangerous one.** It does make the symptom
disappear: if the handler never throws, the invocation always succeeds and
nothing is reprocessed. But the event source mapping treats success as "every
message in this batch was handled" and **deletes all ten**, including the one
that failed. You have converted a visible retry problem into silent data loss.
Say that consequence out loud — "it doesn't fix the failure, it hides it" — because
that is the sentence a reviewer needs to hear.

**D is wrong because** `maxReceiveCount` governs how many times a message may
be received before moving to the DLQ. Raising it means the batch is reprocessed
*more* times, not fewer. It makes the described problem worse.

**A is wrong in context.** It genuinely fixes the problem — one message per
invocation means a failure affects only that message. But it multiplies your
invocation count by ten, raising cost and reducing throughput. The question
asks for the *least disruption*, and reshaping the consumer's performance
profile is more disruptive than the alternative.

**B is correct because** it addresses the failure precisely: the handler
returns the IDs of only the messages that failed, and just those return to the
queue. Batch size, throughput and cost are unchanged.

**One thing worth adding:** B requires **both** halves — the
`function_response_types` setting on the event source mapping *and* the return
value from the handler. Returning `batchItemFailures` without configuring the
mapping is silently ignored, which produces exactly the same data loss as
option C.
</details>

---

## Drill 5 — Deactivated users (doc 02)

> A mobile app authenticates users through a Cognito user pool. The API must
> reject requests from users who have been deactivated in the company's
> internal database, even if their token is still valid. What should the team
> implement?
>
> A. A Cognito user pool authorizer on each method
> B. A Lambda authorizer that validates the JWT and checks user status
> C. Shorter token expiry, set to five minutes
> D. An API key per user, revoked on deactivation

<details>
<summary>Model answer</summary>

**Answer: B.**

**A is wrong because** a Cognito authorizer validates the token itself —
signature, issuer, audience, expiry, and optionally OAuth scopes. It has no
mechanism for consulting an external system. A deactivated user holding an
unexpired, correctly signed token would pass every check it performs.

**C is wrong for two reasons, and both are worth saying.** First, it narrows
the window but never closes it — a user deactivated one minute after issuance
still has four minutes of access, and the requirement says reject, not reject
eventually. Second, five-minute expiry forces the app to refresh constantly,
which adds load and drains battery on mobile. It trades a real cost for a
partial fix.

**D is wrong because** API Gateway API keys identify an *application*, not a
person. They are not designed for per-user issuance, and managing one key per
user means a key-lifecycle problem on top of the identity system you already
have. It also does not authenticate anyone — the key says which client is
calling, not who the user is.

**B is correct because** a Lambda authorizer can do both things: verify the JWT
against the pool's public keys, then look the user up in the internal database
and deny if they are deactivated. It is the only option that can consult state
outside the token.

**Add the caveat** — it shows you have actually operated this: "the authorizer
result is cached by default, so set the TTL deliberately. Cache too long and
you have reintroduced the same window you were trying to close."
</details>

---

## Drill 6 — Compliance retention (doc 03)

> A company must retain three years of Zendesk ticket data for compliance
> auditing, queryable on demand, at the lowest cost. Which approach fits best?
>
> A. AppFlow scheduled to S3 as Parquet, queried with Athena
> B. AppFlow to Redshift, kept in a provisioned cluster
> C. A Lambda calling the Zendesk API, writing JSON to S3 Glacier Deep Archive
> D. Zendesk's own export, downloaded monthly and stored on-premises

<details>
<summary>Model answer</summary>

**Answer: A.**

**Name the constraints first:** *queryable on demand* and *lowest cost*. Each
one eliminates a different option, and saying which is which is the exercise.

**C is wrong because of "on demand".** Glacier Deep Archive is the cheapest
storage on the list, so it wins on cost and loses on access — retrieval takes
hours. Data you have to wait half a day for is not queryable on demand. It
would be the right answer if the requirement were "retain cheaply, retrieve
rarely."

**B is wrong because of "lowest cost".** A provisioned Redshift cluster runs
and bills continuously, whether or not an auditor is asking anything. For data
queried occasionally over three years, you would be paying constantly for
capacity used almost never.

**D is wrong on both counts** and adds a third problem: a manual monthly
download is an operational burden and a compliance risk in itself, because the
control depends on somebody remembering.

**A is correct because** S3 storage is cheap, Parquet compresses well and is
columnar, and Athena is billed per query rather than per hour — so idle years
cost almost nothing while an audit is still answerable immediately. Partitioning
by date reduces the data scanned per query, which is what Athena actually
charges for.

**The general shape:** when a question pairs "on demand" with "lowest cost",
it is testing whether you can tell cheap-and-slow apart from cheap-and-ready.
</details>

---

## Writing your own

Once you have worked through these, the more valuable exercise is building
drills from your own practice exams.

A good question has:

- **One clearly correct answer.**
- **One tempting wrong answer** that solves a *different* problem (drill 1's
  option A, drill 3's option C).
- **One answer that works but violates a stated constraint** (drill 2's option
  B — it fixes the latency, it just costs too much).
- **One that makes the problem worse** (drill 4's option D).

Learning to *spot* which category each distractor belongs to is most of the
skill — in the exam and in a design review, where the tempting-wrong-answer is
usually the one someone has already started building.
