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
---

## 4. Azure API Management (APIM)

### 4.1. Tổng quan

- Fully-managed API Management: gateway + policies + dev portal + analytics.
- Chế độ:
  - Public: có public IP, exposure ra Internet.
  - Internal (vNet-injected): chỉ trong vNet, không public IP.
    
### 4.2. Policies (XML)

Ví dụ policy đơn giản:
```text
<policies>
  <inbound>
    <base />
    <!-- Rate limit -->
    <rate-limit calls="10" renewal-period="60" />
    <!-- Thêm header -->
    <set-header name="X-From-APIM" exists-action="override">
      <value>true</value>
    </set-header>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>

```

### 4.3. Mô hình

Public:

```text
Internet
   |
[ Azure APIM (public) ]
   |
   +--> Azure Functions
   +--> App Service / AKS
   +--> HTTP external services

```

Internal:

```text
Internal clients (vNet / VPN / ExpressRoute)
      |
    vNet
      |
[ Azure APIM (internal, vNet-injected) ]
      |
[ Internal services in vNet / on‑prem ]

```
---

## 5. Kong API Gateway

### 5.1. Tổng quan

- Open source / Enterprise, self-hosted.
- Chạy trên:
  - Kubernetes (Kong Ingress Controller).
  - Docker, VM, bare-metal.
- Plugin phong phú:
  - Auth: JWT, Key Auth, OAuth2, OIDC.
  - Rate limiting, ACL.
  - Logging, metrics (ELK, Prometheus).
  - Transformation, request/response rewrite.

### 5.2. Cấu hình declarative (YAML)
```yaml
_format_version: "2.1"
services:
  - name: orders-service
    url: http://orders-api.default.svc.cluster.local:8080
    routes:
      - name: orders-route
        paths:
          - /orders
plugins:
  - name: key-auth
    service: orders-service
  - name: rate-limiting
    service: orders-service
    config:
      minute: 100
      policy: local

```

### 5.3. Mô hình với Kubernetes
```text
Internet
   |
[ Cloud LB / Ingress ]
   |
[ Kong (Ingress Controller) ]
   |
   +--> Service A (Deployment A)
   +--> Service B (Deployment B)
   +--> Service C (Deployment C)

```
Dùng cho: hệ microservices trên K8s (cloud hoặc on‑prem).

---

## 6. Mô hình Public vs Private API Gateway

### 6.1. Public API Gateway
```text
Mobile / Web / Partners
        |
      Internet
        |
[ Public API Gateway ]
        |
[ BFF / public-facing services ]

```
- Dùng cho:
  - Mobile app, SPA, website, partner bên ngoài.
- Thường bật:
  - OAuth2/OIDC, JWT, API key.
  - WAF, rate-limit, quota.
  - Logging, tracing.

### 6.2. Private / Internal API Gateway
```text
Internal apps / microservices / backoffice
        |
   VPC / vNet / VPN / Internal network
        |
[ Internal API Gateway ]
        |
[ Internal microservices / DB / legacy ]

```
- Không expose ra Internet.
- Dùng cho:
  - Giao tiếp nội bộ giữa dịch vụ.
  - Backoffice, CRM, batch, BI.


### 6.3. Kết hợp Public + Private
```text
Internet
   |
[ Public API Gateway ]
   |
 (VPC Link / PrivateLink / internal LB)
   |
[ Private API Gateway / Internal LB ]
   |
[ Internal microservices / core systems ]

```
- Public:
  - Edge layer, bảo vệ, product hóa API.
- Private:
  - Routing nội bộ, che giấu topology, chuẩn hóa access nội bộ.

## 7. Orchestration (Orchestrate) là gì?

**Orchestration** = điều phối nhiều dịch vụ nhỏ để thực hiện 1 nghiệp vụ phức tạp, theo:

  - Thứ tự (A → B → C).
  - Điều kiện (nếu B ok thì C, nếu ko thì D).
  - Xử lý lỗi (retry, rollback, compensating transaction).
    
