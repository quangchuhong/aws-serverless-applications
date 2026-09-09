# AWS Lambda — Concurrency, Invocations and Deployment

Vietnamese version: [`docs/04-Aws-lambda-function.md`](../docs/04-Aws-lambda-function.md)
Runnable lab: [`labs/04-lambda-concurrency/`](../labs/04-lambda-concurrency/)

---

## 1. What Lambda is

A serverless compute service: you supply code, AWS runs it without you managing
servers, and it scales automatically with the number of concurrent requests.
You are billed for invocations and for duration multiplied by memory.

> **Runtimes expire.** AWS deprecates runtimes on a schedule that tracks the
> upstream language lifecycle. Once a runtime reaches end of support you cannot
> create new functions on it, then you cannot update existing code, and finally
> it stops receiving security patches. `nodejs18.x` reached end of support in
> September 2025 — this lab uses `nodejs22.x`. Check the *Lambda runtimes* page
> before starting anything new.

---

## 2. Three ways a function gets invoked

The invocation model determines retry behaviour, error handling, and where
failures end up. Almost every Lambda surprise traces back to someone assuming
the wrong model.

### 2.1. Synchronous

The caller waits for the result. API Gateway, Application Load Balancer, and
direct SDK calls work this way.

If the function fails, **the caller gets the error immediately**. Lambda does
not retry. Retrying is the client's responsibility.

### 2.2. Asynchronous

The caller hands over the event and does not wait. S3, SNS and EventBridge work
this way.

Lambda queues the event internally and **retries automatically** — twice by
default. If every attempt fails, the event goes to a configured destination, or
is discarded if there is none.

### 2.3. Event source mapping (poll-based)

Lambda polls the source itself: SQS, Kinesis, DynamoDB Streams, Kafka. Each
batch of records becomes one invocation.

Retries here are governed by **the source**, not by Lambda. For SQS that means
the visibility timeout and `maxReceiveCount`.

---

## 3. Concurrency

Concurrency is the number of invocations running at the same time for a
function. When requests arrive faster than they complete, Lambda creates more
execution environments to run them in parallel.

### 3.1. Unreserved account concurrency

A shared pool per account per Region. Every function draws from it, minus
whatever has been reserved elsewhere.

### 3.2. Reserved concurrency

`reserved_concurrent_executions` does two things at once, and the second is the
one people forget:

1. It **caps** the function at that many concurrent executions.
2. It **reserves** that capacity — no other function in the account can use it.

So reserving 100 for a function protects it, but also removes 100 from the pool
available to everything else.

### 3.3. Provisioned concurrency

Keeps N execution environments initialised and warm for a specific version or
alias. This is what removes cold starts for latency-sensitive APIs.

Two constraints:

- It attaches to a **version or alias**, never to `$LATEST`.
- It is **billed hourly whether or not the function is invoked**. This is the
  single most expensive mistake in a practice environment — leave it on
  overnight and you will notice.

---

## 4. Throttling and retries

**Throttling** (`Rate Exceeded` / `TooManyRequests`) happens when you exceed
either the account concurrency limit or the function's reserved concurrency.

What happens next depends entirely on the invocation model:

| Model | On throttle | On error |
|-------|-------------|----------|
| Synchronous | Caller gets an error immediately | Caller gets the error; no retry |
| Asynchronous | Lambda retries with backoff | Retries (default 2), then destination |
| Event source mapping (SQS) | Batch stays in the queue | Batch is redelivered after visibility timeout |

---

## 5. Dead-letter queues versus event destinations

Three different mechanisms are all casually called "the DLQ". They are not the
same thing.

**Lambda's dead-letter queue** (`dead_letter_config`) — the older mechanism.
Applies to asynchronous invocations only. Sends the **original event payload**
with no error information. AWS now recommends destinations instead.

**Event destinations** (`function_event_invoke_config`) — the current
mechanism. Configures `on_failure` and `on_success` targets, which can be SQS,
SNS, another Lambda, or EventBridge. The payload includes the **original event
plus request/response context plus the error message**, which makes debugging
dramatically easier.

**An SQS dead-letter queue** (redrive policy) — a property of the *queue*, not
of the function. Applies when Lambda consumes SQS through an event source
mapping. Messages move there after `maxReceiveCount` unsuccessful receives.

> The lab uses an `on_failure` destination pointing at an SQS queue. That is an
> **event destination**, despite the queue being named `async-s3-lambda-dlq`.

---

## 6. SQS to Lambda: how the numbers work

