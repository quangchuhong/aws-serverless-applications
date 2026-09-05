# 27 — Vận hành account vending: các bước, và code chạy ra sao

Tài liệu này nói về [`landing-zone/account-baseline`](../landing-zone/account-baseline/) — bản DIY thay cho AFT. Hai phần: **làm gì theo thứ tự nào**, và **code làm gì khi bạn chạy nó**.

Doc [09](./09-Account-Vending-Tu-Dong.md) là thiết kế; tài liệu này là thứ đã chạy thật.

---

## 0. Trạng thái đo được

Ba account vending qua catalog, đủ năm bước, `verify.sh` ở layer `network` ra **60 đạt / 0 lỗi**.

| Account | ID | OU | CIDR | Nhận gì |
|---|---|---|---|---|
| `app-uat` | `598122632665` | Workloads/Non-Production | `10.12.0.0/16` | VPC + TGW + DNS tập trung |
| `app-payments-prod` | `913051689123` | Workloads/Production | `10.21.0.0/16` | VPC + TGW + DNS + `prod_guard` |
| `sandbox-thu-nghiem` | `792207721718` | Sandbox | `10.60.0.0/16` | VPC, **không** TGW, **không** DNS |

Cả ba: default VPC bị xoá ở cả hai region, bốn mục hardening áp dụng, có mặt trong `accounts_by_scope`, và người dùng vào được qua Identity Center.

---

## 1. Ba tầng, và vì sao không gộp được

Một account mới cần ba thứ do **ba layer khác nhau** sở hữu, và mỗi thứ chỉ một phía làm được:

| Tầng | Layer | Chạy ở account | Làm gì |
|---|---|---|---|
| 1 | `account-baseline` | management | Tạo account, xoá default VPC, hardening |
| 2 | `network` | account mạng | Chia sẻ TGW, nối attachment vào `rtb-spokes` |
| 3 | `permission-sets` | management (delegated admin) | Ai vào được account đó |

Ranh giới account là thứ chia việc, không phải sở thích tổ chức code:

- **Tạo account** chỉ management làm được.
- **VPC và attachment** phải được tạo *bên trong* account đích — Terraform ở đây chỉ có một provider, trỏ vào management, nên nó dùng CloudFormation StackSet.
- **Nối attachment vào route table** chỉ **chủ sở hữu TGW** làm được, và attachment hiện ra ở account mạng chứ không phải account workload.

Chiều thứ ba đi ngược chiều hai chiều kia. Đó là lý do có bước 5.

---

## 2. Runbook — năm bước

> **Account hạ tầng** (không có khối `network:`) chỉ cần **bước 1**. Bốn bước còn lại là giá của việc nối một account vào lưới mạng.

### Bước 0 — trước khi gõ gì

```bash
cd landing-zone/account-baseline

# Đúng danh tính: layer này KHÔNG assume role, nó dùng thẳng credential trong shell
aws sts get-caller-identity --query Account --output text     # phải là management

# ou_ids phải có khoá khớp trường `ou` trong catalog
cd ../organization && terraform output ou_ids
grep -n -A8 '^ou_ids' ../account-baseline/terraform.tfvars
```

Khoá của `ou_ids` phụ thuộc `ou_structure` bên layer `organization`. Cây lồng nhau cho `"Workloads/Production"`; cây phẳng cho `"Production"`. **Đọc kỹ thứ tự sắp xếp** — Terraform in map theo bảng chữ cái, nên `Non-Production` xuất hiện *sau* `Workloads` là dấu hiệu khoá thật mang tiền tố `Workloads/`. Đọc nhầm chỗ này đã tạo ra lỗi 91.

### Bước 1 — tạo account

Thêm một khối vào `catalog/accounts.yaml`. **Chưa có khối `network:`** — TGW không chia sẻ được cho một account chưa tồn tại.

```yaml
- name: app-uat
  email: ban+lz-app-uat@gmail.com
  ou: NonProd                      # KHOÁ trong var.ou_ids, không phải ID
  scope: nonprod                   # analytics | nonprod | prod | none
  environment: staging             # dev | staging | prod | sandbox
  owner: platform@example.com
  cost_center: CC-1042
  ticket: ACC-2026-001
  note: Môi trường UAT
```

```bash
./lint.sh          # offline, không gọi AWS — chạy trước là nhanh nhất
terraform plan     # 0 to destroy, và KHÔNG có stack_set_instance.spoke_network
terraform apply
terraform output created_accounts
```

### Bước 2 — chia sẻ TGW

