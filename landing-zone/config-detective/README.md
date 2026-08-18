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

---

## Ba lỗi hay gặp

| Lỗi | Nguyên nhân |
|---|---|
| `InsufficientDeliveryPolicyException` | Bucket policy thiếu một trong hai statement `AWSConfigBucketPermissionsCheck` / `AWSConfigBucketDelivery`. Nếu bucket mã hoá KMS thì key policy **cũng phải** cho — thiếu một trong hai là fail, thông báo lỗi không chỉ ra thiếu chỗ nào |
| `AccessDeniedException` khi tạo organization rule | Thiếu `config-multiaccountsetup.amazonaws.com` |
| S3 rỗng sau 24 giờ | `aws configservice describe-delivery-channel-status` để xem lý do thật |

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
