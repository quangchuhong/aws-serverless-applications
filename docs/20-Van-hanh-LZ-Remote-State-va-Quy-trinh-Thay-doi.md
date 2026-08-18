# Vận hành LZ: Remote State và Quy trình thay đổi

Ví dụ 20: Chuyển từ "code Terraform chạy được" sang "hạ tầng vận hành được nhiều người, lâu dài".

> Code: [`landing-zone/tf-backend/`](../landing-zone/tf-backend/). Đây là layer **đầu tiên** phải dựng — mọi layer thường trực khác phụ thuộc vào nó.

---

## 0. Trạng thái triển khai

| Phần | Trạng thái |
|---|---|
| Bucket state + versioning + mã hoá + lifecycle | ✅ Đã viết |
| Khoá state (DynamoDB / S3 lockfile) | ✅ Đã viết, chọn qua biến |
| Bucket policy tách prefix theo account | ✅ Đã viết |
| `wire-backends.sh` sinh `backend.hcl` | ✅ Đã viết |
| `backend "s3" {}` cho các layer thường trực | ✅ Đã thêm (còn comment, bật khi chuyển) |
| `.gitignore` chặn commit state | ✅ Đã thêm |
| `terraform validate` / `plan` | ⏸ Chưa chạy được — registry Terraform bị chặn trong môi trường soạn tài liệu |
| MFA Delete | ⬜ Thủ công, cần credential root |
| CI/CD: plan trong PR, apply sau approve | ⬜ Doc 10 mới là thiết kế |
| Drift detection định kỳ | ⬜ Chưa làm |

---

## 1. Vì sao đây là việc đầu tiên

Trước layer này, toàn bộ repo dùng **state local** — không có `backend` block nào.

Với demo dựng–xoá thì đúng: state không có giá trị, xoá xong là hết. Với layer **thường trực** thì state là **thứ có giá trị nhất trong cả hạ tầng** — nó là bản đồ duy nhất nối code với resource thật trên AWS.

| Không có remote state | Xảy ra khi nào |
|---|---|
| State trên máy cá nhân | Bạn nghỉ phép → không ai apply được |
| Không có lock | Hai người apply cùng lúc → **state hỏng** |
| Không lịch sử | Không biết ai đổi gì, khi nào |
| Mất máy = mất state | Phải `terraform import` lại từng resource bằng tay |

Cái thứ hai là cái đến nhanh nhất. Hai người cùng `terraform apply` trên một layer, state ghi đè lẫn nhau, và Terraform mất dấu một phần resource. Không có thông báo lỗi rõ ràng — bạn chỉ phát hiện khi lần apply sau nó đòi tạo lại thứ đã tồn tại.

Và đây là việc **độc lập với mọi quyết định kiến trúc khác**. Dùng Control Tower hay DIY, dùng OU thế nào, SCP ra sao — đều cần remote state. Nên làm trước, không phải chờ chốt gì.

---

## 2. Kiến trúc state

```
s3://acme-lz-tfstate-111122223333/
├── bootstrap/terraform.tfstate           ← chính layer tf-backend
├── organization/terraform.tfstate        ← DIY: OU + SCP
├── control-tower/terraform.tfstate       ← bản đối chiếu, mặc định tắt
├── billing-guard/terraform.tfstate
├── permission-sets/terraform.tfstate
└── network/terraform.tfstate             ← chưa có code

DynamoDB: acme-lz-tfstate-lock   (hash key: LockID)
```

**Một bucket, mỗi layer một key.** Ba tính chất quan trọng:

| Tính chất | Nghĩa là |
|---|---|
| **Tách biệt** | Apply layer network không thể làm hỏng state của permission-sets |
| **Blast radius nhỏ** | State một layer hỏng thì chỉ layer đó phải khôi phục |
| **Apply song song được** | Khoá theo từng key, hai layer khác nhau chạy cùng lúc thoải mái |

### Vì sao một bucket chứ không phải mỗi account một bucket

| | Một bucket tập trung | Mỗi account một bucket |
|---|---|---|
| Backup, audit, lifecycle | Một chỗ | Nhân lên theo số account |
| Quyền | Bucket policy tách prefix | Đơn giản hơn |
| Rủi ro | Một điểm hỏng | Phân tán |
| Cross-account | Cần `BucketOwnerEnforced` | Không cần |

Chọn **một bucket** ở management account. Đổi lại phải xử lý đúng phần cross-account (mục 3.3).

---

## 3. Ba quyết định thiết kế

### 3.1 Khoá bằng gì