```hcl
# landing-zone/network/terraform.tfvars
share_tgw_with_accounts = ["598122632665", "913051689123"]
```

```bash
cd ../network && terraform apply
```

Bỏ qua account khai `attach_tgw: false` — nó không dùng TGW.

### Bước 3 — account nhận lời mời RAM

```bash
cd ../account-baseline
./accept-ram.sh 598122632665 913051689123
```

Chạy bằng credential **management**: `OrganizationAccountAccessRole` trong account mới chỉ tin management account. Chạy từ nơi khác cho ra `AccessDenied ... not authorized to perform: sts:AssumeRole`, đọc như thiếu quyền, và cấp thêm quyền không sửa được gì.

Với account **trong cùng tổ chức**, AWS thường tự chấp nhận và script báo `da nhan tu truoc` — đó là kết quả đúng, không phải bỏ sót.

### Bước 4 — mạng nền

Giờ mới thêm khối `network:` vào chính khối account đó:

```yaml
  network:
    vpc_cidr: 10.12.0.0/16
    # attach_tgw: false      # sandbox: VPC cô lập, và DNS tập trung tự tắt theo
```

Cần `network_handles` trong `terraform.tfvars` của layer này:

```bash
cd ../network && terraform output -raw paste_network_handles
```

```bash
cd ../account-baseline
./lint.sh && terraform plan
terraform apply
```

Nếu quên `network_handles`, **precondition dừng plan**. Không phải cảnh báo: template cố ý không tạo IGW và không tạo NAT, nên thiếu nốt TGW thì VPC dựng lên không có đường nào đi đâu cả.

### Bước 5 — nối attachment vào route table

```bash
terraform output -raw paste_spokes
```

Dán **hai mục bên trong** vào khối `spokes = { … }` đang có ở `network/terraform.tfvars` — **không** dán cả dòng `spokes = {` và `}`.

Đây là chỗ hỏng im lặng nhất trong cả quy trình: dán cạnh khối thay vì vào trong biến hai mục đó thành khoá cấp cao nhất của tfvars, và Terraform chỉ kêu `Warning: Value for undeclared variable` rồi chạy tiếp. `Apply complete`, `0 changed`, hai account không bao giờ được nối.

**Đếm trước khi apply:**

```bash
cd ../network
python3 -c "
import re
s=open('terraform.tfvars').read()
i=s.find('spokes')
print(re.findall(r'\"([a-z0-9-]+)\"\s*=\s*\{', s[i:s.index('\n}',i)]))"
```

```bash
terraform apply     # có thể phải chạy HAI lần — xem mục 4
./verify.sh         # mục 6c phải liệt kê attachment mới kèm dòng "đường về đã học CIDR"
```

### Sau đó — ba bàn giao còn lại

```bash
cd ../account-baseline
terraform output -raw paste_permission_sets     # → permission-sets: ai vào được
terraform output -raw paste_config_detective    # → config-detective: ai bị loại trừ
./check-sweep.sh                                # default VPC + hardening, đọc từ AWS
```

`paste_config_detective` không phải tuỳ chọn: mọi account ACTIVE phải **hoặc** nằm trong một OU của `recorder_target_ous`, **hoặc** nằm trong `excluded_accounts`. Account rơi ra ngoài cả hai làm organization Config rule ngồi `CREATE_IN_PROGRESS` hàng chục phút rồi `CREATE_FAILED`.

---

## 3. Code chạy ra sao

### 3.1. Catalog → account

```
catalog/accounts.yaml
  └─ yamldecode           local.catalog_raw       danh sách thô
      └─ ou → parent_id    local.catalog_accounts  qua var.ou_ids
          └─ merge         local.accounts          + var.create_accounts
              └─ for_each  aws_organizations_account.this
```

Ba điều quyết định hành vi:

**Khoá là TÊN account, và khoá đi vào state.** Đổi tên một khối trong catalog **không** đổi tên account thật. Terraform thấy một khoá biến mất và một khoá mới xuất hiện, tức: **tạo một account mới**, và gỡ account cũ khỏi state. Cả hai gần như không hoàn tác được. `prevent_destroy` chặn vế thứ hai; không có gì chặn vế thứ nhất ngoài việc đọc kỹ.

**`ou` là TÊN, không phải ID.** `ou-abc1-x9y8z7w6` gõ nhầm một ký tự vẫn là chuỗi hợp lệ, chỉ trỏ vào một OU khác — và Terraform báo một lỗi API không nhắc gì tới việc bạn gõ nhầm. Tên thì đối chiếu được với `var.ou_ids` và dừng ở plan kèm danh sách tên hợp lệ.

