# Khuôn mẫu code — sửa một layer, và caller pipeline của nó

[Doc 28](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) nói pipeline hoạt động ra sao và vì sao. [Doc 29](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) nói hai bộ phận dùng chung. Tài liệu này là thứ mở ra khi bạn **sắp gõ code**: mười hai việc hay gặp, mỗi việc kèm khuôn mẫu thật, cách kiểm, và hỏng ra sao nếu làm sai.

Nguyên tắc chung của cả repo, và nó giải thích phần lớn những gì bên dưới:

> **Một thay đổi phải hoặc chạy được, hoặc làm cái gì đó đỏ. Không được có trạng thái thứ ba.**

Phần lớn khuôn mẫu ở đây tồn tại vì đã từng có trạng thái thứ ba: một dòng được ghi ra, không ai đọc, không có gì đỏ.

---

## 0. Layer nào dùng khuôn mẫu nào

| | `organization` | `org-trail` | `permission-sets` | `config-detective` | `network/ops` |
|---|---|---|---|---|---|
| Chủ sở hữu | sec | cloudops | cloudops | cloudops | cloudops |
| Catalog YAML | 1 file | — | — | — | **6 file** |
| `lint.sh` offline | ✓ (+ `test-lint.sh`) | — | `validate-policies.sh` | — | ✓ |
| Script verify | `kiem-to-chuc.sh` | `kiem-trail.sh` | `kiem-quyen.sh` | `kiem-config.sh` | `../kiem-mang.sh` |
| `check` block | **15** | 4 | 8 | **16** | 13 |
| Chốt cứng `terraform_data` | `scp_guard` (2) | — | — | — | `catalog_guard` (**31**) |
| Đọc state layer khác | — | — | ✓ | ✓ | ✓ |
| `teardown.tf` | — | ✓ | — | ✓ | — |
| Chạy ở account khác | — | log-archive | — | security | **network** |

Hai điều đọc ra được từ bảng này:

- **Catalog không phải mặc định.** Chỉ hai layer có, và đúng hai layer đó là hai layer bị sửa nhiều nhất. Layer đổi vài lần một năm thì biến trong tfvars là đủ — thêm một lớp YAML là thêm một lớp phải bảo trì.
- **`check` block là khuôn mẫu phổ biến nhất**: 56 cái trên năm layer. Nó rẻ, và nó là cách viết ra một điều kiện mà không làm apply thất bại.

---

# Phần I — Code của layer

## 1. Thêm một mục vào catalog

Áp dụng cho `network/ops` (6 file) và `organization` (1 file).

**Sửa ở đâu:** `<layer>/catalog/<tên>.yaml`. Không sửa file `.tf` nào.

```yaml
# network/ops/catalog/firewall-rules.yaml
rules:
  - id: fw-0001
    from: probe                 # tên app, không phải CIDR
    to: app-dev
    ports: [80]
    ticket: NET-1001
    note: Probe đo đường xuống dev qua HTTP
    expires: 2027-12-31         # bỏ trống = vĩnh viễn
```

**Cách code đọc nó:**

```hcl
# network/ops/main.tf:113
locals {
  fw_raw = try(yamldecode(file("${path.module}/${var.catalog_dir}/firewall-rules.yaml")).rules, [])
}
```

`try(..., [])` **không phải cho gọn**. `yamldecode` trả về `null` cho một file chỉ có comment, và `null[...]` làm Terraform báo `Invalid index` ở **một dòng không liên quan gì tới file YAML**. Với `try`, một file rỗng đọc ra danh sách rỗng — trạng thái hợp lệ, nghĩa là "chưa có rule nào".

**Kiểm:**

```bash
cd landing-zone/network/ops && ./lint.sh --strict
```

Offline, không gọi AWS, không cần state. Chạy được ngay sau khi gõ, và stage `Lint` của pipeline chạy đúng lệnh này.

**Trường `expires` không tự làm gì.** Một rule quá hạn **không tự biến mất** — nó xuất hiện trong output `expired` và ở stage `Expiry` của pipeline. Đó là chủ đích: một luật tường lửa tự bốc hơi lúc nửa đêm là một sự cố, không phải một tính năng.

