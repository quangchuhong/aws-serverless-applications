# Bản đồ code Landing Zone — 19 layer, và ai apply cái nào

[`RUNBOOK.md`](../landing-zone/RUNBOOK.md) là trình tự dựng lần đầu. [Doc 22](./22-Nhat-ky-Trien-khai-LZ-DIY.md) là nhật ký lỗi. [Doc 28–30](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) là pipeline và khuôn mẫu code.

Tài liệu này là **bản đồ**: mở ngày đầu tiên, để biết thư mục nào là gì, ai chạm vào nó, và nó đọc state của ai. Không giải thích cơ chế — mỗi dòng trỏ tới doc có cơ chế.

---

## 0. Bốn con số đọc trước

| | |
|---|---|
| **19** | thư mục có code Terraform và có state riêng — 18 ở `landing-zone/`, cộng `network/ops` lồng bên trong `network/` |
| **7** | layer được **pipeline** apply |
| **12** | layer apply **bằng tay** |
| **2** | layer được **hai pipeline khác nhau** apply, với phạm vi và nhịp khác nhau — xem mục 3 |

Con số thứ tư là con số dễ gây nhầm nhất, và nó không phải lỗi.

---

## 1. Ba loại thư mục

**Layer** — có `versions.tf`, có khoá state riêng trong `tf-backend/outputs.tf`, `terraform apply` được. 19 cái.

**Không phải layer, nhưng có code** — không state, không tfvars, không apply:

| | Là gì | Ai dùng |
|---|---|---|
| `modules/tf-pipeline/` | module dựng pipeline: 30 biến, 10 output, 4 buildspec | 5 caller `ops-pipeline*` |
| `landing-zone/ops-gate/` | `gate.py`, `kiem-log.sh`, `test-gate.py` | mọi pipeline gọi từ source đã checkout — [doc 29](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) |
| `landing-zone/kiem-module.py` | 18 phép kiểm đối chiếu module ↔ mọi caller | người, bằng tay |

**Code bên trong một layer** — `trigger-filter/lambda/loc.py` là source của Lambda, đóng gói bởi chính layer `trigger-filter`.

---

## 2. Toàn bộ 19 layer

### Nền — dựng trước mọi thứ

| Layer | Nó là gì | Khoá state | Ai apply |
|---|---|---|---|
| `tf-backend` | Bucket state + bảng khoá DynamoDB + `wire-backends.sh` sinh `backend.tf` cho mọi layer khác | `bootstrap/terraform.tfstate` | **tay** |
| `organization` | Guardrail của tổ chức: SCP, cây OU hai tầng, tag policy, delegated administrator | `organization/terraform.tfstate` | `qh11-lz-ops` (sec) |

### Account và mạng

| Layer | Nó là gì | Khoá state | Ai apply |
|---|---|---|---|
| `account-baseline` | Baseline rải xuống account vừa vend, qua StackSet | `account-baseline/terraform.tfstate` | `vending-pipeline` (stage A, C) |
| `network` | Hạ tầng mạng nền, ~**200** resource: TGW, 17 subnet, 17 route table, security VPC, Network Firewall policy, VPN đối tác | `demo-network-lz-full/terraform.tfstate` | `vending-pipeline` (stage B, D) |
| `network/ops` | Bề mặt **vận hành mạng hằng ngày**: DNS nội bộ, VPC endpoint, route ngoại lệ, dịch vụ đối tác, luật tường lửa east-west | `demo-network-lz-full/ops/terraform.tfstate` | `qh11-lz-ops-network` |

### Nhật ký, phát hiện, quyền

| Layer | Nó là gì | Khoá state | Ai apply |
|---|---|---|---|
| `org-trail` | CloudTrail cấp tổ chức + bucket log có **object lock** ở log-archive | `org-trail/terraform.tfstate` | `qh11-lz-ops-trail` |
| `config-detective` | Cả lớp phát hiện: Config rule, recorder rải mọi account, aggregator, Security Hub, GuardDuty, bucket snapshot, **đường báo động** | `config-detective/terraform.tfstate` | `vending-pipeline` (E0, E) **và** `qh11-lz-ops-config-rules` |
| `permission-sets` | Permission set (bộ quyền) **và** assignment (ai vào account nào) | `permission-sets/terraform.tfstate` | `vending-pipeline` (F) **và** `qh11-lz-ops-permission-set` |

### Chi phí, tag, kho code

