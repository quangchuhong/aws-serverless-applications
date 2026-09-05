# Kết nối đối tác – 3rd-party VPC và Site-to-Site VPN

Ví dụ 16: Cho đối tác bên ngoài kết nối vào hệ thống mà không đưa họ vào mạng nội bộ, dùng một **3rd-party VPC** riêng và VPN.

> Tài liệu chi tiết. Thiết kế tổng thể, quy hoạch CIDR chuẩn và bảng định tuyến Transit Gateway ở [17 – Network LZ Design Guide](./17-Network-LZ-Design-Guide.md).

Tiếp nối [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) và [15 – Security VPC](./15-Security-VPC-Network-Firewall.md).

---

## 0. Trạng thái

| | |
|---|---|
| **Code** | [`demo/network-lz-full/partner.tf`](../demo/network-lz-full/partner.tf) + `partner-sim.tf` — bật bằng `enable_partner_vpn = true` |
| **Vận hành** | Hồ sơ đối tác là catalog YAML ở lớp ops: [`ops/catalog/partners.yaml`](../demo/network-lz-full/ops/catalog/partners.yaml) |
| **Kiểm chứng** | `verify.sh` mục 10 — trạng thái đường hầm, `rtb-partner` không học địa chỉ spoke, đường về, sức khoẻ target |
| **Đã đo được cả tuyến** | Hai đường hầm `UP`, hai SA `ESTABLISHED`, và **`NLB tra ve 200`** từ máy đối tác giả lập: IPsec → VGW → NLB → TGW → firewall → `10.10.0.10` ở một **account khác**. Không phải suy ra từ trạng thái tài nguyên — là một gói tin HTTP đi hết đường và về |
| **Đo cả lớp vận hành** | Dịch vụ công bố qua catalog cũng đã đo: cổng 8080 do `partners.yaml` sinh ra trả `http=200` từ máy đối tác, qua listener → target group → `10.10.0.10:80` |
| **Đường tới đó** | Bảy lỗi, bảy vòng dựng lại máy giả lập. Nguyên nhân đầu tiên là **AL2023 không có gói `strongswan`** (lỗi 77) nên máy giả lập chạy Ubuntu; nguyên nhân cuối là route `vti` thiếu `src` (lỗi 78) — đường hầm lên, `curl` trả về `000`. Chi tiết ở **mục 5.3**, [doc 22 mục 7al và 7am](./22-Nhat-ky-Trien-khai-LZ-DIY.md) |
| **Chi phí** | +~$0.21/giờ: VPN $0.05, private NAT $0.045, NLB $0.045, TGW attachment $0.05, EC2 $0.012 |

Đối tác **giả lập**: một VPC riêng với EC2 chạy strongSwan làm customer gateway. Đường hầm lên thật, nên đo được cả tuyến. Cắm đối tác thật chỉ đổi `aws_customer_gateway.ip_address`.

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

## 4b. VPC không định tuyến bắc cầu — và hai điểm tái khởi tạo

Đây là ràng buộc quyết định toàn bộ hình dạng của thiết kế, và nó không hiện ra trong bất kỳ sơ đồ nào.

**Gói tin vào VPC qua VGW không thể đi tiếp ra TGW attachment của chính VPC đó.** AWS chặn thẳng — không có route table nào sửa được. Nên "đối tác → 3rd-party VPC → TGW → spoke" không phải một đường liền; nó đứt ở giữa.

Mỗi chiều cần một thứ **dừng luồng lại rồi phát lại**:

| Chiều | Điểm tái khởi tạo | Vì sao nó qua được |
|---|---|---|
| Đối tác → bạn | **NLB nội bộ** ở `10.9.100.0/24` | Đối tác gọi địa chỉ NLB, mà địa chỉ đó **nằm trong VPC** nên VGW giao được. NLB mở một kết nối **mới** tới spoke, và kết nối mới đi ra bằng TGW attachment bình thường |
| Bạn → đối tác | **Private NAT Gateway** ở `10.9.10.0/24` | Gói từ spoke vào VPC qua TGW attachment (chiều này không vướng), route trỏ vào NAT, NAT đổi nguồn rồi đẩy ra VGW |

