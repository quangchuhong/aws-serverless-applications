# Vận hành network hằng ngày — route, port firewall, VPC endpoint, DNS

Doc 17 là thiết kế. Doc 24 là trình tự dựng lần đầu. Tài liệu này là thứ đọc **sau khi mạng đã chạy**: một đội xin mở port, một đội xin thêm endpoint, một tên cần vào DNS chung. Code nằm ở [`demo/network-lz-full/ops/`](../demo/network-lz-full/ops/).

---

## 0. Trạng thái

| | |
|---|---|
| **Nền tảng** | Đã dựng thật, 4 account, `verify.sh` **46 đạt, 0 lỗi** — xem doc 24 |
| **Lớp vận hành** | Code viết xong, `terraform fmt` sạch, `lint.sh` kiểm chứng bằng catalog hỏng cố ý (12 lỗi + 8 cảnh báo bắt đủ) |
| **Chưa** | Chưa apply lần nào. Bootstrap hai bước ở mục 3 chưa ai chạy |
| **CI** | `.github/workflows/network-ops.yml` — job `lint` và `expiry` chạy được ngay, job `plan` tự bỏ qua tới khi có OIDC role |

---

## 1. Bốn thao tác, và một thao tác không tồn tại

| Đội xin gì | Sửa file nào | Có phải sửa route không |
|---|---|---|
| Mở port từ app A sang app B ở VPC khác | `firewall-rules.yaml` | **Không** |
| Đóng port đã mở | `firewall-rules.yaml` (xoá khối) | Không |
| Cách ly khẩn một dải địa chỉ | `routes.yaml` (blackhole) | Đây *là* route |
| Nối một dải on-premise qua VPN | `routes.yaml` | Đây *là* route |
| Thêm VPC endpoint (KMS, ECR, Secrets Manager…) | `endpoints.yaml` | Không |
| Thêm một tên vào DNS nội bộ | `dns-records.yaml` | Không |
| **"Thêm route để VPC A nói được VPC B"** | — | **Yêu cầu này sai đề** |

### Vì sao "route giữa các VPC" không phải là bề mặt vận hành

Bảng `rtb-spokes` có **đúng một dòng**:

```
0.0.0.0/0  →  security VPC
```

Một dòng đó phủ mọi đích đến: Internet, spoke khác, ingress VPC. Gói tin rời khỏi bất kỳ spoke nào đều vào firewall trước, rồi TGW mới quyết định nó đi tiếp đâu.

Thêm một route spoke-to-spoke **không mở thêm kết nối nào** — kết nối đã sẵn có. Nó tạo một đường tắt **vòng qua firewall**, vì route cụ thể hơn `0.0.0.0/0` nên nó thắng. Đó đúng là thứ cả thiết kế này tốn ~$770/tháng để ngăn.

Cho nên yêu cầu "mở đường giữa hai VPC" luôn được giải bằng **một dòng trong `firewall-rules.yaml`**, không bao giờ bằng một dòng route. Lớp ops in cảnh báo khi phát hiện route có hình dạng đó (`check "no_firewall_bypass_routes"`).

`routes.yaml` tồn tại cho ba việc thật: blackhole để cách ly, dải ngoài landing zone đến qua VPN/Direct Connect, và đường về cho các dải đó sau khi qua thanh tra.

---

## 2. Hai state, một điểm chạm

```
demo/network-lz-full/            ~200 resource   đổi vài tháng một lần
  TGW · security VPC · firewall · egress · ingress · spoke VPC · StackSet
        │
        │  var.ops_rule_group_arns   ← ĐIỂM CHẠM DUY NHẤT
        ▼
demo/network-lz-full/ops/        4 loại resource · đổi hằng ngày
  rule group · route ngoại lệ · endpoint · bản ghi DNS
        ▲
        │  terraform_remote_state → output "ops_handles"  (chỉ ĐỌC)
```

