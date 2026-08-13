# Centralized DNS – Route 53 Resolver + Windows AD on-premise + Microsoft 365

Ví dụ 07: Phần **DNS tập trung** của Landing Zone (tiếp nối [06 – AWS Landing Zone](./06-Aws-Landing-Zone.md)).

Bài toán thực tế:

- On-premise đã có **Active Directory Domain Services** với zone nội bộ `corp.acme.local`, DC kiêm luôn DNS server.
- AWS có nhiều VPC nằm rải ở các account (dev/prod/network).
- Công ty dùng **Microsoft 365** (Exchange Online, Teams, Entra ID) – phần này là **DNS public**, hoàn toàn khác với DNS nội bộ.
- Yêu cầu: EC2 trong AWS join được domain và resolve được tên on-prem; server on-prem resolve được tên trong AWS; M365 hoạt động bình thường; log DNS query tập trung để audit.

Stack trong bài:

- **Route 53 Resolver** – inbound + outbound endpoint (hybrid DNS)
- **Route 53 Private Hosted Zone** + share cross-account
- **Route 53 Profiles** – cách mới để phân phối cấu hình DNS cho nhiều VPC
- **AWS RAM** – share resolver rule cho cả org
- **AWS Managed Microsoft AD** + two-way trust với forest on-prem
- **Route 53 Resolver DNS Firewall** + Query Logging
- **Route 53 Public Hosted Zone** cho bản ghi Microsoft 365
- IaC với **Terraform**, PowerShell cho phía Windows

---

## 1. Ba không gian tên, đừng trộn vào nhau

Sai lầm phổ biến nhất khi làm hybrid DNS là gộp cả ba thứ này làm một. Chúng khác nhau về bản chất:

| Không gian tên | Ví dụ | Ai là authoritative | Ai cần resolve |
|---|---|---|---|
| **AD nội bộ** | `corp.acme.local` | DC on-premise | Máy on-prem + EC2 domain-joined |
| **AWS nội bộ** | `aws.acme.internal` | Route 53 Private Hosted Zone | Resource trong VPC + máy on-prem |
| **Public / M365** | `acme.com` | Route 53 Public Hosted Zone | Cả thế giới (Exchange Online, khách hàng) |

Ba luồng phân giải tương ứng:

```text
┌──────────────────────── ON-PREMISE ────────────────────────┐
│  Windows client / server                                    │
│        │                                                    │
│        ▼                                                    │
│  AD DNS (DC1 10.1.0.10 / DC2 10.1.0.11)                     │
│  ├─ corp.acme.local ............ authoritative (tại chỗ)    │
│  ├─ aws.acme.internal .......... conditional forwarder ─────┼──┐
│  ├─ 0.10.in-addr.arpa .......... conditional forwarder ─────┼──┤
│  └─ * (acme.com, M365) ......... forwarder → Internet DNS   │  │
└─────────────────────────────────────────────────────────────┘  │
                          │ Direct Connect / VPN                  │
                          ▼                                       │
┌──────────────────── AWS – network account ──────────────────┐   │
│                                                              │   │
│   Route 53 Resolver INBOUND endpoint  ◄─────────────────────┼───┘
│   (10.0.1.10 / 10.0.2.10, port 53)                          │
│         │ trả lời cho on-prem                                │
│         ▼                                                    │
│   ┌──────────────────────────────────────────┐              │
│   │ Route 53 Resolver (VPC + 2)              │              │
│   │  1. Private Hosted Zone (aws.acme.internal)             │
│   │  2. Resolver rules (corp.acme.local → on-prem)          │
│   │  3. Public DNS (acme.com, outlook.com, …)               │
│   └──────────────────────────────────────────┘              │
│         │                                                    │
│         ▼                                                    │
│   Route 53 Resolver OUTBOUND endpoint ──────────────────────┼──► DC on-prem
│   (10.0.1.20 / 10.0.2.20)                                   │    10.1.0.10/11
│                                                              │
│   + DNS Firewall (chặn domain xấu)                          │
│   + Query Logging → S3 ở log-archive account                │
└──────────────────────────────────────────────────────────────┘
          │ RAM share resolver rules + PHZ association
          ▼
    app-dev VPC, app-prod VPC (các account workload)
```

**Inbound** = on-prem hỏi vào AWS. **Outbound** = AWS hỏi ra on-prem. Cần cả hai nếu muốn hai chiều; nếu on-prem không bao giờ cần resolve tên AWS thì bỏ inbound endpoint (tiết kiệm ~$180/tháng, xem mục 12).

---

## 2. Thứ tự phân giải trong VPC – nắm kỹ chỗ này

Khi một EC2 hỏi `something.acme.com`, Route 53 Resolver xử theo thứ tự:

1. **Match dài nhất thắng.** `db.aws.acme.internal` khớp PHZ `aws.acme.internal` (3 label) sẽ thắng rule `acme.internal` (2 label).
2. **Bằng nhau về độ dài → Private Hosted Zone thắng resolver rule.**
3. Không match gì → autodefined rule của AWS (`amazonaws.com`, `ec2.internal`, …) → cuối cùng ra public DNS.

Hệ quả quan trọng, và đây là **cái bẫy hay gặp nhất**:

> Nếu bạn tạo Private Hosted Zone cho **`acme.com`** (đúng tên domain public đang chạy M365), thì mọi EC2 trong VPC associated sẽ **không còn resolve được** `autodiscover.acme.com`, `acme-com.mail.protection.outlook.com`… trừ khi bạn chép thủ công từng bản ghi public vào PHZ đó. Split-brain DNS kiểu này gây sự cố mail rất khó debug.

Cách tránh: **dùng subdomain riêng cho nội bộ AWS**, đừng chiếm apex.

- Tốt: PHZ `aws.acme.com` hoặc `aws.acme.internal`
- Tệ: PHZ `acme.com`

Bài này dùng `aws.acme.internal` cho nội bộ, `acme.com` chỉ tồn tại ở public hosted zone.

