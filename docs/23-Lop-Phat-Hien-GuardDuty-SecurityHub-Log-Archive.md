# Lớp phát hiện: GuardDuty, Security Hub và Log Archive

Ví dụ 23: GuardDuty và Security Hub hoạt động ra sao trong tổ chức nhiều account, mỗi tính năng trả tiền cho cái gì, và vì sao bucket log archive vẫn cần thiết dù không dịch vụ nào đọc nó.

> Code: [`landing-zone/config-detective/`](../landing-zone/config-detective/) (GuardDuty, Security Hub, Config) và [`landing-zone/org-trail/`](../landing-zone/org-trail/) (log archive).
>
> Bản HTML có sơ đồ: **[Lớp phát hiện](https://claude.ai/code/artifact/f42e8771-69c8-43e1-9777-ac9b64de4082)**
>
> Nhật ký lỗi khi dựng: [`22-Nhat-ky-Trien-khai-LZ-DIY.md`](./22-Nhat-ky-Trien-khai-LZ-DIY.md) mục 7h–7o.

---

## 0. Trạng thái triển khai

| Phần | Trạng thái |
|---|---|
| Config recorder + 8 organization rule | ✅ 5 account |
| Security Hub — uỷ quyền, aggregator, auto-enable | ✅ 5 resource, `0 to change` |
| GuardDuty — admin, org config, 5/5 member | ✅ `Enabled` |
| Đường cảnh báo EventBridge → SNS → email | ✅ Đã nhận email thật |
| Feature tính tiền của GuardDuty | ✅ `NONE` toàn bộ account thành viên |
| Standard của Security Hub | ✅ Rỗng, có chủ đích |
| Feature trên detector management account | ⬜ Chưa quản — SCP không chặn ở đó |
| Object Lock trên bucket trail | ⬜ `enable_object_lock = false` |
| Kiểm bucket log archive có object thật | ⬜ **Chưa chạy** |

---

## 1. Ba dịch vụ, ba câu hỏi không thay thế được nhau

Sai lầm hay gặp nhất là coi ba dịch vụ này chồng lấn nhau và chỉ cần bật một cái. Chúng trả lời ba câu hỏi khác hẳn, và câu trả lời của cái này không suy ra được từ cái kia.

| Dịch vụ | Câu hỏi | Không bao giờ thấy |
|---|---|---|
| **AWS Config** | Cấu hình có đúng chuẩn không? | Một EC2 instance đang đào coin — cấu hình của nó hoàn toàn đúng chuẩn |
| **GuardDuty** | Có hành vi bất thường đang xảy ra không? | Một bucket public không ai truy cập — không có hành vi nào để phân tích |
| **Security Hub** | Gom tất cả lại, rồi đẩy đi đâu? | Bất cứ gì, nếu không dịch vụ nào đẩy finding vào nó |

**Quan hệ phụ thuộc phải nhớ:** GuardDuty **không có đường cảnh báo riêng** trong kiến trúc này. Finding của nó đi nhờ Security Hub. Tắt Security Hub thì GuardDuty vẫn chạy, vẫn tính tiền, và không ai nhận được gì. `check "guardduty_findings_reach_someone"` bắt đúng trường hợp đó.

---

## 2. Đường đi của một finding

```
lz-app-dev ─┐
lz-app-prod ─┤
lz-network  ─┼──> GuardDuty admin ────┐
lz-logarchive┤    (lz-security)       │
management  ─┘                        ├──> Security Hub ──> EventBridge ──> SNS ──> email
                                      │    (ASFF, gom      (loc severity      │
             └──> Config aggregator ──┘     cross-region)    + $or)           └──> Slack (tuy chon)
                  8 organization rule
```

Điểm cần nhìn ra: **không có mũi tên nào đi thẳng từ GuardDuty tới SNS.** Cả hai nguồn đều phải qua Security Hub, và cả hai đều phải lọt qua đúng một EventBridge rule. Rule đó là chỗ hẹp nhất của toàn bộ hệ thống — xem mục 6.

---

## 3. GuardDuty — mô hình tổ chức

GuardDuty là dịch vụ **theo account và theo region**. Mỗi account có detector riêng. Cái làm cho nó thành lớp phòng thủ cấp tổ chức là mô hình delegated administrator.

### 3.1 Bốn tầng, và tầng nào là chính sách còn tầng nào là sự kiện

| Tầng | Resource | Nó thật sự làm gì |
|---|---|---|
| Uỷ quyền | `aws_guardduty_organization_admin_account` | Chỉ định `lz-security` làm admin, gọi từ management account. Lệnh này **tự đăng ký** delegated administrator ở Organizations — không cần khai trong `delegated_administrators` |
| Detector | `aws_guardduty_detector` | Công tắc bật trong một account + region. Management account cần detector riêng mới được kết nạp |
| **Chính sách** | `aws_guardduty_organization_configuration` | `auto_enable_organization_members = ALL` — *ý định* cho account hiện tại và tương lai |
| **Sự kiện** | `aws_guardduty_member` | Thứ thực sự tạo ra member |

> **Chính sách ≠ sự kiện.** Trên chính tổ chức này, chính sách nói `ALL`, uỷ quyền trọn vẹn, và sau **hơn 25 phút** `list-members` vẫn rỗng — GuardDuty chỉ giám sát đúng một account. Chỉ `aws_guardduty_member` tạo ra 5 member. Xem lỗi 41 doc 22.

### 3.2 Nguồn dữ liệu nền — luôn chạy, không tắt được

| Nguồn | Phát hiện được gì |
|---|---|
| `CLOUD_TRAIL` | Credential dùng từ IP hoặc quốc gia lạ, gọi API qua Tor, thay đổi bất thường ở IAM, tắt CloudTrail, tạo user ngoài giờ |
| `DNS_LOGS` | Máy trong VPC hỏi tên miền của C&C, DGA, hoặc pool đào coin. Nguồn bắt được nhiều mã độc nhất |
| `FLOW_LOGS` | Kết nối tới địa chỉ đã biết là độc hại, quét cổng, luồng ra bất thường — dấu hiệu dữ liệu đang bị rút |

Ba nguồn này không nằm trong danh sách feature, không tắt được, và tiền ở mức nền tính theo **khối lượng log phân tích** từ chúng.

### 3.3 Feature — mỗi cái một nguồn dữ liệu, một dòng hoá đơn

| Feature | Phân tích cái gì | Chi phí |
|---|---|---|
| `S3_DATA_EVENTS` | Truy cập dữ liệu trong S3 — rút dữ liệu hàng loạt, đọc bucket từ IP lạ. Tính theo **số sự kiện data plane** | ●●● |
| `EBS_MALWARE_PROTECTION` | Khi có finding nghi ngờ trên EC2, chụp snapshot EBS và quét mã độc. Tính theo **GB đã quét** | ●●● |
| `RUNTIME_MONITORING` | Agent trong EC2, ECS Fargate và EKS — nhìn được tiến trình và syscall, thứ log ngoài không thấy | ●●● |
| `EKS_AUDIT_LOGS` | Audit log của Kubernetes control plane — leo thang quyền, pod privileged, service account bị lạm dụng | ●●○ |
| `RDS_LOGIN_EVENTS` | Đăng nhập bất thường vào Aurora — brute force, đăng nhập thành công từ nơi chưa từng thấy | ●○○ |
| `LAMBDA_NETWORK_LOGS` | Luồng mạng của Lambda — hàm bị chèn mã gọi ra ngoài, thứ Flow Log thường không phủ | ●○○ |

**Mặc định của layer này là tắt hết** — và "tắt" ở đây là **tường minh**: code khai cả sáu theo hai chiều, vì AWS **bật sẵn** phần lớn chúng khi tạo detector. Danh sách rỗng chỉ có nghĩa *"Terraform không quản"*, không phải *"tắt"*. Đó là lỗi 37.

**Cách bật đúng:** từng cái một, đo một tuần ở Cost Explorer (`Service = Amazon GuardDuty`, group by Linked Account), rồi mới thêm cái tiếp theo. Mỗi account có 30 ngày dùng thử riêng cho mỗi region, nên hoá đơn tháng đầu **không phản ánh** chi phí thật.

---

## 4. GuardDuty đọc log ở đâu — không phải bucket của bạn

Hiểu nhầm phổ biến nhất về GuardDuty: rằng nó đọc CloudTrail bucket hoặc VPC Flow Log mà bạn đã cấu hình. Nó **không đọc một byte nào** từ đó.

| Nguồn nền | GuardDuty lấy từ đâu | Bucket log archive |
|---|---|---|
| `CLOUD_TRAIL` | Luồng **riêng, độc lập** bên trong AWS | không đọc |
| `FLOW_LOGS` | Bản sao **riêng** — không cần bạn bật VPC Flow Log | không đọc |
| `DNS_LOGS` | Route 53 Resolver, chỉ GuardDuty truy cập được | không tồn tại ở đó |

### 4.1 Bốn hệ quả thực tế

1. **Xoá trail hay xoá bucket không làm GuardDuty mù.** Nó vẫn phân tích như thường. Hai thứ đó phục vụ hai mục đích khác nhau — xem mục 8.
2. **Không cần bật VPC Flow Log** để GuardDuty thấy luồng mạng. Nhiều nơi bật Flow Log tốn tiền vì tưởng GuardDuty cần nó.
3. **Không có quyền IAM nào phải cấp** cho GuardDuty trên bucket log archive, và bucket đó không phát sinh phí request vì GuardDuty.
4. **Chi phí tính theo khối lượng log AWS phân tích**, không theo dung lượng bucket của bạn.

### 4.2 `S3_DATA_EVENTS` cũng không đọc nội dung

Feature này theo dõi **ai truy cập cái gì** — `GetObject`, `PutObject`, `DeleteObject` — cũng từ một luồng CloudTrail data event riêng của AWS. Nghĩa là bật nó **không** buộc bạn bật S3 data event trên trail của mình, thứ rất đắt.

Chỗ đáng cân nhắc: bật nó sẽ giám sát truy cập vào **chính bucket giữ bằng chứng**. SCP hiện chặn `cloudtrail:DeleteTrail` nhưng **không chặn** `s3:DeleteObject` — đây là phần còn lại của lỗi 34.

| Cách bịt | Ngăn hay phát hiện | Chi phí |
|---|---|---|
| **Object Lock** trên bucket trail | **Ngăn** — không ai xoá được, kể cả root | $0 |
| Thêm `s3:DeleteObject` vào SCP `ProtectAuditTrail`, giới hạn theo ARN bucket | **Ngăn** | $0 |
| `S3_DATA_EVENTS` | **Phát hiện** — sau khi đã xảy ra | theo số sự kiện |

Hai cách đầu nên làm trước: miễn phí, và ngăn chặn thật thay vì báo sau.

> Dễ nhầm tên: **Malware Protection for S3** *có* quét nội dung object, nhưng đó là dịch vụ riêng bật theo từng bucket, khác hẳn `EBS_MALWARE_PROTECTION` ở mục 3.3. Repo này chưa dùng.

---

## 5. Security Hub — nơi gom, không phải nơi phát hiện

Security Hub có hai vai trò tách bạch, và trong kiến trúc này chỉ vai trò thứ nhất được dùng. Nhầm lẫn giữa hai vai trò đó là cách nhanh nhất để hoá đơn vượt xa dự tính.

| | Vai trò 1 — nơi gom ✅ | Vai trò 2 — standard tuân thủ ⬜ |
|---|---|---|
| Làm gì | Nhận finding từ GuardDuty, Config, Inspector, Macie, Access Analyzer; quy về **ASFF**; gom cross-account và cross-region; phát sự kiện lên EventBridge | FSBP, CIS, NIST 800-53, PCI DSS — mỗi standard tự chạy **hàng trăm control** liên tục trên mọi resource |
| Chi phí | Không đáng kể | **Số lần kiểm tra × số account × số region** — phần đắt nhất, đắt hơn Config nhiều |
| Cần cho đường cảnh báo? | **Có, và chỉ cần cái này** | Không |

Bật standard chỉ khi muốn độ phủ tương đương *detective control* của Control Tower (xem [doc 21](./21-Control-Tower-vs-DIY.md)). Đó là một quyết định chi phí riêng, không phải phần đi kèm của đường cảnh báo.

### 5.1 Finding aggregator — chỗ mù dễ quên nhất

Security Hub theo region. Không có aggregator thì phải mở console từng region mới thấy hết. Cấu hình ở đây gom `us-east-1` về `ap-southeast-1` — và `us-east-1` quan trọng vì đó là nơi IAM, CloudFront và sự kiện billing đổ về.

### 5.2 Tự bật cho account thành viên

| Thiết lập | Giá trị | Nghĩa là gì |
|---|---|---|
| `auto_enable` | `true` | Account tạo sau tự được bật. Thứ gì phải nhớ làm tay cho từng account mới thì sớm muộn cũng bị quên |
| `auto_enable_standards` | `NONE` | Chỉ nhận `DEFAULT` hoặc `NONE`. `DEFAULT` bật FSBP trên *mọi* account thành viên — đường nhanh nhất để hoá đơn vượt Config. `NONE` **không** làm yếu cảnh báo: member vẫn được bật Security Hub và vẫn gửi finding của Config, GuardDuty về admin |

---

## 6. Hai hình dạng finding — và vì sao bộ lọc phải biết cả hai

Đây là chi tiết kỹ thuật quan trọng nhất trong tài liệu này, vì nó từng chặn đứng toàn bộ cảnh báo GuardDuty mà không báo lỗi nào (lỗi 40).

**Finding tuân thủ** sinh từ *control*. Câu hỏi là "đúng chuẩn hay không", nên nó mang trường `Compliance.Status`:

```json
{ "Severity": { "Label": "HIGH" },
  "Compliance": { "Status": "FAILED" } }
```

**Finding hành vi** sinh từ *phát hiện*. Không kiểm tra tuân thủ, nên **không có** trường đó:

```json
{ "Severity": { "Label": "HIGH" },
  "Compliance": null }
```

GuardDuty, Inspector, Macie, IAM Access Analyzer đều rơi vào nhánh thứ hai.

> **Vì sao im lặng:** EventBridge — **khoá không tồn tại trong event thì pattern không khớp**. Một rule lọc `Compliance.Status = ["FAILED"]` sẽ loại bỏ *toàn bộ* finding hành vi. Không lỗi, không cảnh báo, không dấu vết. GuardDuty vẫn chạy và vẫn tính tiền.

Bộ lọc đúng phải hỏi hai câu khác nhau cho hai hình dạng:

```hcl
event_pattern = {
  source        = ["aws.securityhub"]
  "detail-type" = ["Security Hub Findings - Imported"]
  detail = { findings = {
    RecordState = ["ACTIVE"]
    Workflow    = { Status = ["NEW", "NOTIFIED"] }
    Severity    = { Label = ["CRITICAL", "HIGH"] }

    "$or" = [
      { Compliance = { Status = ["FAILED", "WARNING"] } },   # tuan thu
      { Compliance = { Status = [{ exists = false }] } },    # hanh vi
    ]
  } }
}
```

Bỏ hẳn dòng `Compliance` cũng "chạy được", vì finding `PASSED` thường mang severity `INFORMATIONAL` nên rơi khỏi bộ lọc severity. Nhưng đó là dựa vào một **trùng hợp**, không phải một điều kiện — và lớp cảnh báo không nên đứng trên trùng hợp.

---

## 7. Ba điểm mù, đo được trên tổ chức thật

Không cái nào báo lỗi. Cả ba đều để lại một hệ thống *trông như đang hoạt động*.

| Điểm mù | Triệu chứng | Cách vào đúng |
|---|---|---|
| **Management account** | Cơ chế tự bật **không với tới** nó. Security Hub: không subscribe. GuardDuty: `CreateMembers` trả HTTP 200 rồi không tạo gì | Mỗi dịch vụ cần resource riêng cho account này — `aws_securityhub_account.management` và `aws_guardduty_detector.management`. Đây là account giữ Organizations, SCP và hoá đơn, đồng thời là account duy nhất SCP không bao giờ áp được |
| **Ghi danh member** | `ALL` ở mọi tầng, uỷ quyền trọn vẹn, mà `list-members` rỗng sau 25 phút | Ghi danh tường minh bằng `aws_guardduty_member`. Trong code thì `terraform plan` trả lời được câu "có account nào chưa được giám sát không" |
| **SCP chặn chính Terraform** | `AccessDeniedException … explicit deny in a service control policy` khi đổi feature ở account thành viên | Guardrail cấm `guardduty:UpdateDetector` — API **duy nhất** để đổi feature. Chặn việc tắt feature là **đúng**. **Đừng** miễn trừ `OrganizationAccountAccessRole`: đó là chìa khoá vạn năng vào mọi member account |

---

## 8. Log archive — chiều thời gian còn lại

Nếu GuardDuty không đọc bucket log archive, nó tồn tại để làm gì? Vì hai hệ thống trả lời hai câu hỏi ở **hai chiều thời gian khác nhau**.

| | Câu hỏi | Khoảng thời gian |
|---|---|---|
| GuardDuty + Security Hub | Có gì **đang** xảy ra? | hiện tại — finding giữ 90 ngày |
| Log archive | Chuyện gì **đã** xảy ra, ai làm, lúc nào? | nhiều tháng đến nhiều năm |

> **Bất đối xứng quyết định mọi thứ: lớp phát hiện thay thế được, log thì không tái tạo được.**
>
> Bật GuardDuty ngày mai thì mai nó chạy. Không thu CloudTrail của hôm qua thì hôm qua **mất vĩnh viễn**. Đó là lý do bucket này phải có từ ngày đầu — trước cả GuardDuty — và cũng là lý do `org-trail` đứng sớm trong thứ tự dựng của [RUNBOOK](../landing-zone/RUNBOOK.md).

### 8.1 Bốn việc nó làm mà lớp phát hiện không làm được

| Vai trò | Vì sao finding không thay được |
|---|---|
| **Điều tra sau sự cố** | GuardDuty nói *"credential X dùng từ IP Y lúc T"*. Đó là một tín hiệu, không phải một cuộc điều tra. Câu hỏi thật luôn là *"credential đó còn làm gì nữa, ở account nào, trong sáu tháng qua"* — chỉ trail thô trả lời được |
| **Bằng chứng ngoài tầm với** | Đây là lý do nó là **một account riêng**, không phải một bucket riêng. Kẻ chiếm được `lz-app-prod` không chạm tới `lz-logarchive` — khác credential, khác ranh giới. Không tách account thì kẻ tấn công xoá được dấu vết của chính nó |
| **Tuân thủ** | ISO, SOC 2, PCI đều đòi audit log lưu giữ N tháng và chống sửa. Finding của GuardDuty không đáp ứng — nó là *kết luận*, không phải bản ghi gốc |
| **Phân tích ngoài AWS** | Athena query thẳng trên trail, hoặc đẩy vào SIEM. GuardDuty chỉ phát hiện thứ mô hình của AWS phát hiện được; câu hỏi riêng của tổ chức phải tự hỏi trên dữ liệu thô |

### 8.2 Cấu hình hiện tại

```
quh11-lz-cloudtrail-654560867047        API call moi account, moi region
quh11-lz-config-snapshots-654560867047  lich su cau hinh resource

lifecycle    30 ngay -> STANDARD_IA    90 ngay -> GLACIER_IR
versioning   bat, ban cu don sau 90 ngay
object lock  TAT  (enable_object_lock = false)
```

Chi phí gần như không đáng kể — đây là một trong những control rẻ nhất của cả Landing Zone.

Nhưng `enable_object_lock = false` nghĩa là bucket hiện **tamper-evident** (versioning giữ bản cũ) chứ chưa **tamper-proof**. Ai có quyền vẫn xoá được cả version. Kết hợp với lỗ hổng `s3:DeleteObject` ở mục 4.2, bằng chứng vẫn còn một đường bị xoá.

Nếu bật Object Lock, nhớ ràng buộc đã có `check` bắt: `log_retention_days` phải **lớn hơn** `object_lock_retention_days`. Nhỏ hơn thì lifecycle cố xoá object bị khoá, thất bại lặng lẽ, và object không bao giờ được dọn.

---

## 9. Kiểm chứng — hỏi thẳng dịch vụ

`terraform plan` nói về *ý định*. Những lệnh dưới đây nói về *trạng thái*. Trong lần dựng này, hai thứ đó đã lệch nhau bốn lần.

| Câu hỏi | Lệnh | Câu trả lời đúng |
|---|---|---|
| Uỷ quyền GuardDuty có chưa? | `guardduty list-organization-admin-accounts` | `ENABLED` |
| Account nào *thật sự* được giám sát? | `guardduty list-members --only-associated false` | 5 dòng `Enabled` |
| Feature nào đang tính tiền? | `guardduty get-detector --query 'Features'` | Chỉ ba nguồn nền |
| Security Hub có sống không? | `securityhub describe-hub` | Ra `HubArn` |
| Có standard nào đang chạy không? | `securityhub get-enabled-standards` | `[]` |
| Email đã xác nhận chưa? | `sns list-subscriptions-by-topic` | ARN kết thúc bằng UUID |
| Bằng chứng có *thật sự* được lưu không? | `s3 ls s3://quh11-lz-cloudtrail-… --recursive` | Có object, không rỗng |

> **Lệnh cuối dễ bỏ quên nhất.** Một bucket lưu trữ rỗng vẫn có đủ mọi thứ — lifecycle, versioning, tách account, bucket policy — và **không có giá trị nào**. Rỗng sau 24 giờ gần như luôn là bucket policy hoặc quyền KMS, không phải trail chưa chạy:
>
> ```bash
> aws configservice describe-delivery-channel-status --profile <log-archive>
> ```

### 9.1 Phép thử duy nhất đáng tin

Bảy lệnh trên hỏi **từng mắt xích**. Chỗ đứt thường nằm ở **chỗ nối** — nơi không lệnh nào soi tới. Chỉ một sự kiện thật đi hết đường mới trả lời được:

```bash
aws guardduty create-sample-findings --detector-id <id> \
  --finding-types 'CryptoCurrency:EC2/BitcoinTool.B!DNS' \
  --profile lz-security --region ap-southeast-1
```

Finding mẫu này ở mức **HIGH**, nằm trong bộ lọc severity. Có email trong vài phút = cả chuỗi sống. Không có = có một mắt xích đang đứt, và không cấu hình nào nói cho bạn biết.

Đây cũng là cách bốn lỗi cùng họ được đóng lại — 28, 33, 38 và 40 — mỗi lần bằng một sự kiện thật đi tới một người thật.

---

## Liên quan

| | |
|---|---|
| [22 – Nhật ký triển khai LZ DIY](./22-Nhat-ky-Trien-khai-LZ-DIY.md) | 42 lỗi và cách phát hiện — mục 7h–7o là phần lớp phát hiện |
| [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md) | Detective control của Control Tower tương đương gì ở đây |
| [11 – Tag Policy và Cost Allocation](./11-Tag-Policy-va-Cost-Allocation.md) | Đo chi phí theo account bằng cost allocation tag |
| [19 – Permission Set cho LZ](./19-Permission-Set-cho-Landing-Zone.md) | Lỗi 34 — quyền chạm tới account giữ bằng chứng |
| [RUNBOOK](../landing-zone/RUNBOOK.md) | Thứ tự dựng, giai đoạn 7 |
| [config-detective](../landing-zone/config-detective/) | Code |
