# DNS tập trung và VPC Endpoint tập trung – môi trường thuần AWS

Ví dụ 12: Phiên bản **không có on-premise, không có AD, không có Microsoft 365** của [07 – Centralized DNS](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md). Toàn bộ hạ tầng nằm trên AWS.

Đọc doc này thay cho doc 07 nếu bạn đang ở tình huống đó. Doc 07 vẫn hữu ích khi nào công ty đấu nối on-premise.

---

## 1. Bỏ được những gì

| Thành phần trong doc 07 | Còn cần? | Tiết kiệm/tháng |
|---|---|---|
| Route 53 Resolver **inbound** endpoint | ❌ Không có on-prem nào query vào | ~$180 |
| Route 53 Resolver **outbound** endpoint | ❌ Không có DC nào để forward tới | ~$180 |
| Resolver forward rules | ❌ | — |
| Conditional forwarder trên AD DNS | ❌ | — |
| AWS Managed Microsoft AD + trust | ❌ | ~$88 |
| Public hosted zone cho M365 | ❌ | — |
| **Private Hosted Zone nội bộ** | ✅ Vẫn cần | ~$0.50 |
| **DNS Firewall** | ✅ Nên có | ~$10–30 |
| **Query logging** | ✅ Nên có | vài $ |
| **VPC Endpoint** | ✅ Phần chính của bài này | xem mục 6 |

Tiết kiệm khoảng **$360–450/tháng** so với thiết kế hybrid. Đây là khác biệt rất lớn với một LZ mới.

Lý do đơn giản: resolver endpoint chỉ tồn tại để **bắc cầu giữa AWS và mạng ngoài**. Không có mạng ngoài thì Route 53 Resolver mặc định (địa chỉ `VPC CIDR + 2`) đã làm đủ mọi việc — nó resolve được Private Hosted Zone, tên VPC endpoint, và DNS public, mà không tốn đồng nào.

---

## 2. Trước khi làm: bạn có thực sự cần không?

Đây là câu hỏi quan trọng nhất của cả bài, vì VPC endpoint tập trung là thứ **dễ tiêu tiền hơn tiết kiệm tiền** nếu áp dụng sai lúc.

```text
Workload của bạn là gì?
│
├─ Serverless thuần (Lambda KHÔNG đặt trong VPC, API GW, DynamoDB, SQS…)
│     → Không cần VPC endpoint. Không cần TGW. Không cần gì cả.
│     → Chỉ làm phần DNS ở mục 4 (PHZ), bỏ qua mục 5.
│     → Đây là trường hợp của ví dụ 01–05 trong repo này.
│
├─ Có Lambda-in-VPC / EC2 / ECS / EKS / RDS
│     │
│     ├─ 1–3 VPC?
│     │     → Tạo interface endpoint TRỰC TIẾP trong từng VPC.
│     │     → Đơn giản hơn, và thường RẺ HƠN (xem mục 6).
│     │
│     └─ Nhiều VPC (5+) và ĐÃ có TGW vì lý do khác?
│           → Lúc này centralize mới đáng. Làm theo mục 5.
│
└─ Chưa chắc
      → Bắt đầu bằng endpoint per-VPC. Chuyển sang tập trung sau
        cũng được, không phải quyết định một chiều.
```

Nói thẳng điều mà nhiều bài viết về "hub-and-spoke VPC endpoints" bỏ qua: **centralize chỉ có lãi khi bạn đã trả tiền TGW cho việc khác.** Dựng TGW *chỉ để* dùng chung VPC endpoint gần như luôn lỗ, vì riêng phí attachment ($36.50/VPC/tháng) đã đắt hơn phần tiết kiệm được.

---

## 3. Kiến trúc

