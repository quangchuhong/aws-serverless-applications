# Runbook — dựng Landing Zone bản DIY

Hướng dẫn chạy **theo thứ tự**, từ tài khoản trắng đến LZ hoạt động.

> Mỗi layer có README riêng nói **vì sao**. File này chỉ nói **làm gì, theo thứ tự nào, và dừng ở đâu nếu sai**.
>
> **Đã có người đi hết đường này** — cả 9 giai đoạn (giai đoạn 10 mới có code). [doc 22 – Nhật ký triển khai](../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) ghi lại 29 lỗi thật gặp phải, kèm sổ tay tra cứu nhanh ở mục 6.

**Thời gian**: ~2–3 giờ cho lần đầu, phần lớn là chờ AWS.
**Chi phí**: ~$0. `config-detective` (giai đoạn 7) đo được $0.29 một lần rồi ~$0/ngày; `org-trail` chỉ tốn tiền lưu trữ S3.

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
7. config-detective      30 phút    lop phat hien - LAYER DUY NHAT TON TIEN
   ↓
8. org-trail             15 phút    CloudTrail toan to chuc
   ↓
9. account-baseline      20 phút    thay cho AFT - don default VPC tu dong
   ↓
10. network              45 phút    TGW + firewall + egress   ← CHI KHI CO WORKLOAD
```

Giai đoạn **3 và 4 là thủ công** — không có Terraform. Đừng tìm code cho chúng.

> **Giai đoạn 10 không phải "làm nốt cho đủ bộ".** Chín giai đoạn đầu tốn ~$0/ngày; giai đoạn 10 tốn **~$770/tháng** ở 2 AZ, trong đó $570 là Network Firewall endpoint chạy 24/7 dù có gói tin hay không. Chỉ dựng khi thật sự có workload cần kết nối. Muốn xem thiết kế chạy thế nào mà không trả tiền thường trực thì dùng [`demo/network-lz-full`](../demo/network-lz-full/) — dựng, xem, xoá.

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

> **Chỉ làm phần này SAU KHI `terraform apply` đã xong.** Bucket do **chính layer này** tạo ra — chưa apply thì nó chưa tồn tại.

```bash
./wire-backends.sh --dry-run     # xem truoc
./wire-backends.sh               # sinh backend.hcl + backend.tf cho moi layer
```

Script sinh **hai** file mỗi layer, cả hai đều nằm trong `.gitignore`:

| File | Nội dung |
|---|---|
| `backend.tf` | Khai `backend "s3" {}` rỗng — bật remote state |
| `backend.hcl` | Giá trị thật: bucket, key, region, khoá |

> Không phải sửa file nào được git track. Thư mục chưa có `backend.tf` thì Terraform tự dùng state local — đúng cái cần cho lần chạy đầu.

Rồi:

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

> **Dấu hiệu tainted:** plan in `# ... is tainted, so must be replaced` và số resource được tạo **ít bất thường** — vì thứ phụ thuộc vào nó (OU phụ thuộc `roots[0].id`) trở thành *known after apply* nên không plan được. `untaint` xong là hiện đủ.

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
                                   # DAT ROI THI GIU NGUYEN - doi ve false
                                   # sau khi apply = Terraform doi xoa org
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

**Kiểm chứng `prod_guard`** — cặp lệnh giống hệt nhau, khác kết quả **chỉ vì OU khác nhau**:

Chạy bằng principal **quyền admin** ở cả hai account — `OrganizationAccountAccessRole`, hoặc permission set `lz-account-admin`. Xem phần dưới về lý do.

```bash
aws sts get-caller-identity --profile <prod>   # xac nhan la admin truoc da

aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0 --profile <prod>
# PHAI ra: AccessDenied ... explicit deny in a service control policy: p-xxxx

aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0 --profile <dev>
# PHAI ra: InvalidSnapshot.NotFound   <- khong bi SCP chan, dung
```

> **Vì sao thử được bằng tài nguyên không tồn tại:** SCP được đánh giá **trước** khi AWS kiểm tra resource có tồn tại — nên không cần tạo gì để thử, và không có gì bị xoá. `NotFound` ở account prod nghĩa là SCP **không** chặn.

### Ba điều kiện của một phép thử SCP dùng được

Đã vấp cả ba, mỗi cái một lần. Thiếu bất kỳ điều nào thì phép thử vẫn "ra lỗi" trông rất thuyết phục mà chẳng chứng minh điều gì.