Gộp chung thì mở một port là một plan chạm hơn 200 resource. Người duyệt phải đọc hết để biết plan đó *không* làm gì khác ngoài thêm một dòng rule. Làm vậy mỗi ngày thì không ai đọc thật — và đến một ngày có người bấm yes quá nhanh, đúng lúc plan đó chứa một thay đổi không ai để ý.

Tách ra thì kịch bản xấu nhất của một lần apply sai ở lớp ops là một rule sai hoặc một bản ghi DNS sai. Không lần nào chạm được vào firewall endpoint hay route mặc định — chúng không nằm trong state đó.

`terraform_remote_state` là **quyền đọc**, không phải quyền sửa: lớp ops không tạo được một resource nào trong state của layer cha dù có muốn.

---

## 3. Bootstrap — ba bước, làm đúng một lần

Firewall policy tham chiếu rule group bằng ARN, mà ARN chỉ tồn tại sau khi rule group được tạo. Vòng phụ thuộc đó chỉ có một cách cắt:

```bash
# 0. Đưa output "ops_handles" vào state của layer cha
cd demo/network-lz-full
terraform apply                    # 0 to add, 0 to change — chỉ thêm output

# 1. Tạo rule group ở lớp ops
cd ops
terraform init && terraform apply
terraform output -raw rule_group_arn

# 2. Cắm ARN vào layer cha
cd ..
echo 'ops_rule_group_arns = ["arn:aws:network-firewall:ap-southeast-1:...:stateful-rulegroup/lz-net-ops-east-west"]' >> terraform.tfvars
terraform apply                    # policy giờ đọc rule group ở ưu tiên 150
```

Bước 0 nhìn như thừa — nó không đổi một resource nào. Bỏ nó thì bước 1 hỏng ngay với `This object does not have an attribute named "ops_handles"`, và thông báo đó không hề nói rằng bạn quên apply layer cha.

Từ đó ARN không đổi nữa. Sửa catalog chỉ làm đổi `rules_string` **bên trong** rule group — sửa tại chỗ, không tạo lại resource, không cần ai apply layer cha.

**Ưu tiên 150 là cố ý.** Rule group của layer cha ở 100 chứa hai luồng *hạ tầng*: NLB → app (sid 1800) và SSM → interface endpoint (sid 1810). Chúng phải được đọc trước. Lớp ops không được quyền làm mất SSM ở mọi spoke.

### Kiểm bootstrap

```bash
terraform output bootstrap_done   # phải là true
```

`false` là trạng thái nguy hiểm nhất trong cả lớp này, vì **nó đọc như thành công từ mọi phía**: apply xanh, rule group hiện trong console, `rules_string` đúng y nguyên catalog. Chỉ thiếu một thứ — không policy nào đọc nó. Mọi rule đang không có tác dụng, và không có chỗ nào báo điều đó.

### Gỡ bỏ — thứ tự ngược lại

Gỡ ARN khỏi layer cha **trước**, apply, rồi mới `terraform destroy` lớp ops. Làm ngược thì layer cha giữ tham chiếu tới một rule group đã biến mất, và lần apply kế tiếp của nó hỏng với một lỗi đúng nhưng không nói ai đã xoá.

---

## 4. Runbook

### 4.1. Mở một port giữa hai app

```yaml
# ops/catalog/firewall-rules.yaml
- id: fw-0005              # id MỚI — không dùng lại số đã xoá
  from: app-prod
  to: app-prod-db
  ports: [5432]
  ticket: NET-1099
  note: App gọi PostgreSQL ở tầng dữ liệu
```

```bash
cd ops && ./lint.sh && terraform plan
terraform output rules      # đọc bảng SAU KHI GIẢI TÊN
terraform apply
```

`terraform output rules` là bảng quan trọng nhất trước khi apply. YAML nói *"app-prod gọi app-prod-db"*; bảng này nói *"10.20.0.0/16 → 10.20.10.0/24 port 5432"*. Đọc bảng này là đọc cái thật sự sẽ được nạp vào firewall.

**Kiểm chứng — từ trong spoke nguồn, không phải từ account network:**

