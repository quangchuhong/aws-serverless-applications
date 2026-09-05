# Centralized Ingress/Egress – khoá Internet ở mọi account, đi qua network account

Ví dụ 13: Chặn hoàn toàn đường ra Internet ở mọi account workload, dồn toàn bộ traffic in/out qua **hai VPC chuyên trách** trong network account.

> Tài liệu chi tiết. Thiết kế tổng thể, quy hoạch CIDR chuẩn và bảng định tuyến Transit Gateway ở [17 – Network LZ Design Guide](./17-Network-LZ-Design-Guide.md).

Tiếp nối [06 – Landing Zone](./06-Aws-Landing-Zone.md) (mục 11, TGW) và [12 – DNS và VPC Endpoint](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md).

---

## 1. Mục tiêu

| Yêu cầu | Cách đạt được |
|---|---|
| Account workload không có đường ra Internet trực tiếp | SCP chặn IGW/NAT/EIP + không tạo public subnet |
| Mọi traffic ra Internet đi qua một chỗ | Egress VPC với NAT Gateway tập trung |
| Mọi traffic từ Internet vào đi qua một chỗ | Ingress VPC với ALB/NLB + WAF |
| Kiểm soát và ghi log được | Network Firewall / VPC Flow Logs tập trung |
| Không ai lách được | SCP (chặn) + AWS Config (phát hiện) |

Kết quả: một điểm duy nhất để kiểm soát, thanh tra và ghi log toàn bộ traffic Internet của cả tổ chức. Đây là yêu cầu bắt buộc trong hầu hết chuẩn tuân thủ (PCI-DSS, ISO 27001, các quy định ngành tài chính).

---

## 2. Vì sao tách **hai** VPC thay vì gộp một

Nhiều tài liệu gộp inbound và outbound vào một "inspection VPC". Tách ra tốt hơn vì bốn lý do:

| Lý do | Giải thích |
|---|---|
| **Bán kính ảnh hưởng** | Ingress VPC hứng traffic từ Internet — bề mặt tấn công lớn nhất. Nếu bị xâm nhập, kẻ tấn công **không** có sẵn đường egress để exfil dữ liệu |
| **Chính sách khác nhau** | Ingress cần WAF, Shield, ALB. Egress cần NAT, domain allowlist. Trộn vào một VPC làm SG và NACL rối |
| **Route table đơn giản hơn** | Mỗi VPC một hướng traffic → không phải xử lý routing bất đối xứng |
| **Vận hành độc lập** | Bảo trì đường egress không ảnh hưởng dịch vụ public đang phục vụ khách hàng |

Đánh đổi: thêm một TGW attachment (~$36.50/tháng) và thêm một VPC phải quản. Với môi trường enterprise, đây là cái giá rẻ.

---

## 3. Kiến trúc

```text
                            INTERNET
                    ▲                    │
                    │                    ▼
    ┌───────────────┴──────┐   ┌─────────┴────────────┐
    │  INGRESS VPC         │   │  EGRESS VPC          │
    │  10.0.0.0/16         │   │  10.1.0.0/16         │
    │  (network account)   │   │  (network account)   │
    │                      │   │                      │
    │  ┌────────────────┐  │   │  ┌────────────────┐  │
    │  │ IGW            │  │   │  │ IGW            │  │
    │  └───────┬────────┘  │   │  └───────▲────────┘  │
    │          │           │   │          │           │
    │  public subnets      │   │  public subnets      │
    │  ┌───────▼────────┐  │   │  ┌───────┴────────┐  │
    │  │ ALB + WAF      │  │   │  │ NAT GW (AZ-a)  │  │
    │  │ (internet-     │  │   │  │ NAT GW (AZ-b)  │  │
    │  │  facing)       │  │   │  └───────▲────────┘  │
    │  └───────┬────────┘  │   │          │           │
    │          │           │   │  ┌───────┴────────┐  │
    │  ┌───────▼────────┐  │   │  │ (tuỳ chọn)     │  │
    │  │ tgw subnets    │  │   │  │ Network        │  │
    │  └───────┬────────┘  │   │  │ Firewall       │  │
    └──────────┼───────────┘   │  └───────▲────────┘  │
               │               │  ┌───────┴────────┐  │
               │               │  │ tgw subnets    │  │
               │               │  └───────▲────────┘  │
               │               └──────────┼───────────┘
               │                          │
          ┌────▼──────────────────────────┴────┐
          │        TRANSIT GATEWAY             │
          │  rtb-ingress │ rtb-egress │        │
          │           rtb-spokes               │
          └────┬──────────────┬────────────────┘
               │              │
     ┌─────────▼───┐   ┌──────▼──────┐   ┌─────────────┐
     │ app-dev VPC │   │ app-prod    │   │ data VPC    │
     │ 10.10.0.0/16│   │ 10.20.0.0/16│   │ 10.30.0.0/16│
     │             │   │             │   │             │
     │ KHÔNG IGW   │   │ KHÔNG IGW   │   │ KHÔNG IGW   │
     │ KHÔNG NAT   │   │ KHÔNG NAT   │   │ KHÔNG NAT   │
     │ KHÔNG EIP   │   │ KHÔNG EIP   │   │ KHÔNG EIP   │
     │ chỉ private │   │ chỉ private │   │ chỉ private │
     │ subnet      │   │ subnet      │   │ subnet      │
     └─────────────┘   └─────────────┘   └─────────────┘
```