Hai hệ quả đáng nhớ:

**Firewall không bao giờ thấy `172.16.x`.** Nguồn của lưu lượng đối tác, tính từ góc nhìn của firewall, là dải NLB. Rule khai từ dải thật của đối tác sẽ apply thành công và không khớp một gói tin nào — `ops/lint.sh` chặn trường hợp này.

**Mọi đối tác ra cùng một CIDR nguồn.** Firewall không phân biệt được Acme với Globex. Muốn phân biệt ở tầng đó thì mỗi đối tác một NLB riêng; hoặc chấp nhận rằng tầng phân biệt là VPN và route, còn firewall chỉ nói "từ vùng đệm".

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

### 5.2. Phần duy nhất không có gì kiểm được

Mọi thứ khác trong bộ này đều có lưới: `terraform validate` bắt cấu hình sai, `plan-check.sh` bắt hành vi sai, `verify.sh` đo bằng gói tin thật, phép quét `.tftpl` trong CI bắt nội suy sai.

Cấu hình IPsec nằm trong `user_data` thì **không có cái nào chạm tới**. Nó là một chuỗi ký tự cho tới khi máy boot. Terraform không biết `ipsec.conf` là gì, và AWS chỉ trả lời được một câu duy nhất: đường hầm lên hay không.

Nên khi phần này hỏng, hãy dự tính là phải vào máy đọc log — đó là thiết kế, không phải sự cố.

### 5.2b. Trạng thái khi đã chạy đúng

```
Security Associations (2 up, 0 connecting):
  Tunnel1[1]: ESTABLISHED, 172.16.0.79[47.130.178.166]...13.215.221.92[13.215.221.92]
  Tunnel1{1}:  INSTALLED, TUNNEL, reqid 1, ESP in UDP SPIs: c666a30e_i c094a554_o
  Tunnel2[2]: ESTABLISHED, 172.16.0.79[47.130.178.166]...52.77.185.28[52.77.185.28]
```

Ba chi tiết đáng đọc kỹ, vì mỗi cái xác nhận một quyết định thiết kế:

| Trong output | Xác nhận điều gì |
|---|---|
| `172.16.0.79[47.130.178.166]` | Interface mang IP **riêng**, danh tính IKE là **EIP**. Đó là lý do `leftid` phải khai EIP — khai IP interface thì IKE hỏng ở bước xác thực danh tính với thông báo `no matching peer config`, đúng nhưng không chỉ vào địa chỉ |
| `ESP in UDP` | NAT-T đang hoạt động. Có NAT giữa EC2 và Internet nên ESP thô không qua được; nếu chỗ này ghi `ESP` trần thì security group thiếu UDP 4500 |
| `0.0.0.0/0 === 0.0.0.0/0` | Traffic selector mở hoàn toàn — **đúng thiết kế**. Việc chọn dải nào đi đường hầm nào là của route gắn vào `vti`, không phải của traffic selector. Đây là điểm khác nhau giữa route-based và policy-based, và ghép nhầm hai kiểu cho ra lỗi tệ nhất: SA có mà không gói tin nào qua |

Trên Ubuntu, unit là **`strongswan-starter`**, không phải `strongswan` — vòng dò tên unit ở mục 4c của script tồn tại vì lý do này.

Và bảng route — đọc kỹ hai chi tiết:

```
10.9.100.0/23 dev vti1 scope link src 172.16.0.136 metric 100
10.9.100.0/23 dev vti2 scope link src 172.16.0.136 metric 200

=== Dia chi nguon di ra duong ham ===
10.9.100.1 dev vti1 src 172.16.0.136 uid 0
```

| Chi tiết | Vì sao quan trọng |
|---|---|
| `/23`, không phải `/24` | Phủ cả `10.9.100.0/24` (AZ-a) và `10.9.101.0/24` (AZ-b). NLB nội bộ lấy một địa chỉ ở **mỗi** AZ và tên DNS trả về cả hai — thiếu một dải thì gọi được hay không tuỳ vào địa chỉ nào được chọn |
| `src 172.16.0.136` | Địa chỉ **thật** của máy, không phải `169.254.100.2` trong đường hầm. Thiếu `src` thì nhân tự chọn địa chỉ của interface `vti`, NLB trả lời về đó, và VPC không có đường nào tới dải đó — xem lỗi 78 |