```bash
aws ssm start-session --target <instance-id>
curl -sv --max-time 5 telnet://10.20.10.20:5432
```

`Connection refused` (rc 7) nghĩa là gói tin **đã qua firewall** và tới máy đích — chỉ là không có dịch vụ nghe. `Connection timed out` (rc 28) nghĩa là bị chặn ở tầng mạng. Hai kết quả đó trả lời hai câu hỏi khác nhau; nhầm chúng là mất nửa buổi.

**Nếu vẫn không thông:** kiểm **security group của instance đích** trước. Firewall cho gói tin đi qua; security group vẫn phải mở port. Hai lớp, hai chủ sở hữu, không lớp nào một mình mở được đường — đó là chủ ý, không phải phiền toái.

### 4.2. Đóng một port

Xoá khối YAML, apply. **Để trống `id` đó luôn**, đừng đánh số lại.

`id` sinh ra `sid` Suricata (`fw-0042` → sid `20042`), và sid là thứ hiện trong log alert. Giữ id cố định nghĩa là một dòng log từ tháng trước vẫn trả ngược về đúng một dòng trong `git blame` — kể cả sau khi các rule khác đã bị xoá.

> Cách cũ ở layer cha đánh sid theo **vị trí** (`1000 + i`): chèn một rule vào giữa là đổi sid của mọi rule sau nó, `rules_string` đổi hoàn toàn, và ở `STRICT_ORDER` thì cả thứ tự đánh giá cũng đổi. Một thay đổi đáng lẽ chỉ thêm một dòng lại thành viết lại cả rule group. Cùng họ với lỗi 39.

### 4.3. Thêm một VPC endpoint

```yaml
# ops/catalog/endpoints.yaml
- service: kms
  ticket: SEC-3301
  note: Ứng dụng prod gọi KMS — không được phép đi qua Internet
```

Một dòng đó sinh ra **bốn resource phải đúng cùng lúc**:

| # | Resource | Thiếu nó thì sao |
|---|---|---|
| 1 | `aws_vpc_endpoint` | Không có ENI để trỏ về |
| 2 | `aws_route53_zone` | Tên dịch vụ vẫn phân giải ra IP công khai |
| 3 | `aws_route53_record` | Zone rỗng, phân giải hỏng hẳn |
| 4 | `aws_route53profiles_resource_association` | **Chạy đúng ở account network và không account nào khác thấy** |

(4) là bước hay bị quên nhất, vì ba bước trên đều tạo ra thứ nhìn thấy được trong console của account network. Bước này là thứ duy nhất làm cho account **khác** thấy.

**Kiểm chứng — bắt buộc từ một account khác:**

```bash
# Trong EC2 ở app-prod (account 761558631239), KHÔNG phải account network
dig +short kms.ap-southeast-1.amazonaws.com
```

Phải ra IP trong security VPC (`10.1.30.x` / `10.1.31.x`). Ra IP công khai nghĩa là PHZ chưa tới được spoke đó: **endpoint vẫn tính tiền, lưu lượng vẫn đi vòng ra Internet qua NAT, và không có gì báo.** Vẫn chạy, vẫn đúng kết quả, chỉ là bạn đang trả tiền hai lần cho một thứ không ai dùng.

Kiểm từ account network thì không chứng minh được gì — VPC ở đó được gắn PHZ trực tiếp.

`terraform output endpoints_dns` in sẵn các lệnh.

**Dịch vụ có tên nằm ở tiền tố** (`ecr.dkr`, `ecr.api`, `elasticfilesystem`) cần `wildcard: true`. Thiếu nó thì một nửa số lời gọi đi ra Internet còn nửa kia thì không — kiểu chập chờn rất khó lần. `lint.sh` cảnh báo cho các tên đó.

### 4.4. Thêm một bản ghi DNS

```yaml
# ops/catalog/dns-records.yaml
- name: order-api          # tên NGẮN, không gồm tên miền
  type: A
  ttl: 60
  values: ["10.20.0.10"]
  ticket: NET-1150
```