---

## 3. Cấu trúc thư mục

Tiếp theo cấu trúc ở doc 06:

```text
aws-landing-zone/
  6-dns/
    main.tf              # provider + locals
    resolver.tf          # inbound/outbound endpoint + rules
    private-zones.tf     # PHZ + cross-account association
    ram.tf               # share rules cho org
    firewall.tf          # DNS Firewall
    logging.tf           # query logging → log-archive
    public-m365.tf       # public hosted zone + bản ghi Microsoft 365
    directory.tf         # AWS Managed Microsoft AD + trust (tuỳ chọn)
  onprem/
    Set-ConditionalForwarders.ps1
```

Toàn bộ resource DNS đặt ở **network account** (hoặc tách riêng một `shared-services` account nếu tổ chức lớn).

---

## 4. Route 53 Resolver – inbound & outbound endpoint

### 4.1. 6-dns/main.tf

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "network_account_id" { type = string }
variable "log_archive_account_id" { type = string }
variable "organization_arn" { type = string }

variable "onprem_dns_servers" {
  description = "IP của DC/DNS on-premise"
  type        = list(string)
  default     = ["10.1.0.10", "10.1.0.11"]
}

variable "onprem_cidrs" {
  description = "Dải mạng on-premise được phép query vào inbound endpoint"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "ad_domain" {
  type    = string
  default = "corp.acme.local"
}

provider "aws" {
  alias  = "network"
  region = "ap-southeast-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.network_account_id}:role/OrganizationAccountAccessRole"
  }
}

# VPC hub trong network account (tạo ở doc 06 mục 11)
data "aws_vpc" "hub" {
  provider = aws.network

  tags = {
    Name = "acme-egress-vpc"
  }
}

data "aws_subnets" "hub_private" {
  provider = aws.network

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.hub.id]
  }

  tags = {
    Tier = "private"
  }
}

locals {
  # Resolver endpoint bắt buộc >= 2 subnet ở 2 AZ khác nhau
  resolver_subnets = slice(tolist(data.aws_subnets.hub_private.ids), 0, 2)
}
```

### 4.2. 6-dns/resolver.tf

```hcl
########################
# Security Groups
########################

resource "aws_security_group" "resolver_inbound" {
  provider    = aws.network
  name        = "r53-resolver-inbound"
  description = "Cho phep on-prem DNS query vao AWS"
  vpc_id      = data.aws_vpc.hub.id

  ingress {
    description = "DNS UDP tu on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = var.onprem_cidrs
  }

  ingress {
    description = "DNS TCP tu on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = var.onprem_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "r53-resolver-inbound" }
}

resource "aws_security_group" "resolver_outbound" {
  provider    = aws.network
  name        = "r53-resolver-outbound"
  description = "Cho phep AWS query ra DNS on-prem"
  vpc_id      = data.aws_vpc.hub.id

  egress {
    description = "DNS UDP toi DC on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = var.onprem_cidrs
  }

  egress {
    description = "DNS TCP toi DC on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = var.onprem_cidrs
  }

  tags = { Name = "r53-resolver-outbound" }
}

########################
# INBOUND endpoint – on-prem hỏi vào AWS
########################

resource "aws_route53_resolver_endpoint" "inbound" {
  provider           = aws.network
  name               = "acme-inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.resolver_inbound.id]

  # Cố định IP để khai báo conditional forwarder bên on-prem cho ổn định
  ip_address {
    subnet_id = local.resolver_subnets[0]
    ip        = "10.0.1.10"
  }

  ip_address {
    subnet_id = local.resolver_subnets[1]
    ip        = "10.0.2.10"
  }

  tags = { Name = "acme-inbound" }
}

########################
# OUTBOUND endpoint – AWS hỏi ra on-prem
########################

resource "aws_route53_resolver_endpoint" "outbound" {
  provider           = aws.network
  name               = "acme-outbound"
  direction          = "OUTBOUND"
  security_group_ids = [aws_security_group.resolver_outbound.id]

  ip_address {
    subnet_id = local.resolver_subnets[0]
    ip        = "10.0.1.20"
  }

  ip_address {
    subnet_id = local.resolver_subnets[1]
    ip        = "10.0.2.20"
  }

  tags = { Name = "acme-outbound" }
}

########################
# Forward rules → on-prem
########################

# Zone AD chính. Rule này phủ luôn mọi subdomain, bao gồm
# _msdcs.corp.acme.local (zone riêng trong AD nhưng vẫn là con của corp.acme.local)
resource "aws_route53_resolver_rule" "ad_domain" {
  provider             = aws.network
  name                 = "fwd-corp-acme-local"
  domain_name          = var.ad_domain
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = var.onprem_dns_servers
    content {
      ip   = target_ip.value
      port = 53
    }
  }

  tags = { Name = "fwd-corp-acme-local" }
}

# Reverse DNS cho dải on-prem – AD rất cần PTR cho Kerberos/logging
resource "aws_route53_resolver_rule" "ad_reverse" {
  provider             = aws.network
  name                 = "fwd-onprem-reverse"
  domain_name          = "1.10.in-addr.arpa"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = var.onprem_dns_servers
    content {
      ip   = target_ip.value
      port = 53
    }
  }

  tags = { Name = "fwd-onprem-reverse" }
}

# Zone nội bộ khác on-prem (file server, ứng dụng legacy…)
resource "aws_route53_resolver_rule" "legacy_apps" {
  provider             = aws.network
  name                 = "fwd-acme-intra"
  domain_name          = "intra.acme.com"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = var.onprem_dns_servers
    content {
      ip   = target_ip.value
      port = 53
    }
  }

  tags = { Name = "fwd-acme-intra" }
}

########################
# Associate rule với VPC hub
########################

resource "aws_route53_resolver_rule_association" "hub" {
  provider = aws.network

  for_each = {
    ad      = aws_route53_resolver_rule.ad_domain.id
    reverse = aws_route53_resolver_rule.ad_reverse.id
    legacy  = aws_route53_resolver_rule.legacy_apps.id
  }

  resolver_rule_id = each.value
  vpc_id           = data.aws_vpc.hub.id
}