```text
┌──────────────────── network / shared-services account ─────────────────────┐
│                                                                            │
│   Shared Services VPC  10.0.0.0/16                                         │
│   ┌──────────────────────────────────────────────────────────┐             │
│   │  Interface Endpoints (ENI ở 2 AZ)                        │             │
│   │   • secretsmanager   • kms         • logs                │             │
│   │   • ssm/ssmmessages/ec2messages    • ecr.api/ecr.dkr     │             │
│   │   • sts              • lambda      • execute-api*        │             │
│   └──────────────────────┬───────────────────────────────────┘             │
│                          │                                                 │
│   Private Hosted Zones (một PHZ cho mỗi service endpoint)                  │
│   + PHZ nội bộ  aws.acme.internal                                          │
│                          │                                                 │
│                   Route 53 Profile  ──── RAM share cho cả org              │
│                          │                                                 │
└──────────────────────────┼─────────────────────────────────────────────────┘
                           │
                    Transit Gateway
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
┌───────▼────────┐ ┌───────▼────────┐ ┌───────▼────────┐
│ app-dev VPC    │ │ app-prod VPC   │ │ data VPC       │
│ 10.10.0.0/16   │ │ 10.20.0.0/16   │ │ 10.30.0.0/16   │
│                │ │                │ │                │
│ Gateway EP:    │ │ Gateway EP:    │ │ Gateway EP:    │
│  S3, DynamoDB  │ │  S3, DynamoDB  │ │  S3, DynamoDB  │
│  (MIỄN PHÍ,    │ │  (MIỄN PHÍ,    │ │  (MIỄN PHÍ,    │
│   luôn per-VPC)│ │   luôn per-VPC)│ │   luôn per-VPC)│
└────────────────┘ └────────────────┘ └────────────────┘
```

Hai loại endpoint hoạt động hoàn toàn khác nhau, và đây là chỗ hay nhầm:

| | Gateway Endpoint | Interface Endpoint |
|---|---|---|
| Service | Chỉ **S3** và **DynamoDB** | Hầu hết service còn lại |
| Cơ chế | Route table entry (prefix list) | ENI có IP riêng trong subnet |
| Chi phí | **$0** — miễn phí hoàn toàn | ~$7.30/AZ/tháng + $0.01/GB |
| Dùng chung được không | ❌ **Không** — phải tạo ở từng VPC | ✅ Có, qua TGW |
| Cross-VPC | Không hoạt động | Hoạt động |

Vì gateway endpoint **miễn phí** và **không chia sẻ được**, quy tắc luôn đúng: **tạo S3 + DynamoDB gateway endpoint trong mọi VPC**, không có lý do gì để không làm.

---

## 4. Phần DNS – đơn giản hơn nhiều

### 4.1. Không gian tên

Chỉ còn hai:

| Namespace | Ví dụ | Ở đâu |
|---|---|---|
| Nội bộ AWS | `aws.acme.internal` | Private Hosted Zone |
| Public | `acme.com` | Public Hosted Zone (web, API công khai) |

Vẫn giữ nguyên nguyên tắc quan trọng nhất từ doc 07: **đừng tạo PHZ trùng tên domain public**. Dùng `aws.acme.internal` hoặc `aws.acme.com`, đừng chiếm `acme.com`.

### 4.2. Private Hosted Zone

```hcl
# 6-dns/main.tf
variable "network_account_id"  { type = string }
variable "organization_arn"    { type = string }
variable "organization_id"     { type = string }
variable "region"              { default = "ap-southeast-1" }

provider "aws" {
  alias  = "network"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.network_account_id}:role/OrganizationAccountAccessRole"
  }
}

data "aws_vpc" "shared" {
  provider = aws.network
  tags     = { Name = "acme-shared-services-vpc" }
}

resource "aws_route53_zone" "internal" {
  provider = aws.network
  name     = "aws.acme.internal"
  comment  = "Ten noi bo cho resource trong AWS"

  vpc {
    vpc_id = data.aws_vpc.shared.id
  }

  # BẮT BUỘC: association từ account khác quản lý bằng resource riêng
  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "internal_records" {
  provider = aws.network
  for_each = {
    artifacts = { type = "CNAME", records = ["acme-artifacts.s3.${var.region}.amazonaws.com"] }
    metrics   = { type = "CNAME", records = ["internal-metrics-nlb-xxx.elb.${var.region}.amazonaws.com"] }
  }

  zone_id = aws_route53_zone.internal.zone_id
  name    = "${each.key}.aws.acme.internal"
  type    = each.value.type
  ttl     = 300
  records = each.value.records
}
```

