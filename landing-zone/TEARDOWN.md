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
cd landing-zone
./plan-all.sh                   # layer nao that su dang co state
./unlock-destroy.sh             # cong 1 dang khoa/mo o dau
```

`plan-all.sh` cho biết layer nào thật sự đang có state — đừng destroy theo trí nhớ.

---

## 1. Thứ tự

Ngược chiều dựng. Mỗi bước **phải xong** trước khi sang bước sau.

```
11. landing-zone/network      ← neu dang chay
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

## 2. Gỡ chặn trước khi destroy

Hạ tầng thường trực có **hai cổng khoá**, và chúng khoá ở hai nơi khác nhau. Phải mở cả hai, mở đúng thứ tự.

| | Cổng 1 — `prevent_destroy` | Cổng 2 — `allow_destroy` |
|---|---|---|
| Khoá ở đâu | Terraform, trong `lifecycle` | AWS, trên chính resource |
| Mở bằng | `./unlock-destroy.sh --unlock` | `-var allow_destroy=true` |
| Vì sao không gộp | Terraform **không cho** dùng biến trong `lifecycle` — bắt buộc là hằng số viết thẳng trong file | — |
| Có gọi API không | **Không** | **Có** (firewall). Bucket thì không |
| Cần `apply` xen giữa | Không — mở xong destroy luôn | **Có — bắt buộc** |

### Cổng 1 — `prevent_destroy`

11 resource trên 6 layer. Xem trạng thái hiện tại:

```bash
cd landing-zone && ./unlock-destroy.sh
```

```
  tf-backend         KHOA     2 prevent_destroy
  organization       KHOA     4 prevent_destroy
  control-tower      KHOA     2 prevent_destroy
  config-detective   KHOA     1 prevent_destroy
  org-trail          KHOA     1 prevent_destroy
  account-baseline   KHOA     1 prevent_destroy
```

Mở khoá (script hỏi xác nhận, phải gõ đúng chữ `unlock`):

```bash
./unlock-destroy.sh --unlock                    # tat ca
./unlock-destroy.sh --unlock config-detective   # chi mot layer
./unlock-destroy.sh --lock                      # khoa lai
```

Script đổi `prevent_destroy = true` thành `false` chứ **không xoá dòng** — `git diff` nhìn ra ngay, và `--lock` đảo ngược lại chính xác. Nó chỉ khớp dòng đúng dạng `prevent_destroy = <bool>`, nên các chỗ nhắc tên biến trong comment và mô tả không bị đụng vào.

> Gặp `Instance cannot be destroyed` thì **không phải lỗi** — đó là cổng 1 đang làm đúng việc.

Xong teardown mà còn dùng repo thì `--lock` lại. Chạy `./unlock-destroy.sh` không tham số sẽ cảnh báo nếu còn chỗ đang mở.

### Cổng 2 — `allow_destroy`

Có ở 4 layer: `tf-backend`, `org-trail`, `config-detective`, `network`. Bật lên là gỡ hết bảo vệ phía AWS của layer đó cùng lúc.

| Layer | `allow_destroy = true` gỡ gì |
|---|---|
| `tf-backend` | `force_destroy` bucket state + bucket access log |
| `org-trail` | `force_destroy` bucket CloudTrail |
| `config-detective` | `force_destroy` bucket AWS Config |
| `network` | `delete_protection` + `subnet_change_protection` của Network Firewall, `force_destroy` bucket log firewall |

**Phải `apply` một lần riêng, rồi mới `destroy`** — cả hai loại, vì hai lý do khác nhau:

```bash
terraform apply   -var allow_destroy=true
terraform destroy -var allow_destroy=true
```

- **Firewall**: đổi `delete_protection` gọi `UpdateFirewallDeleteProtection` thật. Đặt biến rồi destroy ngay thì Terraform vẫn gặp firewall đang khoá.
- **Bucket**: `force_destroy` là thuộc tính **phía provider**, đổi nó không gọi API nào — nhưng nó chỉ có tác dụng nếu đã **nằm trong state** trước khi destroy.

