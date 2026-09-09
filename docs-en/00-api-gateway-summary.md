# API Gateways & API Architecture

*AWS / GCP / Azure / Apigee / Kong, with banking and e-commerce patterns*

Vietnamese version: [`docs/00-API-Gateway-Summary.md`](../docs/00-API-Gateway-Summary.md)

---

## 1. Comparing the major gateways

| | **AWS API Gateway** | **GCP API Gateway** | **Azure APIM** | **Apigee** | **MuleSoft Anypoint** | **Kong** |
|---|---|---|---|---|---|---|
| Category | Managed gateway + basic API management | Managed gateway | Managed API management | Full enterprise API management | Integration + API management | Self-hosted gateway |
| Primary cloud | AWS | GCP | Azure | GCP, multi-cloud | Multi-cloud / on-prem | Cloud-agnostic |
| Native backends | Lambda, ALB/NLB, AWS services | Cloud Run, Functions, App Engine | Functions, App Service, AKS | Any HTTP | Mule flows, HTTP, MQ, DB, SOAP, mainframe | Any HTTP |
| API management depth | Moderate | Basic | Strong | Very strong | Very strong, plus ESB | Plugin-dependent |
| Developer portal | Basic | Basic | Built in, decent | Built in, very strong | Anypoint Exchange | Enterprise edition only |
| Typical adopter | AWS-centric, serverless | GCP-centric | Azure-centric | Enterprise, telco, banking | Banks with heavy legacy | Kubernetes, DevOps teams |

### Are backends restricted to the same cloud?

**No.** Every one of these can call a native service in its own cloud *and* any
HTTP backend anywhere — another cloud, on-premises over VPN or a dedicated
interconnect, or the public internet.

Native integration buys you convenience — IAM, logging, tracing wired up for
you — not a restriction on where the backend lives. This comes up constantly in
architecture discussions and the answer is always the same.

---

## 2. AWS API Gateway

### 2.1. API types

**REST API (v1).** The full-featured option: mapping templates, usage plans,
API keys, response caching, request validation, private endpoints, WAF
integration.

**HTTP API (v2).** Newer, cheaper, lower latency, simpler to configure.
Supports Lambda, HTTP backends and JWT authorizers.

HTTP APIs **do not have**: usage plans and API keys, VTL mapping templates,
request validation, caching, private endpoints, or WAF integration. If you need
any of those, you need a REST API. Otherwise prefer HTTP API — it is roughly a
third of the price and noticeably faster.

**WebSocket API.** Stateful, bidirectional, long-lived connections. Chat,
real-time dashboards, push notifications.

### 2.2. Endpoint types

- **Edge-optimised** — routed through CloudFront's edge network.
- **Regional** — served from one Region.
- **Private** — reachable only from inside a VPC via an interface endpoint.

Private endpoints are REST-API-only.

### 2.3. Core capabilities

- **Authorization**: IAM (SigV4), Cognito user pools, Lambda authorizers, API keys.
- **Throttling and quotas**: usage plans.
- **Caching**: per-stage cache cluster, per-method TTL.
- **Transformation**: Velocity (VTL) templates on request and response.
- **Observability**: CloudWatch access logs, execution logs, metrics, X-Ray.

### 2.4. Caching configuration

- `cache_cluster_enabled` turns the stage cache on.
- `cache_cluster_size` picks the cluster size (0.5, 1.6, 6.1 GB and upward).
  Bigger means more cached responses and higher throughput — and more cost.
- `cache_ttl_in_seconds` sets how long a cached response stays valid.

The cache is billed **per hour while it exists**, independent of traffic.

### 2.5. Common architectures

**Public API to serverless backend**

```text
Internet → [ API Gateway ] → [ Lambda ] → [ DynamoDB / RDS / S3 ]
```

**Public API to containerised microservices**

```text
Internet → [ API Gateway ] → (VPC Link) → [ Private NLB/ALB ] → [ ECS / EKS ]
```

The division of labour matters here: the load balancer owns health checking,
load distribution and deployment strategy. The gateway owns API-level
concerns — authentication, rate limiting, request shaping.

**Private API inside a VPC**

```text
Internal clients → VPC / PrivateLink → [ API Gateway, private ] → [ Internal services ]
```

For internal APIs, back-office tooling and batch jobs.

---

## 3. GCP API Gateway and Apigee

**GCP API Gateway** fronts Cloud Run, Cloud Functions, App Engine or any HTTP
backend. Configured through an OpenAPI document with `x-google-backend`
extensions.

**Apigee** is a different class of product — full enterprise API management
with policies (rate limiting, spike arrest, OAuth2/JWT, XML/JSON
transformation, caching), API products, quotas, analytics and a developer
portal. Common in banks and telcos, typically fronting legacy systems reached
over a private interconnect.