Ví dụ (bank):

  1. Gọi service A: tạo tài khoản.
  2. Nếu A thành công → gọi B: kiểm tra KYC.
  3. Nếu B OK → gọi C: cấp hạn mức.
  4. Sau cùng gọi D: gửi email/SMS.
  5. Nếu B hoặc C lỗi → rollback / log / notify.
     
Các platform như MuleSoft, Apigee (policies/flows), AWS Step Functions, Camunda… thường dùng để orchestration.

---

## 8. Mô hình API trong Banking / Finance

### 8.1. API Gateway + Core Banking/Legacy
```text
Mobile / Web / Partner
        |
      Internet
        |
 [ API Management / API Gateway ]
 (Apigee / MuleSoft / Azure APIM / AWS API GW)
        |
 (VPN / DirectConnect / Interconnect)
        |
[ ESB / Core Banking / Legacy ]

```
- Mục tiêu:
  - Bọc hệ thống cũ (SOAP, MQ, DB, mainframe) thành RESTful API.
  - Thêm security, rate limit, audit, monitoring.

### 8.2. API Platform + Microservices
```text
Clients (web/mobile/partners)
        |
[ API Gateway / API Management ]
        |
[ Microservices layer (K8s/ECS/App Service/Cloud Run) ]
        |
[ Core banking / DB / message bus ]
```

- Bank dần hiện đại hóa:
  - Tách monolith/ESB thành microservices: account, card, payment, customer…


### 8.3. BFF (Backend For Frontend) cho mobile/web
```text
Mobile App         Web App
   |                 |
[ Mobile BFF ]   [ Web BFF ]
        \          /
         \        /
        [ API Gateway ]
               |
         [ Core / services ]

```

- Mobile BFF:
  - Payload nhỏ, ít trường, tối ưu mạng di động.
- Web BFF:
  - Có thể trả nhiều dữ liệu hơn, phục vụ layout phức tạp.

---

## 9. Mô hình API trong E‑commerce

### 9.1. API Gateway + BFF + Microservices (AWS ví dụ)
```text
Web SPA / Mobile App / Partner
             |
           Internet
             |
        [ CloudFront ]
             |
        [ AWS API Gateway ]
             |
          [ BFF Layer ]
        (Web BFF / Mobile BFF)
             |
   +---------+-----------------------------+
   |         |         |         |        |
[ Product ] [ Cart ] [ Order ] [ Payment ] [ User/Auth ]
[ Search ]  [ Promo ] [ Stock ] [ Shipping ] [ etc... ]

```

- Product/Catalog Service:
  - DB: DynamoDB + search engine (OpenSearch/Elasticsearch/Algolia).
- Cart Service:
  - State ngắn hạn (DynamoDB, Redis).
- Order Service:
  - RDS/Aurora (cho ACID, báo cáo) hoặc DynamoDB (nếu thiết kế NoSQL).
- Payment Service:
  - Gọi cổng thanh toán bên ngoài (Stripe, Adyen, local PSP…).
- Shipping/Logistics Service:
  - Tích hợp hãng vận chuyển / kho / WMS.


### 9.2. Public vs Internal API

- **Public API:**

  - Cho website, mobile app, partner integrations.
  - Qua public API Gateway (AWS API GW / Kong / NGINX/Envoy + LB).
    
- **Internal/Admin API:**
```text
Admin UI / CRM / OMS
        |
     VPN / SSO
        |
 [ Internal LB / Internal Gateway ]
        |
 [ Admin/Backoffice services ]

```
- Quản lý sản phẩm, giá, promotion, order management, refund…

### 9.3. Xử lý bất đồng bộ & sự kiện

Dùng SNS/SQS/EventBridge (hoặc Kafka) để phát sự kiện:
```text
[ Order Service ] -- "OrderCreated" --> [ SNS / EventBridge / Kafka ]
                                  |
         +------------------------+--------------------+
         |                        |                    |
[ Email Service ]          [ Analytics ]        [ Fraud Check ]

```

