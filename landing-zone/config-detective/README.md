# Config Detective

Lớp **phát hiện** cho LZ. Chạy ở **management account**, assume role sang security + log archive.

**Mặc định TẮT** (`enable = false`) — `terraform plan` ra 0 resource.

---

## Vì sao có layer này

SCP ở [`../organization`](../organization/) **ngăn** hành động. Nó không trả lời được *"hiện tại có bao nhiêu resource đang sai"*.

```
SCP          →  chặn CreateInternetGateway
Config rule  →  phát hiện IGW ĐANG TỒN TẠI
```

Hai lớp bù cho nhau, và danh sách `resource_types` mặc định được chọn **đối xứng với 4 SCP**:

| SCP | Config ghi loại gì |
|---|---|
| `network_lock` | `InternetGateway`, `NatGateway`, `SecurityGroup`, `VPC`, `RouteTable` |
| `baseline` | `IAM::Role`, `IAM::User`, `IAM::Policy`, `CloudTrail::Trail` |
| `prod_guard` | `S3::Bucket`, `KMS::Key`, `RDS::DBInstance` |

---

## Bốn cần gạt chi phí

Config tính theo **configuration item ghi được** + **rule evaluation**. Mặc định của layer này đã đặt cả bốn ở mức tiết kiệm:

| # | Cần gạt | Mặc định | Tác động |
|---|---|---|---|
| 1 | `recording_frequency` | **`DAILY`** | **Lớn nhất** — thay vì ghi mỗi lần resource đổi |
| 2 | Chọn account (`recorder_target_ous`) | Bạn khai — **đừng đưa Sandbox/Dev** | Dev là nơi đổi nhiều nhất = đắt nhất |
| 3 | Chọn region | 1 region cho recorder | Config là per-region |
| 4 | Chọn resource type | 13 loại, **không** `all_supported` | Mỗi loại thêm = thêm CI |

Vài loại vẫn cần biết ngay, nên chúng được để riêng ở chế độ liên tục:

```hcl
continuous_recording_types = [
  "AWS::EC2::SecurityGroup",   # thay doi port
  "AWS::IAM::Role",            # thay doi quyen
  "AWS::IAM::Policy",
]
```

---

## Quyết định kiến trúc: không làm EventBridge fan-in

Config managed rule **tự đẩy finding vào Security Hub**, và Security Hub đã gom sẵn cross-account + cross-region qua delegated admin. Làm thêm một đường EventBridge riêng cho "Config non-compliant" là **làm lại đúng việc đó**, và phải triển khai rule + IAM role ở **mỗi account × mỗi region**.

```
Config rule vi phạm
   └─► Security Hub (delegated admin, tự gom mọi account/region)
         └─► EventBridge rule TẠI security account
               ├─► SNS ─► email
               └─► Lambda ─► Slack   (tuỳ chọn)
```

Lợi thêm: cùng đường này gom luôn GuardDuty, Inspector, Macie — không phải làm riêng từng service.

---

## Có gì

| Thành phần | Ở đâu | Ghi chú |
|---|---|---|
| S3 + **Object Lock** | Log archive | Chỉ bật được lúc tạo bucket |
| StackSet → recorder | Management → OU đích | `auto_deployment`: account mới tự có |
| **Aggregator** | Security | Mảnh thiếu trong sơ đồ ban đầu |
| `aws_config_organization_managed_rule` | Security | **Một** resource, áp cho **mọi** account |
| EventBridge + SNS + Lambda | Security | Đọc Security Hub findings |

### Vì sao dùng organization rule chứ không phải rule từng account

`aws_config_organization_managed_rule` triển khai từ delegated admin cho **toàn tổ chức**. Không nhân lên theo số account, và account mới tự động được áp mà không cần chạy lại gì.

---

## Điều kiện tiên quyết

Trước khi `enable = true`:

```hcl
# landing-zone/organization/terraform.tfvars
delegated_administrators = {
  "config.amazonaws.com"                  = "<security-account-id>"
  "config-multiaccountsetup.amazonaws.com" = "<security-account-id>"
  "securityhub.amazonaws.com"             = "<security-account-id>"
}
```