Phép đo cuối cùng, và là phép duy nhất chứng minh được điều gì:

```
=== Goi dich vu ban cong bo ===
  NLB tra ve 200
```

`200` nghĩa là một gói tin HTTP đã đi hết **IPsec → VGW → NLB → TGW → Network Firewall → spoke `10.10.0.10` ở một account khác** rồi về. Mọi thứ khác trong mục này chỉ nói rằng từng chặng *có vẻ* đúng.

### 5.2c. Phép thử phải thất bại

`200` mới chứng minh được một nửa. Nửa còn lại là đối tác **không** đi được xa hơn thứ bạn công bố:

```
$ curl -sm 5 -o /dev/null -w 'http=%{http_code}\n' http://10.10.0.10/ ; echo "exit=$?"
http=000
exit=28
```

**Đừng chạy `curl -s` trần cho phép thử này.** Thất bại thì nó không in gì — và im lặng của thất bại đọc y hệt im lặng của thành công. Phải hỏi mã HTTP và mã thoát.

`exit=28` là *hết giờ*, không phải `7` (*không nối được*). Khác biệt đó đáng đọc: gói tin **có** rời máy, đi ra default route tới IGW của VPC giả lập, rồi chết ở đó. Lớp cách ly giữ được không phải vì có ai chặn, mà vì **máy đó không có route nào đưa `10.10.0.0/16` vào đường hầm** — chỉ có `10.9.10.0/24` và `10.9.100.0/23`.

Đó là lớp kiểm soát **thứ nhất** trong ba lớp ở mục 1, và nó nằm ở phía đối tác. Với đối tác thật, điều tương đương đạt được bằng static route hoặc BGP filter trên thiết bị của **họ** — nên nó phải nằm trong hợp đồng kỹ thuật, không chỉ nói miệng. Hai lớp còn lại (`rtb-partner` và Network Firewall) là thứ bạn kiểm soát được, và chúng tồn tại chính vì lớp thứ nhất nằm ngoài tầm tay bạn.

`vpn-check` giờ chạy phép thử này thay vì in một câu tuyên bố về nó.

### 5.3. Đường hầm `DOWN` — đọc theo thứ tự nào

```bash
aws ec2 describe-vpn-connections --region ap-southeast-1 \
  --vpn-connection-ids <id> \
  --query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress,Status,StatusMessage]' \
  --output table
```

**Cột `StatusMessage` là thứ cần đọc trước, không phải cột `Status`.** Nó chia bài toán làm đôi:

| `StatusMessage` | Nghĩa | Tìm ở đâu |
|---|---|---|
| **Rỗng** | AWS **chưa từng nhận** gói IKE nào | Phía đối tác: daemon có chạy không, gói tin có ra khỏi máy không, địa chỉ nguồn có đúng không |
| Có chữ | AWS **nhận được** rồi từ chối | Nội dung thông báo chỉ thẳng: PSK, bộ thuật toán, traffic selector |

Rỗng thì mọi giả thuyết từ IKE_SA_INIT trở đi đều bị loại — kể cả bộ thuật toán, kể cả PSK. Đó là bước thu hẹp mạnh nhất trong cả quy trình, và nó miễn phí.

Với đường rỗng, vào máy giả lập:

```bash
aws ssm start-session --target <instance-id> --region ap-southeast-1
sudo tail -40 /var/log/user-data.log   # kết luận nằm ở CUỐI file
sudo vpn-check
```

`user-data.log` tự kết luận ở dòng cuối: hoặc `=== IKE SA DA LEN ===`, hoặc 40 dòng `journalctl` kèm cách đọc. Ba thông báo hay gặp:

| Trong `journalctl` | Nguyên nhân |
|---|---|
| `no matching peer config` | `leftid` không khớp IP mà AWS nhìn thấy — gần như luôn là chuyện NAT |
| `retransmit` lặp mãi, không gì khác | Gói tin không tới được AWS — security group, hoặc route ra Internet |
| `NO_PROPOSAL_CHOSEN` | Lệch `ike=` / `esp=` với tuỳ chọn đường hầm phía AWS |