| # | Điều kiện | Vi phạm thì |
|---|---|---|
| 1 | Tham số **hợp lệ về định dạng** | Request dừng ở tầng kiểm tham số, không bao giờ chạm tới phân quyền |
| 2 | Principal **vốn được phép** nếu không có SCP | Đang đo identity policy của chính mình, không đo SCP |
| 3 | Service **phân biệt được** "không có quyền" với "không tồn tại", và **nêu tên policy** | Không phân biệt được deny đến từ SCP hay từ đâu khác |

**Ba lần vấp:**

| Lệnh | Kết quả | Vi phạm |
|---|---|---|
| `kms schedule-key-deletion --key-id alias/aws/ebs` | `InvalidArnException` | #1 — KMS từ chối alias trước khi tới SCP; AWS-managed key vốn không xoá được |
| `ec2 delete-snapshot --snapshot-id snap-00000000000000000` | `InvalidSnapshotID.Malformed` ở **cả hai** | #1 — ID toàn số 0 không qua kiểm tra định dạng |
| `backup delete-backup-vault --backup-vault-name khong-ton-tai-test` | `AccessDeniedException` ở **cả hai**, dù principal là `OrganizationAccountAccessRole` | #3 — AWS Backup trả `AccessDenied` cho vault **không tồn tại** thay vì `NotFound`, và không nêu tên policy |

Lần thứ ba đáng chú ý nhất: nó phá vỡ giả định *"gọi API lên tài nguyên không tồn tại thì ra NotFound"*. Nhiều service cố ý **không tiết lộ** tài nguyên có tồn tại hay không, nên trả `AccessDenied` cho cả hai trường hợp.

**Dấu hiệu phép thử hỏng — kiểm cái này trước tiên:** hai account cho ra **cùng một** thông báo lỗi. Cặp lệnh chỉ khác nhau ở OU, nên kết quả giống nhau nghĩa là chưa cái nào chạm tới SCP. Dấu hiệu này bắt được cả ba lần vấp.

Phân biệt `NotFound` với `AccessDenied` và nêu tên policy: EC2, IAM, S3. Không phân biệt: AWS Backup và nhiều service mới hơn. Ưu tiên chọn action thuộc nhóm đầu.

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
terraform plan -out=tfplan
```

**Tính trước số resource rồi mới apply.** Ra đúng số nghĩa là locals, ma trận group và phạm vi account đều khớp; ra khác thì lệch chỗ nào đó — lúc này tìm dễ hơn nhiều so với sau khi apply.

| Resource | Số lượng |
|---|---|
| `aws_ssoadmin_permission_set` | 17 |
| `aws_ssoadmin_permission_set_inline_policy` | 16 — `lz-account-admin` chỉ dùng managed policy |
| `aws_ssoadmin_managed_policy_attachment` | 12 |
| `aws_identitystore_group` | 15 |
| `aws_identitystore_user` + membership | 2 × số user |
| `aws_ssoadmin_account_assignment` | *(tính bên dưới)* |

Số assignment = với mỗi group, cộng số account trong phạm vi của từng permission set nó dùng. Với 5 account phạm vi `all`, 1 nonprod, 1 prod, 0 analytics:

```
10 group pham vi "all" x 5 account       = 50
lz-app-teams: 1 nonprod + 1 prod         =  2
lz-billing-team -> management            =  1
3 group analytics/datalake (chua co OU)  =  0
                                    tong = 53   -> 115 resource
```

Đối chiếu nhanh mà không cần tính tay: `terraform output` sẽ có `assignment_count`.

```bash
terraform apply tfplan
```

Apply lâu — mỗi assignment là một lời gọi API chờ Identity Center provision xong một IAM role `AWSReservedSSO_<set>_<hash>` trong account đích. Gặp `ThrottlingException` thì provider tự retry.

**Cảnh báo đúng, không phải lỗi** — nếu chưa có account Data Analytics:

```
Warning: Cac pham vi sau dang RONG nen khong sinh assignment nao: analytics
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

ARN phải có dạng `assumed-role/AWSReservedSSO_lz-network-admin_<hash>/quang`. Chuỗi `AWSReservedSSO_` là bằng chứng permission set đã thành IAM role thật trong account đích.

Kiểm luôn ở phía account đích:

