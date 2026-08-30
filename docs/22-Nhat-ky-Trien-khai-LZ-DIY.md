# Nhật ký triển khai LZ bản DIY

Ví dụ 22: Ghi lại **lần dựng thật đầu tiên** — làm gì, vấp ở đâu, sửa thế nào.

> Khác với [RUNBOOK](../landing-zone/RUNBOOK.md) (*làm gì, theo thứ tự nào*) và các doc thiết kế (*vì sao*). File này ghi **cái đã thật sự xảy ra** — thứ mà không tài liệu thiết kế nào bắt được, vì phải chạy mới biết.
>
> Mọi lỗi dưới đây đều đã sửa và push. Cột "Commit" là bằng chứng.

---

## 0. Kết quả

Dựng từ một account trắng đến LZ có guardrail hoạt động, kiểm chứng được.

| Thành phần | Kết quả |
|---|---|
| Organization | `o-tvkzhcq3yh`, root `r-o5ci` |
| Cây OU | 8 OU — 6 cấp 1 + 2 cấp 2 |
| SCP | 4 policy: `baseline` + `region_lock` ở root, `network_lock` ở 3 OU, `prod_guard` ở `Production` |
| Remote state | S3 + versioning + Object Lock + khoá DynamoDB, 16 resource |
| Account | 6 ACTIVE — management, network, security, logarchive, app-dev, app-prod |
| Kiểm chứng SCP | 4/4 policy — kể cả `prod_guard`, sau 3 lần phép thử hỏng (mục 5c) |
| Identity Center | `ssoins-8210168ac3d88c11`, identity store `d-9667ae9e62` |
| Permission set | 17 set, 15 group, 53 assignment — 115 resource |
| Billing guard | Budget $20, SNS alert (đã xác nhận), anomaly detection — us-east-1 |
| Default VPC | Xoá tay ở `ap-southeast-1` — **và chỉ ở đó**, xem mục 6d |
| Config detective | 4/4 recorder đang ghi, aggregator, 8 org rule — 26 resource |
| Đăng nhập SSO | Kiểm chứng thật — portal hiện đúng 5 account, không có management |
| Org trail | CloudTrail toàn tổ chức, multi-region, log file validation — 8 resource |
| Account baseline | StackSet + Lambda, `auto_deployment`, 5/5 stack instance CURRENT |
| **Vòng khép kín** | `cloud-trail-enabled`: NON_COMPLIANT ×4 → dựng `org-trail` → **COMPLIANT ×4** |
| **Tự động bắt lỗi tay** | `account-baseline` xoá **5 default VPC ở `us-east-1`** mà lần dọn tay bỏ sót |
| Đường cảnh báo | `plan-all.sh` bắt được email cảnh báo bảo mật **không tới ai** — xem mục 6e |
| **Xoá và dựng lại** | 158 resource xoá / 5 layer, rồi 162 dựng lại — kiểm chứng cả hai chiều, xem mục 7 |

**Thời gian thật:** ~3 giờ, trong đó phần lớn là gỡ 34 lỗi dưới đây. Đường đi sạch thì khoảng 1 giờ.

**Chi phí đo được:** $0.29 một lần cho lần quét đầu của AWS Config, sau đó ~$0/ngày. Sáu layer còn lại không tốn gì — S3 vài trăm KB, DynamoDB `PAY_PER_REQUEST`, Organizations/OU/SCP miễn phí.

---

## 1. Bảng lỗi

Xếp theo thứ tự gặp phải.

| # | Lỗi | Nguyên nhân | Loại | Commit sửa |
|---|---|---|---|---|
| 1 | `InvalidInputException: unrecognized service principal` | `reports.billing.amazonaws.com` không hợp lệ | **Lỗi code** | `fd49be8` |
| 2 | `Backend initialization required` | Bật backend trước khi apply | Thiết kế bẫy người dùng | `977f057`, `5434ea7` |
| 3 | `Khong doc duoc output backend_hcl` | Script nuốt stderr của Terraform | **Lỗi code** | `1e5a39a` |
| 4 | Git branch diverged | Bắt sửa file được git track để bật backend | **Lỗi thiết kế** | `5434ea7` |
| 5 | `Unsetting the previously set backend "s3"` | `backend.tf` mất, state vẫn ở S3 | Vòng lặp thứ hai do #4 | `27dfc65` |
| 6 | `grey: command not found` | Hàm được gọi mà chưa khai | **Lỗi code** | `5434ea7` |
| 7 | Script bảo migrate cả 6 layer | Không phân biệt layer đã/chưa có state | Lỗi logic | `df67624`, `15abb10` |
| 8 | `Instance cannot be destroyed` | `create_organization` đổi `true`→`false` | Tên biến gây hiểu nhầm | `cad896f` |
| 9 | `is tainted, so must be replaced` | Apply lỗi giữa chừng để lại taint | Hệ quả của #1 | `3410e1a` |
| 10 | `Inconsistent conditional result types` | `?:` trả về tuple 2 vs tuple 0 trong `permission-sets` | **Lỗi code** | *(mục 2.5)* |
| 11 | `validate-policies.sh` in bảng rỗng rồi thoát 0 | Mã thoát pipeline là của `sed`, `set -e` không nổ | **Lỗi code** | *(mục 2.5)* |
| 12 | `Limit exceeded on dimensional spend monitor creation` | Mỗi account chỉ được 1 dimensional monitor, AWS đã tạo sẵn | **Lỗi code** | *(mục 2.6)* |
| 13 | `Daily or weekly frequencies only support Email subscriptions` | `frequency` và `subscriber.type` ràng buộc nhau | **Lỗi code** | *(mục 2.6)* |
| 14 | `InvalidAccessException: not an administrator` | Security Hub cần chỉ định riêng, Organizations chưa đủ | Thiếu tài liệu | `a48f8a6` |
| 15 | `Unsupported argument: stack_set_instance_region` | Dùng tên tham số của provider v6 trong layer khai `~> 5.0` | **Lỗi code** | `688f3db` |
| 16 | `'Days' in Expiration must be greater than Transition` | Transition ghi cứng 90/180, expiration lấy từ biến | **Lỗi code** | `a397c29` |
| 17 | `You must enable organizations access` | CloudFormation có lời gọi kích hoạt riêng | Thiếu tài liệu | `a397c29` |
| 18 | `InsufficientDeliveryPolicyException` | Sai condition key: `SourceOrgID` thay vì `SourceAccount` | **Lỗi code** | `24836dc` |
| 19 | `InsufficientDeliveryPolicyException` *(vẫn)* | **Object Lock** chặn Config ghi — policy hoàn toàn đúng | **Lỗi thiết kế** | `ee6ebd3` |
| 20 | `explicit deny ... p-2oni53yp` khi rollback | SCP chặn chính CloudFormation | **Lỗi thiết kế** | `150c013` |
| 21 | `NoAvailableDeliveryChannelException` | Vòng lặp giữa hai API Config | **Lỗi code** | `f8754fe` |
| 22 | `NoAvailableConfigurationRecorder` + `UnableToAssumeServiceLinkedRoleException` | `excluded_accounts` không khớp `recorder_target_ous` | **Lỗi thiết kế** | `4e3a406` |
| 23 | User SSO không đăng nhập được, **không lỗi nào** | `CreateUser` không gửi thư mời — tài liệu nói như thể tự động | Thiếu tài liệu | `161c8e7` |
| 24 | `wire-backends.sh` ghi thiếu một layer, im lặng | `backend_hcl` là output nằm trong state — thêm layer phải apply lại `tf-backend` | **Lỗi thiết kế** | `1b67012` |
| 25 | `InsufficientS3BucketPolicyException` | Organization trail ghi vào **hai** prefix, policy chỉ cho một | **Lỗi code** | `e5281e5` |
| 26 | `Runtime.ImportModuleError: No module named 'cfnresponse'` | Module đó **không có** trong `python3.12` — Lambda chết lúc khởi tạo nên không gửi được phản hồi, CloudFormation treo **một giờ** | **Lỗi code** | `cf66390` |
| 27 | Lệnh kiểm chứng in ra **rỗng** dù output vẫn ở đó | Hai bộ lọc JMESPath liên tiếp tạo projection lồng, `--output text` in ra dòng trống | **Lỗi code** | `6336f81` |
| 28 | `terraform plan` **sạch**, cảnh báo bảo mật không tới ai | Email subscription bị SNS xoá; state vẫn giữ ARN thật nên `plan` không thấy gì | **Lỗi thiết kế** | `76dc5b7`, `bc0dfca` |
| 29 | `Invalid template interpolation value` ×4, ngay ở `enable = false` | `one()` trả `null` khi `count = 0`, và null không nội suy được vào string template | **Lỗi code** | `5debc69` |
| 30 | `\1 not defined in the RE` trên macOS, script chạy tốt trên Linux | `sed -i` của BSD **bắt buộc** có tham số hậu tố, nên `sed -i -E` bị đọc thành *"hậu tố = -E"* — mất chế độ ERE, ngoặc thành ký tự thường | **Lỗi code** | `6e771b6` |
| 31 | Script báo `Xong: 1 file` trong khi **không đổi được gì** | Đếm file đã mở thay vì dòng đã sửa. Trên một script chỉ có mỗi việc gỡ lớp chặn cuối cùng, báo thành công giả nguy hơn lỗi 30 | **Lỗi thiết kế** | `6e771b6` |
| 34 | `lz-server-admin` có `s3:*` **ngay trong account log archive** | 10/17 permission set khai `scope = "all"`, mà `all` suy ra từ Organizations nên gồm cả account giữ bằng chứng. `DenyTamperingWithGuardrails` chặn `cloudtrail:DeleteTrail` nhưng **không** chặn `s3:DeleteObject` | **Lỗi thiết kế** | *(mục 7i)* |
| 33 | Nguồn của đường cảnh báo **nằm ngoài code** | `notify.tf` khớp `source = aws.securityhub`, nhưng không layer nào tạo hay quản Security Hub — nó được bật bằng ba lệnh tay ở RUNBOOK giai đoạn 7. Terraform không biết nó tồn tại, nên không ai được báo nếu nó tắt | **Lỗi thiết kế** | *(mục 7h)* |
| 32 | TEARDOWN.md dặn *"giữ `create_organization = false`"* — làm theo là **xoá cả tổ chức** | Câu đó chỉ đúng khi tổ chức chưa nằm trong state. Đã nằm rồi thì đổi biến làm `count` tụt 1→0 = destroy. Mô tả biến ghi đúng, tài liệu teardown ghi ngược | **Tài liệu sai** | `d6f3d1d` |
| 35 | Mô tả biến `delegated_administrators` **mời** khai `guardduty.amazonaws.com`, trong khi layer khác đã sở hữu việc đó | Danh sách "service principal hay dùng" gộp chung hai nhóm khác hẳn nhau: nhóm chỉ đăng ký được qua Organizations, và nhóm có lệnh chỉ định riêng *(lệnh đó tự đăng ký giúp)*. Khai nhóm hai vào map = hai layer cùng sở hữu một sự thật | **Tài liệu sai** | *(mục 7j)* |

| 36 | Comment trong `securityhub.tf` khẳng định một **điều kiện tiên quyết không tồn tại** | Ghi rằng `EnableOrganizationAdminAccount` đòi Security Hub bật sẵn ở management account. Trạng thái thật bác bỏ: management `InvalidAccessException: not subscribed`, mà `list-organization-admin-accounts` vẫn trả về admin `ENABLED` | **Tài liệu sai** | *(mục 7k)* |

**32/36 là lỗi trong code hoặc thiết kế của repo**, không phải người dùng làm sai. Đó là lý do file này tồn tại.

> Bảy lỗi cuối đến từ **vòng xoá–dựng lại và phần rà lại guardrail** (mục 7), không phải lần dựng đầu. Chúng chỉ lộ ra khi đi ngược chiều — và lỗi 32 là loại đáng sợ nhất: một câu dặn nghe hợp lý, trong tài liệu do chính tôi viết, mà làm theo thì mất tổ chức.

> Lỗi 27 là loại tệ nhất trong cả bảng: nó không báo hỏng. Nó nói *"không có gì"* — và "không có gì" đúng là câu trả lời mình **mong đợi** sau khi đã dọn tay. Suýt nữa thì viết vào tài liệu rằng lớp mới không tìm thấy gì, trong khi nó vừa xoá năm cái VPC thật.

---

## 2. Bảy lỗi đáng học nhất

### 2.1. Một service principal sai làm hỏng cả resource

```
Error: enabling AWS Service Access (reports.billing.amazonaws.com):
InvalidInputException: You specified an unrecognized service principal.
```

`aws_organizations_organization` nhận một **danh sách** service principal. Sai một phần tử là AWS từ chối cả lời gọi — và **không nói cái nào sai**.

