# Lớp vận hành mạng — thêm/sửa/xoá hằng ngày

Layer cha (`../`) dựng nền: Transit Gateway, security VPC, firewall, egress, ingress, các VPC spoke. Nó đổi vài tháng một lần.

Thư mục này quản **bốn thứ đổi hằng ngày**, trong một state riêng:

| Việc | File | Resource sinh ra |
|---|---|---|
| Mở/đóng port giữa các app ở VPC khác nhau | `catalog/firewall-rules.yaml` | một rule group Network Firewall |
| Route ngoại lệ trong TGW | `catalog/routes.yaml` | `aws_ec2_transit_gateway_route` |
| Thêm/bớt VPC endpoint tập trung | `catalog/endpoints.yaml` | endpoint + PHZ + bản ghi + Profile association |
| Bản ghi DNS trong PHZ tập trung | `catalog/dns-records.yaml` | `aws_route53_record` |

`catalog/apps.yaml` không tạo resource nào — nó là bảng tra cứu **tên app → dải địa chỉ**, để ba file kia khai bằng tên.

---

## Vì sao tách state

Gộp chung thì mở một port là một `terraform plan` chạm vào hơn 200 resource: firewall endpoint, NAT, mọi subnet, mọi stack instance cross-account. Người duyệt phải đọc hết để biết plan đó *không* làm gì khác ngoài thêm một dòng rule. Làm vậy mỗi ngày thì không ai đọc thật, và đến một ngày có người bấm yes quá nhanh — đúng lúc plan đó chứa một thay đổi không ai để ý.

Tách ra thì plan của lớp này chạm đúng bốn loại resource. Kịch bản xấu nhất của một lần apply sai ở đây là một rule sai hoặc một bản ghi DNS sai — sửa bằng một commit. Không lần nào chạm được vào firewall endpoint hay route mặc định, vì chúng không nằm trong state này.

Đổi lại: hai lớp phải khớp nhau ở **đúng một điểm**, và đó là phần bootstrap dưới đây.

---

## Vì sao khai bằng tên chứ không phải CIDR

`east_west_rules` ở layer cha khai CIDR thô:

```hcl
from_cidr = "10.10.0.0/16"
```

Gõ nhầm một chữ số — `10.10` trong khi spoke thật là `10.11` — thì `terraform apply` vẫn xanh, firewall vẫn nạp rule, và rule đó không khớp một gói tin nào trọn đời. Không lỗi, không cảnh báo, không dòng log nào nói "rule 1003 chưa từng khớp". Người mở ticket báo vẫn không kết nối được, và chỗ đầu tiên ai cũng đi kiểm là route và security group — hai chỗ hoàn toàn đúng.

Khai bằng tên thì gõ nhầm là Terraform dừng ngay ở plan, kèm danh sách tên hợp lệ:

```
apps.yaml: order-api khai spoke khong co trong layer cha.
Spoke hop le: app-dev, app-prod, logarchive, probe, security
```

Cùng loại im lặng đã gặp ở lỗi 62 (spoke đổi tên `app-dev` → `probe`, hai mục kiểm chứng không in gì cả).

---

## Bootstrap — làm đúng một lần

Firewall policy tham chiếu rule group bằng ARN, mà ARN chỉ tồn tại sau khi rule group được tạo. Vòng phụ thuộc đó chỉ có một cách cắt:

```bash
# 0. Đưa output ops_handles vào state của layer cha.
#    Chỉ thêm output, không đổi resource nào — plan sẽ báo "0 to add,
#    0 to change". Nhưng thiếu bước này thì bước 1 hỏng ngay ở init
#    với "This object does not have an attribute named ops_handles",
#    và thông báo đó không nói là bạn quên apply layer cha.
cd demo/network-lz-full
terraform apply

# 1. Tạo rule group ở lớp ops
cd ops
terraform init
terraform apply
terraform output -raw rule_group_arn

# 2. Cắm ARN đó vào layer cha, apply một lần nữa
cd ..
#    THÊM dòng sau vào terraform.tfvars (sửa, đừng `echo >>` - dựng
#    lại lần hai sẽ thành hai dòng và Terraform báo Attribute redefined):
#      ops_rule_group_arns = ["arn:aws:network-firewall:..."]
terraform apply
```

