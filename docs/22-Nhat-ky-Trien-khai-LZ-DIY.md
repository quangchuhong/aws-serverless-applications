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
| Default VPC | Đã xoá ở mọi account × mọi region |

**Thời gian thật:** ~3 giờ, trong đó phần lớn là gỡ 15 lỗi dưới đây. Đường đi sạch thì khoảng 1 giờ.

**Chi phí:** ~$0. S3 vài trăm KB, DynamoDB `PAY_PER_REQUEST`, Organizations/OU/SCP miễn phí.

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
| 15 | `Unsupported argument: stack_set_instance_region` | Dùng tên tham số của provider v6 trong layer khai `~> 5.0` | **Lỗi code** | `01d882a`+ |

**11/15 là lỗi trong code hoặc thiết kế của repo**, không phải người dùng làm sai. Đó là lý do file này tồn tại.

---

## 2. Sáu lỗi đáng học nhất

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

---

## 6. Sổ tay rút gọn

Nếu chỉ đọc một mục của file này, đọc mục này.

| Triệu chứng | Làm gì |
|---|---|
| `unrecognized service principal` | Rút `aws_service_access_principals` về tối thiểu, apply, thêm dần |
| `Backend initialization required` | Có `backend.tf` mà layer chưa apply → `rm backend.tf`, `init -reconfigure`, apply |
| `Unsetting the previously set backend` | Mất `backend.tf` → chạy `./wire-backends.sh`, nó tự dựng lại |
| `-backend-config was used without a "backend" block` | Như trên |
| `is tainted, so must be replaced` | `terraform untaint '<address>'` rồi plan lại |
| `Instance cannot be destroyed` (không có "tainted") | `create_organization` bị đổi về `false` → đặt lại `true` |
| Plan ra số resource **ít bất thường** | Thường là taint: thứ phụ thuộc nó thành *known after apply* nên rơi khỏi plan |
| SCP apply xong không thấy tác dụng | `scp_dry_run = true` — đúng thiết kế |
| Phép thử SCP ra **cùng lỗi ở cả hai** account | Phép thử hỏng, không phải SCP hỏng — xem mục 5c |
| `AccessDenied` mà không nêu tên policy | Có thể là identity policy chứ không phải SCP. Thử lại bằng principal admin |
| Branch diverged sau `git pull` | Đã commit file môi trường? Nay không cần sửa file track nào nữa |

---

## 7. Việc còn lại sau lần dựng này

Bảy giai đoạn của runbook đã đi hết, trừ giai đoạn 7 cố ý để sau.

| # | Việc | Trạng thái |
|---|---|---|
| 1 | 6 account + chuyển vào đúng OU | **Xong** — `list-parents` xác nhận cả 5 account thành viên đúng OU |
| 2 | 4 SCP | **Xong** — kiểm chứng 4/4, kể cả `prod_guard` |
| 3 | Xoá default VPC mọi account × mọi region | **Xong** — làm tay; sẽ phải làm lại cho account thứ 7 |
| 4 | Identity Center | **Xong** — `ssoins-8210168ac3d88c11`, identity store `d-9667ae9e62`, `ap-southeast-1` |
| 5 | `permission-sets` | **Xong** — 115 resource, xem mục 5b |
| 6 | `billing-guard` | **Xong** — budget, SNS đã xác nhận, anomaly. Còn `enable_cost_allocation_tags` khi có resource mang tag |
| 7 | **Layer `account-baseline`** | **Còn** — tự động hoá việc 1 và 3; ứng viên số một |
| 8 | `config-detective` | Còn — chỉ khi cần lớp phát hiện; layer duy nhất tốn tiền |

### Vì sao `account-baseline` là việc tiếp theo

Việc 1 và việc 3 đều đã làm xong **bằng tay**, và cả hai đều sẽ phải làm lại nguyên vẹn cho account thứ bảy:

| Việc tay | Quên thì hậu quả |
|---|---|
| `move-account` vào OU | Account chỉ còn SCP ở root — mất `network_lock` và `prod_guard` |
| Xoá default VPC ở mọi region | Một Internet Gateway mở sẵn, `network_lock` không đụng tới được |
| Thêm account ID vào `accounts_by_scope` | Không ai vào được account đó qua Identity Center |

Ba việc, không việc nào báo lỗi khi quên. Account vẫn chạy, chỉ là không có guardrail — đúng loại sai lệch lặng lẽ mà một landing zone sinh ra để ngăn.

Đó là lý do [doc 09](./09-Account-Vending-Tu-Dong.md) gọi đây là **account vending** và giao cho tự động hoá. Layer đó chưa có code.

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

  # Bo qua management account - khong assume vao chinh minh duoc
  [ "$id" = "$(aws sts get-caller-identity --query Account --output text)" ] && continue

  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::$id:role/OrganizationAccountAccessRole" \
    --role-session-name vpc-audit \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>/dev/null) || { echo "    (khong assume duoc)"; continue; }

  read -r AK SK ST <<<"$creds"
  for r in $ORG_REGIONS; do
    n=$(AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
        aws ec2 describe-vpcs --region "$r" --filters Name=isDefault,Values=true \
          --query 'length(Vpcs)' --output text 2>/dev/null)
    [ "$n" != "0" ] && echo "    $r: CON $n default VPC"
  done
done
```

Không in dòng `CON ... default VPC` nào, và cột cuối không có `ROOT` nào ngoài management account, là sạch.

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

## Liên quan

| | |
|---|---|
| [RUNBOOK](../landing-zone/RUNBOOK.md) | Làm gì, theo thứ tự nào — bảng lỗi ở cuối |
| [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md) | Vì sao chọn DIY, 4 SCP |
| [20 – Vận hành LZ](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Quy ước email, account baseline |
| [06 mục 1b](./06-Aws-Landing-Zone.md) | Root user vs organization root |