```bash
aws iam list-roles --profile lz-network \
  --query 'Roles[?starts_with(RoleName,`AWSReservedSSO_`)].RoleName' --output table
```

> **Ba bước thủ công Terraform không làm được:**
>
> | Việc | Không làm thì sao |
> |---|---|
> | **Users → chọn user → Reset password → *Send an email to the user*** | User tồn tại đủ group đủ quyền mà **không bao giờ login được** — chưa từng có password |
> | Billing console → Account → *IAM user and role access to Billing information* → Activate | `lz-billing` bị `AccessDenied` dù policy đúng hoàn toàn — lỗi khó đoán nhất ở giai đoạn này |
> | Identity Center → Settings → Authentication → *Require MFA every time* | Không có MFA |
>
> Việc đầu **lặp cho mỗi user mới**. API `CreateUser` mà Terraform dùng không gửi thư mời, và triệu chứng là *"không nhận được email"* chứ không phải một lỗi nào — nên rất dễ đi tìm ở hộp thư rác thay vì ở console.
>
> **Đừng** thay việc thứ ba bằng điều kiện `aws:MultiFactorAuthPresent` trong policy — phiên Identity Center không mang claim đó đáng tin, thêm vào chỉ sinh `AccessDenied` khó hiểu.

### Bẫy: `terraform.tfvars` chép từ bản example cũ

Trước commit `a9d9642`, file example ghi `passrole_prefixes` với ba khoá `server`/`app`/`analytics`. Code chỉ đọc `workload` và `analytics`; hai khoá kia **bị bỏ qua im lặng** — sửa tiền tố mà policy vẫn giữ giá trị cũ. Nay có validation chặn, đúng phải là:

```hcl
passrole_prefixes = {
  workload  = "lz-workload-"
  analytics = "lz-analytics-"
}
```

Nếu gặp `TERRAFORM CRASH` kèm `panic: value for local.stmt was requested before it was provided`: đó là bug của `terraform console` chế độ pipe khi variable validation thất bại — panic là **hệ quả**, lỗi thật nằm phía trên banner. Sửa tfvars là hết.

☑ Xong giai đoạn 5 khi: đăng nhập được qua portal và `get-caller-identity` ra ARN `AWSReservedSSO_*`.

### Việc phải làm ngay sau giai đoạn 5

`aws organizations create-account` **không nhận tham số OU** — account mới luôn nằm ở root. SCP thì gắn vào OU, nên account quên chuyển là account không có guardrail nào ngoài SCP gắn ở root.

```bash
for id in $(aws organizations list-accounts --query 'Accounts[?Status==`ACTIVE`].Id' --output text); do
  printf '%-14s %-16s %s\n' "$id" \
    "$(aws organizations describe-account --account-id $id --query 'Account.Name' --output text)" \
    "$(aws organizations list-parents --child-id $id --query 'Parents[0].[Type,Id]' --output text)"
done
```

`ROOT` ở cột cuối = chưa chuyển. Nguy nhất là account production: `prod_guard` gắn vào OU `Production`, account còn ở root thì SCP đó không chạm tới nó — trong khi giai đoạn 5 vừa cấp quyền phạm vi `prod` vào đúng account đó.

```bash
aws organizations move-account --account-id <id> \
  --source-parent-id <root-id> --destination-parent-id <ou-id>
```

---

## Giai đoạn 6 — `billing-guard`

```bash
cd ../billing-guard
cp terraform.tfvars.example terraform.tfvars
```

**Chạy lệnh này TRƯỚC khi sửa tfvars** — kết quả quyết định một biến:

```bash
aws ce get-anomaly-monitors \
  --query 'AnomalyMonitors[?MonitorType==`DIMENSIONAL`].[MonitorName,MonitorArn]' \
  --output table
```

| Kết quả | Đặt |
|---|---|
| Ra ARN (thường có sẵn tên "Services") | `service_anomaly_monitor_arn = "<ARN do>"` |
| Rỗng | Để rỗng, Terraform tạo mới |

Mỗi account **chỉ được một** dimensional monitor. Không kiểm mà apply thẳng sẽ ra `Limit exceeded on dimensional spend monitor creation`.

