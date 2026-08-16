# Kết nối đối tác – 3rd-party VPC và Site-to-Site VPN

Ví dụ 16: Cho đối tác bên ngoài kết nối vào hệ thống mà không đưa họ vào mạng nội bộ, dùng một **3rd-party VPC** riêng và VPN.

Tiếp nối [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) và [15 – Security VPC](./15-Security-VPC-Network-Firewall.md).

---

## 1. Nguyên tắc: đối tác không bao giờ chạm vào spoke

Sai lầm phổ biến nhất là dựng VPN thẳng từ đối tác vào TGW rồi mở route tới VPC ứng dụng. Làm vậy nghĩa là:

- Đối tác nằm **trong** mạng của bạn, chỉ bị giới hạn bằng route và security group.
- Sự cố ở phía đối tác lan thẳng sang bạn.
- Một dòng route sai là đối tác thấy toàn bộ `10.0.0.0/8`.

Mô hình đúng: **3rd-party VPC** làm vùng đệm. Đối tác chỉ vào được tới đó, không xa hơn.

```text
Đối tác A ──VPN──┐
Đối tác B ──VPN──┼──► 3rd-party VPC ──► Security VPC ──► Spoke
Đối tác C ──VPN──┘     (vùng đệm)        (firewall)      (ứng dụng)
                            │
                     Không có route
                     trực tiếp nào
                     tới spoke
```

Ba lớp kiểm soát chồng lên nhau:

| Lớp | Kiểm soát gì |
|---|---|
| **VPN + BGP/route tĩnh** | Đối tác chỉ học được CIDR của 3rd-party VPC |
| **TGW route table** | 3rd-party VPC chỉ đi được tới security VPC |
| **Network Firewall** | Từng cặp IP/port cụ thể mới được qua |

---

## 2. Ba cách cho đối tác truy cập, chọn cái nào

Trước khi dựng VPN, cân nhắc: **có thể tránh nối mạng hoàn toàn không?**

| Cách | Cơ chế | Ưu | Khi nào dùng |
|---|---|---|---|
| **A. PrivateLink** | Endpoint service, đối tác tạo endpoint trong VPC của họ | Không nối mạng, **không lo trùng CIDR**, cách ly tốt nhất | Đối tác **gọi vào** một service cụ thể |
| **B. API công khai** | Qua chuỗi ingress (doc 14), xác thực bằng mTLS/OAuth | Đơn giản nhất, không hạ tầng riêng | Đối tác gọi API HTTP |
| **C. Site-to-Site VPN** | Nối mạng L3 qua IPsec | Đối tác dùng được giao thức bất kỳ | Đối tác **cần nhiều giao thức**, hoặc **họ** phải nhận kết nối từ bạn |

Thứ tự ưu tiên: **A > B > C**. VPN là cách tốn công và rủi ro nhất, chỉ dùng khi hai cách trên không đáp ứng được.

### 2.1. PrivateLink – nên xem xét trước tiên

Nếu đối tác chỉ cần gọi một API/service của bạn:

```hcl
# Ben BAN: dua service ra qua NLB + endpoint service
resource "aws_vpc_endpoint_service" "partner_api" {
  provider = aws.partner_vpc

  acceptance_required        = true    # duyet tung endpoint mot
  network_load_balancer_arns = [aws_lb.partner_api.arn]

  # CHI account cua doi tac duoc phep tao endpoint
  allowed_principals = [
    "arn:aws:iam::${var.partner_a_account_id}:root",
  ]

  supported_ip_address_types = ["ipv4"]

  tags = { Name = "${var.project}-partner-api" }
}

output "partner_service_name" {
  description = "Gui chuoi nay cho doi tac de ho tao interface endpoint"
  value       = aws_vpc_endpoint_service.partner_api.service_name
}
```

Ưu điểm quyết định: **không có định tuyến nào giữa hai mạng**. CIDR trùng nhau cũng không sao, đối tác không thấy gì ngoài đúng NLB bạn đưa ra, và thu hồi quyền chỉ là bỏ `allowed_principals`.

Nhược điểm: chỉ chạy được khi đối tác **cũng ở trên AWS** và chỉ theo một chiều (họ gọi bạn).