| Layer | Nó là gì | Khoá state | Ai apply |
|---|---|---|---|
| `billing-guard` | Budget + cảnh báo chi phí | `billing-guard/terraform.tfstate` | **tay** |
| `service-catalog` | Ép tag ở **thời điểm tạo** resource, không phải phát hiện sau | `service-catalog/terraform.tfstate` | **tay** |
| `codecommit-guard` | Chặn push trực tiếp vào `main` + bắt đi qua pull request của CodeCommit. **CHƯA BẬT** — xem mục 7 | `codecommit-guard/terraform.tfstate` | **tay** |

### Đường tự động

| Layer | Nó là gì | Khoá state | Ai apply |
|---|---|---|---|
| `vending-pipeline` | Pipeline vend account: **7 stage trên 4 layer**, và chủ sở hữu kho tfvars dùng chung | `vending-pipeline/...` | **tay** (bootstrap) |
| `trigger-filter` | Lambda lọc sự kiện commit trước khi chạm pipeline nào — [doc 29 phần I](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) | `trigger-filter/...` | **tay** (bootstrap) |
| `ops-pipeline` | caller → apply `organization`, 3 stage (`sec-ou`, `sec-scp`, `sec-tagging`) | riêng | **tay** (bootstrap) |
| `ops-pipeline-trail` | caller → apply `org-trail`, 1 stage | riêng | **tay** (bootstrap) |
| `ops-pipeline-permission-set` | caller → apply `permission-sets`, 1 stage | riêng | **tay** (bootstrap) |
| `ops-pipeline-config-rules` | caller → apply `config-detective`, 1 stage | riêng | **tay** (bootstrap) |
| `ops-pipeline-network` | caller → apply `network/ops`, 2 stage (một có cổng duyệt) | riêng | **tay** (bootstrap) |

### Không dùng

| Layer | Nó là gì |
|---|---|
| `control-tower` | Bản Control Tower, giữ để **đối chiếu** với bản DIY — [doc 21](./21-Control-Tower-vs-DIY.md). Không dựng. |

---

## 3. Hai layer được hai pipeline apply — và vì sao đó là thiết kế

`config-detective` và `permission-sets` mỗi cái có **hai** pipeline chạm vào, và chúng không tranh nhau vì **phạm vi khác nhau**:

| Layer | `vending-pipeline` | Pipeline ops |
|---|---|---|
| `config-detective` | stage `E0` + `E` — **cả layer** (recorder, aggregator, Security Hub, GuardDuty, bucket, đường báo động) | stage `cloudops-config-rules` — **1 resource**: `aws_config_organization_managed_rule` |
| `permission-sets` | stage `F` — **cả layer** (permission set, inline policy, user) | stage `cloudops-permission-set` — **2 resource**: assignment + group membership |

Đọc ra nguyên tắc:

> **Vending chạy khi có account mới — vài lần một tháng, và nó dựng cả layer.
> Pipeline ops chạy hằng tuần, và nó chỉ được chạm đúng thứ đổi hằng tuần.**

Đó là lý do `-target` tồn tại ở các stage ops (doc 28 mục 1.6): cùng một state, hai nhịp thay đổi rất khác nhau, không phải tách state.

Và đó cũng là lý do `network/` với `network/ops` là **hai layer** thay vì hai stage: mạng nền đổi vài lần một năm, lớp vận hành đổi hằng ngày, và chúng có **khối lượng state** rất khác (200 vs 16 resource).

**Hệ quả phải biết:** sửa một thứ thuộc phạm vi của vending mà chỉ chạy pipeline ops thì không có gì xảy ra, và ngược lại. Ví dụ thật — thêm một publisher vào SNS policy của `config-detective` nằm ngoài `-target` của `cloudops-config-rules`, nên phải apply tay:

```bash
cd landing-zone/config-detective && terraform apply -target=aws_sns_topic_policy.alerts
```

---

## 4. 12 layer apply bằng tay, chia hai nhóm

**Nhóm 1 — bootstrap: không thể tự apply chính nó** (8 layer)

```
tf-backend                     giữ state của mọi layer khác
vending-pipeline               pipeline không tự dựng lại chính nó
trigger-filter                 thứ quyết định pipeline nào chạy
ops-pipeline                   ┐
ops-pipeline-trail             │ năm caller: apply chúng là đổi
ops-pipeline-permission-set    │ định nghĩa của chính đường tự động
ops-pipeline-config-rules      │
ops-pipeline-network           ┘
```