**Dựng lại chỉ máy giả lập**, không đụng vào VPN:

```bash
terraform apply -replace='aws_instance.partner_sim[0]'
```

An toàn vì EIP là resource riêng: customer gateway giữ nguyên địa chỉ, `aws_vpn_connection` không bị tạo lại, PSK và dải địa chỉ trong đường hầm không đổi. Phía AWS không biết có gì vừa xảy ra.

> **Máy giả lập chạy Ubuntu, không phải Amazon Linux.** AL2023 không có gói `strongswan` trong repo — `dnf install` trả về `Unable to find a match`. Đó là nguyên nhân đầu tiên của lần `DOWN` này, và nó nằm ở dòng thứ mười của `user-data.log` ngay từ lần chạy đầu. Thêm một dòng `dnf`/`yum` vào `strongswan.sh.tftpl` sau này sẽ làm hỏng máy đó.
>
> Ba khiếm khuyết tiếp theo tìm được ở đây — tuỳ chọn `install_routes` đặt nhầm file, `|| true` nuốt mất trường hợp "không có unit nào", và cuộc đua giữa lúc charon khởi động với lúc EIP được gắn — ghi ở [doc 22 mục 7al](./22-Nhat-ky-Trien-khai-LZ-DIY.md). Cả ba đều cho ra đúng một triệu chứng: hai đường hầm `DOWN`, `StatusMessage` rỗng.

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

## 10. Vận hành

Kết nối đối tác khác các phần khác của LZ ở chỗ **có một tổ chức khác cùng tham gia**. Phần lớn sự cố đến từ phối hợp, không phải kỹ thuật — nhưng phần kỹ thuật phải tự động đủ để phần phối hợp có chỗ mà đứng.

### 10.1. Hai layer, và ranh giới giữa chúng

Đây là điều cần nắm trước mọi thứ khác. Hạ tầng đối tác nằm ở hai nơi, và biết cái nào ở đâu quyết định bạn sửa file nào:

| Thứ | Ở đâu | Đổi bao lâu một lần |
|---|---|---|
| VPC vùng đệm, VGW, VPN connection, customer gateway, private NAT | `demo/network-lz-full/partner.tf` | vài tháng |
| Bản thân NLB và security group của nó | `partner.tf` | vài tháng |
| **Target group, target, listener** | `ops/vpn.tf` ← `catalog/partners.yaml` | **hằng tuần** |
| **Rule mở cổng trên security group** | `ops/vpn.tf` ← `catalog/partners.yaml` | **hằng tuần** |
| **Route VPN cho dải phụ** | `ops/vpn.tf` ← `catalog/partners.yaml` | hằng tháng |
| **Rule firewall** | `ops/firewall.tf` ← `catalog/firewall-rules.yaml` | **hằng tuần** |
| Cảnh báo đường hầm | `ops/vpn.tf` | tự động |

Nguyên tắc chia: **ai sở hữu listener thì sở hữu cả rule mở cổng cho nó.** Cắt sai chỗ này là lỗi 82 — listener ở một layer, security group ở layer kia, hai nửa của cùng một thay đổi lệch nhau, và triệu chứng là hết giờ không log.

### 10.2. Hồ sơ đối tác — một file, không phải hai

```yaml
# ops/catalog/partners.yaml
partners:
  - name: acme
    remote_cidr: 172.16.0.0/16        # dải họ công bố cho bạn
    extra_cidrs: [10.240.0.0/16]      # dải phụ, thành route VPN tĩnh
    contact: noc@acme.example
    ticket: PARTNER-2024-11
    expires: 2026-12-31               # ngày hết hợp đồng
    note: Đối soát đơn hàng hằng đêm

    services:
      - name: order
        port: 8080                    # đối tác gọi vào cổng này
        target_port: 80               # ứng dụng thật sự nghe cổng này
        target: order-api             # app trong apps.yaml, cidr phải là /32
        expires: 2026-06-30           # dịch vụ có thể hết trước hợp đồng
```