**Số mục trong catalog ≠ số dòng luật ở AWS.** Một mục `ports: [80, 443]` thành một dòng Suricata phủ hai port. Đừng so hai số đó — `kiem-mang.sh` cố ý không so, và nói ra là nó không so.

## 2. Layer chưa có catalog thì sửa ở đâu

Ba layer còn lại khai bằng **biến trong tfvars**:

```hcl
# config-detective/terraform.tfvars
organization_rules = [
  "cloud-trail-enabled",
  "encrypted-volumes",
  ...
]
```

**Và tfvars nằm trong `.gitignore`.** Nên sửa nó là hai bước, không phải một:

```bash
# 1. sửa file trên máy
# 2. đẩy lên kho tfvars - pipeline đọc từ S3, KHÔNG từ git
cd landing-zone/vending-pipeline && ./push-tfvars.sh
```

Bỏ bước 2 thì pipeline chạy với **bản tfvars cũ**, plan ra "không có thay đổi", và không có gì sai ở đâu cả.

Và đẩy tfvars lên S3 **không kích hoạt pipeline** — EventBridge nghe CodeCommit, không nghe S3. Sửa chỉ tfvars thì phải tự chạy:

```bash
aws codepipeline start-pipeline-execution --name qh11-lz-ops-config-rules
```

## 3. Thêm một resource mới vào layer — bốn chỗ, cùng lúc

Đây là việc dễ làm nửa vời nhất trong cả repo.

| # | Sửa ở đâu | Bỏ thì sao |
|---|---|---|
| 1 | `<layer>/*.tf` — resource | — |
| 2 | caller `local.stages[].targets` | resource **không vào plan** → pipeline không bao giờ apply nó, và job drift báo lệch **vĩnh viễn** |
| 3 | `ops-gate/gate.py` → `PHAM_VI[stage]` | resource vào plan rồi bị cổng từ chối `NGOAI PHAM VI` → plan **đỏ** |
| 4 | `ops-gate/gate.py` → `LUAT` *(cân nhắc)* | loại không có trong bảng thì cổng **bỏ qua hoàn toàn** — không đọc được chiều nới/thắt của nó |

Chỗ 2 và 3 hỏng theo **hai kiểu khác nhau**, và sửa chỗ 2 làm lộ chỗ 3. Đã xảy ra thật khi đưa `terraform_data.catalog_guard` vào phạm vi (doc 28 mục 4).

**Kiểm cả bốn:**

```bash
cd landing-zone && python3 kiem-module.py     # phép kiểm 18 đối chiếu chỗ 2 với chỗ 3
python3 ops-gate/test-gate.py                 # 43 test
```

**Dạng địa chỉ hay dạng type ở `PHAM_VI`?** Dạng **địa chỉ** khi resource là một cái cụ thể (`terraform_data.catalog_guard`), dạng **type** khi stage được quản mọi resource cùng loại (`aws_route53_record`). Cho cả type một loại nguy hiểm — ví dụ `terraform_data` — nghĩa là mọi resource loại đó trong tương lai cũng qua được, kể cả một cái mang `provisioner` chạy lệnh cục bộ.

## 4. Cho layer đọc state của layer khác

**Trong layer:**

```hcl
data "terraform_remote_state" "hub" {
  backend = var.state_backend
  config  = local.state_config
}
```

rồi dùng `data.terraform_remote_state.hub.outputs.<gì đó>`.

**Trong caller pipeline — bắt buộc, và hay quên:**

```hcl
state_chi_doc = [
  "demo-network-lz-full/terraform.tfstate",
]
```

Module chỉ cấp `s3:GetObject` cho những khoá này — **không bao giờ cấp ghi**. Thiếu dòng đó thì plan chết:

```
data.terraform_remote_state.vending[0]: Reading...
Error: Unable to access object "account-baseline/terraform.tfstate"
in S3 bucket "...": StatusCode: 403, Forbidden
```

Thông báo đó nói về **S3**, không nhắc một chữ nào tới `terraform_remote_state`. Cách tìm khoá cần khai:

```bash
grep -rn 'terraform_remote_state' <layer>/*.tf     # xem nó đọc biến nào
# rồi tra biến đó ở landing-zone/tf-backend/outputs.tf, local.layers
```

## 5. Cho layer chạy ở account khác

**Layer tự assume trong provider, KHÔNG assume trong buildspec.**

```hcl
# <layer>/versions.tf
provider "aws" {
  region = var.region
  # ...
  assume_role { role_arn = var.assume_role_arn }   # rỗng = dùng chính credential đang có
}
```

Buildspec chỉ export biến:

```sh
if [ -n "${ASSUME_ROLE_ARN:-}" ]; then
  export TF_VAR_assume_role_arn="${ASSUME_ROLE_ARN}"
fi
```

**Vì sao không `aws sts assume-role` rồi export `AWS_ACCESS_KEY_ID`:** làm vậy thì **cả backend cũng nhảy** theo, và CodeBuild mất quyền đọc bucket state ở account management. Hoặc tệ hơn: đọc được **một state khác**, và plan đòi tạo lại toàn bộ. Nên backend giữ credential của CodeBuild, provider nhảy sang account đích.

**Và một hệ quả phải xử lý bằng tay** — khi layer đọc state layer cha *và* assume sang account khác:

```hcl
# network/ops/main.tf:59
state_config_hieu_luc = var.assume_role_arn == "" ? var.state_config : {
  for k, v in var.state_config : k => v if k != "profile"
}
```

`state_config` trong tfvars có `profile = "default"` cho người chạy tay. Trong CodeBuild không có file `~/.aws/config`, nên `profile` đó làm `terraform_remote_state` chết với:

```
failed to get shared config profile, default
```

Một thông báo không nhắc gì tới `state_config` hay `profile` của tfvars. Nên phải **lược `profile` ra** khi đang assume. Cùng logic ở `versions.tf`:

```hcl
profile = var.assume_role_arn == "" && var.aws_profile != "" ? var.aws_profile : null
```

**Một layer, hai đường vào:** người chạy tay dùng `aws_profile`, CodeBuild dùng `assume_role_arn`. Hai đường đó không được đá nhau, và tfvars dùng chung cho cả hai.

## 6. Thêm một phép kiểm: `check` hay `precondition`

Cách chọn đã ghi ở [doc 27](./27-Van-hanh-Account-Vending.md); ở đây là quy tắc ngắn:

| | `check` block | `lifecycle.precondition` |
|---|---|---|
| Khi điều kiện sai | **cảnh báo**, apply chạy tiếp | **plan chết** |
| Dùng cho | "nên xem lại" — một lựa chọn hợp lệ nhưng phải là lựa chọn | "sai, và không được đi tiếp" |
| Ví dụ | firewall đang `alert` nên rule không quyết định gì | rule trỏ tới một app **không tồn tại** |
| Đặt ở đâu | bất cứ file `.tf` nào | trong `lifecycle` của một resource |

**Và một cái bẫy lớn của `precondition`:** nó **chỉ được tính khi resource nằm trong plan**. Mọi stage đều `-target`, nên một `precondition` trên resource không được target sẽ **không bao giờ chạy** trên đường tự động. Đó là cách 33 chốt cứng từng vắng mặt suốt nhiều lần chạy (doc 28 mục 3.3). Nếu bạn đặt `precondition`, quay lại mục 3 chỗ số 2 và 3.

Khuôn mẫu chốt cứng dùng chung: một `terraform_data` không tạo gì ở AWS, chỉ để mang `precondition` và một `input` buộc plan tính lại khi catalog đổi:

```hcl
resource "terraform_data" "catalog_guard" {
  input = { apps = length(local.apps_raw), rules = length(local.fw_raw), ... }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == local.hub.account_id
      error_message = "..."
    }
    # ... 30 precondition nữa
  }
}
```

## 7. Viết output cho người, không cho máy

Khuôn mẫu này có ở năm layer, và nó không phải trang trí: `next_steps` là chỗ ghi những việc **Terraform không làm được** nhưng thiếu thì hệ thống hỏng im lặng.

