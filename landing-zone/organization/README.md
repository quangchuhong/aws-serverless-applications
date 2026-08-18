# Organization (DIY)

Organizations + OU + SCP bằng Terraform thuần. Chạy ở **management account**.

> **Đây là bản dùng thật cho lab.** Bản Control Tower để đối chiếu ở [`../control-tower/`](../control-tower/), mặc định tắt. So sánh đầy đủ: [doc 21](../../docs/21-Control-Tower-vs-DIY.md).

**Chi phí: $0.** Organizations, OU và SCP đều miễn phí.

---

## Có gì

| Thành phần | Ghi chú |
|---|---|
| `aws_organizations_organization` | `feature_set = ALL` — bắt buộc để dùng SCP |
| Cây OU 2 cấp | Khớp với phạm vi của `permission-sets` |
| **4 SCP** | Gom lại vì AWS chỉ cho 5 policy/target |
| `check` block | Tự bắt vượt giới hạn ký tự và số lượng |

### Cây OU

```
Root
├── Security          log-archive, audit
├── Infrastructure    network, shared-services   ← KHÔNG bị network_lock
├── Workloads
│   ├── Non-Production   → permission-sets scope "nonprod"
│   └── Production       → permission-sets scope "prod"
├── Data Analytics       → permission-sets scope "analytics"
├── Sandbox
└── Suspended
```

Đổi cấu trúc ở đây thì **phải** đổi `accounts_by_scope` bên `permission-sets`. Có `check` block bắt việc này.

---

## Bốn SCP

AWS giới hạn **5 policy gắn vào một target**, `FullAWSAccess` đã chiếm 1 → còn 4. Nên không viết 10 SCP nhỏ mà gom thành 4 SCP lớn.

| SCP | Gắn vào | Chặn gì |
|---|---|---|
| `baseline` | Root | Rời tổ chức, tắt CloudTrail/Config/GuardDuty, root user, tạo IAM user |
| `region_lock` | Root | Mọi region ngoài `allowed_regions` |
| `network_lock` | Workloads, Data Analytics, Sandbox | IGW/NAT/EIP/TGW/VPN/peering, public IP lúc launch |
| `prod_guard` | Workloads/Production | Xoá snapshot, xoá KMS key, tắt versioning S3 |

`Infrastructure` **không** bị `network_lock` — network account sống ở đó và cần đúng những action ấy.

Kích thước thực tế (giới hạn 5120 ký tự/SCP):

```
baseline      ~1511    29%
region_lock    ~709    14%
network_lock  ~1013    20%
prod_guard     ~649    13%
```

Còn nhiều chỗ để thêm.

---

## Chạy

```bash
cd landing-zone/organization
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan
```

### Trước tiên: Organization đã có chưa

```bash
aws organizations describe-organization
```

| Kết quả | Đặt |
|---|---|
| Ra thông tin | `create_organization = false` — Terraform chỉ đọc |
| Báo lỗi | `create_organization = true` — Terraform tạo mới |

Đã có mà đặt `true` thì apply lỗi `AlreadyInOrganizationException`. Muốn Terraform quản cái đã có thì import:

```bash
terraform import aws_organizations_organization.this o-xxxxxxxxxx
```

### Bật SCP từng cái một

Mặc định trong `terraform.tfvars.example`:

```hcl
enable_scp = {
  baseline     = true
  region_lock  = false
  network_lock = false
  prod_guard   = false
}

scp_dry_run = true    # TAO policy nhung KHONG GAN
```

`scp_dry_run = true` tạo policy để bạn đọc trên console mà **chưa chặn gì**. SCP gắn nhầm có thể khoá cả tổ chức ra ngoài — bước này đáng vài phút.

Thứ tự đề xuất: `baseline` → `region_lock` → `network_lock` → `prod_guard`. Bật hết một lượt rồi có gì hỏng thì không biết do cái nào.

---

## Kiểm chứng — quan trọng hơn phần cho phép

SCP chặn sai thì **im lặng** cho tới khi có người vướng. Phải chủ động thử:

```bash
# Account Workloads - PHAI bi tu choi
aws ec2 create-internet-gateway --profile lz-app-dev

# Ngoai allowed_regions - PHAI bi tu choi
aws ec2 describe-vpcs --region eu-west-1 --profile lz-app-dev

# Account Infrastructure - PHAI THANH CONG
aws ec2 create-internet-gateway --profile lz-network

# Xem SCP nao dang ap cho mot account
aws organizations list-policies-for-target \
  --target-id <account-id> --filter SERVICE_CONTROL_POLICY
```

Dòng thứ ba quan trọng ngang ba dòng kia: siết quá tay cũng là lỗi.

---

## Ba điều dễ vấp

**1. SCP không áp dụng cho management account.** Mọi quyền ở đó là quyền thật, không có trần chặn. Đó là lý do management account phải "sạch".

**2. `allowed_regions` bắt buộc có `us-east-1`.** CloudFront, WAF scope CLOUDFRONT, ACM cho CloudFront và nhiều API billing chỉ tồn tại ở đó. Có `validation` chặn nếu thiếu.

**3. OU không tự thành quyền.** Identity Center chỉ nhận `AWS_ACCOUNT`, không nhận OU. Chuyển account vào OU xong vẫn phải cập nhật `accounts_by_scope` bên `permission-sets` rồi apply.

```bash
terraform output accounts_by_scope_hint
terraform output active_accounts
```

---

## Xoá

Organization và OU đều có `prevent_destroy = true` — `terraform destroy` sẽ **fail**, đúng thiết kế.

Xoá organization = mọi account con bị tách ra, SCP mất tác dụng, CloudTrail org trail và RAM share ngừng hoạt động. Muốn xoá thật thì bỏ `lifecycle` trong code, apply, rồi mới destroy.

---

## Liên quan

| | |
|---|---|
| [Doc 21 – Control Tower vs DIY](../../docs/21-Control-Tower-vs-DIY.md) | So sánh hai bản |
| [Doc 06 – Landing Zone](../../docs/06-Aws-Landing-Zone.md) | Nền tảng |
| [Doc 13 – Centralized Ingress/Egress](../../docs/13-Centralized-Ingress-Egress-Network.md) | Nguồn của `network_lock` |
| [`../permission-sets`](../permission-sets/) | SCP là trần trên permission set |
| [`../tf-backend`](../tf-backend/) | Remote state |
