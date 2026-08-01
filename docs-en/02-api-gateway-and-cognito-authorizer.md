# API Gateway REST API & Cognito Authorizer

Vietnamese version: [`docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md`](../docs/02-Aws-Api-gateway-core-and-Cognito-authorizer.md)
Runnable lab: [`labs/02-api-gateway-cognito/`](../labs/02-api-gateway-cognito/)

---

## 1. What this builds

One REST API demonstrating three different integration types, protected by two
independent mechanisms.

| Endpoint | Integration | Protected by |
|----------|-------------|--------------|
| `POST /orders` | Lambda, non-proxy, with a VTL mapping template | API key |
| `POST /orders/{id}/notify` | AWS service integration → SNS `Publish` | API key |
| `GET /orders/{id}` | HTTP backend (httpbin.org) | API key **and** Cognito JWT |

The point of the third row is that API keys and JWTs answer **different
questions**, and a serious API usually wants both. More on that in §5.

---

## 2. Resources, methods and integrations

A **resource** is a path segment: `/orders`, `/orders/{id}`,
`/orders/{id}/notify`. A **method** is an HTTP verb on a resource, and it is
where you configure `authorization`, `api_key_required` and expected request
parameters. An **integration** is how the gateway reaches the backend.

(HTTP APIs and WebSocket APIs collapse resource and method into a single
**route** — `GET /orders/{id}`.)

### Integration types

**Lambda proxy (`AWS_PROXY`)** — the entire HTTP request is passed to the
function as a structured event, and the function's return value must describe
the whole HTTP response. Almost always what you want.

**Lambda non-proxy (`AWS`)** — you write mapping templates to reshape the
request going in and the response coming out. The function receives exactly
what your template produces. Used here specifically to demonstrate templates.

**HTTP / HTTP proxy** — forward to any HTTP backend, with or without
transformation.

**AWS service integration** — call an AWS API directly with no Lambda in
between: SNS `Publish`, SQS `SendMessage`, DynamoDB `GetItem`, Step Functions
`StartExecution`. Requires an IAM role the gateway can assume.

**Mock** — return a canned response with no backend at all. Useful for stubs
and for CORS preflight.

---

## 3. Mapping templates (VTL)

Templates let you transform the request before it reaches the backend and the
response before it reaches the client. The language is Velocity (VTL).

### Request transformation

The client sends:

```json
{
  "customer": { "id": "u-123", "name": "Alice" },
  "items": [{ "sku": "SKU-1", "qty": 2 }],
  "meta": { "source": "mobile" }
}
```

The template flattens and renames it for the function:

```velocity
#set($inputRoot = $input.path('$'))
{
  "orderId": "$context.requestId",
  "customerId": "$inputRoot.customer.id",
  "items": [
    #foreach($item in $inputRoot.items)
      { "sku": "$item.sku", "quantity": $item.qty }#if($foreach.hasNext),#end
    #end
  ],
  "source": "$inputRoot.meta.source"
}
```

Note `qty` becoming `quantity`, and `orderId` being injected from
`$context.requestId` — the client never supplied it.

The useful building blocks: `$input.path('$')` and `$input.json('$')` for the
body, `$context.*` for request metadata, `$util.urlEncode()` and
`$util.escapeJavaScript()` for escaping.

### Two mistakes that are easy to make

**Building an AWS service call as JSON.** The SNS integration URI
`arn:aws:apigateway:<region>:sns:action/Publish` targets an AWS **Query
protocol** API. SNS reads `Action=Publish&TopicArn=...&Message=...`, not a JSON
body. Sending JSON produces a `MissingParameter` error. You must override the
content type:

```hcl
request_parameters = {
  "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
}

request_templates = {
  "application/json" = <<-EOF
    #set($inputRoot = $input.path('$'))
    #set($payload = "{""orderId"":""$input.params('id')"",""notificationType"":""$inputRoot.type""}")
    Action=Publish&TopicArn=$util.urlEncode('${aws_sns_topic.order_notifications.arn}')&Message=$util.urlEncode($payload)
  EOF
}
```

**Nesting quotes wrongly.** VTL has no JSON object literal you can drop inside
an already-open string. Escape a double quote by **doubling** it (`""`), as
above. And run everything going into a query string through `$util.urlEncode()`
— an `&` in a customer's data will otherwise split your request.

---

## 4. Usage plans and API keys

An **API key** is a shared secret the client sends in `x-api-key`. A **usage
plan** binds keys to API stages and applies throttling and quotas:

```hcl
throttle_settings {
  burst_limit = 200   # short spike ceiling
  rate_limit  = 100   # sustained requests per second
}

quota_settings {
  limit  = 100000
  period = "DAY"
}
```

Exceeding the rate returns `429 Too Many Requests`. Exceeding the quota rejects
requests until the period rolls over.