PHZ này gắn vào **mọi VPC** của landing zone qua Route 53 Profile. Một bản ghi ở đây hiện ra ở cả năm account. Đó là không gian tên chung — và không gian tên chung mà không có một chỗ duy nhất để đọc thì sớm muộn sẽ có hai đội đặt trùng tên, rồi cả hai đều báo DNS "chập chờn" trong khi Route 53 trả lời hoàn toàn nhất quán theo bản ghi của bên ghi đè sau cùng.

**TTL: chọn trước, đừng sửa sau.** TTL cao trên một tên đang cần đổi biến một thao tác hai phút thành sự cố một tiếng — sửa xong vẫn phải chờ cache hết hạn ở resolver của từng VPC. Hạ TTL xuống *trước* khi đổi.

### 4.5. Cách ly khẩn một dải địa chỉ

```yaml
# ops/catalog/routes.yaml
- id: rt-0001
  table: spokes
  destination: 10.13.7.0/24
  target: blackhole
  ticket: SEC-2201
  note: Cách ly subnet bị xâm nhập — gỡ sau khi đội IR đóng ticket
```

Blackhole ở bảng `spokes` chặn **trước cả firewall**: mọi spoke mất đường tới dải đó ngay lập tức, không phụ thuộc rule nào. Đây là công cụ đúng khi cần cắt nhanh và chưa kịp phân tích.

---

## 5. Triệu chứng → nguyên nhân

Bảng này là thứ đọc lúc 2 giờ sáng. Mọi dòng đều là kiểu hỏng **không phát ra lỗi**.

| Triệu chứng | Nguyên nhân thật | Kiểm bằng |
|---|---|---|
| Apply xanh, rule hiện trong console, luồng vẫn bị chặn | Rule group chưa được cắm vào policy | `terraform output bootstrap_done` |
| Mở port xong vẫn không thông, port khác lại thông | Security group của instance đích | `curl -v telnet://ip:port` → rc 7 hay 28 |
| Rule "không có tác dụng", `rules_string` trông đúng | Hai rule cùng `sid` — Suricata nạp cái đầu, **bỏ im lặng** cái sau | `./lint.sh` |
| Rule icmp không làm gì | Bị che bởi sid 1900 ở rule group ưu tiên 100; `pass` kết thúc đánh giá ở `STRICT_ORDER` | `check "icmp_rules_are_shadowed"` |
| Rule không khớp gì cả, không lỗi ở đâu | CIDR gõ nhầm — đây là lý do lớp ops khai bằng **tên** | Terraform dừng ở plan |
| `dig` ra IP công khai từ spoke | Thiếu Profile association (bước 4 ở mục 4.3) | `dig` **từ account khác** |
| Endpoint tính tiền mà không ai dùng | Cùng nguyên nhân trên | Xem hoá đơn NAT không giảm |
| Tên DNS "nhảy qua nhảy lại" | Trùng tên với bản ghi layer cha sinh ra — **cả hai plan đều sạch** | `terraform plan` (precondition bắt) |
| Mở port giữa hai app cùng VPC không có tác dụng | Lưu lượng trong cùng VPC không qua TGW nên không tới firewall | `./lint.sh` |
| Chế độ `alert`: mọi thứ đều thông kể cả khi không có rule | Đúng thiết kế — mặc định là cho qua và chỉ ghi log | `terraform output next_steps` |

---

## 6. Bốn cái bẫy đáng nhớ nhất

**1. `bootstrap_done = false` đọc như thành công.** Apply xanh, resource tồn tại, nội dung đúng. Chỉ là không ai đọc nó. Đây là biến thể của cùng một bài học từ lỗi 65: ba chỉ báo xanh, không cái nào trả lời đúng câu hỏi đang hỏi.

**2. `capacity` của rule group là bất biến.** Sửa nó là Terraform **xoá và tạo lại** rule group. ARN mới không khớp `ops_rule_group_arns` bên layer cha, và trong khoảng giữa, policy tham chiếu một rule group đã biến mất. Đặt rộng ngay từ đầu — mặc định 1000, và capacity không dùng tốn $0.

