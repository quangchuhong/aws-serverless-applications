# Demo multi-account: Network tập trung qua network account

Bản multi-account của [demo single-account](../centralized-network/README.md). Ba account thật, TGW share qua RAM, PHZ cross-account.

**Account không bị đụng tới** — `terraform destroy` chỉ xoá resource bên trong, account vẫn nguyên vẹn để dùng lại lần sau.

---

## Chuẩn bị

Cần **ba account đã có sẵn** trong Organization:

| Vai trò | Chứa gì |
|---|---|
| `network` | TGW, egress VPC, NAT, interface endpoint |
| `spoke_a` | VPC workload (app-dev) |
| `spoke_b` | VPC workload (app-prod) |

Yêu cầu:

- Cả ba account assume được bằng cùng một role name (mặc định `OrganizationAccountAccessRole` — account tạo qua Organizations có sẵn).
- Đã bật **RAM sharing trong Organization**, nếu chưa:

```bash
aws ram enable-sharing-with-aws-organization
```

Không bật thì share TGW sẽ tạo invitation phải chấp nhận thủ công ở từng account.

---

## Chạy

```bash
cd demo/centralized-network-multiaccount

cat > terraform.tfvars <<'EOF'
network_account_id = "111111111111"
spoke_a_account_id = "222222222222"
spoke_b_account_id = "333333333333"
organization_id    = "o-xxxxxxxxxx"

region = "ap-southeast-1"
az     = "ap-southeast-1a"

enable_interface_endpoints = false   # bật ở bước 2
enable_test_instances      = true
EOF

terraform init
terraform apply        # ~7 phút
```

Chạy từ management account, hoặc từ bất kỳ account nào assume được cả ba role.

Xoá:

```bash
terraform destroy -auto-approve    # ~10 phút, account giữ nguyên
```

---

## Bốn thứ chỉ multi-account mới có

Đây là phần đáng học nhất, không xuất hiện trong bản single-account:

### 1. RAM share TGW

```hcl
resource "aws_ram_resource_share" "tgw" { ... }
resource "aws_ram_resource_association" "tgw" { resource_arn = aws_ec2_transit_gateway.hub.arn }
resource "aws_ram_principal_association" "spokes" { for_each = spoke account ids }
```

Không có phần này thì account spoke không "nhìn thấy" TGW để attach vào.

### 2. Attachment tạo ở spoke, route table quản ở network

| Việc | Làm ở account nào |
|---|---|
| Tạo `aws_ec2_transit_gateway_vpc_attachment` | **Spoke** (chủ VPC) |
| `route_table_association` / `propagation` | **Network** (chủ TGW) |

Đây là ranh giới quyền quan trọng trong mô hình thật: team ứng dụng tự attach VPC của họ, nhưng **không** tự quyết định VPC đó được đi tới đâu. Việc đó do network team kiểm soát.

Trong code, chú ý `depends_on = [aws_ram_principal_association.spokes]` ở module spoke — share phải xong trước khi attach.

### 3. `auto_accept_shared_attachments`

```hcl
auto_accept_shared_attachments = "enable"
```

Bật thì attachment từ account khác tự được chấp nhận. Tắt thì network account phải accept từng cái bằng `aws_ec2_transit_gateway_vpc_attachment_accepter` — chậm hơn nhưng là một cổng kiểm soát nữa. Production thường tắt.

### 4. Cross-account PHZ — hai bước

```hcl
# Bước 1: chủ zone cấp phép
resource "aws_route53_vpc_association_authorization" "spoke_a" {
  provider = aws.network
  zone_id  = ...
  vpc_id   = module.spoke_a.vpc_id
}

# Bước 2: chủ VPC thực hiện association
resource "aws_route53_zone_association" "spoke_a" {
  provider = aws.spoke_a
  zone_id  = aws_route53_vpc_association_authorization.spoke_a.zone_id
  vpc_id   = aws_route53_vpc_association_authorization.spoke_a.vpc_id
}
```

Và bắt buộc có `lifecycle { ignore_changes = [vpc] }` trên `aws_route53_zone`. Thiếu nó thì mỗi lần apply Terraform coi các association từ account khác là "thừa" và gỡ chúng ra — DNS của spoke chết mà không hiểu vì sao.

---

## Kiểm chứng

```bash
# 1. Vào EC2 ở spoke A (cần profile assume được vào account đó)
aws ssm start-session --target "$(terraform output -json spoke_a | jq -r .instance_id)" \
  --region ap-southeast-1 --profile spoke-a
```

Trong session:

```bash
# IP ra Internet phải là NAT của NETWORK account, không phải của account này
curl -s https://checkip.amazonaws.com
# So với: terraform output nat_public_ip

# Account này KHÔNG có NAT nào
# (chạy ở máy ngoài, với profile spoke-a)
aws ec2 describe-nat-gateways --profile spoke-a --query 'NatGateways[?State==`available`]'
# => []
```

Cách ly giữa hai account:

```bash
# Từ EC2 ở spoke A, ping sang spoke B -> phải timeout
ping -c 3 "$(terraform output -json spoke_b | jq -r .private_ip)"
```

Security group **cho phép** ICMP. Timeout là do TGW route table `rtb-spokes` không propagate từ spoke khác — cách ly ở tầng routing, không phụ thuộc vào việc ai đó sửa security group.

---

## Chi phí

| Cấu hình | ~$/giờ | ~$/ngày |
|---|---|---|
| Mặc định (3 attachment + NAT + 2 EC2) | $0.22 | $5.30 |
| Bật interface endpoint (+3) | $0.25 | $6.00 |

`terraform output estimated_hourly_cost_usd` in ra con số hiện tại.

Đơn giá tham khảo ap-southeast-1, kiểm tra lại bằng AWS Pricing Calculator.

---

## Sau khi destroy

Còn lại (và đó là điều mong muốn):

| Còn lại | Chi phí |
|---|---|
| Ba AWS account | $0 |
| `OrganizationAccountAccessRole` | $0 |
| Cấu trúc OU | $0 |

Bị xoá sạch: VPC, TGW, NAT, EIP, endpoint, PHZ, EC2, IAM role của demo, RAM share.

Kiểm tra từng account sau khi destroy:

```bash
for p in network spoke-a spoke-b; do
  echo "=== $p ==="
  aws ec2 describe-nat-gateways --profile "$p" --region ap-southeast-1 \
    --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text
  aws ec2 describe-addresses --profile "$p" --region ap-southeast-1 \
    --query 'Addresses[].AllocationId' --output text
  aws resourcegroupstaggingapi get-resources --profile "$p" --region ap-southeast-1 \
    --tag-filters "Key=Ephemeral,Values=true" \
    --query 'length(ResourceTagMappingList)' --output text
done
```

Cả ba phải trả về rỗng / `0`.

**EIP là khoản dễ sót nhất** — EIP không gắn vào đâu vẫn tính ~$3.6/tháng.

---

## Thêm spoke thứ ba

Terraform **không** cho `for_each` trên provider, nên mỗi account phải khai báo tường minh. Ba chỗ cần sửa:

```hcl
# 1. providers.tf
provider "aws" {
  alias  = "spoke_c"
  region = var.region
  assume_role { role_arn = "arn:aws:iam::${var.spoke_c_account_id}:role/${var.execution_role_name}" }
  default_tags { tags = local.common_tags }
}

# 2. spokes.tf
module "spoke_c" {
  source    = "./modules/spoke"
  providers = { aws = aws.spoke_c }
  name      = "data"
  cidr      = "10.30.0.0/16"
  # ... các biến còn lại
  depends_on = [aws_ram_principal_association.spokes]
}

# 3. spokes.tf - thêm vào local.spoke_attachments
locals {
  spoke_attachments = {
    "app-dev"  = module.spoke_a.attachment_id
    "app-prod" = module.spoke_b.attachment_id
    "data"     = module.spoke_c.attachment_id   # thêm dòng này
  }
}
```

Nhớ thêm `var.spoke_c_account_id` vào `variables.tf` và `aws_ram_principal_association`.

Đây chính là lý do LZ thật dùng **một state cho mỗi account** thay vì gom hết vào một config — xem [doc 09 mục 5.3](../../docs/09-Account-Vending-Tu-Dong.md).

---

## Chưa có trong demo này

| Thiếu | Xem ở đâu |
|---|---|
| SCP chặn IGW/NAT/EIP ở spoke | [Doc 13 mục 4](../../docs/13-Centralized-Ingress-Egress-Network.md) |
| Ingress VPC + ALB + WAF | [Doc 13 mục 7](../../docs/13-Centralized-Ingress-Egress-Network.md) — hoặc bản single-account |
| NAT ở nhiều AZ | Demo dùng 1 AZ để tiết kiệm |
| VPC Flow Logs tập trung | [Doc 06 mục 8](../../docs/06-Aws-Landing-Zone.md) |
| Network Firewall | [Doc 13 mục 9](../../docs/13-Centralized-Ingress-Egress-Network.md) — ~$576/tháng, cân nhắc kỹ |

SCP cố tình để ngoài demo: attach SCP rồi thì `terraform destroy` sẽ không xoá được EIP và NAT, kẹt giữa chừng. Trong LZ thật, thứ tự đúng là dọn resource trước rồi mới attach SCP (doc 13 mục 4.3).