**An API key is not authentication.** It identifies an application, not a
person, and it travels in a header that is trivially readable in a mobile
binary or browser dev tools. It is a mechanism for usage tracking, tiering
(Free / Pro / Enterprise) and backend protection — not for deciding who someone
is.

---

## 5. Authentication versus authorization

The distinction matters and the words are often used loosely:

- **Authentication** — who is this? Cognito answers this.
- **Authorization** — is this caller allowed to do this? The API Gateway
  authorizer answers this.

### Options in API Gateway

**IAM (`AWS_IAM`)** — SigV4-signed requests. Right when the caller is itself an
AWS principal: another service, an internal backend, a CI job.

**Cognito user pools** — the gateway validates a JWT issued by your user pool.
No code to write.

**Lambda authorizer** — your own function inspects the request and returns an
IAM policy. Maximum flexibility, maximum responsibility.

**API key + usage plan** — not authentication, as above.

### Cognito user pools

A user pool is an identity store plus an authentication service: sign-up,
sign-in, password policy, MFA, social and enterprise federation (OIDC, SAML), a
hosted login UI, and JWT issuance.

Three tokens come out of a successful login:

| Token | Contains | Used for |
|-------|----------|----------|
| **ID token** | User profile claims — `sub`, `email`, `cognito:username` | Telling the client application who the user is |
| **Access token** | Scopes, client ID, groups | Authorising API calls |
| **Refresh token** | — | Obtaining new tokens without re-authenticating |

All are signed with RS256 and verifiable against the pool's public keys at
`https://cognito-idp.<region>.amazonaws.com/<pool_id>/.well-known/jwks.json`.

The refresh token should **never** be sent to your API. It travels only between
the client and Cognito.

### Use the authorization code flow

Older examples use the implicit flow (`response_type=token`) because the token
arrives directly in the URL fragment and is quick to grab by hand. Implicit
grant was **removed from OAuth 2.1** — tokens in URLs end up in browser
history, server logs and `Referer` headers.

Use **authorization code with PKCE**:

```hcl
allowed_oauth_flows  = ["code"]
allowed_oauth_scopes = ["openid", "email", "profile"]
callback_urls        = ["http://localhost:3000/callback"]
```

The client receives a short-lived `code` and exchanges it for tokens at
`/oauth2/token`. One extra call, and the tokens never appear in a URL.

### Cognito authorizer or Lambda authorizer?

**Cognito authorizer** validates the signature, issuer, audience and expiry —
plus OAuth scopes if you declare `authorization_scopes` on the method (access
tokens only, not ID tokens). No code, no maintenance. This covers most cases.

**Lambda authorizer** when you need logic Cognito cannot express: restricting
to one email domain, checking whether the user is still active in your own
database, applying per-tenant policy, or accepting tokens from several identity
providers. You own the code, and a mistake in it is a security hole.

Default to the Cognito authorizer. Move to a Lambda authorizer when you have a
specific requirement it cannot meet — not preemptively.

> A practical gotcha: the Cognito authorizer expects the raw token in the
> `Authorization` header, **without** a `Bearer ` prefix. Clients that always
> prepend `Bearer` will get 401s.

---

## 6. Where each layer sits

```text
Client
  ↓
CloudFront                    ← caching, global edge (optional)
  ↓
AWS WAF                       ← SQLi, XSS, bots, IP reputation
  ↓
API Gateway
  ├─ Cognito authorizer       ← is this a valid user?
  ├─ API key + usage plan     ← which app, and how much may it call?
  └─ throttling, validation
  ↓
Backend (Lambda / SNS / HTTP services)
```

Cognito does not stop SQL injection, XSS or volumetric attacks — it has no
opinion about HTTP payloads at all. That is the WAF's job. Cognito establishes
identity; the authorizer enforces access; the usage plan controls consumption;
the WAF filters hostile traffic before any of them run.

Combining them answers different questions at once: the JWT says **who** the
user is, the API key says **which application** is calling, and the backend can
read claims out of the JWT for finer-grained decisions — restricting an
endpoint to `role=admin`, or logging `email` for audit.

**Patterns by API type:**

- **Public API** — minimum: API key plus usage plan. Better: JWT for identity,
  API key for tiering and metering.
- **Internal API** — `AWS_IAM` with a private endpoint.
- **Partner / B2B API** — OAuth2 or a Lambda authorizer, with a separate usage
  plan and key per partner.

---

## 7. Observability

**Access logs** — one structured line per request at the stage level.
Request ID, source IP, method, path, status, latency, integration errors. Emit
JSON so it can be queried.

**Execution logs** — per-method internal detail: mapping template evaluation,
integration request and response, errors. Controlled by `logging_level`
(`OFF` / `ERROR` / `INFO`) and `data_trace_enabled`.