### 6.1. The mechanism

```text
[Producer] → [SQS Queue] → [Event Source Mapping] → [Lambda Function]
```

The event source mapping polls the queue, groups messages according to
`batch_size`, and invokes the function once per batch.

### 6.2. Batch size and concurrency multiply

This catches people out. The two settings compound:

| `batch_size` | Max concurrent executions | Messages in flight |
|--------------|---------------------------|--------------------|
| 1 | 5 | 5 |
| 5 | 5 | **25** |
| 10 | 10 | **100** |

Five executions each holding a batch of five means twenty-five messages are
being processed at once, even though only five invocations are running.

If a downstream system can only handle N concurrent operations, you must
account for both numbers.

### 6.3. The controls

- **`batch_size`** — messages per invocation.
- **`reserved_concurrent_executions`** — maximum simultaneous invocations.
- **`scaling_config.maximum_concurrency`** on the event source mapping — caps
  concurrent pollers for that queue specifically. Prefer this over reserved
  concurrency when you only want to limit *this* queue's consumption, because
  it does not remove capacity from the account pool.

To process at most N messages at a time: `batch_size = 1` and concurrency
limited to N.

### 6.4. Partial batch failures

By default, if an invocation throws, **the entire batch returns to the queue** —
including messages that were processed successfully. They get processed again.

Set `function_response_types = ["ReportBatchItemFailures"]` and return the
identifiers of only the messages that actually failed:

```python
return {"batchItemFailures": [{"itemIdentifier": message_id}]}
```

Without this, a single poison message forces repeated reprocessing of
everything alongside it.

---

## 7. Versions and aliases

### 7.1. Versions

Publishing creates an **immutable** version: `my-func:1`, `my-func:2`. Code and
configuration are frozen at that point and cannot change.

`$LATEST` always points at the most recent unpublished code and changes every
time you update the function.

### 7.2. Aliases

An alias is a **named pointer** to a specific version. `prod → v2`, `dev → v3`.

An alias behaves like an independent function: it has its own ARN, its own
permissions, and provisioned concurrency attaches to it.

### 7.3. Why this matters — rollback

```text
        publish v1      publish v2      publish v3
             ↓               ↓               ↓
           [ v1 ]          [ v2 ]          [ v3 ]
                             ↑               ↑
                    alias: prod       alias: dev
                             ↑               ↑
              API Gateway (prod)   API Gateway (dev)
```

Clients call the **alias**, never a version directly. Releasing means
repointing `prod` from v2 to v3. Rolling back means repointing it back — which
takes effect immediately, with no redeploy and no rebuild.

---

## 8. Deployment: CLI versus Terraform

### 8.1. Comparison

| | AWS CLI / SDK (imperative) | Terraform (declarative) |
|---|---------------------------|--------------------------|
| Scope | Function code and config only | All infrastructure: IAM, triggers, API GW, queues, alarms |
| State | None — you track it yourself | State file; `plan` previews changes |
| First run | You choose `create-function` vs `update-function-code` | `apply` figures it out |
| Teardown | Delete each resource manually | `terraform destroy` |
| Drift | Console edits go unnoticed | `plan` detects drift |
| Speed | Seconds | Slower — refreshes state |

### 8.2. Which to use

**CLI/SDK** for the code-deployment step inside a pipeline, and for quick
experiments. **Terraform** for provisioning and for anything with more than one
environment.

Most teams use both: Terraform creates the function, role and triggers once,
then the pipeline runs `aws lambda update-function-code --publish` on every
commit because it is far faster than a full apply. If you do this, stop
Terraform from fighting the pipeline:

```hcl
lifecycle {
  ignore_changes = [filename, source_code_hash, last_modified]
}
```

### 8.3. A packaging detail worth knowing

The Node.js runtime decides module type from the file extension and the `type`
field in `package.json`:

| Extension | Module type |
|-----------|-------------|
| `.mjs` | Always ES module |
| `.cjs` | Always CommonJS |
| `.js` | Depends on `package.json`; defaults to CommonJS |

If you zip a single `.js` file with no `package.json` and use
`export const handler`, it fails at runtime. Use `.mjs`. The handler string
stays `lambda_sync.handler` — no extension.

---

## 9. Monitoring

### 9.1. Logs

Every function writes to `/aws/lambda/<function_name>`, provided its role has
the basic execution policy. Each execution environment gets its own log stream.

```bash
aws logs tail "/aws/lambda/sync-api-lambda" --since 5m
```

