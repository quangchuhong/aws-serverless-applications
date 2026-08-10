# Phrasebook

Collocations from across the documents, grouped by **situation** rather than by
service — because you retrieve them by situation when speaking.

The noun is rarely the problem. You know *queue*, *message*, *permission*. What
does not come automatically is the verb that belongs with it, and that is what
is listed here.

---

## Describing how a system behaves

| Phrase | Example |
|--------|---------|
| to poll a queue | "The consumer polls the queue continuously." |
| a message is redelivered | "The message is redelivered once the visibility timeout expires." |
| to fall behind | "The consumer has been falling behind since noon." |
| to keep up with | "One worker can't keep up with peak traffic." |
| to drain a queue | "We drained the queue before the migration." |
| in flight | "Messages in flight are invisible to other consumers." |
| to absorb a spike | "The queue absorbs traffic spikes." |
| to lag | "Processing lags, but nothing is lost." |
| to spin up / tear down | "Lambda spins up a new environment per concurrent request." |
| to fan out | "SNS fans out the event to three subscribers." |
| to compound | "Batch size and concurrency compound." |
| to land in | "Failed messages land in the DLQ." |
| to hit a service | "The read handler hits DynamoDB directly." |
| to sit in front of / behind | "The WAF sits in front of the gateway." |
| to front | "API Gateway fronts the Lambda functions." |
| to take effect | "The change takes effect immediately." |

---

## Failure and recovery

| Phrase | Example |
|--------|---------|
| to be throttled | "Requests beyond the limit are throttled." |
| to back off | "Lambda retries with exponential backoff." |
| to exhaust retries | "Once retries are exhausted, the event goes to the destination." |
| a poison message | "One poison message was failing the whole batch." |
| to reprocess | "Successful messages were being reprocessed unnecessarily." |
| a failure mode | "That failure mode is quiet and expensive." |
| to silently drop | "Failed messages are silently deleted." |
| to degrade gracefully | "The API degrades gracefully when the database is slow." |
| to blow up | "It blows up if the payload contains a float." (informal, common) |
| to be lost / to lose data | "Nothing is lost; processing just lags." |
| to recover from | "You need time to investigate before you recover from it." |
| to roll back | "Rolling back is just repointing the alias." |
| to mask an error | "The integration response was masking backend errors as 200." |
| to swallow an error | "That catch block swallows the exception." |
| to fail silently | "It fails silently — the config updates but never deploys." |
| to be blind to | "Retry logic is blind to a failure that arrives as a 200." |
| to surface something | "Nothing surfaces the failure to the caller." |
| to fire (an alarm) | "The alarm never fires because the metric stays at zero." |
| verbatim | "The error body reaches the client verbatim." |
| to pass through | "With a proxy integration the status code passes straight through." |

---

## Security

| Phrase | Example |
|--------|---------|
| to authenticate vs to authorize | "Cognito authenticates; the authorizer authorizes." |
| to issue a token | "Cognito issues three tokens on login." |
| to validate a token | "The authorizer validates the signature and expiry." |
| to expire | "The access token expires after an hour." |
| to revoke | "You can revoke a refresh token." |
| to enforce a policy | "The authorizer enforces access at the API layer." |
| to grant / to deny access | "The policy grants access to that method only." |
| least privilege | "The read handler follows least privilege." |
| to scope something to | "The key is scoped to one usage plan." |
| a security boundary | "The gateway is the security boundary." |
| to inherit permissions | "It would inherit write permissions it doesn't need." |
| to leak | "Tokens in URLs leak into browser history." |
| to be trivially readable | "An API key in a mobile binary is trivially readable." |
| to flag | "That's what an audit would flag." |

---

## Cost and scale

| Phrase | Example |
|--------|---------|
| to be billed for / billed as | "Billed for duration"; "each chunk is billed as one request." |
| to scale out vs scale up | "Scale out to more consumers, not up to bigger ones." |
| headroom | "The visibility timeout needs headroom for retries." |
| a ceiling / a hard limit | "Fifteen minutes is a hard ceiling." |
| to add up | "KMS charges add up at volume." |
| to account for | "Account for both settings when sizing the database." |
| at volume | "That's negligible at low traffic and significant at volume." |
| an order of magnitude | "Batching cuts requests by an order of magnitude." |
| to eat into | "Retries eat into your free tier." |
| negligible | "The cost is negligible for a test workload." |

---

## Making a recommendation

| Phrase | Example |
|--------|---------|
| to be a good fit for | "HTTP APIs are a good fit for most new services." |
| to lend itself to | "This pattern lends itself to multi-tenant systems." |
| to come at the cost of | "The features come at the cost of latency." |
| to buy you something | "Native integration buys you convenience, not capability." |
| to fall short | "It falls short when you need request validation." |
| to be overkill | "Apigee would be overkill here." |
| it comes down to | "It comes down to whether you need usage plans." |
| all things being equal | "All things being equal, prefer the HTTP API." |
| I'd lean towards | "I'd lean towards FIFO, unless throughput becomes a problem." |
| to default to | "Default to the Cognito authorizer." |
| preemptively | "Don't reach for a Lambda authorizer preemptively." |
| the trade-off is | "The trade-off is eventual consistency." |

---

## Disagreeing and correcting

Hardest register to get right in a second language. Too blunt sounds rude; too
soft and nobody registers that you objected.

| Phrase | Strength | Example |
|--------|----------|---------|
| "That's close, but the important distinction is…" | gentle | correcting a premise |
| "I'd push back on that slightly." | mild | standard in a review |
| "That works, but it's not what you want, because…" | mild | the "works but wrong" case |
| "I don't think that holds, because…" | medium | disagreeing with reasoning |
| "That would break X." | direct | concrete consequence |
| "That's going to bite us later." | direct, informal | predicting future pain |
| "I'd strongly advise against it." | strong | reserve this one |

Two patterns worth memorising outright:

- **"X is wrong because Y, so it doesn't Z."** The elimination pattern. Exactly
  what a design review needs.
- **"X is not Y in the sense that Z is."** Precise denial rather than a flat
  no. Lets you say "not really" without sounding unhelpful.

---

## Grammar traps for Vietnamese speakers

**Articles.** Vietnamese has none, and this is the most persistent tell. When
you name a component of a system you are describing, it is almost always *the*:
*the write path*, *the consumer*, *the queue*. A first mention of a new
countable thing takes *a*: *we added a dead-letter queue*.

**a / an by sound, not spelling.** *A user*, *a UUID*, *a URL*, *a usage plan*
(the /j/ sound is a consonant). But *an hour*, *an S3 bucket*, *an IAM role*
(the letters are read *ess*, *eye*).

**Uncountable nouns** take no plural: *traffic*, *latency*, *throughput*,
*backlog*, *infrastructure*, *feedback*. Never *"the backlogs are growing"* or
*"these infrastructures"*.

**scale out ≠ scale up.** Out = more instances. Up = bigger instances. Using
the wrong one in a design discussion is noticed.

**billed for + noun, billed as + category.** *Billed for duration*; *billed as
one request*.

**up front (adverb, two words)** versus **upfront (adjective, one word)**:
*more work up front*, but *an upfront cost*.

**Present simple for how systems behave.** *"The consumer polls the queue"* —
not *"is polling"* — when describing normal behaviour. Use the continuous only
for something happening right now: *"the consumer is falling behind"* (it is,
currently).