> **Hai dòng `config` là hai service principal khác nhau và đều cần.** Thiếu dòng thứ hai thì `aws_config_organization_managed_rule` báo `AccessDeniedException` mà **không nói rõ thiếu gì** — đây là lỗi mất nhiều thời gian nhất trong cả layer. Layer `organization` có `check` block bắt việc này.

### Và phải bật Security Hub — nếu không thì không có cảnh báo nào

`notify.tf` lọc sự kiện theo `source = ["aws.securityhub"]`. Layer này **không bật Security Hub**, nó chỉ đọc findings từ đó.

```
Config rule vi pham  ──►  Security Hub  ──►  EventBridge  ──►  SNS
                            ▲
                     CHUA BAT = day dut o day
```

Security Hub chưa bật thì mọi thứ khác vẫn chạy đúng: recorder ghi, rule đánh giá, file vào S3, aggregator gom dữ liệu. **Chỉ là không một cảnh báo nào được gửi** — không lỗi, không cảnh báo, chỉ im lặng.

Ba lệnh, ở **hai account khác nhau**, đúng thứ tự — lặp cho mỗi region trong `aggregator_regions`:

```bash
# 1. TU MANAGEMENT ACCOUNT
aws securityhub enable-organization-admin-account \
  --admin-account-id <security-account-id> --region ap-southeast-1

# 2. TU SECURITY ACCOUNT
aws securityhub enable-security-hub --no-enable-default-standards \
  --profile <security> --region ap-southeast-1

# 3. TU SECURITY ACCOUNT
aws securityhub update-organization-configuration --auto-enable \
  --auto-enable-standards NONE \
  --profile <security> --region ap-southeast-1
```

**Bỏ bước 1** thì bước 3 báo `InvalidAccessException: Account <id> is not an administrator for this organization`. Đăng ký delegated administrator ở tầng Organizations là **cần nhưng chưa đủ**: Security Hub có cơ chế chỉ định riêng và nó chỉ gọi được từ management account. GuardDuty cũng vậy. Config thì không cần.

**Hai cờ standard là bắt buộc.** `enable-security-hub` mặc định bật AWS FSBP + CIS, tính tiền theo số lần kiểm tra — vài trăm control chạy liên tục trên mọi resource. Đó là phần đắt nhất của Security Hub, đắt hơn Config nhiều, và layer này **không cần** standard nào.

Lỡ bật rồi:

```bash
aws securityhub get-enabled-standards --profile <security> --region ap-southeast-1
aws securityhub batch-disable-standards \
  --standards-subscription-arns <arn> --profile <security> --region ap-southeast-1
```

Kiểm chứng đường ống trước khi tin nó:

```bash
aws securityhub get-findings --max-items 1 \
  --profile <security> --region ap-southeast-1 \
  --query 'Findings[0].[Title,Compliance.Status]'
```

> **Security Hub có chi phí riêng**, tính theo số lần kiểm tra và số finding nạp vào — không nằm trong ước tính chi phí của Config bên trên. Bật kèm security standard (CIS, AWS FSBP) sẽ tốn thêm đáng kể; layer này **không cần** standard nào, chỉ cần Security Hub bật để nhận findings từ Config.

---

## Chạy

```bash
cd landing-zone/config-detective
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan     # enable = false -> 0 resource

# sau khi dien account id + OU id
# enable = true
terraform apply
```

---

## Kiểm chứng

```bash
# 0. Duong canh bao co ai o dau kia khong
aws sns list-subscriptions-by-topic --topic-arn <alert_topic> \
  --profile <security> --region ap-southeast-1 \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table

# 1. Recorder da chay chua
aws configservice describe-configuration-recorder-status \
  --profile <account> --region ap-southeast-1
# recording: true, lastStatus: SUCCESS

# 2. File da vao S3 chua (doi ~24h voi TwentyFour_Hours)
aws s3 ls s3://<bucket>/ --recursive --profile <log-archive> | head

# 3. Trang thai tuan thu tu aggregator
aws configservice describe-aggregate-compliance-by-config-rules \
  --configuration-aggregator-name acme-lz-org \
  --profile <security> --region ap-southeast-1
```

