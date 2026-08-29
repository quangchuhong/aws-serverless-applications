# `service-catalog` — ép tag ở thời điểm tạo

Lớp duy nhất trong LZ chạm được tới **người tạo resource bằng console**. Mặc định tắt.

> Thiết kế và bối cảnh: [doc 11 mục 3b](../../docs/11-Tag-Policy-va-Cost-Allocation.md#3b-service-catalog-tagoptions--ép-tag-ở-thời-điểm-tạo).
>
> **Chưa ai apply layer này.** Nó chưa qua `terraform plan` với provider thật — khác với 7 layer đã đi qua lửa. Đọc [doc 22](../../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) để thấy phần lớn lỗi trong repo này thuộc loại `validate` không bắt được.

---

## Vì sao có layer này

Bốn lớp tag còn lại đều hụt ở cùng một chỗ:

| | Hụt ở đâu |
|---|---|
| `default_tags` | Chỉ phủ thứ Terraform quản |
| Tag policy | Chỉ ràng buộc **giá trị của tag đã gắn** — không bắt ai phải gắn |
| SCP | Chặn được, nhưng chỉ vài action |
| Config `required-tags` | Phát hiện **sau khi việc đã rồi** |

TagOption là thứ duy nhất làm được: **không chọn tag thì không tạo được resource.**

## Nhưng nó không "bật tag" cho bạn

Đây là điều phải hiểu trước khi bật, vì nó quyết định layer có giá trị hay không:

> **TagOption chỉ ép được người đi qua catalog.** Ai còn quyền tạo resource trực tiếp thì vẫn tạo bằng console, và layer này không chạm tới họ.

Giá trị của nó đến từ việc **đổi cách làm việc**: đội ứng dụng không còn quyền tạo RDS trực tiếp, họ launch product *"RDS chuẩn của công ty"* từ catalog — và product đó đã có sẵn tag, mã hoá, backup, subnet đúng.

Chưa sẵn sàng đổi cách làm việc thì đây chỉ là một portfolio rỗng không ai dùng. `enable = false` là mặc định đúng.

---

## Có gì

| Thành phần | Ghi chú |
|---|---|
| `aws_servicecatalog_tag_option` | Thư viện key–value. Sinh từ `map(list(string))` |
| `aws_servicecatalog_portfolio` | Một portfolio mỗi đối tượng dùng |
| `..._tag_option_resource_association` | Gắn ở **portfolio**, product thêm sau tự thừa hưởng |
| `aws_servicecatalog_portfolio_share` | Chia theo OU, `share_tag_options = true` |
| `aws_iam_role.sc_launch` | Role Service Catalog dùng để tạo resource |

**Không có product nào.** Product là template CloudFormation riêng của từng tổ chức — chúng không thuộc về Landing Zone. Layer này dựng phần khung; `terraform output next_steps` có mẫu thêm product và launch constraint.

## Số lượng giá trị quyết định hành vi

```hcl
tag_options = {
  ManagedBy   = ["service-catalog"]                          # 1 -> tu gan, khong thay
  Environment = ["dev", "staging", "prod", "sandbox"]        # 4 -> BUOC CHON
  CostCenter  = ["CC-1001", "CC-2002", "CC-3010"]            # 3 -> BUOC CHON
}
```

Một giá trị thì tag tự gắn — nhưng đó là việc `default_tags` đã làm rồi, và làm tốt hơn. **Giá trị riêng của TagOption đến từ việc ép chọn.** `check "tag_options_force_a_choice"` cảnh báo nếu không key nào có từ hai giá trị.

Vì vậy `CostCenter` nên liệt kê mã phòng ban thật: một danh sách bắt người ta chọn đúng hơn hẳn một ô trống bắt họ gõ.

---

## Chạy

```bash
cd landing-zone/service-catalog
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan
```

### Chạy ở account nào

Layer **không** assume role sang account khác — nó chạy ở đúng account credential đang trỏ tới.

```bash
unset AWS_PROFILE && terraform apply     # management account
AWS_PROFILE=<hub> terraform apply        # account shared-services rieng
```

Cách thứ hai đúng hơn khi tổ chức lớn lên. Management account nên **sạch**: không workload, rất ít người vào, và SCP không áp lên nó nên mọi quyền cấp ở đó là quyền thật không có trần chặn — trong khi catalog tự phục vụ là thứ người ta vào thường xuyên. `check "catalog_not_in_management"` nhắc điều đó lúc `plan`.

---

## Bốn chỗ dễ sai

| | |
|---|---|
| **`share_tag_options`** | Mặc định của AWS là `false`. Thiếu nó thì portfolio sang tới nơi mà **TagOption ở lại** — người bên đó launch product không bị hỏi tag nào. Layer này luôn đặt `true`, nhưng biết để khỏi ngạc nhiên nếu tự viết |
| **Thiếu launch constraint** | Người launch phải tự có quyền trên mọi dịch vụ product tạo ra. Có quyền đó rồi thì họ tạo thẳng được, catalog thành hình thức |
| **Launch role quá rộng** | Role tạo resource **thay mặt** người dùng, nên quyền của nó là trần trên của mọi thứ product làm được. `AdministratorAccess` ở đây nghĩa là ai launch được product đều gián tiếp có quyền admin |
| **TagOption theo account + region** | Không phải tài nguyên toàn cầu. Dùng ở nhiều region thì tạo lại ở từng region |

> Ngừng dùng một giá trị thì đặt `active = false`, **đừng xoá** — xoá làm provisioned product đang chạy mất tham chiếu tới TagOption của nó.

---

## Phải khớp với tag policy

`tag_options["Environment"]` và `tag_policy_keys["Environment"].allowed_values` bên [`organization`](../organization/) phải **cùng một danh sách**. Lệch nhau thì người dùng chọn được một giá trị mà tag policy đánh dấu là không tuân thủ — hợp lệ ở một chỗ, sai ở chỗ kia, và không lệnh nào nói ra.

`check "tag_options_match_tag_policy"` bắt trường hợp này với `Environment`.

---

## Kiểm chứng — phải launch thật

```
Console → Service Catalog → Products → Launch
```

Màn hình launch **phải hỏi bạn chọn giá trị** cho từng key có nhiều giá trị. Không hỏi nghĩa là TagOption chưa tới nơi — kiểm lại `share_tag_options` và việc gán vào portfolio.

`terraform output` không trả lời được câu này. Nó nói ý định; chỉ một lần launch thật mới nói kết quả.

---

## Liên quan

| | |
|---|---|
| [doc 11 mục 3b](../../docs/11-Tag-Policy-va-Cost-Allocation.md) | Năm lớp tag, và lớp này đứng ở đâu |
| [doc 21](../../docs/21-Control-Tower-vs-DIY.md) | Account Factory là một portfolio Service Catalog |
| [`organization`](../organization/) | Tag policy — ràng buộc giá trị, không ép gắn |
| [doc 09](../../docs/09-Account-Vending-Tu-Dong.md) | Service Catalog cho account vending |