```hcl
alert_emails           = ["quang.hong.0991@gmail.com"]
org_monthly_budget_usd = "20"

# Lan dau CHUA CO resource nao mang tag -> phai TAT
enable_cost_allocation_tags = false

# Mot bien dat CA HAI truong frequency va subscriber.type, vi AWS
# rang buoc chung: DAILY/WEEKLY chi nhan EMAIL, SNS can IMMEDIATE.
anomaly_alert_mode = "sns_immediate"

service_anomaly_monitor_arn = ""   # hoac ARN tu lenh tren
```

```bash
terraform init -backend-config=backend.hcl
terraform apply
```

> **Region là `us-east-1`, không phải region của bạn.** Budget, Cost Explorer, anomaly detection và metric `AWS/Billing` chỉ tồn tại ở đó. Đó cũng là lý do `allowed_regions` ở giai đoạn 2 bắt buộc có `us-east-1` — có validation chặn nếu thiếu. Bỏ region đó ra là tự khoá mình khỏi toàn bộ tầng billing.

Sau khi đã dựng vài resource (demo network chẳng hạn), quay lại bật:

```hcl
enable_cost_allocation_tags = true
```

> **Cost allocation tag không hồi tố.** Bật muộn = mất vĩnh viễn dữ liệu phân bổ của giai đoạn trước. Nên bật sớm nhất có thể sau khi có resource đầu tiên.

**Xác nhận email SNS** — chưa bấm link = không nhận được cảnh báo nào. Terraform vẫn báo `Creation complete`, nhưng subscription nằm ở trạng thái `PendingConfirmation` và mọi cảnh báo rơi vào hư không.

```bash
aws sns list-subscriptions-by-topic --topic-arn <sns_topic_arn> \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
```

Cột thứ hai còn ghi `PendingConfirmation` là chưa xong. Thử đường cảnh báo từ đầu đến cuối:

```bash
aws sns publish --topic-arn <sns_topic_arn> \
  --subject "test canh bao billing" --message "Duong canh bao da thong."
```

☑ Xong giai đoạn 6 khi: `list-subscriptions-by-topic` ra ARN thật (không phải `PendingConfirmation`) và `sns publish` về được hộp thư.

---

## Giai đoạn 7 — `config-detective`

Lớp **phát hiện**: SCP trả lời *"ai được làm gì"*, Config trả lời *"hiện có bao nhiêu thứ đang sai"*.

> **Đây là lớp duy nhất tốn tiền thật.** SCP đã lo phần ngăn chặn — phần quan trọng hơn — nên hoãn giai đoạn này là lựa chọn hợp lý cho tới khi thật sự cần trả lời câu hỏi trên.

### 7a. Bốn điều kiện tiên quyết — thiếu cái nào cũng hỏng

> **Khuôn chung đáng nhớ:** đăng ký ở tầng Organizations là **một chuyện**, dịch vụ tự kích hoạt là **chuyện khác**. Ba dịch vụ trong giai đoạn này đều cần bước riêng — Security Hub, GuardDuty, CloudFormation StackSets. Chỉ AWS Config là đăng ký ở Organizations đủ dùng.

**(1) Delegated administrator** — làm ở layer `organization`, không phải ở đây:

```hcl
# landing-zone/organization/terraform.tfvars
delegated_administrators = {
  "config.amazonaws.com"                   = "<security-account-id>"
  "config-multiaccountsetup.amazonaws.com" = "<security-account-id>"   # PHAI co
  "securityhub.amazonaws.com"              = "<security-account-id>"
}
```

```bash
cd ../organization && terraform apply
aws organizations list-delegated-administrators --output table
```

Thiếu `config-multiaccountsetup` thì organization rule báo `AccessDeniedException` **không nói rõ thiếu gì**. Có `check` block bắt.

**(2) Security Hub** — layer này **đọc** findings từ Security Hub chứ không bật nó. Ba lệnh, chạy ở **hai account khác nhau**, đúng thứ tự:

```bash
# 1. TU MANAGEMENT ACCOUNT - chi dinh admin o tang Security Hub
aws securityhub enable-organization-admin-account \
  --admin-account-id <security-account-id> --region ap-southeast-1

# 2. TU SECURITY ACCOUNT - bat, KHONG kem standard
aws securityhub enable-security-hub --no-enable-default-standards \
  --profile <security> --region ap-southeast-1

# 3. TU SECURITY ACCOUNT - gom findings moi account
aws securityhub update-organization-configuration --auto-enable \
  --auto-enable-standards NONE \
  --profile <security> --region ap-southeast-1
```