Bước 3 quan trọng nhất: rule ở trạng thái **`INSUFFICIENT_DATA`** nghĩa là recorder **không ghi** loại resource mà rule đó kiểm tra. Nó **im lặng**, và rất dễ nhầm là "mọi thứ đều ổn". Có `check` block bắt trường hợp rule `s3-*` mà không ghi `AWS::S3::Bucket`.

### Bước 0: thứ Terraform không kiểm được

Cột `SubscriptionArn` phải là một ARN kết thúc bằng UUID. Hai giá trị khác đều nghĩa là **không ai nhận được cảnh báo nào**:

| Giá trị | Nghĩa là | Chữa |
|---|---|---|
| `PendingConfirmation` | Chưa bấm link trong thư | Bấm link |
| `Deleted` | SNS đã vứt subscription đi | Xem phần dưới — **đừng vội `-replace`** |

### `Deleted` — phân biệt hai nguyên nhân trước khi sửa

`Deleted` có hai nguồn hoàn toàn khác nhau, và chữa nhầm thì lặp vô hạn:

1. Subscription chưa xác nhận **quá 3 ngày** — SNS tự dọn
2. **Địa chỉ đó bị SNS chặn ở topic này** — do có người từng bấm *"unsubscribe"* trong một thư từ chính topic đó

Trường hợp 2 nhìn y hệt trường hợp 1, nhưng `-replace` **không bao giờ** sửa được: SNS nhận `Subscribe`, trả về `"pending confirmation"`, rồi xoá ngay trong vài phút.

> **Chặn theo topic, không phải theo địa chỉ.** Cùng địa chỉ đó vẫn đăng ký bình thường vào topic khác, kể cả ở account khác — nên "email của tôi vẫn nhận cảnh báo billing đấy thôi" **không** loại trừ được trường hợp 2.

Phân biệt bằng một phép thử, không phải bằng suy luận — đăng ký một địa chỉ **khác** vào **cùng topic**, cùng lúc. Plus-addressing của Gmail là lý tưởng: cùng hộp thư, nhưng với SNS là endpoint khác hẳn.

```bash
aws sns subscribe --topic-arn <alert_topic> --protocol email \
  --notification-endpoint <ban>+lztest@gmail.com \
  --profile <security> --region ap-southeast-1

sleep 60   # ListSubscriptionsByTopic la eventually consistent

aws sns list-subscriptions-by-topic --topic-arn <alert_topic> \
  --profile <security> --region ap-southeast-1 \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
```

| Kết quả | Nguyên nhân | Chữa |
|---|---|---|
| Địa chỉ mới `PendingConfirmation`, cũ `Deleted` | Địa chỉ cũ **bị chặn** | Đổi `alert_emails` sang endpoint khác rồi `terraform apply`. **Không có API gỡ chặn cho email** — phải qua AWS Support |
| Cả hai `Deleted` | Vấn đề ở topic hoặc account | Không phải chuyện địa chỉ — xem policy của topic |
| Địa chỉ cũ biến mất khỏi bảng | Chỉ là bản ghi cũ chưa dọn xong | Không phải lỗi. `sleep 60` là thứ thiếu |

> **Bản ghi cũ còn nằm đó thì phép thử đọc sai.** Một dòng `Deleted` sót lại trông hệt như trường hợp 2, và `Subscribe` cho cùng endpoint sẽ **khớp vào bản ghi cũ** thay vì tạo mới — `-replace` khi đó trả về đúng UUID cũ và không có thư nào được gửi.
>
> Nên trình tự đúng là: `aws sns unsubscribe` bản ghi cũ → chờ tới khi nó **biến mất khỏi bảng** (không phải tới khi nó ghi `Deleted`) → rồi mới `Subscribe` lại. Chỉ lúc đó kết quả mới đọc được.