Từ đó về sau ARN không đổi nữa. Sửa catalog chỉ làm đổi `rules_string` bên trong rule group — một thuộc tính sửa tại chỗ, không tạo lại resource, **không cần ai apply layer cha**.

### Hai lỗi hay gặp ở bước 0–1

`./lint.sh` kiểm cả hai trước khi Terraform chạy, nên chạy nó trước là nhanh nhất.

| Terraform báo | Nghĩa thật |
|---|---|
| `Unable to find remote state` / `No stored state was found` | Không thấy state của layer cha. Câu này **không in ra đường dẫn đã thử** và đọc y hệt như "layer cha chưa bao giờ được apply" — trong khi nguyên nhân thường gặp nhất là layer cha dùng **backend S3**, nên trên đĩa không có file nào cả. `lint.sh` đọc `../.terraform/terraform.tfstate` và in ra khối `state_config` dán được ngay |
| `This object does not have an attribute named "ops_handles"` | State có, nhưng layer cha chưa apply lại sau khi kéo code mới về — tức là bỏ qua bước 0 |

Đường dẫn state mặc định tính theo **vị trí file `.tf`** (`${path.module}/../terraform.tfstate`), không theo thư mục đang chạy. Backend `local` của `terraform_remote_state` giải đường dẫn tương đối theo thư mục đang chạy — hai cái đó trùng nhau khi gõ `cd ops && terraform apply` và lệch nhau khi gõ `terraform -chdir=ops apply` hoặc khi chạy từ CI.

Nếu state của layer cha nằm chỗ khác, trỏ tới nó bằng **đường dẫn tuyệt đối**:

```hcl
state_config = { path = "/Users/laptop/…/demo/network-lz-full/terraform.tfstate" }
```

### Khi layer cha dùng backend S3 — hai thứ khác nhau, cần cả hai

Rất dễ làm một nửa rồi tưởng xong, vì mỗi nửa hỏng ở một chỗ khác nhau.

| | Ở đâu | Để làm gì | Key |
|---|---|---|---|
| `state_config` | `ops/terraform.tfvars` | **Đọc** state layer cha | key **của layer cha** |
| `backend "s3"` | `ops/versions.tf` | **Ghi** state của chính lớp ops | key **của ops**, cùng prefix |

Thiếu `backend` → ops vẫn chạy nhưng state nằm trên máy một người. Thiếu `state_config` → `Unable to find remote state`.

```hcl
# ops/terraform.tfvars — ĐỌC state layer cha
state_backend = "s3"
state_config = {
  bucket  = "…"
  key     = "demo-network-lz-full/terraform.tfstate"   # key của LAYER CHA
  region  = "ap-southeast-1"
  profile = "default"                                  # nếu layer cha có
}
```

`state_config` là `map(string)` nên bỏ các giá trị không phải chuỗi (`encrypt = true`) — chúng không cần để đọc. `./lint.sh` in ra khối này đã lọc sẵn.

Nhưng khi đó **state của chính lớp ops cũng nên chuyển sang S3** — bỏ chú thích khối `backend "s3"` trong `versions.tf`. Không phải cho đồng bộ cho đẹp: state này giữ ARN của rule group mà firewall policy đang tham chiếu. Mất file đó là mất quyền sửa và quyền xoá một resource vẫn đang chạy — Terraform sẽ đòi tạo rule group thứ hai, còn cái cũ nằm lại vĩnh viễn không ai quản. Và state local nghĩa là không có khoá: hai người cùng sửa catalog thì người apply sau ghi đè người trước, không bên nào thấy diff.

**Key phải nằm dưới đúng prefix mà account này được cấp.** `landing-zone/tf-backend` cấp quyền theo prefix, mỗi account một prefix riêng (`var.state_writer_accounts`):

```
s3:ListBucket   trên bucket, điều kiện s3:prefix = "<tên>/*"
s3:GetObject    trên "<bucket>/<tên>/*"
s3:PutObject    trên "<bucket>/<tên>/*"
```

Đặt một prefix mới (`network-ops/`) thì không có dòng Allow nào phủ, và `terraform init` báo:

```
Error refreshing state: ... HeadObject ... StatusCode: 403
api error Forbidden: Forbidden
```

**403 chứ không phải 404**, dù object chưa hề tồn tại — không có `ListBucket` trên prefix đó thì S3 không được phép tiết lộ cả việc object có tồn tại hay không. Và 403 đọc như "sai credential", nên chỗ đầu tiên ai cũng đi kiểm là vai trò và profile.