output "inbound_endpoint_ips" {
  description = "Khai bao cac IP nay lam conditional forwarder tren AD DNS"
  value       = [for ip in aws_route53_resolver_endpoint.inbound.ip_address : ip.ip]
}
```

Vài điểm cần biết:

- Mỗi resolver endpoint cần **tối thiểu 2 IP ở 2 AZ**. Mỗi IP xử lý khoảng **10.000 query/giây** – thêm IP nếu cần scale.
- Đặt IP tĩnh (`ip = "10.0.1.10"`) thay vì để AWS random, vì bên on-prem phải hardcode IP này vào conditional forwarder. Đổi IP sau = phải sửa cả hai đầu.
- Rule `FORWARD` áp cho domain **và toàn bộ subdomain**. Muốn một subdomain cụ thể **không** forward mà resolve bằng public DNS, tạo rule `SYSTEM` cho subdomain đó:

```hcl
resource "aws_route53_resolver_rule" "bypass_public_sub" {
  provider    = aws.network
  name        = "system-public-intra"
  domain_name = "public.intra.acme.com"
  rule_type   = "SYSTEM"
}
```

---

## 5. Share resolver rules cho cả Organization

Không đi association thủ công từng VPC ở từng account. Share bằng RAM một lần:

### 5.1. 6-dns/ram.tf

```hcl
resource "aws_ram_resource_share" "dns" {
  provider                  = aws.network
  name                      = "acme-dns-rules"
  allow_external_principals = false

  tags = { Name = "acme-dns-rules" }
}

resource "aws_ram_resource_association" "rules" {
  provider = aws.network

  for_each = {
    ad      = aws_route53_resolver_rule.ad_domain.arn
    reverse = aws_route53_resolver_rule.ad_reverse.arn
    legacy  = aws_route53_resolver_rule.legacy_apps.arn
  }

  resource_arn       = each.value
  resource_share_arn = aws_ram_resource_share.dns.arn
}

resource "aws_ram_principal_association" "org" {
  provider           = aws.network
  principal          = var.organization_arn
  resource_share_arn = aws_ram_resource_share.dns.arn
}
```

Bên account workload, sau khi rule đã được share thì associate vào VPC của mình:

```hcl
provider "aws" {
  alias = "app_prod"
  # assume role vào app-prod...
}

data "aws_route53_resolver_rules" "shared" {
  provider     = aws.app_prod
  rule_type    = "FORWARD"
  share_status = "SHARED_WITH_ME"
}

resource "aws_route53_resolver_rule_association" "app_prod" {
  provider = aws.app_prod
  for_each = toset(data.aws_route53_resolver_rules.shared.resolver_rule_ids)

  resolver_rule_id = each.value
  vpc_id           = var.app_prod_vpc_id
}
```

### 5.2. Cách mới hơn: Route 53 Profiles

Nếu org có hàng chục VPC, quản lý từng association rất mệt. **Route 53 Profiles** gói (PHZ + resolver rules + DNS Firewall + cấu hình resolver) thành một object, share qua RAM, rồi mỗi VPC chỉ cần attach vào profile:

```hcl
resource "aws_route53profiles_profile" "corp" {
  provider = aws.network
  name     = "acme-corp-dns"
}

resource "aws_route53profiles_resource_association" "ad_rule" {
  provider     = aws.network
  name         = "ad-forward-rule"
  profile_id   = aws_route53profiles_profile.corp.id
  resource_arn = aws_route53_resolver_rule.ad_domain.arn
}

resource "aws_route53profiles_resource_association" "phz" {
  provider     = aws.network
  name         = "aws-internal-phz"
  profile_id   = aws_route53profiles_profile.corp.id
  resource_arn = aws_route53_zone.aws_internal.arn
}

# Share profile cho org, rồi mỗi VPC gắn 1 lần
resource "aws_route53profiles_association" "app_prod" {
  provider    = aws.app_prod
  name        = "app-prod-vpc"
  profile_id  = aws_route53profiles_profile.corp.id
  resource_id = var.app_prod_vpc_id
}
```

Một VPC chỉ gắn được **một** profile. Nếu đang xây mới, đi thẳng hướng Profiles cho đỡ nợ kỹ thuật.

---

## 6. Private Hosted Zone và chia sẻ cross-account

### 6.1. 6-dns/private-zones.tf

```hcl
########################
# PHZ nội bộ AWS
########################