**`var.create_accounts` đè catalog.** Đó là đường cũ, giữ cho account tạo trước khi có catalog. Khai ở cả hai chỗ thì precondition dừng plan — không để tfvars lặng lẽ thắng.

**`close_on_deletion = false` mặc định.** `terraform destroy` chỉ gỡ khỏi state, **không** đóng account. Có chủ đích: account đóng rồi phải chờ 90 ngày, và email không bao giờ dùng lại được.

### 3.2. Hai StackSet, hai mục đích khác hẳn nhau

| | `<project>-account-baseline` | `<project>-spoke-network` |
|---|---|---|
| Làm gì | Xoá default VPC + hardening | VPC, subnet, TGW attachment, DNS |
| Triển khai tới | **OU** (`baseline_target_ous`) | **Từng account một** |
| `auto_deployment` | **Bật** | **Tắt** |
| `failure_tolerance` | 10% | **0%** |

Khác biệt đó có lý do:

**Sweep làm cùng một việc cho mọi account**, không tham số riêng, nên deploy thẳng xuống OU và bật `auto_deployment` — account mới vào OU tự nhận, không cần chạy lại Terraform. Đó chính là cơ chế baseline.

**Mạng thì mỗi account một CIDR khác nhau**, tức mỗi account một bộ tham số, mà tham số chỉ đè được theo từng instance. Và `auto_deployment` ở đây sẽ **nguy hiểm**: một account mới vào OU sẽ nhận CIDR mặc định, tức trùng dải với nhau ngay từ ngày đầu.

**`failure_tolerance = 0` cho mạng** vì một VPC dựng nửa chừng, hoặc attachment tạo mà route không tạo, để lại một trạng thái không ai đọc được bằng mắt. Sweep thì độc lập giữa các account — hỏng ở một chỗ không có lý do gì làm dừng chỗ khác.

`deployment_targets` của spoke dùng `account_filter_type = "INTERSECTION"`: StackSet service-managed **bắt buộc** khai OU, còn `accounts` chỉ là bộ lọc bên trong OU đó. Thiếu `account_filter_type` thì `accounts` bị bỏ qua và stack triển khai ra **cả OU** — mọi account trong đó nhận một VPC cùng CIDR.

### 3.3. Lambda quét — vì sao là custom resource

CloudFormation không có resource nào cho "xoá default VPC", "bật EBS encryption mặc định", "đặt IAM password policy", hay "gỡ rule của default SG". Bốn thứ đó không có resource gốc, nên chúng đi cùng một Lambda.

```
Sweep (AWS::CloudFormation::CustomResource)
  ├─ Regions = var.sweep_regions
  ├─ Version = var.sweep_version        ← đổi giá trị này để BUỘC chạy lại
  └─ Harden  = { PasswordPolicy, S3PublicAccessBlock, EbsEncryption, LockDefaultSg, … }
```

**Cấu hình nằm trong thuộc tính custom resource, không nằm trong code Lambda.** Lý do: CloudFormation chỉ gọi lại hàm khi **thuộc tính đổi**. Đổi một biến hardening mà không có nó trong thuộc tính thì stack không làm gì cả — kiểu hỏng im lặng. Cùng lý do với `Version`: thêm region vào `sweep_regions` mà không đổi `sweep_version` thì không có gì xảy ra.

**IAM cấp quyền theo từng công tắc.** `harden_s3_public_access_block = false` thì role không có `s3:PutAccountPublicAccessBlock` — nó không làm được việc đó kể cả khi ai đó sửa code Lambda.

**`try` riêng cho từng việc, và không nuốt lý do.** Xoá VPC và hardening có `try` riêng: một default VPC không xoá được (còn ENI gắn vào) sẽ ném lỗi, và nếu hai việc dùng chung một `try` thì hardening của **cả region đó** bị bỏ qua vì một lý do không liên quan.

Mỗi lỗi ghi vào `SweepResult` kèm **mã lỗi thật** của AWS:

```
iam/password-policy, s3/public-access-block, ap-southeast-1/ebs-encryption,
ap-southeast-1/default-sg:sg-03aeaedba63e2d244, us-east-1/ebs-encryption
```

Trước đây nó ghi `type(e).__name__`, tức `ClientError` cho **mọi** lời từ chối của AWS. Chính chữ đó đã che một SCP tự khoá suốt nhiều tháng — xem [doc 22 mục 7as](./22-Nhat-ky-Trien-khai-LZ-DIY.md).

