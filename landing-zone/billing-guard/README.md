# Billing Guard

Lớp bảo vệ chi phí cho toàn bộ Organization. Chạy ở **management account**.

**Không nằm trong teardown của demo** — dựng một lần rồi để đó. Chi phí ~$0.

---

## Vì sao cần dựng sớm

Chỉ có **một** lý do, nhưng nó đủ mạnh:

> **Cost allocation tag không hồi tố.** Bật hôm nay thì dữ liệu phân bổ chi phí bắt đầu từ hôm nay. Dữ liệu tháng trước vẫn còn nhưng không chia theo tag được nữa.

Mọi thứ khác trong layer này bật lúc nào cũng được. Nhưng vì đằng nào cũng phải vào management account, làm luôn một thể.

Lý do thứ hai, thực dụng hơn với mô hình dựng–xoá: **quên xoá demo một tháng là ~$550**. Budget cảnh báo là lớp bảo vệ rẻ nhất cho việc đó.

---

## Có gì trong này

| Thành phần | Chi phí | Làm gì |
|---|---|---|
| **Cost allocation tag** | $0 | Bật `CostCenter`, `Environment`, `Project`, `Owner` để Cost Explorer group được theo tag |
| **Budget toàn org** | 2 budget đầu **free**, sau đó ~$0.02/ngày | Cảnh báo ở 50/80/100% và theo dự báo |
| **Budget từng account** | như trên | Tuỳ chọn |
| **Cost Anomaly Detection** | **$0** | Bắt "hôm nay tự nhiên tốn gấp 3" kể cả khi tổng vẫn dưới hạn mức |
| **SNS topic** | ~$0 | Kênh chung, dùng lại được cho alert khác |
| **CloudWatch dashboard** | ~$0 | Tuỳ chọn — đọc mục dưới trước khi bật |

---

## Dashboard tập trung: bạn đã có sẵn

Câu hỏi hay gặp: *"có cần build dashboard billing cho toàn bộ account không?"*

**Không cần build gì.** Consolidated billing của Organizations tự động gom chi phí mọi account về management account, và **Cost Explorer ở đó đã là dashboard tập trung**:

```
https://us-east-1.console.aws.amazon.com/costmanagement/home#/cost-explorer
```

Miễn phí, group được theo **Linked Account / Service / Region / Tag / Cost Category**, lọc và lưu report được.

Cái bạn thực sự cần build là **thứ làm cho nó hữu ích**: cost allocation tag. Không bật tag thì Cost Explorer chỉ group được theo account và service — biết được "account app-prod tốn $200" nhưng không biết "team nào trong đó tốn bao nhiêu".

### Bốn lựa chọn, xếp theo thứ tự nên dùng

| Cách | Chi phí | Khi nào |
|---|---|---|
| **Cost Explorer** | $0 | **Mặc định.** Đủ cho hầu hết nhu cầu |
| CloudWatch dashboard (layer này) | ~$0 | Muốn chi phí nằm cạnh dashboard vận hành khác |
| CUR + Athena | Phí S3 + query | Cần báo cáo tự động, chargeback |
| QuickSight / CUDOS | ~$9–24/user/tháng | Cần chia sẻ cho người không có quyền vào AWS console |

CloudWatch dashboard trong layer này có **hạn chế thật**, biết trước để không kỳ vọng nhầm:

- Độ phân giải **6 tiếng**
- Chỉ có tổng và theo service — **không chia được theo account hay tag**
- Cần bật **"Receive Billing Alerts"** thủ công trước (Billing console → Billing preferences), không bật thì dashboard trống trơn

Nói cách khác: nó là tiện ích, không phải công cụ phân tích. Phân tích thật thì dùng Cost Explorer.

---

## Chạy

```bash
cd landing-zone/billing-guard
cp terraform.tfvars.example terraform.tfvars
# sua alert_emails

terraform init
terraform apply
```

Phải chạy bằng credential của **management account** — cost allocation tag và budget không bật được từ account con.

### Sau khi apply

1. **Xác nhận email.** SNS gửi email xác nhận. Chưa bấm link = không nhận được cảnh báo nào. Đây là bước hay quên nhất.

2. **Chờ ~24 giờ** để cost allocation tag xuất hiện:

```bash
aws ce list-cost-allocation-tags --status Active \
  --query 'CostAllocationTags[].[TagKey,Status]' --output table
```

3. **Kiểm tra budget:**

```bash
aws budgets describe-budgets --account-id $(aws sts get-caller-identity --query Account --output text) \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,TimeUnit]' --output table
```

---

## Nếu apply lỗi ở cost allocation tag

Nguyên nhân gần như luôn là: **chưa có resource nào mang tag đó**. AWS chỉ cho bật tag đã xuất hiện ít nhất một lần.

Xử lý:

```hcl
# terraform.tfvars
enable_cost_allocation_tags = false
```

Dựng LZ và demo trước (mọi resource đều đã gắn tag qua `default_tags`), rồi quay lại bật:

```hcl
enable_cost_allocation_tags = true
```

---

## Ngưỡng đặt bao nhiêu

Với mô hình dựng–xoá:

| Cấu hình | Chi phí thật | Ngưỡng đề xuất |
|---|---|---|
| Chỉ billing guard, không có demo nào chạy | ~$0 | — |
| Demo network 4 tiếng | ~$3 | — |
| **Ngưỡng cảnh báo tháng** | | **$20** |

Cảnh báo ở 50% = báo khi tới $10. Demo bình thường không bao giờ chạm; chạm nghĩa là có gì đó đang chạy mà bạn không biết — thường là destroy fail giữa chừng để lại NAT hoặc EIP.

Khi LZ lên production thật, nâng ngưỡng theo chi phí thực tế (xem [doc 17 mục 7](../../docs/17-Network-LZ-Design-Guide.md)).

---

## Quan hệ với các phần khác

| Phần | Liên quan thế nào |
|---|---|
| [Doc 11 – Tag policy và cost allocation](../../docs/11-Tag-Policy-va-Cost-Allocation.md) | Thiết kế đầy đủ. Layer này chỉ làm phần **phải làm sớm** |
| [Doc 17 mục 7.5](../../docs/17-Network-LZ-Design-Guide.md) | Chi phí mô hình dựng–xoá, bốn cái bẫy |
| [`demo/network-lz-full`](../../demo/network-lz-full/) | Mọi resource gắn `Ephemeral=true`; budget này bắt khi quên xoá |

Phần còn lại của doc 11 — tag policy, SCP bắt buộc tag, Cost Categories, CUR + Athena — làm sau, khi đã có nhiều account và nhiều team thật.

---

## Xoá (nếu thực sự cần)

```bash
terraform destroy
```

Nhưng **cân nhắc đừng xoá**: layer này tốn ~$0 và là lớp bảo vệ duy nhất chống việc quên xoá demo. Xoá nó đi rồi quên xoá demo là kịch bản tệ nhất.

Riêng cost allocation tag: sau khi xoá, dữ liệu phân bổ đã thu thập vẫn còn, nhưng dừng thu thập từ thời điểm đó. Bật lại sau thì có khoảng trống ở giữa.
