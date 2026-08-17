# Demo: Network Landing Zone – dựng, kiểm chứng, xoá

Triển khai thiết kế ở [doc 17 – Network LZ Design Guide](../../docs/17-Network-LZ-Design-Guide.md), **trừ Palo Alto và F5**.

Dựng lên chạy thử rồi xoá. Buổi thực hành 4 tiếng khoảng **$3**.

---

## Có gì và chưa có gì

| Thành phần | Trong demo | Doc chi tiết |
|---|---|---|
| Transit Gateway + 4 route table | ✅ | [17 mục 4](../../docs/17-Network-LZ-Design-Guide.md) |
| **security-vpc + AWS Network Firewall** | ✅ | [15](../../docs/15-Security-VPC-Network-Firewall.md) |
| egress-vpc + NAT Gateway | ✅ | [13](../../docs/13-Centralized-Ingress-Egress-Network.md) |
| Spoke không IGW/NAT | ✅ | [13](../../docs/13-Centralized-Ingress-Egress-Network.md) |
| Gateway endpoint S3/DynamoDB | ✅ | [12](../../docs/12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) |
| Interface endpoint trong security VPC | ✅ (tuỳ chọn) | [15 mục 6.3](../../docs/15-Security-VPC-Network-Firewall.md) |
| ingress-vpc + NLB | ✅ | [14](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| **CloudFront + AWS WAF + khoá origin** | ✅ (tuỳ chọn) | [14 mục 5](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| **Palo Alto (GWLB)** | ⏸ **code sẵn, mặc định tắt** | [14 mục 6](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| **F5 BIG-IP WAF** | ⏸ **code sẵn, mặc định tắt** | [18](../../docs/18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md) |
| 3rd-party VPC + VPN | ❌ chưa | [16](../../docs/16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) |

Demo cũng **không tạo AWS account** và **không attach SCP** — cả hai đều làm `terraform destroy` không chạy được.

### Palo Alto và F5: code viết sẵn, chưa bật

`appliances.tf` có đầy đủ Terraform cho GWLB + Palo Alto + F5, nhưng `enable_appliances = false` mặc định. Lý do: cần license Marketplace, để phase sau.

Code viết trước để **kiểm chứng bằng `terraform plan` ngay bây giờ**, khi có license chỉ bật biến lên:

```bash
./plan-check.sh
```

Script này chạy `terraform plan` cho **9 tổ hợp biến**, gồm cả phần appliance, và kiểm tra plan có đúng hành vi mong đợi không (`appliance_mode_support = enable`, `source_dest_check = false`, NLB trỏ vào F5 chứ không trỏ thẳng app…). **Không tạo resource nào.**

Để plan được phần appliance mà chưa subscribe Marketplace, script tự lấy một AMI Amazon Linux làm AMI giả — `plan` chỉ cần một AMI ID hợp lệ.

---

## Chạy

```bash
cd demo/network-lz-full
cp terraform.tfvars.example terraform.tfvars
chmod +x plan-check.sh verify.sh teardown.sh

# Kiem chung toan bo code truoc, khong tao gi
./plan-check.sh

terraform init
terraform apply          # ~8 phút (firewall mất ~5 phút)

./verify.sh              # đợi ~2 phút cho EC2 boot xong rồi chạy
```

Xong việc:

```bash
./teardown.sh            # destroy + xác nhận không còn gì tính tiền
```

Cần `jq` cho `verify.sh`.

---

## Kịch bản 5 bước

Mỗi bước sửa `terraform.tfvars` rồi `terraform apply` lại.

### Bước 1 — Chế độ rẻ, chưa có firewall (~$0.34/giờ)

```hcl
enable_firewall = false
```

Kiểm chứng được: spoke không có IGW/NAT, egress đi qua NAT tập trung, ingress NLB → app.

```bash
aws ssm start-session --target $(terraform output -json instances | jq -r '.["app-dev"].id')
```

Trong session:

```bash
curl -s https://checkip.amazonaws.com    # = terraform output nat_public_ip
```

Chính việc **vào được session** đã chứng minh đường egress chạy — SSM agent phải ra Internet qua egress VPC mới đăng ký được.

### Bước 2 — Bật firewall, chế độ alert (~$0.74/giờ)

```hcl
enable_firewall = true
firewall_mode   = "alert"
```

Giờ mọi luồng đi qua security VPC. Firewall **ghi log nhưng chưa chặn** — đây là chế độ bắt buộc phải dùng đầu tiên khi triển khai thật.

```bash
aws s3 ls s3://$(terraform output -raw firewall_log_bucket)/alert/ --recursive | tail
```

### Bước 3 — Chuyển sang drop

```hcl
firewall_mode = "drop"
```

Từ EC2 `app-dev`:

```bash
PROD=$(terraform output -json instances | jq -r '.["app-prod"].private_ip')

curl -s -o /dev/null -w '%{http_code}\n' http://$PROD/   # 200 — có rule
nc -zvw 5 $PROD 22                                        # timeout — không có rule
curl -sm 5 https://example.com                            # fail — ngoài allowlist
curl -sI https://www.amazonaws.com                        # OK — trong allowlist
```

**Điểm mấu chốt:** port 22 bị chặn dù security group đã mở nó. Chặn ở tầng firewall, không phụ thuộc ai sửa SG.

### Bước 4 — Mở/đóng kết nối VPC-to-VPC

Đây là bước trả lời câu hỏi *"có cần route VPC-to-VPC không?"*

Thêm một dòng vào `east_west_rules`:

```hcl
east_west_rules = [
  { from_cidr = "10.10.0.0/16", to_cidr = "10.20.0.0/16", port = 80, note = "http" },
  { from_cidr = "10.10.0.0/16", to_cidr = "10.20.0.0/16", port = 22, note = "ssh" },
]
```

```bash
terraform apply
```

Xem plan: **chỉ rule group thay đổi. Không có route nào bị sửa.** Sau đó SSH thông.

Xoá dòng đó đi, apply lại — SSH bị chặn ngay. Vẫn không đụng route nào.

### Bước 5 — Interface endpoint trong security VPC

```hcl
enable_interface_endpoints = true
```

```bash
dig +short ssm.ap-southeast-1.amazonaws.com    # trả về 10.1.30.x
```

Traffic tới AWS API giờ đi `spoke → TGW → firewall → local route → endpoint`. Được thanh tra mà **không tốn thêm chặng TGW** nào.

### Bước 6 — CloudFront + AWS WAF

```hcl
enable_cdn = true
waf_mode   = "count"    # chỉ đếm, chưa chặn
```

> `apply` chậm thêm **5–15 phút**, `destroy` chậm thêm **15–20 phút** — CloudFront phải disable trước rồi mới delete được. Terraform tự làm cả hai, cứ để nó chạy.

Dùng hostname mặc định `*.cloudfront.net`, nên **không cần mua domain, không cần Route 53, không cần ACM**.

```bash
CDN=$(terraform output -raw cloudfront_domain)
NLB=$(terraform output -raw nlb_dns_name)

curl -sI "https://$CDN/"        # 200 — đi qua CDN
curl -sm 8 "http://$NLB/"       # timeout — origin đã khoá
```

**Khoá origin** là điểm đáng xem nhất: bật `enable_cdn` cũng đổi security group của NLB sang chỉ nhận traffic từ prefix list `com.amazonaws.global.cloudfront.origin-facing`. Không khoá thì kẻ tấn công gọi thẳng NLB, bỏ qua toàn bộ WAF.

Đổi sang chặn thật:

```hcl
waf_mode = "block"
```

```bash
# Payload SQLi → phải trả về 403
curl -s -o /dev/null -w '%{http_code}\n' "https://$CDN/?id=1%27%20OR%20%271%27=%271"
```

**Luôn chạy `count` trước.** Managed rule group hay chặn nhầm request hợp lệ; xem CloudWatch metric vài ngày rồi mới chuyển sang `block`. Nguyên tắc y hệt Network Firewall ở bước 2–3.

---

## Ba tầng kiểm soát – đừng lẫn

Câu hỏi hay gặp: *"kết nối VPC-to-VPC có cần route không?"*

**Không.** Route đã có sẵn và chỉ có **một dòng duy nhất**:

```hcl
# vpc-spokes.tf
resource "aws_route" "spoke_default_to_tgw" {
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
}
```

Dòng này phủ hết: ra Internet, sang spoke khác, tới ingress VPC, tới VPC endpoint.

| Tầng | Câu hỏi | Sửa ở đâu | Thay đổi khi mở luồng mới? |
|---|---|---|---|
| **Route** | Có đường đi không? | `rtb-spokes`: `0.0.0.0/0 → security` | ❌ Không bao giờ |
| **Firewall rule** | Được phép không? | `var.east_west_rules` | ✅ Có |
| **Security group** | Đích có nhận không? | `aws_security_group.test` | ✅ Có |

Và **không được** có route trực tiếp spoke A → spoke B. Đó chính là đường lách firewall. `verify.sh` mục 5 quét mọi TGW route table để tìm những đường như vậy.

Thêm spoke mới cũng theo đúng khuôn: attach → associate vào `rtb-spokes` → propagate vào `rtb-security`. Không có route theo từng cặp.

---

## Chi phí

| Cấu hình | ~$/giờ | ~$/ngày | 4 tiếng |
|---|---|---|---|
| Bước 1 (không firewall) | $0.34 | $8 | ~$1.4 |
| Bước 2–4 (có firewall) | $0.74 | $18 | ~$3.0 |
| Bước 5 (thêm 3 endpoint) | $0.77 | $18 | ~$3.1 |
| **Bước 6 (thêm CDN + WAF)** | **$0.78** | $19 | **~$3.2** |

`terraform output estimated_cost` in con số cho cấu hình hiện tại.

Chi tiết:

| Khoản | Đơn giá | Ghi chú |
|---|---|---|
| **Network Firewall endpoint** | ~$0.395/giờ | Khoản lớn nhất |
| TGW attachment | ~$0.05/giờ mỗi cái | 5 cái khi bật đủ |
| NAT Gateway | ~$0.045/giờ | |
| NLB | ~$0.0225/giờ | |
| EC2 t3.micro × 2 | ~$0.023/giờ | |
| **CloudFront** | **$0** | Free tier 1 TB + 10 triệu request/tháng |
| WAF Web ACL | ~$5/tháng chia theo giờ | ~$0.007/giờ |
| WAF rule group × 4 | ~$1/tháng mỗi cái | ~$0.005/giờ |
| **Gateway endpoint** | **$0** | Luôn bật |

CloudFront + WAF chỉ thêm khoảng **5 cent cho cả phiên 4 tiếng**. Cái giá thật là **30–35 phút** thêm vào thời gian apply và destroy.

**Quên xoá một tháng ≈ $550.** Đó là lý do `teardown.sh` có phần xác nhận, và tại sao mọi resource đều gắn tag `Ephemeral=true`.

> `teardown.sh` kiểm tra cả **WAF Web ACL ở us-east-1** — WAF cho CloudFront bắt buộc nằm ở region đó, không phải region bạn đang làm việc. Đây là chỗ dễ sót nhất khi dọn thủ công.

---

## Nếu destroy bị kẹt

Thường chỉ là timing:

| Kẹt ở | Nguyên nhân | Xử lý |
|---|---|---|
| VPC không xoá được | Còn ENI của firewall/endpoint | Đợi 2 phút, `terraform destroy` lại |
| Network Firewall | Đang xoá endpoint (~5 phút) | Đợi rồi chạy lại |
| TGW | Attachment chưa xoá hết | Đợi rồi chạy lại |
| Subnet | ENI mồ côi | `aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=<id>"` |

Chạy `terraform destroy` lần hai gần như luôn xử lý được.

Sót lại thì tìm bằng tag:

```bash
aws resourcegroupstaggingapi get-resources --region ap-southeast-1 \
  --tag-filters "Key=Ephemeral,Values=true" \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

---

## Cấu trúc file

| File | Nội dung |
|---|---|
| `tgw.tf` | **Trái tim** — TGW + 4 route table, association, propagation |
| `vpc-security.tf` | Security VPC, TGW attachment (appliance mode), interface endpoint |
| `firewall.tf` | Network Firewall, policy, rule group east-west + egress, logging |
| `vpc-egress.tf` | IGW, NAT, và **đường về** hay bị quên |
| `vpc-ingress.tf` | IGW, NLB, security group khoá origin |
| `cdn.tf` | CloudFront, AWS WAF (ở us-east-1), header bí mật |
| `appliances.tf` | **Phase sau** — GWLB + Palo Alto + F5, edge routing. Mặc định tắt |
| `templates/f5-runtime-init.yaml` | Bootstrap F5: DO + AS3 + WAF policy transparent |
| `plan-check.sh` | Chạy `terraform plan` cho 9 tổ hợp biến, không apply |
| `vpc-spokes.tf` | Spoke VPC, route một dòng, gateway endpoint |
| `instances.tf` | EC2 nginx, vào bằng SSM |
| `verify.sh` | 8 nhóm kiểm chứng, gồm chạy lệnh thật trên EC2 qua SSM |
| `teardown.sh` | Destroy + xác nhận sạch |

---

## Khác biệt so với production

| Demo | Production (doc 17) |
|---|---|
| 1 AZ | Mỗi AZ một firewall endpoint và một NAT |
| Một account | Nhiều account, TGW share qua RAM |
| Không SCP | SCP chặn IGW/NAT/EIP ở OU workload |
| Không Palo Alto / F5 | Chuỗi đầy đủ (doc 14) |
| Hostname `*.cloudfront.net` | Domain riêng + ACM cert |
| Origin khoá bằng prefix list | Thêm kiểm tra header bí mật ở F5 |
| `delete_protection = false` | Bật cho firewall và NLB |
| NLB nghe HTTP:80 | HTTPS:443 + ACM |
| Không đối tác | 3rd-party VPC + VPN (doc 16) |

> Header `X-Origin-Verify` đã được sinh và gửi đi từ CloudFront, nhưng demo dùng nginx nên **chưa ai kiểm tra nó**. Trong thiết kế thật, F5 kiểm tra header này và trả 403 nếu thiếu — lớp thứ hai phòng khi ai đó qua được tầng mạng. Xem [doc 14 mục 7.1](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md).

---

## Bước tiếp theo

1. Chạy hết 5 bước, xác nhận `verify.sh` xanh hết
2. Thêm 3rd-party VPC + VPN (doc 16)
3. Thêm Palo Alto + F5 khi có license — hạ tầng định tuyến không đổi
4. Chuyển sang multi-account (xem [`demo/centralized-network-multiaccount`](../centralized-network-multiaccount/) để biết phần RAM share và cross-account PHZ)
