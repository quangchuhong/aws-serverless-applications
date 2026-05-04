# Tài liệu nghiên cứu API Gateway & Kiến trúc API  
*(AWS / GCP / Azure / Apigee / Kong + Use case Bank & E‑commerce)*

Tài liệu này tóm tắt:

- Lý thuyết & cấu hình quan trọng của các dòng API Gateway:
  - AWS API Gateway
  - GCP API Gateway & Apigee
  - Azure API Management (APIM)
  - Kong API Gateway
- Các mô hình kiến trúc Public / Private API Gateway.
- Mô hình API trong Banking/Finance.
- Mô hình API trong E‑commerce.
- Một số khái niệm liên quan (orchestration, integration, load balancer…).

---

## 1. Tổng quan & so sánh các API Gateway chính

### 1.1. Bảng so sánh tổng quan

| Tiêu chí | **AWS API Gateway** | **GCP API Gateway** | **Azure APIM** | **Apigee (GCP)** | **MuleSoft Anypoint** | **Kong API Gateway** |
|----------|---------------------|---------------------|----------------|-------------------|------------------------|----------------------|
| Loại     | Managed gateway + basic API mgmt | Managed gateway | Managed API mgmt | Full API mgmt enterprise | Integration + API mgmt enterprise | Self-hosted gateway |
| Cloud chính | AWS | GCP | Azure | GCP (multi‑cloud) | Multi‑cloud / on‑prem | Cloud-agnostic / on‑prem |
| Backend native | Lambda, ALB/NLB, AWS services | Cloud Run, Functions, App Engine | Functions, App Service, AKS… | HTTP bất kỳ | Mule flows, HTTP, MQ, DB, SOAP, mainframe | HTTP backend bất kỳ |
| Backend ngoài | HTTP(S) bất kỳ, VPC Link/on‑prem | HTTP(S) bất kỳ | HTTP(S) bất kỳ | HTTP(S) bất kỳ | Rất mạnh với on‑prem legacy | HTTP(S) bất kỳ |
| API Management | Trung bình (usage plan, key, quota) | Cơ bản | Mạnh | Rất mạnh (policies, monetization, portal) | Rất mạnh + ESB/integration | Tuỳ plugin / Enterprise suite |
| Dev portal | Cơ bản | Cơ bản | Có sẵn, khá tốt | Có sẵn, rất mạnh | Exchange/portal mạnh | Dev Portal (bản Enterprise) |
| Dùng nhiều ở | Hệ trên AWS, serverless | Hệ trên GCP | Hệ trên Azure | Enterprise, telco, bank | Bank/enterprise nhiều legacy | Microservices/K8s, DevOps |

### 1.2. Backend có bị giới hạn “cùng cloud” không?

**Không.** Cả AWS, GCP, Azure, Apigee, Kong đều có thể gọi:

- Native service trong cloud tương ứng (Lambda, Cloud Run, Functions, App Service,…).
- HTTP backend ở:
  - Cloud khác (AWS ↔ GCP ↔ Azure).
  - On‑prem (qua VPN / Direct Connect / Interconnect / ExpressRoute).
  - Public Internet.

“Native integration” chỉ giúp tiện hơn (IAM, logging, monitor…), không giới hạn backend.

---

## 2. AWS API Gateway

### 2.1. Loại API

- **REST API**:
  - Đầy tính năng: mapping template, usage plan, API key, cache, models.
- **HTTP API**:
  - Đơn giản hơn, latency thấp, rẻ hơn.
  - Hỗ trợ Lambda, HTTP backend, JWT auth.

### 2.2. Endpoint types

- **EDGE / REGIONAL**: public endpoint trên Internet.
- **PRIVATE**: chỉ trong VPC (qua VPC Endpoint / PrivateLink).

### 2.3. Chức năng chính

- Auth: IAM, Cognito User Pool (JWT), Lambda authorizer, API Key.
- Throttling & quota: Usage Plan.
- Cache:
  - Stage cache (`cache_cluster_enabled`, `cache_cluster_size`).
  - TTL per method (`cache_ttl_in_seconds`).
- Transformation: Velocity templates (VTL) cho request/response.
- Logging & metrics: CloudWatch, X-Ray, access logs.

### 2.4. Cấu hình cache (ý nghĩa chính)

- `cache_cluster_enabled = true`: bật cache cluster cho Stage.
- `cache_cluster_size = "0.5"`:
  - Chọn kích thước cache cluster (0.5, 1.6, 6.1,…).  
  - Size càng lớn → nhiều bộ nhớ cache hơn, throughput cao hơn, tốn tiền hơn.
- `cache_ttl_in_seconds`:
  - Quyết định response cache sống bao lâu (ví dụ 60s, 300s,…).

### 2.5. Mô hình kiến trúc thường dùng (AWS)

#### 2.5.1. Public API → Lambda/serverless

```text
Internet
   |
[ AWS API Gateway ]
   |
[ Lambda ]
   |
[ DynamoDB / RDS / S3 / ... ]
```

Dùng cho: mobile/web API, serverless backend.

#### 2.5.2. Public API → LB → microservices

```text
Internet
   |
[ API Gateway ]
   |
 (VPC Link / HTTP integration)
   |
[ NLB/ALB private ]
   |
[ ECS / EKS / EC2 services ]

```

  - LB chịu trách nhiệm health check, load balancing, deployment strategy.
  - Gateway chịu trách nhiệm API-level concerns (auth, rate limit, mapping).


#### 2.5.3. Private API trong VPC
```text
Internal clients (EC2/ECS/Lambda/on‑prem via VPN/DC)
      |
    VPC / PrivateLink
      |
[ API Gateway (PRIVATE endpoint) ]
      |
[ Internal services ]

```
Dùng cho: API nội bộ, backoffice, batch.

---

## 3. GCP API Gateway & Apigee

### 3.1. GCP API Gateway

  - Managed API gateway cho Cloud Run / Cloud Functions / App Engine / HTTP backend.
  - Cấu hình bằng OpenAPI + x-google-backend.
  - Tích hợp tốt với IAM, Cloud Logging, Cloud Monitoring.
    
Ví dụ rút gọn (OpenAPI):
```yaml
swagger: '2.0'
info:
  title: example-api
  version: 1.0.0
host: my-gateway-xyz.a.run.app
x-google-endpoints:
  - name: my-gateway-xyz.a.run.app
paths:
  /orders/{id}:
    get:
      x-google-backend:
        address: https://my-service-abcdef-uc.a.run.app
      responses:
        '200':
          description: OK

```

### 3.2. Apigee (Apigee X / Hybrid)

- Nền tảng API Management enterprise:
  - Policies: rate limit, spike arrest, JWT/OAuth2, transform XML/JSON, caching, security.
  - API Product, quota, analytics, developer portal.
- Backend:
  - Cloud Run/Functions/App Engine.
  - HTTP backend ở bất cứ đâu (AWS, Azure, on‑prem).
    
Mô hình hay gặp trong bank/enterprise:
```text
Mobile / Web / Partner
        |
      Internet
        |
     [ Apigee ]
        |
  (VPN / Interconnect)
        |
[ ESB / Core Banking / Legacy ]

```