---

## 4. Azure API Management

Fully managed: gateway, policies, developer portal and analytics. Runs in two
modes — public with an internet-facing IP, or internal (VNet-injected) with no
public address at all.

Policies are XML documents with `inbound`, `backend`, `outbound` and `on-error`
sections. A simple one:

```xml
<policies>
  <inbound>
    <base />
    <rate-limit calls="10" renewal-period="60" />
    <set-header name="X-From-APIM" exists-action="override">
      <value>true</value>
    </set-header>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

---

## 5. Kong

Open source and self-hosted, on Kubernetes (as an ingress controller), Docker,
VMs or bare metal. Capability comes from plugins: JWT, key auth, OAuth2, OIDC,
rate limiting, ACLs, logging, metrics, request and response rewriting.

Configured declaratively:

```yaml
_format_version: "2.1"
services:
  - name: orders-service
    url: http://orders-api.default.svc.cluster.local:8080
    routes:
      - name: orders-route
        paths: [/orders]
plugins:
  - name: key-auth
    service: orders-service
  - name: rate-limiting
    service: orders-service
    config:
      minute: 100
      policy: local
```

Chosen when you want the gateway under your own control, or when you are
multi-cloud and do not want a managed service dictating where things run.

---

## 6. Public versus private gateways

**Public gateway** — faces mobile apps, single-page applications, websites and
external partners. Typically runs OAuth2/OIDC or JWT validation, a WAF, rate
limiting and quotas, plus full logging and tracing.

**Private gateway** — never exposed to the internet. Handles service-to-service
traffic, back-office tools, batch jobs and BI.

**Both together** is the common enterprise shape:

```text
Internet
   ↓
[ Public API Gateway ]        ← edge protection, productised APIs
   ↓ (PrivateLink / internal LB)
[ Private API Gateway ]       ← internal routing, hides topology
   ↓
[ Internal microservices / core systems ]
```

The public layer productises and protects. The private layer routes internally
and hides the topology from anything outside.

---

## 7. Orchestration

**Orchestration** means coordinating several services to complete one business
operation, with ordering, conditional branching, and error handling including
compensating transactions.

A banking example:

1. Call service A to open an account.
2. If A succeeds, call B to run KYC checks.
3. If B passes, call C to assign a credit limit.
4. Call D to notify the customer.
5. If B or C fails, roll back, log and alert.

AWS Step Functions, Apigee flows, MuleSoft and Camunda all exist to make step 5
tractable. Doing this in application code is where distributed systems go to
die.

---

## 8. API patterns in banking

### 8.1. Wrapping core banking

```text
Mobile / Web / Partner → Internet → [ API Management ]
    → (VPN / Direct Connect) → [ ESB / Core Banking / Legacy ]
```

The goal is to present SOAP, MQ, mainframe and database interfaces as RESTful
APIs, and to add security, rate limiting, auditing and monitoring on the way
through.

### 8.2. Backend for Frontend (BFF)

```text
Mobile App        Web App
    ↓                ↓
[ Mobile BFF ]  [ Web BFF ]
        ↘         ↙
       [ API Gateway ]
             ↓
       [ Core services ]
```

The mobile BFF returns small payloads with few fields, tuned for a mobile
network. The web BFF can return richer data for a complex layout. Neither
compromises the other, and neither pollutes the core services with
channel-specific logic.

### 8.3. MuleSoft's three-layer model

- **System APIs** wrap core banking, CRM, loan origination, the existing ESB,
  message queues — one per underlying system, normalising the interface.
- **Process APIs** implement composite business operations (open an account,
  transfer funds, disburse a loan) by orchestrating system APIs.
- **Experience APIs** are shaped for one channel — mobile banking, internet
  banking, a partner integration.

The value is that channel-specific requirements land in the experience layer
instead of leaking into the systems underneath.

---

## 9. API patterns in e-commerce

```text
Web SPA / Mobile / Partner → CloudFront → API Gateway → BFF layer
    ↓
[ Product ] [ Cart ] [ Order ] [ Payment ] [ User/Auth ] [ Search ] [ Shipping ]
```

Data store per service, chosen for the access pattern:

- **Product catalogue** — DynamoDB plus a search engine (OpenSearch, Algolia).
- **Cart** — short-lived state; DynamoDB or Redis.
- **Order** — RDS/Aurora when you need ACID transactions and reporting.
- **Payment** — calls an external payment service provider.

Asynchronous work goes through events rather than synchronous calls:

```text
[ Order Service ] --"OrderCreated"--> [ SNS / EventBridge ]
                         ↓
     ┌───────────────────┼───────────────────┐
