# MCP vs MLOps – Hai tầng khác nhau của hệ thống AI

*(Model Context Protocol vs Machine Learning Operations + Use case trên AWS Serverless)*

Tài liệu này làm rõ:

- **MCP (Model Context Protocol)** là gì, kiến trúc, primitives, transport, auth.
- **MLOps** là gì, các thành phần trong vòng đời ML.
- Vì sao câu hỏi “MCP vs MLOps” là **so sánh sai tầng**, và chúng bổ sung nhau ở đâu.
- **LLMOps** – phần giao nhau thực sự giữa hai thế giới.
- Cách triển khai một **MCP server trên AWS Serverless** (API Gateway + Lambda + Cognito).
- Checklist bảo mật & vận hành, lộ trình học.

---

## 0. TL;DR – Trả lời ngắn

| | **MCP** | **MLOps** |
|---|---|---|
| Bản chất | Một **giao thức** (protocol/spec) | Một **tập practice + toolchain** (discipline) |
| Tầng | Runtime – lúc agent đang chạy | Lifecycle – build, deploy, vận hành mô hình |
| Trả lời câu hỏi | “Làm sao cho LLM **dùng được** tool và dữ liệu của tôi?” | “Làm sao **đưa mô hình ra production** và giữ nó khỏe?” |
| Đơn vị công việc | 1 request JSON-RPC (`tools/call`, `resources/read`) | 1 pipeline run, 1 model version, 1 deployment |
| Tương tự trong web | REST / gRPC / OpenAPI | DevOps / SRE |
| Ai làm | Backend / platform / AI engineer | ML engineer / data engineer / platform |

> **Không phải “A thay thế B”.** Một hệ agentic production thường **dùng cả hai**:
> MCP để agent nói chuyện với thế giới bên ngoài, MLOps/LLMOps để build – deploy –
> giám sát chính hệ agent đó.
>
> Ví von: MCP giống **cổng USB-C** (chuẩn cắm), MLOps giống **quy trình sản xuất +
> QA + bảo hành** của nhà máy. Bạn không hỏi “USB-C vs quy trình sản xuất”.

---

## 1. MCP – Model Context Protocol

### 1.1. Định nghĩa

MCP là một **open protocol** (Anthropic công bố cuối 2024, sau đó mở cho cộng đồng)
chuẩn hóa cách một ứng dụng LLM kết nối tới:

- **Tool** (hành động: query DB, gọi API, tạo ticket…)
- **Data / context** (file, tài liệu, bảng dữ liệu…)
- **Prompt template** (workflow dựng sẵn cho người dùng chọn)

Trước MCP, mỗi app AI phải viết integration riêng cho mỗi hệ thống → bài toán
**M × N** (M app × N hệ thống). MCP biến nó thành **M + N**: mỗi hệ thống viết
1 MCP server, mỗi app viết 1 MCP client.

```text
        TRƯỚC MCP (M x N)                          SAU MCP (M + N)

  App A ──┬── custom → Jira                  App A ─┐
          ├── custom → Postgres              App B ─┼─ MCP client ─┬─ MCP server Jira
          └── custom → S3                    App C ─┘              ├─ MCP server Postgres
  App B ──┬── custom → Jira                                        └─ MCP server S3
          ├── custom → Postgres
          └── custom → S3
```

### 1.2. Kiến trúc

MCP theo mô hình **client–server**, message dạng **JSON-RPC 2.0**, có handshake
`initialize` để thỏa thuận version + capabilities.

```text
+-------------------------------------------+
|  HOST (Claude Desktop / IDE / app của bạn) |
|                                            |
|   +------------+      +------------+       |
|   | MCP client | 1:1  | MCP client |       |
|   +-----+------+      +-----+------+       |
+---------|-------------------|--------------+
          |  stdio            |  Streamable HTTP
          v                   v
   +-------------+      +-----------------+
   | MCP server  |      |  MCP server     |
   | (local)     |      |  (remote/SaaS)  |
   +------+------+      +--------+--------+
          |                      |
      file system            Jira / DB / API
```

- **Host**: ứng dụng chứa LLM, quản lý quyền và vòng đời kết nối.
- **Client**: thành phần trong host, giữ kết nối **1–1** với một server.
- **Server**: chương trình expose tool/resource/prompt. Không cần biết LLM là gì.

### 1.3. Primitives

**Server cung cấp (server → client):**