Tệ hơn: **organization đã được tạo** trước khi bước bật service access lỗi. Nên lần plan sau ra `AlreadyInOrganizationException`, và resource bị đánh dấu **tainted** (lỗi #9).

Bài học: với resource có danh sách "bật/tắt dịch vụ", giữ danh sách **tối thiểu và đã kiểm chứng**. Nay nó là biến, sửa `terraform.tfvars` chứ không sửa resource:

```bash
aws organizations list-aws-service-access-for-organization
```

### 2.2. Vòng lặp con gà – quả trứng, và cái thứ hai tôi tự tạo ra

Layer `tf-backend` **tạo ra chính cái bucket** nó dùng để cất state. Lần đầu bắt buộc chạy state local.

Ban đầu tôi giải bằng một dòng comment trong `versions.tf`, kèm ghi chú *"bỏ comment ở bước 3"*. Ba thứ hỏng theo:

| | |
|---|---|
| Bỏ comment sớm | `terraform init` hỏi nhập bucket, mọi lệnh sau báo `Backend initialization required` |
| `versions.tf` được git track | Bật backend thành một commit riêng của máy — **branch diverged ngay lần pull đầu** |
| Clone mới | Có sẵn backend đang bật — sai hoàn toàn cho lần chạy đầu |

Sửa gốc: backend chuyển sang **`backend.tf` do script sinh**, gitignore.

```
Khong co backend.tf  ->  Terraform tu dung state local
Chay wire-backends   ->  backend.tf xuat hien  ->  remote state
```

Thứ tự tự đúng, không phải nhớ. **Không còn file track nào phải sửa.**

Nhưng nó đẻ ra vòng lặp thứ hai: script cần **đọc state** để biết tên bucket, mà đọc state lại **cần `backend.tf`**. Mất `backend.tf` (nó gitignore nên `git reset --hard` quét phải) là không có đường quay lại.

Gỡ bằng cách nhận diện đúng hình dạng — *không có `backend.tf`, còn `backend.hcl`, state đọc không được* — rồi dựng lại từ `backend.hcl`, file sống sót qua cùng những thao tác đó.

> **Bài học chung:** mỗi lần "giải quyết" một phụ thuộc vòng bằng cách dời nó đi, kiểm tra xem có tạo ra vòng mới không.

### 2.3. Thông báo lỗi đoán mò tệ hơn không có thông báo

Script cũ:

```bash
if ! configs=$(terraform output -json backend_hcl 2>/dev/null); then
  red "Khong doc duoc output backend_hcl. Da apply chua?"
```

`2>/dev/null` vứt đi thứ duy nhất hữu ích — Terraform nói gì. Ba tình huống rất khác nhau (state rỗng / apply dở dang / backend chưa init) đều ra **một câu đoán mò**.

Sửa: tách ba nhánh, và **in nguyên văn** Terraform nói gì.

```bash
if ! state_out=$(terraform state list 2>&1); then
  if echo "$state_out" | grep -q "Backend initialization required"; then
    # tinh huong cu the -> huong dan cu the
```

### 2.4. `create_organization` — tên biến nói dối

Bảng preflight ghi: *`describe-organization` ra kết quả → đặt `false`*. Đúng cho **lần chạy đầu**.

Nhưng sau khi Terraform đã tạo org, đổi về `false` nghĩa là `count` 1 → 0 → **Terraform lên kế hoạch xoá organization**, kéo theo mọi account con ra khỏi tổ chức.

`prevent_destroy` chặn được — đúng lúc, đúng việc. Nhưng thông báo `Instance cannot be destroyed` đọc như lỗi, không như lưới an toàn.

Tên biến sai ngay từ đầu: nó không phải *"có tạo mới không"* mà là **"Terraform có quản lý resource này không"** — và một khi đã `true` thì phải giữ `true`.

> Muốn thật sự chuyển sang chỉ đọc thì gỡ khỏi state trước, **không** đổi biến:
> ```bash
> terraform state rm 'aws_organizations_organization.this[0]'
> ```

### 2.5. Viết cảnh báo về cái bẫy rồi vẫn ngã vào nó

Giai đoạn 5, lệnh đầu tiên ở layer `permission-sets` đã dừng:

```
Error: Inconsistent conditional result types
  The 'true' tuple has length 2, but the 'false' tuple has length 0.
```

Đoạn gây lỗi:

```hcl
deny_create_without_boundary = var.enforce_security_admin_boundary ? [
  { Sid = "...", Action = [...], Resource = "*", Condition = { ... } },   # CO Condition
  { Sid = "...", Action = [...], Resource = "arn:...:policy/lz-boundary" } # KHONG co Condition
] : []
```

Terraform kiểm kiểu **cả hai nhánh**, kể cả khi biến là `false` — nên lỗi xuất hiện bất kể cấu hình. Layer này chưa từng `plan` được lần nào.

Cơ chế: hai object có bộ thuộc tính khác nhau (một có `Condition`, một không) nên không quy được về `list(object)` chung. Kết quả giữ nguyên kiểu **tuple**. Tuple độ dài 2 và tuple độ dài 0 là hai kiểu khác nhau, không thống nhất được — trong khi `list(X)` độ dài 2 và độ dài 0 thì thống nhất bình thường.

> Đây chính là hạn chế mà comment đầu `permission-sets.tf` đã mô tả và đã có cách vòng tránh — `jsonencode` từng statement thành **chuỗi**, rồi ghép `list(string)`. Cách vòng tránh được áp dụng đúng ở file này, nhưng file `locals-policies.tf` bên cạnh vẫn còn một chỗ dùng list object thô.

Thứ khiến nó sống sót lâu: **hai công tắc cho một việc**. `local.guard_bound` trong `permission-sets.tf` đã quyết định có dùng hai statement này hay không; điều kiện trong `locals-policies.tf` là thừa. Cách chữa là bỏ cái thừa — tách thành hai local riêng, không điều kiện, không đánh chỉ số list:

```hcl
deny_create_without_boundary = { Sid = "DenyCreatePrincipalWithoutBoundary", ... }
deny_boundary_tampering      = { Sid = "DenyRemovingOrEditingTheBoundaryItself", ... }
```

**Lỗi thứ hai lộ ra ngay sau đó.** `validate-policies.sh` đáng lẽ phải bắt được chuyện này từ lâu, nhưng nó im lặng:

```bash
sets=$(terraform console <<<'keys(local.permission_sets)' | tr -d '[]",' | tr ' ' '\n' | sed '/^$/d')
```

Mã thoát của một pipeline là mã thoát của **lệnh cuối** — tức `sed`, luôn bằng 0. `set -e` không bao giờ nổ, lỗi của Terraform chỉ hiện trên stderr rồi script in tiếp một bảng rỗng và thoát 0. Một script kiểm tra báo "đạt" khi không kiểm được gì thì tệ hơn là không có script.

Bản viết lại gọi `terraform console` **một lần** (thay vì ~100 lần, mỗi statement một lần), bắt stderr ra file, và kiểm tra mã thoát tường minh. Thêm hai chi tiết cụ thể của `terraform console` phi tương tác, phải thoả **đồng thời**:

| Ràng buộc | Vi phạm thì báo |
|---|---|
| Đánh giá **từng dòng** — không nhận biểu thức nhiều dòng | `Missing expression` |
| HCL cần newline **hoặc dấu phẩy** giữa các thuộc tính object | `Missing attribute separator` |

Ép biểu thức về một dòng thoả điều 1 thì vi phạm điều 2. Nên phải viết nhiều dòng *có dấu phẩy sau mỗi thuộc tính*, rồi `tr '\n' ' '`.

Kiểm chứng bản mới bằng một **test âm** — nhân đôi một mảnh statement để tạo `Sid` trùng:

```
lz-billing    1331    3    TRUNG Sid
CO LOI - khong apply.        EXIT=1
```

Bắt đúng và thoát khác 0. Bài học: mỗi lưới an toàn phải được thử bằng một trường hợp *chắc chắn sai*, nếu không thì không biết nó có còn hoạt động hay không.

### 2.6. Hai cấu hình mà không giá trị nào làm cho đúng được

`billing-guard` hỏng hai lần liên tiếp, và cả hai đều cùng một dạng: code yêu cầu một thứ **AWS không bao giờ chấp nhận**, bất kể điền gì vào biến.

**Lần một** — mỗi account chỉ được **một** dimensional anomaly monitor, và AWS thường đã tự tạo sẵn một cái tên "Services" khi Cost Explorer được bật:

```
ValidationException: Limit exceeded on dimensional spend monitor creation
```

Code vô điều kiện xin cái thứ hai. Cách chữa là **mượn thay vì tạo** — thêm `service_anomaly_monitor_arn`, để rỗng thì tạo mới, điền ARN thì bỏ qua bước tạo và gắn thẳng subscription vào cái sẵn có.

Vì sao không `terraform import`? Import cũng chạy được, nhưng nó trao cho Terraform quyền sở hữu một thứ Terraform không tạo ra — ngày `destroy` layer này thì monitor mặc định của account bị xoá theo. Ranh giới đúng: Terraform quản lý subscription, còn monitor thì mượn.

**Lần hai** — `frequency` và `subscriber.type` không độc lập với nhau:

```
ValidationException: Daily or weekly frequencies only support Email subscriptions
```

| `frequency` | Subscriber nhận được |
|---|---|
| `DAILY` / `WEEKLY` | **chỉ** `EMAIL` |
| `IMMEDIATE` | `SNS` (và `EMAIL`) |

Code ghép `DAILY` với `SNS`. Cách chữa **không phải** đổi thành `IMMEDIATE` rồi thôi — hai trường ràng buộc nhau nhưng nằm cách nhau mấy dòng, để nguyên thì lần sau lại ghép sai. Thay bằng một biến đặt cả hai:

```hcl
anomaly_alert_mode = "sns_immediate"   # IMMEDIATE + SNS
anomaly_alert_mode = "email_daily"     # DAILY + EMAIL
```

Và đây là khác biệt thật, không chỉ cú pháp: ở chế độ `email_daily`, Cost Explorer gửi **thẳng** tới từng địa chỉ, **không qua SNS topic**. Muốn đẩy cảnh báo bất thường sang Slack sau này thì phải làm lại từ đầu. `sns_immediate` giữ mọi cảnh báo chi phí đi chung một cửa.

> **Dạng lỗi này đáng nhận ra:** khi hai trường của cùng một resource ràng buộc lẫn nhau, để chúng là hai biến riêng nghĩa là mời người dùng ghép sai. Gộp thành một biến với danh sách giá trị hợp lệ thì tổ hợp sai không tồn tại.

**Và điều cả hai lỗi này nói về repo:** không lỗi nào bị `terraform validate` bắt được — cú pháp đúng, kiểu đúng, tham chiếu đúng. Chỉ AWS mới biết. Nghĩa là **layer nào chưa apply thật thì chưa tin được**, và đó là thông tin nên có khi đọc repo này:

| Layer | Đã chạy thật |
|---|---|
| `tf-backend`, `organization`, `permission-sets`, `billing-guard` | ✔ |
| `config-detective`, `control-tower` | ✘ — và `config-detective` là layer duy nhất tốn tiền |

---

## 3. Ba lưới an toàn đã cứu bài

Những thứ này chặn đúng lúc — đáng giữ lại trong mọi thiết kế sau:

| Lưới | Chặn gì |
|---|---|
| `prevent_destroy` trên organization | Kế hoạch xoá org (2 lần) |
| `scp_dry_run = true` mặc định | SCP gắn nhầm trước khi kịp đọc nội dung |
| Kiểm tra **"phải chạy được"** cạnh "phải bị chặn" | Siết quá tay — lỗi im lặng nhất |

Cái thứ ba đáng nói riêng. Ba lệnh kiểm chứng SCP đầu tiên đều là *"phải bị từ chối"*. Nếu chỉ có chúng thì một SCP chặn **quá tay** vẫn "pass" hết. Nên phải luôn có ít nhất một lệnh *"phải chạy được"*:

```bash
aws ec2 describe-vpcs --region ap-southeast-1 --profile lz-network   # PHAI THANH CONG
```

---

## 4. Phát hiện không phải lỗi: default VPC

Lệnh kiểm chứng "phải chạy được" lộ ra thứ đáng chú ý:

```json
"VpcId": "vpc-0f37e24fbed5a5b38",
"CidrBlock": "172.31.0.0/16",
"IsDefault": true
```

AWS tạo **default VPC ở mọi region** cho mọi account mới, và nó **có sẵn Internet Gateway**.

Đây đúng là thứ phá vỡ thiết kế *"không account nào ra Internet trực tiếp"* ở [doc 13](./13-Centralized-Ingress-Egress-Network.md): SCP chặn **tạo mới** IGW, nhưng cái có sẵn từ lúc account ra đời thì không.

Phải xoá cho **mọi region** trong `allowed_regions`, và lặp lại cho **mọi account mới**:

```bash
REGION=ap-southeast-1; PROFILE=lz-network; VPC=vpc-xxxx

for s in $(aws ec2 describe-subnets --region $REGION --profile $PROFILE \
    --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id $s --region $REGION --profile $PROFILE
done

IGW=$(aws ec2 describe-internet-gateways --region $REGION --profile $PROFILE \
  --filters Name=attachment.vpc-id,Values=$VPC \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC --region $REGION --profile $PROFILE
aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $REGION --profile $PROFILE

aws ec2 delete-vpc --vpc-id $VPC --region $REGION --profile $PROFILE
```

Đây chính là việc [doc 09](./09-Account-Vending-Tu-Dong.md) gọi là **account baseline** và giao cho StackSet làm tự động. Layer đó **chưa có code** — nên tạm thời làm tay, và nó là ứng viên số một cho lần bổ sung tiếp theo.

> **Đính chính, viết sau khi lớp tự động chạy (mục 6d).** Đoạn trên nói "phải xoá cho **mọi** region". Thực tế lần dọn tay chỉ chạy ở `ap-southeast-1` — cái region đang mở terminal. `us-east-1` **cũng nằm trong `allowed_regions`** mà không ai đụng tới, và cả **năm** account thành viên vẫn còn nguyên default VPC ở đó, kèm Internet Gateway, cho tới khi `account-baseline` xoá chúng.
>
> Câu "đã xoá ở mọi region" được viết ra vì vòng lặp bash lúc đó chỉ có một region trong biến. Không lệnh nào báo sai — nó làm đúng cái được bảo làm.

---

## 5. Kiểm chứng cuối

Ba lệnh, chạy từ account con đầu tiên:

```bash
aws ec2 describe-vpcs --region eu-west-1 --profile lz-network
# UnauthorizedOperation ... explicit deny in a service control policy: p-93vo2yro   <- region_lock

aws ec2 describe-vpcs --region ap-southeast-1 --profile lz-network
# tra ve VPC  <- dung, khong siet qua tay

aws iam create-user --user-name test --profile lz-network
# AccessDenied ... explicit deny in a service control policy: p-2oni53yp   <- baseline
```

Thông báo lỗi của AWS **chỉ đích danh policy ID** — rất hữu ích khi có nhiều SCP chồng nhau. Ghi lại ID lúc `terraform output scp_summary` để đối chiếu.

### 5b. Giai đoạn 5 — permission-sets

Apply sạch sau khi sửa lỗi #10 và #11: **115 resource**.

| Resource | Số lượng |
|---|---|
| `aws_ssoadmin_permission_set` | 17 |
| `aws_ssoadmin_permission_set_inline_policy` | 16 |
| `aws_ssoadmin_managed_policy_attachment` | 12 |
| `aws_identitystore_group` | 15 |
| `aws_identitystore_user` + membership | 2 |
| `aws_ssoadmin_account_assignment` | **53** |

`lz-account-admin` không có inline policy — chỉ dùng `AdministratorAccess` managed. Đó là lý do 16 chứ không phải 17.

**53 assignment tính ra sao**, với 5 account trong phạm vi `all` (6 ACTIVE trừ management):

| Nhóm | Assignment |
|---|---|
| 10 group phạm vi `all` × 5 account | 50 |
| `lz-app-teams`: `lz-app-admin` (1 nonprod) + `lz-app-operator` (1 prod) | 2 |
| `lz-billing-team` → management | 1 |
| 3 group analytics/datalake — chưa có account | 0 |

Mỗi assignment làm Identity Center tự tạo một IAM role `AWSReservedSSO_<set>_<hash>` trong account đích. 53 assignment = 53 role.

> **Tính trước con số rồi mới apply.** Plan ra đúng 115 nghĩa là phần locals, ma trận group và phạm vi account đều khớp nhau. Ra khác 115 thì có gì đó lệch — và lúc đó dễ tìm hơn nhiều so với sau khi apply.

**Cảnh báo đúng, không phải lỗi:**

```
Warning: Cac pham vi sau dang RONG nen khong sinh assignment nao: analytics
```

Chưa có account Data Analytics. Ba group `lz-analytics-*` và `lz-datalake-admins` vẫn được tạo nhưng chưa gán đi đâu. `check` block chỉ cảnh báo, không chặn apply — cố ý.

**Ba việc Terraform không làm được**, phải vào console:

| Việc | Không làm thì sao |
|---|---|
| Billing → *IAM user and role access to Billing information* → Activate | `lz-billing` bị `AccessDenied` dù policy đúng hoàn toàn |
| Identity Center → Settings → Authentication → *Require MFA every time* | Không có MFA |
| Bật Identity Center lần đầu | Data source trả list rỗng, apply lỗi ở `tolist(...)[0]` |

Việc đầu là thứ khó đoán nhất: policy đúng, permission set đúng, assignment đúng, vẫn `AccessDenied`.

> **Đừng** đặt điều kiện `aws:MultiFactorAuthPresent` trong policy của permission set để thay cho việc bật MFA ở console. Phiên Identity Center không mang claim đó một cách đáng tin, thêm vào chỉ sinh `AccessDenied` khó hiểu.

**Một mâu thuẫn thiết kế lộ ra khi đọc `assignment_matrix`:** `lz-db-admin` và `lz-server-admin` có phạm vi `all`, tức có quyền ghi ở cả `lz-app-prod` — trong khi `lz-app-admin` cố ý chỉ có nonprod với lý do *"không người nào ghi được lên prod application"*. `dynamodb:Scan` trong `lz-db-admin` còn đọc được toàn bộ dữ liệu production.

Với lab thì chấp nhận được. Với môi trường thật thì phải chọn: hoặc hạ hai set đó xuống `nonprod` và thêm breakglass tương ứng, hoặc thừa nhận câu "không ai ghi được lên prod" chỉ đúng với tầng application. Xem [doc 19 mục 4.3](./19-Permission-Set-cho-Landing-Zone.md).

### 5c. Ba lần hỏng một phép thử SCP

Mục 3 nói *phải luôn có một lệnh "phải chạy được" bên cạnh các lệnh "phải bị chặn"*. Đúng, nhưng chưa đủ. Kiểm chứng `prod_guard` hỏng **ba lần liên tiếp**, mỗi lần một lý do khác, và cả ba lần đều "ra lỗi" trông rất thuyết phục.

Ý tưởng ban đầu vẫn đúng: chạy cùng một lệnh ở hai account chỉ khác nhau ở OU. Prod bị SCP chặn, dev thì không. Không cần tạo tài nguyên gì vì **SCP được đánh giá trước khi AWS kiểm tra tài nguyên có tồn tại** — nên `NotFound` ở dev chính là bằng chứng request đã đi lọt qua tầng SCP.

Cái sai nằm ở việc chọn lệnh.

| Lần | Lệnh | Kết quả | Vì sao vô nghĩa |
|---|---|---|---|
| 1 | `kms schedule-key-deletion --key-id alias/aws/ebs` | `InvalidArnException` | KMS từ chối alias trước khi tới phân quyền; AWS-managed key vốn không xoá được |
| 2 | `ec2 delete-snapshot --snapshot-id snap-00000000000000000` | `InvalidSnapshotID.Malformed` ở **cả hai** | ID toàn số 0 không qua kiểm tra định dạng |
| 3 | `backup delete-backup-vault --backup-vault-name khong-ton-tai-test` | `AccessDeniedException` ở **cả hai**, dù principal là `OrganizationAccountAccessRole` | AWS Backup trả `AccessDenied` cho vault **không tồn tại** thay vì `ResourceNotFoundException` — nó không tiết lộ tài nguyên có tồn tại hay không. Thông báo cũng không nêu tên policy |

Rút ra ba điều kiện, thiếu cái nào cũng hỏng:

| # | Điều kiện | Vi phạm thì |
|---|---|---|
| 1 | Tham số **hợp lệ về định dạng** | Request dừng ở tầng kiểm tham số, không bao giờ chạm tới phân quyền |
| 2 | Principal **vốn được phép** nếu không có SCP | Đang đo identity policy của chính mình, không đo SCP |
| 3 | Service **phân biệt được** "không có quyền" với "không tồn tại", và **nêu tên policy** | Không phân biệt được deny đến từ SCP hay từ đâu khác |

Điều kiện 3 là cái tinh vi nhất, và là cái đã lừa được lần thứ ba. Ai cũng ngầm giả định rằng gọi API lên một tài nguyên không tồn tại thì sẽ ra `NotFound`. **AWS Backup thì không**: nó trả `AccessDenied` cho vault không tồn tại, cố ý không tiết lộ tài nguyên có tồn tại hay không. Cả hai account ra cùng một câu, dù ở dev chẳng có SCP nào chặn `backup:` — chỉ `prod_guard` nhắc tới nó trong toàn bộ 4 SCP.

Điều kiện 2 thì chưa vấp lần nào, nhưng vẫn phải nhớ: ba phép thử ở mục 5 chạy đúng một phần **nhờ hoàn cảnh** — lúc đó chưa có Identity Center nên buộc phải dùng `OrganizationAccountAccessRole`. Sau giai đoạn 5, nếu đăng nhập bằng permission set hẹp thì cùng một lệnh sẽ cho cùng một lỗi ở mọi account và chẳng chứng minh gì. Chạy `aws sts get-caller-identity` trước để biết mình đang là ai.

> **Dấu hiệu nhận biết, kiểm trước tiên:** hai account cho ra **cùng một** thông báo lỗi. Cặp lệnh chỉ khác nhau ở OU — kết quả giống nhau nghĩa là chưa cái nào chạm tới SCP. Dấu hiệu này bắt được cả ba lần hỏng, kể cả lần đầu nếu lúc đó tôi chạy đủ cả cặp.

Nêu tên policy trong lỗi và phân biệt `NotFound` với `AccessDenied`: EC2, IAM, S3. Không phân biệt: AWS Backup, và nhiều service mới hơn cũng theo hướng không tiết lộ sự tồn tại. Ưu tiên nhóm đầu.

Lệnh cuối cùng dùng được:

```bash
aws sts get-caller-identity --profile <prod>    # xac nhan la admin TRUOC da

aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0 --profile <prod>
# AccessDenied ... explicit deny in a service control policy: p-xxxx

aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0 --profile <dev>
# InvalidSnapshot.NotFound
```

**Bài học rộng hơn cả SCP:** một phép kiểm chứng bảo mật báo "đạt" vì lý do sai thì nguy hiểm hơn không kiểm gì — nó tạo niềm tin không có cơ sở. Mọi phép thử "phải bị chặn" cần một cách phân biệt *bị chặn đúng chỗ mình nghĩ* với *bị chặn ở đâu đó khác*.

### 5d. Cùng một `tainted`, hai cách xử lý ngược nhau

Taint xuất hiện hai lần trong buổi, và cách đúng lần sau **ngược hẳn** lần trước.

| | Lỗi #9 — organization | Giai đoạn 7 — 8 org config rule |
|---|---|---|
| Vì sao tainted | Bật service access lỗi *sau khi* org đã tạo xong | `create` gọi được, waiter hết 5 phút |
| Ở AWS thì sao | **Lành lặn** — org đủ dùng | **Hỏng dở** — kẹt `CREATE_IN_PROGRESS` vì chưa account nào có recorder |
| Cách đúng | `terraform untaint` | **Cứ để thay thế** |
| Untaint sai ở đâu | — | Chỉ giấu vấn đề: rule vẫn kẹt, và không bao giờ tự thoát |

Câu hỏi phải trả lời trước khi gõ lệnh không phải *"làm sao hết tainted"* mà là:

> **Resource đó ở phía AWS đang lành hay đang hỏng dở?**

`untaint` chỉ nói với Terraform *"tôi đã kiểm, nó ổn"*. Nếu chưa kiểm thì đó là nói dối, và cái giá là một resource hỏng nằm im trong state — Terraform không bao giờ đụng lại nữa vì nó tin bạn.

Cách kiểm: hỏi thẳng AWS, đừng hỏi Terraform.

```bash
aws organizations describe-organization                          # loi #9
aws configservice describe-organization-config-rule-statuses \
  --profile <security> --region <region>                         # giai doan 7
```

Với 8 rule kia, để Terraform thay thế lại là điều **mong muốn**: kèm `depends_on` mới, nó xoá rule đang kẹt, dựng recorder qua StackSet, rồi tạo lại rule khi đã có dữ liệu để đọc — đúng thứ tự lẽ ra phải có ngay từ đầu.

### 5e. Giai đoạn 7 — sáu lớp lỗi chồng lên một nguyên nhân

`config-detective` là layer khó nhất trong repo, và lý do không phải vì nó phức tạp. Nguyên nhân gốc bị **sáu lớp khác che**, và mỗi lớp báo lỗi trỏ sai hướng.

Nguyên nhân gốc, phát hiện ở lần apply đầu tiên:

```
NoAvailableDeliveryChannelException: Delivery channel is not available
to start configuration recorder
```

Nhưng phải gỡ hết năm lớp khác mới quay lại được chỗ đó.

| Lớp | Lỗi | Trỏ vào đâu | Thực ra là gì |
|---|---|---|---|
| 1 | `You must enable organizations access` | Organizations | CloudFormation có lời gọi kích hoạt riêng |
| 2 | `InsufficientDeliveryPolicyException` | Bucket policy | Sai condition key: `SourceOrgID` thay vì `SourceAccount` |
| 3 | `InsufficientDeliveryPolicyException` *(vẫn)* | Bucket policy | **Object Lock** — policy hoàn toàn đúng |
| 4 | `explicit deny ... p-2oni53yp` | SCP chặn kẻ xấu | SCP chặn chính CloudFormation rollback |
| 5 | `MaxNumberOfDeliveryChannelsExceededException` | Giới hạn AWS | Rác từ chính phép thử chẩn đoán |
| 6 | `NotStabilized` / `NoAvailableDeliveryChannel` | Thứ tự template | Vòng lặp thật giữa hai API |

**Lớp 3 tốn nhiều thời gian nhất**, vì tên exception nói dối. `InsufficientDeliveryPolicyException` dẫn thẳng tới bucket policy, và bucket policy không hề sai. Chỉ khi dựng hai bucket giống hệt nhau — cùng policy, cùng `BucketOwnerEnforced`, cùng account nguồn, khác **duy nhất** Object Lock — mới thấy: bucket không khoá thì Config ghi được `ConfigWritabilityCheckFile` ngay, bucket khoá thì không.

#### Vòng lặp không giải được bằng thứ tự

Lớp 6 là cái đáng học nhất về kỹ thuật. AWS CLI làm ba bước:

```
put-configuration-recorder  ->  put-delivery-channel  ->  start-configuration-recorder
```

CloudFormation gộp bước 1 và 3 vào `AWS::Config::ConfigurationRecorder`. Kết quả là hai API đòi nhau:

```
PutDeliveryChannel   -> NoAvailableConfigurationRecorderException
Start (CFN tu goi)   -> NoAvailableDeliveryChannelException
```

Cả hai chiều `DependsOn` đều chết. Đã thử cả hai.

Lời giải là **bỏ hẳn `DependsOn` giữa chúng** — để cả hai chỉ phụ thuộc `ConfigRole` và chạy song song:

```
recorder Put -> Start hong -> cho, thu lai
                                ^
channel Put thanh cong (recorder da ton tai) -> Start dat
```

Handler của recorder thử lại bước start trong lúc chờ ổn định, và đến lượt thử sau thì delivery channel đã có. Delivery channel chỉ cần recorder **tồn tại**, không cần nó **đang chạy**.

> Đó là lý do template mẫu của AWS không đặt `DependsOn` giữa hai resource này — nhìn như sơ suất cho tới khi vấp phải.

Kết quả cuối: 4/4 account `CURRENT`, 4/4 recorder `recording: true`, `lastStatus: SUCCESS`.

#### Phép thử sai vì tôi đọc nhầm một lỗi trước đó

Giữa chừng tôi kết luận "không có vòng lặp" dựa trên việc `put-delivery-channel` chạy được trong `lz-network`. Sai: `lz-network` **vẫn còn recorder** — lệnh xoá recorder trước đó đã bị SCP từ chối, mà tôi đọc như thể nó thành công.

Phép thử chỉ chứng minh "tạo được delivery channel khi *đã có* recorder" — đúng điều kiện mà account cần thử không thoả. Chạy lại trong `lz-logarchive`, account chưa từng có recorder, thì ra ngay `NoAvailableConfigurationRecorderException`.

> **Bài học:** một phép thử chỉ có giá trị khi điều kiện đầu vào đã được **xác nhận**, không phải giả định. Ở đây điều kiện là "account không có recorder", và nó sai vì một lệnh trước đó thất bại lặng lẽ.

#### SCP chặn nhầm công cụ của chính mình

Lớp 4 đáng ghi riêng. `baseline` chặn `config:DeleteConfigurationRecorder` — đúng ý đồ. Nhưng CloudFormation rollback cũng gọi đúng API đó, nên mọi lần triển khai hỏng để lại một stack `DELETE_FAILED` không ai dọn được.

**SCP chặn hành động, không phân biệt được ý định.** "Xoá recorder" khi kẻ tấn công làm và khi rollback làm là cùng một lời gọi API; chỉ danh tính người gọi mới phân biệt được. Nên mọi SCP bảo vệ hạ tầng đều cần một đường miễn trừ cho chính công cụ quản lý hạ tầng — và đường đó thành thứ phải canh giữ.

Role cần miễn trừ là `stacksets-exec-*`, **không** phải `AWSServiceRoleForCloudFormationStackSetsOrgMember` (cái sau là service-linked role phía quản trị). Tên thật luôn nằm trong `StatusReason` của stack instance, ở dòng `assumed-role/<ten>/...`.

#### Ba lần timeout, ba con số

| Resource | Mặc định | Thực tế | Đặt lại |
|---|---|---|---|
| `aws_config_organization_managed_rule` | 5 phút | > 30 phút | 90 phút |
| `aws_cloudformation_stack_set_instance` | 30 phút | ~29 phút với 4 account | 90 phút |

Với 6 account và 8 rule, cả 8 rule chạm mốc 30 phút **cùng lúc** — AWS triển khai từng rule xuống từng account, và 8 rule chạy song song nên chúng cùng chậm như nhau.

Vượt timeout **không phải thất bại** — AWS vẫn chạy tiếp. Nhưng Terraform đánh dấu tainted, và lần apply sau đòi thay thế một thứ đang hoạt động bình thường.

#### Cần gạt chi phí và phạm vi rule là hai biến ở hai file

Lỗi cuối cùng của giai đoạn, và là hệ quả trực tiếp của một quyết định **đúng**.

`recorder_target_ous` cố ý bỏ `Non-Production` — cần gạt chi phí số hai, vì dev là nơi resource đổi nhiều nhất. Nhưng organization rule đẩy xuống **mọi account thành viên, kể cả management**, bất kể biến đó:

| Account | Lỗi |
|---|---|
| `lz-app-dev` — ngoài `recorder_target_ous` | `NoAvailableConfigurationRecorder` |
| management — chưa từng bật Config | `UnableToAssumeServiceLinkedRoleException` |

Hai biến ràng buộc nhau mà không có gì trong code nối lại:

```hcl
recorder_target_ous = [...]   # account nao CO recorder
excluded_accounts   = []      # account nao KHONG bi ap rule
```

Và nó hỏng **chậm**: rule ngồi `CREATE_IN_PROGRESS` hàng chục phút rồi mới thành `CREATE_FAILED`, kéo cả lần apply theo — rồi lại không xoá được vì còn đang tạo.

Nay có `check` block bắt trường hợp management account (layer chạy ở đó nên `data.aws_caller_identity` biết ID). Các account khác không suy ra được nếu không phụ thuộc dữ liệu OU, nên thành quy tắc trong mô tả biến:

> Mọi account ACTIVE không nằm trong `recorder_target_ous` **phải** có mặt trong `excluded_accounts`. Luôn bao gồm management account.

**Kết quả cuối giai đoạn 7:** 26 resource, 4/4 recorder đang ghi, aggregator gom 2 region, 8 organization rule áp cho 4 account.

---

## 6. Sổ tay rút gọn

Nếu chỉ đọc một mục của file này, đọc mục này.

| Triệu chứng | Làm gì |
|---|---|
| `unrecognized service principal` | Rút `aws_service_access_principals` về tối thiểu, apply, thêm dần |
| `Backend initialization required` | Có `backend.tf` mà layer chưa apply → `rm backend.tf`, `init -reconfigure`, apply |
| `Unsetting the previously set backend` | Mất `backend.tf` → chạy `./wire-backends.sh`, nó tự dựng lại |
| `-backend-config was used without a "backend" block` | Như trên |
| `is tainted, so must be replaced` | **Hỏi trước: resource đó ở AWS lành hay hỏng dở?** Lành → `terraform untaint '<address>'`. Hỏng dở → cứ để thay thế. Xem mục 5d |
| `Instance cannot be destroyed` (không có "tainted") | `create_organization` bị đổi về `false` → đặt lại `true` |
| Plan ra số resource **ít bất thường** | Thường là taint: thứ phụ thuộc nó thành *known after apply* nên rơi khỏi plan |
| SCP apply xong không thấy tác dụng | `scp_dry_run = true` — đúng thiết kế |
| Phép thử SCP ra **cùng lỗi ở cả hai** account | Phép thử hỏng, không phải SCP hỏng — xem mục 5c |
| `AccessDenied` mà không nêu tên policy | Có thể là identity policy chứ không phải SCP. Thử lại bằng principal admin |
| Branch diverged sau `git pull` | Đã commit file môi trường? Nay không cần sửa file track nào nữa |

---

## 6b. Sau 24 giờ — số đo thật, và lỗ hổng đầu tiên bị bắt

Ba con số thay cho ba ước tính đã nằm trong file này từ đầu.

### Chi phí: thấp hơn ước tính một bậc

| Ngày | AWS Config |
|---|---|
| 20/8 — chưa bật | $0 |
| 21/8 — ngày dựng | **$0.292** |
| 22/8 — ổn định | $0 |

$0.292 là chi phí **một lần**: recorder khởi động và ghi một configuration item cho mọi resource đang tồn tại thuộc 13 loại, ở 4 account. Sau đó chỉ ghi khi có **thay đổi**.

Ước tính ban đầu là $2–10/tháng, và nó **sai một bậc**. Lý do: tôi tính theo *số resource* mà quên rằng `DAILY` chỉ phát sinh chi phí khi có thay đổi. Lab tĩnh thì gần như không có gì đổi.

> Con số này sẽ khác hẳn khi có workload thật — mỗi lần deploy sinh một loạt configuration item. Nhưng mức nền thì nay đã đo được, không còn phải đoán.

### Giao file: 4/4 SUCCESS

Cả bốn account `lastStatus: SUCCESS`, đã lên lịch lần giao kế tiếp. Đường ống recorder → delivery channel → S3 ở account log archive hoạt động đầy đủ.

### Một báo động sai của tôi, và trường đã giải thích nó

Danh sách S3 có `ConfigHistory` cho `AWS::Athena::WorkGroup`, `AWS::Cassandra::Keyspace`, `AWS::IoT::DomainConfiguration`, `AWS::Scheduler::ScheduleGroup` — **không loại nào nằm trong 13 loại đã khai**. Tôi kết luận ngay là cần gạt chi phí số bốn không hoạt động.

Sai. `describe-configuration-recorders` cho thấy cấu hình hoàn toàn đúng:

```json
"allSupported": false,
"recordingStrategy": { "useOnly": "INCLUSION_BY_RESOURCE_TYPES" },
"resourceTypes": [ ...dung 13 loai... ],
"recordingScope": "PAID"
```

Trường quyết định là **`recordingScope: PAID`**. AWS Config ghi một nhóm loại resource **miễn phí**, ngoài phạm vi tính tiền, bất kể `resourceTypes` khai gì. Chúng chiếm chỗ trong S3 nhưng không tính vào hoá đơn.

> Lại đúng cái lỗi suy luận của mục 5e: nhìn triệu chứng rồi kết luận, thay vì đọc cấu hình thật. Danh sách file trong S3 **không phải** nguồn đáng tin để suy ra phạm vi ghi — `describe-configuration-recorders` mới là.

### Lỗ hổng đầu tiên bị bắt: không có CloudTrail nào

| Rule | Kết quả |
|---|---|
| `iam-root-access-key-check` | COMPLIANT × 4 |
| **`cloud-trail-enabled`** | **NON_COMPLIANT × 4** |
| `s3-bucket-*` | COMPLIANT, chỉ ở account có bucket |

Đây không phải lỗi Config. Toàn bộ repo **không có một resource `aws_cloudtrail` nào**, trong khi:

- `baseline` SCP chặn `cloudtrail:StopLogging`, `DeleteTrail`, `UpdateTrail` — bảo vệ một thứ không tồn tại
- `aws_service_access_principals` đã bật `cloudtrail.amazonaws.com` cho org trail
- `lz-auditor` và `lz-security-operator` được cấp quyền đọc CloudTrail

Ba tầng chuẩn bị cho CloudTrail, không tầng nào tạo ra nó. **Không tài liệu thiết kế nào bắt được điều này** — phải có lớp phát hiện chạy thật mới lộ ra, và nó lộ ra trong ngày đầu tiên.

Đó chính là lý do lớp phát hiện tồn tại: SCP nói *ai được làm gì*, Config nói *thực tế đang thế nào*, và hai câu đó lệch nhau nhiều hơn người ta tưởng.

### Bốn rule vắng mặt — và vì sao đó không phải "đạt"

`encrypted-volumes`, `rds-storage-encrypted`, `vpc-sg-open-only-to-authorized-ports` và các rule S3 ở 3 account không xuất hiện trong bảng. Không có resource nào thuộc loại đó để đánh giá — không EBS, không RDS, và không security group vì default VPC đã bị xoá hết.

> **Vắng mặt ≠ tuân thủ.** Nó nghĩa là "không có gì để kiểm". Khi dựng workload thật, các rule đó sẽ hiện ra và có thể mang màu khác.

---

## 6c. Vòng khép kín — thứ đáng giá nhất của cả dự án

Lỗ hổng CloudTrail ở mục 6b được vá bằng layer [`org-trail`](../landing-zone/org-trail/). Điều đáng ghi không phải bản vá, mà là **cách nó được xác nhận**.

```
config-detective  →  "cloud-trail-enabled NON_COMPLIANT o 4 account"
                         │
                     dung org-trail
                         │
config-detective  →  "COMPLIANT o 4 account"
```

Không ai khẳng định trail chạy. Một hệ thống **độc lập**, dựng từ trước và không biết gì về layer mới, tự phát hiện chỗ thiếu rồi tự xác nhận chỗ vá.

Đó là khác biệt giữa *"tôi đã cấu hình đúng"* và *"có bằng chứng nó đúng"* — và cả hai mươi chín lỗi trong file này đều xoay quanh khoảng cách đó.

### Rule định kỳ không phản ứng với thay đổi

Sau khi trail chạy, aggregator vẫn báo `NON_COMPLIANT` ở cả 4 account. Không phải sai — chỉ là kết quả **cũ**.

| Loại rule | Đánh giá lại khi |
|---|---|
| Configuration change | Resource thay đổi — vài phút |
| **Periodic** | Theo lịch, mặc định **24 giờ** |

`CLOUD_TRAIL_ENABLED` thuộc loại thứ hai. Bạn vá xong, Config vẫn báo sai suốt cả ngày, và rất dễ tưởng bản vá không có tác dụng.

Ép chạy ngay, trong **account thành viên**:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names OrgConfigRule-<ten-rule>-<hash> \
  --profile <account> --region <region>

# hoi thang account do, khong qua aggregator - nhanh hon
aws configservice describe-compliance-by-config-rule \
  --config-rule-names OrgConfigRule-<ten-rule>-<hash> \
  --profile <account> --region <region> \
  --query 'ComplianceByConfigRules[0].Compliance.ComplianceType' --output text
```

`StartConfigRulesEvaluation` có giới hạn tốc độ — gọi lại quá sớm cho cùng một rule sẽ ra `LimitExceededException`. Đó là hạn chế, không phải lỗi.

> **Trộn hai loại rule trong một dashboard mà không biết loại nào là loại nào** thì mọi bản vá đều trông như không có tác dụng trong tối đa 24 giờ. Khi vận hành, luôn hỏi rule đang xem thuộc loại nào trước khi kết luận bản vá hỏng.

---

## 6d. Giai đoạn 9 — `account-baseline`, và bằng chứng rằng việc tay không đủ

Không dùng Control Tower thì không có **AFT**. Layer [`account-baseline`](../landing-zone/account-baseline/) làm phần việc đó: một StackSet `SERVICE_MANAGED` với `auto_deployment`, mỗi account một stack instance, bên trong là một Lambda tự quét các region trong `sweep_regions`.

Điểm mấu chốt không phải sáu account hiện có — dọn tay được. Là **account thứ bảy**: `auto_deployment` khiến account vừa vào OU tự được dọn, không phải chạy lại gì.

### Kết quả: năm default VPC chưa ai biết là còn

Mục 4 kết luận default VPC "đã xoá ở mọi account × mọi region". Lớp tự động trả lời khác:

```
lz-network       us-east-1/vpc-05d7cc1ef6007e805
lz-security      us-east-1/vpc-00ca7292432c5ff23
lz-logarchive    us-east-1/vpc-0b3933a8423ea26d6
lz-app-dev       us-east-1/vpc-09e5a7ecc087170f0
lz-app-prod      us-east-1/vpc-00e86d924d937405a
```

**Năm trên năm.** Lần dọn tay chỉ chạy ở `ap-southeast-1`, và không ai nhận ra vì `describe-vpcs` cũng chỉ được hỏi ở `ap-southeast-1`. Câu kiểm chứng dùng đúng cái giả định mà nó đáng ra phải kiểm.

Và đây **không phải** trường hợp `SKIP` vô hại:

| | |
|---|---|
| `us-east-1` có trong `allowed_regions` không? | **Có** — bắt buộc, `variables.tf` có validation ép phải có, vì service toàn cầu neo ở đó |
| Vậy `region_lock` có chặn `RunInstances` ở đó không? | **Không** |
| Nghĩa là | Năm account có sẵn đường ra Internet ở một region **được phép chạy EC2**, suốt cả tuần |

Nếu `us-east-1` nằm ngoài `allowed_regions` thì Lambda đã ghi `us-east-1/SKIP:ClientError` và đó mới là chuyện vô hại — không ai tạo được gì ở region bị khoá. Ở đây thì ngược lại.

### Lỗi 26 — treo một giờ, không phải "lỗi"

Ví dụ Lambda inline của AWS dùng `import cfnresponse`. Module đó có với một số runtime; với `python3.12` thì không.

Hỏng ở đây hỏng theo kiểu tệ nhất: Lambda chết ngay lúc **khởi tạo**, trước khi vào `try`, nên **không nhánh nào gửi được phản hồi**. Triệu chứng không phải thông báo lỗi mà là:

```
Still creating... [4m50s elapsed]
Still creating... [37m40s elapsed]
```

CloudFormation chờ **hết một giờ** rồi mới bỏ cuộc. Stack treo `CREATE_IN_PROGRESS`, các account còn lại xếp hàng `PENDING` phía sau, và stack hỏng rơi vào `DELETE_FAILED` — trạng thái chỉ gỡ được bằng:

```bash
aws cloudformation delete-stack --stack-name <ten> \
  --retain-resources <LogicalId>     # chi hop le khi dang DELETE_FAILED
```

Bản sửa: tự gửi phản hồi bằng `urllib`, không phụ thuộc module nào ngoài thư viện chuẩn. Dài thêm 12 dòng.

> **Quy tắc chung cho custom resource:** phải trả lời được CloudFormation **kể cả khi chính nó hỏng**. Cả nhánh `FAILED` cũng phải bọc `try` — không gửi được phản hồi thì triệu chứng là "treo một giờ", khó chẩn đoán hơn hẳn một dòng lỗi.

Thêm một điểm dễ quên: custom resource **chỉ chạy lại khi thuộc tính đổi**. Thêm region vào `sweep_regions` mà không đổi `sweep_version` thì không có gì xảy ra — và cũng không có gì báo.

### Lỗi 27 — lệnh kiểm chứng nói dối một cách êm ái

Sau khi apply xong, lệnh tôi tự viết trong README in ra **rỗng** ở cả năm account:

```bash
# SAI - in ra dong trong
--query 'Stacks[?...].Outputs[?OutputKey==`SweepResult`].OutputValue'

# DUNG
--query "Stacks[?...].Outputs[] | [?OutputKey=='SweepResult'].OutputValue"
```

Hai bộ lọc liên tiếp tạo một **projection lồng**. Với `--output json` nó hiện ra `[[{...}]]`; với `--output text` nó in một dòng trống — trông y hệt stack không có output nào.

Cái bẫy nằm ở chỗ **"rỗng" là câu trả lời hợp lý**: đã dọn tay rồi thì không tìm thấy gì là đúng. Suýt nữa thì ghi vào nhật ký rằng lớp mới chạy sạch và không phát hiện gì.

> **Bài học:** khi một lệnh kiểm chứng trả về đúng cái mình mong đợi, đó là lúc phải nghi ngờ **chính lệnh đó** nhất — chứ không phải lúc nó trả về thứ bất ngờ. Cách rẻ nhất: đổi sang `--output json` một lần. `[[...]]` là dấu hiệu của projection lồng.

### Kiểm độc lập

Không tin stack output — hỏi thẳng AWS:

```bash
for p in lz-network lz-security lz-logarchive lz-app-dev lz-app-prod; do
  printf '%-16s ' "$p"
  for r in ap-southeast-1 us-east-1; do
    printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r --profile $p \
      --filters Name=isDefault,Values=true --query 'length(Vpcs)' --output text)"
  done; echo