### Cách đúng: đăng ký như một layer của `tf-backend`

Lớp này giờ có tên trong `local.layers` (`landing-zone/tf-backend/outputs.tf`), nên backend được **sinh ra** chứ không gõ tay:

```bash
# 1. Khai profile cho lớp ops — cùng profile với layer cha
#    landing-zone/tf-backend/terraform.tfvars
#      backend_profiles = {
#        "demo/network-lz-full"     = "default"
#        "demo/network-lz-full/ops" = "default"
#      }

# 2. Apply tf-backend (0 resource đổi, chỉ Outputs) rồi sinh file
cd landing-zone/tf-backend
terraform apply
./wire-backends.sh              # ghi backend.tf + backend.hcl vào ops/

# 3. Tạo sẵn object rỗng cho key mới — bước không ai đoán được
aws s3api put-object --bucket <bucket> \
  --key 'demo-network-lz-full/ops/terraform.tfstate'

# 4. Nối
cd demo/network-lz-full/ops
terraform init -backend-config=backend.hcl
```

**Đừng gõ tay khối `backend "s3"` vào `versions.tf`** — `wire-backends.sh` ghi `backend.tf` riêng, và hai khối `backend` trong một module là lỗi. Thêm dòng thẳng vào `backend.hcl` cũng vô ích: file đó bị ghi đè mỗi lần chạy script, nên sửa tay sẽ biến mất im lặng.

Bước 3 cần vì `ListBucket` mang điều kiện `s3:prefix`, mà khoá đó chỉ có trong yêu cầu list — `HeadObject` thì không. Chi tiết ở [`landing-zone/tf-backend/README.md`](../../../landing-zone/tf-backend/README.md).

### Khi phải xem cấu hình backend của layer cha

```bash
./backend-hint.sh
```

Nó đọc `../.terraform/terraform.tfstate` (file `terraform init` của layer cha ghi ra), in lại **nguyên khối backend** với đúng một thay đổi: `key` chuyển sang cùng thư mục + `ops/`.

Giữ nguyên mọi dòng là điểm mấu chốt. Cấu hình backend có thể mang `role_arn`, `profile` hoặc `assume_role` — thiếu chúng thì Terraform vẫn báo `Successfully configured the backend`, rồi hỏng ở bước đọc state với đúng cái 403 ở trên. **403 đó không phải vì key sai**: lớp ops đang gọi S3 bằng một *danh tính khác* layer cha — credential mặc định trong shell, thay vì vai trò mà layer cha vào. Cùng bucket, cùng vùng, khác người gọi.

Và vì S3 trả 403 chứ không phải 404 khi thiếu `ListBucket`, một thông báo duy nhất phủ ba nguyên nhân hoàn toàn khác nhau:

- key nằm ngoài prefix được cấp
- gọi bằng danh tính khác
- bucket không tồn tại ở account đó

### `Error acquiring the state lock` — 403 trên `.tflock`

Đây là lỗi **hữu ích nhất** trong cả nhóm, vì nó nói đủ: principal nào, hành động nào, resource nào, và vì sao.

```
User: arn:aws:sts::436908791055:assumed-role/AWSReservedSSO_lz-account-admin/quang
is not authorized to perform: s3:PutObject on resource:
"arn:aws:s3:::qh11-lz-tfstate-609320954321/demo-network-lz-full/ops/terraform.tfstate.tflock"
because no resource-based policy allows the s3:PutObject action
```

`no resource-based policy` = gọi **xuyên account**, nên phải có **bucket policy** cho phép. Backend khai `profile = "default"` (IAM user trong account chứa bucket), nhưng shell đang mang credential SSO của account network — và biến môi trường đứng trước `profile`, nên profile bị bỏ qua. Account network không nằm trong `state_writer_accounts` cho prefix này, nên bucket policy không phủ.

Hai cách, khác nhau về mức độ đụng chạm:

**Nhanh — không sửa layer dùng chung.** Gỡ biến môi trường để cả hai dòng `profile` có hiệu lực: backend dùng `default` (account chứa bucket), provider dùng `var.aws_profile` (account network).

```hcl
# ops/terraform.tfvars
aws_profile = "<tên profile của account network>"
```