Quy hoạch CIDR — **bảng chuẩn ở [17 – Design Guide mục 3](./17-Network-LZ-Design-Guide.md)**:

| Vùng | CIDR |
|---|---|
| Ingress VPC | `10.0.0.0/16` |
| Security VPC (doc 15) | `10.1.0.0/16` |
| Egress VPC | `10.2.0.0/16` |
| 3rd-party VPC (doc 16) | `10.9.0.0/16` |
| NonProd | `10.10.0.0/15` + `10.12.0.0/15` |
| Prod | `10.20.0.0/14` |
| Sandbox | `10.60.0.0/14` |

> Bản đầu của doc này gán `10.1.0.0/16` cho egress VPC. Khi security VPC được chèn vào ([doc 15](./15-Security-VPC-Network-Firewall.md)), `10.1.0.0/16` dành cho security và egress chuyển sang `10.2.0.0/16`. Ví dụ Terraform bên dưới vẫn ghi `10.1.0.0/16` cho egress — đổi thành `10.2.0.0/16` nếu bạn triển khai cả security VPC.

---

## 4. Lớp 1: SCP khoá đường ra

> **Đã có code chạy được:** SCP này hiện thực thành `network_lock` trong [`landing-zone/organization/scp.tf`](../landing-zone/organization/scp.tf), gắn vào `Workloads`, `Data Analytics`, `Sandbox` — **không** gắn vào `Infrastructure`, vì network account sống ở đó và cần đúng những action bị chặn.
>
> Khác biệt so với file JSON dưới đây: layer đó **gộp** vào 4 SCP tổng thay vì mỗi guardrail một policy, vì AWS chỉ cho **5 policy/target** và `FullAWSAccess` đã chiếm 1. Xem [doc 21 mục 4](./21-Control-Tower-vs-DIY.md).


Đây là phần "khoá". Không có nó thì mọi thứ còn lại chỉ là gợi ý.

### 4.1. policies/deny-internet-paths.json

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInternetGateways",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:CreateEgressOnlyInternetGateway",
        "ec2:CreateCarrierGateway",
        "ec2:CreateDefaultVpc",
        "ec2:CreateDefaultSubnet"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyNatGateway",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateNatGateway"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyElasticIp",
      "Effect": "Deny",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:AssociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyPublicIpOnInstanceLaunch",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "Bool": {
          "ec2:AssociatePublicIpAddress": "true"
        }
      }
    },
    {
      "Sid": "DenyAlternativeNetworkPaths",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateVpcPeeringConnection",
        "ec2:AcceptVpcPeeringConnection",
        "ec2:CreateTransitGateway",
        "ec2:CreateVpnGateway",
        "ec2:CreateVpnConnection",
        "ec2:CreateClientVpnEndpoint",
        "globalaccelerator:CreateAccelerator",
        "globalaccelerator:CreateCustomRoutingAccelerator"
      ],
      "Resource": "*"
    }
  ]
}
```

Giải thích vài lựa chọn:

- **`CreateDefaultVpc`** — default VPC đi kèm IGW sẵn. Không chặn cái này thì một lệnh CLI là có ngay đường ra Internet.
- **`AllocateAddress`** — không có EIP thì không gán được IP public cho instance hay NAT.
- **`CreateVpcPeeringConnection`, `CreateTransitGateway`, VPN** — chặn các đường vòng. Không có nhóm này thì team có thể peer sang một VPC khác có IGW.
- **Global Accelerator** — đường vào từ Internet không qua ingress VPC.
- **`ModifySubnetAttribute`** cố tình **không** chặn: không có IGW thì `MapPublicIpOnLaunch` vô hại, mà chặn nó lại cản trở việc quản lý subnet bình thường.

### 4.2. Attach vào đâu

Quan trọng: **network account phải nằm ngoài phạm vi SCP này**, vì chính nó cần IGW và NAT.

```hcl
resource "aws_organizations_policy" "deny_internet" {
  name    = "deny-internet-paths"
  type    = "SERVICE_CONTROL_POLICY"
  content = file("${path.module}/policies/deny-internet-paths.json")
}