### 4.3. Chia sẻ PHZ – dùng Route 53 Profiles

Không có on-prem thì công việc DNS chủ yếu còn lại là **gắn PHZ vào nhiều VPC ở nhiều account**. Làm thủ công từng cặp (authorization + association) rất mệt khi có 10 PHZ × 10 VPC.

Route 53 Profiles gói tất cả lại thành một object, share một lần:

```hcl
# 6-dns/profile.tf

resource "aws_route53profiles_profile" "shared" {
  provider = aws.network
  name     = "acme-shared-dns"

  tags = { Name = "acme-shared-dns" }
}

# Gắn PHZ nội bộ vào profile
resource "aws_route53profiles_resource_association" "internal" {
  provider     = aws.network
  name         = "internal-phz"
  profile_id   = aws_route53profiles_profile.shared.id
  resource_arn = aws_route53_zone.internal.arn
}

# Gắn toàn bộ PHZ của VPC endpoint (tạo ở mục 5)
resource "aws_route53profiles_resource_association" "endpoints" {
  provider     = aws.network
  for_each     = aws_route53_zone.endpoint

  name         = "endpoint-${each.key}"
  profile_id   = aws_route53profiles_profile.shared.id
  resource_arn = each.value.arn
}

# Gắn DNS Firewall vào cùng profile
resource "aws_route53profiles_resource_association" "firewall" {
  provider     = aws.network
  name         = "dns-firewall"
  profile_id   = aws_route53profiles_profile.shared.id
  resource_arn = aws_route53_resolver_firewall_rule_group.main.arn
}

########################
# Share profile cho cả org
########################

resource "aws_ram_resource_share" "dns" {
  provider                  = aws.network
  name                      = "acme-dns-profile"
  allow_external_principals = false
}

resource "aws_ram_resource_association" "profile" {
  provider           = aws.network
  resource_arn       = aws_route53profiles_profile.shared.arn
  resource_share_arn = aws_ram_resource_share.dns.arn
}

resource "aws_ram_principal_association" "org" {
  provider           = aws.network
  principal          = var.organization_arn
  resource_share_arn = aws_ram_resource_share.dns.arn
}
```

Bên account workload, mỗi VPC chỉ cần **một dòng**:

```hcl
resource "aws_route53profiles_association" "spoke" {
  provider    = aws.app_prod
  name        = "app-prod-vpc"
  profile_id  = var.shared_dns_profile_id
  resource_id = var.app_prod_vpc_id
}
```

Hai giới hạn cần nhớ:

- **Một VPC chỉ gắn được một Profile.** Nên gom tất cả vào một profile chung, đừng tách nhiều profile theo chủ đề.
- Route 53 Profiles còn khá mới — cần AWS provider `~> 5.60` trở lên.

Nếu vì lý do nào đó chưa dùng được Profiles, cách cũ vẫn chạy:

```hcl
resource "aws_route53_vpc_association_authorization" "app_prod" {
  provider = aws.network
  zone_id  = aws_route53_zone.internal.zone_id
  vpc_id   = var.app_prod_vpc_id
}

resource "aws_route53_zone_association" "app_prod" {
  provider = aws.app_prod
  zone_id  = aws_route53_vpc_association_authorization.app_prod.zone_id
  vpc_id   = aws_route53_vpc_association_authorization.app_prod.vpc_id
}
```

Chỉ là bạn phải nhân số dòng này lên `số PHZ × số VPC`.

---

## 5. VPC Endpoint tập trung

### 5.1. Chọn endpoint nào

Đừng tạo hết mọi service. Chỉ tạo cái workload thật sự gọi tới:

| Endpoint | Khi nào cần | Ghi chú |
|---|---|---|
| `s3` (**Gateway**) | Luôn luôn | Miễn phí, tạo ở mọi VPC |
| `dynamodb` (**Gateway**) | Luôn luôn | Miễn phí, tạo ở mọi VPC |
| `ssm`, `ssmmessages`, `ec2messages` | Dùng Session Manager | **Cần cả ba**, thiếu một là không vào được |
| `ecr.api`, `ecr.dkr` | Chạy container | **Cộng thêm S3 gateway** để tải image layer |
| `logs` | Ghi CloudWatch Logs từ trong VPC | |
| `secretsmanager` | Đọc secret | |
| `kms` | Giải mã bằng KMS | |
| `sts` | Assume role trong VPC | SDK phải dùng STS regional |
| `lambda` | Gọi Lambda từ trong VPC | |
| `sqs`, `sns` | Gọi từ Lambda-in-VPC / EC2 | |
| `execute-api` | Gọi **private** API Gateway | ⚠️ Xem cảnh báo mục 7 |
| `monitoring` | PutMetricData | |

Ba bộ ba hay bị thiếu, gây lỗi rất khó đoán:

- **Session Manager**: thiếu `ssmmessages` → agent online nhưng không mở được session.
- **ECR**: có `ecr.api` + `ecr.dkr` nhưng thiếu **S3 gateway endpoint** → `docker pull` xác thực xong rồi treo ở bước tải layer, vì layer nằm trong S3.
- **CloudWatch**: `logs` (ghi log) và `monitoring` (ghi metric) là hai endpoint khác nhau.

### 5.2. Interface endpoint tập trung

```hcl
# 6-dns/endpoints.tf

locals {
  # Endpoint đặt tập trung ở shared services VPC
  central_endpoints = toset([
    "secretsmanager",
    "kms",
    "logs",
    "monitoring",
    "sts",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "ecr.api",
    "ecr.dkr",
    "lambda",
    "sqs",
  ])

  # Tên PHZ khác tên service với một số endpoint
  endpoint_zone_name = {
    "ecr.api" = "api.ecr"
    "ecr.dkr" = "dkr.ecr"
  }

  # Dải mạng của toàn bộ spoke VPC
  spoke_cidrs = ["10.10.0.0/16", "10.20.0.0/16", "10.30.0.0/16"]
}

########################
# Security Group
########################

resource "aws_security_group" "endpoints" {
  provider    = aws.network
  name        = "vpc-endpoints"
  description = "Cho phep spoke VPC goi vao interface endpoint"
  vpc_id      = data.aws_vpc.shared.id

  ingress {
    description = "HTTPS tu cac spoke VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.spoke_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vpc-endpoints" }
}

########################
# Interface endpoints
########################

resource "aws_vpc_endpoint" "central" {
  provider = aws.network
  for_each = local.central_endpoints

  vpc_id            = data.aws_vpc.shared.id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = var.shared_private_subnet_ids   # >= 2 AZ
  security_group_ids = [aws_security_group.endpoints.id]

  # TẮT private DNS: ta tự quản PHZ để share cho mọi VPC.
  # Bật true chỉ tạo PHZ cho riêng VPC này -> spoke không dùng được.
  private_dns_enabled = false

  # Chỉ account trong org mới gọi được qua endpoint này
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = var.organization_id
        }
      }
    }]
  })

  tags = { Name = "vpce-${each.value}" }
}

########################
# PHZ cho mỗi endpoint
########################

resource "aws_route53_zone" "endpoint" {
  provider = aws.network
  for_each = local.central_endpoints

  name    = "${lookup(local.endpoint_zone_name, each.value, each.value)}.${var.region}.amazonaws.com"
  comment = "PHZ cho VPC endpoint ${each.value}"

  vpc {
    vpc_id = data.aws_vpc.shared.id
  }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "endpoint_apex" {
  provider = aws.network
  for_each = local.central_endpoints

  zone_id = aws_route53_zone.endpoint[each.value].zone_id
  name    = aws_route53_zone.endpoint[each.value].name
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.central[each.value].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.central[each.value].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}

# Một số service dùng subdomain (vd: <account>.dkr.ecr.<region>.amazonaws.com)
resource "aws_route53_record" "endpoint_wildcard" {
  provider = aws.network
  for_each = local.central_endpoints

  zone_id = aws_route53_zone.endpoint[each.value].zone_id
  name    = "*.${aws_route53_zone.endpoint[each.value].name}"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.central[each.value].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.central[each.value].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = false
  }
}
```