Phần còn lại của bài dành cho trường hợp buộc phải dùng VPN.

---

## 3. Kiến trúc 3rd-party VPC

```text
        ĐỐI TÁC A                    ĐỐI TÁC B
     (on-prem/DC riêng)            (cloud khác)
      203.0.113.10                  198.51.100.20
            │                             │
            │  IPsec VPN                  │  IPsec VPN
            │  (2 tunnel)                 │  (2 tunnel)
            ▼                             ▼
┌───────────────────────────────────────────────────────────┐
│  3RD-PARTY VPC  10.9.0.0/16   (network account)           │
│                                                            │
│  subnet: vpn 10.9.0.0/24                                   │
│   ┌─────────────────────────────────────────────────┐     │
│   │ Virtual Private Gateway HOẶC TGW VPN attachment │     │
│   └───────────────────┬─────────────────────────────┘     │
│                       │                                    │
│  subnet: nat 10.9.10.0/24    (khi CIDR trùng nhau)        │
│   ┌───────────────────▼─────────────────────────────┐     │
│   │ Private NAT Gateway                             │     │
│   │ 10.9.10.0/24 ← dải NAT phía bạn                 │     │
│   └───────────────────┬─────────────────────────────┘     │
│                       │                                    │
│  subnet: tgw 10.9.20.0/28                                  │
│   ┌───────────────────▼─────────────────────────────┐     │
│   │ TGW attachment                                   │     │
│   └───────────────────┬─────────────────────────────┘     │
└───────────────────────┼────────────────────────────────────┘
                        │
                 TRANSIT GATEWAY
                 rtb-partner: chỉ → security
                        │
                        ▼
             SECURITY VPC (Network Firewall)
                        │
                        ▼
                     SPOKE
```

Đặt 3rd-party VPC ở đâu:

| Lựa chọn | Khi nào |
|---|---|
| Trong network account | Ít đối tác, cùng một đội quản |
| **Account riêng** `partner-connectivity` | Nhiều đối tác, cần tách quyền và hoá đơn |
| Một VPC cho mỗi đối tác | Đối tác nhạy cảm, hoặc CIDR trùng nhau nhiều |

Với môi trường enterprise, khuyến nghị **account riêng** trong OU `Infrastructure`. Đội network quản đường ống, đội security quản policy firewall, và log của từng đối tác tách bạch.

---

## 4. VPN vào đâu: TGW hay 3rd-party VPC?

Hai cách kết cuối VPN, khác nhau đáng kể về mức cách ly:

| | VPN → TGW attachment | VPN → VGW của 3rd-party VPC |
|---|---|---|
| Cách ly | Traffic đối tác vào thẳng TGW | Traffic **bị giữ trong VPC** trước |
| Định tuyến | TGW route table quyết định | VPC route table + TGW route table |
| Trùng CIDR | Khó xử lý | Dễ — NAT ngay trong VPC |
| Số VPN tối đa | Cao | Giới hạn theo VGW |
| Độ phức tạp | Thấp hơn | Cao hơn một chút |
| **Khuyến nghị** | Đối tác tin cậy, CIDR không trùng | **Mặc định cho enterprise** |

Bài này dùng **VGW trong 3rd-party VPC**, vì nó cho phép xử lý CIDR trùng và giữ traffic đối tác trong một ranh giới rõ ràng trước khi cho vào TGW.

---

## 5. Terraform – Site-to-Site VPN