resource "aws_route53_zone" "aws_internal" {
  provider = aws.network
  name     = "aws.acme.internal"
  comment  = "Ten noi bo cho resource trong AWS"

  vpc {
    vpc_id = data.aws_vpc.hub.id
  }

  # Association từ account khác được quản lý bằng resource riêng bên dưới
  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "artifacts" {
  provider = aws.network
  zone_id  = aws_route53_zone.aws_internal.zone_id
  name     = "artifacts.aws.acme.internal"
  type     = "CNAME"
  ttl      = 300
  records  = ["acme-artifacts.s3.ap-southeast-1.amazonaws.com"]
}

########################
# Cross-account association
# Bước 1: zone owner cấp phép   Bước 2: VPC owner associate
########################

resource "aws_route53_vpc_association_authorization" "app_prod" {
  provider = aws.network
  zone_id  = aws_route53_zone.aws_internal.zone_id
  vpc_id   = var.app_prod_vpc_id
}

resource "aws_route53_zone_association" "app_prod" {
  provider = aws.app_prod
  zone_id  = aws_route53_vpc_association_authorization.app_prod.zone_id
  vpc_id   = aws_route53_vpc_association_authorization.app_prod.vpc_id
}
```

`lifecycle { ignore_changes = [vpc] }` là bắt buộc: nếu không, mỗi lần apply Terraform sẽ thấy các VPC được associate từ account khác là "thừa" và gỡ chúng ra.

### 6.2. PHZ cho VPC endpoint (PrivateLink)

Đây là chỗ nối trực tiếp với các ví dụ trước trong repo. Nếu bạn deploy **Private API Gateway** (doc 02) và muốn on-prem gọi vào qua Direct Connect:

```hcl
resource "aws_vpc_endpoint" "execute_api" {
  provider            = aws.network
  vpc_id              = data.aws_vpc.hub.id
  service_name        = "com.amazonaws.ap-southeast-1.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.resolver_subnets
  private_dns_enabled = false # tự quản PHZ để share cho nhiều account

  security_group_ids = [aws_security_group.vpce.id]
}

resource "aws_route53_zone" "execute_api" {
  provider = aws.network
  name     = "execute-api.ap-southeast-1.amazonaws.com"

  vpc {
    vpc_id = data.aws_vpc.hub.id
  }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "execute_api_wildcard" {
  provider = aws.network
  zone_id  = aws_route53_zone.execute_api.zone_id
  name     = "*.execute-api.ap-southeast-1.amazonaws.com"
  type     = "A"

  alias {
    name                   = aws_vpc_endpoint.execute_api.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.execute_api.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}
```

Sau đó bên on-prem thêm conditional forwarder cho `execute-api.ap-southeast-1.amazonaws.com` trỏ về inbound endpoint → máy on-prem gọi được private API.

> Cẩn thận: PHZ này chiếm **toàn bộ** namespace `execute-api.ap-southeast-1.amazonaws.com` trong các VPC được associate. Mọi API Gateway public trong region đó sẽ resolve về VPC endpoint. Nếu VPC vừa gọi private API vừa gọi public API, cân nhắc kỹ hoặc tách VPC.

---

## 7. Phía Windows – conditional forwarder trên AD DNS

Chạy trên DC (hoặc từ máy có RSAT), quyền Domain Admin.

### 7.1. onprem/Set-ConditionalForwarders.ps1

```powershell
<#
    Tro cac namespace cua AWS ve Route 53 Resolver INBOUND endpoint.
    ReplicationScope = Forest -> tu dong replicate sang moi DC.
#>

$InboundEndpointIPs = @("10.0.1.10", "10.0.2.10")

$Zones = @(
    "aws.acme.internal"                              # PHZ noi bo
    "execute-api.ap-southeast-1.amazonaws.com"       # Private API Gateway
    "ap-southeast-1.amazonaws.com"                   # cac VPC endpoint khac (tuy chon)
    "0.10.in-addr.arpa"                              # reverse cho dai AWS 10.0.x
    "10.10.in-addr.arpa"
    "20.10.in-addr.arpa"
)

foreach ($Zone in $Zones) {
    $existing = Get-DnsServerZone -Name $Zone -ErrorAction SilentlyContinue

    if ($null -eq $existing) {
        Write-Host "Creating conditional forwarder: $Zone"
        Add-DnsServerConditionalForwarderZone `
            -Name             $Zone `
            -MasterServers    $InboundEndpointIPs `
            -ReplicationScope "Forest"
    }
    else {
        Write-Host "Updating conditional forwarder: $Zone"
        Set-DnsServerConditionalForwarderZone `
            -Name          $Zone `
            -MasterServers $InboundEndpointIPs
    }
}

# Kiem tra
Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Forwarder" } |
    Format-Table ZoneName, MasterServers -AutoSize

Resolve-DnsName -Name "artifacts.aws.acme.internal" -Server 127.0.0.1
```

### 7.2. Đừng tạo forwarding loop

Quy tắc: **mỗi zone chỉ có một hướng forward.**

- On-prem forward `aws.acme.internal` → AWS inbound. AWS **không** được forward zone này ngược về on-prem.
- AWS forward `corp.acme.local` → DC on-prem. DC **không** được forward zone này về AWS.

Nếu lỡ cấu hình cả hai chiều cho cùng một zone, query sẽ nảy qua lại tới khi timeout, và triệu chứng là "DNS lúc được lúc không" rất khó lần ra.

### 7.3. Firewall giữa on-prem và AWS

Mở TCP **và** UDP port 53 hai chiều:

| Chiều | Nguồn | Đích | Port |
|---|---|---|---|
| On-prem → AWS | DC (10.1.0.10/11) | Inbound endpoint (10.0.1.10, 10.0.2.10) | TCP/UDP 53 |
| AWS → On-prem | Outbound endpoint (10.0.1.20, 10.0.2.20) | DC (10.1.0.10/11) | TCP/UDP 53 |

Chỉ mở UDP là một lỗi kinh điển: các truy vấn trả về response lớn (nhiều bản ghi SRV của AD, DNSSEC) sẽ fallback sang TCP và fail.

---

## 8. DHCP option set – để nguyên AmazonProvidedDNS

Cám dỗ thường gặp: trỏ DHCP option set của VPC thẳng vào IP của DC để EC2 join domain được. **Đừng làm vậy** trừ khi bắt buộc, vì khi đó EC2 sẽ không còn resolve được Private Hosted Zone và tên VPC endpoint.

Cách đúng:

```hcl
# Giữ mặc định AmazonProvidedDNS (VPC CIDR + 2).
# Route 53 Resolver lo phần forward corp.acme.local sang DC.
# => EC2 vừa join domain được, vừa resolve được PHZ + VPC endpoint.
```

Nếu vì lý do nào đó vẫn phải trỏ về DC:

```hcl
resource "aws_vpc_dhcp_options" "ad" {
  provider            = aws.network
  domain_name         = var.ad_domain
  domain_name_servers = var.onprem_dns_servers # tối đa 4 IP

  tags = { Name = "dhcp-ad" }
}

resource "aws_vpc_dhcp_options_association" "ad" {
  provider        = aws.network
  vpc_id          = data.aws_vpc.hub.id
  dhcp_options_id = aws_vpc_dhcp_options.ad.id
}
```

thì bắt buộc phải cấu hình DC forward ngược các zone AWS về inbound endpoint (mục 7.1), nếu không PHZ sẽ chết.

---

## 9. AWS Managed Microsoft AD + trust với forest on-prem

Nếu muốn EC2/RDS/FSx trong AWS xác thực bằng AD mà không phụ thuộc đường Direct Connect luôn sống, dựng **AWS Managed Microsoft AD** trong AWS và thiết lập **two-way forest trust** với on-prem.

So sánh nhanh ba hướng:

| Hướng | Khi nào dùng | Nhược điểm |
|---|---|---|
| Forward DNS về DC on-prem (mục 4) | Ít workload AD trong AWS | Đứt DC/đứt link = không auth được |
| **AWS Managed Microsoft AD + trust** | Có workload AD thật sự trong AWS | Tốn thêm phí directory |
| AD Connector | Chỉ cần proxy auth cho WorkSpaces/CLI | Không phải DC thật, không cache |

### 9.1. 6-dns/directory.tf

```hcl
resource "aws_directory_service_directory" "aws_ad" {
  provider = aws.network

  name     = "aws.acme.local" # KHÁC với corp.acme.local của on-prem
  password = var.ad_admin_password
  edition  = "Standard"       # Enterprise nếu cần nhiều object / multi-region
  type     = "MicrosoftAD"

  vpc_settings {
    vpc_id     = data.aws_vpc.hub.id
    subnet_ids = local.resolver_subnets
  }

  tags = { Name = "acme-aws-ad" }
}

# Managed AD cần biết đường tìm DC on-prem
resource "aws_directory_service_conditional_forwarder" "onprem" {
  provider = aws.network

  directory_id       = aws_directory_service_directory.aws_ad.id
  remote_domain_name = var.ad_domain
  dns_ips            = var.onprem_dns_servers
}

# Two-way forest trust
resource "aws_directory_service_trust" "onprem" {
  provider = aws.network

  directory_id            = aws_directory_service_directory.aws_ad.id
  remote_domain_name      = var.ad_domain
  trust_direction         = "Two-Way"
  trust_password          = var.trust_password
  conditional_forwarder_ip_addrs = var.onprem_dns_servers

  # "Forest" cho phép dùng chung toàn bộ forest; "External" chỉ 1 domain
  trust_type = "Forest"

  selective_auth = "Disabled"
}

# Forward zone của Managed AD cho các VPC khác trong org
resource "aws_route53_resolver_rule" "aws_ad_domain" {
  provider             = aws.network
  name                 = "fwd-aws-acme-local"
  domain_name          = "aws.acme.local"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = aws_directory_service_directory.aws_ad.dns_ip_addresses
    content {
      ip   = target_ip.value
      port = 53
    }
  }
}
```

Phía on-prem, tạo trust đối ứng (chỉ làm một lần, PowerShell hoặc *AD Domains and Trusts*):

```powershell
# Tren DC on-prem: conditional forwarder toi Managed AD truoc
Add-DnsServerConditionalForwarderZone `
    -Name          "aws.acme.local" `
    -MasterServers "10.0.1.30","10.0.2.30" `   # DNS IP cua Managed AD
    -ReplicationScope "Forest"

# Sau do tao trust doi ung (dung cung trust_password voi phia AWS)
netdom trust corp.acme.local /Domain:aws.acme.local /twoway /transitive /add /passwordt:<trust_password> /userD:CORP\Administrator /passwordD:*
```

Trust chỉ hoạt động khi **DNS hai chiều đã thông trước** – đây là lý do gần như mọi lỗi "trust creation failed" đều là lỗi DNS.

---

## 10. Microsoft 365 – phần DNS public

Điểm hay nhầm: **M365 không dùng DNS nội bộ của bạn.** Exchange Online, Teams, Entra ID đều tra cứu bản ghi **public** của `acme.com`. Nên toàn bộ phần này nằm ở **Public Hosted Zone**, tách hẳn khỏi mọi thứ ở mục 4–9.

### 10.1. 6-dns/public-m365.tf

```hcl
variable "m365_tenant" {
  description = "Ten tenant, vi du acme.onmicrosoft.com -> 'acme'"
  type        = string
  default     = "acme"
}

variable "m365_verification_txt" {
  description = "Chuoi MS=msXXXXXXXX lay tu Microsoft 365 admin center"
  type        = string
}

resource "aws_route53_zone" "public" {
  provider = aws.network
  name     = "acme.com"
  comment  = "Public zone - M365 + web"
}

locals {
  # Microsoft dat ten host mail theo domain, dau '.' doi thanh '-'
  mx_host = "${replace("acme.com", ".", "-")}.mail.protection.outlook.com"
}

########################
# Xác minh domain
########################

resource "aws_route53_record" "ms_verification" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "acme.com"
  type     = "TXT"
  ttl      = 3600

  records = [
    var.m365_verification_txt,               # "MS=ms12345678"
    "v=spf1 include:spf.protection.outlook.com -all",
  ]
}
```

> Bản ghi TXT tại apex phải gộp **tất cả** giá trị vào một resource Route 53 duy nhất – tạo hai `aws_route53_record` cùng name/type sẽ đè lên nhau. Nếu sau này thêm SPF của bên thứ ba (SendGrid, Zendesk…), sửa chuỗi `v=spf1` này chứ đừng thêm bản ghi TXT thứ hai.

```hcl
########################
# Exchange Online
########################

resource "aws_route53_record" "mx" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "acme.com"
  type     = "MX"
  ttl      = 3600
  records  = ["0 ${local.mx_host}"]
}

resource "aws_route53_record" "autodiscover" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "autodiscover.acme.com"
  type     = "CNAME"
  ttl      = 3600
  records  = ["autodiscover.outlook.com"]
}

########################
# DKIM – bật trong Exchange admin center sau khi tạo 2 CNAME này
########################

resource "aws_route53_record" "dkim1" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "selector1._domainkey.acme.com"
  type     = "CNAME"
  ttl      = 3600
  records  = ["selector1-acme-com._domainkey.${var.m365_tenant}.onmicrosoft.com"]
}

resource "aws_route53_record" "dkim2" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "selector2._domainkey.acme.com"
  type     = "CNAME"
  ttl      = 3600
  records  = ["selector2-acme-com._domainkey.${var.m365_tenant}.onmicrosoft.com"]
}