done
```

Kết quả thật:

```
lz-network       ap-southeast-1=0 us-east-1=0
lz-security      ap-southeast-1=0 us-east-1=0
lz-logarchive    ap-southeast-1=0 us-east-1=0
lz-app-dev       ap-southeast-1=0 us-east-1=0
lz-app-prod      ap-southeast-1=0 us-east-1=0
```

Mười ô, mười số `0`, hỏi thẳng EC2 chứ không đọc `SweepResult`. Đây là điểm khác biệt đáng giữ: `SweepResult` là **stack tự khai về chính nó**, còn bảng trên là AWS trả lời một câu hỏi không liên quan gì tới CloudFormation.

Lần này lặp **cả hai** region — đúng cái mà lần dọn tay không làm, và cũng đúng cái mà câu kiểm chứng của lần đó không làm.

---

## 6e. Lỗi 28 — ba thứ cùng nói "ổn", không ai nhận được gì

Chạy `./plan-all.sh` sau khi xong giai đoạn 9. Tám layer, bảy cái `khong doi`, một cái lệch:

```
config-detective     ok        ok        Plan: 1 to add, 0 to change, 0 to destroy
```

Một resource: `aws_sns_topic_subscription.email`. Địa chỉ có trong `terraform.tfvars`, nhưng lần apply cuối chạy trước khi thêm nó. Và vì `tfvars` nằm trong `.gitignore`, **không commit nào lộ ra sự lệch này** — chỉ `plan` mới thấy.

`terraform apply`. Thư xác nhận về hộp. Hỏi SNS:

```
quang.hong.0991@gmail.com    Deleted
```

### Ba lời khai đều sai

| Nguồn | Nói gì | Thực tế |
|---|---|---|
| `terraform apply` | `1 added` | Subscription không tồn tại |
| `terraform plan` | `No changes` | State giữ một ARN đã chết |
| `aws sns publish` | `MessageId: a8872013-...` | Không có subscriber nào |

`sns publish` là cái độc nhất: nó **luôn** trả `MessageId` miễn topic tồn tại. Lệnh báo OK, số hiệu thư có thật, thư rơi vào hư không.

Nặng hơn lỗi 23 (user SSO không có thư mời): ở đó ít nhất **không có gì tuyên bố thành công**. Ở đây có ba thứ cùng khẳng định đường cảnh báo bảo mật của cả tổ chức đang chạy.

### Bốn giả thuyết, bốn lần sai

Đây mới là phần đáng ghi.

| # | Tôi nói | Bằng chứng bác bỏ |
|---|---|---|
| 1 | `assume-role` hỏng vì credential là **root user** | `get-caller-identity` → IAM user có quyền admin, và lời gọi đó chạy rời thì thành công |
| 2 | Subscription hết hạn sau **3 ngày** | Thư xác nhận về **vài phút** trước khi listing báo `Deleted`, không phải vài ngày |
| 3 | Provider lưu ID là chuỗi `pending confirmation` | Log apply cho thấy state giữ **ARN thật kết thúc bằng UUID** |
| 4 | Địa chỉ bị chặn — *(đúng, nhưng đo sai)* | Tôi đọc phép thử khi bản ghi cũ vẫn còn trong bảng, nên không phân biệt được "bị chặn" với "bản ghi chưa dọn" |

Mỗi lần tôi lại nói chắc hơn mức bằng chứng cho phép. Giả thuyết 4 **về sau hoá ra đúng** — nhưng lúc phát biểu thì nó chưa được chứng minh, và "đoán trúng" không phải là "đo được".

### Cái giải được nó

Phép thử hai nhánh, giống hệt nhau, khác đúng một biến — cùng khuôn đã dùng cho lỗi 19 (hai bucket y hệt để chứng minh Object Lock chặn Config):

```bash
aws sns subscribe --topic-arn <cung mot topic> --protocol email \
  --notification-endpoint quang.hong.0991+lztest@gmail.com ...