**Nhóm 2 — chưa có pipeline, hoặc cố ý để tay** (4 layer)

```
billing-guard        đổi vài lần một năm
service-catalog      đổi vài lần một năm
codecommit-guard     chưa bật (mục 7)
control-tower        không dựng
```

Khác biệt giữa hai nhóm không phải hình thức: nhóm 1 **không bao giờ** nên có pipeline (một pipeline tự apply định nghĩa của chính nó là một vòng không có chỗ dừng), còn nhóm 2 chỉ là chưa cần.

---

## 5. Thứ tự dựng

```
1. tf-backend         ← trước mọi thứ: nó giữ state của phần còn lại
2. organization       ← OU + SCP; delegated administrator cho các layer sau
3. Account            ← thủ công, và KHÔNG xoá được
4. Identity Center    ← console, không Terraform
5. permission-sets
6. billing-guard
7. config-detective   ← cần delegated admin từ bước 2
8. org-trail          ← cần delegated admin từ bước 2
9. account-baseline
10. network
11. network/ops       ← đọc state của network
```

Rồi mới tới đường tự động: `vending-pipeline` → năm `ops-pipeline*` → `trigger-filter` **bật sau cùng**, và chỉ sau đó mới đặt `tu_kich_hoat = false` ở từng pipeline (doc 28 mục 2.1).

Xoá thì **ngược chiều**, và có hai cái móc không suy ra được từ sơ đồ này — xem [`TEARDOWN.md`](../landing-zone/TEARDOWN.md) mục 11.

---

## 6. Ai đọc state của ai

Chỉ có **hai** cạnh phụ thuộc state trong cả hạ tầng, và cả hai đều phải khai tường minh ở caller pipeline qua `state_chi_doc`:

```
account-baseline/terraform.tfstate
   ├──► permission-sets      (danh sách account vừa vend)
   └──► config-detective     (danh sách account vừa vend)

demo-network-lz-full/terraform.tfstate       (layer network)
   └──► network/ops          (TGW, VPC, vùng, firewall policy)
```

**Vì sao ít cạnh là chủ đích:** mỗi cạnh là một layer có thể làm layer khác chết. Thiếu một dòng `state_chi_doc` thì plan chết với `403 Forbidden` trên S3, và thông báo không nhắc gì tới `terraform_remote_state` (doc 30 mục 4).

Và cạnh thứ hai là cạnh đã dạy chúng ta thứ tự teardown: `network/ops` đọc state của `network`, nên **xoá cha trước thì không destroy được con nữa** — mọi `local.hub.*` mất nền, và plan không chạy được.

---

## 7. Hai layer đặc biệt

### `control-tower` — viết để đối chiếu, không dựng

Quyết định đã chốt: **DIY**. Layer này giữ lại để so sánh hai cách dựng nền tảng ([doc 21](./21-Control-Tower-vs-DIY.md)). Biến `core_account_emails` của nó là `object` với mặc định rỗng — không phải chỗ bị quên điền, mà là chỗ cố ý để trống.

### `codecommit-guard` — đã viết, CHƯA bật, và bật nó đổi quy trình

```hcl
variable "enable" {
  type    = bool
  default = false
}
```

Nó có hai phần, và chú thích đầu file gọi đúng cái bẫy: **một phần không đủ.**

| Phần | Chặn cái gì |
|---|---|
| approval rule template | áp dụng cho **pull request** của CodeCommit |
| IAM Deny `GitPush` | chặn **push trực tiếp** |

Chỉ bật approval rule thì ai cũng push thẳng vào `main` và không qua review. Chỉ bật Deny thì không có đường nào hợp lệ để đưa code vào.

**Bật nó là đổi quy trình hằng ngày.** Hôm nay `git push codecommit HEAD:main` chạy được — vì layer này đang tắt. Khi bật, đường đó bị Deny, và mọi thay đổi phải đi qua một pull request **của CodeCommit** với approval rule. Lúc đó:

- Quy trình 8 bước ở [doc 30 mục 14](./30-Khuon-mau-Code-Layer-va-Caller-Pipeline.md) phải viết lại: bước 4 không còn là push mà là mở PR trên CodeCommit.
- Và câu *"không có PR nên không có chỗ nào tự nhiên để một thay đổi bị đọc bởi người thứ hai"* (doc 28 mục 1.2) hết đúng — cơ chế `loosen` vẫn có giá trị, nhưng nó không còn là **thứ duy nhất** thay cho diff của PR.

