# Org Trail

Organization CloudTrail cho LZ. Chạy ở **management account**, assume role sang log archive.

**Mặc định TẮT** (`enable = false`) — `terraform plan` ra 0 resource.

---

## Vì sao có layer này

Layer này ra đời **vì lớp phát hiện tìm ra chỗ thiếu**, không phải vì ai đọc tài liệu thiết kế rồi nghĩ ra.

Ngày đầu tiên `config-detective` chạy, rule `cloud-trail-enabled` ra `NON_COMPLIANT` ở **mọi account**. Toàn bộ repo không có một resource `aws_cloudtrail` nào, trong khi ba tầng khác đã chuẩn bị sẵn cho nó:

| Tầng | Đã có |
|---|---|
| `baseline` SCP | Chặn `cloudtrail:StopLogging`, `DeleteTrail`, `UpdateTrail` |
| `aws_service_access_principals` | Đã bật `cloudtrail.amazonaws.com` |
| Permission set | `lz-auditor`, `lz-security-operator` được cấp quyền đọc CloudTrail |

Ba tầng bảo vệ và cấp quyền cho một thứ **không tồn tại**. Đọc code thì không thấy gì sai — vì cái thiếu không nằm ở đâu để mà nhìn thấy.

> Đó là toàn bộ lý do lớp phát hiện đáng tiền: SCP nói *ai được làm gì*, Config nói *thực tế đang thế nào*, và hai câu đó lệch nhau nhiều hơn người ta tưởng.

---

## Vì sao là organization trail

Một trail tạo ở management account với `is_organization_trail = true`:

- phủ **mọi account hiện có**
- phủ **mọi account tương lai** — không phải chạy lại gì
- account con **không tắt được**, chỉ management account sửa được

Trail từng account thì nhân lên theo số account, và account mới sẽ im lặng không có trail cho tới khi ai đó nhớ ra. Đúng loại sai lệch lặng lẽ mà landing zone sinh ra để ngăn.

`is_multi_region_trail = true` cũng bắt buộc: bỏ nó là tự tạo một vùng mù đúng bằng số region còn lại.

---

## Chi phí

| Thành phần | Giá |
|---|---|
| Management event, bản sao đầu tiên | **Miễn phí**, mọi account |
| Lưu trữ S3 | Vài chục MB/tháng cho tổ chức nhỏ |
| Log file validation | Không đáng kể |
| **Data event** | **Tính tiền theo từng sự kiện** |

`data_events` mặc định **tắt**, và đó là cần gạt chi phí lớn nhất. Một bucket S3 có lưu lượng bình thường sinh hàng triệu sự kiện mỗi tháng; bật "cho chắc" ở phạm vi tổ chức là cách nhanh nhất biến một layer miễn phí thành khoản lớn nhất trong hoá đơn.

Có `check` block cảnh báo khi đặt `true`.

---

## Điều kiện tiên quyết

```bash
aws organizations list-aws-service-access-for-organization \
  --query 'EnabledServicePrincipals[?ServicePrincipal==`cloudtrail.amazonaws.com`]'
```

Rỗng thì thêm `cloudtrail.amazonaws.com` vào `aws_service_access_principals` ở [`../organization`](../organization/) rồi apply. Có `check` block bắt việc này.

Ngoài ra cần một **account log archive** khác management account. Có `check` block bắt luôn.

---

## Chạy

```bash
cd landing-zone/org-trail
cp terraform.tfvars.example terraform.tfvars

terraform init -backend-config=backend.hcl
terraform plan            # enable = false -> 0 resource
```

Điền `log_archive_account_id`, đổi `enable = true`, rồi `plan` lại.

Mong đợi **9 to add**: bucket + 6 resource kèm theo + bucket policy + trail. Bật `enable_object_lock` thì thành 10.

```bash
terraform apply
```

---

## Kiểm chứng

CloudTrail giao theo lô, **không tức thì**. Bucket rỗng ngay sau apply là bình thường.

```bash
# ~15 phut
aws cloudtrail get-trail-status --name <project>-org-trail \
  --query '[IsLogging,LatestDeliveryTime,LatestDeliveryError]'

aws s3 ls s3://<project>-cloudtrail-<log-archive-id>/ --recursive \
  --profile <log-archive> | head
```

`LatestDeliveryError` có giá trị thì gần như luôn là bucket policy.

**Phép kiểm chứng thật của layer này** không phải việc trail tồn tại, mà là việc lớp phát hiện xác nhận nó tồn tại — sau ~1 giờ:

```bash
aws configservice describe-aggregate-compliance-by-config-rules \
  --configuration-aggregator-name <project>-org \
  --profile <security> --region <region> \
  --query 'AggregateComplianceByConfigRules[?contains(ConfigRuleName,`cloud-trail`)]'
```

`cloud-trail-enabled` phải chuyển từ `NON_COMPLIANT` sang `COMPLIANT` ở mọi account. Vòng khép kín: phát hiện → sửa → phát hiện xác nhận.

---

## Ba chỗ dễ sai

| Chỗ | Hậu quả |
|---|---|
| **Đường dẫn trong bucket policy** | Organization trail ghi vào `AWSLogs/<org-id>/<account-id>/CloudTrail/...` — có thêm đoạn `<org-id>` mà trail thường không có. Sai prefix thì CloudTrail báo lỗi quyền ghi mà không nói rõ là do đường dẫn |
| **Thiếu `AWSCloudTrailAclCheck`** | CloudTrail đọc ACL để kiểm quyền **trước** khi giao file đầu tiên. Thiếu statement này thì không bao giờ giao được |
| **Object Lock** | `enable_object_lock` mặc định `false` và **chưa ai kiểm chứng với CloudTrail**. AWS Config không ghi được vào bucket có Object Lock; CloudTrail thì chưa đo. Object Lock chỉ bật được lúc tạo bucket, và `prevent_destroy` chặn xoá — bật nhầm là rất phiền. Cách đo nằm trong mô tả biến |

Vòng lặp giữa trail và bucket policy được cắt bằng cách **ráp ARN của trail bằng tay** thay vì lấy từ resource — ARN đó hoàn toàn đoán trước được từ region, account ID và tên trail.

---

## Liên quan

| | |
|---|---|
| [`../config-detective`](../config-detective/) | Lớp phát hiện đã tìm ra chỗ thiếu này |
| [`../organization`](../organization/) | SCP bảo vệ trail, service access, delegated admin |
| [doc 22 mục 6b](../../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) | Nhật ký: lỗ hổng bị bắt như thế nào |
| [doc 06](../../docs/06-Aws-Landing-Zone.md) | Thiết kế LZ: logging tập trung |
