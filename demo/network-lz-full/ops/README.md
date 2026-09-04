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
echo 'ops_rule_group_arns = ["arn:aws:network-firewall:..."]' >> terraform.tfvars
terraform apply
```

Từ đó về sau ARN không đổi nữa. Sửa catalog chỉ làm đổi `rules_string` bên trong rule group — một thuộc tính sửa tại chỗ, không tạo lại resource, **không cần ai apply layer cha**.

### Hai lỗi hay gặp ở bước 0–1

`./lint.sh` kiểm cả hai trước khi Terraform chạy, nên chạy nó trước là nhanh nhất.

| Terraform báo | Nghĩa thật |
|---|---|
| `Unable to find remote state` / `No stored state was found` | Không thấy file state của layer cha. Câu này **không in ra đường dẫn đã thử** và đọc y hệt như "layer cha chưa bao giờ được apply". Kiểm: `ls -la ../terraform.tfstate` |
| `This object does not have an attribute named "ops_handles"` | State có, nhưng layer cha chưa apply lại sau khi kéo code mới về — tức là bỏ qua bước 0 |

Đường dẫn state mặc định tính theo **vị trí file `.tf`** (`${path.module}/../terraform.tfstate`), không theo thư mục đang chạy. Backend `local` của `terraform_remote_state` giải đường dẫn tương đối theo thư mục đang chạy — hai cái đó trùng nhau khi gõ `cd ops && terraform apply` và lệch nhau khi gõ `terraform -chdir=ops apply` hoặc khi chạy từ CI.

Nếu state của layer cha nằm chỗ khác, trỏ tới nó bằng **đường dẫn tuyệt đối**:

```hcl
state_config = { path = "/Users/laptop/…/demo/network-lz-full/terraform.tfstate" }
```

Kiểm bootstrap đã xong chưa:

```bash
terraform output bootstrap_done   # true
```

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

## Gỡ bỏ

Thứ tự **ngược** với bootstrap:

```bash
# 1. Gỡ ARN khỏi layer cha TRƯỚC
cd ..
# xoá dòng ops_rule_group_arns khỏi terraform.tfvars
terraform apply

# 2. Rồi mới xoá lớp ops
cd ops
terraform destroy
```

Làm ngược thứ tự thì layer cha giữ một tham chiếu tới rule group đã biến mất, và lần apply kế tiếp của nó hỏng với một lỗi đúng nhưng không nói ai đã xoá.

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
