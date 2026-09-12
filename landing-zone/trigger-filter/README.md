# trigger-filter — lọc sự kiện commit trước khi chạm vào pipeline

## Vấn đề

Mỗi pipeline trước đây có một rule EventBridge riêng bắt "có commit vào nhánh
`main`". Rule đó **không lọc được theo đường dẫn** — và đây không phải là "chưa
ai viết luật đó", mà là **không thể viết**.

Sự kiện `CodeCommit Repository State Change` chỉ mang:

```json
{ "repositoryName": "...", "commitId": "...",
  "oldCommitId": "...", "referenceName": "refs/heads/main" }
```

Danh sách file **không có trong sự kiện**. Nên không có trường nào để `event_pattern`
so khớp.

CodePipeline V2 có bộ lọc đường dẫn, nhưng chỉ cho nguồn kiểu *connection* —
GitHub, GitLab, Bitbucket. Công ty chỉ dùng CodeCommit nội bộ, nên đường đó
không mở.

Hậu quả thực tế: sửa một dòng trong `docs/` cũng làm pipeline **vending** chạy cả
bảy stage vending account.

## Cách chữa

Một hàm Lambda đứng **giữa** sự kiện và pipeline. Thứ *có* trong sự kiện là hai
commit id, nên hàm gọi `codecommit:GetDifferences(oldCommitId, commitId)`, lấy
danh sách đường dẫn đã đổi, rồi khởi động đúng những pipeline có đường dẫn bị
chạm.

```
commit  →  EventBridge (1 rule duy nhất, không lọc gì)
        →  Lambda loc.py  →  GetDifferences  →  đối chiếu BAN_DO
        →  StartPipelineExecution cho những pipeline khớp
```

## Quyết định quan trọng nhất: hỏng thì chạy

Khi không đọc được diff — API lỗi, hết giờ, thiếu quyền, commit bị ép đẩy — hàm
khởi động **mọi** pipeline trong bản đồ.

Lý do không làm ngược lại: một lần chạy thừa là vài phút CodeBuild và một dòng
log. Một lần **không** chạy là một thay đổi đã merge vào `main` mà không bao giờ
đến AWS — và không có gì báo, vì pipeline "không chạy" trông giống hệt "không có
gì để chạy".

Ngoại lệ: **diff rỗng thật sự** (commit rỗng, merge không đổi gì) không phải
fail-open. Đó là một kết luận đọc được, không phải một phép đọc hỏng.

## Bốn cách bản đồ có thể sai — cả bốn đều im lặng

`loc.py` kiểm cả bốn ở **mỗi lần gọi**, và cả bốn đều là lỗi cứng:

| Sai | Hậu quả nếu không kiểm |
|---|---|
| `BAN_DO` rỗng | chặn sạch mọi thay đổi, báo thành công |
| một pipeline có danh sách tiền tố `[]` | `startswith(())` luôn `False` → pipeline đó không bao giờ chạy. Trong tfvars, `[]` đọc giống "chưa điền" |
| tên pipeline gõ sai | `StartPipelineExecution` bị từ chối |
| **pipeline có thật, thiếu trong `BAN_DO`** | sau khi tắt rule riêng, không còn đường nào đến nó. Nó vẫn tồn tại, vẫn xanh, và không bao giờ chạy nữa |

Dòng cuối là chiều nguy hiểm nhất của cả thiết kế này. `kiem_do_phu = true` bắt
nó: hàm liệt kê pipeline thật ở AWS mỗi lần chạy và báo hỏng nếu có cái nào mang
tiền tố `<project>-` mà không có trong bản đồ.

Phép kiểm đó bảo đảm đúng một điều: *"mọi pipeline **tên bắt đầu bằng**
`<project>-` đều có trong bản đồ"* — **không phải** *"mọi pipeline của landing
zone đều có trong bản đồ"*. Hai câu đó trùng nhau chỉ vì tên pipeline do
Terraform ghép (`local.name = "${var.project}-${var.ten}"` trong
`modules/tf-pipeline` và `vending-pipeline`). Một pipeline đặt tên tay thì nó
không thấy.

Đo thật: account này có 5 pipeline, 3 mang tiền tố `qh11-lz-`. Hai cái còn lại
(`MyImagePipeline1`, `shopping-cart-pipeline`) không thuộc landing zone — nhưng
đó là kết luận rút ra từ việc **nhìn** danh sách, không phải từ việc phép kiểm im
lặng.

