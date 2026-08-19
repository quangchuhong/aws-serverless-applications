# Runbook — dựng Landing Zone bản DIY

Hướng dẫn chạy **theo thứ tự**, từ tài khoản trắng đến LZ hoạt động.

> Mỗi layer có README riêng nói **vì sao**. File này chỉ nói **làm gì, theo thứ tự nào, và dừng ở đâu nếu sai**.

**Thời gian**: ~2–3 giờ cho lần đầu, phần lớn là chờ AWS.
**Chi phí**: ~$0. Tốn tiền chỉ khi bật `config-detective` (giai đoạn 6, để sau).

---

## Bản đồ đường đi

```
0. Preflight              5 phút    kiem tra moi truong
   ↓
1. tf-backend            15 phút    S3 + khoa state
   ↓
2. organization          30 phút    Org + OU + SCP (dry-run truoc)
   ↓
3. Account               30 phút    tao + chuyen vao OU   ← thu cong
   ↓
4. Identity Center        5 phút    bat mot lan            ← thu cong, console
   ↓
5. permission-sets       20 phút    17 set + group + user
   ↓
6. billing-guard         10 phút    budget + cost tag
   ↓
7. config-detective         sau     de khi co account prod that
```

Giai đoạn **3 và 4 là thủ công** — không có Terraform. Đừng tìm code cho chúng.

---

## Giai đoạn 0 — Preflight

```bash
aws sts get-caller-identity
terraform version
aws organizations describe-organization
```

| Kiểm tra | Phải là |
|---|---|
| `Account` trong lệnh 1 | **Management account** |
| `Terraform` | ≥ 1.5 |
| Lệnh 3 | Ghi lại kết quả — quyết định biến ở giai đoạn 2 |

**Lệnh 3 quyết định một biến:**

| Kết quả | Đặt trong giai đoạn 2 |
|---|---|
| Ra thông tin org | `create_organization = false` |
| `AWSOrganizationsNotInUseException` | `create_organization = true` |

> **DỪNG nếu** lệnh 1 trả về account con. Toàn bộ runbook này chạy ở management account.

---

## Giai đoạn 1 — `tf-backend`

```bash
cd landing-zone/tf-backend
cp terraform.tfvars.example terraform.tfvars
```

Sửa 4 dòng:

```hcl
region                = "ap-southeast-1"
prefix                = "acme-lz"          # doi thanh ten cua ban
management_account_id = "111111111111"     # tu lenh preflight
owner                 = "ban@example.com"
```

```bash
terraform init
terraform plan
terraform apply
```

**Kiểm tra:**

```bash
terraform output bucket
aws s3 ls | grep tfstate
```

### Chuyển chính layer này vào bucket vừa tạo

> **Chỉ làm phần này SAU KHI `terraform apply` đã xong.** Bỏ comment `backend "s3" {}` sớm là lỗi hay gặp nhất ở giai đoạn này: bucket do **chính layer này** tạo ra, chưa apply thì nó chưa tồn tại, và mọi lệnh sau đó sẽ báo `Backend initialization required`.
>
> Lỡ làm sớm rồi thì: comment lại → `terraform init -reconfigure` → `terraform apply`. Không mất gì, vì chưa có state nào để mất.

```bash
./wire-backends.sh --dry-run     # xem truoc
./wire-backends.sh               # ghi backend.hcl cho moi layer
```

**Giờ mới** bỏ comment dòng `backend "s3" {}` trong `versions.tf`, rồi:

```bash
terraform init -migrate-state -backend-config=backend.hcl
#   -> hoi "copy existing state?" -> yes
```

Kiểm tra **trước khi xoá** — đừng gõ cả ba lệnh một lượt:

```bash
terraform state list        # phai con nguyen resource
terraform plan              # PHAI ra "No changes"  <- bang chung that
```

Chỉ khi `plan` ra **"No changes"** mới xoá state local:

```bash
rm terraform.tfstate terraform.tfstate.backup
```

> **DỪNG nếu** `plan` ra diff hoặc `state list` rỗng. State chưa chuyển đủ — `terraform.tfstate.backup` là bản sao lưu duy nhất, đừng xoá.

