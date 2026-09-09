# AWS Serverless — English Study Edition

English versions of the AWS serverless notes, written to support a specific
practice routine rather than just to be read.

If you only want the reference material, read the docs and stop there. If you
are using these to build English fluency for work, follow the routine below.

---

## The routine

Each document ends with a **Practice** block containing four parts. Work
through them in order — they build on each other.

### 1. Read (15 min)

Every Practice block links to the matching page in the official AWS
documentation. Read it **in English, without translating**.

You will not understand every word. That is expected and it is not a problem.
Read for the shape of the argument: what is this page claiming, what does it
warn you about, what does it tell you to configure. Look up a word only when
the sentence collapses without it.

> Documentation URLs move. Every link is listed with its **page title** as
> well. If a link 404s, search the title on `docs.aws.amazon.com`.

### 2. Collect phrases

Each Practice block lists the phrases worth stealing from that page — the
collocations engineers actually say, not vocabulary-list words.

The point is the **collocation**, not the noun. You already know "message" and
"queue". What you may not produce naturally is "the message is **redelivered**"
or "the consumer **falls behind**" or "we **drain** the queue". Those are the
target.

Add anything you meet to [`phrasebook.md`](phrasebook.md).

### 3. Write (10 min)

Write **5–8 sentences** summarising what you read, using **at least 3 new
phrases**.

Rules that make this work:

- Write from memory, then check. Re-reading while you write turns it into
  copying.
- Explain a **decision**, not a definition. "SQS has a visibility timeout" is a
  definition and teaches you nothing. "We set the visibility timeout to six
  times the function timeout because the event source mapping needs headroom to
  retry" is a decision, and it forces real sentence structure.
- Do not translate from Vietnamese. If a sentence will not come out in English,
  the idea is not clear yet — go back to the page.

Keep the summaries in [`practice/writing-log.md`](practice/writing-log.md).

### 4. Speak (5 min)

Two drills, alternate between them:

**Drill A — the 2-minute explainer.** Explain one service to an imaginary
colleague. Not a lecture: a colleague who is competent but has not used this
service. Two minutes, out loud, recorded.

The structure that works:

1. What problem it solves (1 sentence)
2. How it works, roughly (3–4 sentences)
3. One thing that surprises people (1–2 sentences)
4. When you would *not* use it (1 sentence)

Point 4 is the one that separates fluent from memorised. Prepare it.

**Drill B — elimination out loud.** Take a practice exam question. Before
choosing the answer, say out loud why each wrong option is wrong.

Force yourself into full sentences. Not "no, wrong, this one" but "B is wrong
because provisioned concurrency is billed hourly whether or not the function
is invoked, so it does not address a cost-optimisation requirement."

That sentence pattern — *X is wrong because Y, so it does not Z* — is the exact
pattern you need in a design review. Drilling it on exam questions is cheap
practice for a conversation that is expensive to fumble.

Prompts: [`practice/speaking-prompts.md`](practice/speaking-prompts.md)
Drills: [`practice/elimination-drills.md`](practice/elimination-drills.md)

---

## Documents

| # | Document | Practice focus |
|---|----------|----------------|
| 00 | [API Gateway & API architecture](00-api-gateway-summary.md) | Comparing and recommending — hedged, qualified language |
| 01 | [Serverless Order API](01-serverless-order-api.md) | Describing a request flow end to end |
| 02 | [API Gateway REST & Cognito](02-api-gateway-and-cognito-authorizer.md) | Auth vocabulary; explaining a security boundary |
| 03 | [AppFlow & SaaS data backup](03-appflow-saas-data-backup.md) | Stating limitations without sounding negative |
| 04 | [Lambda concurrency & invocations](04-aws-lambda-functions.md) | Cause and effect; scaling behaviour |
| 05 | [Amazon SQS](05-amazon-sqs.md) | Trade-offs and cost reasoning |

Supporting material:

- [`phrasebook.md`](phrasebook.md) — collocations grouped by situation
- [`practice/writing-log.md`](practice/writing-log.md) — template + worked example
- [`practice/speaking-prompts.md`](practice/speaking-prompts.md) — 2-minute explainer prompts
- [`practice/elimination-drills.md`](practice/elimination-drills.md) — exam questions with model answers

---

## Relationship to the Vietnamese docs

These are **rewrites, not translations**. Same technical content, but the
sentences are built in English rather than carried across from Vietnamese, so
the phrasing is what an English-speaking engineer would actually produce.

Runnable Terraform lives in [`labs/`](../labs/) and is shared between both
language editions — infrastructure code does not need translating. The English
docs quote the parts worth discussing and link to the rest.

| English | Vietnamese |
|---------|-----------|
| [00](00-api-gateway-summary.md) | [docs/00](../docs/00-API-Gateway-Summary.md) |
| [01](01-serverless-order-api.md) | [docs/01](../docs/01-Example-Aws-Serverless-Order-API.md) |
| [02](02-api-gateway-and-cognito-authorizer.md) | [docs/02](../docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md) |
| [03](03-appflow-saas-data-backup.md) | [docs/03](../docs/03-Amazon-AppFlow-Backup-du-lieu-SaaS.md) |
| [04](04-aws-lambda-functions.md) | [docs/04](../docs/04-Aws-lambda-function.md) |
| [05](05-amazon-sqs.md) | [docs/05](../docs/05-Aws-sqs-queue.md) |

---

## One warning about the method

The reading and writing parts are comfortable. The speaking part is not, and it
is the one that actually moves fluency. If you skip a step, skip the reading —
not drill A.

Record yourself. You will hear filler words and hesitation you cannot notice
while speaking, and hearing them once is worth more than reading about them.