| Primitive | Ai điều khiển | Dùng cho | Method chính |
|---|---|---|---|
| **Tools** | Model quyết định gọi | Hành động có side-effect: ghi DB, gọi API, deploy | `tools/list`, `tools/call` |
| **Resources** | Ứng dụng chọn đưa vào context | Dữ liệu chỉ đọc: file, record, log | `resources/list`, `resources/read` |
| **Prompts** | Người dùng chọn | Template/workflow: “review PR này”, “tóm tắt incident” | `prompts/list`, `prompts/get` |

**Client cung cấp ngược lại (client → server):**

| Primitive | Ý nghĩa |
|---|---|
| **Sampling** | Server nhờ client gọi LLM hộ (server không cần API key riêng) |
| **Roots** | Client khai báo phạm vi thư mục/URI mà server được phép đụng vào |
| **Elicitation** | Server hỏi thêm thông tin từ người dùng giữa chừng (ví dụ: xác nhận, nhập tham số thiếu) |

Ngoài ra có **notifications** (ví dụ `notifications/tools/list_changed`) cho phép
server báo client rằng danh sách tool đã thay đổi → hỗ trợ dynamic discovery.

### 1.4. Transport

| Transport | Dùng khi | Ghi chú |
|---|---|---|
| **stdio** | Server chạy local, cùng máy với host | Đơn giản nhất, không cần network, không cần auth |
| **Streamable HTTP** | Server remote (SaaS, nội bộ, sau API Gateway) | 1 endpoint `POST`/`GET`, hỗ trợ trả về SSE stream khi cần |

> Bản HTTP+SSE hai-endpoint đời đầu đã bị **thay thế bởi Streamable HTTP**.
> Khi viết server mới cho môi trường remote, dùng Streamable HTTP.

Spec MCP được đánh version theo ngày (ví dụ `2025-06-18`) và vẫn đang tiến hóa —
luôn đối chiếu revision mới nhất tại `modelcontextprotocol.io` trước khi implement.

### 1.5. Authorization (cho transport HTTP)

MCP dựa trên **OAuth 2.1**, trong đó **MCP server đóng vai Resource Server**, còn
việc phát token do một Authorization Server riêng (Cognito, Entra ID, Auth0, Okta…)
đảm nhiệm:

1. Client gọi server không token → server trả `401` kèm header
   `WWW-Authenticate` trỏ tới **Protected Resource Metadata** (RFC 9728).
2. Client đọc metadata → tìm ra Authorization Server → đọc tiếp
   **AS metadata** (RFC 8414).
3. Client đăng ký (có thể qua **Dynamic Client Registration**, RFC 7591) rồi chạy
   Authorization Code + **PKCE**.
4. Client gọi lại kèm `Authorization: Bearer <token>`.

**Quy tắc bắt buộc:**

- Token phải **audience-bound** cho đúng MCP server (`resource` parameter, RFC 8707).
- **Cấm token passthrough**: server **không được** lấy token của client rồi
  đem gọi thẳng upstream API. Phải đổi token / dùng credential riêng.
- Server phải từ chối token không phát cho chính nó → chống *confused deputy*.

### 1.6. Ví dụ tối giản một MCP server (Python)

```python
# server.py – MCP server expose 1 tool đọc trạng thái order từ DynamoDB
import boto3
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("order-service")
table = boto3.resource("dynamodb").Table("OrdersTable")


@mcp.tool()
def get_order_status(order_id: str) -> dict:
    """Lấy trạng thái của một order theo orderId."""
    resp = table.get_item(Key={"orderId": order_id})
    item = resp.get("Item")
    if not item:
        return {"found": False, "orderId": order_id}
    return {
        "found": True,
        "orderId": order_id,
        "status": item.get("status"),
        "updatedAt": item.get("updatedAt"),
    }


@mcp.resource("orders://recent")
def recent_orders() -> str:
    """Danh sách 20 order gần nhất (read-only context)."""
    items = table.scan(Limit=20).get("Items", [])
    return "\n".join(f'{i["orderId"]}: {i.get("status")}' for i in items)


if __name__ == "__main__":
    mcp.run()  # stdio transport
```

Điểm cần nhớ: **docstring và tên tool chính là “prompt” cho model**. Tool mô tả mơ hồ
→ model gọi sai. Đây là điểm khác biệt lớn so với REST API cho người dùng.

---

## 2. MLOps – Machine Learning Operations

### 2.1. Định nghĩa