**Dải bạn công bố cho họ không khai ở đây.** Nó do layer cha quyết định (dải NAT + dải NLB) và lớp ops đọc từ `ops_handles`. Khai lại là hai chỗ có thể lệch nhau — và tài liệu bạn đưa cho đối tác sẽ là chỗ sai.

Cũng vì thế, thứ đưa cho đối tác **sinh ra từ chính cấu hình đang chạy**, không gõ tay:

```bash
cd demo/network-lz-full/ops && terraform output -raw partner_handover
```

In ra dải hai bên, danh sách dịch vụ kèm cổng và hạn, và câu cuối nói rằng ngoài những dải đó **không có đường nào tồn tại** — không phải bị chặn, mà là không tồn tại.

> Bản trước của tài liệu này mô tả một `partners/partner-a.yaml` viết tay chép lại CIDR, cổng và ngày rà soát. Nó đã bị bỏ: mọi trường trong đó hoặc suy ra được từ state, hoặc là thứ sẽ lệch với thực tế sau lần sửa Terraform đầu tiên mà không ai cập nhật lại tài liệu.

### 10.3. Runbook — thêm một đối tác mới

**Layer cha** (một lần cho mỗi đối tác):

```bash
cd demo/network-lz-full
# terraform.tfvars: enable_partner_vpn = true
# aws_customer_gateway.ip_address = IP thiết bị VPN của họ
terraform apply
```

Chuyển PSK qua kênh riêng — **không email, không chat**. Xem mục 5.1.

**Lớp ops** (hồ sơ và dịch vụ):

```bash
cd ops
# catalog/partners.yaml: thêm khối partner
./lint.sh && terraform plan && terraform apply
```

`lint.sh` chặn trước khi apply: tên sai định dạng, `remote_cidr` lệch dải layer cha thật sự định tuyến, trùng tên đối tác, hợp đồng đã hết hạn.

### 10.4. Runbook — công bố một dịch vụ

Thao tác hay xin nhất, và nó **không** động tới đường hầm.

**Bước 1** — thêm khối `services` vào hồ sơ đối tác (schema ở 10.2).

**Bước 2** — mở đường qua firewall. Cổng ở đây là **`target_port`**, không phải `port`:

```yaml
# ops/catalog/firewall-rules.yaml
- id: fw-0020
  from: partner-acme        # dải NLB, KHÔNG phải dải của đối tác
  to: order-api
  ports: [80]               # target_port
  ticket: PARTNER-2024-11
  expires: 2026-12-31
```

**Bước 3**:

```bash
./lint.sh && terraform plan && terraform apply
```

Sinh ra bốn thứ: target group, target, listener, và rule mở cổng trên security group của NLB.

Ba chỗ dễ sai, cả ba đều bị chặn **trước** khi apply:

| Sai | Vì sao nó im lặng nếu không chặn |
|---|---|
| `from` là dải thật của đối tác thay vì `partner-<tên>` | NLB dừng kết nối của họ lại và mở kết nối **mới** tới ứng dụng, nên firewall thấy nguồn là dải NLB. Rule khai dải đối tác apply thành công và không khớp gói tin nào |
| `ports` là `port` thay vì `target_port` | Firewall nằm trên kết nối **thứ hai**, từ NLB tới ứng dụng. Rule mở cổng ngoài mô tả một kết nối không bao giờ xảy ra |
| Trùng cổng với dịch vụ khác hoặc với `reserved_port` | Một NLB cho **mọi** đối tác, và NLB chỉ cho một listener trên một cổng — nên Acme và Globex chạm cổng nhau được |

`lint.sh` **đối chiếu hai file**: với mỗi dịch vụ nó tìm rule từ `partner-<tên>` tới đúng app đó và kiểm rule ấy có mở `target_port` không. Phép đối chiếu này quan trọng vì ở chế độ `alert` cả hai trạng thái đều "chạy" — ngày chuyển sang `drop` mới đứt.

### 10.5. Runbook — cắt một dịch vụ, hoặc một đối tác

**Cắt một dịch vụ:** xoá khối `services` đó, `apply`. Listener và rule mở cổng biến mất **ngay** — không chờ rule firewall.

Hai lớp trả lời hai câu hỏi khác nhau, và gỡ **một trong hai** là đủ để cắt:

| Lớp | Câu hỏi |
|---|---|
| Listener + rule SG | Đối tác **gọi được** tới đâu |
| Rule firewall | Gói tin có **đi tiếp** tới spoke không |

Giữ cả hai để một sai sót ở một lớp không tự nó mở đường.

**Cắt một đối tác:** xoá cả khối partner. Điều đó cũng bỏ app `partner-<tên>`, nên mọi rule firewall trỏ tới nó sẽ **làm `lint.sh` đỏ** — đúng ý đồ: nó bắt bạn dọn nốt thay vì để lại rule trỏ vào hư không.

**Hết hạn không tự cắt.** `expires` chỉ làm `lint.sh` thoát khác 0 và job `expiry` trong CI đỏ mỗi ngày. Gỡ vẫn là một commit có người duyệt — cắt đường của đối tác lúc nửa đêm là một cuộc gọi điện lúc nửa đêm.

### 10.6. Cảnh báo đường hầm

`ops/vpn.tf` tạo hai cảnh báo CloudWatch trên `TunnelState`:

| Cảnh báo | Ngưỡng | Nghĩa |
|---|---|---|
| `-DUT` | Average < 0.5, 2 phút | Cả hai đường hầm xuống — đứt hẳn |
| `-mat-du-phong` | Average < 1, 15 phút | Một đường hầm xuống — **vẫn chạy**, hết dự phòng |

Hai mức vì chúng đòi hai hành động khác nhau. Gộp làm một thì hoặc bỏ qua trạng thái mất dự phòng, hoặc kêu mỗi lần AWS bảo trì một đường hầm — và kiểu thứ hai thì sau vài lần không ai đọc nữa.

Mức "đứt" đặt `treat_missing_data = "breaching"`: một VPN connection **ngừng phát metric** là tin xấu, không phải tin trung tính. Mặc định của CloudWatch là im lặng trong trường hợp đó.

Chúng chỉ gọi được ai khi `alarm_actions` trỏ tới SNS topic thật. Để rỗng thì cảnh báo vẫn được tạo và vẫn đổi trạng thái trong console — chỉ là **không ai được báo**, và người phát hiện ra sẽ là đối tác. `check "partner_alarms_reach_someone"` nhắc lúc plan.

### 10.7. Danh sách kiểm tra khi thêm đối tác mới

```text
TRUOC khi cau hinh
  □ Da ky thoa thuan ky thuat (CIDR, port, muc dich)
  □ Da co dau moi ky thuat va duong escalation cua ho
  □ Da thong nhat thuat toan IPsec (phase 1/2)
  □ Da xac nhan dai CIDR ho cong bo KHONG trung dai noi bo cua ban
  □ Da quyet dinh: PrivateLink duoc khong? (uu tien hon VPN)
  □ alarm_actions da tro toi SNS topic that

Cau hinh
  □ Layer cha: customer gateway + VPN connection, apply
  □ Chuyen PSK qua kenh an toan (KHONG email/chat)
  □ Lop ops: ho so trong partners.yaml
  □ Lop ops: services cho tung dich vu, dung target_port
  □ Rule firewall mo target_port, from la partner-<ten>
  □ ./lint.sh sach truoc khi plan

Kiem thu - CHAY THAT, DUNG GIA DINH
  □ Tunnel len ca hai
  □ curl toi tung cong da cong bo -> 200
  □ curl thang toi mot IP spoke -> PHAI that bai
  □ Failover: tat tunnel 1, luu luong chuyen sang tunnel 2
  □ verify.sh muc 10 sach

Ban giao
  □ terraform output -raw partner_handover -> gui doi tac
  □ Runbook xu ly su co
  □ expires da dat trong ca ho so lan tung dich vu
```

Dòng "chạy thật, đừng giả định" đáng nhấn mạnh: rất nhiều tổ chức chỉ kiểm tra luồng **được phép** chạy tốt, mà không bao giờ kiểm tra luồng **bị cấm** thật sự bị chặn. `vpn-check` trên máy giả lập chạy cả hai và báo `DAT`/`LOI` — trước đây mục đó chỉ **in một câu tuyên bố** mà không kiểm gì.