Rồi chạy **gỡ biến ngay trong lệnh**, đừng dựa vào `unset`:

```bash
env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  terraform plan
```

`unset` chỉ có tác dụng trong đúng shell đó, và nhiều thiết lập SSO đặt lại `AWS_PROFILE` từ `~/.zshrc` hoặc mỗi khi mở tab mới — nên "đã unset rồi mà vẫn lỗi" thường nghĩa là biến đã quay lại chứ không phải cách sửa sai. `env -u` gỡ cho **đúng tiến trình đó**, không phụ thuộc shell.

Khi ấy: backend dùng profile trong khối `backend` (account chứa bucket), provider dùng `var.aws_profile` (account network). Cả hai đọc từ `~/.aws`, không qua biến môi trường.

Nếu vẫn lỗi, bốn dòng này nói đủ để kết luận:

```bash
env | grep -oE '^AWS_[A-Z_]+'                 # biến nào còn sót (chỉ in TÊN)
aws sts get-caller-identity                   # shell đang là ai
grep -A10 'backend "s3"' versions.tf          # backend khai profile gì
grep -n 'aws_profile' terraform.tfvars        # provider khai profile gì
```

**Đúng gốc — dùng đúng thứ `tf-backend` sinh ra để làm.** Thêm account network vào `state_writer_accounts` rồi apply `landing-zone/tf-backend` từ management account. Sau đó backend không cần `profile` nữa: chính credential SSO của account network đọc ghi được state.

Cách hai bỏ luôn được IAM user dùng chung cho state — một access key dài hạn, đúng thứ [doc 10](../../../docs/10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) tồn tại để loại bỏ.

### Vẫn 403 sau khi dán nguyên khối

Hai nguyên nhân, phân biệt bằng một phép đo. Chạy `./backend-hint.sh`, nó in sẵn hai lệnh khác nhau đúng một biến: `head-object` lên một key **đã tồn tại** (của layer cha) và lên một key **chưa tồn tại**, cùng prefix.

**Cả A lẫn B đều 403 — biến môi trường đè lên `profile`**

Khối backend khai `profile = "..."`, nhưng trong chuỗi giải credential của AWS SDK thì **biến môi trường đứng trước file cấu hình**. Có `AWS_ACCESS_KEY_ID` trong shell là `profile` bị bỏ qua — với cả Terraform lẫn `aws-cli`.

Nghĩa là cùng một thư mục, cùng một file `.tf`, vẫn chạy bằng hai danh tính khác nhau tuỳ shell nào đang mở. Và không có gì báo: Terraform vẫn in `Successfully configured the backend`.

```bash
aws sts get-caller-identity                  # đang gọi bằng ai
env | grep -oE '^AWS_[A-Z_]+'                # biến nào đang đè (chỉ in TÊN)
aws sts get-caller-identity --profile default # profile default thật ra là account nào
```