MLOps là tập hợp practice để **đưa mô hình ML từ notebook ra production và giữ nó
hoạt động đúng theo thời gian**. Nó là DevOps + hai thứ mà phần mềm truyền thống
không có:

1. **Dữ liệu cũng là code** → phải version, validate, kiểm soát chất lượng.
2. **Mô hình xuống cấp theo thời gian** (drift) dù code không đổi một dòng nào.

### 2.2. Vòng đời & thành phần

```text
  [Data sources]
        |
        v
  Ingestion / ETL ──> Data validation ──> Feature engineering ──> Feature Store
                                                                       |
                                                                       v
                                                          Training + Experiment tracking
                                                                       |
                                                          Evaluation / Model validation
                                                                       |
                                                                       v
                                                              Model Registry (v1, v2...)
                                                                       |
                                       +-------------------------------+
                                       v
                            Deployment (batch / real-time / streaming)
                                       |
                                       v
                     Monitoring: latency, error, data drift, concept drift, bias
                                       |
                                       +---- trigger retrain ----> (quay lại Training)
```

| Thành phần | Vai trò | Tool phổ biến | Trên AWS |
|---|---|---|---|
| Data versioning | Tái lập được thí nghiệm | DVC, LakeFS, Delta Lake | S3 + Glue Catalog, Lake Formation |
| Feature store | Feature nhất quán train ↔ serve | Feast, Tecton | SageMaker Feature Store |
| Experiment tracking | So sánh run, param, metric | MLflow, W&B | SageMaker Experiments |
| Pipeline / orchestration | Tự động hóa các bước | Airflow, Kubeflow, Dagster | SageMaker Pipelines, Step Functions |
| Model registry | Quản lý version + approval | MLflow Registry | SageMaker Model Registry |
| Serving | Endpoint inference | KServe, BentoML, Triton | SageMaker Endpoint, Lambda, ECS |
| Monitoring | Drift, chất lượng, bias | Evidently, WhyLabs | SageMaker Model Monitor, Clarify |
| CI/CD/CT | Build, test, continuous training | GitHub Actions, Jenkins, Argo | CodePipeline, CodeBuild |

### 2.3. Mức trưởng thành (MLOps maturity)

| Level | Đặc điểm | Triệu chứng thực tế |
|---|---|---|
| **0 – Manual** | Notebook → tay → server | “Model chạy trên máy anh Nam”, không ai retrain được |
| **1 – ML pipeline automation** | Pipeline tự động train + validate, có registry, có CT | Retrain theo lịch hoặc theo drift alert |
| **2 – CI/CD automation** | Pipeline **của pipeline**: đổi code → tự build, test, deploy pipeline mới | Đội nhiều model, release thường xuyên |

### 2.4. Ba loại test đặc thù của MLOps

Ngoài unit test thông thường:

- **Data test**: schema, null rate, phân phối, giá trị ngoại lai.
- **Model test**: metric tối thiểu, so với baseline, test theo slice
  (ví dụ: accuracy trên nhóm khách hàng mới), fairness.
- **Infra test**: model load được, latency P95, đúng version artifact.

---

## 3. So sánh trực diện

| Tiêu chí | **MCP** | **MLOps** |
|---|---|---|
| Loại | Đặc tả kỹ thuật (spec) | Phương pháp luận + toolchain |
| Có “chuẩn” chính thức? | Có – JSON-RPC 2.0, versioned spec | Không – tập hợp best practice, mỗi tổ chức khác nhau |
| Ra đời | 2024 (Anthropic, sau đó open) | ~2018–2020 (Google/Microsoft phổ biến hóa) |
| Trọng tâm | Interoperability, kết nối | Reproducibility, reliability, governance |
| Artifact chính | MCP server, tool schema, prompt | Dataset version, model version, pipeline |
| Đơn vị deploy | Một server (container/Lambda/binary) | Một pipeline + model endpoint |
| Metric quan tâm | Tool call success rate, latency, độ chính xác chọn tool | Accuracy/AUC, drift, data quality, training cost |
| Rủi ro đặc trưng | Prompt injection, tool poisoning, quyền quá rộng | Drift, data leakage, bias, model không reproduce được |
| Vai trò LLM | Bắt buộc – MCP sinh ra để phục vụ LLM | Không bắt buộc – MLOps áp dụng cho mọi loại mô hình |
| Người tiêu thụ | Agent / LLM | Ứng dụng, business process |