> **Bỏ bước 1 thì bước 3 báo:**
> ```
> InvalidAccessException: Account <id> is not an administrator for this organization
> ```
> Đăng ký delegated administrator ở tầng **Organizations** là cần nhưng **chưa đủ** — Security Hub có cơ chế chỉ định riêng, và nó chỉ gọi được từ management account. GuardDuty cũng vậy (`guardduty enable-organization-admin-account`). Config thì không cần — với Config, đăng ký ở Organizations là đủ.

> **`--no-enable-default-standards` và `--auto-enable-standards NONE` là bắt buộc, không phải tuỳ chọn.** Mặc định của `enable-security-hub` là **bật** AWS FSBP + CIS. Standard tính tiền theo **số lần kiểm tra**, mà FSBP có vài trăm control chạy liên tục trên mọi resource — đây là phần đắt nhất của Security Hub, đắt hơn Config nhiều. Layer này **không cần** standard nào.
>
> Lỡ bật rồi thì gỡ:
> ```bash
> aws securityhub get-enabled-standards --profile <security> --region ap-southeast-1
> aws securityhub batch-disable-standards \
>   --standards-subscription-arns <arn> --profile <security> --region ap-southeast-1
> ```

Security Hub là dịch vụ **theo region** — lặp cả ba bước cho mỗi region trong `aggregator_regions`.

Chưa bật thì recorder vẫn ghi, rule vẫn đánh giá, S3 vẫn có file — **và không một cảnh báo nào được gửi**. Không lỗi, không cảnh báo.

**(3) Trusted access cho CloudFormation StackSets** — chạy **một lần** từ management account:

```bash
aws cloudformation activate-organizations-access --region ap-southeast-1
aws cloudformation describe-organizations-access --region ap-southeast-1   # Status: ENABLED
```

Bỏ bước này thì StackSet báo `ValidationError: You must enable organizations access to operate a service managed stack set`. Có `member.org.stacksets.cloudformation.amazonaws.com` trong `aws_service_access_principals` là **chưa đủ** — đúng khuôn của Security Hub và GuardDuty.

**Và miễn trừ SCP cho role thực thi của StackSet**, ở layer `organization`:

```hcl
scp_exempt_role_names = ["stacksets-exec-*"]
```

`baseline` chặn `config:DeleteConfigurationRecorder` — đúng ý đồ, không ai được tắt audit trail. Nhưng nó chặn luôn **CloudFormation rollback**: một lần triển khai hỏng là để lại stack `DELETE_FAILED` mà không ai có quyền dọn, kể cả Terraform.

Tên role là `stacksets-exec-<hash>`, **không** phải `AWSServiceRoleForCloudFormationStackSetsOrgMember` — cái sau là service-linked role phía quản trị. Hash sinh theo tổ chức nên dùng wildcard; `exempt_condition` dùng `ArnNotLike` nên hiểu dấu `*`.

Gặp `explicit deny in a service control policy` trong `StatusReason` của stack instance thì đọc thẳng dòng `assumed-role/<ten>/...` — đó là tên role thật cần miễn trừ.

**(4) Object Lock** — quyết định **trước** khi tạo bucket, không sửa được sau:

```hcl
enable_object_lock         = true
object_lock_retention_days = 90
snapshot_retention_days    = 365   # PHAI lon hon retention
```

COMPLIANCE mode: không ai xoá được, **kể cả root**. Đổi lại, object đã ghi thì phải trả tiền lưu trữ tới hết hạn. Đó cũng chính là lý do tách account log archive — account bị xâm nhập không xoá được bằng chứng.

### 7b. Chạy

```bash
cd ../config-detective
cp terraform.tfvars.example terraform.tfvars

terraform init -backend-config=backend.hcl
terraform plan            # enable = false -> 0 resource, xac nhan truoc
```

Điền account ID và OU ID (`cd ../organization && terraform output ou_ids`), **đừng đưa Sandbox/Dev vào `recorder_target_ous`** — đó là nơi resource đổi nhiều nhất, tức đắt nhất, mà vi phạm ở đó lại là chuyện bình thường.

Rồi `enable = true` và `terraform apply`.

### 7c. Kiểm chứng — bước 3 quan trọng nhất