########################
# DMARC – bắt đầu p=none để quan sát, siết dần
########################

resource "aws_route53_record" "dmarc" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "_dmarc.acme.com"
  type     = "TXT"
  ttl      = 3600
  records  = ["v=DMARC1; p=none; rua=mailto:dmarc-reports@acme.com; fo=1"]
}

########################
# Entra ID – device join & Intune enrollment
########################

resource "aws_route53_record" "enterpriseregistration" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "enterpriseregistration.acme.com"
  type     = "CNAME"
  ttl      = 3600
  records  = ["enterpriseregistration.windows.net"]
}

resource "aws_route53_record" "enterpriseenrollment" {
  provider = aws.network
  zone_id  = aws_route53_zone.public.zone_id
  name     = "enterpriseenrollment.acme.com"
  type     = "CNAME"
  ttl      = 3600
  records  = ["enterpriseenrollment.manage.microsoft.com"]
}
```

Bảng tra nhanh các bản ghi M365:

| Bản ghi | Type | Giá trị | Bắt buộc khi |
|---|---|---|---|
| `acme.com` | TXT | `MS=ms…` | Xác minh domain |
| `acme.com` | TXT | `v=spf1 include:spf.protection.outlook.com -all` | Gửi mail |
| `acme.com` | MX | `0 acme-com.mail.protection.outlook.com` | Nhận mail |
| `autodiscover` | CNAME | `autodiscover.outlook.com` | Outlook tự cấu hình |
| `selector1/2._domainkey` | CNAME | `selectorN-acme-com._domainkey.<tenant>.onmicrosoft.com` | Bật DKIM |
| `_dmarc` | TXT | `v=DMARC1; p=…` | Chống giả mạo |
| `enterpriseregistration` | CNAME | `enterpriseregistration.windows.net` | Hybrid Entra join |
| `enterpriseenrollment` | CNAME | `enterpriseenrollment.manage.microsoft.com` | Intune |
| `sip`, `lyncdiscover`, 2 SRV | CNAME/SRV | `sipdir.online.lync.com`, … | **Chỉ** khi còn Skype for Business |

Tenant Teams-only (đại đa số hiện nay) **không cần** nhóm bản ghi SIP/SRV cuối bảng. Lấy danh sách chính xác cho tenant của bạn ở Microsoft 365 admin center → Settings → Domains → DNS records.

### 10.2. Hybrid identity – nối AD on-prem với Entra ID

Nếu đồng bộ user từ `corp.acme.local` lên Entra ID bằng **Entra Connect** (tên cũ: Azure AD Connect):

**Vấn đề UPN suffix.** Domain nội bộ là `.local` – không routable, Microsoft không xác minh được. User sẽ bị sync thành `user@acme.onmicrosoft.com`, đăng nhập M365 khác username Windows, rất phiền. Xử lý trước khi sync:

```powershell
# Tren DC: them UPN suffix routable
Get-ADForest | Set-ADForest -UPNSuffixes @{ Add = "acme.com" }

