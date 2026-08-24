# Terraform Backend

Nơi cất state cho **mọi layer thường trực** của LZ. Chạy ở **management account**.

Đây là layer **đầu tiên** phải dựng — mọi layer khác phụ thuộc vào nó.

**Chi phí: ~$0.** State vài trăm KB, DynamoDB `PAY_PER_REQUEST` vài request mỗi lần apply. Bật KMS CMK thì thêm ~$1/tháng.

---

## Vì sao cần

State local dùng được khi một người làm một layer. Với LZ vận hành lâu dài thì không:

| Vấn đề | Xảy ra khi nào |
|---|---|
| State nằm trên máy cá nhân | Bạn nghỉ phép → không ai apply được |
| Không có lock | Hai người apply cùng lúc → **state hỏng**, phải import lại tay |
| Không có lịch sử | Không biết ai đổi gì, khi nào |
| Mất máy = mất state | Terraform không còn biết resource nào của mình |

Cái thứ hai không phải rủi ro lý thuyết. Nó xảy ra rất nhanh khi có từ hai người.

---

## Có gì trong này

| Thành phần | Làm gì |
|---|---|
| **S3 bucket** | Chứa state, bật versioning + mã hoá + chặn public |
| **Versioning** | Cứu bạn khi apply nhầm — quay lại bản trước được |
| **Lifecycle** | Dọn version cũ sau 90 ngày, huỷ multipart dở |
| **`BucketOwnerEnforced`** | Account chứa bucket luôn sở hữu mọi object, kể cả object account khác ghi vào |
| **Bucket policy** | Chặn non-TLS; mỗi account con chỉ ghi được vào prefix của nó |
| **DynamoDB table** | Khoá khi apply (tuỳ chọn — xem dưới) |
| **KMS key** | Tuỳ chọn, mặc định tắt |
| **Access log bucket** | Ghi lại ai đọc/ghi state |
| **`prevent_destroy`** | Chặn `terraform destroy` xoá nhầm bucket và bảng khoá |

---

## Chạy

### Bước 1 — Apply lần đầu (state còn local)

```bash
cd landing-zone/tf-backend
cp terraform.tfvars.example terraform.tfvars
# sua prefix, region, cost tag

terraform init
terraform apply
```

Lần đầu **bắt buộc** dùng state local — bucket chưa tồn tại thì chưa có chỗ cất state của chính nó. Vòng lặp con gà quả trứng, ai cũng phải đi qua.

### Bước 2 — Sinh `backend.hcl` cho mọi layer

```bash
./wire-backends.sh --dry-run    # xem truoc
./wire-backends.sh              # ghi that
```

Script chỉ **tạo file `backend.hcl`**, không sửa file `.tf` nào và không tự chuyển state. Việc chuyển do bạn chạy tay, có đọc kỹ trước khi đồng ý.

### Bước 3 — Chuyển chính layer này sang remote state

```bash
# 1. Bo comment dong  backend "s3" {}  trong versions.tf
terraform init -migrate-state -backend-config=backend.hcl
#    -> Terraform hoi "copy existing state?" -> yes

# 2. Kiem tra
terraform state list        # phai con nguyen resource

# 3. Xoa state local
rm terraform.tfstate terraform.tfstate.backup
```

**Đừng bỏ qua bước này.** Bỏ qua nghĩa là state của layer quản lý state vẫn nằm trên máy bạn — mất máy là mất quyền quản lý bucket state của cả tổ chức.

### Bước 4 — Nối các layer còn lại

Làm **từng layer một**, kiểm tra xong mới sang layer tiếp:

```bash
cd ../billing-guard
terraform init -migrate-state -backend-config=backend.hcl
terraform state list
terraform plan                  # phai la "No changes"

cd ../permission-sets
terraform init -migrate-state -backend-config=backend.hcl
terraform state list
terraform plan                  # phai la "No changes"
```

`terraform plan` ra **"No changes"** là dấu hiệu chuyển đúng. Ra diff nghĩa là state không chuyển được đầy đủ — **dừng lại**, đừng apply.

---

## Chọn cách khoá state

```hcl
lock_mode = "dynamodb"   # mac dinh
```

| Chế độ | Yêu cầu | Khi nào dùng |
|---|---|---|
| `dynamodb` | Mọi phiên bản Terraform | **Mặc định.** An toàn nhất về tương thích |
| `s3` | **Terraform ≥ 1.10** | Không cần thêm resource nào; khoá bằng chính S3 |
| `both` | — | Đang chuyển dần, còn layer cũ trỏ tới DynamoDB |

Kiểm tra phiên bản trước khi chọn `s3`:

```bash
terraform version
```

Dưới 1.10 mà đặt `lock_mode = "s3"` thì backend sẽ báo lỗi không nhận `use_lockfile`.

---

## Mã hoá: SSE-S3 hay KMS

Mặc định `use_kms_cmk = false`.

**Cả hai đều mã hoá thật** ở mức lưu trữ. Khác biệt nằm ở quyền quản lý khoá:

| | SSE-S3 (mặc định) | KMS CMK |
|---|---|---|
| Chi phí | $0 | ~$1/tháng + phí request |
| Ai giữ khoá | AWS | Bạn |
| Chặn đọc state | Phải thu quyền S3 | Thu quyền trên key là đủ, **kể cả khi còn quyền S3** |
| Audit | Log S3 | Thêm CloudTrail riêng cho từng lần dùng khoá |