| Cách | Yêu cầu | Chi phí |
|---|---|---|
| **DynamoDB** *(mặc định)* | Mọi phiên bản Terraform | ~$0 với `PAY_PER_REQUEST` |
| **S3 native lockfile** | **Terraform ≥ 1.10** | $0, không thêm resource |

S3 native locking dùng conditional write của S3, gọn hơn — không phải quản thêm một bảng. Nhưng cần Terraform từ 1.10 trở lên.

Mặc định để `dynamodb` vì nó chạy với mọi phiên bản. Chuyển sang lockfile:

```hcl
lock_mode = "s3"     # backend se khai use_lockfile = true
```

Kiểm tra trước:

```bash
terraform version
```

> Tên thuộc tính hash key **phải** là `LockID` — Terraform hardcode tên này, đặt khác là không khoá được.

### 3.2 Mã hoá: SSE-S3 hay KMS

Mặc định `use_kms_cmk = false`.

**Cả hai đều mã hoá thật.** Khác biệt là quyền quản lý khoá:

| | SSE-S3 | KMS CMK |
|---|---|---|
| Chi phí | $0 | ~$1/tháng + phí request |
| Chặn đọc state | Phải thu quyền S3 | Thu quyền trên key là đủ, **kể cả khi còn quyền S3** |
| Audit | Log S3 | Thêm CloudTrail riêng mỗi lần dùng khoá |

Bật khi state bắt đầu chứa bí mật. Hai layer hiện tại không chứa — `billing-guard` chỉ có budget và tag, `permission-sets` chỉ có ARN và policy.

Nhưng biết trước: **state của layer database sau này sẽ chứa mật khẩu ở dạng rõ.** Terraform ghi mọi attribute vào state, kể cả `password`. Đến lúc đó thì bật.

### 3.3 Cross-account — hai cái bẫy

Layer network chạy ở account network nhưng ghi state vào bucket ở management.

**Bẫy 1: quyền sở hữu object.**

```hcl
resource "aws_s3_bucket_ownership_controls" "state" {
  rule { object_ownership = "BucketOwnerEnforced" }
}
```

Thiếu dòng này thì state do account network ghi lên **thuộc sở hữu của account network**, và management account có thể **không đọc được chính file trong bucket của mình**. Lỗi này rất khó đoán vì bucket là của bạn, quyền cũng có, mà vẫn `AccessDenied`.

**Bẫy 2: dùng KMS thì phải cấp quyền hai nơi.** Key policy (code đã làm) **và** IAM policy phía account con. Thiếu một nơi là `AccessDenied` ngay lúc `terraform init`.

Bucket policy tách prefix cho từng account:

```
account 2222  →  s3://<bucket>/network/*     ghi được
              →  s3://<bucket>/security/*    KHÔNG đọc được
```

---

## 4. Chuyển đổi an toàn

Đây là thao tác chạm vào state — làm sai thì mất dấu resource. Bốn nguyên tắc:

| Nguyên tắc | Vì sao |
|---|---|
| **Từng layer một** | Hỏng thì biết ngay layer nào |
| **`terraform plan` sau mỗi lần chuyển** | Phải ra **"No changes"** |
| **Ra diff thì DỪNG** | State chưa chuyển đủ. Đừng apply "cho nó xong" |
| **Giữ state local cho tới khi xác nhận xong** | Đó là bản sao lưu duy nhất |

```bash
# Buoc 1 - dung bucket (state con local)
cd landing-zone/tf-backend
terraform init && terraform apply

# Buoc 2 - sinh backend.hcl cho moi layer
./wire-backends.sh --dry-run
./wire-backends.sh

# Buoc 3 - chuyen chinh layer nay
#   bo comment  backend "s3" {}  trong versions.tf
terraform init -migrate-state -backend-config=backend.hcl
terraform state list
rm terraform.tfstate terraform.tfstate.backup

# Buoc 4 - tung layer con lai
cd ../billing-guard
terraform init -migrate-state -backend-config=backend.hcl
terraform plan          # PHAI la "No changes"
```

Bước 3 hay bị bỏ qua nhất, và nó là bước quan trọng nhất: **layer quản lý state mà state của nó nằm trên máy bạn** thì mất máy là mất quyền quản lý bucket state của cả tổ chức.

### Vì sao dùng `backend.hcl` chứ không viết thẳng vào `.tf`

Backend block **không nhận biến** — không dùng được `var.bucket` trong đó. Nên hoặc hardcode tên bucket vào code (mỗi người một môi trường là hỏng), hoặc dùng **partial configuration**:

```hcl
terraform {
  backend "s3" {}      # rong
}
```

```bash
terraform init -backend-config=backend.hcl
```

