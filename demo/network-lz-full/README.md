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
| **Palo Alto (GWLB)** | ❌ **chưa** | [14 mục 6](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| **F5 BIG-IP WAF** | ❌ **chưa** | [14 mục 7](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| CDN (CloudFront) | ❌ chưa | [14 mục 5](../../docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| 3rd-party VPC + VPN | ❌ chưa | [16](../../docs/16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) |

Demo dùng NLB trỏ thẳng xuống app. Khi có license Palo Alto và F5, chúng chèn vào **giữa IGW và NLB** — phần định tuyến TGW, security VPC và spoke **giữ nguyên không đổi**. Đó là lý do làm phần này trước có ý nghĩa: nó kiểm chứng đúng chỗ dễ sai nhất.

Demo cũng **không tạo AWS account** và **không attach SCP** — cả hai đều làm `terraform destroy` không chạy được.

---

## Chạy

```bash
cd demo/network-lz-full
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform apply          # ~8 phút (firewall mất ~5 phút)

chmod +x verify.sh teardown.sh
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

`terraform output estimated_cost` in con số cho cấu hình hiện tại.

Chi tiết:

| Khoản | Đơn giá | Ghi chú |
|---|---|---|
| **Network Firewall endpoint** | ~$0.395/giờ | Khoản lớn nhất |
| TGW attachment | ~$0.05/giờ mỗi cái | 5 cái khi bật đủ |
| NAT Gateway | ~$0.045/giờ | |
| NLB | ~$0.0225/giờ | |
| EC2 t3.micro × 2 | ~$0.023/giờ | |
| **Gateway endpoint** | **$0** | Luôn bật |

**Quên xoá một tháng ≈ $540.** Đó là lý do `teardown.sh` có phần xác nhận, và tại sao mọi resource đều gắn tag `Ephemeral=true`.

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
| `vpc-ingress.tf` | IGW, NLB (chỗ Palo Alto và F5 sẽ chèn vào) |
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
| Không CDN | CloudFront + khoá origin |
| `delete_protection = false` | Bật cho firewall và NLB |
| NLB nghe HTTP:80 | HTTPS:443 + ACM |
| Không đối tác | 3rd-party VPC + VPN (doc 16) |

---

## Bước tiếp theo

1. Chạy hết 5 bước, xác nhận `verify.sh` xanh hết
2. Thêm 3rd-party VPC + VPN (doc 16)
3. Thêm Palo Alto + F5 khi có license — hạ tầng định tuyến không đổi
4. Chuyển sang multi-account (xem [`demo/centralized-network-multiaccount`](../centralized-network-multiaccount/) để biết phần RAM share và cross-account PHZ)