# Attach vào Workloads và Security — KHÔNG attach vào Infrastructure
# (network account nằm trong Infrastructure OU)
resource "aws_organizations_policy_attachment" "deny_internet" {
  for_each = toset([
    aws_organizations_organizational_unit.workloads.id,
    aws_organizations_organizational_unit.security.id,
  ])

  policy_id = aws_organizations_policy.deny_internet.id
  target_id = each.value
}
```

Đây chính là lý do vì sao cấu trúc OU ở doc 06 tách `Infrastructure` riêng khỏi `Workloads` — để SCP này áp được chính xác mà không cần điều kiện account ID.

Nếu network account đang nằm chung OU với account khác, tách nó ra OU riêng **trước khi** attach SCP.

### 4.3. Roll out — đừng làm một phát

SCP này chặn những thứ team đang dùng hằng ngày. Trình tự bắt buộc:

```text
1. Dựng xong ingress + egress VPC, TGW routing hoạt động
2. Attach spoke VPC vào TGW, kiểm tra egress đi được
3. Migrate workload đang dùng NAT riêng sang đường tập trung
4. Xoá IGW/NAT cũ ở các spoke (bằng Terraform)
5. Attach SCP vào OU Sandbox — sống 1 tuần
6. Mở rộng NonProd — sống 2 tuần
7. Mở rộng Prod
```

Đảo thứ tự bước 4 và 5 là công thức chắc chắn gây sự cố: SCP không xoá IGW đang có, nhưng nó chặn việc tạo lại — nên nếu Terraform của team cần recreate một NAT Gateway thì apply sẽ fail giữa chừng.

---

## 5. Lớp 2: Phát hiện bằng AWS Config

SCP chặn cái mới. Config tìm cái đã lỡ tồn tại:

```hcl
resource "aws_config_organization_managed_rule" "no_unauthorized_igw" {
  provider = aws.security

  name            = "internet-gateway-authorized-vpc-only"
  rule_identifier = "INTERNET_GATEWAY_AUTHORIZED_VPC_ONLY"

  input_parameters = jsonencode({
    AuthorizedVpcIds = "${var.ingress_vpc_id},${var.egress_vpc_id}"
  })
}

resource "aws_config_organization_managed_rule" "no_public_ip" {
  provider = aws.security

  name            = "ec2-instance-no-public-ip"
  rule_identifier = "EC2_INSTANCE_NO_PUBLIC_IP"
  excluded_accounts = [var.network_account_id]
}

resource "aws_config_organization_managed_rule" "subnet_no_auto_public_ip" {
  provider = aws.security

  name            = "subnet-auto-assign-public-ip-disabled"
  rule_identifier = "SUBNET_AUTO_ASSIGN_PUBLIC_IP_DISABLED"
  excluded_accounts = [var.network_account_id]
}
```

Gắn EventBridge bắt finding NON_COMPLIANT → SNS → Slack, dùng lại pattern alert ở [ví dụ 01](./01-Example-Aws-Serverless-Order-API.md).

---

## 6. Egress VPC

### 6.1. Cấu trúc subnet

Ba tầng subnet, mỗi AZ một bộ:

| Tầng | CIDR mẫu | Chứa gì | Route mặc định |
|---|---|---|---|
| `public` | `10.1.0.0/24`, `10.1.1.0/24` | NAT Gateway | `0.0.0.0/0` → IGW |
| `firewall` (tuỳ chọn) | `10.1.10.0/28`, `10.1.11.0/28` | Network Firewall endpoint | `0.0.0.0/0` → NAT |
| `tgw` | `10.1.20.0/28`, `10.1.21.0/28` | ENI của TGW attachment | `0.0.0.0/0` → NAT (hoặc Firewall) |

### 6.2. Terraform

```hcl
# 5-network/egress-vpc.tf

locals {
  azs = ["ap-southeast-1a", "ap-southeast-1b"]

  egress_subnets = {
    public = { a = "10.1.0.0/24",   b = "10.1.1.0/24"   }
    tgw    = { a = "10.1.20.0/28",  b = "10.1.21.0/28"  }
  }

  spoke_supernet = "10.8.0.0/13"   # phủ toàn bộ dải spoke
}

resource "aws_vpc" "egress" {
  provider             = aws.network
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "acme-egress-vpc" }
}

resource "aws_internet_gateway" "egress" {
  provider = aws.network
  vpc_id   = aws_vpc.egress.id

  tags = { Name = "acme-egress-igw" }
}

########################
# Subnets
########################