> `data_trace_enabled` logs **full request and response bodies**. Extremely
> useful while developing a mapping template, and unacceptable in production —
> it writes customer PII into CloudWatch and inflates log costs. Enable it in
> dev, leave it off in prod.

**Metrics** worth alarming on: `5XXError` (backend broken), `4XXError` (clients
calling wrongly, or auth failing), `Latency` versus `IntegrationLatency` (the
gap is gateway overhead), and `CacheHitCount`/`CacheMissCount` if caching is on.

**X-Ray** traces a request across gateway, Lambda and downstream services.

---

## 8. Operational notes on the lab

Full configuration: [`labs/02-api-gateway-cognito/main.tf`](../labs/02-api-gateway-cognito/main.tf)

**`aws_api_gateway_account` is account-and-Region-wide.** It sets the
CloudWatch role for *every* API in that Region, not just this one. Applying the
lab in an account that already has one will overwrite it. Comment it out on a
shared account.

**Do not trigger deployments with `timestamp()`.** A `triggers` block
containing `timestamp()` creates a new deployment on every single apply,
whether or not anything changed. Hash the actual configuration instead, and add
`create_before_destroy` so the stage is never left pointing at a deleted
deployment.

---

## Practice

### Read

| Page title | URL |
|------------|-----|
| *Control access to REST APIs* | https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-to-api.html |
| *Using tokens with user pools* | https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-with-identity-providers.html |
| *Set up API Gateway API request and response data mappings* | https://docs.aws.amazon.com/apigateway/latest/developerguide/rest-api-data-transformations.html |
| *Throttle API requests for better throughput* | https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-request-throttling.html |

The tokens page is the important one. Knowing precisely what is in an ID token
versus an access token — and being able to say it out loud — comes up in real
design conversations constantly.

### Key phrases

Security vocabulary is high-stakes: using the wrong word here makes people
doubt the rest of what you say.

| Phrase | Used like this |
|--------|----------------|
| **to authenticate** vs **to authorize** | "Cognito authenticates the user; the authorizer authorizes the call." |
| **to issue a token** | "Cognito issues three tokens on successful login." |
| **to validate a token** | "The authorizer validates the signature and expiry." |
| **to expire** | "The access token expires after one hour." |
| **to revoke** | "You can revoke a refresh token." |
| **to enforce** a policy | "The authorizer enforces access at the API layer." |
| **to grant / to deny access** | "The policy grants access to that method only." |
| **least privilege** | "The read handler follows least privilege." |
| **to scope something to** | "The key is scoped to one usage plan." |
| **a security boundary** | "The gateway is the security boundary here." |
| **to sit behind** | "The Lambda sits behind the authorizer." |
| **to be trivially readable** | "An API key in a mobile binary is trivially readable." |
| **to leak** | "Tokens in URLs leak into browser history." |
| **a gotcha** | "One practical gotcha: no `Bearer` prefix." |
| **to default to** | "Default to the Cognito authorizer." |
| **preemptively** | "Don't reach for a Lambda authorizer preemptively." |

Two errors that stand out badly:

- **"authorize"** ≠ **"authenticate"**. Native speakers notice the swap
  instantly, and in a security discussion it undermines you.
- **"an user"** → **"a user"**. *User* starts with a consonant sound (/j/), so
  it takes *a*. Same for *a UUID*, *a URL*, *a usage plan*.

### Write

Write **5–8 sentences**, using **at least 3** phrases from the table.

Prompt: *A teammate asks: "We already have API keys on every endpoint. Why do
we need Cognito as well?" Answer them.*

The trap is answering only "keys aren't secure". Say what each mechanism
actually establishes, and give a concrete example of something you can do with
one and not the other.

### Speak

**Drill A — 2-minute explainer.** Explain **the three Cognito tokens** — what
each contains, what each is for, and which must never reach your API.

Then handle this follow-up cold: *"Can I just use the ID token for everything?"*
The honest answer is that it usually works and is still not what you want.
Explaining "works but is wrong" clearly is a genuinely hard piece of English —
practise it.

**Drill B — elimination.**

> A mobile app authenticates users through a Cognito user pool. The API must
> reject requests from users who have been deactivated in the company's
> internal database, even if their token is still valid. What should the team
> implement?
>
> A. A Cognito user pool authorizer on each method
> B. A Lambda authorizer that validates the JWT and checks user status
> C. Shorter token expiry, set to five minutes
> D. An API key per user, revoked on deactivation

Say why each wrong option fails. C is the one worth dwelling on — it reduces
the window but does not close it, and there is a real cost to setting expiry
that low. Say both parts.

Model answers: [`practice/elimination-drills.md`](practice/elimination-drills.md)