```hcl
output "next_steps" {
  value = <<-EOT
    1. XAC NHAN EMAIL, ROI KIEM LAI BANG LENH.
       SNS gui thu xac nhan toi tung dia chi trong alert_emails.
       CHUA BAM LINK = KHONG NHAN DUOC CANH BAO NAO.
       TERRAFORM KHONG KIEM DUOC VIEC NAY. ...
  EOT
}
```

Hai quy tắc học được từ những output này:

- **Kèm lệnh kiểm, không chỉ kèm lời khuyên.** `"phải bấm link xác nhận"` là lời khuyên; `aws sns list-subscriptions-by-topic ... --query '...'` kèm câu *"cột cuối PHẢI là ARN kết thúc bằng UUID"* là một phép thử.
- **Nói cả cái không kiểm được, và vì sao.** `output` của `config-detective` giải thích luôn ba nguyên nhân của trạng thái `Deleted` và cái nào `-replace` không sửa được.

**Một lưu ý kỹ thuật:** heredoc trong output bị bộ đọc log của pipeline khớp như dữ liệu. Nếu output của bạn chứa chữ `Warning:` hay `Error:`, `kiem-log.sh` sẽ đếm nó thành một phát hiện. Nó đã có lớp lọc heredoc, nhưng đừng thử thách lớp đó.

## 8. Khoá một layer khỏi destroy

Hai layer dùng khuôn mẫu này (`org-trail`, `config-detective`), và nó gồm ba phần:

```hcl
# 1. cổng: một biến phải bật tường minh mới destroy được
variable "allow_destroy" { type = bool, default = false }

# 2. resource đọc nó
force_destroy = var.allow_destroy

# 3. và một check KÊU khi cổng đang mở
check "destroy_guard_still_on" {
  assert {
    condition     = !var.allow_destroy
    error_message = "allow_destroy = true: bucket CloudTrail dang o che do force_destroy, mot lan destroy la mat bang chung kiem toan cua ca to chuc. Dung neu dang teardown. Xong viec - hoac neu doi y - dat lai false va apply."
  }
}
```

Phần 3 là phần hay bị bỏ, và nó là phần quan trọng nhất: `allow_destroy = true` là trạng thái **tạm thời**. Để sót lại thì hạ tầng thường trú đang không còn lớp chặn nào, và **không có gì trong `terraform plan` nhắc bạn cả**.

`check` chứ không phải `precondition` ở đây là có chủ đích: giữa lần apply "mở khoá" và lần destroy, plan **phải chạy được**.

---

# Phần II — Code của caller pipeline

Thiết kế và trình tự dựng một pipeline mới ở [doc 28 mục 8–9](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md). Ở đây là phần dùng.

## 9. Một caller gồm những gì

```
landing-zone/ops-pipeline-<tên>/
  main.tf        local.stages + module block + quyền
  variables.tf   enable_*_stage, approve_stages, drift_*, …
  outputs.tf     next_steps, drift_project, cong_duyet
  versions.tf
  terraform.tfvars.example
```

Caller chỉ khai **cái gì** chạy; module `modules/tf-pipeline` (30 biến, 10 output) dựng **chạy thế nào**: CodePipeline, 4 CodeBuild project, IAM role, artifact bucket, topic duyệt, job drift.

## 10. Sáu trường của một stage

```hcl
{
  key     = "cloudops-network"              # DUY NHẤT toàn cục, mang tiền tố chủ sở hữu
  layer   = "landing-zone/network/ops"
  enabled = var.enable_network_stage

  targets = [
    "terraform_data.catalog_guard",
    "aws_route53_record.ops",
    ...
  ]

  khong_co_lint   = "network/ops không có catalog - phép kiểm ý nghĩa là gate.py"
  assume_role_arn = var.network_deploy_role_arn
  mo_ta           = "DNS record, endpoint, route, load balancer, alarm. Không có cổng duyệt - thay đổi sai ở đây có triệu chứng ngay."
}
```