resource "aws_subnet" "egress_public" {
  provider = aws.network
  for_each = { a = 0, b = 1 }

  vpc_id            = aws_vpc.egress.id
  cidr_block        = local.egress_subnets.public[each.key]
  availability_zone = local.azs[each.value]

  # Public subnet nhưng KHÔNG tự gán IP public - chỉ NAT GW ở đây
  map_public_ip_on_launch = false

  tags = { Name = "egress-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "egress_tgw" {
  provider = aws.network
  for_each = { a = 0, b = 1 }

  vpc_id            = aws_vpc.egress.id
  cidr_block        = local.egress_subnets.tgw[each.key]
  availability_zone = local.azs[each.value]

  tags = { Name = "egress-tgw-${each.key}", Tier = "tgw" }
}

########################
# NAT Gateway – mỗi AZ một cái
########################

resource "aws_eip" "nat" {
  provider = aws.network
  for_each = toset(["a", "b"])
  domain   = "vpc"

  tags = { Name = "egress-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "egress" {
  provider      = aws.network
  for_each      = toset(["a", "b"])
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.egress_public[each.key].id

  tags = { Name = "egress-nat-${each.key}" }

  depends_on = [aws_internet_gateway.egress]
}

########################
# Route tables
########################

# Public subnet: ra Internet qua IGW, về spoke qua TGW
resource "aws_route_table" "egress_public" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.egress.id

  tags = { Name = "egress-public-rt-${each.key}" }
}

resource "aws_route" "egress_public_default" {
  provider               = aws.network
  for_each               = aws_route_table.egress_public
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

# QUAN TRỌNG: đường về cho traffic từ spoke
resource "aws_route" "egress_public_to_spokes" {
  provider               = aws.network
  for_each               = aws_route_table.egress_public
  route_table_id         = each.value.id
  destination_cidr_block = local.spoke_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  provider       = aws.network
  for_each       = toset(["a", "b"])
  subnet_id      = aws_subnet.egress_public[each.key].id
  route_table_id = aws_route_table.egress_public[each.key].id
}

# TGW subnet: mọi thứ ra NAT của CÙNG AZ (tránh phí cross-AZ)
resource "aws_route_table" "egress_tgw" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.egress.id

  tags = { Name = "egress-tgw-rt-${each.key}" }
}

resource "aws_route" "egress_tgw_default" {
  provider               = aws.network
  for_each               = aws_route_table.egress_tgw
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.egress[each.key].id
}

resource "aws_route_table_association" "egress_tgw" {
  provider       = aws.network
  for_each       = toset(["a", "b"])
  subnet_id      = aws_subnet.egress_tgw[each.key].id
  route_table_id = aws_route_table.egress_tgw[each.key].id
}

########################
# TGW attachment
########################

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [for k in ["a", "b"] : aws_subnet.egress_tgw[k].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  # Bật khi có Network Firewall - giữ đối xứng luồng đi/về
  appliance_mode_support = "disable"

  tags = { Name = "tgwa-egress" }
}
```

Điểm hay bị bỏ sót: **route `egress_public_to_spokes`**. Không có nó, gói tin từ spoke ra được Internet nhưng gói trả về từ NAT không biết đường quay lại spoke — biểu hiện là timeout, rất khó đoán.

Điểm thứ hai: TGW subnet trỏ về NAT **cùng AZ**. Trỏ chéo AZ vẫn chạy nhưng phát sinh phí cross-AZ cho toàn bộ lưu lượng egress.

---

## 7. Ingress VPC

### 7.1. Hai cách đưa traffic vào spoke

| Cách | Cơ chế | Ưu | Nhược |
|---|---|---|---|
| **A. ALB với IP target qua TGW** | ALB ở ingress VPC, target là IP private trong spoke | Đơn giản, ít thành phần | Ingress VPC cần route tới mọi spoke |
| **B. PrivateLink** | NLB ở spoke → Endpoint Service → interface endpoint ở ingress VPC → ALB target endpoint đó | Cách ly tốt nhất, không cần CIDR routable | Nhiều thành phần, thêm chi phí endpoint |

Cách A đủ tốt cho hầu hết trường hợp và là cách trình bày dưới đây. Chọn cách B khi spoke thuộc đơn vị khác, CIDR có thể trùng, hoặc yêu cầu cách ly rất chặt.

> Với ALB dùng IP target, IP phải nằm trong dải RFC 1918 (hoặc các dải AWS cho phép) và **định tuyến phải thông** — TGW đáp ứng được. Đăng ký target xong nhớ kiểm tra health check thật sự pass, đừng tin mỗi trạng thái `initial`.

### 7.2. Terraform

```hcl
# 5-network/ingress-vpc.tf

resource "aws_vpc" "ingress" {
  provider             = aws.network
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "acme-ingress-vpc" }
}

resource "aws_internet_gateway" "ingress" {
  provider = aws.network
  vpc_id   = aws_vpc.ingress.id

  tags = { Name = "acme-ingress-igw" }
}