**3. Chế độ `alert` làm mọi phép kiểm "mở port" trở nên vô nghĩa.** Rule `pass` vẫn được nạp, nhưng mặc định của policy cũng là cho qua. Luồng *không có* rule cũng đi qua bình thường. Đây là trạng thái đúng khi đang đo đường — nhưng nó cũng nghĩa là bạn chưa kiểm chứng được rule nào thật sự cần.

**4. Rule hết hạn không tự gỡ.** Có chủ ý. Gỡ một rule firewall lúc nửa đêm vì không ai gia hạn ticket là một sự cố đang chờ sẵn, và nó sẽ xảy ra vào đúng lúc không ai trực. Thay vào đó nó làm `lint.sh` thoát khác 0 và làm job `expiry` trong CI đỏ mỗi ngày — tín hiệu, không phải hành động tự động.

---

## 7. Tự động hoá

| Chạy khi nào | Cần gì | Làm gì |
|---|---|---|
| `lint` — mọi PR, mọi push | Không cần AWS, không cần secret | `lint.sh --strict` + `terraform fmt -check` |
| `plan` — PR | OIDC role (`vars.OPS_PLAN_ROLE_ARN`) | `terraform plan`, dán kết quả vào PR |
| `expiry` — 08:00 mỗi ngày | Không cần gì | `lint.sh` — đỏ khi có rule quá hạn |

`lint.sh` chạy dưới một giây và không gọi mạng. Đó là chủ đích: nếu vòng phản hồi ngắn nhất của người mở PR là "đợi CI bốn phút", họ sẽ đoán thay vì kiểm.

Job `plan` **tự bỏ qua và vẫn xanh** khi chưa cấu hình OIDC. Một job đỏ vĩnh viễn vì thiếu cấu hình là một job không ai còn đọc.

Job `expiry` cố ý **không** dùng `--strict`: chạy theo lịch thì chỉ nên đỏ vì một lý do — có rule *đã* quá hạn. Nếu không, bảng sẽ đỏ triền miên và tín hiệu thật mất luôn.

**Chưa có job `apply`.** Doc 10 có đủ mẫu apply qua OIDC; chưa nối vào vì repo chưa dùng IAM role thật, và một dấu X đỏ mỗi lần merge sẽ dạy người ta thôi nhìn vào dấu X.

---

## 8. Chi phí

| | |
|---|---|
| Rule group | **$0** — Network Firewall tính theo giờ endpoint và GB xử lý, không theo capacity hay số rule |
| Route TGW | $0 |
| Bản ghi DNS | ~$0 (Route 53 tính $0.40/triệu truy vấn) |
| Interface endpoint | **~$0.01/giờ mỗi AZ mỗi dịch vụ** — 2 AZ = ~$14.60/tháng cho mỗi dòng, kể cả khi không ai gọi |

Chỉ `endpoints.yaml` tốn tiền thật. Đổi lại nó bớt phí NAT ($0.045/GB) và bớt một đường ra khỏi mạng. Với dịch vụ bị gọi nhiều thì endpoint **rẻ hơn**; với dịch vụ gọi vài lần một ngày thì đắt hơn — và đó là lựa chọn đúng khi lý do là **bảo mật** chứ không phải tiền.

---

## 9. Còn thiếu

- Lớp ops chưa apply lần nào. Bootstrap ở mục 3 chưa ai chạy.
- `landing-zone/network` chưa có `output "ops_handles"` và `var.ops_rule_group_arns` — hiện chỉ `demo/network-lz-full` có. Bản thân layer đó cũng chưa từng được apply, và bước RAM share của nó đã đo là hỏng (RUNBOOK giai đoạn 10).
- Chưa có job `apply` trong CI (mục 7).
- Chưa đọc log `UNMATCHED east-west` để dựng catalog từ lưu lượng thật. Đó là việc phải làm **trước** khi chuyển `firewall_mode = "drop"` — catalog hiện tại là ví dụ, không phải bản đồ luồng thật.