```bash
aws configservice describe-configuration-recorder-status --profile <account>
aws configservice describe-aggregate-compliance-by-config-rules \
  --configuration-aggregator-name <project>-org --profile <security>
```

Rule ở trạng thái **`INSUFFICIENT_DATA`** nghĩa là recorder **không ghi** loại resource mà rule đó kiểm — nó im lặng và rất dễ nhầm thành "mọi thứ đều ổn". Có `check` block bắt trường hợp rule `s3-*` mà không ghi `AWS::S3::Bucket`.

Sau ~24 giờ, đo chi phí thật trước khi mở rộng: Cost Explorer → lọc Service = *AWS Config* → group by Linked Account.

Chi tiết đầy đủ ở [README của layer](./config-detective/README.md).

☑ Xong giai đoạn 7 khi: `describe-configuration-recorder-status` ra `recording: true` ở mọi account đích, và 8 rule đều `CREATE_SUCCESSFUL`.

---

## Giai đoạn 8 — `org-trail`

CloudTrail cho toàn tổ chức. **Giai đoạn này tồn tại vì giai đoạn 7 tìm ra chỗ thiếu**: ngày đầu `config-detective` chạy, `cloud-trail-enabled` ra `NON_COMPLIANT` ở mọi account — tổ chức không có trail nào, dù `baseline` SCP đã chặn `cloudtrail:StopLogging` và `lz-auditor` đã được cấp quyền đọc CloudTrail.

Ba tầng bảo vệ và cấp quyền cho một thứ không tồn tại. Đọc code không thấy được, vì cái thiếu không nằm ở đâu để nhìn.

### Điều kiện tiên quyết

```bash
aws organizations list-aws-service-access-for-organization \
  --query 'EnabledServicePrincipals[?ServicePrincipal==`cloudtrail.amazonaws.com`]'
```

Rỗng thì thêm vào `aws_service_access_principals` ở giai đoạn 2. Có `check` block bắt.

### Chạy

```bash
cd ../org-trail
cp terraform.tfvars.example terraform.tfvars
```

```hcl
enable                 = true
log_archive_account_id = "444444444444"
data_events            = false      # GIU FALSE - xem duoi
log_retention_days     = 365
enable_object_lock     = false      # chua kiem chung voi CloudTrail
```

```bash
terraform init -backend-config=backend.hcl
terraform plan          # mong doi 8 to add
terraform apply
```

> **`data_events` là cần gạt chi phí lớn nhất.** Management event: bản sao đầu tiên **miễn phí** mọi account. Data event: **tính tiền theo từng sự kiện**, và một bucket S3 có lưu lượng bình thường sinh hàng triệu sự kiện mỗi tháng. Bật ở phạm vi tổ chức "cho chắc" là cách nhanh nhất biến một layer miễn phí thành khoản lớn nhất trong hoá đơn.

### Kiểm chứng

CloudTrail giao theo lô, **không tức thì** — bucket rỗng ngay sau apply là bình thường.

```bash
# ~15 phut
aws cloudtrail get-trail-status --name <project>-org-trail \
  --query '[IsLogging,LatestDeliveryTime,LatestDeliveryError]'

aws cloudtrail describe-trails --trail-name-list <project>-org-trail \
  --query 'trailList[0].[IsOrganizationTrail,IsMultiRegionTrail]'
```

Cả hai giá trị ở lệnh sau phải là `true`. `IsOrganizationTrail = false` nghĩa là trail chỉ ghi management account — đúng vùng mù lớn nhất.

**Phép kiểm chứng thật** không phải việc trail tồn tại, mà là việc lớp phát hiện xác nhận nó tồn tại, sau ~1 giờ:

```bash
aws configservice describe-aggregate-compliance-by-config-rules \
  --configuration-aggregator-name <project>-org \
  --profile <security> --region <region> \
  --query 'AggregateComplianceByConfigRules[?contains(ConfigRuleName,`cloud-trail`)]'
```

`cloud-trail-enabled` phải chuyển `NON_COMPLIANT` → `COMPLIANT` ở mọi account. Vòng khép kín: phát hiện → sửa → phát hiện xác nhận.

☑ Xong giai đoạn 8 khi: `IsLogging = true`, file vào S3, và `cloud-trail-enabled` chuyển sang `COMPLIANT`.

Chi tiết ở [README của layer](./org-trail/README.md).

---

## Giai đoạn 9 — `account-baseline`