resource "aws_subnet" "ingress_public" {
  provider = aws.network
  for_each = { a = { az = 0, cidr = "10.0.0.0/24" }, b = { az = 1, cidr = "10.0.1.0/24" } }

  vpc_id                  = aws_vpc.ingress.id
  cidr_block              = each.value.cidr
  availability_zone       = local.azs[each.value.az]
  map_public_ip_on_launch = false

  tags = { Name = "ingress-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "ingress_tgw" {
  provider = aws.network
  for_each = { a = { az = 0, cidr = "10.0.20.0/28" }, b = { az = 1, cidr = "10.0.21.0/28" } }

  vpc_id            = aws_vpc.ingress.id
  cidr_block        = each.value.cidr
  availability_zone = local.azs[each.value.az]

  tags = { Name = "ingress-tgw-${each.key}", Tier = "tgw" }
}

########################
# Route tables
########################

resource "aws_route_table" "ingress_public" {
  provider = aws.network
  vpc_id   = aws_vpc.ingress.id

  tags = { Name = "ingress-public-rt" }
}

resource "aws_route" "ingress_public_default" {
  provider               = aws.network
  route_table_id         = aws_route_table.ingress_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress.id
}

# ALB cần với tới target trong spoke
resource "aws_route" "ingress_public_to_spokes" {
  provider               = aws.network
  route_table_id         = aws_route_table.ingress_public.id
  destination_cidr_block = local.spoke_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.ingress]
}

resource "aws_route_table_association" "ingress_public" {
  provider       = aws.network
  for_each       = aws_subnet.ingress_public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.ingress_public.id
}

resource "aws_ec2_transit_gateway_vpc_attachment" "ingress" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.ingress.id
  subnet_ids         = [for k in ["a", "b"] : aws_subnet.ingress_tgw[k].id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "tgwa-ingress" }
}

########################
# ALB + WAF
########################

resource "aws_security_group" "alb" {
  provider    = aws.network
  name        = "ingress-alb"
  description = "ALB cong khai"
  vpc_id      = aws_vpc.ingress.id

  ingress {
    description = "HTTPS tu Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Toi target trong spoke"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.spoke_supernet]
  }

  tags = { Name = "ingress-alb" }
}

resource "aws_lb" "ingress" {
  provider           = aws.network
  name               = "acme-ingress-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = [for s in aws_subnet.ingress_public : s.id]
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = true

  access_logs {
    bucket  = "acme-alb-logs-${var.log_archive_account_id}"
    prefix  = "ingress"
    enabled = true
  }

  tags = { Name = "acme-ingress-alb" }
}

# Target group trỏ vào IP private trong spoke
resource "aws_lb_target_group" "app_prod" {
  provider    = aws.network
  name        = "tg-app-prod"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.ingress.id

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group_attachment" "app_prod" {
  provider         = aws.network
  for_each         = toset(var.app_prod_target_ips)  # vd ["10.20.1.15", "10.20.2.22"]
  target_group_arn = aws_lb_target_group.app_prod.arn
  target_id        = each.value
  port             = 8080

  # BẮT BUỘC khi target nằm ngoài VPC của ALB
  availability_zone = "all"
}

resource "aws_wafv2_web_acl_association" "ingress" {
  provider     = aws.network
  resource_arn = aws_lb.ingress.arn
  web_acl_arn  = aws_wafv2_web_acl.ingress.arn
}
```

`availability_zone = "all"` trong `aws_lb_target_group_attachment` là bắt buộc khi IP target nằm ngoài VPC của ALB. Thiếu nó thì đăng ký target sẽ lỗi.

Phía spoke, security group của workload phải cho phép traffic từ **CIDR của ingress VPC** (không phải từ SG của ALB — SG reference không hoạt động xuyên VPC qua TGW):

```hcl
resource "aws_security_group_rule" "from_ingress_alb" {
  provider          = aws.app_prod
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/16"]   # ingress VPC
  security_group_id = var.app_sg_id
  description       = "Tu ALB o ingress VPC"
}
```

---

## 8. Transit Gateway route table – chỗ hay sai nhất

Ba route table riêng biệt, mỗi cái phục vụ một vai trò:

| Route table | Associate với | Propagate từ | Route tĩnh |
|---|---|---|---|
| `rtb-spokes` | Mọi spoke attachment | ingress attachment | `0.0.0.0/0` → egress attachment |
| `rtb-egress` | egress attachment | mọi spoke attachment | — |
| `rtb-ingress` | ingress attachment | mọi spoke attachment | — |

Tách như vậy tạo ra ba tính chất quan trọng:

1. **Spoke không thấy nhau.** `rtb-spokes` không propagate từ spoke khác → app-dev không route được sang app-prod. Muốn cho phép cặp nào thì thêm route tĩnh cho đúng cặp đó.
2. **Traffic ra Internet bắt buộc qua egress VPC** — chỉ có một default route duy nhất.
3. **Egress VPC không tự đi vào được spoke** trừ khi có phiên do spoke khởi tạo.

```hcl
# 5-network/tgw-routing.tf

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "rtb-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "rtb-egress" }
}