`backend.hcl` do `wire-backends.sh` sinh từ output của tf-backend, và nằm trong `.gitignore`.

---

## 5. Quy trình thay đổi hằng ngày

Đây là thứ remote state mở đường tới. Trước khi có nó, mọi thay đổi là "ai đó apply từ máy mình".

```
1. Sửa code          →  một dòng trong locals hoặc tfvars
2. Mở PR             →  CI tự chạy terraform plan
3. Đọc plan          →  người review xem đúng cái mình muốn không
4. Merge             →  CI apply, khoá state trong lúc chạy
5. Ghi lại           →  PR chính là biên bản thay đổi
```

Vài ví dụ cụ thể với code hiện có:

| Việc | Sửa gì | Ở đâu |
|---|---|---|
| Thêm người vào team network | Thêm `users` + `groups` | `permission-sets/terraform.tfvars` |
| Cho phép app-dev gọi app-prod cổng 443 | Thêm một dòng `east_west_rules` | stack network |
| Thêm service vào quyền app team | Thêm một dòng `svc_compute` | `permission-sets/locals-services.tf` |
| Account mới vào OU non-prod | Thêm ID vào `accounts_by_scope` | `permission-sets/terraform.tfvars` |
| Nâng ngưỡng budget | Sửa `org_monthly_budget_usd` | `billing-guard/terraform.tfvars` |

Điểm chung: **một dòng, một PR, một plan đọc được**. Đó là mục tiêu của cách chia code ở doc 19 — sửa ở một chỗ, hệ quả rõ ràng trên plan.

---

## 6. Task vận hành nào đã dùng được

Rà lại thực trạng repo:

| Task | Dùng được? | Ở đâu |
|---|---|---|
| Thêm/sửa permission set | ✅ | `landing-zone/permission-sets` |
| Thêm user, đổi group | ✅ | `permission-sets/identity.tf` |
| Budget, cost tag, cảnh báo | ✅ | `landing-zone/billing-guard` |
| **State, khoá, lịch sử** | ✅ | `landing-zone/tf-backend` ← **mới** |
| Cấp quyền cho account mới | ⚠️ Bán tự động | Sửa `accounts_by_scope` rồi apply |
| Networking day-2 | ⚠️ Cơ chế đúng, nhưng nằm trong demo | `demo/network-lz-full` |
| Tạo/đóng account | ❌ | Doc 09 mới là thiết kế |
| Sửa OU | ✅ | `landing-zone/organization` |
| Sửa SCP | ✅ | `landing-zone/organization` — 4 SCP |
| Upgrade Control Tower | ⚠️ Code sẵn, mặc định tắt | `landing-zone/control-tower` — xem mục 7 |

### Demo không phải layer vận hành

`demo/network-lz-full` gắn `Ephemeral = "true"`, có `teardown.sh`, chạy trong **một account**. Nó được thiết kế để **xoá đi**.

Cơ chế day-2 trong đó thì đúng — `east_west_rules` là interface tốt: thêm một dòng = mở một luồng, không phải sửa route nào. Nhưng cần nâng thành layer thường trực multi-account mới dùng vận hành được.

Demo **cố ý không** nối vào remote state: chúng không cần lịch sử, và thêm backend chỉ làm chậm việc dựng–xoá.

---

## 7. Control Tower: đã chốt — DIY

> **Cập nhật:** quyết định này đã chốt. Lab dùng **DIY**, và bản Control Tower vẫn được viết sẵn để đối chiếu (mặc định tắt). Chi tiết đầy đủ: [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md). Code: [`landing-zone/organization/`](../landing-zone/organization/) và [`landing-zone/control-tower/`](../landing-zone/control-tower/).

Nền tảng LZ này là **DIY** — Organizations thuần + Terraform. Nên "upgrade Control Tower" là khái niệm chỉ tồn tại ở layer `control-tower` đang tắt.

| | DIY *(repo hiện tại)* | Control Tower |
|---|---|---|
| OU | Bạn tự tạo | CT tạo sẵn Security, Sandbox |
| SCP | Bạn viết | Bộ *controls* riêng của CT |
| Tạo account | Doc 09 | Account Factory / AFT |
| Permission set | 17 set ở doc 19 | CT tự tạo bộ riêng |
| Nâng cấp | Không có khái niệm | "Update landing zone" theo version |

Nếu đưa Control Tower vào sau, **bốn chỗ va nhau**: đăng ký OU sẵn có vào CT sẽ đẩy StackSet baseline xuống mọi account trong đó; SCP hai nguồn cùng áp; CT tự bật Identity Center; và drift detection của CT báo động với thay đổi Terraform làm ngoài nó.

