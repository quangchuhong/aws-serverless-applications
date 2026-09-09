# Pipeline vending account

CodePipeline ở **account management**. Tự động hoá năm bước của [doc 27](../../docs/27-Van-hanh-Account-Vending.md) thành sáu stage, mỗi stage một cổng duyệt.

**Mặc định tắt.** Bật nó không phải là thêm vài resource — nó tạo một đường tự động có quyền apply bốn layer, trong đó có layer `network`.

---

## Sáu stage cho năm bước

```
Nguồn (CodeCommit)
  │
  ├─ Lint                    lint.sh + fmt + validate — không gọi AWS
  │
  ├─ A  account-baseline     plan → DUYỆT → apply    tạo account
  ├─ B  network              plan → DUYỆT → apply    chia sẻ TGW
  ├─ C  account-baseline     plan → DUYỆT → apply    VPC + attachment
  ├─ D  network      ⏳chờ → plan → DUYỆT → apply    nối vào rtb-spokes
  ├─ E  config-detective     plan → DUYỆT → apply    excluded_accounts
  └─ F  permission-sets      plan → DUYỆT → apply    accounts_by_scope
```

A và C cùng một layer, B và D cũng vậy. **Không gộp được:** C cần TGW đã chia sẻ ở B, D cần attachment đã tồn tại ở C. Ràng buộc thứ tự không biến mất khi bỏ người ra — nó chỉ thôi cần người.

Lần chạy nào không có account mới thì cả sáu stage đều ra `KHÔNG CÓ THAY ĐỔI`, nên lặp lại là rẻ.

---

## Bốn quyết định đáng đọc trước khi bật

### 1. `terraform plan -out=tfplan`, và apply đúng file đó

Giữa lúc duyệt và lúc apply có thể vài giờ. Không có `-out` thì apply **tính một plan mới**, và thứ người ta bấm duyệt không còn là thứ được thực hiện. Cổng duyệt lúc đó là nghi thức, không phải kiểm soát.

Kéo theo: `terraform_version` **ghim cứng**, không dùng `latest`. `apply tfplan` đòi đúng phiên bản đã sinh ra file plan; nếu CodeBuild tải bản mới giữa hai bước thì apply từ chối file plan, và thông báo nói về **định dạng file** chứ không nói rằng HashiCorp vừa phát hành một bản.

### 2. Buildspec tự sinh `backend.tf`

`backend.tf` và `backend.hcl` đều nằm trong `.gitignore` — cố ý, vì chúng do `wire-backends.sh` sinh trên máy từng người. Nghĩa là bản checkout trong CodeBuild **không có khối backend nào**.

Thiếu bước sinh thì `terraform init` cấu hình backend **local** — một state rỗng — và `plan` báo cần tạo mới toàn bộ hạ tầng. **Không có lỗi nào cả.** Người duyệt nhìn `200 to add` có thể tưởng đây là môi trường mới.

Nên buildspec còn dừng lại khi state rỗng mà `FIRST_APPLY != yes`: một layer đã từng apply mà state rỗng nghĩa là sai khoá, không phải lần chạy đầu.

### 3. `terraform.tfvars` đi qua S3, không đi qua git

Cùng lý do với `backend.tf`: `.gitignore` loại `terraform.tfvars` vì nó chứa account ID, email, mã phòng ban. Bản checkout của CodeBuild **không có tfvars của layer nào**.

Nhưng hậu quả khác hẳn, và tệ hơn. Thiếu backend thì state rỗng, và chốt chặn bắt được. Thiếu tfvars thì **không có gì hỏng**:

| Layer | Biến bắt buộc (không có `default`) |
|---|---|
| account-baseline | *không có* |
| network | *không có* |
| config-detective | *không có* |
| permission-sets | `management_account_id` |

Ba trong bốn layer mọi biến đều có `default`. Thiếu tfvars thì `terraform plan` chạy **thành công** với `catalog = {}`, `spokes = {}`, `ou_ids = {}` — trên **đúng** state thật. Nghĩa là plan mô tả việc **xoá** account, StackSet, VPC, attachment đang có. Chốt chặn state rỗng không thấy gì bất thường: state đầy đủ, chỉ có biến là rỗng.

Nên tfvars nằm trong một bucket riêng (`tfvars_bucket`), buildspec kéo về trước `init`, và **thiếu file là lỗi cứng**.

```bash
cd landing-zone/vending-pipeline
./push-tfvars.sh          # chạy lại MỖI KHI sửa tfvars của bất kỳ layer nào
```

