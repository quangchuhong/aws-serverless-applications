# Teardown — xoá Landing Zone theo thứ tự

Ngược lại [RUNBOOK](./RUNBOOK.md). Đọc hết trước khi gõ lệnh đầu tiên.

> **Ba thứ không hoàn tác được, và không lệnh nào cảnh báo bạn:**
>
> | | |
> |---|---|
> | **Account** | Không xoá được, chỉ **đóng**. Đóng rồi nằm lại tổ chức **90 ngày**, và **email không bao giờ dùng lại được** ở phạm vi AWS toàn cầu |
> | **Identity Center** | Xoá instance là mất toàn bộ user/group/assignment, và **identity store ID đổi** → URL portal đổi |
> | **Lịch sử** | CloudTrail, Config, log firewall — xoá bucket là mất bằng chứng, không khôi phục được |

---

## 0. Trước khi bắt đầu

**Chạy từ management account.** SCP **không bao giờ** áp lên management account, nên không có chuyện SCP tự chặn việc gỡ chính nó — đó là lý do mọi bước dưới đây chạy được.

```bash
aws sts get-caller-identity     # phai la management, KHONG phai account con
unset AWS_PROFILE               # export con sot lai se gui lenh sai account
cd landing-zone && ./plan-all.sh
```

`plan-all.sh` cho biết layer nào thật sự đang có state — đừng destroy theo trí nhớ.

---

## 1. Thứ tự

Ngược chiều dựng. Mỗi bước **phải xong** trước khi sang bước sau.

```
11. demo/network-lz-full      ← neu dang chay
10. landing-zone/network      ← neu da enable
 9. account-baseline
 8. org-trail
 7. config-detective
 6. billing-guard
 5. permission-sets
 4. Identity Center           ← console, khong Terraform
 3. Account                   ← KHONG XOA DUOC, xem muc 3
 2. organization
 1. tf-backend                ← CUOI CUNG
```

**Vì sao ngược chiều:** `config-detective` và `org-trail` cần delegated administrator do `organization` đăng ký; `permission-sets` cần Identity Center instance; và `tf-backend` giữ state của **mọi layer khác** — xoá nó trước là mất khả năng destroy phần còn lại.

---

## 2. Hai thứ chặn mọi bước

### `prevent_destroy` — phải sửa code, không phải đổi biến

```
account-baseline/accounts.tf      account
config-detective/s3-log-archive.tf bucket snapshot
control-tower/main.tf              ×2
org-trail/main.tf                  bucket trail
organization/organization.tf       ×3  org, OU
organization/delegated-admin.tf    delegated admin
tf-backend/main.tf                 ×2  bucket state, khoá
```

Gặp `Instance cannot be destroyed` thì **không phải lỗi** — đó là lớp chặn làm đúng việc. Gỡ bằng cách xoá khối `lifecycle { prevent_destroy = true }` trong file tương ứng, commit lại, rồi destroy. Sửa xong nhớ hoàn nguyên nếu còn dùng repo.

### Không layer nào có `force_destroy`

Mọi bucket còn object là `destroy` dừng lại. **Cố ý** — bucket ở đây chứa log kiểm toán.

Bucket đều bật **versioning**, nên `aws s3 rm --recursive` **không đủ**: nó chỉ tạo delete marker. Phải xoá cả version lẫn delete marker:

```bash
BUCKET=<ten-bucket>; PROFILE=<profile>

aws s3api list-object-versions --bucket "$BUCKET" --profile "$PROFILE" \
  --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  > /tmp/v.json
aws s3api delete-objects --bucket "$BUCKET" --profile "$PROFILE" --delete file:///tmp/v.json

aws s3api list-object-versions --bucket "$BUCKET" --profile "$PROFILE" \
  --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
  > /tmp/d.json
aws s3api delete-objects --bucket "$BUCKET" --profile "$PROFILE" --delete file:///tmp/d.json
```

Bucket rỗng thật thì `list-object-versions` không in gì.

---

## 3. Từng bước

### 11 + 10 — Network

Bộ demo và layer thật đều bật bảo vệ khi `ephemeral = false`:

```hcl
ephemeral = true     # demo/network-lz-full
```

```bash
terraform apply      # go bao ve - RIENG mot lan
./teardown.sh        # script tu choi chay khi ephemeral = false
```

`landing-zone/network` thì đổi `delete_protection` của firewall về `false`, apply, rồi destroy.

> Firewall endpoint phải biến mất **hẳn** thì VPC mới xoá được. Gặp `DependencyViolation` giữa chừng là bình thường — chạy `terraform destroy` lần nữa. Tổng ~15–20 phút.

### 9 — `account-baseline`

```bash
cd account-baseline && terraform destroy
```

`close_accounts_on_destroy = false` (mặc định) nên **account không bị đóng** — chỉ gỡ StackSet và Lambda dọn VPC. Nếu bạn tạo account bằng layer này thì `prevent_destroy` sẽ chặn; xem mục 2.

### 8 — `org-trail`

Trail nằm ở **management account** nên `baseline` SCP (chặn `cloudtrail:DeleteTrail`) **không chạm tới**. Bucket ở logarchive thì phải dọn tay trước — xem mục 2.

### 7 — `config-detective`

**Bước dễ kẹt nhất.** `baseline` SCP chặn ở mọi account thành viên:

```
config:DeleteConfigurationRecorder
config:StopConfigurationRecorder
config:DeleteDeliveryChannel
```