> **Năm layer còn lại chưa apply bao giờ** nên không có state để chuyển. Khi dùng tới chúng chỉ cần `terraform init -backend-config=backend.hcl`, **không** có `-migrate-state`. `wire-backends.sh` tự phân biệt hai nhóm này.

☑ Xong giai đoạn 1 khi: `terraform state list` còn đủ resource và không còn file state local.

---

## Giai đoạn 2 — `organization`

### 2a. Dry-run: tạo policy nhưng CHƯA gắn

```bash
cd ../organization
cp terraform.tfvars.example terraform.tfvars
```

Sửa:

```hcl
create_organization = false        # hoac true, tuy giai doan 0
allowed_regions     = ["ap-southeast-1", "us-east-1"]
network_account_id  = ""           # chua co account network thi de rong

enable_scp = {
  baseline     = true
  region_lock  = false
  network_lock = false
  prod_guard   = false
}

scp_dry_run = true                 # QUAN TRONG: chua gan vao dau
```

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**Kiểm tra:**

```bash
terraform output ou_ids            # ghi lai, giai doan 3 can
terraform output scp_summary       # xem kich thuoc policy
terraform output root_id
```

Vào console Organizations đọc nội dung policy. **Chưa có gì bị chặn ở bước này.**

### 2b. Gắn SCP — từng cái một

Đổi `scp_dry_run = false`, giữ nguyên chỉ `baseline = true`:

```bash
terraform apply
```

Thử lại các thao tác bình thường của bạn. Ổn thì bật cái tiếp theo:

```hcl
enable_scp = { baseline = true, region_lock = true, ... }
```

`apply` → thử → bật tiếp. Thứ tự: `baseline` → `region_lock` → `network_lock` → `prod_guard`.

> **Vì sao từng cái một:** bật hết một lượt rồi có gì hỏng thì không biết do cái nào. Mỗi lần `apply` chỉ mất vài giây.

**Kiểm tra sau mỗi lần bật** — bốn lệnh, ba "phải bị chặn" và **một "phải chạy được"**:

```bash
# Se dung duoc SAU giai doan 3, khi da co account con
aws ec2 create-internet-gateway --profile <workload>            # PHAI bi tu choi
aws ec2 describe-vpcs --region eu-west-1 --profile <workload>   # PHAI bi tu choi
aws ec2 create-internet-gateway --profile <network>             # PHAI THANH CONG

aws organizations list-policies-for-target \
  --target-id <account-id> --filter SERVICE_CONTROL_POLICY
```

Lệnh thứ ba quan trọng ngang ba lệnh kia — siết quá tay cũng là lỗi.

☑ Xong giai đoạn 2 khi: `terraform output ou_ids` ra đủ cây OU, và SCP đã gắn ở mức bạn muốn.

---

## Giai đoạn 3 — Account *(thủ công)*

Layer `organization` **không tạo account**. Làm bằng CLI.

### 3a. Chuẩn bị email

```
quang.hong.0991+lz-network-01@gmail.com
quang.hong.0991+lz-security-01@gmail.com
quang.hong.0991+lz-logarchive-01@gmail.com
quang.hong.0991+lz-app-dev-01@gmail.com
quang.hong.0991+lz-app-prod-01@gmail.com
```

Ba điều: **duy nhất toàn cầu vĩnh viễn**, plus-addressing về cùng một inbox, và **thêm hậu tố `-01` ngay từ đầu** để lần dựng lại còn `-02`. Chi tiết ở [doc 09 mục 3b](../docs/09-Account-Vending-Tu-Dong.md).

### 3b. Tạo

```bash
aws organizations create-account \
  --email "quang.hong.0991+lz-network-01@gmail.com" \
  --account-name "lz-network" \
  --role-name OrganizationAccountAccessRole

# Tao account mat vai phut, va gan nhu tuan tu - dung tao dong loat
aws organizations list-create-account-status --states IN_PROGRESS
aws organizations list-create-account-status --states SUCCEEDED \
  --query 'CreateAccountStatuses[].[AccountName,AccountId]' --output table
```