[ Email ]          [ Analytics ]        [ Fraud check ]
```

Publishing an event instead of calling three services keeps the order service
from knowing or caring who consumes it, and stops a slow fraud check from
delaying the customer's confirmation.

---

## 10. ESB versus MuleSoft

An **Enterprise Service Bus** is the traditional integration layer: connectors
for heterogeneous systems, data transformation between formats, orchestration
and routing, and decoupling so systems talk to the bus rather than to each
other. IBM Integration Bus, TIBCO and Oracle ESB are the classic products.

**MuleSoft Anypoint** does all of that and adds API management on top — API
design, policies, a developer portal, analytics, and the three-layer model
above.

| | Traditional ESB | MuleSoft |
|---|-----------------|----------|
| Goal | Internal integration hub | Integration plus enterprise API management |
| Protocols | Mostly SOAP/XML, JMS, MQ, file, DB | REST/JSON as first class, plus all of the above |
| API management | Weak or absent | Built in |
| API structure | No clear layering | System / Process / Experience |
| Deployment | On-premises data centre | On-prem, cloud, hybrid |
| Reuse | Usually confined to the ESB team | Catalogued organisation-wide |

**When each makes sense.** If the ESB works, sits in the data centre, and there
is little demand to expose APIs externally, leave it as the integration
backbone and put an API layer above it. If the strategy is API-first, open
banking, or a digital platform, MuleSoft tends to become the primary platform
and the old ESB gradually becomes just another system underneath it.

---

## Practice

### Read

| Page title | URL |
|------------|-----|
| *What is Amazon API Gateway?* | https://docs.aws.amazon.com/apigateway/latest/developerguide/welcome.html |
| *Choose between REST APIs and HTTP APIs* | https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html |
| *Amazon API Gateway API endpoint types* | https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-api-endpoint-types.html |

The REST versus HTTP comparison page is the most useful thing on this list. It
is essentially a decision table, and being able to reproduce its reasoning out
loud is worth more than memorising it.

### Key phrases

This document is about **comparing and recommending**, so the target language
is hedged and qualified — the register you need when you are advising rather
than asserting.

| Phrase | Used like this |
|--------|----------------|
| **to front** something | "API Gateway fronts the Lambda functions." |
| **to sit in front of** | "The WAF sits in front of the gateway." |
| **to be a good fit for** | "HTTP APIs are a good fit for most new workloads." |
| **to lend itself to** | "This pattern lends itself to multi-tenant systems." |
| **to come at the cost of** | "The extra features come at the cost of latency." |
| **to buy you** something | "Native integration buys you convenience, not capability." |
| **to fall short** | "HTTP APIs fall short when you need request validation." |
| **to be overkill** | "Apigee would be overkill for three internal APIs." |
| **the division of labour** | "The division of labour is clear: the LB handles health checks, the gateway handles auth." |
| **to productise an API** | "The public layer productises the APIs for partners." |
| **to hide the topology** | "The private gateway hides the internal topology." |
| **to leak into** | "Channel-specific logic shouldn't leak into the core services." |
| **to be confined to** | "Reuse is usually confined to one team." |
| **it comes down to** | "It comes down to whether you need usage plans." |
| **all things being equal** | "All things being equal, prefer the HTTP API." |

Hedging is a skill, not a weakness. "**I'd lean towards** HTTP API here,
**unless** you need usage plans" is a stronger professional sentence than "HTTP
API is better" — it shows you know the boundary of your own claim.

### Write

Write **5–8 sentences**, using **at least 3** phrases from the table.

Prompt: *A team is building a public API for a mobile app. They expect 500
requests per second, need per-partner rate limits later, and want the lowest
possible latency. Recommend REST API or HTTP API and justify it.*

Make an actual recommendation — do not write "it depends" and stop. State the
condition that would change your answer.

### Speak

**Drill A — 2-minute explainer.** Explain **the difference between a REST API
and an HTTP API in API Gateway** to a colleague starting a new service tomorrow.

1. What the choice is
2. What HTTP API gives up
3. What surprises people — the price and latency gap is larger than expected
4. When you must use REST

The hard part is being concise. Two minutes is not long, and this topic invites
rambling. Time yourself and cut.

**Drill B — elimination.**

> A company needs a public API with per-customer usage quotas, request payload
> validation, and response caching. Which is most appropriate?
>
> A. HTTP API with a Lambda authorizer
> B. REST API with usage plans and API keys
> C. HTTP API with a JWT authorizer and CloudFront in front
> D. Application Load Balancer with Lambda targets

Say why each wrong option fails. For C in particular, say precisely which of
the three requirements CloudFront does and does not satisfy — that distinction
is the whole question.

Model answers: [`practice/elimination-drills.md`](practice/elimination-drills.md)