### 3.1. Chúng gặp nhau ở đâu?

```text
   +------------------------------------------------------------+
   |                  Sản phẩm AI trên production               |
   +------------------------------------------------------------+
   |  Tầng agent/runtime   :  LLM + MCP client + MCP servers     |  <-- MCP
   +------------------------------------------------------------+
   |  Tầng model           :  model được train/fine-tune/serve   |  <-- MLOps
   +------------------------------------------------------------+
   |  Tầng vận hành chung  :  CI/CD, eval, observability, cost,  |  <-- LLMOps
   |                          security, governance               |      (giao nhau)
   +------------------------------------------------------------+
```

**MCP server cũng là một service production** → nó cần đúng những thứ MLOps đã dạy:
versioning, CI/CD, test tự động, observability, rollback, quản lý cost.

---

## 4. LLMOps – phần giao nhau thực sự

Khi bạn đưa một hệ agent dùng MCP ra production, các practice sau là **MLOps áp
dụng cho LLM**:

| Vấn đề | Practice |
|---|---|
| Tool schema đổi làm agent gãy | Version hóa MCP server; contract test cho từng tool; canary theo tool |
| Không biết agent làm đúng không | **Eval suite**: bộ task cố định, chấm điểm tự động, chạy trong CI trước mỗi release |
| Prompt/model đổi → hành vi đổi | Version prompt như code; A/B hoặc shadow traffic; giữ được rollback |
| Không debug được | **Tracing**: log toàn bộ chuỗi (user input → tool call → args → result → output), gắn trace-id |
| Chi phí bùng nổ | Đo token/session, cache, giới hạn số tool call mỗi turn |
| Drift | Với LLM là *behaviour drift*: provider đổi model version, dữ liệu nguồn đổi → chạy lại eval định kỳ |
| An toàn | Human-in-the-loop cho tool có side-effect; least privilege cho từng MCP server |

> Quy tắc thực dụng: **MCP cho bạn khả năng kết nối; LLMOps mới cho bạn niềm tin
> để bật nó lên cho khách hàng thật.**

---

## 5. Use case: MCP server trên AWS Serverless

Kiến trúc này tái sử dụng đúng những khối trong `01-Example-Aws-Serverless-Order-API.md`.

### 5.1. Kiến trúc

```text
  Agent / Claude / IDE
        |  Streamable HTTP + Bearer token
        v
  +--------------------------+
  |  API Gateway (HTTP API)  |
  |  JWT authorizer          |<---- Amazon Cognito (Authorization Server)
  +------------+-------------+
               |
               v
     +---------------------+
     |  Lambda: mcp-server |   (JSON-RPC handler: initialize, tools/list, tools/call)
     +----+-----------+----+
          |           |
          v           v
    DynamoDB      SQS / Step Functions
   OrdersTable    (tool có side-effect → xử lý async)
          |
          v
     CloudWatch Logs / X-Ray  (trace mọi tool call)
```

### 5.2. Ánh xạ khái niệm

| Khái niệm MCP | Thành phần AWS |
|---|---|
| Transport Streamable HTTP | API Gateway HTTP API, route `POST /mcp` (+ `GET /mcp` nếu cần SSE) |
| Authorization Server | Cognito User Pool (hoặc IdP doanh nghiệp) |
| Resource Server (MCP server) | Lambda + JWT authorizer, validate `aud` |
| Protected Resource Metadata | Route công khai `GET /.well-known/oauth-protected-resource` |
| Tool có side-effect | Lambda ghi vào SQS → consumer xử lý → tránh timeout 29s của API Gateway |
| Audit | CloudWatch Logs + X-Ray, log `tool_name`, `caller_sub`, `args_hash` |

### 5.3. Lưu ý triển khai

- **Streamable HTTP là stateless-friendly**: cố gắng thiết kế server **không giữ
  session state** trong Lambda (Lambda có thể bị recycle). Nếu cần state, đẩy vào
  DynamoDB với TTL.
- **Timeout**: API Gateway HTTP API giới hạn ~29–30s. Tool chạy lâu → trả về
  `jobId` ngay và cho agent poll bằng một tool `get_job_status`.
- **Cold start**: Lambda Python + boto3 nên giữ package nhỏ; init client boto3 ở
  scope module để tái sử dụng giữa các invocation.
- **Least privilege**: mỗi MCP server = một IAM role riêng, chỉ đúng bảng/queue
  cần thiết. Đừng gắn một role “god mode” cho server nhiều tool.