> Giãn ra, đừng tạo 5 account trong 5 phút — dễ bị fraud detection treo chờ review.

### 3c. Chuyển vào OU

```bash
ROOT=$(cd ../organization && terraform output -raw root_id)

aws organizations move-account \
  --account-id <account-id> \
  --source-parent-id $ROOT \
  --destination-parent-id <ou-id>     # tu terraform output ou_ids
```

Gợi ý xếp chỗ:

| Account | OU |
|---|---|
| `lz-logarchive`, `lz-security` | `Security` |
| `lz-network` | `Infrastructure` ← **không** bị `network_lock` |
| `lz-app-dev` | `Workloads/Non-Production` |
| `lz-app-prod` | `Workloads/Production` |

### 3d. Lập profile để test

```bash
# ~/.aws/config
[profile lz-network]
role_arn       = arn:aws:iam::<network-account-id>:role/OrganizationAccountAccessRole
source_profile = default
region         = ap-southeast-1
```

```bash
aws sts get-caller-identity --profile lz-network
```

Giờ mới chạy được bốn lệnh kiểm chứng SCP ở giai đoạn 2b.

☑ Xong giai đoạn 3 khi: `aws organizations list-accounts --query 'Accounts[].[Name,Id]'` ra đủ, và mỗi account nằm đúng OU.

---

## Giai đoạn 4 — Identity Center *(thủ công, console)*

Terraform **không tạo được instance** Identity Center. Bật một lần:

```
Console management account → IAM Identity Center → Enable
```

Chọn region — **chỉ một region cho cả tổ chức**, và nên trùng region chính của bạn.

```bash
aws sso-admin list-instances
```

> **DỪNG nếu** lệnh này trả về rỗng. Giai đoạn 5 sẽ fail ở dòng `tolist(...)[0]`.

Bật luôn **MFA bắt buộc**: Settings → Authentication → *Require MFA every time*. Terraform không làm được bước này.

☑ Xong giai đoạn 4 khi: `list-instances` ra `InstanceArn` và `IdentityStoreId`.

---

## Giai đoạn 5 — `permission-sets`

```bash
cd ../permission-sets
cp terraform.tfvars.example terraform.tfvars
```

Sửa — dùng account ID từ giai đoạn 3:

```hcl
region                = "ap-southeast-1"   # region cua Identity Center
management_account_id = "111111111111"

accounts_by_scope = {
  analytics = []
  nonprod   = ["222222222222"]     # lz-app-dev
  prod      = ["333333333333"]     # lz-app-prod
}

manage_groups = true

users = {
  quang = {
    given_name  = "Quang"
    family_name = "Chu Hong"
    email       = "quang.hong.0991@gmail.com"
    groups      = ["lz-platform-admins"]
  }
}
```

```bash
terraform init -backend-config=backend.hcl
./validate-policies.sh          # kiem tra 17 inline policy
terraform plan
terraform apply
```

**Kiểm tra:**

```bash
terraform output assignment_matrix    # doi chieu voi bang thiet ke
terraform output unscoped_accounts    # account quen khai pham vi
terraform output portal_url
```

Đăng nhập thử:

```bash
aws configure sso
aws sso login --profile lz-net-admin
aws sts get-caller-identity --profile lz-net-admin
```

ARN phải có dạng `assumed-role/AWSReservedSSO_lz-network-admin_<hash>/quang`.

> **Hai bước thủ công còn lại:** xác nhận email đặt password, và bật quyền xem billing ở management account (Billing console → Account → *IAM user and role access to Billing information* → Activate) — không bật thì `lz-billing` vẫn bị Access Denied.

☑ Xong giai đoạn 5 khi: đăng nhập được qua portal và `get-caller-identity` ra ARN `AWSReservedSSO_*`.

---

## Giai đoạn 6 — `billing-guard`

```bash
cd ../billing-guard
cp terraform.tfvars.example terraform.tfvars
```

```hcl
alert_emails           = ["quang.hong.0991@gmail.com"]
org_monthly_budget_usd = "20"

# Lan dau CHUA CO resource nao mang tag -> phai TAT
enable_cost_allocation_tags = false
```