Bật khi state bắt đầu chứa bí mật — mật khẩu RDS, khoá API do Terraform sinh. Hai layer hiện tại (`billing-guard`, `permission-sets`) thì **không chứa bí mật nào**.

---

## Layer chạy ở account khác

Layer network chạy ở account network nhưng vẫn ghi state vào bucket này:

```hcl
state_writer_accounts = {
  network  = "222222222222"
  security = "333333333333"
}
```

Sinh ra bucket policy cho mỗi account một prefix riêng:

```
account 2222  →  s3://<bucket>/network/*     ghi được
              →  s3://<bucket>/security/*    KHÔNG đọc được
```

Hai điều kèm theo:

**1. `BucketOwnerEnforced` là bắt buộc, không phải tuỳ chọn.** Thiếu nó thì state do account network ghi lên sẽ **thuộc sở hữu của account network**, và management account có thể không đọc được chính file trong bucket của mình.

**2. Dùng KMS thì phải cấp quyền hai nơi.** Key policy (code đã làm) **và** IAM policy phía account con. Thiếu một nơi là `AccessDenied` lúc `terraform init`, khá khó đoán nguyên nhân.

> `aws_dynamodb_resource_policy` cần provider AWS tương đối mới. Nếu apply báo không nhận resource này thì nâng provider, hoặc cấp quyền khoá qua IAM policy phía account con.

---

## Bước thủ công: MFA Delete

Terraform không làm được — cần credential **root** và bắt buộc qua CLI:

```bash
aws s3api put-bucket-versioning \
  --bucket <ten-bucket> \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::<account>:mfa/root-account-mfa-device <ma-6-so>"
```

Sau khi bật, xoá version state phải có MFA. Đây là lớp chặn cuối cùng chống xoá nhầm.

---

## Khi state hỏng

Versioning tồn tại chính là để dùng lúc này.

```bash
# 1. Xem cac ban truoc
aws s3api list-object-versions \
  --bucket <ten-bucket> \
  --prefix permission-sets/terraform.tfstate \
  --query 'Versions[].[VersionId,LastModified,Size]' --output table

# 2. Tai ban truoc do ve XEM, chua ghi de gi
aws s3api get-object \
  --bucket <ten-bucket> \
  --key permission-sets/terraform.tfstate \
  --version-id <VERSION_ID> \
  /tmp/state-cu.json

# 3. Doi chieu
jq '.resources[].type' /tmp/state-cu.json | sort | uniq -c

# 4. Chac chan roi moi day len
aws s3api copy-object \
  --bucket <ten-bucket> \
  --key permission-sets/terraform.tfstate \
  --copy-source "<ten-bucket>/permission-sets/terraform.tfstate?versionId=<VERSION_ID>"
```

Nếu lock bị kẹt (apply chết giữa chừng):

```bash
terraform force-unlock <LOCK_ID>
```

Chỉ chạy khi **chắc chắn** không còn ai đang apply. Gỡ khoá trong lúc người khác đang chạy thì đúng cái tình huống mà khoá sinh ra để ngăn.

---

## Demo thì vẫn dùng state local

`demo/*` **không** nối vào backend này. Cố ý:

- Demo dựng lên xem rồi xoá, không cần lịch sử
- Chúng gắn `Ephemeral = "true"` và có `teardown.sh`
- Thêm remote state chỉ làm phức tạp việc dựng–xoá nhanh

Layer thường trực thì ngược lại — state là thứ có giá trị nhất, phải giữ.

---

## Xoá

Bucket và bảng khoá đều có `prevent_destroy = true`, nên `terraform destroy` sẽ **fail** — đúng như thiết kế.

Xoá thật phải mở **hai cổng**, ở hai nơi khác nhau:

```bash
cd .. && ./unlock-destroy.sh --unlock tf-backend   # cong 1: prevent_destroy
cd tf-backend
terraform apply   -var allow_destroy=true          # cong 2: force_destroy bucket
terraform destroy -var allow_destroy=true
```

Ba bước có chủ đích, không thể lỡ tay. `force_destroy` phải nằm trong state **trước** khi destroy mới có tác dụng — nên `apply` đó bắt buộc, không gộp được vào lệnh destroy.

Bật MFA Delete rồi thì `force_destroy` cũng chịu: xoá version bắt buộc có MFA và chỉ credential **root** làm được.

**Và trước tất cả: chuyển state của chính layer này về local**, nếu không bạn xoá mất cái đang cầm. Xem [TEARDOWN.md bước 1](../TEARDOWN.md#1--tf-backend--cuối-cùng).

Nhưng **cân nhắc đừng xoá**: xoá bucket state là mọi layer khác mất dấu vết về resource của mình. Terraform sẽ không còn biết cái gì là của nó, và bạn phải `terraform import` lại từng resource bằng tay.

---

## Liên quan

| | |
|---|---|
| [Doc 20 – Vận hành LZ](../../docs/20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Mô hình vận hành, quy trình thay đổi hằng ngày |
| [Doc 10 – CI/CD GitHub Actions OIDC](../../docs/10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) | Plan trong PR, apply sau approve |
| [`landing-zone/permission-sets`](../permission-sets/) | Layer dùng backend này |
| [`landing-zone/billing-guard`](../billing-guard/) | Layer dùng backend này |