```

```
quang.hong.0991@gmail.com          Deleted                 <- chan
quang.hong.0991+lztest@gmail.com   PendingConfirmation     <- binh thuong
```

Cùng topic, cùng account, cùng phút. Một bảng loại trừ đồng thời cả ba thứ mà bốn lượt suy luận không loại được: **không phải Terraform** (subscribe trực tiếp), **không phải bản ghi cũ** (đã dọn sạch trước), **không phải topic hay account** (dòng thứ hai đứng ngay cạnh).

### Hai điều phép thử dạy thêm

**Chặn theo topic, không theo địa chỉ.** Cùng địa chỉ đó vẫn đăng ký bình thường vào topic khác, kể cả account khác. Chính điều này làm giả thuyết trông vô lý suốt mấy lượt — *"email này tôi dùng đăng ký khá nhiều SNS topic ở các account"* nghe như bằng chứng loại trừ, mà không phải.

**Thứ tự quyết định phép thử đọc được hay không.** `Subscribe` cho endpoint còn bản ghi cũ sẽ **khớp vào bản ghi cũ** thay vì tạo mới — đó là lý do `-replace` trả về **đúng UUID cũ** và không gửi thư nào. Phải `unsubscribe`, chờ dòng đó **biến mất khỏi bảng** (không phải chờ tới khi nó ghi `Deleted`), rồi mới thử.

### Kết cục

Đổi `alert_emails` sang một địa chỉ khác:

```
quangchutcb@gmail.com   arn:aws:sns:ap-southeast-1:458195083898:quh11-lz-security-findings:1a0f73d2-ec42-4784-9715-0d1e8c1f8929
```

ARN thật, kết thúc bằng UUID. Không có API gỡ chặn cho email — địa chỉ cũ phải qua AWS Support mới lấy lại được ở topic này.

> **Terraform không thể tự bắt lỗi này.** Nó không có data source đọc subscription của SNS, nên không `lifecycle` hay `check` block nào cứu được. Đây không phải drift mà `plan` phát hiện được — là drift mà `plan` **khẳng định là không có**. Lưới duy nhất là layer tự nhắc người vận hành đi hỏi thẳng SNS, và đó là thứ đã thêm vào `README`, `notify.tf`, `next_steps`.

> **Bài học rộng hơn cả SNS:** mọi đường cảnh báo đều phải kiểm bằng cách **hỏi đầu nhận**, không phải hỏi đầu gửi. `plan` sạch, `apply` xanh, `publish` trả `MessageId` — cả ba đều là đầu gửi.

---

## 6f. Giai đoạn 10 — `network`, và lỗi do chính bản vá an toàn gây ra

> **Mục này khác mọi mục trên: `network` MỚI CÓ CODE, CHƯA AI APPLY.** Đo được ở đây chỉ có `terraform plan`. Đừng đọc nó như bảy giai đoạn kia — chúng có số đo thật từ AWS, mục này thì chưa.

Layer [`network`](../landing-zone/network/) làm giai đoạn 1 của [doc 17](./17-Network-LZ-Design-Guide.md): TGW + security VPC + Network Firewall + egress VPC, chia sẻ TGW cho cả tổ chức qua RAM. Chưa có ingress VPC (Palo Alto và F5 cần license Marketplace), chưa có 3rd-party VPC, chưa có Route 53 Profile.

### Layer đầu tiên phá vỡ mẫu "~$0/ngày"

| Layer | Chi phí |
|---|---|
| Bảy layer trước | ~$0/ngày |
| `network`, 2 AZ | **~$770/tháng** |

Trong đó **$570 là Network Firewall endpoint** — $0.395/giờ **mỗi AZ**, chạy 24/7 dù có gói tin nào đi qua hay không. Đây là quyết định khác hẳn `enable = true` ở mọi layer trước, nên README của layer mở đầu bằng bảng chi phí chứ không phải bằng kiến trúc.

### Lỗi 29 — bản vá an toàn tự tạo ra lỗ hổng của nó

Soát tay trước khi commit, tôi tìm ra một chỗ: `[0].id` trên resource `count = 0` là *Invalid index*, **kể cả ở nhánh không được chọn**. Sửa thành `one(...[*].id)` cho an toàn.

`one()` trả về `null` khi `count = 0`. Với một phép gán thì null vô hại. Trong string template thì:

```
Error: Invalid template interpolation value
  aws_ec2_transit_gateway.hub is empty tuple
  The expression result is null. Cannot include a null value in a string template.