resource "aws_ec2_transit_gateway_route_table" "ingress" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "rtb-ingress" }
}

########################
# Association
########################

resource "aws_ec2_transit_gateway_route_table_association" "spokes" {
  provider                       = aws.network
  for_each                       = var.spoke_attachment_ids   # { app_dev = "tgw-attach-...", ... }
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route_table_association" "egress" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route_table_association" "ingress" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress.id
}

########################
# Propagation
########################

# egress và ingress học được đường tới mọi spoke
resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_egress" {
  provider                       = aws.network
  for_each                       = var.spoke_attachment_ids
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_ingress" {
  provider                       = aws.network
  for_each                       = var.spoke_attachment_ids
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress.id
}

# spoke học được đường VỀ ingress VPC (cho traffic trả lời ALB)
resource "aws_ec2_transit_gateway_route_table_propagation" "ingress_to_spokes" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

########################
# Default route: mọi spoke ra Internet qua egress VPC
########################

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  provider                       = aws.network
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}
```

Phía spoke VPC, route table của private subnet:

```hcl
resource "aws_route" "spoke_default_to_tgw" {
  provider               = aws.app_prod
  for_each               = toset(var.app_prod_private_route_table_ids)
  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id
}
```

Chỉ một dòng này ở phía spoke — mọi thứ còn lại do TGW quyết định.

---

## 9. Network Firewall (tuỳ chọn, và đắt)

Muốn thanh tra và **allowlist theo domain** cho traffic egress:

```hcl
resource "aws_networkfirewall_rule_group" "domain_allowlist" {
  provider = aws.network
  capacity = 100
  name     = "egress-domain-allowlist"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]

        targets = [
          ".amazonaws.com",
          ".ubuntu.com",
          ".debian.org",
          ".pypi.org",
          ".npmjs.org",
          ".github.com",
          ".docker.io",
        ]
      }
    }
  }
}
```

Ba điều phải biết trước khi bật:

1. **Chi phí rất cao.** Firewall endpoint khoảng **$0.395/giờ mỗi AZ** ≈ **$288/tháng/AZ**, cộng ~$0.065/GB xử lý. Hai AZ là **~$576/tháng** trước khi tính data. Đắt hơn toàn bộ phần còn lại của LZ cộng lại.
2. **Phải bật `appliance_mode_support = "enable"`** trên TGW attachment của egress VPC. Không bật thì gói đi và gói về có thể rơi vào hai AZ khác nhau, firewall stateful thấy luồng nửa vời và drop.
3. **Bắt đầu bằng ALERT.** Allowlist domain gần như chắc chắn thiếu thứ gì đó ở lần đầu — chạy chế độ alert vài ngày, đọc log, rồi mới chuyển sang drop.

Phương án rẻ hơn cho phần lớn nhu cầu: **VPC endpoint (doc 12) + Route 53 DNS Firewall**. Endpoint kéo traffic tới AWS service ra khỏi đường NAT hoàn toàn, DNS Firewall chặn domain xấu ở tầng phân giải tên. Cộng lại khoảng $30/tháng thay vì $576, và xử lý được đa số tình huống thực tế.

> Nếu yêu cầu là **mọi traffic của mọi account** phải qua Network Firewall — gồm cả luồng giữa các account với nhau — thì firewall nên nằm ở một **security VPC riêng** thay vì nhét vào egress VPC. Thiết kế đầy đủ, gồm TGW route table giữ tính đối xứng và runbook bypass, ở [15 – Security VPC](./15-Security-VPC-Network-Firewall.md).

---

## 10. Những gì mô hình này **không** chặn được

Phần này quan trọng — đừng báo cáo lên lãnh đạo là "đã khoá hoàn toàn Internet" nếu chưa hiểu các lỗ hổng còn lại:

| Đường ra còn lại | Vì sao SCP không chặn | Xử lý |
|---|---|---|
| **Lambda không đặt trong VPC** | Chạy trên hạ tầng AWS quản lý, có Internet mặc định | Bắt buộc Lambda phải gắn VPC (SCP điều kiện trên `lambda:VpcIds`), hoặc chấp nhận |
| **Gọi AWS API public** | Traffic tới `*.amazonaws.com` không đi qua VPC | Dùng VPC endpoint + endpoint policy giới hạn org (doc 12) |
| **S3 bucket public** | Không liên quan đường mạng | S3 Block Public Access ở mức account (doc 06 mục 12) |
| **CloudShell, SSM Session Manager** | Kênh của AWS, không qua VPC | Chấp nhận; ghi log CloudTrail |
| **Dịch vụ serverless (SQS, SNS, DynamoDB)** | Endpoint public của AWS | VPC endpoint + `aws:PrincipalOrgID` |
| **Exfil qua DNS** | Query DNS vẫn đi được | Route 53 DNS Firewall + query logging |

Điểm đầu tiên đáng lưu ý nhất với repo này: các ví dụ 01–05 dùng **Lambda không đặt trong VPC**, và những Lambda đó vẫn ra Internet được bình thường. Nếu yêu cầu tuân thủ bắt buộc mọi traffic phải qua egress tập trung thì phải đưa Lambda vào VPC — đổi lại là cold start lâu hơn, cần VPC endpoint cho mọi service Lambda gọi, và tốn thêm tiền.

Quyết định này nên đưa ra sớm và ghi lại thành ADR, vì sửa sau rất tốn công.

---

## 11. Chi phí

| Thành phần | Đơn giá | Tháng |
|---|---|---|
| TGW attachment – ingress VPC | ~$0.05/giờ | ~$36.50 |
| TGW attachment – egress VPC | ~$0.05/giờ | ~$36.50 |
| TGW attachment – mỗi spoke | ~$0.05/giờ | ~$36.50/spoke |
| TGW data processing | ~$0.02/GB | theo lưu lượng |
| NAT Gateway × 2 AZ | ~$0.045/giờ | ~$65.70 |
| NAT data processing | ~$0.045/GB | theo lưu lượng |
| ALB | ~$0.0225/giờ + LCU | ~$16.50+ |
| IGW × 2 | miễn phí | $0 |
| **Cộng cố định (3 spoke)** | | **~$265/tháng** |
| Network Firewall (nếu bật, 2 AZ) | ~$0.395/giờ/AZ | **+~$576** |

Lưu ý về data: traffic từ spoke ra Internet bị tính **ba lần** — TGW processing + NAT processing + data transfer out. 1 TB/tháng ra Internet tốn khoảng $20 (TGW) + $45 (NAT) + phí transfer.

Cách giảm chi phí hiệu quả nhất, theo thứ tự:

1. **S3 + DynamoDB gateway endpoint ở mọi VPC** — miễn phí, cắt phần lớn lưu lượng NAT.
2. **Interface endpoint cho ECR** nếu kéo container image — image layer là nguồn tiêu thụ NAT lớn nhất ở đa số môi trường.
3. **Bỏ Network Firewall**, thay bằng DNS Firewall + endpoint policy, trừ khi tuân thủ bắt buộc.
4. Xem lại số spoke attachment — VPC ít dùng thì gộp lại.

---

## 12. Kiểm tra

```bash
# === Từ EC2 trong spoke VPC ===