Quên chạy = pipeline chạy trên cấu hình **cũ**, và không có gì báo điều đó. Bucket bật versioning để lùi lại được sau một lần đẩy nhầm.

Role CodeBuild **bị Deny tường minh** quyền ghi vào bucket này. Deny chứ không phải "không khai Allow": `s3:*` trong cùng policy đã cấp ghi rồi, và chỉ Deny mới thật sự chặn. Sửa cấu hình là việc của người, từ máy có credential riêng.

### 4. Hai danh tính trong một lần chạy

CodeBuild chỉ có **một** bộ credential, của management, và nó cần bộ đó để đọc bucket state. Nếu provider cũng dùng bộ đó thì layer `network` dựng TGW và firewall **trong account management** — đúng sự cố đêm 5/9.

```
backend   → credential CodeBuild (management)   đọc/ghi state
provider  → assume_role sang account mạng       tạo resource
```

Buildspec **không** assume role. Nó truyền `TF_VAR_assume_role_arn`, và layer `network` tự assume trong provider block. Assume ở buildspec thì cả hai cùng nhảy, và CodeBuild mất quyền đọc state — hoặc tệ hơn, đọc được một state khác.

---

## Ba thứ pipeline này không làm

| | Vì sao |
|---|---|
| **Không tự duyệt** | Tạo account gần như không hoàn tác được, và email là duy nhất vĩnh viễn ở phạm vi AWS toàn cầu. Sáu cổng duyệt, không có đường tắt |
| **Không đính kèm plan vào thư** | Cố ý. Một cổng duyệt mà nội dung hiện ngay trong thư sẽ được bấm từ điện thoại, không đọc. Thư chỉ có link tới log CodeBuild |
| **Không tạo repo CodeCommit** | Layer này trỏ tới repo đã có. Repo là nơi chứa lịch sử thay đổi hạ tầng; tạo và xoá nó bằng cùng một `terraform destroy` với pipeline là một ý tồi |

---

## Cài đặt

Hai layer trỏ vào nhau, nên lần đầu phải apply **ba lượt**:

```bash
# 1. Layer này, chưa có role mạng
cd landing-zone/vending-pipeline
cp -n terraform.tfvars.example terraform.tfvars
#    enable = true, network_deploy_role_arn = ""
terraform init -backend-config=backend.hcl
terraform apply
terraform output codebuild_role_arn

# 2. Layer network tạo role phía bên kia
cd ../network
#    pipeline_trusted_role_arns = ["<ARN vừa lấy>"]
terraform apply
terraform output pipeline_deploy_role_arn
terraform output -raw transit_gateway_id

# 3. Quay lại, điền hai giá trị
cd ../vending-pipeline
#    network_deploy_role_arn = "..."
#    transit_gateway_id      = "tgw-..."
terraform apply

# 4. Đẩy tfvars của bốn layer lên kho của pipeline
./push-tfvars.sh
```

Rồi bốn việc còn lại:

```bash
# Xác nhận địa chỉ nhận thư — chưa bấm thì không nhận được gì
aws sns list-subscriptions-by-topic --region ap-southeast-1 \
  --topic-arn "$(terraform output -raw approval_topic_arn)" \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
```

`SubscriptionArn` còn là `PendingConfirmation` = chưa bấm xác nhận, và Terraform vẫn báo tạo thành công.

**Đẩy code lên CodeCommit.** Pipeline đọc từ repo CodeCommit, không đọc GitHub. Commit vào GitHub không kích hoạt gì cả.

**Lần chạy đầu tiên phải là một lần không có account mới.** Mọi stage phải ra `KHÔNG CÓ THAY ĐỔI`. Duyệt sáu lần để xem đường đi có thông không — **trước** khi một account thật đi qua nó.

**Bật `vending_state` ở ba layer nhận** trước khi tin vào stage E và F, xem [doc 27](../../docs/27-Van-hanh-Account-Vending.md). Không có nó thì pipeline vẫn chạy nhưng `accounts_by_scope` và `excluded_accounts` vẫn là giá trị gõ tay — tức stage E và F không làm gì với account mới.

---

## Thêm một account, khi pipeline đã chạy

```bash
# Một khối vào catalog/accounts.yaml, ĐỦ CẢ khối network:
#   (khác quy trình tay: bước 2 và 3 giờ nằm trong pipeline)
git commit && git push codecommit main
```