```hcl
# 7-partner/vpn.tf

variable "partners" {
  description = "Danh sach doi tac"
  type = map(object({
    customer_gateway_ip = string       # IP public thiet bi VPN cua ho
    bgp_asn             = number       # ASN cua ho (65000-65534 cho private)
    remote_cidrs        = list(string) # Dai mang ho cong bo
    local_cidrs         = list(string) # Dai mang BAN cong bo cho ho
    use_bgp             = bool
  }))

  default = {
    "partner-a" = {
      customer_gateway_ip = "203.0.113.10"
      bgp_asn             = 65010
      remote_cidrs        = ["172.16.0.0/16"]
      local_cidrs         = ["10.9.10.0/24"] # CHI dai NAT, khong lo spoke
      use_bgp             = true
    }
    "partner-b" = {
      customer_gateway_ip = "198.51.100.20"
      bgp_asn             = 65020
      remote_cidrs        = ["192.168.50.0/24"]
      local_cidrs         = ["10.9.10.0/24"]
      use_bgp             = false
    }
  }
}

resource "aws_vpc" "partner" {
  provider             = aws.partner
  cidr_block           = "10.9.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-3rd-party-vpc" }
}

########################
# Virtual Private Gateway
########################

resource "aws_vpn_gateway" "partner" {
  provider = aws.partner
  vpc_id   = aws_vpc.partner.id

  # ASN phia AWS - phai KHAC ASN cua moi doi tac
  amazon_side_asn = 64512

  tags = { Name = "${var.project}-vgw" }
}

########################
# Customer Gateway - thiet bi phia doi tac
########################

resource "aws_customer_gateway" "partner" {
  provider = aws.partner
  for_each = var.partners

  bgp_asn    = each.value.bgp_asn
  ip_address = each.value.customer_gateway_ip
  type       = "ipsec.1"

  tags = { Name = "${var.project}-cgw-${each.key}" }
}

########################
# VPN Connection - moi ket noi co 2 tunnel o 2 AZ khac nhau
########################

resource "aws_vpn_connection" "partner" {
  provider = aws.partner
  for_each = var.partners

  vpn_gateway_id      = aws_vpn_gateway.partner.id
  customer_gateway_id = aws_customer_gateway.partner[each.key].id
  type                = "ipsec.1"

  static_routes_only = !each.value.use_bgp

  # Thuat toan - THONG NHAT voi doi tac TRUOC khi apply.
  # Khong khop la tunnel khong len, va thong bao loi rat kho doc.
  tunnel1_phase1_dh_group_numbers      = [14, 15, 16]
  tunnel1_phase2_dh_group_numbers      = [14, 15, 16]
  tunnel1_phase1_encryption_algorithms = ["AES256", "AES256-GCM-16"]
  tunnel1_phase2_encryption_algorithms = ["AES256", "AES256-GCM-16"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256", "SHA2-384", "SHA2-512"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256", "SHA2-384", "SHA2-512"]

  tunnel2_phase1_dh_group_numbers      = [14, 15, 16]
  tunnel2_phase2_dh_group_numbers      = [14, 15, 16]
  tunnel2_phase1_encryption_algorithms = ["AES256", "AES256-GCM-16"]
  tunnel2_phase2_encryption_algorithms = ["AES256", "AES256-GCM-16"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256", "SHA2-384", "SHA2-512"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256", "SHA2-384", "SHA2-512"]

  # Ghi log tunnel de debug - rat dang gia
  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn[each.key].arn
      log_output_format = "json"
    }
  }

  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn[each.key].arn
      log_output_format = "json"
    }
  }

  tags = { Name = "${var.project}-vpn-${each.key}" }
}

resource "aws_cloudwatch_log_group" "vpn" {
  provider          = aws.partner
  for_each          = var.partners
  name              = "/aws/vpn/${var.project}-${each.key}"
  retention_in_days = 90
}

# Route tinh khi doi tac khong dung BGP
resource "aws_vpn_connection_route" "partner_static" {
  provider = aws.partner
  for_each = {
    for pair in flatten([
      for pk, p in var.partners : [
        for cidr in p.remote_cidrs : {
          key         = "${pk}-${cidr}"
          partner     = pk
          destination = cidr
        } if !p.use_bgp
      ]
    ]) : pair.key => pair
  }

  vpn_connection_id      = aws_vpn_connection.partner[each.value.partner].id
  destination_cidr_block = each.value.destination
}

########################
# Chi cho VGW propagate vao route table cua subnet VPN
########################

resource "aws_vpn_gateway_route_propagation" "vpn_subnet" {
  provider       = aws.partner
  vpn_gateway_id = aws_vpn_gateway.partner.id
  route_table_id = aws_route_table.partner_vpn.id
}
```

**Đừng propagate VGW vào mọi route table.** Nếu route của đối tác lan vào route table của subnet TGW, traffic có thể đi thẳng ra đối tác mà không qua firewall.

### 5.1. Pre-shared key