# 1. Ra được Internet (qua egress VPC)
curl -s https://checkip.amazonaws.com
# Kỳ vọng: trả về EIP của NAT Gateway trong egress VPC

# 2. Xác nhận IP đó đúng là NAT của mình
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=vpc-egress-xxx" \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp' --profile network

# 3. Route mặc định phải trỏ TGW, không phải IGW/NAT
aws ec2 describe-route-tables --route-table-id rtb-xxx \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'
# Kỳ vọng: TransitGatewayId, KHÔNG có GatewayId=igw-*

# 4. Spoke KHÔNG có IGW
aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=vpc-spoke-xxx"
# Kỳ vọng: rỗng

# 5. Spoke không thấy spoke khác (nếu đã tách route table)
ping 10.30.1.10   # từ app-prod sang data VPC -> phải timeout

# === Test SCP ===

# 6. Tạo IGW phải bị chặn
aws ec2 create-internet-gateway --profile app-prod
# An error occurred (UnauthorizedOperation) ... explicit deny in a service control policy

# 7. Cấp EIP phải bị chặn
aws ec2 allocate-address --domain vpc --profile app-prod

# === Từ Internet ===

# 8. Gọi vào ALB
curl -sI https://api.acme.com/healthz

# 9. Health check của target group phải healthy
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" --profile network \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table

# === Kiểm tra tổng thể ===

# 10. Đường đi thực tế giữa hai điểm
aws ec2 create-network-insights-path \
  --source i-spoke-instance --destination 8.8.8.8 \
  --protocol tcp --destination-port 443 --profile app-prod