| Trường | Bỏ được không | Bỏ thì sao |
|---|---|---|
| `key` | không | phải duy nhất toàn cục: `PHAM_VI` của `gate.py` là **một bảng dùng chung**, hai stage trùng tên đè nhau và cái bị đè lặng lẽ nhận phạm vi của cái kia |
| `layer` | không | — |
| `enabled` | không | — |
| `targets` | được (rỗng = apply cả layer) | rỗng thì **không giới hạn phạm vi**, và `precondition` của cả layer vào plan sẵn |
| `lint` **hoặc** `khong_co_lint` | không — phải có **một trong hai** | một stage không lint *và* không giải thích là một stage chỉ còn `FAIL_ON_DESTROY`, tức chỉ còn phép đếm |
| `assume_role_arn` | được (rỗng = chạy bằng credential CodeBuild) | xem mục 11 |
| `mo_ta` | không | nó in ra trong `next_steps` và trong bản ghi của cổng duyệt |

## 11. Cái bẫy đắt nhất của caller: type của `var.stages`

**Terraform âm thầm bỏ thuộc tính không khai trong type constraint.**

```hcl
# modules/tf-pipeline/variables.tf
type = list(object({
  key = string
  # assume_role_arn KHÔNG có ở đây
}))
```

Caller khai `assume_role_arn = "arn:..."` → **bị bỏ đi, không lỗi, không cảnh báo**. Rồi `try(stage.value.assume_role_arn, "")` biến cái thiếu thành `""` — hai lớp im lặng. Lỗi hiện ra ba lớp xa:

```
failed to get shared config profile, default
```

Dấu hiệu thật là một dòng log **không xuất hiện**: `== provider se assume: ...`.

**Kiểm:**

```bash
cd landing-zone && python3 kiem-module.py    # phép kiểm 13 đối chiếu mọi stage.value.X với type
```

Quy tắc: thêm một trường vào `local.stages` thì **phải** thêm vào `type` của `var.stages` trong module, và **đừng** bọc nó trong `try()` — `try` biến một lỗi cấu hình thành một giá trị mặc định.

## 12. Bốn chỗ ngoài caller phải sửa cùng

| Chỗ | Khai gì | Quên thì sao |
|---|---|---|
| `ops-gate/gate.py` → `PHAM_VI` | stage mới + phạm vi | `gate.py` chỉ **cảnh báo** "stage không có trong bảng" — không kiểm được phạm vi mà vẫn xanh |
| `vending-pipeline/push-tfvars.sh` → `LAYERS` | layer mới | lỗi lúc pipeline chạy, và thông báo nói về S3 |
| `trigger-filter` → `ban_do` | tiền tố → tên **ngắn** của pipeline | pipeline tồn tại, xanh trong console, **không bao giờ chạy nữa** |
| `trigger-filter` → `tru` | nếu có layer lồng nhau | pipeline khác chạy vô ích, kèm một cổng duyệt treo mang nhãn sai |

Ba trong bốn chỗ này được `kiem-module.py` đối chiếu (phép kiểm 10, 11, 18).

---

## 13. Thứ tự kiểm trước khi push

Bốn lệnh, tất cả offline, tất cả chạy được trên máy:

```bash
cd landing-zone
./<layer>/lint.sh --strict          # nếu layer có catalog
python3 kiem-module.py              # 18 phép kiểm: module ↔ mọi caller
python3 ops-gate/test-gate.py       # 43 test cho cổng chặn
python3 trigger-filter/test-loc.py  # 39 test cho bộ lọc
```

Rồi **một lần plan đầy đủ bằng tay**, và đây là lệnh quan trọng nhất trong danh sách:

```bash
cd <layer> && terraform plan
```

Pipeline luôn `plan` có `-target`, nên nó **không thấy** những gì nằm ngoài phạm vi. Một `plan` đầy đủ là phép kiểm duy nhất thấy được cái mà `-target` bỏ qua — và đó là cách 33 precondition vắng mặt suốt nhiều lần chạy được phát hiện: một dòng `1 to change` lạ trên máy.

---

## 14. Một chỗ tài liệu trong code đã lạc hậu