Không đặt PSK trong Terraform. Để AWS sinh, rồi lấy ra một lần và chuyển cho đối tác qua kênh an toàn:

```bash
# Lay cau hinh cho thiet bi cua doi tac (co chua PSK)
aws ec2 describe-vpn-connections \
  --vpn-connection-ids vpn-xxxxx \
  --query 'VpnConnections[0].CustomerGatewayConfiguration' \
  --output text > partner-a-config.xml

# Chuyen qua kenh an toan, KHONG gui qua email/chat
# Xoa file ngay sau khi chuyen xong
shred -u partner-a-config.xml
```

Nếu bắt buộc phải đặt PSK cụ thể (thiết bị đối tác yêu cầu), lấy từ Secrets Manager, đừng để trong `.tfvars`:

```hcl
data "aws_secretsmanager_secret_version" "psk" {
  secret_id = "partner-vpn-psk"
}

# tunnel1_preshared_key = jsondecode(data.aws_secretsmanager_secret_version.psk.secret_string)["partner-a-t1"]
```

---

## 6. CIDR trùng nhau – bài toán gần như chắc chắn gặp

Đối tác dùng `172.16.0.0/16`, bạn cũng dùng `172.16.0.0/16`. Không định tuyến được. Chuyện này xảy ra thường xuyên vì ai cũng chọn dải RFC 1918 phổ biến.

**Private NAT Gateway** giải quyết cả hai chiều:

```hcl
# Private NAT: dich dai mang cua BAN thanh dai trung gian
resource "aws_nat_gateway" "partner_private" {
  provider          = aws.partner
  connectivity_type = "private" # KHONG can EIP, khong ra Internet
  subnet_id         = aws_subnet.partner_nat.id

  tags = { Name = "${var.project}-partner-nat" }
}
```

Cách hoạt động:

```text
BAN gọi đối tác:
  spoke 10.20.1.5 → security VPC → 3rd-party VPC
  → private NAT dịch nguồn thành 10.9.10.x
  → qua VPN → đối tác thấy nguồn là 10.9.10.x (không trùng dải của họ)

ĐỐI TÁC gọi bạn:
  họ gọi 10.9.100.50 (địa chỉ ảo bạn công bố cho họ)
  → qua VPN vào 3rd-party VPC
  → NLB/firewall dịch tiếp tới 10.20.1.5 thật
```

Thoả thuận CIDR với đối tác — đưa vào **hợp đồng kỹ thuật**, không chỉ nói miệng:

| Hạng mục | Giá trị | Ghi chú |
|---|---|---|
| Dải bạn công bố cho đối tác | `10.9.10.0/24` | Chỉ dải NAT, **không bao giờ** công bố `10.0.0.0/8` |
| Dải đối tác công bố cho bạn | `172.16.0.0/16` | Yêu cầu họ thu hẹp nhất có thể |
| Địa chỉ dịch vụ đối tác gọi | `10.9.100.0/24` | Dải ảo, NLB đứng ở đây |
| Port được phép | 443 | Ghi rõ từng port |

Dòng đầu quan trọng nhất: **chỉ công bố dải NAT**. Đối tác không cần biết, và không nên biết, `10.20.0.0/16` của bạn tồn tại.

---

## 7. TGW route table – cách ly đối tác

Thêm một route table thứ năm vào thiết kế của [doc 15](./15-Security-VPC-Network-Firewall.md):

| Route table | Associate | Propagate | Route tĩnh |
|---|---|---|---|
| `rtb-spokes` | Mọi spoke | — | `0.0.0.0/0` → security |
| `rtb-security` | security | Mọi spoke **+ partner** | `0.0.0.0/0` → egress |
| `rtb-egress` | egress | — | `spoke_supernet` → security |
| `rtb-ingress` | ingress | — | `spoke_supernet` → security |
| **`rtb-partner`** | **3rd-party VPC** | **— (không propagate gì)** | **`0.0.0.0/0` → security** |

