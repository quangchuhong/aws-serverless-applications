# Speaking Prompts — the 2-Minute Explainer

Explain one service to an imaginary colleague. Competent engineer, has not used
this particular service. Two minutes, out loud, recorded.

---

## The structure

1. **What problem it solves** — 1 sentence
2. **How it works, roughly** — 3–4 sentences
3. **What surprises people** — 1–2 sentences
4. **When you would *not* use it** — 1 sentence

Point 4 separates understanding from memorising. Anyone can recite what a
service does; knowing where it stops being the right answer is what makes you
sound like you have used it. **Always prepare point 4.**

## Rules

- **Two minutes.** Time it. Running long is the most common failure and it
  means you have not decided what to cut.
- **Record it.** You cannot hear your own filler words while speaking. Listen
  once, note one thing, move on. Do not transcribe.
- **No script.** Bullet points are fine; sentences are not. Reading aloud
  trains nothing.
- **Repeat the same prompt after a week.** The second attempt is where the
  improvement shows.

## What to listen for

| Problem | Fix |
|---------|-----|
| "Um", "uh", long pauses mid-sentence | Pause **between** sentences instead. Silence is fine; filler is not. |
| Every sentence starts "And then…" | Vary connectors: *from there*, *at that point*, *meanwhile*, *once that happens*. |
| Rising intonation on statements | Statements fall at the end. Rising sounds uncertain. |
| Ran to 3+ minutes | You explained the *how* before the *why*. Lead with the problem. |
| Could not answer the follow-up | You memorised a description instead of understanding the trade-off. |

---

## Prompts

Ordered roughly by difficulty.

### Level 1 — single concept

1. **SQS visibility timeout.** Follow-up: *"Why not just set it to 12 hours?"*
2. **The difference between a Lambda version and an alias.** Follow-up: *"Why not just redeploy to roll back?"*
3. **Long polling.** Follow-up: *"Does waiting longer cost more?"*
4. **What an API key gives you and what it does not.** Follow-up: *"So it's useless?"*
5. **Standard versus FIFO queues.** Follow-up: *"Isn't FIFO always safer?"*

### Level 2 — a mechanism with moving parts

6. **Provisioned concurrency.** Follow-up: *"Should we turn it on everywhere?"*
7. **The three Cognito tokens.** Follow-up: *"Can I just use the ID token for everything?"*
8. **Dead-letter queues, and why you don't consume them.** Follow-up: *"But how do I know something's in there?"*
9. **Partial batch failures in an SQS event source mapping.** Follow-up: *"Can't I just catch all exceptions?"*
10. **REST API versus HTTP API in API Gateway.** Follow-up: *"Why would anyone still pick REST?"*

### Level 3 — a whole design

11. **The order API architecture** (doc 01), end to end including the failure path. Follow-up: *"Why not write to DynamoDB directly?"*
12. **Where WAF, Cognito, API Gateway and the backend each sit**, and what each is responsible for. Follow-up: *"Doesn't Cognito already protect us?"*
13. **How you would size Lambda concurrency** for a queue consumer writing to a database with a connection limit. Follow-up: *"Why not just raise the connection limit?"*
14. **Why AppFlow is not a backup tool**, to a project manager who was told it was. Follow-up: *"So what do we tell the auditor?"*
15. **How you would cost out an SQS workload** before building it. Follow-up: *"Where's the biggest thing people get wrong?"*

### Level 4 — no preparation

Pick one at random and start speaking within ten seconds. This is the real
skill; the earlier levels are rehearsal for it.

16. Explain **eventual consistency** to a frontend developer who just filed a bug about a 404.
17. Explain **least privilege** to someone who wants to attach `AdministratorAccess` "just for now".
18. Explain **why a runtime deprecation matters** to a manager who asks why you are spending a sprint on it.
19. Explain **cold starts** to someone who says "serverless is slow".
20. Explain **why the DLQ is empty but messages are still disappearing** — you have five minutes of an incident call.

---

## A note on 20

That one is different on purpose. It is not an explanation, it is thinking out
loud under pressure, and the English you need is different: hedging
(*"my current theory is…"*), revising (*"actually, that doesn't fit, because…"*),
and asking for information (*"can someone check whether…"*).

If you can do 20 comfortably, you can hold your own in an incident call, which
is the hardest routine English situation in this job.
