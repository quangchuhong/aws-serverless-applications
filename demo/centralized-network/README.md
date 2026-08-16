# Demo: Network tập trung – dựng, xem, xoá

Bộ code mô phỏng mô hình ở [doc 13](../../docs/13-Centralized-Ingress-Egress-Network.md): mọi traffic Internet của workload đi qua egress VPC tập trung, không account/VPC nào có đường ra riêng.

**Thiết kế để dựng lên xem rồi xoá đi.** Chi phí một buổi thực hành ~$1.

---

## Quyết định thiết kế quan trọng: demo KHÔNG tạo AWS account

Doc 13 mô tả mô hình multi-account. Demo này mô phỏng bằng **nhiều VPC trong một account**, vì:

| Lý do | Chi tiết |
|---|---|
| Account **không xoá được** | Chỉ "đóng" được, và AWS giới hạn số account đóng trong 30 ngày |
| Email không tái sử dụng | Đóng account rồi vẫn không dùng lại được email đó |
| Không cần thiết cho mục đích học | Routing của TGW hoạt động y hệt nhau, dù VPC ở một hay nhiều account |

Phần khác biệt duy nhất khi lên multi-account là **chia sẻ TGW qua RAM** và **cross-account PHZ association** — được ghi chú ngay trong code.

---

## Chạy

```bash
cd demo/centralized-network

cp terraform.tfvars.example terraform.tfvars

terraform init
terraform apply          # ~5 phút

chmod +x verify.sh && ./verify.sh
```

Xong việc:

```bash
terraform destroy -auto-approve    # ~10 phút
```

---

## Kịch bản demo

### Bước 1 – Luồng egress tập trung (mặc định)

```bash
terraform apply
```

Vào EC2 trong spoke. Không có IP public, không có key pair — **việc vào được đã chứng minh đường egress hoạt động**, vì SSM agent phải ra Internet qua egress VPC mới đăng ký được:

```bash
aws ssm start-session --target "$(terraform output -raw test_instance_id)"
```

Trong session:

```bash
# IP ra Internet phải là NAT của egress VPC
curl -s https://checkip.amazonaws.com
# So sánh với: terraform output nat_public_ip

# Traceroute cho thấy hop đầu là TGW, không phải IGW
traceroute -n -m 3 8.8.8.8
```

Kiểm tra spoke thật sự không có đường ra riêng:

```bash
./verify.sh
```

### Bước 2 – Thêm VPC endpoint tập trung

```bash
# Bỏ comment enable_interface_endpoints trong terraform.tfvars
terraform apply
```

Trong session SSM:

```bash
# TRƯỚC: resolve ra IP public -> traffic đi qua NAT
# SAU:   resolve ra 10.1.x.x -> đi thẳng vào endpoint
dig +short ssm.ap-southeast-1.amazonaws.com
```

Đây là điểm mấu chốt: cùng một hostname, cùng một lệnh gọi, nhưng đường đi hoàn toàn khác — và không tốn phí NAT data processing nữa.

### Bước 3 – Thêm luồng ingress

```bash
# Bỏ comment enable_ingress trong terraform.tfvars
terraform apply

curl "http://$(terraform output -raw alb_dns_name)"
```

ALB nằm ở ingress VPC, target là **IP private trong spoke VPC**, đi qua TGW. Spoke vẫn không có IGW.

### Bước 4 – Kiểm chứng cách ly spoke-to-spoke

Từ session SSM trong `app-dev`, thử ping sang `app-prod`:

```bash
ping -c 3 10.20.1.10
```

Phải timeout. Security group **cho phép** ICMP — nhưng TGW route table `rtb-spokes` không propagate từ spoke khác nên không có đường đi. Đây là cách ly ở tầng routing, chắc chắn hơn security group.

---

## Chi phí

`terraform output estimated_hourly_cost_usd` in ra con số cho cấu hình hiện tại.

| Cấu hình | ~$/giờ | ~$/ngày |
|---|---|---|
| Bước 1 (2 spoke + egress + EC2) | $0.21 | $5.00 |
| Bước 2 (thêm 3 interface endpoint) | $0.24 | $5.70 |
| Bước 3 (thêm ingress + ALB) | $0.31 | $7.50 |
| Một spoke, không EC2 | $0.15 | $3.50 |

Chi tiết đơn giá:

| Khoản | Đơn giá | Ghi chú |
|---|---|---|
| TGW attachment | ~$0.05/giờ mỗi cái | Khoản lớn nhất |
| NAT Gateway | ~$0.045/giờ | Demo dùng 1, production cần mỗi AZ một cái |
| Interface endpoint | ~$0.01/giờ mỗi cái/AZ | |
| ALB | ~$0.0225/giờ | |
| EC2 t3.micro | ~$0.0116/giờ | |
| **Gateway endpoint (S3, DynamoDB)** | **$0** | Luôn bật |
| Transit Gateway (bản thân nó) | $0 | Chỉ tính phí attachment |
| Internet Gateway | $0 | |

Buổi thực hành 4 tiếng ≈ **$1**. Quên xoá một tháng ≈ **$150**.

Đơn giá tham khảo cho ap-southeast-1, kiểm tra lại bằng AWS Pricing Calculator.

---

## Dọn dẹp

```bash
terraform destroy -auto-approve
```

Mất khoảng 10 phút: NAT Gateway ~2 phút, TGW attachment ~3–5 phút mỗi cái (xoá song song).

Kiểm tra lại sau khi destroy — mọi lệnh phải trả về rỗng:

```bash
REGION=ap-southeast-1

aws ec2 describe-nat-gateways --region $REGION \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId' --output text

aws ec2 describe-addresses --region $REGION \
  --query 'Addresses[].AllocationId' --output text

aws ec2 describe-transit-gateways --region $REGION \
  --filters "Name=state,Values=available" \
  --query 'TransitGateways[].TransitGatewayId' --output text

aws ec2 describe-vpc-endpoints --region $REGION \
  --filters "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text
```

Tìm mọi thứ còn sót của demo bằng tag:

```bash
aws resourcegroupstaggingapi get-resources --region $REGION \
  --tag-filters "Key=Ephemeral,Values=true" \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

**EIP là khoản dễ quên nhất**: EIP không gắn vào đâu vẫn bị tính ~$0.005/giờ (~$3.6/tháng). `terraform destroy` có giải phóng, nhưng nếu destroy fail giữa chừng thì kiểm tra lại bằng lệnh trên.

### Nếu destroy bị treo

Thứ tự phụ thuộc hay gây kẹt:

| Kẹt ở | Nguyên nhân | Xử lý |
|---|---|---|
| VPC không xoá được | Còn ENI của endpoint hoặc NAT | Chờ NAT xoá xong (~2 phút) rồi `terraform destroy` lại |
| TGW không xoá được | Attachment chưa xoá hết | Chờ, rồi chạy lại |
| Subnet không xoá được | ENI mồ côi | `aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=<id>"` |
| ALB không xoá được | Deletion protection | Code đã đặt `false`, nếu sửa tay thì tắt lại |

Chạy `terraform destroy` lần hai gần như luôn xử lý được — nguyên nhân thường chỉ là timing.

---

## Cấu trúc file

| File | Nội dung |
|---|---|
| `versions.tf` | Provider, default tags (`Ephemeral=true` để dễ dọn) |
| `variables.tf` | Công tắc bật/tắt theo chi phí |
| `vpc.tf` | 3 loại VPC: ingress, egress, spoke |
| `tgw.tf` | TGW + 3 route table + association/propagation |
| `egress.tf` | IGW, NAT, route — gồm cả **đường về** hay bị quên |
| `ingress.tf` | IGW, ALB, target group với IP target xuyên VPC |
| `endpoints.tf` | Gateway endpoint (miễn phí) + interface endpoint tập trung + PHZ |
| `test-instance.tf` | EC2 vào bằng SSM, không key pair, không IP public |
| `outputs.tf` | Gồm ước tính chi phí theo giờ |
| `verify.sh` | 5 nhóm kiểm tra mô hình đúng thiết kế |

---

## Khác biệt so với production

Demo này **không** phải cấu hình dùng thật. Những chỗ đã đơn giản hoá:

| Demo | Production (doc 13) |
|---|---|
| 1 AZ, 1 NAT | Mỗi AZ một NAT — hiện tại là điểm chết đơn lẻ |
| Một account | Nhiều account, TGW share qua RAM |
| Không có SCP | SCP chặn IGW/NAT/EIP ở OU workload |
| PHZ khai báo VPC trực tiếp | Cross-account authorization + `ignore_changes = [vpc]` |
| Endpoint policy giới hạn theo account | `aws:PrincipalOrgID` |
| ALB nghe HTTP:80 | HTTPS:443 + ACM + WAF |
| Không có Flow Logs | Flow Logs tập trung về log-archive |
| Không có deletion protection | Bật cho ALB và resource quan trọng |

Muốn nâng lên multi-account, phần cần thêm là RAM share cho TGW và cross-account PHZ association — hai thứ này được ghi chú ngay tại chỗ trong `tgw.tf` và `endpoints.tf`.