- Email/SMS:
  - Worker/Lambda subscribe topic để gửi mail.
- Analytics:
  - Đẩy data sang data lake/warehouse cho BI.
- Fraud:
  - Gọi hệ thống chấm điểm rủi ro.

---

## 10. Gợi ý chọn API Gateway theo ngữ cảnh

- Hệ thống chủ yếu trên AWS:
  - Dùng AWS API Gateway (HTTP API/REST API) + Lambda/ECS + Cognito.
- Hệ thống chủ yếu trên GCP:
  - Dùng GCP API Gateway cho Cloud Run/Functions;
  - Enterprise/bank cân nhắc Apigee.
- Hệ thống trên Azure:
  - Dùng Azure API Management.
- Multi‑cloud / on‑prem / K8s-heavy / muốn tự kiểm soát gateway:
  - Dùng Kong API Gateway (Kong Ingress trên K8s, hoặc VM).
    
---

## 11. MuleSoft vs ESB trong môi trường ngân hàng (Bank‑wide)

### 11.1. ESB là gì trong ngân hàng?

ESB (Enterprise Service Bus) là lớp trung gian dùng để:

1. **Kết nối hệ thống dị biệt (integration hub)**  
   - Core banking, thẻ, LOS, CRM, DWH, hệ thống kế toán…  
   - Giao thức khác nhau: HTTP, SOAP, JMS, MQ, file, DB…  
   - ESB cung cấp adapter/connector để các hệ thống chỉ cần kết nối về ESB, thay vì point‑to‑point lẫn nhau.

2. **Chuyển đổi & chuẩn hóa dữ liệu (transformation)**  
   - Chuyển đổi XML ↔ JSON ↔ fixed‑length ↔ CSV…  
   - Mapping field (tên, format, kiểu dữ liệu) để các hệ thống hiểu nhau.

3. **Orchestration & routing (điều phối luồng nghiệp vụ)**  
   - Điều phối nhiều bước:  
     - VD: tạo khách hàng → gọi CRM → gọi core → gọi scoring → gửi email/SMS.  
   - Routing theo rule nghiệp vụ, xử lý lỗi, retry.

4. **Giảm phụ thuộc (decoupling)**  
   - Hệ thống không gọi trực tiếp nhau, mà nói chuyện qua ESB.  
   - Khi thay thế core/CRM/LOS, tác động tới hệ khác được giảm bớt.

ESB truyền thống: IBM Integration Bus, TIBCO, Oracle ESB, v.v.

---

### 11.2. MuleSoft là gì trong bức tranh đó?

MuleSoft Anypoint Platform thường được dùng như **integration + API management platform hiện đại**, có thể thay thế hoặc “bọc” ESB truyền thống.

Đặc điểm chính:

- Có đủ chức năng **ESB**:
  - Connector phong phú: HTTP, SOAP, JMS, MQ, FTP, DB, SAP, mainframe adapter…
  - DataWeave để transform các format dữ liệu.
  - Flow để orchestration, routing, xử lý lỗi.

- Đồng thời là **API Management**:
  - API design (RAML/OAS), publish, secure, monitor.
  - Policies: OAuth2/JWT, rate limit, quota, logging, masking, IP filter…
  - Developer/consumer portal (Anypoint Exchange).

- Có **mô hình 3 lớp API** (System / Process / Experience) rất hợp với bank‑wide:
  - **System APIs**: bọc trực tiếp vào core/CRM/LOS/ESB/MQ.
  - **Process APIs**: orchestration nghiệp vụ (mở tài khoản, chuyển tiền, vay…).
  - **Experience APIs**: API cho từng kênh (mobile, web, partner), tối ưu payload / use case.

---

### 11.3. So sánh MuleSoft vs ESB truyền thống (góc nhìn bank‑wide)