```hcl
resource "aws_ec2_transit_gateway_route_table" "partner" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.project}-rtb-partner" }
}

resource "aws_ec2_transit_gateway_route_table_association" "partner" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.partner.id
}

# 3rd-party VPC CHI di duoc toi security VPC. Khong co duong nao khac.
resource "aws_ec2_transit_gateway_route" "partner_to_security" {
  provider = aws.network

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.security.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.partner.id
}

# Security VPC hoc duong ve 3rd-party VPC de tra loi
resource "aws_ec2_transit_gateway_route_table_propagation" "partner_to_security" {
  provider = aws.network

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}

# Spoke muon goi doi tac: them route TINH cho dung dai NAT.
# KHONG propagate - de kiem soat chinh xac dai nao di duoc.
resource "aws_ec2_transit_gateway_route" "security_to_partner" {
  provider = aws.network

  destination_cidr_block         = "10.9.0.0/16"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.partner.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security.id
}
```

`rtb-partner` **không propagate gì cả** — đây là điểm cốt lõi. Đối tác không học được đường tới bất kỳ spoke nào. Mọi gói tin của họ chỉ có một hướng đi: vào security VPC, nơi firewall quyết định.

---

## 8. Rule firewall cho đối tác

Bổ sung vào [doc 15 mục 7](./15-Security-VPC-Network-Firewall.md):

```hcl
resource "aws_networkfirewall_rule_group" "partner" {
  provider = aws.network
  capacity = 200
  name     = "${var.project}-partner"
  type     = "STATEFUL"

  rule_group {
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }

    rules_source {
      rules_string = <<-EOT
        # ===== Doi tac A GOI VAO =====
        # Chi toi dung NLB, dung port. Khong gi khac.
        pass tcp 172.16.0.0/16 any -> 10.9.100.50 443 (msg:"partner-a to api"; sid:3001; rev:1;)

        # ===== BAN goi doi tac A =====
        # Nguon la dai NAT, khong phai IP that cua spoke
        pass tcp 10.9.10.0/24 any -> 172.16.5.10 443 (msg:"to partner-a api"; sid:3002; rev:1;)

        # ===== Doi tac B =====
        pass tcp 192.168.50.0/24 any -> 10.9.100.51 8443 (msg:"partner-b to service"; sid:3010; rev:1;)

        # ===== CHAN tuong minh =====
        # Doi tac khong duoc cham vao bat ky dai noi bo nao
        drop ip 172.16.0.0/16    any -> 10.10.0.0/16 any (msg:"BLOCK partner-a to app-dev"; sid:3900; rev:1;)
        drop ip 172.16.0.0/16    any -> 10.20.0.0/16 any (msg:"BLOCK partner-a to app-prod"; sid:3901; rev:1;)
        drop ip 172.16.0.0/16    any -> 10.30.0.0/16 any (msg:"BLOCK partner-a to data-prod"; sid:3902; rev:1;)
        drop ip 192.168.50.0/24  any -> 10.0.0.0/8   any (msg:"BLOCK partner-b to internal"; sid:3910; rev:1;)

        # Doi tac khong duoc noi chuyen voi nhau
        drop ip 172.16.0.0/16 any -> 192.168.50.0/24 any (msg:"BLOCK partner-a to partner-b"; sid:3920; rev:1;)
        drop ip 192.168.50.0/24 any -> 172.16.0.0/16 any (msg:"BLOCK partner-b to partner-a"; sid:3921; rev:1;)

        # Ghi log moi thu con lai tu doi tac
        alert ip 172.16.0.0/16   any -> any any (msg:"UNMATCHED partner-a"; sid:3990; rev:1;)
        alert ip 192.168.50.0/24 any -> any any (msg:"UNMATCHED partner-b"; sid:3991; rev:1;)
      EOT
    }
  }
}
```

Rule `drop` tường minh ở `sid:39xx` là **thừa về mặt logic** — `rtb-partner` đã không có đường tới spoke, và default action đã là drop. Nhưng giữ chúng lại vì hai lý do: chúng ghi log rõ ràng khi có ai đó thử, và chúng vẫn bảo vệ nếu sau này ai đó sửa nhầm TGW route table. Phòng thủ nhiều lớp có giá trị đúng ở chỗ này.

Rule `sid:399x` là hệ thống cảnh báo sớm: đối tác dò quét mạng của bạn sẽ hiện lên ngay trong alert log.

---

## 9. Giám sát

VPN đối tác là thứ **sẽ** đứt, và thường đứt vào lúc bất tiện.