```

Bốn lần, trong hai output sinh HCL. Và nó hỏng ở **`enable = false`** — trạng thái mặc định, thứ ai cũng gặp đầu tiên, trước cả khi đọc tới TGW hay firewall.

Ba điều đáng ghi, và không điều nào nói về Terraform:

| | |
|---|---|
| **Bản vá tạo ra lỗi** | Thay đổi duy nhất tôi làm *để giảm rủi ro* là thay đổi duy nhất gây lỗi. `one()` đúng cho phép gán, sai cho template — tôi áp dụng nó ở cả hai chỗ mà không phân biệt |
| **Hỏng ở trạng thái mặc định** | Không phải góc khuất nào. `terraform plan` với cấu hình xuất xưởng là hỏng |
| **`fmt` sạch và soát tay kỹ đều không bắt được** | Tôi vừa soát ra ba lỗi khác nên thấy yên tâm. `fmt` chỉ kiểm định dạng, và mắt người không lần được `null` chảy vào đâu. `plan` thật bắt trong một giây |

Bản sửa cho cả hai giá trị đi qua `coalesce()` với một chuỗi giữ chỗ đọc được, nên khối HCL sinh ra vẫn in được trước khi hub tồn tại.

> **Vì sao tôi không tự bắt được:** layer này viết trong môi trường có chính sách mạng chặn `registry.terraform.io`, nên `terraform init` và `validate` không chạy được ở đó. Tôi nói rõ điều đó khi bàn giao — nhưng nói rõ giới hạn không làm giới hạn biến mất. **Một layer chưa ai chạy vẫn là một layer chưa ai tin được**, kể cả khi người viết đã cảnh báo trước.

### Ba quyết định thiết kế, và lý do

**Spoke VPC cố ý không nằm trong layer.** Provider không sinh động được bằng `for_each` — sáu account là sáu alias viết tay, account thứ bảy là sửa code. Nên layer sở hữu TGW, share qua RAM, và **nối** attachment do account workload tạo. Bước nối bắt buộc ở đây: chỉ chủ sở hữu TGW mới `associate`/`propagate` được.

Bỏ bước nối = attachment `State: available` và không thuộc route table nào. Không lỗi, không cảnh báo, không một gói tin nào đi qua — **đúng họ với lỗi 28**: mọi thứ báo ổn, không ai nhận được gì.

**Route table theo từng AZ**, khác bản demo một-AZ. Gói vào subnet `tgw` của AZ-a phải tới firewall endpoint của chính AZ-a. `sync_states` là một **set không có thứ tự**, nên code lập map `AZ → endpoint` chứ không lấy theo chỉ số.

**`appliance_mode_support` chỉ lộ ra từ 2 AZ trở lên.** Với một AZ nó không bao giờ sai. Nên bản một-AZ — thứ tôi khuyên dùng để thử code cho rẻ — **không kết luận được là cấu hình đúng**. Đó là một giới hạn của phép thử, phải biết trước khi tin nó.

---

## 7. Việc còn lại sau lần dựng này

Đã đi hết cả chín giai đoạn của runbook.

| # | Việc | Trạng thái |
|---|---|---|
| 1 | 6 account + chuyển vào đúng OU | **Xong** — `list-parents` xác nhận cả 5 account thành viên đúng OU |
| 2 | 4 SCP | **Xong** — kiểm chứng 4/4, kể cả `prod_guard` |
| 3 | Xoá default VPC mọi account × mọi region | **Xong** — làm tay sót `us-east-1` ở cả 5 account, `account-baseline` dọn nốt. Xem mục 6d |
| 4 | Identity Center | **Xong** — `ssoins-8210168ac3d88c11`, identity store `d-9667ae9e62`, `ap-southeast-1` |
| 5 | `permission-sets` | **Xong** — 115 resource, xem mục 5b |
| 6 | `billing-guard` | **Xong** — budget, SNS đã xác nhận, anomaly. Còn `enable_cost_allocation_tags` khi có resource mang tag |
| 7 | `config-detective` | **Xong** — $0.29 một lần, ~$0/ngày ổn định. Xem mục 6b |
| 8 | **Layer `org-trail`** | **Xong** — 8 resource, và `cloud-trail-enabled` đã chuyển sang COMPLIANT ×4. Xem mục 6c |
| 9 | **Layer `account-baseline`** | **Xong** — 5/5 stack instance CURRENT, xoá 5 default VPC lần dọn tay bỏ sót. Xem mục 6d |
| 10 | **Layer `network`** | **Mới có code** — `plan` sạch ở `enable = false`, **chưa ai apply**. Xem mục 6f |

Còn lại, không thuộc giai đoạn nào của runbook:

| Việc | Vì sao |
|---|---|
| `enable_cost_allocation_tags` ở `billing-guard` | Chỉ có nghĩa khi đã có resource mang tag |
| Xem lại pham vi `lz-db-admin` / `lz-server-admin` | Hai set này để `all`, tức có quyền ghi vào production, trong khi `lz-app-admin` chỉ nonprod. Không nhất quán — hoặc là cố ý và cần ghi rõ, hoặc là sót |
| Layer `control-tower` | **Chưa ai chạy bao giờ.** Mặc định tắt, không ảnh hưởng gì — nhưng một lớp chưa ai chạy là một lớp chưa ai tin được, đúng như lỗi 26 vừa chứng minh với code viết cùng ngày |
| Layer `network` | Có code, `plan` sạch, **chưa apply**. Và bật nó là ~$770/tháng — không phải việc "làm nốt cho đủ bộ" mà là quyết định có workload thật hay không. Xem mục 6f |

### Vì sao `org-trail` là việc tiếp theo

Lớp phát hiện bắt được ngay ngày đầu: **không có CloudTrail nào trong tổ chức**. Ba tầng đã chuẩn bị sẵn cho nó mà không tầng nào tạo ra nó — `baseline` SCP chặn `cloudtrail:StopLogging`, `aws_service_access_principals` đã bật `cloudtrail.amazonaws.com`, `lz-auditor` được cấp quyền đọc. Chi tiết ở mục 6b.

Không có trail thì không có bản ghi ai làm gì, `lz-auditor` không có gì để đọc, và điều tra sự cố không có nguồn dữ liệu.

Một **organization trail** tạo ở management account phủ mọi account hiện tại và tương lai, ghi vào cùng bucket account log archive. Management event lần đầu miễn phí; chỉ trả tiền lưu trữ S3.

### Vì sao `account-baseline` là việc sau đó

Việc 1 và việc 3 lúc đó đã làm **bằng tay**, và cả hai đều sẽ phải làm lại nguyên vẹn cho account thứ bảy:

| Việc tay | Quên thì hậu quả |
|---|---|
| `move-account` vào OU | Account chỉ còn SCP ở root — mất `network_lock` và `prod_guard` |
| Xoá default VPC ở mọi region | Một Internet Gateway mở sẵn, `network_lock` không đụng tới được |
| Thêm account ID vào `accounts_by_scope` | Không ai vào được account đó qua Identity Center |

Ba việc, không việc nào báo lỗi khi quên. Account vẫn chạy, chỉ là không có guardrail — đúng loại sai lệch lặng lẽ mà một landing zone sinh ra để ngăn.

Đó là lý do [doc 09](./09-Account-Vending-Tu-Dong.md) gọi đây là **account vending** và giao cho tự động hoá.

> Viết đoạn trên xong thì dựng luôn layer đó, và nó lập tức chứng minh lập luận mạnh hơn cả dự tính: không phải account thứ bảy mới thiếu guardrail — **sáu account hiện có đã thiếu sẵn rồi**, chỉ là không ai hỏi đúng region. Chi tiết ở mục 6d.

### Lệnh kiểm lại toàn bộ

Chạy từ management account. Ba câu hỏi: account nào sai OU, region nào còn default VPC, đường cảnh báo có thông không.

```bash
ORG_REGIONS="ap-southeast-1 us-east-1"