Hai account đó khác nhau thì gỡ biến đi:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
terraform init -reconfigure
```

Cùng họ với lỗi 57 và 58: một phép đo đúng, trả lời cho một câu hỏi khác với câu đang hỏi.

**A được mà B trả 403 — thiếu `ListBucket`, không phải thiếu quyền key**

S3 chỉ trả 404 cho object không tồn tại **khi người gọi có `s3:ListBucket`**; không có thì nó trả 403, để không tiết lộ cả việc object đó có tồn tại hay không.

`landing-zone/tf-backend` *có* cấp `s3:ListBucket` — nhưng kèm `Condition = { StringLike = { "s3:prefix" = ["<tên>/*"] } }`. Mà `s3:prefix` chỉ có mặt trong yêu cầu **list**. `HeadObject` không phải lệnh list, nên khoá đó không có trong ngữ cảnh, `StringLike` không khớp, và `ListBucket` coi như không được cấp.

Hệ quả: key **đã tồn tại** thì đọc ghi bình thường; key **chưa tồn tại** thì 403. Nghĩa là **mọi layer mới đều hỏng ở lần `init` đầu tiên, và chỉ lần đầu** — đó là lý do layer cha chạy tốt suốt còn lớp ops thì không.

**Cách đi qua** — tạo sẵn object rỗng, một lần cho mỗi layer mới:

```bash
aws s3api put-object --bucket <bucket> --key '<prefix>/ops/terraform.tfstate'
```

Không có `--body` nên object rỗng; Terraform đọc payload rỗng là coi như chưa có state — đúng cái nó cần ở lần init đầu.

Cách kia là bỏ điều kiện `s3:prefix` khỏi statement `ListBucket` trong `tf-backend`. Sửa hẳn gốc, nhưng phải apply một layer dùng chung cho cả tổ chức, và account đó sẽ nhìn thấy **tên key** của mọi prefix khác — không đọc được nội dung, vì quyền object vẫn theo prefix. Rò rỉ tên key là nhỏ, nhưng có thật, nên đây là một lựa chọn có đánh đổi chứ không phải bản sửa hiển nhiên.

Kiểm bootstrap đã xong chưa:

```bash
terraform apply                   # 0 added, 0 changed — chỉ cập nhật Outputs
terraform output bootstrap_done   # true
```

**Phải `apply` trước.** `terraform output` in giá trị **đã lưu trong state**, không tính lại — và giá trị đó được tính ở lần apply trước, khi `ops_rule_group_arns` bên layer cha còn rỗng. Chạy `output` ngay sau khi apply layer cha sẽ ra `false` cho một cấu hình đã đúng.

Cùng họ với lỗi 65: một chỉ báo xanh (hoặc đỏ) trả lời trung thực cho câu hỏi *"lần chạy trước thấy gì"*, không phải *"bây giờ thế nào"*. `terraform apply` đọc lại `terraform_remote_state` và tính lại; `terraform apply -refresh-only` cũng được.

`false` nghĩa là rule group tồn tại, hiện trong console, `rules_string` đúng y nguyên catalog — và không policy nào đọc nó. Mọi rule trong catalog đang không có tác dụng, và không có chỗ nào báo điều đó. Terraform in cảnh báo cho trạng thái này (`check "rule_group_is_referenced"`).

---

## Quy trình hằng ngày

```bash
vi catalog/firewall-rules.yaml     # thêm một khối
./lint.sh                          # < 1 giây, không cần AWS
git commit && git push             # CI chạy lint + plan, dán plan vào PR
                                   # có người duyệt, merge
terraform apply
```

`lint.sh` không cần credential, không cần `terraform init`, không gọi mạng. Đó là chủ đích: nếu vòng phản hồi ngắn nhất của người mở PR là "đợi CI 4 phút", họ sẽ đoán thay vì kiểm.

Ba thứ `lint.sh` bắt được mà Terraform không:

- **Rule trùng nội dung dưới hai id khác nhau.** Cả hai hợp lệ, cả hai apply, không xung đột. Chúng chỉ làm danh sách dài thêm — nên khi một ticket đóng, không ai dám gỡ dòng nào.
- **Rule sắp hết hạn.** Precondition chỉ biết *đã* hết hạn hay chưa.
- **YAML sai cú pháp.** `yamldecode` báo lỗi không nói dòng nào.

---

## Ví dụ: mở port 5432 từ app-prod xuống tầng dữ liệu

```yaml
# catalog/apps.yaml — thu hẹp xuống một subnet thay vì cả VPC
- name: app-prod-db
  spoke: app-prod
  cidr: 10.20.10.0/24        # phải NẰM TRONG CIDR của spoke
  owner: team-app
```

```yaml
# catalog/firewall-rules.yaml
- id: fw-0005                # id mới, không dùng lại số đã xoá
  from: app-prod
  to: app-prod-db
  ports: [5432]
  ticket: NET-1099
  note: App gọi PostgreSQL ở tầng dữ liệu