# Doi UPN cho user (lam theo lo, test truoc voi 1 OU)
Get-ADUser -Filter * -SearchBase "OU=Staff,DC=corp,DC=acme,DC=local" |
    ForEach-Object {
        $newUpn = "$($_.SamAccountName)@acme.com"
        Set-ADUser -Identity $_ -UserPrincipalName $newUpn
        Write-Host "$($_.SamAccountName) -> $newUpn"
    }
```

**Đặt Entra Connect ở đâu.** Server chạy Entra Connect cần: resolve được `corp.acme.local`, tới được DC qua LDAP/Kerberos, và ra được Internet tới `*.msappproxy.net`, `login.microsoftonline.com`. Hai lựa chọn:

| Vị trí | Ưu | Nhược |
|---|---|---|
| On-premise (gần DC) | Độ trễ thấp tới DC, đơn giản | Phụ thuộc hạ tầng on-prem |
| EC2 trong AWS | Nằm trong LZ, backup/patch theo chuẩn AWS | Mọi lệnh gọi DC đi qua Direct Connect |

Nếu đặt trên EC2, server đó cần resolver rule `corp.acme.local` ở mục 4 (đã có sẵn) và phải join domain.

### 10.3. Đừng hairpin traffic M365 qua NAT tập trung

Ở doc 06 mục 11 ta dựng **centralized egress**: mọi traffic ra Internet đi qua NAT Gateway ở network account. Với M365 thì đây là anti-pattern – Microsoft khuyến nghị **local breakout** cho nhóm endpoint "Optimize" (Exchange Online, Teams media, SharePoint). Đẩy traffic Teams qua TGW → NAT tập trung → Internet sẽ làm tăng latency, vỡ chất lượng thoại/video, và tốn phí NAT.

Nếu có workload trong AWS gọi M365 nhiều (ví dụ VDI, WorkSpaces, mail relay), tách đường ra riêng:

```hcl
# Route table cho subnet chay VDI/WorkSpaces:
# M365 di thang IGW cua VPC do, phan con lai qua TGW ve egress tap trung
resource "aws_route" "default_via_tgw" {
  provider               = aws.app_prod
  route_table_id         = var.vdi_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id
}