**`import cfnresponse` không được dùng.** Với `python3.12` module đó không có sẵn, và hỏng ở đây là hỏng theo kiểu tệ nhất: Lambda chết lúc **khởi tạo**, trước khi vào `try`, nên không nhánh nào gửi được phản hồi. CloudFormation ngồi chờ **hết một giờ** rồi mới bỏ cuộc, và các account còn lại xếp hàng `PENDING` đằng sau. Hàm tự gửi phản hồi bằng `urllib`.

### 3.4. Chốt chặn — `check` và `precondition` khác nhau thế nào

Quy tắc trong repo này: **`check` cảnh báo, `precondition` dừng plan**. Chọn cái nào là một quyết định về hậu quả.

| Chốt | Loại | Vì sao |
|---|---|---|
| Chạy sai account (không phải management) | **precondition** | `DescribeOrganization` **vẫn chạy** ở account thành viên, nên plan vẫn xanh và in đủ kế hoạch; apply chết ở **giữa**, sau khi một phần StackSet đã tạo |
| Tên OU không giải được thành ID | **precondition** | Lỗi API không nhắc gì tới việc bạn gõ nhầm tên |
| Account khai ở cả catalog lẫn `create_accounts` | **precondition** | tfvars đè catalog lặng lẽ |
| Hai account trùng email | **precondition** | AWS từ chối cái thứ hai ở **giữa** apply, sau khi cái thứ nhất đã tạo |
| Xin nối TGW mà `network_handles` rỗng | **precondition** | VPC không IGW, không NAT, không TGW = không đường nào đi đâu; sửa sau là một CloudFormation UPDATE trên stack ở account khác |
| Không có `dns_profile_id` | `check` | VPC **vẫn định tuyến được**; chỉ là tên AWS phân giải ra IP công khai và trả phí NAT cho chuyến đi đó |
| `close_accounts_on_destroy = true` | `check` | Một lựa chọn hợp lệ, nhưng phải nhìn thấy |
| Account tạo thẳng vào ROOT | `check` | SCP gắn vào OU; account ở root mất `network_lock` và `prod_guard` mà vẫn chạy bình thường |

`lint.sh` đứng **trước** cả hai: nó đọc catalog, chạy offline, và bắt được phần lớn lỗi trước khi ai đó có credential trong tay.

### 3.5. Bốn bàn giao, và vì sao chúng là output chứ không phải resource

Layer này **không sửa được `terraform.tfvars` của layer khác** — mỗi layer một state, và tfvars nằm trong `.gitignore`. Nhưng nó biết đủ để sinh sẵn khối HCL:

| Output | Dán vào | Bỏ qua thì |
|---|---|---|
| `paste_spokes` | `network` | VPC có, attachment có, **không gói tin nào đi đâu** |
| `paste_permission_sets` | `permission-sets` | Không ai vào được account mới, và người ta sẽ quay ra dùng root |
| `paste_config_detective` | `config-detective` | Organization rule treo rồi `CREATE_FAILED` |
| `network_handles` (chiều ngược) | layer này | Precondition dừng plan |

`paste_spokes` **cố ý bỏ** account khai `attach_tgw: false`. Đưa chúng sang `var.spokes` làm `check "remote_attachments_wired"` bên layer `network` lệch vĩnh viễn — nó đếm số spoke đã khai so với số attachment tìm được, và một account không bao giờ tạo attachment thì phép đếm đó không bao giờ khớp. Thông báo của check bảo *"chạy lại apply một lần nữa"*, một việc không sửa được nguyên nhân.

### 3.6. `attach_dns` mặc định bằng `attach_tgw`

Không phải sở thích — là kỹ thuật. Route 53 Profile mang PHZ trỏ tên dịch vụ AWS vào **interface endpoint** đặt ở security VPC, dải `10.1.0.0/16`. Một VPC không nối TGW **không có đường tới dải đó**.

Gắn profile cho VPC không attach nghĩa là mọi lời gọi API của AWS trong đó phân giải ra một địa chỉ **không đi tới được** — tệ hơn hẳn IP công khai, vì ít ra IP công khai còn đi được. Triệu chứng đọc như *"account mới hỏng hoàn toàn"*, và chỗ đầu tiên người ta tìm là endpoint, nơi không có gì sai.

---

## 4. Triệu chứng → nguyên nhân