```hcl
resource "aws_cloudwatch_metric_alarm" "vpn_tunnel_down" {
  provider = aws.partner
  for_each = var.partners

  alarm_name          = "${var.project}-vpn-${each.key}-tunnel-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1

  dimensions = {
    VpnId = aws_vpn_connection.partner[each.key].id
  }

  alarm_description = "Tunnel VPN toi ${each.key} down"
  alarm_actions     = [var.network_alerts_topic_arn]
  ok_actions        = [var.network_alerts_topic_arn]

  treat_missing_data = "breaching"
}

# Canh bao khi CA HAI tunnel cung down - su co nghiem trong
resource "aws_cloudwatch_metric_alarm" "vpn_both_tunnels_down" {
  provider = aws.partner
  for_each = var.partners

  alarm_name          = "${var.project}-vpn-${each.key}-CRITICAL"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Sum"
  threshold           = 1

  dimensions = {
    VpnId = aws_vpn_connection.partner[each.key].id
  }

  alarm_description = "CA HAI tunnel toi ${each.key} down - mat ket noi hoan toan"
  alarm_actions     = [var.network_critical_topic_arn]
}
```

`TunnelState` bằng 1 khi UP, 0 khi DOWN. Alarm đầu bắt "một tunnel down" (còn dự phòng, xử lý trong giờ hành chính); alarm thứ hai bắt "mất hẳn kết nối" (gọi on-call ngay).

Nhớ `treat_missing_data = "breaching"` — VPN chưa từng lên thì không có metric, và im lặng ở đây không có nghĩa là ổn.

---

## 10. Vận hành – phần con người

Kết nối đối tác khác các phần khác của LZ ở chỗ **có một tổ chức khác cùng tham gia**. Phần lớn sự cố đến từ phối hợp, không phải kỹ thuật.

### 10.1. Hồ sơ mỗi đối tác

Mỗi kết nối cần một tài liệu, để trong Git cạnh Terraform:

```yaml
# partners/partner-a.yaml
partner:
  name: "Công ty A"
  business_owner: "nguyenvb@acme.com"
  technical_contact: "noc@partner-a.com"
  escalation_phone: "+84..."
  contract_expiry: "2027-06-30"

connectivity:
  type: "site-to-site-vpn"
  customer_gateway_ip: "203.0.113.10"
  bgp_asn: 65010

cidr:
  they_advertise: ["172.16.0.0/16"]
  we_advertise: ["10.9.10.0/24"]
  service_addresses: ["10.9.100.50"]

allowed_flows:
  - direction: "inbound"
    source: "172.16.0.0/16"
    destination: "10.9.100.50"
    port: 443
    purpose: "Doi tac goi API don hang"
    approved_by: "security-team"
    review_date: "2027-01-15"

  - direction: "outbound"
    source: "10.9.10.0/24"
    destination: "172.16.5.10"
    port: 443
    purpose: "Truy van ton kho"
    approved_by: "security-team"
    review_date: "2027-01-15"
```

Trường `review_date` là thứ hay bị bỏ qua nhất: kết nối đối tác có xu hướng **sống lâu hơn lý do tạo ra nó**. Rà soát định kỳ, và đóng những kết nối không còn ai dùng.

### 10.2. Danh sách kiểm tra khi thêm đối tác mới

```text
TRUOC khi cau hinh
  □ Da ky thoa thuan ky thuat (CIDR, port, muc dich)
  □ Da co dau moi ky thuat va duong escalation cua ho
  □ Da thong nhat thuat toan IPsec (phase 1/2)
  □ Da xac nhan dai CIDR ho cong bo KHONG trung dai noi bo cua ban
  □ Da quyet dinh: PrivateLink duoc khong? (uu tien hon VPN)

Cau hinh
  □ Customer gateway + VPN connection
  □ Chuyen PSK qua kenh an toan (KHONG email/chat)
  □ Route: chi cong bo dai NAT, khong bao gio cong bo 10.0.0.0/8
  □ rtb-partner: khong propagate gi
  □ Rule firewall: pass tuong minh + drop tuong minh + alert
  □ Alarm tunnel

Kiem thu
  □ Tunnel len ca hai
  □ Luong duoc phep: thong
  □ Luong KHONG duoc phep: bi chan (test that, dung gia dinh)
  □ Doi tac KHONG ping duoc bat ky IP spoke nao
  □ Failover: tat tunnel 1, luu luong chuyen sang tunnel 2

Ban giao
  □ Ho so partners/<ten>.yaml da commit
  □ Runbook xu ly su co
  □ Dat review_date
```