Còn thiếu để bật: ARN thật của nhóm security trong `terraform.tfvars` (hiện là placeholder).

---

## 8. Một câu hỏi hay gặp: tôi sửa file này thì cái gì chạy

| Bạn sửa | Cái gì chạy |
|---|---|
| `network/ops/catalog/*.yaml` | `qh11-lz-ops-network` — Lint → Plan → (duyệt nếu là firewall) → Apply → Verify |
| `organization/catalog/scp.yaml` | `qh11-lz-ops` — ba stage `sec-*` |
| `org-trail/*.tf` | `qh11-lz-ops-trail` |
| `config-detective/*.tf` | `qh11-lz-ops-config-rules` — **nhưng chỉ apply được 1 resource trên 75** |
| `permission-sets/*.tf` | `qh11-lz-ops-permission-set` — **chỉ assignment và group membership** |
| `ops-gate/gate.py` | `ops-network` chạy ngay; **bốn pipeline kia dùng bản mới ở lần chạy sau của chúng** |
| `terraform.tfvars` bất kỳ | **không gì cả** cho tới khi `./push-tfvars.sh`, và ngay cả lúc đó cũng không kích hoạt pipeline |
| `modules/tf-pipeline/**` | **không gì cả** — phải `terraform apply` từng caller `ops-pipeline*` bằng tay |
| `docs/**`, `*.md` | không pipeline nào *nên* chạy — nhưng `ops-network` vẫn chạy nếu `tu_kich_hoat = true` |

Dòng cuối là chỗ đang gây ồn: `tu_kich_hoat = true` ở `ops-network` nghĩa là **mọi** commit vào `main` làm nó chạy và park một phiếu duyệt, kể cả một commit chỉ sửa tài liệu.

---

## 9. Thuật ngữ — thư mục này gọi là gì ở ngoài kia

Bộ code này đặt tên thư mục bằng chức năng của nó trong tổ chức. Cộng đồng cloud/devops có tên **tiếng Anh** riêng cho từng thứ, và biết tên đó có ba cái lợi: tìm tài liệu được, nói chuyện với người ngoài được, và biết mình đang tự viết lại cái gì đã có sẵn trên thị trường.

### 9.1 Gọi cả bộ này là gì

| Tên | Dùng khi nào |
|---|---|
| **Custom landing zone** (hay *DIY / hand-rolled / self-managed landing zone*) | Chính xác nhất. AWS dùng chữ *custom-built landing zone* để đối lập với *service-based* (Control Tower) |
| **Landing zone as code** | Khi muốn nhấn rằng toàn bộ nền tảng nằm trong IaC |
| **Cloud foundation** | Tên trung lập giữa các cloud — Azure gọi *Azure Landing Zones (ALZ)*, GCP có *Cloud Foundation Fabric* |
| **Cloud platform engineering** | Tên của **nghề**, không phải của sản phẩm |

Đội làm việc này: **platform team**, **cloud platform team**, hoặc **CCoE** (Cloud Center of Excellence).

### 9.2 Từng phần trong repo