for id in $(aws organizations list-accounts \
              --query 'Accounts[?Status==`ACTIVE`].Id' --output text); do
  name=$(aws organizations describe-account --account-id "$id" \
           --query 'Account.Name' --output text)
  parent=$(aws organizations list-parents --child-id "$id" \
             --query 'Parents[0].[Type,Id]' --output text)
  printf '%-14s %-16s %s\n' "$id" "$name" "$parent"

  [ "$id" = "$(aws sts get-caller-identity --query Account --output text)" ] \
    && continue

  # KHONG nuot stderr - xem phan duoi vi sao
  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::$id:role/OrganizationAccountAccessRole" \
    --role-session-name vpc-audit \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text) || { echo "    ^ khong assume duoc, xem loi ngay tren"; continue; }

  read -r AK SK ST <<<"$creds"
  for r in $ORG_REGIONS; do
    n=$(AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
        aws ec2 describe-vpcs --region "$r" --filters Name=isDefault,Values=true \
          --query 'length(Vpcs)' --output text)
    [ "$n" != "0" ] && echo "    $r: CON $n default VPC"
  done
done
```

Không in dòng `CON ... default VPC` nào, và cột cuối không có `ROOT` nào ngoài management account, là sạch.

> **Đừng dán comment `#` vào zsh.** macOS mặc định dùng zsh, và zsh **tương tác** không bật `interactive_comments` — mọi dòng `#` trong khối dán vào sẽ thành `zsh: command not found: #`. Vô hại nhưng ồn. `setopt interactive_comments` một lần là hết.

> **Bản đầu của đoạn script trên có `2>/dev/null` ở cả hai lời gọi**, và khi `assume-role` hỏng nó chỉ in `(khong assume duoc)` — không nói vì sao. Đúng cùng một lỗi với #27: che mất câu trả lời rồi để người đọc tự đoán.
>
> Lần dựng này nó hỏng ở cả 5 account. Tôi đoán là do credential mặc định là root user — **đoán sai**: `get-caller-identity` cho ra một IAM user có quyền admin, và cùng lời gọi `assume-role` đó chạy rời thì thành công. Nguyên nhân thật vẫn chưa biết, vì thông báo lỗi đã bị `2>/dev/null` nuốt mất trước khi ai kịp đọc.
>
> Ghi lại đúng như vậy, không viết một nguyên nhân nghe hợp lý vào chỗ trống. Bài học nằm ở chính chỗ đó: **script nuốt stderr thì lỗi không biến mất, nó chỉ chuyển thành phỏng đoán** — và phỏng đoán đầu tiên của tôi đã sai.