# Local breakout cho dai IP cua M365 "Optimize"
# Lay danh sach dong tu Microsoft 365 IP Address and URL Web Service:
#   https://endpoints.office.com/endpoints/worldwide?clientrequestid=<guid>
resource "aws_route" "m365_local_breakout" {
  provider               = aws.app_prod
  for_each               = toset(var.m365_optimize_cidrs)
  route_table_id         = var.vdi_route_table_id
  destination_cidr_block = each.value
  nat_gateway_id         = var.local_nat_gateway_id
}
```

Danh sách CIDR của M365 thay đổi định kỳ – nên có Lambda chạy hàng tuần kéo từ endpoint web service của Microsoft rồi cập nhật prefix list, thay vì hardcode.

---

## 11. DNS Firewall và Query Logging

### 11.1. 6-dns/firewall.tf

```hcl
resource "aws_route53_resolver_firewall_domain_list" "blocked" {
  provider = aws.network
  name     = "acme-blocked-domains"

  domains = [
    "*.bit",
    "*.onion",
    "*.duckdns.org",  # dynamic DNS hay bị dùng cho C2
    "*.no-ip.com",
  ]
}

# Domain nội bộ luôn cho qua, đặt priority thấp nhất để chạy trước
resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  provider = aws.network
  name     = "acme-allowed-domains"

  domains = [
    "corp.acme.local",
    "aws.acme.internal",
    "acme.com",
    "*.acme.com",
    # M365 – tuyệt đối đừng chặn nhầm
    "*.outlook.com",
    "*.office.com",
    "*.office365.com",
    "*.microsoftonline.com",
    "*.sharepoint.com",
    "*.teams.microsoft.com",
    "*.windows.net",
  ]
}

resource "aws_route53_resolver_firewall_rule_group" "main" {
  provider = aws.network
  name     = "acme-dns-firewall"
}

resource "aws_route53_resolver_firewall_rule" "allow_internal" {
  provider                = aws.network
  name                    = "allow-internal-and-m365"
  action                  = "ALLOW"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.allowed.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.main.id
  priority                = 100
}

resource "aws_route53_resolver_firewall_rule" "block_bad" {
  provider                = aws.network
  name                    = "block-known-bad"
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.blocked.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.main.id
  priority                = 200
}

resource "aws_route53_resolver_firewall_rule_group_association" "hub" {
  provider               = aws.network
  name                   = "hub-vpc"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.main.id
  vpc_id                 = data.aws_vpc.hub.id
  priority               = 101
}
```

AWS còn có managed domain list (`AWSManagedDomainsMalwareDomainList`, `AWSManagedDomainsBotnetCommandandControl`) – lấy ID bằng `aws route53resolver list-firewall-domain-lists` rồi tham chiếu vào rule.

> Roll out DNS Firewall bằng `action = "ALERT"` trước, xem query log vài ngày rồi mới đổi sang `BLOCK`. Block nhầm một domain M365 sẽ làm cả công ty mất Outlook.

### 11.2. 6-dns/logging.tf

```hcl
resource "aws_route53_resolver_query_log_config" "main" {
  provider       = aws.network
  name           = "acme-dns-query-log"
  destination_arn = "arn:aws:s3:::acme-dns-logs-${var.log_archive_account_id}"
}

resource "aws_route53_resolver_query_log_config_association" "hub" {
  provider                     = aws.network
  resolver_query_log_config_id = aws_route53_resolver_query_log_config.main.id
  resource_id                  = data.aws_vpc.hub.id
}

# Share cấu hình log cho cả org để VPC ở account khác gắn vào
resource "aws_ram_resource_association" "query_log" {
  provider           = aws.network
  resource_arn       = aws_route53_resolver_query_log_config.main.arn
  resource_share_arn = aws_ram_resource_share.dns.arn
}
```

Query log là nguồn dữ liệu điều tra rất giá trị: máy nào đang gọi domain lạ, ai vẫn còn trỏ về server đã tắt, ứng dụng nào vẫn dùng tên cũ trước khi migrate.

---

## 12. Chi phí ước tính

Số tham khảo, region ap-southeast-1 (kiểm tra lại bằng AWS Pricing Calculator):

| Hạng mục | Đơn giá | Ước tính / tháng |
|---|---|---|
| Resolver **inbound** endpoint (2 ENI) | ~$0.125/ENI/giờ | ~$180 |
| Resolver **outbound** endpoint (2 ENI) | ~$0.125/ENI/giờ | ~$180 |
| Resolver query (forward ra ngoài) | ~$0.40 / triệu query | vài $ |
| Private Hosted Zone | ~$0.50/zone | ~$0.50 |
| Public Hosted Zone | ~$0.50/zone | ~$0.50 |
| DNS Firewall | ~$0.60 / triệu query + phí rule group | ~$10–30 |
| Query logging (S3) | Phí S3 thường | vài $ |
| AWS Managed Microsoft AD (Standard) | ~$0.12/giờ | ~$88 |
| AWS Managed Microsoft AD (Enterprise) | ~$0.40/giờ | ~$292 |

Riêng hai resolver endpoint đã ~**$360/tháng** – khoản đắt nhất trong cả Landing Zone. Cách cắt:

- **Bỏ inbound endpoint** nếu on-prem không cần resolve tên AWS. Rất nhiều tổ chức chỉ cần chiều outbound.
- **Dùng chung endpoint cho toàn org.** Endpoint đặt một lần ở network account, share rule qua RAM – đừng dựng endpoint riêng ở mỗi account (lỗi này nhân chi phí lên theo số account).
- Endpoint là **per-region**. Chỉ dựng ở region thực sự có workload.

---

## 13. Kiểm tra

### 13.1. Từ EC2 trong AWS

```bash
# Resolve tên AD on-prem (đi qua outbound endpoint)
dig +short dc1.corp.acme.local
nslookup corp.acme.local

# SRV record của AD – bắt buộc phải ra kết quả thì mới join domain được
dig +short SRV _ldap._tcp.dc._msdcs.corp.acme.local
dig +short SRV _kerberos._tcp.corp.acme.local

# Private Hosted Zone
dig +short artifacts.aws.acme.internal

# Reverse lookup về on-prem
dig +short -x 10.1.0.10

# Public / M365 vẫn phải resolve bình thường
dig +short MX acme.com
dig +short autodiscover.acme.com