- **Rate limit**: dùng usage plan / throttling của API Gateway — agent có thể gọi
  tool trong vòng lặp và tự tạo ra một cuộc tấn công DoS vào chính backend của bạn.

---

## 6. Checklist bảo mật cho MCP

Đây là phần hay bị bỏ qua nhất khi mới nghịch MCP.

| Rủi ro | Mô tả | Giảm thiểu |
|---|---|---|
| **Prompt injection qua tool result** | Dữ liệu trả về từ tool (ticket, email, trang web) chứa chỉ thị lừa model | Coi mọi tool output là **untrusted**; tách rõ data vs instruction; không auto-execute hành động nguy hiểm |
| **Tool poisoning** | Server độc hại nhét chỉ thị vào description của tool | Chỉ cài server từ nguồn tin cậy; review tool description; pin version |
| **Rug pull** | Server đổi định nghĩa tool sau khi đã được duyệt | Pin version, hash tool schema, cảnh báo khi `list_changed` |
| **Confused deputy** | Server dùng quyền của mình làm việc thay attacker | Kiểm tra `aud` của token; ủy quyền theo user, không theo server |
| **Token passthrough** | Server chuyển tiếp token của client sang upstream | Cấm; dùng token exchange hoặc credential riêng |
| **Quyền quá rộng** | Một server truy cập được toàn bộ DB | Least privilege theo từng server; dùng **roots** để giới hạn phạm vi |
| **Thiếu human-in-the-loop** | Agent tự deploy/xóa/chuyển tiền | Bắt buộc xác nhận cho tool destructive; dùng **elicitation** |

---

## 7. Nên học cái nào trước?

| Bạn đang là… | Ưu tiên |
|---|---|
| Backend / DevOps / Cloud engineer (như repo này) | **MCP trước.** Bạn đã có sẵn API, IAM, serverless — MCP chỉ là một protocol layer mới trên nền đó. Học MLOps sau, ở mức đủ để hiểu eval + monitoring. |
| Data scientist | **MLOps trước.** Đó là cầu nối từ notebook ra production. MCP học sau khi cần build agent. |
| Muốn làm sản phẩm AI agent | **MCP để build, LLMOps để ship.** Bỏ qua phần training/feature store của MLOps cổ điển nếu bạn chỉ dùng model API. |
| Doanh nghiệp có model tự train | Cần **cả hai** đầy đủ. |

### Lộ trình gợi ý cho repo này

1. Viết một MCP server stdio bọc quanh Order API ở doc `01` (tool: `create_order`,
   `get_order_status`) → chạy local, test bằng MCP Inspector.
2. Đưa lên **remote**: Lambda + API Gateway + Cognito JWT authorizer (mục 5).
3. Thêm **eval suite**: ~20 câu hỏi mẫu, assert agent gọi đúng tool với đúng args;
   chạy trong CI.
4. Thêm **tracing** vào CloudWatch/X-Ray, dashboard: tool call count, error rate,
   latency P95 — tái dùng đúng tư duy dashboard ở doc `05`.
5. Khi nào thật sự cần train/fine-tune model riêng → mới bước vào MLOps đầy đủ
   (SageMaker Pipelines + Model Registry + Model Monitor).

---

## 8. Những hiểu nhầm thường gặp

| Hiểu nhầm | Thực tế |
|---|---|
| “MCP thay thế REST API” | Không. MCP thường **bọc quanh** REST API sẵn có, thêm mô tả để model hiểu được. |
| “Có MCP là không cần MLOps” | MCP không nói gì về train, eval, drift, deploy. Đó vẫn là việc của MLOps/LLMOps. |
| “MLOps chỉ dành cho ai train model” | Monitoring, eval, CI/CD, versioning áp dụng cho cả hệ dùng model API. |
| “MCP server = chỉ là một API endpoint” | Nó còn là một **bề mặt tấn công mới**: model tự quyết định gọi gì, với args gì. |
| “Cứ expose hết tool cho agent” | Càng nhiều tool, model càng chọn sai. Tool set nhỏ, mô tả rõ, đặt tên tốt sẽ chính xác hơn nhiều. |

---

## 9. Tóm tắt một dòng

> **MCP là cách agent chạm vào hệ thống của bạn. MLOps (và LLMOps) là cách bạn
> đảm bảo nó chạm đúng — hôm nay, và cả sáu tháng nữa.**