> **Vòng lặp này không phải thứ bắt buộc.** Nếu đã có profile cho từng account thì bản dưới đây trả lời cùng câu hỏi với ít chỗ hỏng hơn hẳn — nó không cần `assume-role`, không cần env var tạm, không cần role nào tồn tại.

### Bản không cần assume-role

Nếu đã có profile cho từng account thì bỏ hẳn `assume-role` đi — ít chỗ hỏng hơn, và đây mới là kiểm chứng thật của mục 6d: `SweepResult` là stack tự khai về chính nó, còn cái này hỏi thẳng EC2.

```bash
for p in lz-network lz-security lz-logarchive lz-app-dev lz-app-prod; do
  printf '%-16s ' "$p"
  for r in ap-southeast-1 us-east-1; do
    printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r --profile $p \
      --filters Name=isDefault,Values=true --query 'length(Vpcs)' --output text)"
  done; echo
done
```

### Cái bẫy của việc 1

`aws organizations create-account` **không nhận tham số OU**. Account mới luôn nằm ở root, phải `move-account` thủ công. SCP thì gắn vào OU — nên một account quên chuyển là account **không có guardrail nào ngoài hai SCP gắn ở root**.

Nguy nhất là `lz-app-prod`: `prod_guard` gắn vào OU `Production`, account còn ở root thì SCP đó không chạm tới nó.

```bash
for id in $(aws organizations list-accounts --query 'Accounts[].Id' --output text); do
  printf '%-14s %-16s %s\n' "$id" \
    "$(aws organizations describe-account --account-id $id --query 'Account.Name' --output text)" \
    "$(aws organizations list-parents --child-id $id --query 'Parents[0].[Type,Id]' --output text)"
done
```

`ROOT` ở cột cuối = chưa chuyển.

---

## 7. Vòng xoá–dựng lại

Lần dựng đầu chứng minh code **dựng được**. Nó không chứng minh được code **gỡ được** — và đó là hai việc khác nhau, vì lớp bảo vệ chỉ lộ ra khi bạn đi ngược chiều.

### 7a. Số đo

| Layer | Xoá | Thời gian đáng chú ý | Dựng lại |
|---|---|---|---|
| `config-detective` | 25 | StackSet instance **1m33s**; 8 org rule 1m20s–1m46s | 25 |
| `account-baseline` | 2 | StackSet instance **2m5s** trên 6 OU | 2 |
| `org-trail` | 8 | Bucket **26 giây** | 8 |
| `billing-guard` | 5 | tức thì | **9** |
| `permission-sets` | 118 | ~2 phút | 118 |
| | **158** | | **162** |

Chênh 4 vì lần dựng lại bật thêm cost allocation tag — xem 7e.

### 7b. Hai cổng khoá, và bằng chứng chúng khác nhau thật

Hạ tầng thường trực có hai lớp chặn, khoá ở hai nơi:

| | `prevent_destroy` | `allow_destroy` |
|---|---|---|
| Khoá ở | Terraform, trong `lifecycle` | AWS, trên chính resource |
| Gọi API khi gỡ | **Không** | **Có** (firewall) |
| Cần `apply` xen giữa | Không | **Bắt buộc** |

Terraform **không cho** dùng biến trong `lifecycle`, nên lớp thứ nhất không thể thành một cờ — phải sửa file. Đó là lý do có `unlock-destroy.sh`: nó đổi `true` ↔ `false` trên 11 chỗ / 6 layer, và vì đổi giá trị chứ không xoá dòng nên `git diff` về **rỗng đúng từng byte** sau khi khoá lại.

Bằng chứng rõ nhất rằng cổng thứ hai làm việc thật nằm ở hai con số cạnh nhau:

```
aws_s3_bucket.config[0]:  Destruction complete after 3s      <- bucket rong
aws_s3_bucket.trail[0]:   Destruction complete after 26s     <- force_destroy quet version that
```

Cùng một kiểu resource, cùng bật versioning. 3 giây là bucket không có gì; 26 giây là `force_destroy` duyệt và xoá từng version cùng delete marker của log CloudTrail. Không có nó thì `destroy` dừng ở `BucketNotEmpty` — vì `aws s3 rm --recursive` chỉ tạo delete marker.

### 7c. Hai cảnh báo tôi đưa ra, cả hai đều sai

**"Bước dễ kẹt nhất là `config-detective`, phải miễn trừ role StackSet trước."** Tôi nói điều này hai lần. Nó chạy thẳng, không vướng gì. Lý do: đường miễn trừ `stacksets-exec-*` **đã nằm sẵn trong `scp_exempt_role_names`** từ lúc sửa lỗi 20, năm ngày trước. Cảnh báo đúng về nguyên tắc, thừa với org này — và tôi đã không kiểm `scp_summary` trước khi nói.

**"Vòng thử `--unlock`/`--lock` đã kiểm chứng, đảo ngược chính xác."** Vòng thử đó chạy trên Linux, nơi GNU `sed` chấp nhận `sed -i -E`. Máy người dùng là macOS. Xem lỗi 30 và 31 — tôi báo là đã kiểm chứng một thứ mà phép kiểm không phủ tới nền tảng đang dùng.

> Cả hai đều cùng một dạng: **suy luận từ thứ mình biết thay vì hỏi hệ thống**. Đúng cái mục 2.5 đã viết ra, rồi lại ngã vào.

### 7d. Ba thứ nhanh hơn lần đầu, và vì sao

| | Lần đầu | Lần dựng lại |
|---|---|---|
| 8 Config rule | Cả 8 chạm mốc timeout 30 phút, Terraform đánh dấu tainted | Xong trong giới hạn, không tainted |
| Cost allocation tag | — | `Active` **ngay lập tức** |
| CloudTrail giao file đầu | ~15 phút (ước tính) | `LatestDeliveryTime` có ngay sau apply |

Cái đầu là do bản sửa nâng timeout lên 90 phút đã ăn. Cái thứ hai đáng ghi vì `next_steps` nói *"chờ ~24 giờ"* — câu đó vẫn đúng nhưng cho **việc khác**: kích hoạt tag key có hiệu lực ngay, còn 24 giờ là để dữ liệu chi phí **nhóm theo tag** xuất hiện trong báo cáo. Hai chuyện.

### 7e. Cost allocation tag — chỗ duy nhất "muộn" tệ hơn "chưa hoàn hảo"

`enable_cost_allocation_tags` đang là `false` trong tfvars, đúng theo mô tả biến: *"tag chỉ bật được SAU KHI đã có ít nhất một resource mang tag đó"*. Lần dựng đầu chưa có gì mang chúng.

Nhưng cost allocation tag **không hồi tố**. Mỗi ngày để tắt là một ngày dữ liệu hoá đơn vĩnh viễn không chia được theo team. Và lúc dựng lại thì đã có 118 permission set + 5 SCP mang đủ 4 tag key.

Bật, apply, và cả 4 ra `Active` ngay. Câu hỏi bỏ ngỏ trước đó — *"AWS có tính tag trên resource không tính tiền không?"* — được trả lời bằng chính phép thử: **có**.

### 7f. Account không xoá được, nên đừng xoá

Điều đáng nhớ nhất của cả vòng này không phải kỹ thuật. Account AWS **chỉ đóng được**, sau đó nằm lại tổ chức 90 ngày, và email cháy vĩnh viễn trên toàn AWS.

Nên `organization` có thêm OU `Suspended` với đúng một SCP `Deny *`, cùng `park-account.sh` để chuyển account vào ra. Ba chi tiết học được khi viết nó:

- **OU không có SCP nguy hơn không có OU.** Lệnh chạy trót lọt, báo thành công, account vẫn chạy bình thường trong một OU tên `Suspended`. Script vì vậy đọc nội dung policy thật gắn trên OU và từ chối move nếu không thấy `Deny *`.
- **Ghi tag trước khi move, không phải sau.** OU cũ lưu vào `lz:parked-from`; ghi tag hỏng thì dừng, chưa move gì cả.
- **`Deny *` chặn hành động, không chặn hoá đơn.** Tài nguyên còn chạy vẫn tính tiền, và không xoá được cho tới khi `--restore`. Dọn sạch trước, park sau.

### 7g. Ba nguồn phải cùng nói một điều

Bước kiểm cuối của `account-baseline` hỏi ba nơi khác nhau về cùng một sự thật:

```
StackSet  ->  5/5 CURRENT                      (da toi noi chua)
Lambda    ->  "khong co default VPC nao" ×5    (no BAO cao xoa gi)
AWS       ->  0 / 0 ×5 accounts × 2 regions    (thuc te con gi)
```

Lệnh thứ ba là lệnh duy nhất không tin lời ai — và nó xác nhận lỗ hổng `us-east-1` ở mục 6d đã đóng. Vòng lặp **một** region chính là thứ đã tạo ra lỗ hổng đó: lần dọn tay chỉ chạy ở một region, và câu kiểm chứng cũng chỉ hỏi region đó.

### 7h. Lỗi 33 — nguồn của đường cảnh báo nằm ngoài code

Câu hỏi khởi đầu vô hại: *"guardrail của Control Tower có port sang DIY được không?"* Trả lời nó buộc phải đọc lại `notify.tf`, và ở đó có một dòng:

```hcl
event_pattern = jsonencode({
  source        = ["aws.securityhub"]
  ...
})
```

**Không layer nào tạo hay quản Security Hub.** `grep -r aws_securityhub --include=*.tf` ra rỗng.

Nghĩa là toàn bộ đường cảnh báo — EventBridge rule, SNS topic, subscription — treo trên một dịch vụ mà Terraform không biết là có tồn tại.

#### Tôi đã ghi lỗi này nặng hơn thực tế, và đây là bản sửa

Bản đầu của mục này viết rằng *"không sự kiện nào từng đi qua"*, và dựng nó thành **lỗi thứ hai trên cùng đường ống mà lỗi 28 che đi**. Cả hai đều sai.

Sự thật: Security Hub **đang chạy và có dữ liệu đổ về**. Nó được bật ở giai đoạn 7 bằng ba lệnh tay mà chính RUNBOOK ghi ra (commit `a48f8a6`), và destroy `config-detective` không tắt nó — Security Hub không nằm trong layer đó.

Tôi suy từ *"repo không bật nó"* sang *"nên nó chưa bao giờ chạy"*. Bước suy luận đó bỏ qua mất phần thủ công của chính runbook mình viết. Kiểm bằng một lệnh là ra:

```bash
aws securityhub describe-hub --profile lz-security --region ap-southeast-1
```

> **Cùng một sai lầm với lỗi 28, chỉ đổi hướng.** Lỗi 28 tôi tin `terraform plan` và không hỏi SNS. Lần này tôi tin `grep` và không hỏi Security Hub. Cả hai lần đều suy ra trạng thái vận hành từ thứ nằm trong repo — mà repo chỉ là một nửa câu chuyện, nửa kia là những bước tay runbook bảo người ta làm.

#### Vậy lỗi thật là gì

Không phải "đường cảnh báo chết". Là **một phụ thuộc không được quản lý**:

| | |
|---|---|
| Rủi ro thật | Ai đó tắt Security Hub, hoặc dựng LZ này ở tổ chức mới mà bỏ qua bước tay — đường cảnh báo im lặng, không gì báo |
| `terraform plan` thấy gì | Không gì cả. Nó không biết dịch vụ đó tồn tại |
| Vì sao vẫn là lỗi thiết kế | Một đường cảnh báo mà nguồn nằm ngoài code là đường cảnh báo không ai kiểm được bằng code |

`securityhub.tf` đưa nguồn đó vào Terraform để `plan` nhìn thấy nó. Và `check "alerts_have_a_source"` **không** khẳng định đường ống chết — nó nói rằng nguồn không do layer này quản, rồi đưa ra lệnh để hỏi thẳng dịch vụ.

Bản sửa thêm `securityhub.tf` và một `check` bắt đúng trạng thái này lúc `plan`:

```
alert_emails da khai nhung enable_security_hub = false.
notify.tf khop event theo source = aws.securityhub, nen KHONG CO
su kien nao toi rule EventBridge va khong ai nhan duoc gi -
du SNS co subscriber da xac nhan.
```

Cùng file đó cũng đưa **lỗi 14 vào code**: `aws_securityhub_organization_admin_account` là lệnh chỉ định riêng của Security Hub, và đăng ký `securityhub.amazonaws.com` ở tầng Organizations là chưa đủ — thiếu nó thì mọi lệnh gọi từ security account báo `InvalidAccessException: The account is not an administrator`, một thông báo không nhắc gì tới Organizations.