> `dns_entry[0]` theo quy ước là bản ghi DNS regional, và đây là cách viết phổ biến. Thứ tự phần tử trong `dns_entry` không được AWS cam kết — sau lần apply đầu tiên, chạy `terraform state show` kiểm tra một lần cho chắc.

### 5.3. Gateway endpoint – ở từng VPC, miễn phí

```hcl
# Chạy trong TỪNG account/VPC workload
resource "aws_vpc_endpoint" "s3_gateway" {
  provider          = aws.app_prod
  vpc_id            = var.app_prod_vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.app_prod_private_route_table_ids

  tags = { Name = "vpce-s3-gateway" }
}

resource "aws_vpc_endpoint" "dynamodb_gateway" {
  provider          = aws.app_prod
  vpc_id            = var.app_prod_vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.app_prod_private_route_table_ids

  tags = { Name = "vpce-dynamodb-gateway" }
}
```

Đưa hai resource này vào module `account-baseline` ([doc 06 mục 12](./06-Aws-Landing-Zone.md)) để mọi VPC mới đều có sẵn. Miễn phí, giảm chi phí NAT, không có lý do bỏ qua.

---

## 6. Bài toán chi phí – tính trước khi làm

Đơn giá tham khảo (ap-southeast-1, kiểm tra lại bằng Pricing Calculator):

| Khoản | Đơn giá | Quy đổi tháng |
|---|---|---|
| Interface endpoint | ~$0.01/AZ/giờ | ~$7.30/AZ → **$14.60** (2 AZ) |
| Interface endpoint data | ~$0.01/GB | |
| TGW attachment | ~$0.05/giờ | **$36.50**/VPC |
| TGW data processing | ~$0.02/GB | |
| Gateway endpoint | **$0** | **$0** |

### 6.1. Điểm hoà vốn

Với `N` VPC, mỗi VPC cần `E` interface endpoint:

```
Per-VPC:      N × E × $14.60
Tập trung:    E × $14.60  +  N × $36.50  +  phí data qua TGW
```

Bảng kết quả (chưa tính data processing, tức là đã ưu ái phương án tập trung):

| Endpoint/VPC | Số VPC hoà vốn | Nhận xét |
|---|---|---|
| 3 endpoint | ~6 VPC | Ít endpoint → tập trung hiếm khi lãi |
| 5 endpoint | ~3 VPC | |
| 10 endpoint | ~2 VPC | Nhiều endpoint → tập trung lãi sớm |
| 15 endpoint | ~2 VPC | |

Ví dụ cụ thể, 5 VPC × 10 endpoint:

```
Per-VPC:    5 × 10 × $14.60  = $730/tháng
Tập trung:  10 × $14.60      = $146
          + 5 × $36.50       = $182.50
                             = $328.50/tháng  (+ data)
→ Tiết kiệm ~$400/tháng
```

Ngược lại, 2 VPC × 3 endpoint:

```
Per-VPC:    2 × 3 × $14.60   = $87.60/tháng
Tập trung:  3 × $14.60       = $43.80
          + 2 × $36.50       = $73.00
                             = $116.80/tháng  (+ data)
→ ĐẮT HƠN $29/tháng, lại phức tạp hơn nhiều
```

**Nếu TGW đã tồn tại sẵn** vì lý do khác (kết nối giữa các VPC), bỏ cột `N × $36.50` ra khỏi phép tính — lúc đó tập trung gần như luôn lãi.

### 6.2. Đừng quên phí data processing