Thay cho **AFT**. Bản DIY không có Control Tower nên không có Account Factory for Terraform; giai đoạn này làm phần việc đó.

Ba việc tay khi thêm account, **không việc nào báo lỗi khi quên**:

| Việc | Quên thì |
|---|---|
| `move-account` vào OU | Account chỉ còn SCP ở root — mất `network_lock` và `prod_guard` |
| Xoá default VPC | Một Internet Gateway mở sẵn; `network_lock` chỉ chặn **tạo** IGW mới |
| Khai `accounts_by_scope` | Không ai vào được account qua Identity Center |

### Chạy

```bash
cd ../organization && terraform output ou_ids     # lay OU ID
cd ../account-baseline
cp terraform.tfvars.example terraform.tfvars
```

```hcl
enable = true

# MOI OU chua account thuc, ke ca Sandbox va Non-Production.
# Khac config-detective: xoa default VPC mien phi va lam mot lan,
# nen bo sot mot OU chi de lai lo hong chu khong tiet kiem duoc gi.
baseline_target_ous = ["ou-xxxx-security", "ou-xxxx-infrastructure",
                       "ou-xxxx-non-production", "ou-xxxx-production"]

sweep_regions = ["ap-southeast-1", "us-east-1"]   # khop allowed_regions
sweep_version = "1"

create_accounts = {}                              # GIU RONG - xem duoi

account_scopes = {
  "222222222222" = "none"       # ha tang
  "555555555555" = "nonprod"
  "666666666666" = "prod"
}
```

```bash
terraform init -backend-config=backend.hcl
terraform plan          # mong doi 2 to add
terraform apply
```

> **`create_accounts` gần như không hoàn tác được.** Account không xoá được, chỉ **đóng**, và phải chờ 90 ngày. Email **duy nhất vĩnh viễn** — đóng rồi cũng không dùng lại được. Giữ rỗng cho tới khi chắc; tạo tay bằng `create-account` hoàn toàn được.

### Kiểm chứng

```bash
# ~5 phut
aws cloudformation list-stack-instances   --stack-set-name <project>-account-baseline --call-as SELF   --query 'Summaries[].[Account,Status]' --output table

# Xem no xoa duoc gi
aws cloudformation describe-stacks --profile <account> --region <region> \
  --query "Stacks[?contains(StackName,'account-baseline')].Outputs[] | [?OutputKey=='SweepResult'].OutputValue" \
  --output text
```

> Dấu `[]` sau `Outputs` là **bắt buộc**. Không có nó thì hai bộ lọc liên tiếp tạo một projection lồng và `--output text` in ra **dòng trống** — trông y hệt như stack không có output nào. Đây là lỗi 27 trong [doc 22](../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md), và nó suýt làm cả năm cái VPC bị xoá thật được ghi thành "không tìm thấy gì".

`SKIP` ở region **ngoài** `allowed_regions` là bình thường — `region_lock` chặn cả `ec2:DeleteVpc`, và default VPC ở đó vô hại vì không ai tạo được gì. `SKIP` ở region **trong** `allowed_regions` mới là vấn đề.

**Kiểm độc lập**, đừng tin stack output — và lặp **mọi region** trong `sweep_regions`, không chỉ region đang mở terminal:

```bash
for p in <cac profile>; do
  printf '%-16s ' "$p"
  for r in <cac region trong sweep_regions>; do
    printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r --profile $p \
      --filters Name=isDefault,Values=true --query 'length(Vpcs)' --output text)"
  done; echo
done
```

Tất cả phải ra `0`. Lần dựng thật chỉ hỏi một region, và bỏ sót default VPC ở `us-east-1` tại **cả 5 account** — xem doc 22 mục 6d.

```bash
terraform output -raw paste_permission_sets
terraform output -raw paste_config_detective
terraform output unmapped_accounts
```

☑ Xong giai đoạn 9 khi: mọi account ra `0` default VPC, và `unmapped_accounts` rỗng.

Chi tiết ở [README của layer](./account-baseline/README.md).

---

## Giai đoạn 10 — `network`

> **Chỉ làm khi có workload thật cần kết nối.** ~$770/tháng ở 2 AZ. Chín giai đoạn trước cộng lại là ~$0/ngày.
>
> **Layer này chưa ai apply.** `plan` sạch, code đã soát, nhưng chưa chạm AWS lần nào — khác hẳn chín giai đoạn trên. Đi chậm, và kiểm từng bước.