You will see `START RequestId`, your own output, `END`, and a `REPORT` line
with duration, billed duration, memory size and max memory used. The `REPORT`
line is where you find out you allocated 1024 MB and are using 90.

> Log groups created implicitly by Lambda **retain logs forever**. Create them
> explicitly in Terraform with `retention_in_days` set.

### 9.2. Metrics

| Metric | Read it for |
|--------|-------------|
| `Invocations` | Call volume, success or failure |
| `Errors` | Failed invocations |
| `Throttles` | Concurrency ceiling being hit |
| `ConcurrentExecutions` | How parallel you actually are |
| `Duration` | Latency — look at p50, p95, p99, not the average |
| `ProvisionedConcurrencyUtilization` | Whether you are paying for warm capacity you do not use |

The average duration hides everything interesting. Cold starts live in the
tail, so look at p99.

---

## Practice

### Read

| Page title | URL |
|------------|-----|
| *Lambda function scaling* | https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html |
| *Asynchronous invocation* | https://docs.aws.amazon.com/lambda/latest/dg/invocation-async.html |
| *Using Lambda with Amazon SQS* | https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html |
| *Lambda function versions* | https://docs.aws.amazon.com/lambda/latest/dg/configuration-versions.html |
| *Lambda runtimes* | https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html |

Read the scaling page first. It explains burst behaviour, which this document
summarises but does not fully cover.

### Key phrases

| Phrase | Used like this |
|--------|----------------|
| **to spin up / to tear down** | "Lambda spins up a new execution environment for each concurrent request." |
| **a cold start** | "Provisioned concurrency eliminates cold starts for the first N requests." |
| **to warm up / to keep warm** | "Provisioned concurrency keeps five environments warm." |
| **to be throttled** | "Requests beyond the reserved concurrency are throttled." |
| **to back off** | "Lambda retries with exponential backoff." |
| **to exhaust retries** | "Once retries are exhausted, the event goes to the destination." |
| **to fan out** | "SNS fans out the event to three subscribers." |
| **to compound** | "Batch size and concurrency compound — five batches of five is twenty-five messages." |
| **a poison message** | "One poison message was forcing the whole batch to be reprocessed." |
| **to reprocess** | "Successfully handled messages were being reprocessed unnecessarily." |
| **to repoint an alias** | "Rolling back is just repointing the alias at the previous version." |
| **to take effect** | "The change takes effect immediately — no redeploy needed." |
| **to account for** | "You have to account for both settings when sizing the downstream system." |
| **to trace back to** | "Most Lambda surprises trace back to assuming the wrong invocation model." |
| **in the tail** | "Cold starts live in the tail, so look at p99." |

Grammar note: **"to be billed for"** takes a noun, **"to be billed as"** takes a
category. *"You are billed for duration"* but *"each chunk is billed as one
request"*. Mixing them sounds wrong immediately to a native speaker.

### Write

Write **5–8 sentences**, using **at least 3** phrases from the table.

Prompt: *A colleague set `batch_size = 10` and `reserved_concurrent_executions
= 50` on a Lambda that writes to an RDS instance with a connection limit of
100. Explain what will go wrong and what you would change.*

The arithmetic is the point — say the number out loud in your writing. Then say
which control you would reach for and why you would prefer it to the
alternative.

### Speak

**Drill A — 2-minute explainer.** Explain **provisioned concurrency** to a
colleague who is about to enable it on every function in the account.

Structure:
1. What problem it solves (cold starts)
2. How it works, and why it attaches to an alias rather than `$LATEST`
3. What surprises people — hourly billing regardless of traffic
4. When *not* to use it

Point 4 is the whole conversation here. Your colleague is about to make an
expensive mistake and you need to say so without being dismissive. Practise the
sentence you would actually use.

**Drill B — elimination.**

> A synchronous API backed by Lambda has a p99 latency of 3 seconds, while p50
> is 80 ms. Traffic is steady during business hours and near zero overnight.
> Which change best addresses the p99, at the lowest cost?
>
> A. Increase the function's memory from 512 MB to 3008 MB
> B. Enable provisioned concurrency on the `prod` alias, always on
> C. Enable provisioned concurrency with scheduled scaling for business hours
> D. Increase reserved concurrency

Say out loud why each wrong answer fails. Pay attention to what the gap between
p50 and p99 tells you — name the cause before you evaluate the options.

Model answers: [`practice/elimination-drills.md`](practice/elimination-drills.md)