Muốn "chạy với mọi commit" thì khai `[""]`, **không phải** `[]`.

## Layer không có đường tự động

Bản đồ trỏ **pipeline → layer nó apply**, không phải thư mục định nghĩa của chính
pipeline. Sửa `landing-zone/ops-pipeline/main.tf` không làm pipeline đó chạy —
đúng, vì layer pipeline được apply bằng tay.

Nhưng một pipeline có thể apply **nhiều** layer. Pipeline vending apply bốn:
`account-baseline` (stage A, C), `network` (B, D), `config-detective` (E0, E),
`permission-sets` (F). Bản đồ chỉ cho nó `landing-zone/account-baseline/`, nên
hai layer giữa mất đường tự động — và mất theo kiểu im lặng nhất: code vào
`main`, không gì chạy, không gì báo.

Đó là có chủ đích. Nhiệm vụ của vending là *"có account mới, lan toả ra các layer
liên quan"*, không phải *"apply mọi thay đổi code của bốn layer đó"*. Hai layer
ấy sẽ có đường trở lại khi pipeline riêng của chúng bật — **không** phải bằng
cách nới bản đồ của vending, vì thế là trộn lại đúng thứ đã tách ra theo phòng
ban.

Nên chúng phải được **khai**:

```hcl
layer_thu_cong = [
  "landing-zone/network",
  "landing-zone/config-detective",
  "landing-zone/network/ops",
  "landing-zone/org-trail",
]
```

`landing-zone/kiem-module.py` (phép 10) đối chiếu mọi `layer = "..."` khai trong
các caller pipeline với `ban_do` ∪ `layer_thu_cong`, và kêu khi có layer nằm
ngoài cả hai. Nó cũng kêu chiều ngược lại — một ngoại lệ đã hết hạn, vì nó nói
rằng có chỗ trống ở đâu đó trong khi chỗ đó không còn.

## Thứ tự bật — một chiều an toàn, một chiều im lặng

1. Apply layer này (`enable = true`).
2. **Rồi mới** đặt `tu_kich_hoat = false` trong tfvars của `ops-pipeline`,
   `ops-pipeline-permission-set`, `ops-pipeline-network`,
   `ops-pipeline-config-rules`, `ops-pipeline-trail` và `vending-pipeline`.

Giữa hai bước đó mỗi pipeline bị kích hoạt **hai lần** — vô hại, CodePipeline
thay thế bản đang chờ bằng bản mới.

Làm **ngược lại** thì giữa hai bước không có gì kích hoạt pipeline nào, và không
có triệu chứng nào: console vẫn xanh, pipeline chỉ không bao giờ chạy.

`tu_kich_hoat = false` **không** tắt lịch drift — đó là một rule khác, không liên
quan đến commit. Hai rule dùng chung một IAM role, nên role đó cố ý không bị tắt
theo biến này.

## Chạy

```bash
cp terraform.tfvars.example terraform.tfvars   # sửa project, repository_name, ban_do
../tf-backend/wire-backends.sh                 # sinh backend.tf
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
terraform output -raw huong_dan
```

`./test-loc.py` chạy bộ kiểm của hàm lọc — không cần mạng, không cần boto3 thật.

## Ba phép thử sau khi apply

Chỉ phép (c) chứng minh bộ lọc **có tác dụng**:

- **(a)** push một thay đổi chỉ trong `docs/` → không pipeline nào chạy.
- **(b)** push một thay đổi trong `landing-zone/account-baseline/` → chỉ
  `<project>-vending` chạy.
- **(c)** push một thay đổi trong `landing-zone/organization/` →
  `<project>-ops` chạy **và** `<project>-vending` **không** chạy.

(a) và (b) vẫn đạt nếu bộ lọc bị bỏ qua hoàn toàn và mọi pipeline đều chạy — ở
(a) thì "không ai chạy" trông giống "chạy hết rồi không có gì để làm". Chỉ (c)
phân biệt được hai trường hợp đó, vì nó đòi một pipeline chạy **và** một pipeline
không chạy trong cùng một lần push.

Xem log:

```bash
aws logs tail /aws/lambda/<project>-trigger-filter --follow --region <region>
```