| Tiêu chí | ESB truyền thống | MuleSoft Anypoint Platform |
|----------|------------------|----------------------------|
| Mục tiêu | Integration hub, kết nối hệ thống nội bộ | Integration + API Management toàn doanh nghiệp |
| Kiểu tích hợp | Chủ yếu SOAP/XML, JMS, MQ, file, DB | HTTP/REST/JSON + SOAP/XML + JMS/MQ + nhiều connector cloud/SAAS |
| API Management | Thường yếu hoặc không có (cần sản phẩm khác để quản lý API) | Tích hợp sẵn: design, policies, portal, analytics |
| Tổ chức API | Ít khái niệm rõ ràng về phân tầng API | Three‑layer API: System / Process / Experience |
| Hướng sử dụng | Tập trung trong nội bộ DC / on‑prem | On‑prem, cloud (CloudHub), hybrid, multi‑DC |
| Governance & reuse | Thường bị giới hạn ở mức project/ESB team | Anypoint Exchange làm catalogue bank‑wide, khuyến khích reuse System/Process APIs |
| Thân thiện với kênh số (digital) | Thường cần “bọc” thêm API GW/Layer mới | Hỗ trợ trực tiếp design/API lifecycle cho mobile/web/open API |

---

### 11.4. Cách MuleSoft thường được dùng “bank‑wide”

Mô hình điển hình:

```text
Mobile / Web / Partner / Open Banking
                |
              Internet
                |
        [ API Gateway / Edge (F5, WAF, etc.) ]
                |
         [ MuleSoft Anypoint Platform ]
          (API Manager + Runtime)
                |
        +-------+---------------------+
        |       |         |           |
   [ Experience APIs ] [ Process APIs ] [ System APIs ]
                |
        [ Core Banking / Cards / Loans / CRM / ESB / MQ ]
```

- **System APIs:**

  - Kết nối vào core banking, thẻ, LOS, CRM, DWH, ESB cũ, MQ…
  - Chuẩn hóa giao diện: REST/JSON, che giấu chi tiết kỹ thuật bên dưới.
- **Process APIs:**

  - Thực hiện nghiệp vụ composite:
    - Mở tài khoản, chuyển tiền, thu nợ, giải ngân, đăng ký sản phẩm…
  - Orchestrate nhiều System APIs, áp dụng rule nghiệp vụ, xử lý lỗi.
- **Experience APIs:**

  - Thiết kế cho từng kênh:
    - Mobile banking, internet banking, API cho đối tác fintech, merchant.
  - Mapping nhu cầu của UI/UX (payload, paging, filter…) mà không làm bẩn Process/System APIs.
    
---
 
### 11.5. Khi nào bank dùng ESB, khi nào dùng (hoặc nâng cấp sang) MuleSoft?

- **ESB vẫn đang chạy tốt, tập trung trong DC, ít yêu cầu mở API ra ngoài:**

  - ESB tiếp tục đóng vai trò integration backbone.
  - MuleSoft có thể được đặt như “API layer” phía trên ESB:
    - System APIs nối với ESB cũ.
    - Process/Experience APIs thêm logic & giao diện cho kênh số.
- **Bank muốn chiến lược API‑first / Open Banking / Digital platform:**

  - MuleSoft thường được chọn làm nền tảng chính, dần thay thế vai trò integration của ESB:
    - Dùng các connector của MuleSoft kết nối trực tiếp vào core/CRM/DB/MQ.
    - Dùng API Manager để quản lý API cho mobile/web/partner.
    - ESB cũ có thể trở thành một trong các “System” phía dưới.
      
Tóm lại:

  - ESB = lớp integration truyền thống tập trung vào kết nối / transform / route giữa hệ thống nội bộ.
  - MuleSoft = integration + API platform hiện đại, phù hợp cho chiến lược bank‑wide API: vừa kết nối legacy, vừa expose API ra kênh số và đối tác một cách quản trị được.