> Đây chính là ca đã gặp trong lần dựng thật. Bốn giả thuyết suông đều sai; thứ giải được nó là phép thử trên, chạy lại sau khi bản ghi cũ đã sạch. Xem [doc 22](../../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md).

> **Cảnh báo bảo mật của cả tổ chức không nên gắn vào email cá nhân.** Một lần ai đó bấm "unsubscribe" là mù toàn hệ thống, và không có API nào gỡ lại. Một distribution list an toàn hơn hẳn.

> **`terraform plan` không bắt được trường hợp này.** Đo được trong lần dùng thật:
>
> ```
> terraform state  ->  ARN thật, kết thúc bằng UUID
> terraform plan   ->  No changes          (Terraform nói ON)
> SNS              ->  Deleted             (không ai nhận gì)
> ```
>
> Provider truyền `ReturnSubscriptionArn=true`, nên SNS trả ARN thật **ngay cả khi chưa xác nhận**. State giữ ARN đó, và khi SNS xoá subscription chưa xác nhận thì `plan` vẫn sạch.
>
> Đây không phải drift mà `plan` phát hiện được. Là drift mà `plan` **khẳng định là không có** — và không `lifecycle` hay `check` block nào sửa được, vì Terraform không có data source đọc subscription của SNS. Cách duy nhất là hỏi thẳng SNS.

> **`-replace` chưa chắc đã sửa được.** SNS `Subscribe` với cùng topic + protocol + endpoint có thể trả về **đúng ARN cũ** thay vì tạo mới. Terraform in ra `1 added, 1 destroyed` với **cùng một UUID ở cả hai dòng**, trong khi bên SNS không đổi gì. Log của Terraform không phải bằng chứng — chỉ `list-subscriptions-by-topic` mới là.

> **Đừng dùng `aws sns publish` để kiểm.** Nó trả về `MessageId` kể cả khi topic không có subscriber nào. Lệnh báo OK, số hiệu thư có thật, thư rơi vào hư không.

---

## Ba lỗi hay gặp

| Lỗi | Nguyên nhân |
|---|---|
| `InsufficientDeliveryPolicyException` | Bucket policy thiếu một trong hai statement `AWSConfigBucketPermissionsCheck` / `AWSConfigBucketDelivery`. Nếu bucket mã hoá KMS thì key policy **cũng phải** cho — thiếu một trong hai là fail, thông báo lỗi không chỉ ra thiếu chỗ nào |
| `AccessDeniedException` khi tạo organization rule | Thiếu `config-multiaccountsetup.amazonaws.com` |
| S3 rỗng sau 24 giờ | `aws configservice describe-delivery-channel-status` để xem lý do thật |
| `plan` sạch mà cảnh báo không tới | Email subscription bị SNS xoá sau 3 ngày chưa xác nhận — xem bước 0 |

---

## Đo chi phí trước khi mở rộng

```
Cost Explorer → lọc Service = "AWS Config" → group by Linked Account
```

Chạy **một tuần** rồi mới mở rộng, và mở **từng thứ một**: thêm region, **hoặc** thêm resource type, **hoặc** bỏ `DAILY`. Mở hai thứ cùng lúc thì không biết cái nào làm tăng.

---

## Xoá

```bash
terraform destroy
```

Bucket có `prevent_destroy` — destroy sẽ fail, đúng thiết kế.

> **Object Lock ở chế độ COMPLIANCE không gỡ được.** Object đã ghi phải trả tiền lưu trữ đủ hết hạn, không xoá sớm được bằng bất kỳ cách nào — kể cả root, kể cả đóng account. Cân nhắc `object_lock_retention_days` cho kỹ.

---

## Liên quan

| | |
|---|---|
| [Doc 21 – Control Tower vs DIY](../../docs/21-Control-Tower-vs-DIY.md) | Thế đối xứng SCP ↔ Config |
| [`../organization`](../organization/) | SCP + delegated administrator |
| [Doc 06 mục 9](../../docs/06-Aws-Landing-Zone.md) | Security tooling, Security Hub |
