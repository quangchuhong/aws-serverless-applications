# Writing Log

Five to eight sentences after each reading session, using at least three new
phrases. Keep them here so you can look back and see the phrases you have
actually started using.

---

## How to make this work

**Write from memory, then check.** If the page is open while you write, you are
copying. Close it, write, then reopen and correct.

**Explain a decision, not a definition.** "SQS has a visibility timeout" is a
definition — it teaches you nothing and needs no real grammar. "We set the
visibility timeout to six times the function timeout because the event source
mapping needs headroom to retry" is a decision, and it forces subordinate
clauses, causal connectors and precise verbs. That is where the learning is.

**Don't translate.** If a sentence will not come out in English, the idea is
not clear yet. Go back to the page rather than composing in Vietnamese and
converting.

**Mark your target phrases in bold** so you can see at a glance whether you hit
three, and so re-reading old entries reinforces them.

**Keep the mistakes.** Do not silently fix an old entry. Add a correction
underneath. The comparison is the useful part.

---

## Template

```markdown
## YYYY-MM-DD — <topic>

**Read:** <page title + URL>

**Target phrases:** phrase one, phrase two, phrase three

<Your 5–8 sentences.>

**Corrections:**
- <what you got wrong, and the fix>
```

---

## Worked example

## 2026-08-01 — SQS visibility timeout

**Read:** *Amazon SQS visibility timeout* —
https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html

**Target phrases:** to be redelivered, headroom, to fall behind

When a consumer receives a message, SQS hides it from other consumers for the
duration of the visibility timeout. If the consumer deletes the message before
that window closes, it disappears; otherwise **the message is redelivered** and
its receive count goes up. This is why the timeout has to be longer than the
worst-case processing time rather than the average — the average tells you
nothing about the slow requests. For a Lambda event source mapping AWS
recommends at least six times the function timeout, because the mapping needs
**headroom** for its own internal retries. Setting it too low is worse than
setting it too high: messages get processed twice and reach the dead-letter
queue even though the code is fine. I had assumed a low value was safer because
it recovers faster from a crashed consumer, but that only matters if consumers
actually crash often, and meanwhile every slow request is punished. The signal
that this is misconfigured is a rising receive count while the error rate stays
flat — the consumer is not failing, it is just **falling behind** the timeout.

**Corrections:**
- Wrote "the message will be redeliver" → **redelivered** (passive, past
  participle).
- Wrote "more longer than" → **longer than**. No *more* with a comparative
  that already has *-er*.
- Wrote "informations" → **information** is uncountable.

---

*(Add your entries below.)*