> **Lệnh `apply` mới là lệnh bắt buộc, không phải cái `-var` ở lệnh `destroy`.** Kế hoạch destroy chỉ sinh hành động xoá, nó đọc thuộc tính từ **state** chứ không tính lại từ config — nên giá trị có tác dụng là giá trị `apply` đã ghi vào state. Truyền biến ở lệnh `destroy` chỉ để hai lệnh khớp nhau khi đọc lại lịch sử shell.

Bốn layer đều có `check` cảnh báo khi biến này còn bật, để lỡ quên thì `plan` nhắc:

```
Warning: Check block assertion failed
  allow_destroy = true: bucket state va bucket log dang o che do
  force_destroy, mot lan destroy la mat state cua MOI layer.
```

### Khi `force_destroy` vẫn không đủ

| Tình huống | Vì sao | Làm gì |
|---|---|---|
| **Object Lock** đang bật (`org-trail`, `config-detective`) | Object còn trong thời hạn giữ thì `COMPLIANCE` mode từ chối xoá, kể cả root | Đợi hết hạn. Không có đường tắt — đó là điểm của Object Lock |
| **MFA Delete** đang bật (bucket state) | Xoá version bắt buộc có MFA, và chỉ credential **root** làm được | Tắt bằng CLI với credential root + mã MFA, hoặc dọn tay như dưới |

Dọn tay bucket versioned — nhớ **cả** version lẫn delete marker, vì `aws s3 rm --recursive` chỉ tạo delete marker:

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

### Cổng thứ ba, không nằm trong layer nào: SCP