Dòng "test thật, đừng giả định" đáng nhấn mạnh: rất nhiều tổ chức chỉ kiểm tra luồng **được phép** chạy tốt, mà không bao giờ kiểm tra luồng **bị cấm** thật sự bị chặn.

---

## 11. Chi phí

| Thành phần | Đơn giá | Tháng |
|---|---|---|
| VPN connection | ~$0.05/giờ mỗi kết nối | ~$36.50/đối tác |
| VPN data transfer out | Theo giá data transfer thường | Theo lưu lượng |
| TGW attachment (3rd-party VPC) | ~$0.05/giờ | ~$36.50 |
| Private NAT Gateway | ~$0.045/giờ + $0.045/GB | ~$33 + traffic |
| Firewall data (đã có ở doc 15) | ~$0.065/GB | Theo lưu lượng |
| **Ba đối tác** | | **~$180/tháng** + traffic |

So sánh: **PrivateLink** cho một service khoảng $7.30/tháng mỗi AZ cộng $0.01/GB — rẻ hơn nhiều và cách ly tốt hơn. Đây là lý do thực tế, ngoài lý do bảo mật, để ưu tiên PrivateLink khi có thể.

---

## 12. Bẫy hay gặp

| Triệu chứng | Nguyên nhân |
|---|---|
| Tunnel không lên | Thuật toán phase 1/2 không khớp; đọc CloudWatch log của tunnel |
| Tunnel lên nhưng không có traffic | Thiếu route, hoặc SA proposal không khớp dải mạng |
| Đối tác ping được vào spoke | `rtb-partner` bị propagate; hoặc VGW propagate vào nhầm route table |
| Traffic đối tác không qua firewall | `rtb-partner` có route trực tiếp thay vì chỉ trỏ security |
| Route đè lên nhau, mất kết nối nội bộ | Đối tác công bố dải trùng với dải của bạn qua BGP |
| Tunnel đứt định kỳ ~mỗi giờ | Thiết bị đối tác cấu hình rekey khác AWS; thống nhất lại lifetime |
| Chỉ một tunnel hoạt động | Bình thường — AWS chỉ active một tunnel tại một thời điểm |
| Đối tác thấy IP thật của spoke | Thiếu private NAT, hoặc rule NAT chưa đúng chiều |
| Không ai biết kết nối này còn dùng không | Thiếu hồ sơ và `review_date` |
| Đối tác A gọi được đối tác B | Thiếu rule drop chéo giữa các đối tác |

---

## 13. Lộ trình

```text
Giai doan 1 - Danh gia
  □ Liet ke tung doi tac va nhu cau thuc su
  □ Voi tung cai: PrivateLink duoc khong? API cong khai duoc khong?
  □ Chi nhung cai con lai moi dung VPN

Giai doan 2 - Ha tang
  □ Account partner-connectivity trong OU Infrastructure
  □ 3rd-party VPC + TGW attachment
  □ rtb-partner (khong propagate gi)
  □ Rule firewall: alert-only truoc

Giai doan 3 - Doi tac dau tien (chon cai it quan trong nhat)
  □ VPN + kiem thu day du, ca luong bi cam
  □ Sống với alert-only 1-2 tuan
  □ Chuyen sang drop

Giai doan 4 - Mo rong
  □ Tung doi tac mot, khong lam hang loat
  □ Moi cai deu qua danh sach kiem tra muc 10.2

Giai doan 5 - Van hanh
  □ Ra soat dinh ky theo review_date
  □ Dong ket noi khong con dung
  □ Dien tap su co dut VPN
```

Nguyên tắc xuyên suốt: **đối tác đầu tiên nên là đối tác ít quan trọng nhất**. Bạn sẽ mắc lỗi ở lần đầu, và tốt hơn hết là mắc lỗi ở nơi ít gây thiệt hại.