```bash
cd ../network
cp terraform.tfvars.example terraform.tfvars

cd ../organization && terraform output account_ids   # lay network_account_id
cd ../network
```

Điền `network_account_id`. **Chưa đổi `enable` vội** — chạy thử trước:

```bash
terraform init -backend-config=backend.hcl
terraform plan          # enable = false -> PHAI ra 0 resource, khong loi
```

Rồi mới bật. Để **thử code** thì một AZ là đủ và rẻ hơn ~$335/tháng:

```hcl
enable             = true
availability_zones = ["ap-southeast-1a"]   # mot AZ: chi de thu
firewall_mode      = "alert"               # LUON alert truoc
```

```bash
terraform apply
```

`aws_networkfirewall_firewall` mất **vài phút** ở `PROVISIONING` — bình thường, đừng ngắt.

**Kiểm tra:**

```bash
aws network-firewall describe-firewall --firewall-name <project>-fw \
  --profile <network> --region ap-southeast-1 \
  --query 'FirewallStatus.Status' --output text
# PHAI la READY

# TGW da share chua - hoi tu ACCOUNT WORKLOAD, khong phai account network
aws ec2 describe-transit-gateways --profile <workload> --region ap-southeast-1 \
  --query 'TransitGateways[].TransitGatewayId' --output text
```

> **Một AZ không kiểm chứng được `appliance_mode_support`.** Với một AZ nó không bao giờ sai, nên bản rẻ này chứng minh được đường đi nhưng **không** chứng minh được cấu hình đúng cho môi trường thật. Biết giới hạn đó trước khi tin kết quả.

**Nối spoke** — bước hay quên nhất:

```bash
terraform output -raw paste_spoke_vpc    # chay khoi nay o ACCOUNT WORKLOAD
```

Rồi lấy attachment ID điền vào `spoke_attachments` của layer này và `apply` lại. Bỏ bước này thì attachment ở `State: available` mà **không thuộc route table nào** — không lỗi, không cảnh báo, không gói tin nào đi qua.

☑ Xong giai đoạn 10 khi: EC2 trong spoke `curl` ra Internet được, và IP trả về nằm trong `terraform output nat_public_ips`.

Chi tiết ở [README của layer](./network/README.md).

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
| `InvalidInputException: unrecognized service principal` | Một service principal sai làm hỏng cả resource, và AWS **không nói cái nào**. Bỏ bớt `aws_service_access_principals` về danh sách tối thiểu, apply lại, rồi thêm dần |
| `is tainted, so must be replaced` + `Instance cannot be destroyed` | Apply trước lỗi giữa chừng → Terraform đánh dấu tainted. Resource thật vẫn tốt (refresh được): `terraform untaint '"'"'aws_organizations_organization.this[0]'"'"'` rồi plan lại. **Đây là nguyên nhân hay gặp hơn cả biến bên dưới** |
| `Instance cannot be destroyed` (không có chữ tainted) trên `aws_organizations_organization` | Đổi `create_organization` từ `true` về `false` sau khi đã apply — Terraform hiểu là xoá org. Đặt lại `true`. Muốn chuyển sang chỉ đọc thật thì `terraform state rm 'aws_organizations_organization.this[0]'` trước |
| `AlreadyInOrganizationException` sau khi apply lỗi | Org **đã được tạo** trước khi bước sau lỗi. `terraform import aws_organizations_organization.this[0] <org-id>` |
| `Backend initialization required` | Có `backend.tf` nhưng layer chưa apply lần nào — `rm backend.tf`, `init -reconfigure`, apply, rồi `./wire-backends.sh` |
| `Unsetting the previously set backend "s3"` | `backend.tf` bị xoá (nó gitignore nên `git reset --hard`/`clean` hay quét phải) trong khi `.terraform` vẫn nhớ s3. **State vẫn an toàn trong S3.** Chạy `./wire-backends.sh` — script tự dựng lại `backend.tf` từ `backend.hcl` — rồi `terraform init -reconfigure -backend-config=backend.hcl` |
| `-backend-config was used without a "backend" block` | Thiếu `backend.tf`. Như trên |
| `terraform init` hỏi nhập bucket/key | Có `backend.tf` mà thiếu `-backend-config=backend.hcl` |
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