| Triệu chứng | Nguyên nhân thật | Kiểm bằng |
|---|---|---|
| `Apply complete, 0 changed` mà account mới không được nối | `paste_spokes` bị dán **cạnh** khối `spokes` thay vì vào trong → khoá cấp cao nhất → chỉ là `Warning: Value for undeclared variable` | Đếm spoke trong tfvars (mục 2 bước 5) |
| `verify.sh` 6c: attachment `KHONG thuoc route table nao` | Data source lọc `state = available`; attachment cross-account mất ~1 phút để chuyển từ `pending` | `terraform apply` lần hai |
| `invalid transit gateway ID` khi tạo VPC | Bước 2/3 chưa xong — TGW chưa được chia sẻ. Câu lỗi nói về ID trong khi vấn đề là quyền nhìn thấy | `./accept-ram.sh <id>` |
| `AccessDenied ... sts:AssumeRole` | Không phải thiếu quyền — **sai account**. `OrganizationAccountAccessRole` chỉ tin management | `aws sts get-caller-identity` |
| `unmapped_accounts` rỗng ngay sau khi tạo account | Nó tính từ data source, đọc **trước** khi account tồn tại | Chạy `terraform plan` lần nữa |
| `SweepResult` có `SKIP` ở region ngoài `allowed_regions` | `region_lock` SCP từ chối `ec2:DeleteVpc`. Default VPC ở region bị khoá là vô hại | Bình thường, bỏ qua |
| `SKIP` ở region **trong** `allowed_regions` | Mới là vấn đề — đọc mã lỗi | `./check-sweep.sh` |
| Stack `CURRENT` nhưng default VPC vẫn còn | `CURRENT` chỉ nói Lambda chạy xong. Nó bắt lỗi và ghi `SKIP`, cố ý | `./check-sweep.sh` — hỏi cả AWS, không chỉ đọc output |
| Đổi biến hardening mà không có gì xảy ra | Custom resource chỉ chạy lại khi thuộc tính đổi | Tăng `sweep_version` |

---

## 5. Thêm, sửa, đóng

**Thêm account** — năm bước ở mục 2.

**Sửa CIDR của một account đã có VPC** — không sửa được tại chỗ. `VpcCidr` là tham số của stack, đổi nó là CloudFormation thay VPC, tức xoá mọi thứ bên trong. Cách đúng là thêm CIDR phụ vào VPC hiện có, ngoài phạm vi layer này.

**Đổi tên account** — đừng. Đổi `name` trong catalog tạo một account **mới** và gỡ account cũ khỏi state.

**Đóng account** — `close_accounts_on_destroy` mặc định `false`, nên `terraform destroy` chỉ gỡ khỏi state. Muốn đóng thật thì làm bằng tay ở console, và nhớ: 90 ngày chờ, và email **không bao giờ dùng lại được** ở phạm vi AWS toàn cầu.

**Gỡ một khối khỏi catalog** — không đóng account. Nó chỉ rời khỏi state, và từ đó không còn ai quản lý nó bằng code.

---

## 6. Công cụ

| | |
|---|---|
| `./lint.sh` | Đọc catalog, chạy offline. Chạy trước Terraform là nhanh nhất |
| `./accept-ram.sh` | Bước 3. Không `export` credential nào ra shell — mỗi lệnh AWS nhận biến đặt ngay trước nó |
| `./check-sweep.sh` | Hỏi **hai** câu: Lambda kể gì, và AWS nói hiện còn gì. Chỉ câu thứ hai là bằng chứng |

Cả hai script kiểm danh tính là management **trước** khi thử, vì `AccessDenied` từ `sts:AssumeRole` đọc như thiếu quyền chứ không như sai account.

---

## Liên quan
| | |
|---|---|
| [`account-baseline/README.md`](../landing-zone/account-baseline/README.md) | Chi tiết từng biến, và số đo của lần chạy đầu |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Thiết kế gốc, quy ước email |
| [24 – Triển khai network cross-account](./24-Trien-khai-Network-LZ-Cross-Account.md) | Bốn pha dựng nền + pha 5 lớp ops. Bước 2–5 ở đây là bản thu nhỏ về một account |
| [25 – Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md) | Lớp `ops`, và mục 3c về backend |
| [17 – Network design guide](./17-Network-LZ-Design-Guide.md) | Bảng cấp phát CIDR ở mục 3 |
| [22 – Nhật ký lỗi](./22-Nhat-ky-Trien-khai-LZ-DIY.md) | Mục 7ar–7as: chín lỗi của chính quy trình này |
| [11 – Tag policy](./11-Tag-Policy-va-Cost-Allocation.md) | `environment` hợp lệ, và vì sao không có `shared` |