### 10.8. Triệu chứng → nguyên nhân

Mọi dòng đều là kiểu hỏng **không phát ra lỗi**.

| Triệu chứng | Nguyên nhân |
|---|---|
| Cổng mới `http=000 exit=28`, cổng cũ vẫn `200` | Thiếu rule mở cổng trên security group của NLB — gói tin bị vứt **trước** listener. Thường là chưa `apply` ở lớp ops (lỗi 82) |
| Đối tác nhận `connection reset` | Có listener, firewall chặn. Chỉ xảy ra ở chế độ `drop`; rule mở nhầm `port` thay vì `target_port` |
| `000` ngay sau khi apply, vài chục giây sau thì `200` | Target group vừa tạo chưa qua đủ chu kỳ health check (10s × 2) |
| Gọi được, rồi mất sau một lần apply layer cha, rồi có lại sau khi apply lớp ops | Security group của layer cha quay về dùng khối `ingress` **lồng nhau** — nó sở hữu toàn bộ danh sách rule và xoá sạch rule của lớp ops (lỗi 82) |
| Một lần gọi được, lần sau không | Dải NLB công bố không phủ hết subnet NLB của mọi AZ. Tên DNS trả về cả hai địa chỉ, gọi được hay không tuỳ địa chỉ nào được chọn (lỗi 79) |
| Target `unhealthy` ngay từ đầu | `target_port` trỏ tới cổng ứng dụng không nghe |
| Đường hầm `UP` mà `curl` hết giờ | Route trên `vti` thiếu `src`, nên nguồn là địa chỉ trong đường hầm và gói trả lời không có đường về (lỗi 78) |
| Đường hầm `DOWN`, `StatusMessage` rỗng | Chưa có gói IKE nào tới nơi — xem **mục 5.3** |

---

## 11. Chi phí

| Thành phần | Đơn giá | Tháng |
|---|---|---|
| VPN connection | ~$0.05/giờ mỗi kết nối | ~$36.50/đối tác |
| VPN data transfer out | Theo giá data transfer thường | Theo lưu lượng |
| TGW attachment (3rd-party VPC) | ~$0.05/giờ | ~$36.50 |
| Private NAT Gateway | ~$0.045/giờ + $0.045/GB | ~$33 + traffic |
| Firewall data (đã có ở doc 15) | ~$0.065/GB | Theo lưu lượng |
| NLB nội bộ (vùng đệm) | ~$0.0225/giờ mỗi AZ | ~$33 (2 AZ) |
| Cảnh báo CloudWatch | $0.10/cảnh báo | $0.20 |
| **Ba đối tác** | | **~$215/tháng** + traffic |

**Cái gì miễn phí:** target group, listener, rule security group, route VPN tĩnh, và bản thân **số lượng dịch vụ** công bố. Công bố dịch vụ thứ mười cho một đối tác không tốn thêm gì — tiền nằm ở đường ống, không ở số cửa mở trên nó.

Ba khoản đắt nhất đều tính theo **giờ, không theo lưu lượng**: VPN connection, TGW attachment và private NAT chạy $0.145/giờ ngay cả khi không một gói tin nào đi qua. Và VPN tính tiền **từ lúc tạo, không từ lúc đường hầm lên** — một kết nối đối tác bị quên là ~$105/tháng cho không có gì. Đó là lý do `expires` tồn tại.

So sánh: **PrivateLink** cho một service khoảng $7.30/tháng mỗi AZ cộng $0.01/GB — rẻ hơn nhiều và cách ly tốt hơn. Đây là lý do thực tế, ngoài lý do bảo mật, để ưu tiên PrivateLink khi có thể.

---

## 12. Bẫy hay gặp — tầng đường hầm và định tuyến

Bảng này là bẫy ở tầng IPsec và định tuyến. Bẫy ở **tầng vận hành** — listener, cổng, security group, rule firewall — nằm ở **mục 10.8**.

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
| Không ai biết kết nối này còn dùng không | Thiếu `expires` trong hồ sơ — `lint.sh` cảnh báo khi thiếu, và job `expiry` trong CI đỏ mỗi ngày khi quá hạn |
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