```

Xong. **Không route nào.** Route `0.0.0.0/0` trong `rtb-spokes` đã phủ mọi cặp VPC (xem `../tgw.tf`).

Còn phải làm ngoài Terraform: **security group của instance đích**. Firewall cho gói tin đi qua; security group vẫn phải mở port. Hai lớp, hai chủ sở hữu, không lớp nào một mình mở được đường. Nếu sau khi apply vẫn không thông, kiểm security group trước.

---

## id không bao giờ dùng lại, không bao giờ đánh số lại

`id` sinh ra `sid` Suricata (`fw-0042` → sid `20042`), và sid là thứ hiện trong log alert. Giữ id cố định nghĩa là một dòng log từ tháng trước vẫn trả ngược về đúng một dòng trong `git blame` — kể cả sau khi các rule khác đã bị xoá. Xoá một rule thì để trống id đó luôn.

Cách cũ đánh sid theo **vị trí** trong danh sách (`1000 + i`): chèn một rule vào giữa là đổi sid của mọi rule sau nó, `rules_string` đổi hoàn toàn, và ở `STRICT_ORDER` thì cả thứ tự đánh giá cũng đổi. Một thay đổi đáng lẽ chỉ thêm một dòng lại thành viết lại cả rule group.

---

## Rule hết hạn không tự biến mất

Có chủ ý. Gỡ một rule firewall lúc nửa đêm vì không ai gia hạn ticket là một sự cố đang chờ sẵn, và nó sẽ xảy ra vào đúng lúc không ai trực.

Thay vào đó, hết hạn là một **tín hiệu**: `lint.sh` thoát khác 0, plan in cảnh báo, và job `expiry` trong CI chạy theo lịch mỗi ngày nên nó nói lên kể cả khi không ai sửa gì. Việc gỡ vẫn là một commit có người duyệt.

---

## Kiểm chứng sau khi apply

```bash
terraform output rules          # catalog sau khi GIẢI TÊN thành CIDR
terraform output rules_string   # chuỗi Suricata thật sự được nạp
terraform output next_steps
terraform output endpoints_dns  # lệnh kiểm DNS, chạy TỪ TRONG spoke
```

`terraform output rules` là bảng quan trọng nhất để đọc trước khi apply: YAML nói *"order-api gọi user-db"*, bảng này nói *"10.20.0.0/16 → 10.21.0.0/16 port 5432"*.

Với endpoint và DNS, phép kiểm phải chạy **từ một account khác**, không phải từ account network. VPC ở đây được gắn PHZ trực tiếp, nên mọi phép thử tại chỗ đều xanh trong khi bốn account kia không phân giải được gì. Xem `../verify.sh` mục 7d.

---

## Firewall đang ở chế độ `alert`

Rule `pass` vẫn được nạp, nhưng mặc định của policy cũng là cho qua — nên "mở port" không chứng minh được gì: luồng không có rule cũng đi qua bình thường.

Đó là trạng thái đúng khi đang đo đường. Nó cũng nghĩa là bạn chưa kiểm chứng được rule nào thật sự cần thiết. Đọc log `UNMATCHED east-west` trong bucket firewall log ít nhất một tuần, xây catalog từ những gì thật sự đang chảy, rồi mới chuyển `firewall_mode = "drop"` ở layer cha.

---

## Gỡ bỏ và dựng lại

Thứ tự **ngược** với bootstrap:

```bash
# 1. Gỡ ARN khỏi layer cha TRƯỚC
cd ..
# xoá dòng ops_rule_group_arns khỏi terraform.tfvars
terraform apply

# 2. Rồi mới xoá lớp ops
cd ops && terraform destroy && cd ..

# 3. Rồi mới xoá layer cha
./teardown.sh
```

Làm ngược thứ tự thì layer cha giữ một tham chiếu tới rule group đã biến mất, và lần apply kế tiếp của nó hỏng với một lỗi đúng nhưng không nói ai đã xoá. `teardown.sh` chặn nếu bạn bỏ qua bước 1.

**Dựng lại thì ngắn hơn nhiều**: object state trong S3, đăng ký layer trong `tf-backend`, và `backend.tf`/`backend.hcl` đều còn nguyên sau `destroy`. Chỉ chạy lại `wire-backends.sh` nếu bạn clone lại repo. ARN của rule group cũng giống hệt lần trước — nó sinh từ region + account + tên. Trình tự đầy đủ ở [doc 25 mục 3b](../../../docs/25-Van-hanh-Network-Hang-Ngay.md).

---

## Trỏ vào landing zone thật

`landing-zone/network` dùng backend S3. Đổi hai biến, không đổi gì khác:

```hcl
state_backend = "s3"
state_config = {
  bucket = "acme-lz-tfstate"
  key    = "network/terraform.tfstate"
  region = "ap-southeast-1"
}
```

Layer đó cũng cần output `ops_handles` và biến `ops_rule_group_arns` — hiện chỉ `demo/network-lz-full` có. Và bản thân `landing-zone/network` **chưa từng được apply**, bước RAM share của nó đã đo là hỏng (xem `landing-zone/RUNBOOK.md` giai đoạn 10).