#### Đóng lại — import chứ không apply thẳng

Security Hub đang chạy thật, nên không thể apply `securityhub.tf` như dựng mới. Trình tự đã dùng:

| Bước | Kết quả |
|---|---|
| Hỏi thẳng dịch vụ, cả hai account | Ba resource đã tồn tại, hai chưa |
| `terraform plan` sau khi pull `1f94d2d` | `5 to add` — `fsbp` biến mất, `auto_enable_standards = "NONE"`, khớp live |
| Import 3 resource | — |
| `terraform plan` | **`2 to add, 0 to change`** |
| `terraform apply` | management `hub/default` + finding aggregator |

`0 to change` là con số đáng giá nhất ở bảng trên: nó nói code và trạng thái thật khớp **từng trường**, chứ không phải "apply chạy được".

Ba điểm chỉ lộ ra khi làm thật:

- **Thứ tự import có ý nghĩa.** Uỷ quyền phải vào state trước, vì hai resource sau dùng provider `aws.security` và chỉ đọc được khi account đó đang là delegated admin.
- **zsh coi `[0]` là glob.** `terraform import aws_securityhub_account.security[0]` trên macOS ra `zsh: no matches found`. Phải quote địa chỉ.
- **`-var` là cái bẫy đặt sẵn.** Ba resource nằm sau `count`. Lần nào ai đó `terraform apply` thiếu `-var enable_security_hub=true`, `count` tụt 1→0 và Terraform **destroy** cả ba — `DisableSecurityHub`, gỡ uỷ quyền, đường cảnh báo mất nguồn. Giá trị phải nằm trong `terraform.tfvars`, không phải trên dòng lệnh.

RUNBOOK giai đoạn 7 mục (2) đã thay ba lệnh CLI bằng một biến, và giữ ba lệnh cũ lại **chỉ** làm đường import cho tổ chức đã bật tay.

> Lỗi 33 đóng ở đây theo đúng nghĩa của nó: không phải "đường cảnh báo đã sống" — nó vẫn sống từ đầu — mà là **nguồn của nó giờ nằm trong code**. Ai tắt Security Hub thì `plan` sẽ nói, thay vì `notify.tf` lặng lẽ chờ một event không bao giờ tới.

### 7i. Lỗi 34 — `scope = "all"` nghĩa là *tất cả*, kể cả nơi giữ bằng chứng

Câu hỏi của người dùng: *"sao account `lz-security` lại nhận nhiều permission set đến vậy?"*

Đếm ra 10. Nguyên nhân: **10/17 permission set khai `scope = "all"`**, và `all` không phải một danh sách viết tay — nó suy ra từ Organizations:

```hcl
all_accounts = [for id in local.active_accounts : id if id != var.management_account_id]
```

Không có khái niệm "chỉ account workload". `all` là *tất cả*, kể cả hai account giữ tài sản nhạy cảm nhất.

Đó mới là câu hỏi. Câu trả lời tệ hơn nhiều.

`lz-server-admin` cũng ở `scope = "all"`. Quyền của nó sinh từ `admin_actions["compute"]`, và `svc_compute` chứa `"s3"` — nên nó có **`s3:*`**. Còn `all` gồm cả `lz-logarchive`.

Kiểm các deny của set đó: `DenyEc2NetworkApis`, `DenyEc2SecurityGroupRuleChanges`, `DenyIamWritesOutsideSecurityDomain`, `DenyTamperingWithGuardrails`. Cái cuối chặn `cloudtrail:DeleteTrail`, `config:DeleteConfigurationRecorder`… **không chặn `s3:DeleteObject`**.

> **Kết quả: cả đội hạ tầng compute xoá được bucket CloudTrail và bucket Config snapshot của cả tổ chức.**

Điều làm nó đáng ghi riêng: **hai tin nhắn trước đó tôi vừa bảo vệ chính lớp bảo mật này.** Người dùng hỏi vì sao log phải ghi vào account log archive riêng, tôi trả lời rằng nó mua được tính chất *"account phát hiện được không phải account xoá được"*, và lập luận dựa trên việc `lz-security-admin` phải đi vòng qua `iam:*`.

Lập luận đúng về ranh giới account, và **thiếu hẳn tầng permission set đâm xuyên qua nó** — không cần vòng vèo, `s3:*` là cấp thẳng. Tôi đã đọc kỹ SCP và IAM policy của một account, rồi quên hỏi *ai được gán vào account đó*.

**Bản sửa dùng hai lớp, vì một lớp là một lần sửa nhầm:**

| Lớp | Làm gì |
|---|---|
| **Phạm vi** | Tách `all` thành `all` / `security` / `network` / `workloads`. `workloads` = mọi account **trừ** ba account hạ tầng lõi, khai trong `core_accounts` |
| **Deny cứng** | `DenyDeletingAuditEvidence` nêu đích danh ARN của hai bucket bằng chứng, gắn **tự động** vào mọi set đã có `deny_guardrails` |

Lớp thứ hai bắt trường hợp sau này ai đó khai lại `scope = "all"`, hoặc thêm một account lõi mà quên đưa vào `core_accounts`. Một lớp thì một lần sửa nhầm là mất; hai lớp thì phải sai ở hai chỗ khác nhau cùng lúc.

Deny đó **phải nêu Resource cụ thể**, không được `"*"` — `s3:DeleteBucket` trên `"*"` sẽ chặn cả việc xoá bucket hợp lệ trong account workload, mà quản S3 ở đó đúng là việc của `lz-server-admin`. Tôi viết sai chỗ này ở bản nháp đầu và phải sửa lại trước khi commit.

Và nó được gắn **tự động** theo `contains(each.value.statements, "deny_guardrails")` chứ không khai tay ở từng set: khai tay nghĩa là phải nhớ gắn vào 10 chỗ, nhớ lại mỗi lần thêm set mới — và chỗ bị quên chính là chỗ mất bằng chứng.

**Số đo thật sau khi áp dụng:**

| | Trước | Sau |
|---|---|---|
| Tổng assignment | 53 | **29** |
| Permission set trên `lz-logarchive` | 10 | **3** |
| `lz-server-admin`, `lz-db-admin` | 5 account mỗi cái | **2** — chỉ app-dev và app-prod |
| `lz-security-admin` | 5 | **1** |
| `lz-network-admin` | 5 | **1** |

Ba set còn lại trên log archive là `lz-account-admin` (trần đã nêu ở trên), `lz-auditor` và `lz-security-operator` — hai cái sau chỉ đọc và đã chặn data-plane.

Terraform báo `16 to change`, đúng bằng 7 tag `PermissionSetScope` đổi giá trị cộng 9 inline policy nhận thêm `DenyDeletingAuditEvidence` — đúng 9 set có `deny_guardrails`.

> **Bài học:** phân quyền có hai câu hỏi, và tôi chỉ hỏi một. *"Set này cho quyền gì?"* đọc trong policy. *"Set này gán vào đâu?"* đọc ở chỗ khác hoàn toàn. Một set vô hại ở account workload thành nguy hiểm ở account log archive mà **nội dung policy không đổi một chữ**.
>
> Output `scope_map` thêm vào để câu hỏi thứ hai trả lời được bằng một lệnh.

---

### 7j. Lỗi 35 — "service principal hay dùng" gộp hai nhóm không cùng loại

Câu hỏi bắt được lỗi này rất ngắn: *đã có `config`, `config-multiaccountsetup`, `securityhub` trong `delegated_administrators` — có thêm `guardduty` không?*

Câu trả lời là **không**, và lý do cho thấy mô tả biến do tôi viết đang sai.

**Hai nhóm dịch vụ, không cùng cơ chế:**

| Nhóm | Cách chỉ định delegated admin | Khai trong `delegated_administrators`? |
|---|---|---|
| `config`, `config-multiaccountsetup`, `access-analyzer`, `storage-lens` | Đăng ký ở Organizations là **cách duy nhất** | **Có** — bắt buộc |
| `securityhub`, `guardduty` | Có lệnh chỉ định **riêng**, và lệnh đó tự đăng ký ở Organizations giúp | **Không** |

Với nhóm hai, `aws_securityhub_organization_admin_account` và `aws_guardduty_organization_admin_account` — cả hai nằm ở `config-detective` — đã làm trọn việc. Layer `organization` chỉ cần **trusted access** cho chúng, thứ đã có sẵn trong `enabled_service_principals`.

**Khai ở cả hai nơi hỏng ở đâu:** hai layer cùng sở hữu một sự thật. Bỏ khoá ra khỏi map — hoặc destroy layer `organization` — sẽ gọi `DeregisterDelegatedAdministrator`, rút admin ra **từ dưới chân** `config-detective` mà layer đó không hay biết. Nó cũng biến thứ tự apply thành chuyện phải nhớ, thay vì thứ Terraform tự lo.

**`securityhub.amazonaws.com` đang nằm trong map thật.** Nó vào từ trước khi `securityhub.tf` tồn tại, và `prevent_destroy` không cho gỡ ra một cách vô tình. Để nguyên — vô hại vì layer `organization` luôn apply trước. Nhưng nó là **ngoại lệ lịch sử, không phải tiền lệ**.

Mô tả biến giờ tách rõ hai nhóm, và có `check "guardduty_admin_belongs_to_config_detective"` cảnh báo nếu khoá `guardduty.amazonaws.com` lọt vào map.

> **Bài học:** một danh sách gợi ý trong mô tả biến là **tài liệu có sức nặng ngang code** — nó là thứ người dùng đọc ngay lúc sắp gõ giá trị. Tôi liệt kê `guardduty.amazonaws.com` như một lựa chọn hợp lệ trong khi đang viết layer khác sở hữu chính việc đó. Danh sách phẳng che mất chuyện các mục trong nó không cùng loại.

---

### 7k. Lỗi 36 — điều kiện tiên quyết tôi tự nghĩ ra, và hai lệnh bác bỏ nó

Trước khi import Security Hub đang chạy vào state, phải biết cái gì đã tồn tại. Hai lệnh chạy từ management account:

```
aws securityhub describe-hub
  -> InvalidAccessException: Account 609320954321 is not subscribed to AWS Security Hub

aws securityhub list-organization-admin-accounts
  -> AccountId 458195083898   Status ENABLED
```

Hai dòng đó **không thể cùng đúng** nếu comment tôi viết ở `securityhub.tf` mục 1 là đúng:

> *"`EnableOrganizationAdminAccount` gọi từ management account, và đòi Security Hub đã bật ở chính account đó. Nên bước này đứng trước việc uỷ quyền, không phải sau."*

Uỷ quyền đang chạy. Management chưa từng subscribe. Điều kiện tiên quyết đó **không tồn tại** — tôi viết nó ra vì nó *nghe hợp lý*, không vì đo được.

**Điều thật sự đúng, cũng từ hai lệnh đó:** `AutoEnable: true` đã bật từ lâu ở delegated admin, mà management vẫn không subscribe. Nghĩa là **`auto_enable` không với tới management account** — nó chỉ phủ member account.

Nên resource `aws_securityhub_account.management` vẫn giữ, nhưng vì một lý do khác hẳn lý do tôi viết ban đầu: **không bật ở đó thì không ai bật nó**. Và đó là account đáng tiếc nhất nếu bỏ sót — nó giữ Organizations, SCP và hoá đơn, đồng thời là account duy nhất **SCP không bao giờ áp được**. Nó cần lớp phát hiện *hơn* các account khác, không phải kém hơn.

Hệ quả thực tế: khi import Security Hub sẵn có, ba resource import được, riêng dòng này **tạo mới** — một thay đổi thật, không phải import. Comment giờ nói thẳng điều đó và chỉ cách bỏ nếu không muốn.

`depends_on` giữ nguyên nhưng đổi lý do: không phải ràng buộc kỹ thuật lúc tạo, mà để **định thứ tự destroy** — gỡ uỷ quyền trước khi tắt Security Hub ở management.

> **Bài học:** lỗi 32 là câu dặn sai trong tài liệu vận hành; lỗi 36 là cùng loại nhưng nằm trong **comment giải thích code**, chỗ khó soi hơn nhiều vì không ai chạy comment. Cả hai đều là thứ tôi *suy ra* rồi viết như thể đã kiểm chứng. Khác biệt duy nhất giữa hai lỗi đó và phần còn lại của repo: ở đây có hai lệnh CLI hỏi thẳng dịch vụ, và tôi đã không chạy chúng trước khi viết.

---

## Liên quan

| | |
|---|---|
| [TEARDOWN](../landing-zone/TEARDOWN.md) | Chiều ngược lại — hai cổng khoá, parking account |
| [RUNBOOK](../landing-zone/RUNBOOK.md) | Làm gì, theo thứ tự nào — bảng lỗi ở cuối |
| [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md) | Vì sao chọn DIY, 4 SCP |
| [20 – Vận hành LZ](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Quy ước email, account baseline |
| [06 mục 1b](./06-Aws-Landing-Zone.md) | Root user vs organization root |