Năm file vẫn dạy quy trình cũ:

```
account-baseline/catalog/accounts.yaml
network/ops/catalog/firewall-rules.yaml
network/ops/catalog/dns-records.yaml   (nhắc PR)
organization/scp-catalog.tf
network/ops/firewall.tf · routes.tf
```

Ví dụ header của `firewall-rules.yaml`:

```
#   1. them mot khoi vao day
#   2. ./lint.sh
#   3. mo PR - CI chay terraform plan va dan ket qua vao PR
#   4. co nguoi duyet, merge
#   5. terraform apply
```

Bước 1, 2 đúng. Ba bước còn lại **chỉ còn đúng một nửa**:

- PR trên GitHub **vẫn là** chỗ code review — sec review ở đúng hai chỗ, và đây là một.
- Nhưng **không có CI nào chạy `terraform plan` và dán vào PR nữa**. Plan xảy ra trong pipeline, **sau khi** bạn `git push codecommit`.
- Và **không ai `terraform apply` bằng tay**. Pipeline apply, và giữa plan với apply có `gate.py` cộng một cổng duyệt cho stage `cloudops-firewall`.

Quy trình đúng hôm nay:

```
1. thêm một khối vào catalog
2. ./lint.sh --strict
3. push GitHub → PR để review (không kích hoạt gì)
4. git push codecommit HEAD:main          ← cái này mới chạy
5. gate.py chặn nếu là NỚI → khai ops-loosen.yaml kèm ticket
6. một người duyệt ở cổng duyệt
7. pipeline apply, rồi Verify đọc lại từ AWS
8. xoá khai báo loosen + push  (nhịp 3 — xem doc 29)
```

Chưa sửa năm file đó. Sửa thì nên sửa một lượt, vì đó là văn bản người vận hành đọc hằng ngày.

---

## Sổ quyết định

| Quyết định | Lý do |
|---|---|
| Catalog YAML chỉ ở hai layer bị sửa nhiều nhất | layer đổi vài lần một năm thì biến tfvars là đủ; thêm lớp YAML là thêm lớp phải bảo trì |
| `try(yamldecode(...), [])` | `yamldecode` trả `null` cho file chỉ có comment, và `null[...]` báo `Invalid index` ở một dòng không liên quan |
| `expires` **không** tự xoá mục quá hạn | một luật tường lửa tự bốc hơi lúc nửa đêm là một sự cố, không phải tính năng |
| Provider tự assume, buildspec chỉ export biến | assume ở buildspec làm **cả backend** nhảy theo, và CodeBuild mất quyền đọc state |
| Lược `profile` khỏi `state_config` khi đang assume | CodeBuild không có `~/.aws/config`; thông báo lỗi không nhắc gì tới `state_config` |
| `check` cho "nên xem lại", `precondition` cho "không được đi tiếp" | và `precondition` **chỉ chạy khi resource nằm trong plan** — nhớ mục 3 |
| Không bọc trường mới của stage trong `try()` | `try` biến một lỗi cấu hình thành một giá trị mặc định |
| `output` mang lệnh kiểm, không chỉ lời khuyên | "phải bấm link xác nhận" là lời khuyên; một lệnh `aws` kèm câu "cột cuối PHẢI là ARN" là một phép thử |

---

## Liên quan

- [Doc 28 — Pipeline vận hành LZ](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) — năm pipeline, sáu lớp kiểm, sáu layer, và dựng một pipeline mới
- [Doc 29 — Bộ lọc kích hoạt và cổng chặn](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) — `loc.py`, `gate.py`, `kiem-log.sh`
- [Doc 27 — Vận hành account vending](./27-Van-hanh-Account-Vending.md) — `check` vs `precondition` chọn thế nào
- [Doc 20 — Remote state và quy trình thay đổi](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) — kiến trúc state, `wire-backends.sh`
- [Doc 25 — Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md) — catalog của `network/ops`, theo góc người dùng
- [`landing-zone/TEARDOWN.md`](../landing-zone/TEARDOWN.md) — thứ tự xoá, và cái móc Network Firewall ở mục 11
