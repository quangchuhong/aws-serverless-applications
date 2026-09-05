# Control Tower (để đối chiếu)

Bản Control Tower của layer organization. **Mặc định TẮT** — `enable_landing_zone = false`.

> **Bản dùng thật cho lab là [`../organization/`](../organization/) (DIY).** Layer này viết sẵn để so sánh và kiểm chứng bằng `terraform plan`, giống cách đã làm với Palo Alto / F5 trong `landing-zone/network/appliances.tf`.
>
> So sánh đầy đủ: [doc 21](../../docs/21-Control-Tower-vs-DIY.md).

---

## Ba điều phải biết trước khi bật

**1. Chi phí thường trực.** Control Tower miễn phí, nhưng **bật AWS Config ở mọi account × mọi governed region**. Config tính theo configuration item ghi được và rule evaluation. Đây là khoản **chạy liên tục, không tắt được** nếu còn dùng CT.

`governed_regions` là biến quyết định chi phí — mỗi region thêm vào nhân chi phí Config lên theo số account. Có `check` block cảnh báo khi vượt 2 region.

Con số thật phụ thuộc số resource và tần suất thay đổi — kiểm bằng [AWS Pricing Calculator](https://calculator.aws), đừng tin ước lượng nào khác.

**2. Không xoá được theo buổi.** Decommission Control Tower là quy trình thủ công nhiều bước. Mô hình dựng–xoá của repo này **không áp dụng** cho nó.

**3. Đăng ký OU sẵn có sẽ đẩy StackSet baseline xuống mọi account trong OU đó.** Làm từng OU một.

---

## Kiểm chứng mà không tạo gì

```bash
cd landing-zone/control-tower
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan     # enable_landing_zone = false -> 0 resource
```

Hoặc chạy cả 5 layer một lượt:

```bash
cd landing-zone
./plan-all.sh
./plan-all.sh --no-plan     # chi init + validate, khong can credential
```

---

## Có gì

| Resource | Vai trò |
|---|---|
| `aws_organizations_account` × 2 | Log Archive + Audit — **bắt buộc có trước** |
| `aws_controltower_landing_zone` | Landing zone + version + manifest |
| `aws_controltower_control` | Bật guardrail trên từng OU |

### Hai account lõi phải tạo trước

`aws_controltower_landing_zone` đòi **account ID có sẵn** trong manifest — nó không tự tạo Log Archive và Audit. Nên layer này tạo chúng trước bằng `aws_organizations_account`.

Email phải **duy nhất toàn cầu** và **có thật** — AWS gửi thư xác nhận, và đó là đường khôi phục root duy nhất. Dùng plus-addressing:

```hcl
core_account_emails = {
  log_archive = "ban+lz-logarchive-01@gmail.com"
  audit       = "ban+lz-audit-01@gmail.com"
}
```

Thêm hậu tố `-01` ngay từ đầu: email đã dùng cho một AWS account thì **không tái sử dụng được**, kể cả sau khi đóng account.

---

## "Upgrade Control Tower" là gì

Đây là thứ bạn hỏi ban đầu. Cụ thể là đổi một biến:

```hcl
landing_zone_version = "3.3"   # doi so nay roi apply
```

Sau khi nâng, các account thường phải **re-enroll** — bước đó **không tự động**, phải làm qua console hoặc script.

Xem version hiện tại:

```bash
terraform output landing_zone_version
terraform output drift_status
```

> `drift_status` của Control Tower **khác** drift của Terraform: CT so với baseline của chính nó, Terraform so với state. Hai hệ thống có thể cùng báo drift vì hai lý do khác nhau.

---

## Controls: phải tự kiểm chứng identifier

```hcl
controls = {
  "Workloads" = ["AWS-GR_RESTRICT_ROOT_USER", ...]
}
```

**Control identifier thay đổi theo thời gian và theo phiên bản landing zone.** Liệt kê cái có thật trong môi trường của bạn trước khi điền:

```bash
aws controltower list-controls --region <home-region>
```

Điền identifier không tồn tại = apply lỗi `ValidationException`. Mặc định để rỗng — bật bằng tay trên console trước, rồi mới đưa vào code.

`control_target_ou_arns` cũng phải khai tay: OU do **Control Tower** tạo chứ không phải Terraform, nên không tham chiếu bằng resource được.

---

## Sống chung với phần còn lại của repo

| Layer | Với Control Tower |
|---|---|
| [`../tf-backend`](../tf-backend/) | ✅ Dùng lại nguyên |
| [`../billing-guard`](../billing-guard/) | ✅ Dùng lại nguyên |
| [`../permission-sets`](../permission-sets/) | ✅ Dùng lại — nhưng xem lưu ý dưới |
| [`../organization`](../organization/) | ❌ Thay thế — dùng cái này **hoặc** cái kia, không dùng cả hai |

**Lưu ý về permission set:** `enable_access_management = true` khiến Control Tower tự bật Identity Center và tạo bộ permission set riêng (`AWSAdministratorAccess`, …). 17 set ở `permission-sets` vẫn dùng được — CT không cấm tạo thêm — nhưng sẽ có **hai bộ song song**. Phải rõ ai dùng bộ nào, hoặc đặt `enable_access_management = false` nếu đã tự quản Identity Center bằng Terraform.

**Đừng chạy cả `organization` lẫn `control-tower`.** Cả hai đều quản OU và guardrail, sẽ giẫm lên nhau.

---

## Xoá

Hai account lõi có `prevent_destroy = true`. Và **account AWS không xoá được bằng `terraform destroy`** — Terraform chỉ gỡ khỏi state và tách khỏi organization. Muốn đóng thật thì phải đăng nhập root của account đó, đóng bằng tay, chờ 90 ngày.

Riêng landing zone: `terraform destroy` sẽ gọi API xoá, nhưng đó **không phải** quy trình decommission đầy đủ của Control Tower. Đọc tài liệu AWS trước khi làm.

---

## Liên quan

| | |
|---|---|
| [Doc 21 – Control Tower vs DIY](../../docs/21-Control-Tower-vs-DIY.md) | So sánh đầy đủ, bảng chi phí, khi nào chọn cái nào |
| [Doc 20 – Vận hành LZ](../../docs/20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
| [`../organization`](../organization/) | Bản DIY — bản dùng thật |