| Trong repo này | Tên cộng đồng | Ghi chú |
|---|---|---|
| `vending-pipeline` | **Account Vending Machine (AVM)** · **account factory** | AWS đặt ra từ *account vending machine* ở giải pháp landing zone đời đầu. Bản Terraform chính thức của AWS tên là **AFT — Account Factory for Terraform** |
| `account-baseline` | **account baseline** · **account bootstrap** | Đúng từ, dùng nguyên |
| `organization` — SCP, tag policy | **preventive guardrails** | CT gọi là *controls*; trước đây gọi là *guardrails* |
| `config-detective` | **detective controls** · **detective guardrails** | Phát hiện sau, đối lập với preventive |
| `ops-gate/gate.py` | **policy as code**, cụ thể là **plan-time policy enforcement** | Bản thương mại của đúng việc này: **OPA/Conftest**, **HashiCorp Sentinel**, **Checkov**, **tfsec**. `gate.py` là một *home-grown policy engine* |
| `catalog/*.yaml` có `ticket` + `expires` | **exception management** · **time-bound exceptions** | Mở port bằng sửa YAML rồi qua duyệt: *self-service through code review* |
| 5 pipeline `ops-pipeline*` | **TACOS** — *Terraform Automation and Collaboration Software* | Từ này có thật và đang dùng rộng: Terraform Cloud, Spacelift, env0, Atlantis, Scalr đều tự gọi mình là TACOS. Ta đã tự viết một cái |
| `approve_stages` | **manual approval gate** · **change gate** | Ngữ cảnh kiểm toán: **segregation of duties (SoD)** |
| Job drift, không có nhánh apply | **drift detection**, chế độ **detect-only** | Chiều ngược lại là **continuous reconciliation** / **self-healing** |
| 7 script `verify.sh` | **post-deployment verification** · **infrastructure acceptance testing** | Công cụ tương đương: **Terratest**, **InSpec**, **Config conformance pack** |
| 126 `precondition` / `check` | **assertions in IaC** | Terraform gọi thẳng là *custom conditions* |
| 19 layer, mỗi layer một state | **state isolation** để giảm **blast radius**; kiến trúc **layered stacks** | Phản đề — một state khổng lồ cho cả hạ tầng — Gruntwork đặt tên là **terralith** |
| `modules/tf-pipeline` + 5 caller | **root module** vs **child module**; caller mỏng bọc module dày là **wrapper module** | |
| `tf-backend`, và việc pipeline không tự dựng lại chính nó (mục 4) | **the bootstrap problem** · **seed / bootstrap stack** | |
| Mô hình đội nền tảng lo guardrail, đội khác tự phục vụ bên trong | **paved road** (Netflix) · **golden path** (Spotify) | |
| Rủi ro ở mục 4 của [doc 33](./33-Danh-gia-DIY-vs-Control-Tower-Sau-Khi-Dung.md) | **bus factor** · **key person risk**; hệ thống tự viết kiểu này bị gọi là **bespoke**, gắt hơn là **snowflake** | |
| `network/` — TGW + VPC kiểm tra | **hub-and-spoke** với **centralized inspection** / **centralized egress** | Đây là từ khoá để tìm whitepaper của AWS về multi-VPC |

### 9.3 Ba cái tên **không** đúng với bộ này

Dùng sai ba từ này là chỗ hay bị vặn lại khi trình bày với kiểm toán hoặc khi phỏng vấn:

| Từ | Vì sao không đúng |
|---|---|
| **GitOps** | GitOps đòi **continuous reconciliation**: một agent liên tục so trạng thái thật với git rồi *tự kéo về*. Ở đây là **push-based CI/CD**, và job drift **cố ý không có nhánh apply**. Gọi đúng là **pipeline-driven IaC** |
| **IDP** (Internal Developer Platform) | IDP nhấn vào **developer self-service** — portal, catalog dịch vụ, lập trình viên tự bấm (Backstage, Port, Humanitec). Bộ này hướng vào **governance**, người dùng là đội vận hành |
| **SRE** | Khác nghề. SRE lo SLO, error budget, độ tin cậy lúc chạy. Đây là **platform / infrastructure engineering** |

### 9.4 Một câu để mô tả bộ này ra ngoài

> Một **custom AWS landing zone** dựng bằng Terraform — multi-account guardrails, **account vending**, hub-and-spoke network với **centralized inspection** — vận hành bằng **pipeline-driven IaC** có **policy-as-code gate** đọc plan, **manual approval**, **drift detection** và **post-apply verification**.

Câu này dùng đúng từ khoá mà người cùng nghề nhận ra ngay, và không có từ nào nói quá so với thứ thật sự có trong code.

---

## Liên quan

- [`landing-zone/RUNBOOK.md`](../landing-zone/RUNBOOK.md) — trình tự dựng, từng lệnh
- [`landing-zone/TEARDOWN.md`](../landing-zone/TEARDOWN.md) — thứ tự xoá, và hai cái móc ở mục 11
- [Doc 28 — Pipeline vận hành LZ](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) — năm pipeline, sáu lớp kiểm, sáu layer chi tiết
- [Doc 29 — Bộ lọc kích hoạt và cổng chặn](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) — `loc.py`, `gate.py`, `kiem-log.sh`
- [Doc 30 — Khuôn mẫu code](./30-Khuon-mau-Code-Layer-va-Caller-Pipeline.md) — mười hai việc hay gặp khi sửa code
- [Doc 22 — Nhật ký triển khai](./22-Nhat-ky-Trien-khai-LZ-DIY.md) — từng lỗi, theo thứ tự gặp
- [Doc 20 — Remote state](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) · [Doc 21 — Control Tower vs DIY](./21-Control-Tower-vs-DIY.md)