Rồi mở console, duyệt sáu lần, đọc plan trước mỗi lần. Stage A tạo account; stage B chia sẻ TGW; stage C dựng VPC; stage D nối route table; E và F cắm account vào lớp phát hiện và lớp truy cập.

Khác biệt lớn nhất so với làm tay: **khối `network:` khai được ngay từ đầu**, catalog không phải sửa hai lần.

Điều làm được chuyện đó **không** phải thứ tự stage. Stage A và stage C là cùng một layer, và thứ tự giữa các stage không tách được hai việc nằm trong cùng một `terraform apply` — Terraform xếp theo phụ thuộc tài nguyên, nên `spoke_network` chạy ngay sau `aws_organizations_account`, không chừa chỗ cho stage B chen vào.

Thứ làm được là **`-target`**:

```hcl
# main.tf, stage A
targets = ["aws_organizations_account.this"]
```

Stage A apply đúng một resource. Stage B mới chia sẻ TGW. Stage C apply cả layer.

Câu này từng được viết ở đây như một hệ quả hiển nhiên của sơ đồ `A → B → C`, và nó sai suốt cho tới khi hai account thật đi qua — xem lỗi 103 doc 22. Sơ đồ mô tả thứ tự **mong muốn**; `-target` là dòng code duy nhất bắt buộc nó.

---

## Khi hỏng

| Triệu chứng | Nguyên nhân |
|---|---|
| Stage plan báo `LOI: state RONG` | Sai khoá trong `layer_keys`, hoặc backend chưa được cấu hình. Đối chiếu `cd ../tf-backend && terraform output layers` |
| `Error acquiring the state lock` … `DynamoDB: PutItem` | Đọc như một khoá đang bị giữ, nhưng nếu **không** có khối `Lock Info` đi kèm thì chưa từng có khoá nào — là thiếu quyền DynamoDB trên bảng khoá. `init` không lấy khoá nên mọi bước trước đó vẫn xanh |
| Stage plan báo `LOI: khong lay duoc terraform.tfvars` | Chưa chạy `./push-tfvars.sh`, hoặc chạy trước lần apply tạo bucket. Thông báo in nguyên câu AWS trả về |
| Stage nào đó plan ra **rất nhiều `destroy`** | Gần như luôn là tfvars sai hoặc cũ, không phải hạ tầng sai. Đừng duyệt. So `aws s3api head-object` trên khoá tfvars của layer đó với file ở máy |
| Build chết ngay sau `... resource trong state`, không in `== plan` | `cd` bằng đường dẫn tương đối lần thứ hai. CodeBuild chạy mọi lệnh trong **cùng một shell** nên thư mục giữ nguyên giữa các khối `- \|`. Phải dùng `$CODEBUILD_SRC_DIR` |
| Stage apply báo `khong thay file tfplan` | Artifact từ stage plan không tới. Xem `input_artifacts` của action |
| Stage chờ báo `HET GIO` | Attachment kẹt ở trạng thái không phải `available` — StackSet ở account đích hỏng giữa chừng. Xem CloudFormation **ở account đó**, không phải ở đây |
| Stage chờ báo `LOI: khong goi duoc describe...` | Thiếu quyền, không phải còn đang chờ. Hai cái này cố tình tách ra — gộp lại thì một lỗi quyền hiện ra thành một vòng chờ đến hết giờ |
| Pipeline không bao giờ chạy | `PollForSourceChanges = false`, nên nó phụ thuộc EventBridge rule. Kiểm rule và nhánh — một nhánh không ai merge vào là một pipeline không bao giờ chạy, và không có gì báo |
| Thư duyệt không tới | Địa chỉ chưa bấm xác nhận SNS |
| Layer network dựng resource ở **management** | `assume_role_arn` không tới được provider. Đọc dòng `Danh tinh CodeBuild` ở đầu log, và `account-guard` của layer đó phải chặn trước khi kịp tạo gì |

---

## Liên quan
| | |
|---|---|
| [27 – Vận hành account vending](../../docs/27-Van-hanh-Account-Vending.md) | Năm bước làm tay, và code chạy ra sao |
| [10 – CI/CD cho landing zone](../../docs/10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) | GitHub Actions + OIDC. Sống chung được: Actions lo phản hồi trên PR, pipeline này lo apply |
| [`account-baseline`](../account-baseline/README.md) | Catalog, năm bước, và số đo lần chạy đầu |
| [22 – Nhật ký lỗi](../../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) | Mục 7ar–7as: chín lỗi của chính quy trình này |
