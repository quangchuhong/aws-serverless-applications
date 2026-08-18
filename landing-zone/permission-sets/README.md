# Permission Sets

17 permission set cho toàn bộ Landing Zone, gán theo **group** qua IAM Identity Center. Chạy ở **management account**.

Thiết kế và lý do đằng sau từng quyết định: [doc 19 – Permission Set cho Landing Zone](../../docs/19-Permission-Set-cho-Landing-Zone.md).

**Chi phí: $0.** Identity Center và permission set không tính tiền.

---

## Yêu cầu trước khi chạy

1. **Organizations đã bật** (doc 06)
2. **Identity Center đã bật thủ công một lần** trong console management account — Terraform không tạo được instance:

```bash
aws sso-admin list-instances
```

Trả về rỗng nghĩa là chưa bật. Vào console → IAM Identity Center → Enable.

3. Biết **region** đặt instance. Identity Center chỉ tồn tại ở **đúng một region** cho cả organization — không phải region chạy workload.

---

## Chạy

```bash
cd landing-zone/permission-sets
cp terraform.tfvars.example terraform.tfvars
# sua: region, management_account_id, accounts_by_scope, users

terraform init
./validate-policies.sh     # kiem tra JSON cua inline policy
terraform plan
terraform apply
```

---

## Cấu trúc

| File | Nội dung |
|---|---|
| `locals-services.tf` | **Nguồn sự thật** về danh sách service theo miền |
| `locals-policies.tf` | Các mảnh policy dùng chung — Deny list, chốt PassRole, boundary |
| `permission-sets.tf` | 17 permission set, ráp từ hai file trên |
| `identity.tf` | 15 group + user + membership |
| `assignments.tf` | Ma trận (group × permission set × account) |
| `organizations.tf` | Suy ra phạm vi account |
| `validate-policies.sh` | Kiểm tra inline policy trước khi apply |

### Vì sao tách `locals-services.tf` riêng

Trong bảng thiết kế gốc:

```
lz-app-admin = lz-server-admin ∪ lz-db-admin
```

đúng từng service, không lệch một cái nào. Viết tay ba lần thì vài tháng sau chúng sẽ lệch — thêm Step Functions vào một chỗ, quên hai chỗ kia, không ai phát hiện cho tới khi có người báo lỗi permission.

Nên danh sách service khai **một lần** ở `locals-services.tf`, cả ba set cùng dẫn xuất từ đó. Sửa một chỗ, ba set cập nhật.

---

## Ba khác biệt so với bảng thiết kế gốc

Đọc [doc 19](../../docs/19-Permission-Set-cho-Landing-Zone.md) để hiểu đầy đủ. Tóm tắt:

**1. `lz-auditor` dùng `ViewOnlyAccess`, không dùng `ReadOnlyAccess`.**

`ReadOnlyAccess` bao gồm cả `s3:GetObject`, `dynamodb:Scan`, `secretsmanager:GetSecretValue`. Gán cho auditor ở tất cả account = cấp quyền đọc toàn bộ dữ liệu production. `ViewOnlyAccess` chỉ cho thấy resource tồn tại.

Mọi set operator còn có thêm `deny_data_plane` (tắt bằng `operator_can_read_data = true`).

**2. Chốt `iam:PassRole` ở mọi set admin.**

Không chốt thì `lz-server-admin` tạo được Lambda gán role admin rồi invoke — leo thẳng lên admin. `lz-analytics-admin` còn ngắn hơn: SageMaker notebook là shell thật.

Chỉ pass được role có tiền tố `lz-workload-` / `lz-analytics-`.

**3. Thêm 2 set so với bảng gốc (15 → 17).**

| Set thêm | Vì sao |
|---|---|
| `lz-app-breakglass` | Prod không ai ghi được. Sự cố 2h sáng cần đường vào có kiểm soát |
| `lz-datalake-admin` | `lakeformation:PutDataLakeSettings` cho phép tự cấp quyền đọc cả data lake — tách khỏi analytics-admin |

---

## Ba bước thủ công sau apply

Terraform không làm được, và thiếu bước nào cũng khiến quyền không hoạt động:

**1. Bắt buộc MFA** — Identity Center console → Settings → Authentication → Require MFA every time.

> Đừng đặt điều kiện `aws:MultiFactorAuthPresent` trong policy của permission set. Phiên Identity Center không mang claim này một cách đáng tin, thêm vào chỉ sinh Access Denied khó hiểu. MFA phải ép ở tầng Identity Center.

**2. Bật quyền xem billing** — management account → Billing console → Account → *IAM user and role access to Billing information* → Activate. Không bật thì `lz-billing` vẫn bị Access Denied dù policy đúng.

**3. Giành lại root từng account con** và bật MFA — permission set không thay thế được root.

---

## Kiểm chứng

```bash
terraform output assignment_matrix    # doi chieu voi bang thiet ke
terraform output unscoped_accounts    # account quen khai pham vi
terraform output accounts_in_scope
terraform output portal_url
```

Đăng nhập thử:

```bash
aws configure sso
aws sso login --profile lz-network
aws sts get-caller-identity --profile lz-network
```

ARN trả về phải có dạng `assumed-role/AWSReservedSSO_lz-network-admin_<hash>/<user>` — xác nhận đang chạy bằng IAM role sinh từ permission set.

---

## Hai điều dễ hiểu nhầm

**SCP vẫn chặn ở trên.** Permission set cho phép ≠ làm được. Một action chạy được chỉ khi **cả** permission set **lẫn** SCP cho phép. Có `lz-network-admin` ở account app-prod mà vẫn không tạo được Internet Gateway là **đúng thiết kế** — SCP `deny-internet-paths` (doc 13) chặn. Không phải bug.

**Tạo account mới phải apply lại.** Identity Center không gán được cho OU (`target_type` chỉ nhận `AWS_ACCOUNT`). Account mới trong OU non-prod phải thêm vào `accounts_by_scope` rồi apply, nếu không không ai vào được và người ta sẽ quay ra dùng root. Gắn bước này vào account vending (doc 09).

---

## Dùng với AD / Entra / Okta

Mặc định `manage_groups = true` — Terraform làm chủ user và group (trường hợp AWS-only, không có AD).

Nếu nối IdP ngoài qua SCIM thì **SCIM làm chủ**, Terraform chỉ được đọc:

```hcl
manage_groups = false
users         = {}
```

Lúc đó group phải đã tồn tại với đúng tên trong `local.groups`. Đừng trộn hai kiểu — SCIM ghi đè, Terraform thấy drift, apply lại, lặp vô tận. Chi tiết: [doc 08](../../docs/08-Dong-bo-User-AD-sang-IAM-Identity-Center.md).

---

## Xoá

```bash
terraform destroy
```

Xoá assignment thì các IAM role `AWSReservedSSO_*` trong account đích cũng biến mất — không còn ai đăng nhập được vào account con qua portal. Đảm bảo còn đường vào khác (root hoặc `OrganizationAccountAccessRole`) trước khi chạy.