# rồi start-network-insights-analysis để xem từng hop
```

Lệnh 10 (**Reachability Analyzer**) là công cụ tốt nhất để debug routing trong mô hình này — nó chỉ ra chính xác gói tin bị chặn ở hop nào, thay vì phải đoán qua timeout.

---

## 13. Bẫy hay gặp

| Triệu chứng | Nguyên nhân |
|---|---|
| Spoke ra Internet timeout | Thiếu route `spoke_supernet → TGW` trong **public subnet RT** của egress VPC (đường về) |
| Egress chạy nhưng phí cross-AZ cao | TGW subnet trỏ về NAT khác AZ |
| ALB target luôn unhealthy | SG phía spoke chưa mở cho CIDR ingress VPC; SG reference không hoạt động xuyên VPC |
| Đăng ký IP target bị lỗi | Thiếu `availability_zone = "all"` |
| Firewall stateful drop ngẫu nhiên | Chưa bật `appliance_mode_support` |
| Terraform apply fail sau khi bật SCP | Code còn tạo NAT/IGW ở spoke — dọn trước khi attach SCP |
| Spoke vẫn nói chuyện được với nhau | Vẫn dùng TGW default route table thay vì `rtb-spokes` |
| Hoá đơn NAT tăng vọt | Thiếu VPC endpoint cho S3/ECR |
| Egress VPC là điểm chết đơn lẻ | Chỉ có NAT ở một AZ |
| Lambda vẫn ra thẳng Internet | Lambda không đặt trong VPC — SCP không chạm tới |

Bẫy đầu bảng chiếm phần lớn số ca gỡ rối trong mô hình này. Khi egress không chạy, kiểm tra **đường về** trước khi kiểm tra đường đi.

---

## 14. Code demo chạy được

Hai bộ Terraform dựng lên xem rồi xoá, không đụng tới Organizations:

| Demo | Dùng khi | Chi phí |
|---|---|---|
| [`demo/centralized-network`](../demo/centralized-network/) | Học routing, một account, nhiều VPC | ~$0.21/giờ |
| [`demo/centralized-network-multiaccount`](../demo/centralized-network-multiaccount/) | Ba account có sẵn, RAM share TGW, PHZ cross-account | ~$0.22/giờ |

Cả hai **không tạo AWS account mới** — account không xoá được, chỉ đóng được, và email không tái sử dụng được. Bản multi-account dùng account đã có; `terraform destroy` chỉ xoá resource, account giữ nguyên để dùng lại.

Buổi thực hành 4 tiếng khoảng $1. Quên xoá một tháng khoảng $150 — mỗi README có phần kiểm tra sau khi destroy để không sót EIP.

Ba thứ demo cố tình **không** làm, vì chúng cản trở việc `destroy`: SCP chặn IGW/NAT, deletion protection, và NAT nhiều AZ.

---

## 15. Lộ trình triển khai

```text
Giai đoạn 1 – Dựng hạ tầng (chưa khoá gì)
  ✔ TGW + 3 route table (spokes/egress/ingress)
  ✔ Egress VPC: IGW + NAT × 2 AZ + attachment
  ✔ Ingress VPC: IGW + ALB + WAF + attachment
  ✔ VPC endpoint cho S3/DynamoDB ở mọi VPC (doc 12)

Giai đoạn 2 – Đấu nối và kiểm chứng
  ✔ Attach spoke vào TGW
  ✔ Đổi default route của spoke sang TGW
  ✔ Test bằng Reachability Analyzer, curl checkip
  ✔ Chuyển dịch vụ public sang ALB ở ingress VPC

Giai đoạn 3 – Dọn dẹp
  ✔ Xoá NAT Gateway cũ ở từng spoke (tiết kiệm rõ rệt)
  ✔ Xoá IGW cũ ở từng spoke
  ✔ Xoá public subnet không còn dùng

Giai đoạn 4 – Khoá
  ✔ SCP vào OU Sandbox (1 tuần)
  ✔ SCP vào OU NonProd (2 tuần)
  ✔ SCP vào OU Prod
  ✔ Bật Config rule phát hiện

Giai đoạn 5 – Nâng cao (tuỳ nhu cầu tuân thủ)
  ✔ VPC Flow Logs tập trung về log-archive
  ✔ Route 53 DNS Firewall
  ○ Network Firewall (chỉ khi bắt buộc – xem chi phí mục 11)
```

Giai đoạn 3 là chỗ **thu hồi vốn**: mỗi NAT Gateway xoá đi tiết kiệm ~$33/tháng cộng phí data. Ba spoke mỗi cái 2 NAT là ~$200/tháng — gần đủ bù chi phí cố định của cả mô hình tập trung.

Đừng bỏ qua thứ tự này. Attach SCP trước khi dọn NAT cũ sẽ làm Terraform của các team fail giữa chừng, và bạn sẽ mất nhiều tuần lấy lại niềm tin của họ.