Recorder do StackSet tạo trong account thành viên, nên xoá chúng **phải qua role được miễn trừ**. Kiểm trước khi destroy:

```bash
cd ../organization && terraform output -json scp_summary
```

`scp_exempt_role_names` phải chứa role thực thi StackSet (`stacksets-exec-*`). Không có thì thêm vào rồi `apply` layer `organization` **trước**, sau đó mới destroy `config-detective`.

> Đây chính là lỗi 20 trong [doc 22](../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md): SCP chặn chính CloudFormation, và thông báo lỗi chỉ nói *"explicit deny in a service control policy"* kèm ID policy — không nói action nào.

### 6 — `billing-guard`

Gọn. Một lưu ý: anomaly monitor là **của AWS tạo sẵn**, layer chỉ tham chiếu qua `service_anomaly_monitor_arn` — destroy **không** xoá nó, và như vậy là đúng.

### 5 — `permission-sets`

115 resource. **Sau bước này không ai đăng nhập được qua SSO nữa.** Giữ sẵn một đường vào khác trước khi chạy — IAM user ở management, hoặc `OrganizationAccountAccessRole`.

### 4 — Identity Center

**Console, không có Terraform.** IAM Identity Center → Settings → Delete. Phải gõ tên instance để xác nhận.

Bỏ qua bước này cũng được: instance không tính tiền. Chỉ xoá khi thật sự muốn trả account về trạng thái trắng.

### 3 — Account

**Dừng lại và đọc.** Account **không xoá được**.

| Muốn gì | Làm gì |
|---|---|
| Giữ account, bỏ quản lý tập trung | Bỏ qua bước này. Sang bước 2 |
| Đóng thật | Console → Account settings → Close account, **từng account một** |

Đóng account là quyết định **không lùi được**: 90 ngày mới rời tổ chức, và email cháy vĩnh viễn.

> `baseline` SCP chặn `account:CloseAccount` và `organizations:LeaveOrganization` ở account thành viên. Đóng từ **management account** thì không vướng — SCP không áp lên management.

### 2 — `organization`

```bash
cd ../organization
# go prevent_destroy trong organization.tf va delegated-admin.tf
terraform destroy
```

**OU phải rỗng.** Còn account trong OU thì `DeleteOrganizationalUnit` báo `OrganizationalUnitNotEmptyException`. Chuyển account về root trước:

```bash
ROOT=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
for id in $(aws organizations list-accounts --query 'Accounts[].Id' --output text); do
  src=$(aws organizations list-parents --child-id "$id" --query 'Parents[0].Id' --output text)
  [ "$src" = "$ROOT" ] && continue
  aws organizations move-account --account-id "$id" \
    --source-parent-id "$src" --destination-parent-id "$ROOT"
done
```

Giữ `create_organization = false` thì Terraform **không** xoá tổ chức, chỉ gỡ OU và SCP. Đó gần như luôn là điều bạn muốn.

### 1 — `tf-backend` — cuối cùng

Layer này giữ state của mọi layer khác. Chuyển state của **chính nó** về local trước, nếu không bạn xoá mất cái đang cầm:

```bash
cd ../tf-backend
# comment dong backend "s3" {} trong versions.tf
terraform init -migrate-state          # S3 -> local
terraform state list                   # phai con nguyen resource
```

Rồi dọn bucket (xem mục 2 — nhớ cả version lẫn delete marker), gỡ `prevent_destroy`, và:

```bash
terraform destroy
```

> Bật MFA Delete rồi thì xoá version **bắt buộc có MFA**, và chỉ credential **root** làm được. Đó là lớp chặn cuối cùng, cố ý.

---

## 4. Xác nhận đã sạch

```bash
for p in <cac profile>; do
  printf '%-16s ' "$p"
  printf 'vpc=%s ' "$(aws ec2 describe-vpcs --profile $p --query 'length(Vpcs)' --output text)"
  printf 'tgw=%s ' "$(aws ec2 describe-transit-gateways --profile $p \
    --query 'length(TransitGateways[?State!=`deleted`])' --output text)"
  printf 'nat=%s\n' "$(aws ec2 describe-nat-gateways --profile $p \
    --query 'length(NatGateways[?State!=`deleted`])' --output text)"
done
```

**Đọc kỹ cột `vpc`:** ra `1` thường là **default VPC** — AWS tự tạo lại khi không có gì, và nó vô hại. Ra `0` nghĩa là `account-baseline` đã dọn và chưa có gì tạo lại.

Kiểm chi phí sau **48 giờ** — Cost Explorer trễ, xoá xong hôm nay không thấy ngay:

```
Cost Explorer → Service → Daily
```

---

## 5. Ba thứ vẫn còn sau khi destroy xong

| | |
|---|---|
| **Configuration item của AWS Config** | Đã ghi rồi, không xoá được. Nằm trong bucket log archive — nếu bucket đó đã xoá thì mất theo |
| **Bản ghi managed instance của SSM** | Tự hết sau vài ngày. Vô hại, không tính tiền |
| **Account** | Vẫn tồn tại trừ khi bạn cố ý đóng ở bước 3 |

---

## Liên quan

| | |
|---|---|
| [RUNBOOK](./RUNBOOK.md) | Chiều ngược lại — dựng theo thứ tự |
| [doc 22](../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) | Lỗi 20: SCP chặn chính CloudFormation |
| [doc 20](../docs/20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