Traffic đi từ spoke qua TGW tới endpoint bị tính **hai lần**: TGW data processing (~$0.02/GB) + endpoint data processing (~$0.01/GB). Với workload đọc secret/ghi log lượng nhỏ thì không đáng kể. Với workload kéo image ECR hàng chục GB mỗi ngày thì đây là khoản đáng kể — và đó chính là lý do **layer image nên đi qua S3 gateway endpoint (miễn phí, tại chỗ)** thay vì vòng qua hub.

---

## 7. Bẫy hay gặp

| Vấn đề | Nguyên nhân | Cách xử lý |
|---|---|---|
| **PHZ `execute-api` nuốt mọi API Gateway** | PHZ chiếm cả namespace trong VPC associated → API public trong region đó cũng resolve về endpoint | Chỉ associate PHZ này với VPC thật sự cần private API |
| `docker pull` treo ở bước tải layer | Có `ecr.api`+`ecr.dkr` nhưng thiếu **S3 gateway** | Thêm S3 gateway ở VPC đó |
| Session Manager không mở được session | Thiếu `ssmmessages` | Cần đủ `ssm` + `ssmmessages` + `ec2messages` |
| Gọi API vẫn đi qua NAT, hoá đơn NAT không giảm | VPC chưa được associate PHZ của endpoint | Kiểm tra `dig` trả về IP private hay public |
| Timeout khi gọi endpoint | SG của endpoint chưa mở 443 từ CIDR spoke | Cập nhật `local.spoke_cidrs` |
| Phí cross-AZ tăng bất thường | Spoke ở AZ-a gọi ENI endpoint ở AZ-b | Tạo endpoint ENI ở **mọi AZ** mà spoke đang dùng |
| Terraform gỡ mất association của account khác | Thiếu `lifecycle { ignore_changes = [vpc] }` | Thêm vào mọi `aws_route53_zone` |
| VPC không gắn được Profile thứ hai | Giới hạn 1 profile/VPC | Gom mọi thứ vào một profile |
| Bật `private_dns_enabled = true` rồi spoke không dùng được | PHZ tự tạo chỉ gắn vào VPC chứa endpoint | Đặt `false` và tự quản PHZ |

Bẫy đầu tiên đáng nói kỹ vì hậu quả âm thầm: khi VPC được associate PHZ `execute-api.<region>.amazonaws.com`, **mọi** lệnh gọi tới API Gateway trong region đó — kể cả API public của bên thứ ba — sẽ resolve về VPC endpoint và fail nếu endpoint policy không cho. Nếu VPC vừa gọi private API vừa gọi public API, cân nhắc tách VPC hoặc thêm bản ghi tường minh cho các API public cần dùng.

Bẫy "vẫn đi qua NAT" thì ngược lại — nó **không báo lỗi**, chỉ âm thầm tốn tiền. Nên có alarm theo dõi `BytesOutToDestination` của NAT Gateway; giảm mạnh sau khi bật endpoint là dấu hiệu đúng.

---

## 8. DNS Firewall và query logging

Vẫn nên có, và bây giờ đơn giản hơn vì không phải allowlist domain của M365:

```hcl
resource "aws_route53_resolver_firewall_domain_list" "blocked" {
  provider = aws.network
  name     = "acme-blocked-domains"

  domains = [
    "*.bit",
    "*.onion",
    "*.duckdns.org",
    "*.no-ip.com",
  ]
}

resource "aws_route53_resolver_firewall_rule_group" "main" {
  provider = aws.network
  name     = "acme-dns-firewall"
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

resource "aws_route53_resolver_query_log_config" "main" {
  provider        = aws.network
  name            = "acme-dns-query-log"
  destination_arn = "arn:aws:s3:::acme-dns-logs-${var.log_archive_account_id}"
}
```

Vẫn giữ nguyên lời khuyên từ doc 07: **bật `ALERT` trước, quan sát query log vài ngày, rồi mới đổi sang `BLOCK`.**

Firewall rule group gắn vào Route 53 Profile ở mục 4.3 là xong cho toàn org.

---

## 9. Kiểm tra