Tin tốt: **`tf-backend`, `permission-sets`, `billing-guard` sống chung với cả hai bản.** Chỉ `organization` và `control-tower` là thay thế nhau — dùng cái này **hoặc** cái kia, không dùng cả hai.

---

## 8. Sự cố state thường gặp

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| `Error acquiring the state lock` | Apply trước chết giữa chừng | `terraform force-unlock <ID>` — **chỉ khi chắc không ai đang chạy** |
| `plan` đòi tạo lại thứ đã có | State không khớp thực tế | `terraform import`, hoặc khôi phục version cũ |
| `AccessDenied` lúc `init` cross-account | Thiếu `BucketOwnerEnforced` hoặc quyền KMS | Mục 3.3 |
| State rỗng sau migrate | Không bấm "yes" ở `-migrate-state` | Khôi phục từ `terraform.tfstate.backup` local |
| Hai người apply cùng lúc, state lạ | Chưa bật khoá | Khôi phục version, bật `lock_mode` |

Khôi phục version cũ:

```bash
aws s3api list-object-versions --bucket <bucket> \
  --prefix permission-sets/terraform.tfstate \
  --query 'Versions[].[VersionId,LastModified]' --output table

# Tai ve XEM truoc, chua ghi de
aws s3api get-object --bucket <bucket> \
  --key permission-sets/terraform.tfstate \
  --version-id <ID> /tmp/state-cu.json

jq '.resources[].type' /tmp/state-cu.json | sort | uniq -c
```

Chắc chắn rồi mới `copy-object` đè lên. Versioning tồn tại chính là để dùng lúc này.

---

## 9. Sổ quyết định

| # | Quyết định | Lý do | Đánh đổi |
|---|---|---|---|
| D1 | Một bucket, mỗi layer một key | Backup/audit/lifecycle một chỗ | Một điểm hỏng — bù bằng versioning + `prevent_destroy` |
| D2 | DynamoDB là mặc định, không phải S3 lockfile | Chạy với mọi phiên bản Terraform | Thêm một resource phải quản |
| D3 | SSE-S3 mặc định, KMS tuỳ chọn | State hiện tại không chứa bí mật | Phải nhớ bật khi có layer database |
| D4 | `BucketOwnerEnforced` | Không có thì cross-account state không đọc được | ACL bị tắt hoàn toàn |
| D5 | `prevent_destroy` trên bucket và bảng khoá | Xoá nhầm = mọi layer mất dấu resource | `destroy` cần hai bước có chủ đích |
| D6 | Partial config `backend.hcl`, không hardcode | Backend block không nhận biến | Thêm một bước `wire-backends.sh` |
| D7 | Giữ version cũ 90 ngày | Cân bằng khôi phục và chi phí | Sự cố phát hiện sau 90 ngày thì hết cứu |
| D8 | Demo **không** dùng remote state | Ephemeral, không cần lịch sử | Hai cách làm khác nhau trong cùng repo |
| D9 | Script chỉ sinh `backend.hcl`, không tự migrate | Chuyển state phải có người đọc và đồng ý | Thêm thao tác tay |

---

## 10. Việc còn lại

| # | Việc | Chặn bởi |
|---|---|---|
| 1 | Chạy `terraform init && apply` ở môi trường có registry | Môi trường soạn tài liệu chặn `registry.terraform.io` |
| 2 | Bật MFA Delete cho bucket state | Cần credential root, thủ công |
| 3 | CI/CD: plan trong PR, apply sau approve | Doc 10 mới là thiết kế |
| 4 | Drift detection định kỳ (`plan -detailed-exitcode` theo lịch) | Cần (3) |
| 5 | ~~Chốt Control Tower hay DIY~~ | ✅ Đã chốt: DIY |
| 6 | ~~Layer `organization` — OU + SCP~~ | ✅ Đã xong |
| 7 | Nâng network từ demo thành layer thường trực | — |
| 8 | Account vending có code thật | Cần (6) |

---

## Liên quan

| Tài liệu | Quan hệ |
|---|---|
| [06 – AWS Landing Zone](./06-Aws-Landing-Zone.md) | Organizations, OU, SCP |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Account mới phải cập nhật `accounts_by_scope` |
| [10 – CI/CD GitHub Actions OIDC](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) | Plan trong PR — bước tiếp theo của tài liệu này |
| [19 – Permission set](./19-Permission-Set-cho-Landing-Zone.md) | Layer dùng backend này |
| [17 – Network LZ Design Guide](./17-Network-LZ-Design-Guide.md) | Thiết kế mạng, phần cần nâng thành layer thường trực |