`config-detective` còn vướng một lớp nữa mà cả hai biến trên **đều không gỡ được** — xem [bước 7](#7--config-detective).

---

## 3. Từng bước

### 11 + 10 — Network

Cùng một cơ chế, hai tên biến ngược chiều nhau:

```bash
# landing-zone/network
ephemeral = true     # trong terraform.tfvars
terraform apply      # go bao ve - RIENG mot lan
./teardown.sh        # script tu choi chay khi ephemeral = false

# landing-zone/network
terraform apply   -var allow_destroy=true    # RIENG mot lan
terraform destroy -var allow_destroy=true
```

Cả hai gỡ đúng ba thứ: `delete_protection`, `subnet_change_protection`, và `force_destroy` bucket log firewall.

> Firewall endpoint phải biến mất **hẳn** thì VPC mới xoá được. Gặp `DependencyViolation` giữa chừng là bình thường — chạy `terraform destroy` lần nữa. Tổng ~15–20 phút.

### 9 — `account-baseline`

```bash
cd account-baseline && terraform destroy
```

`close_accounts_on_destroy = false` (mặc định) nên **account không bị đóng** — chỉ gỡ StackSet và Lambda dọn VPC. Nếu bạn tạo account bằng layer này thì `prevent_destroy` sẽ chặn; mở bằng `./unlock-destroy.sh --unlock account-baseline`, xem mục 2.

### 8 — `org-trail`

```bash
cd ../org-trail
terraform apply   -var allow_destroy=true    # RIENG mot lan
terraform destroy -var allow_destroy=true
```

Trail nằm ở **management account** nên `baseline` SCP (chặn `cloudtrail:DeleteTrail`) **không chạm tới**.

**Bật `enable_object_lock = true` thì `allow_destroy` không cứu được** — object còn trong thời hạn giữ vẫn từ chối xoá. Phải đợi hết hạn.

Đây là log kiểm toán của cả tổ chức. Cần giữ thì copy trước khi destroy:

```bash
aws s3 sync s3://<bucket-trail> ./trail-backup/ --profile <logarchive>
```

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

`scp_exempt_role_names` phải chứa role thực thi StackSet (`stacksets-exec-*`). Không có thì thêm vào rồi `apply` layer `organization` **trước**, sau đó mới destroy `config-detective`:

```bash
cd ../organization
terraform apply -var 'scp_exempt_role_names=["stacksets-exec-<hau-to>"]'

cd ../config-detective
terraform apply   -var allow_destroy=true    # RIENG mot lan
terraform destroy -var allow_destroy=true
```

Đừng dùng `enable_scp = false` cho việc này. Nó gỡ **sạch** SCP của cả tổ chức trong lúc bạn đang dọn dẹp — `scp_exempt_role_names` chỉ mở đúng một role, phần còn lại vẫn được bảo vệ.

**Và layer `organization` phải còn sống khi làm việc này.** Destroy nó ở bước 2 trước rồi mới phát hiện SCP đang chặn `config-detective` thì bạn tự khoá mình ra ngoài — SCP vẫn còn trên tổ chức nhưng Terraform không còn chỗ nào để sửa nó nữa.

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

Layer này **không có** `allow_destroy` — nó không giữ resource nào có bảo vệ phía AWS. Nhưng **kiểm một thứ trước khi mở cổng 1**:

```bash
cd organization && terraform state list | grep aws_organizations_organization
```

| Kết quả | Nghĩa là |
|---|---|
| **Rỗng** | Terraform chỉ đọc tổ chức qua data source. Destroy an toàn, sang phần dưới |
| `aws_organizations_organization.this[0]` | **Terraform đang quản lý chính tổ chức.** `destroy` sẽ XOÁ NÓ — mọi account con bị tách ra khỏi tổ chức |

Với trường hợp thứ hai, gỡ tổ chức khỏi state **trước**. Lệnh này không gọi API nào, tổ chức thật không hề bị đụng tới:

```bash
terraform state rm 'aws_organizations_organization.this[0]'
```

rồi đặt `create_organization = false` và destroy.

> **Đừng đổi `create_organization` về `false` khi chưa `state rm`.** `count` tụt từ 1 xuống 0, và Terraform hiểu là *"không quản nữa, XOÁ ĐI"* — đúng cái bạn đang tránh. Bình thường `prevent_destroy` chặn lại với `Instance cannot be destroyed`, nhưng nếu bạn vừa chạy `unlock-destroy.sh --unlock organization` thì **lưới an toàn đó đã bị gỡ**. Hai thao tác riêng lẻ đều hợp lý; ghép lại thì xoá mất tổ chức.

Xong phần đó rồi mới mở cổng 1:

```bash
cd .. && ./unlock-destroy.sh --unlock organization
cd organization && terraform destroy
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

Với `create_organization = false` **và** tổ chức không nằm trong state, Terraform chỉ gỡ OU cùng SCP — tổ chức và mọi account con giữ nguyên. Đó gần như luôn là điều bạn muốn.

#### Gửi account đi đâu: root, hay OU `Suspended`

Chuyển hết về root là cách nhanh nhất để OU rỗng. Nhưng account ở root **chỉ còn các SCP gắn ở root** — mất `network_lock` và `prod_guard`, trong khi vẫn chạy bình thường.

Nếu account còn sống tiếp — bạn parking chúng lại chứ không đóng — thì dùng OU `Suspended`. Layer `organization` đã có sẵn, xem [mục 6](#6-parking-account-thay-vì-đóng).

**Nhưng nếu bạn thật sự destroy layer `organization`** thì OU `Suspended` của nó cũng bị xoá theo, và OU nào còn account bên trong sẽ chặn chính lệnh destroy với `OrganizationalUnitNotEmptyException`. Hai đường ra:

| | |
|---|---|
| **Giữ layer** (thường đúng hơn) | Đừng destroy `organization`. Nó gần như miễn phí, và là nền móng cho mọi thứ dựng lại sau này |
| **Vẫn destroy** | Tạo một OU parking **bằng tay** ngoài Terraform trước, chuyển account sang đó. OU của layer khi ấy rỗng và xoá trôi |

### 1 — `tf-backend` — cuối cùng

Layer này giữ state của mọi layer khác. Chuyển state của **chính nó** về local trước, nếu không bạn xoá mất cái đang cầm:

```bash
cd ../tf-backend
# comment dong backend "s3" {} trong versions.tf
terraform init -migrate-state          # S3 -> local
terraform state list                   # phai con nguyen resource
```

Rồi mở cả hai cổng và destroy:

```bash
cd .. && ./unlock-destroy.sh --unlock tf-backend
cd tf-backend
terraform apply   -var allow_destroy=true    # RIENG mot lan
terraform destroy -var allow_destroy=true
```

`force_destroy` lo phần dọn bucket, kể cả version lẫn delete marker — **trừ** khi đã bật MFA Delete.

> Bật MFA Delete rồi thì xoá version **bắt buộc có MFA**, và chỉ credential **root** làm được — `force_destroy` cũng chịu. Phải tắt MFA Delete bằng CLI với credential root trước, hoặc dọn tay theo mục 2. Đó là lớp chặn cuối cùng, cố ý.

Xong hết mà còn giữ repo thì khoá lại:

```bash
cd .. && ./unlock-destroy.sh --lock
```

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

## 6. Parking account thay vì đóng

**Cách rẻ nhất để dừng một account mà không mất gì.** Account AWS không xoá được, chỉ đóng — và đóng là quyết định không lùi được: 90 ngày mới rời tổ chức, email cháy vĩnh viễn. OU `Suspended` là đường ở giữa: account vẫn tồn tại, nhưng SCP chặn mọi hành động.

Layer `organization` đã dựng sẵn cả hai phần: OU `Suspended` trong `ou_structure`, và SCP `suspended` (một statement `Deny *`) gắn vào đúng OU đó.

```bash
./park-account.sh --list                    # ai dang bi dong bang
./park-account.sh lz-app-dev                # dong bang mot account
./park-account.sh --restore lz-app-dev      # tha ra, VE DUNG OU CU
```

Script ghi OU cũ vào tag `lz:parked-from` **trước khi** move, nên `--restore` đưa account về đúng chỗ chứ không phải về root. Mất tag thì nó hỏi trước khi rơi về root, kèm cảnh báo rằng account ở root mất `network_lock` và `prod_guard`.

### Vì sao không phải Terraform

Account nằm ở OU nào là **trạng thái vận hành**, không phải mô tả hạ tầng. Đưa vào Terraform nghĩa là mỗi lần parking phải sửa code, commit, apply — và bất kỳ ai chạy `apply` với `tfvars` cũ sẽ lặng lẽ kéo account trở lại.

Script cũng **đọc trạng thái thật từ AWS** chứ không đọc `terraform output`, nên nó đúng kể cả khi state nằm ở máy khác.

### Ba thứ phải biết trước

| | |
|---|---|
| **Vẫn tính tiền** | SCP chặn *hành động*, không tắt máy. Tài nguyên đang chạy vẫn tính phí — **dọn sạch trước khi park**, xem mục 4 |
| **Không dọn được sau khi park** | `Deny *` chặn cả việc xoá tài nguyên. Muốn dọn phải `--restore` đưa ra trước |
| **Không park được management** | SCP không bao giờ áp lên management account. Script từ chối thẳng |

### Kiểu hỏng tệ nhất, và cách script chặn nó

Nguy hiểm nhất **không phải** thiếu OU — mà là **có OU mà không có SCP**. Khi đó lệnh chạy trót lọt, báo thành công, và account vẫn chạy bình thường trong một OU tên `Suspended`.

Script kiểm nội dung policy thật sự gắn trên OU trước khi move, và từ chối nếu không tìm thấy `Deny *`. Hai cấu hình dẫn tới trạng thái đó, cả hai đều có `check` cảnh báo lúc `plan`:

```hcl
enable_scp = { suspended = false }   # OU co, SCP khong
scp_dry_run = true                   # policy duoc tao nhung khong gan vao dau
```

> `FullAWSAccess` vẫn gắn ở OU và **không sao cả** — `Deny` tường minh luôn thắng `Allow`. Gỡ nó ra chỉ làm ý đồ rõ ràng hơn, và phải làm bằng tay vì Terraform không quản lý attachment mặc định của AWS.

---

## Liên quan

| | |
|---|---|
| [RUNBOOK](./RUNBOOK.md) | Chiều ngược lại — dựng theo thứ tự |
| [`unlock-destroy.sh`](./unlock-destroy.sh) | Bật/tắt `prevent_destroy` — cổng 1 ở mục 2 |
| [`park-account.sh`](./park-account.sh) | Đóng băng account mà không đóng nó — mục 6 |
| [doc 22](../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) | Lỗi 20: SCP chặn chính CloudFormation |
| [doc 20](../docs/20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