```bash
# Từ EC2 trong spoke VPC:

# 1. Endpoint resolve về IP PRIVATE (10.0.x.x), không phải IP public
dig +short secretsmanager.ap-southeast-1.amazonaws.com
# Kỳ vọng: 10.0.1.x, 10.0.2.x

# 2. Gọi thử qua endpoint
aws secretsmanager list-secrets --region ap-southeast-1

# 3. S3 phải đi qua GATEWAY endpoint – kiểm tra prefix list trong route table
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-xxxx" \
  --query 'RouteTables[].Routes[?DestinationPrefixListId!=null]'

# 4. PHZ nội bộ
dig +short artifacts.aws.acme.internal

# 5. Xác nhận traffic KHÔNG đi qua NAT nữa
#    (chạy trước và sau khi bật endpoint, so sánh)
aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value=nat-xxxxx \
  --start-time "$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 86400 --statistics Sum

# 6. Profile đã gắn vào VPC nào
aws route53profiles list-profile-associations

# 7. Endpoint đang ở AZ nào (để kiểm tra phí cross-AZ)
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].[ServiceName,SubnetIds]' --output table
```

Lệnh 1 là bài test quan trọng nhất. Trả về IP public nghĩa là DNS chưa trỏ vào endpoint — traffic vẫn ra Internet qua NAT, endpoint đang tính tiền mà không ai dùng.

---

## 10. Lộ trình đề xuất

Với LZ mới, thuần AWS, tôi khuyên đi theo thứ tự này:

```text
Giai đoạn 1 – ngay bây giờ (chi phí ~$1/tháng)
  ✔ PHZ nội bộ aws.acme.internal
  ✔ Route 53 Profile + RAM share
  ✔ S3 + DynamoDB gateway endpoint trong MỌI VPC (miễn phí)
  ✔ Query logging
  ✘ Chưa cần resolver endpoint (không có on-prem)
  ✘ Chưa cần interface endpoint

Giai đoạn 2 – khi có workload trong VPC
  ✔ Interface endpoint TRỰC TIẾP trong VPC cần dùng
  ✔ Đo lưu lượng NAT để biết endpoint nào thật sự đáng tạo
  ✔ DNS Firewall ở chế độ ALERT

Giai đoạn 3 – khi đã có 5+ VPC VÀ đã có TGW
  ✔ Tính lại bài toán mục 6
  ✔ Nếu lãi: chuyển interface endpoint về shared services VPC
  ✔ Giữ nguyên gateway endpoint ở từng VPC

Giai đoạn 4 – khi đấu nối on-premise
  → Quay lại doc 07: thêm resolver inbound/outbound endpoint
```

Điểm quan trọng: **giai đoạn 1 gần như miễn phí và luôn đáng làm.** Giai đoạn 3 thì phải tính toán, và hoàn toàn có thể là câu trả lời "chưa cần".

Với workload serverless như ví dụ 01–05 trong repo này, rất có thể bạn dừng ở giai đoạn 1 trong thời gian dài — và đó là kết quả tốt, không phải thiếu sót.

---

## 11. Điều chỉnh doc 06 cho môi trường thuần AWS

Vài chỗ trong [doc 06](./06-Aws-Landing-Zone.md) có thể đơn giản hoá:

| Mục doc 06 | Điều chỉnh |
|---|---|
| Mục 11 – Transit Gateway | **Hoãn lại.** Chỉ dựng khi có VPC cần nói chuyện với nhau. Tiết kiệm ~$36.50/VPC + $33 NAT |
| Mục 11 – Centralized egress | Hoãn cùng TGW. Serverless không cần NAT |
| Mục 15 – Chi phí | Bỏ dòng TGW + NAT, LZ còn khoảng $40–100/tháng |
| Mục 16 – DNS | Trỏ sang doc này thay vì doc 07 |

Một LZ thuần serverless, không TGW, không NAT, không resolver endpoint có chi phí nền tảng rất thấp — phần lớn hoá đơn sẽ là Config + GuardDuty + Security Hub, tức là tiền mua khả năng quan sát và tuân thủ. Đó là khoản đáng chi.