```bash
terraform init -backend-config=backend.hcl
terraform apply
```

Sau khi đã dựng vài resource (demo network chẳng hạn), quay lại bật:

```hcl
enable_cost_allocation_tags = true
```

> **Cost allocation tag không hồi tố.** Bật muộn = mất vĩnh viễn dữ liệu phân bổ của giai đoạn trước. Nên bật sớm nhất có thể sau khi có resource đầu tiên.

**Xác nhận email SNS** — chưa bấm link = không nhận được cảnh báo nào.

☑ Xong giai đoạn 6 khi: nhận được email xác nhận SNS và đã bấm link.

---

## Giai đoạn 7 — `config-detective` *(để sau)*

**Chưa cần bây giờ.** Đây là lớp duy nhất **tốn tiền thật**, và SCP đã lo phần ngăn chặn — phần quan trọng hơn.

Bật khi đã có account prod thật và cần trả lời "hiện có bao nhiêu resource đang sai". Xem [README của layer](./config-detective/README.md).

---

## Kiểm tra toàn bộ

```bash
cd landing-zone
./plan-all.sh
```

Mọi layer phải ra **"No changes"**. Layer nào ra diff nghĩa là có gì đó lệch giữa code và thực tế.

---

## Khi kẹt

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| `AlreadyInOrganizationException` | Org đã có mà đặt `create_organization = true` |
| `POLICY_TYPE_NOT_ENABLED` | `aws organizations enable-policy-type --root-id <id> --policy-type SERVICE_CONTROL_POLICY` |
| `DuplicateOrganizationalUnitException` | OU trùng tên — cần `terraform import` |
| SCP apply xong không thấy tác dụng | `scp_dry_run = true` — đúng thiết kế |
| `Backend initialization required` | Bỏ comment `backend "s3" {}` trước khi apply — comment lại, `init -reconfigure`, apply, rồi mới migrate |
| `terraform init` hỏi nhập bucket/key | Như trên — backend block đang bật mà chưa có `backend.hcl` |
| `tolist(...)[0]` index out of range | Chưa bật Identity Center (giai đoạn 4) |
| `EMAIL_ALREADY_EXISTS` | Email đã dùng cho account khác, kể cả đã đóng |
| Đăng nhập portal không thấy account nào | Quên cập nhật `accounts_by_scope` rồi apply |
| `terraform plan` ra diff sau migrate state | State chưa chuyển đủ — **đừng apply**, khôi phục rồi làm lại |

Gửi lại cả khối `│ Error:` kèm tên layer — đừng chỉ gửi dòng cuối.

---

## Xoá đi dựng lại

Layer thường trực đều có `prevent_destroy`, nên `terraform destroy` sẽ fail — **đúng thiết kế**.

| Thứ | Xoá được? |
|---|---|
| Demo (`demo/*`) | ✅ `./teardown.sh` |
| `config-detective` | ⚠️ Object Lock COMPLIANCE không gỡ được trước hạn |
| `permission-sets`, `billing-guard` | ⚠️ Bỏ `prevent_destroy` trước |
| `organization`, `tf-backend` | ❌ Đừng — xoá org là tách mọi account con |
| **Account AWS** | ❌ Không xoá được, chỉ **đóng** được, và email cháy vĩnh viễn |

Muốn tiết kiệm giữa các buổi thì **xoá demo, giữ nguyên layer thường trực** — chúng tốn ~$0.

---

## Liên quan

| | |
|---|---|
| [Doc 21 – Control Tower vs DIY](../docs/21-Control-Tower-vs-DIY.md) | Vì sao chọn DIY, 4 SCP |
| [Doc 20 – Vận hành LZ](../docs/20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
| [Doc 19 – Permission set](../docs/19-Permission-Set-cho-Landing-Zone.md) | 17 set |
| [Doc 09 mục 3b](../docs/09-Account-Vending-Tu-Dong.md) | Quy ước email |
| [Doc 06 mục 1b](../docs/06-Aws-Landing-Zone.md) | Root user vs organization root |