# Test join domain
sudo realm discover corp.acme.local
```

### 13.2. Từ Windows on-premise

```powershell
# Resolve tên AWS qua inbound endpoint
Resolve-DnsName artifacts.aws.acme.internal
Resolve-DnsName artifacts.aws.acme.internal -Server 10.0.1.10   # hỏi thẳng endpoint

# Kiểm tra conditional forwarder đang trỏ đâu
Get-DnsServerZone | Where-Object ZoneType -eq "Forwarder" |
    Select-Object ZoneName, MasterServers

# Kiểm tra bản ghi M365 (hỏi DNS public, không qua DC)
Resolve-DnsName acme.com -Type MX -Server 8.8.8.8
Resolve-DnsName selector1._domainkey.acme.com -Type CNAME -Server 8.8.8.8
Resolve-DnsName _dmarc.acme.com -Type TXT -Server 8.8.8.8

# Sức khoẻ AD/DNS tổng thể
dcdiag /test:dns /v
```

### 13.3. Kiểm tra M365 phía Microsoft

- Microsoft 365 admin center → **Settings → Domains → acme.com → Check health**: đối chiếu từng bản ghi kỳ vọng với thực tế.
- **Exchange admin center → Mail flow → DKIM**: bật sau khi 2 CNAME đã propagate (có thể mất tới 1 giờ).
- Gửi thử một mail ra ngoài, xem header người nhận: `spf=pass`, `dkim=pass`, `dmarc=pass`.

### 13.4. Đọc query log

```bash
aws s3 ls s3://acme-dns-logs-222222222222/AWSLogs/ --recursive --profile log-archive | head

# Query bằng Athena
# SELECT query_name, count(*) AS c
# FROM dns_query_logs
# WHERE query_timestamp > current_timestamp - interval '1' day
# GROUP BY query_name ORDER BY c DESC LIMIT 50;
```

---

## 14. Bẫy hay gặp

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| EC2 join domain fail, `dig SRV` không ra | Rule forward chưa associate với VPC của EC2, hoặc SG outbound chưa mở tới DC |
| DNS "lúc được lúc không" | Forwarding loop – cả hai đầu cùng forward một zone cho nhau |
| Query lớn bị timeout, query nhỏ OK | Firewall chỉ mở UDP 53, thiếu TCP 53 |
| Sau khi tạo PHZ `acme.com`, Outlook hỏng | Split-brain – PHZ chiếm apex, che mất bản ghi M365. Dùng subdomain |
| On-prem không resolve được tên AWS | Chưa tạo conditional forwarder, hoặc IP inbound endpoint đã đổi |
| Trust với on-prem tạo không được | DNS hai chiều chưa thông trước khi tạo trust |
| User sync lên M365 thành `@onmicrosoft.com` | UPN suffix vẫn là `.local`, chưa thêm suffix routable |
| Terraform gỡ mất VPC association của account khác | Thiếu `lifecycle { ignore_changes = [vpc] }` trên `aws_route53_zone` |
| Teams giật, latency cao | Traffic M365 bị hairpin qua NAT tập trung thay vì local breakout |
| Hoá đơn Route 53 Resolver cao bất thường | Mỗi account dựng endpoint riêng thay vì share qua RAM |

---

## 15. Thứ tự triển khai

```bash
# 0. Chuẩn bị: Direct Connect/VPN đã thông, firewall đã mở TCP+UDP 53 hai chiều

# 1. Dựng resolver endpoint + rules
cd 6-dns
terraform init
terraform apply -target=aws_route53_resolver_endpoint.inbound \
                -target=aws_route53_resolver_endpoint.outbound
terraform output inbound_endpoint_ips

# 2. Cấu hình conditional forwarder trên AD (chạy PowerShell ở mục 7.1)
#    -> test Resolve-DnsName trước khi đi tiếp

# 3. Apply phần còn lại: rules, PHZ, RAM share
terraform apply

# 4. Associate rule vào từng VPC workload (hoặc gắn Route 53 Profile)

# 5. Public hosted zone cho M365
#    -> đổi NS tại nhà đăng ký domain sang NS của Route 53
#    -> chờ propagate, verify trong M365 admin center

# 6. DNS Firewall: bật ALERT trước, quan sát 3–7 ngày, rồi mới BLOCK

# 7. Bật query logging
```

Bước 5 là bước duy nhất có rủi ro downtime thật với người dùng cuối. Trước khi đổi NS: hạ TTL các bản ghi hiện tại xuống 300s và chờ ít nhất một chu kỳ TTL cũ, đối chiếu từng bản ghi giữa zone cũ và zone Route 53 mới, đổi NS ngoài giờ làm việc.

---

## 16. Hướng mở rộng

- **DNSSEC** cho public hosted zone – Route 53 hỗ trợ ký, cần bật DS record ở nhà đăng ký.
- **Prefix list tự động cho M365**: Lambda chạy hàng tuần gọi `https://endpoints.office.com/endpoints/worldwide` rồi cập nhật `aws_ec2_managed_prefix_list`, thay cho CIDR hardcode ở mục 10.3.
- **Multi-region**: resolver endpoint theo từng region, rule share qua RAM cho region đó; PHZ thì global nên associate được VPC nhiều region.
- **Failover khi đứt Direct Connect**: dựng Managed AD trong AWS (mục 9) để auth không phụ thuộc link, hoặc đặt thêm read-only DC trên EC2.
- **Giám sát**: CloudWatch alarm cho `InboundQueryVolume` / `OutboundQueryAggregateVolume` của resolver endpoint; EventBridge bắt finding DNS Firewall severity cao → SNS → Slack (dùng lại pattern alert ở [ví dụ 01](./01-Example-Aws-Serverless-Order-API.md)).
- **Bỏ dần `.local`**: nếu có kế hoạch dài hạn, migrate AD sang subdomain routable (`ad.acme.com`) để hết vướng cả với M365 lẫn chứng chỉ TLS nội bộ.
