# Ingress chain – CDN → Palo Alto → F5 WAF → App

Ví dụ 14: Chuỗi thanh tra nhiều tầng cho luồng vào, mở rộng phần ingress của [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md).

> Tài liệu chi tiết. Thiết kế tổng thể, quy hoạch CIDR chuẩn và bảng định tuyến Transit Gateway ở [17 – Network LZ Design Guide](./17-Network-LZ-Design-Guide.md).

Egress vẫn giữ nguyên: spoke → TGW → egress VPC → NAT Gateway → Internet. Bài này chỉ nói về chiều **vào**.

---

## 1. Bốn tầng, và tầng nào làm gì

Trước khi dựng, cần rõ mỗi tầng thực sự đóng góp gì — vì ba tầng đầu có phần chồng lấn, và chồng lấn không kiểm soát là nguồn gốc của những sự cố khó lần.

| Tầng | Nhiệm vụ chính | Nhìn thấy gì | Không làm được gì |
|---|---|---|---|
| **CDN** (CloudFront/Akamai) | Cache, chống DDoS thể tích, TLS đầu vào, chặn theo địa lý | L7 sau khi terminate TLS | Không hiểu logic ứng dụng |
| **Palo Alto** (VM-Series) | IPS/threat prevention, App-ID, kiểm soát L3–L7, log luồng | **Chỉ L3/L4 nếu traffic còn mã hoá** | Không phải WAF chuyên sâu |
| **F5 BIG-IP** (Advanced WAF) | Terminate TLS, WAF theo policy ứng dụng, bot defense, LB L7 | Toàn bộ payload sau giải mã | Không chống DDoS thể tích ở edge |
| **App** | Nghiệp vụ | | |

### Điểm quan trọng nhất của thiết kế này

**Palo Alto đứng trước F5, mà F5 mới là nơi terminate TLS.** Nghĩa là khi gói tin đi qua Palo Alto, nó vẫn đang **được mã hoá**. Hệ quả:

- PA làm được: kiểm soát L3/L4, chặn IP xấu, phát hiện bất thường luồng, App-ID dựa trên SNI/JA3, IPS trên phần không mã hoá.
- PA **không** làm được nếu không cấu hình thêm: thanh tra nội dung HTTP, chặn SQLi/XSS trong body.

Ba cách xử lý:

| Cách | Mô tả | Đánh đổi |
|---|---|---|
| **A. Chấp nhận** (phổ biến nhất) | PA lo L3/L4 + IPS, F5 lo L7. Phân vai rõ ràng | PA không thấy payload — thường là đủ |
| **B. SSL Inbound Inspection trên PA** | Nạp private key của server vào PA để giải mã | Key nằm ở hai nơi, PA tốn CPU nhiều hơn, vận hành phức tạp |
| **C. Đảo thứ tự** | CDN → F5 (terminate) → PA (thấy plaintext) → App | Trái với chuỗi bạn đang có; PA thành tầng trong |

Bài này đi theo **cách A** vì đúng với chuỗi bạn mô tả và là cách vận hành đơn giản nhất. Mục 9 nói cách chuyển sang B nếu tuân thủ bắt buộc.

---

## 2. Kiến trúc

```text
                          NGƯỜI DÙNG
                              │
                              ▼
              ┌───────────────────────────────┐
              │  CDN (CloudFront / Akamai)    │
              │  + AWS WAF: rate limit, bot   │
              │  TLS đầu vào từ client        │
              └───────────────┬───────────────┘
                              │ HTTPS tới origin.acme.com
                              │ (chỉ IP của CDN được vào)
┌─────────────────────────────▼─────────────────────────────────────┐
│  INGRESS VPC 10.0.0.0/16  (network account)                       │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ Internet Gateway                                          │    │
│  │   ↑ edge route table (ingress routing)                    │    │
│  │   └─ dest = public subnet CIDR → GWLB endpoint            │    │
│  └────────────────────────┬─────────────────────────────────┘    │
│                           │                                       │
│  subnet: gwlbe   ┌────────▼─────────┐                            │
│  10.0.10.0/28    │ GWLB Endpoint    │                            │
│                  └────────┬─────────┘                            │
│                           │ GENEVE 6081                           │
│  subnet: appliance ┌──────▼──────────────────────┐               │
│  10.0.20.0/24      │ Gateway Load Balancer       │               │
│                    │   └→ Palo Alto VM-Series    │  TẦNG 1       │
│                    │      (AZ-a, AZ-b)           │  IPS / L3-L4  │
│                    └──────┬──────────────────────┘               │
│                           │ trả về đúng đích ban đầu             │
│  subnet: public    ┌──────▼──────────────────────┐               │
│  10.0.0.0/24       │ NLB (internet-facing)       │               │
│                    │ TCP 443 passthrough         │               │
│                    └──────┬──────────────────────┘               │
│                           │                                       │
│  subnet: f5        ┌──────▼──────────────────────┐               │
│  10.0.30.0/24      │ F5 BIG-IP Advanced WAF      │  TẦNG 2       │
│                    │ - terminate TLS             │  WAF L7       │
│                    │ - WAF policy                │               │
│                    │ - pool → app trong spoke    │               │
│                    └──────┬──────────────────────┘               │
│                           │                                       │
│  subnet: tgw       ┌──────▼──────────────────────┐               │
│  10.0.40.0/28      │ TGW attachment              │               │
│                    └──────┬──────────────────────┘               │
└───────────────────────────┼───────────────────────────────────────┘
                            │
                     Transit Gateway
                            │
                  ┌─────────▼──────────┐
                  │ app-prod VPC       │
                  │ 10.20.0.0/16       │
                  │ App (private only) │
                  └────────────────────┘
```

Sáu tầng subnet trong ingress VPC, mỗi AZ một bộ:

| Subnet | CIDR mẫu | Chứa | Route mặc định |
|---|---|---|---|
| `gwlbe` | `10.0.10.0/28` | GWLB endpoint | `0.0.0.0/0` → IGW |
| `appliance` | `10.0.20.0/24` | Palo Alto VM-Series | `0.0.0.0/0` → IGW (cho license/update) |
| `public` | `10.0.0.0/24` | NLB internet-facing | `0.0.0.0/0` → **GWLBe** |
| `f5` | `10.0.30.0/24` | F5 BIG-IP VE | `0.0.0.0/0` → GWLBe, spoke → TGW |
| `tgw` | `10.0.40.0/28` | ENI của TGW attachment | spoke → TGW |
| `mgmt` | `10.0.50.0/24` | Interface quản trị của PA/F5 | qua egress VPC |

---

## 3. Vì sao Palo Alto đi qua Gateway Load Balancer

Hai cách đưa PA vào đường traffic:

| Cách | Cơ chế | Ưu | Nhược |
|---|---|---|---|
| **GWLB** (khuyến nghị) | Chèn bằng **route table**, GENEVE encap, PA hoạt động trong suốt | PA thấy IP nguồn gốc; scale/HA do GWLB lo; không phải NAT | Cần hiểu ingress routing |
| **NLB inline** | PA là target của NLB, làm proxy/NAT | Quen thuộc hơn | Mất IP nguồn; HA phải tự lo; PA thành điểm nghẽn |

GWLB thắng ở ba điểm quan trọng với PA:

1. **Giữ nguyên IP nguồn** — quan trọng cho log, cho policy theo địa lý, cho việc điều tra sự cố.
2. **Đối xứng luồng** — GWLB dùng flow hashing 5-tuple, gói đi và gói về của cùng một phiên luôn tới **cùng một** instance PA. Firewall stateful bắt buộc điều này.
3. **Scale ngang** — thêm PA instance vào target group, không phải cấu hình lại đường mạng.

---

## 4. Luồng gói tin – đọc kỹ phần này

Đây là chỗ hay sai nhất. Bảy chặng cho chiều vào:

```text
1. Client → CDN                        TLS #1 (cert public, do CDN giữ)
2. CDN → origin.acme.com               TLS #2 (cert origin)
                                       → phân giải về EIP của NLB
3. IGW nhận gói
   → edge route table: dest 10.0.0.0/24 → GWLBe
4. GWLBe → GWLB → Palo Alto            GENEVE 6081, PA thấy IP thật của CDN
   PA kiểm tra → trả gói về GWLB
5. GWLBe chuyển gói tới đích ban đầu   = NLB ở public subnet
6. NLB (TCP 443 passthrough) → F5
7. F5: terminate TLS #2, chạy WAF policy
   → mở TLS #3 (hoặc HTTP) tới app trong spoke, qua TGW
```

Chiều về, ngược lại nhưng vẫn **phải qua PA**:

```text
8.  App → TGW → F5
9.  F5 → NLB → public subnet
    → route table của public subnet: 0.0.0.0/0 → GWLBe
10. GWLBe → GWLB → Palo Alto (cùng instance nhờ flow hashing)
11. → GWLBe → IGW → CDN → Client
```

Bước 9 là điểm hay bị bỏ sót: nếu public subnet để `0.0.0.0/0 → IGW` như VPC thông thường, **gói về không đi qua PA**, luồng trở nên bất đối xứng và PA sẽ drop phiên. Triệu chứng: kết nối bắt tay được rồi treo.

---

## 5. Terraform – CDN và khoá origin

```hcl
# 5-network/cdn.tf

resource "aws_cloudfront_distribution" "app" {
  provider = aws.network
  enabled  = true
  comment  = "${var.project} ingress"

  aliases = ["www.acme.com", "api.acme.com"]

  origin {
    domain_name = "origin.acme.com" # Route 53 alias → NLB
    origin_id   = "ingress-nlb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Bí mật chia sẻ: F5 kiểm tra header này, request thiếu nó bị chặn.
    # Đây là lớp chống đi vòng qua CDN, bổ sung cho prefix list ở dưới.
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  default_cache_behavior {
    target_origin_id       = "ingress-nlb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn # PHẢI ở us-east-1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["VN", "SG", "US"]
    }
  }

  # AWS WAF ở edge: rate limit + bot. Bổ sung cho F5, không thay thế.
  web_acl_id = aws_wafv2_web_acl.edge.arn
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}
```

### 5.1. Chỉ cho CDN vào origin

Không khoá thì kẻ tấn công gọi thẳng `origin.acme.com`, bỏ qua toàn bộ tầng CDN và AWS WAF.

```hcl
# Prefix list do AWS quản lý, chứa dải IP CloudFront dùng để gọi origin
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  provider = aws.network
  name     = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "nlb_ingress" {
  provider    = aws.network
  name        = "${var.project}-nlb-ingress"
  description = "Chi CloudFront duoc goi vao NLB"
  vpc_id      = aws_vpc.ingress.id

  ingress {
    description     = "HTTPS tu CloudFront"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-nlb-ingress" }
}
```

Dùng **Akamai** hay CDN khác thay CloudFront: thay `prefix_list_ids` bằng dải IP nhà cung cấp công bố, và cân nhắc dịch vụ khoá origin của họ (Akamai Site Shield). Prefix list tự quản:

```hcl
resource "aws_ec2_managed_prefix_list" "cdn" {
  provider       = aws.network
  name           = "${var.project}-cdn-ranges"
  address_family = "IPv4"
  max_entries    = 100

  dynamic "entry" {
    for_each = var.cdn_ip_ranges
    content {
      cidr        = entry.value
      description = "CDN edge"
    }
  }
}
```

Dải IP của CDN thay đổi định kỳ — nên có Lambda chạy hằng tuần kéo danh sách từ API nhà cung cấp và cập nhật prefix list, thay vì hardcode.

Hai lớp bảo vệ origin nên có **cả hai**: prefix list (chặn ở tầng mạng) và header bí mật kiểm tra tại F5 (chặn ở tầng ứng dụng, dùng khi có ai đó đi qua được tầng mạng).

---

## 6. Terraform – GWLB và Palo Alto

### 6.1. Gateway Load Balancer

```hcl
# 5-network/gwlb-palo-alto.tf

resource "aws_lb" "gwlb" {
  provider           = aws.network
  name               = "${var.project}-gwlb"
  load_balancer_type = "gateway"
  subnets            = [for k in ["a", "b"] : aws_subnet.appliance[k].id]

  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.project}-gwlb" }
}

resource "aws_lb_target_group" "palo_alto" {
  provider    = aws.network
  name        = "${var.project}-pa"
  port        = 6081
  protocol    = "GENEVE"
  vpc_id      = aws_vpc.ingress.id
  target_type = "instance"

  health_check {
    port                = var.pa_health_check_port     # kiểm tra tài liệu PA cho phiên bản đang dùng
    protocol            = var.pa_health_check_protocol
    path                = var.pa_health_check_path
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  # Giữ phiên bám vào cùng một instance PA (firewall stateful)
  stickiness {
    type    = "source_ip_dest_ip_proto"
    enabled = true
  }
}

resource "aws_lb_target_group_attachment" "palo_alto" {
  provider         = aws.network
  for_each         = aws_instance.palo_alto
  target_group_arn = aws_lb_target_group.palo_alto.arn
  target_id        = each.value.id
}

resource "aws_lb_listener" "gwlb" {
  provider          = aws.network
  load_balancer_arn = aws_lb.gwlb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.palo_alto.arn
  }
}

########################
# Endpoint service + endpoint
########################

resource "aws_vpc_endpoint_service" "gwlb" {
  provider                   = aws.network
  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb.arn]

  tags = { Name = "${var.project}-gwlb-svc" }
}

resource "aws_vpc_endpoint" "gwlbe" {
  provider          = aws.network
  for_each          = toset(["a", "b"])
  vpc_id            = aws_vpc.ingress.id
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.gwlbe[each.key].id]

  tags = { Name = "${var.project}-gwlbe-${each.key}" }
}
```

### 6.2. Instance Palo Alto

```hcl
# AMI lấy từ AWS Marketplace. Phải subscribe TRƯỚC khi terraform apply,
# nếu không sẽ lỗi OptInRequired.
data "aws_ami" "palo_alto" {
  provider    = aws.network
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = [var.pa_ami_name_pattern] # vd "PA-VM-AWS-11.1*"
  }
}

resource "aws_instance" "palo_alto" {
  provider = aws.network
  for_each = toset(["a", "b"])

  ami           = var.pa_ami_id != "" ? var.pa_ami_id : data.aws_ami.palo_alto.id
  instance_type = var.pa_instance_type # m5.xlarge trở lên

  # Interface dữ liệu - nơi GWLB gửi GENEVE tới
  subnet_id              = aws_subnet.appliance[each.key].id
  vpc_security_group_ids = [aws_security_group.palo_alto.id]

  # Firewall PHẢI tắt source/dest check để chuyển tiếp gói không phải của mình
  source_dest_check = false

  iam_instance_profile = aws_iam_instance_profile.palo_alto.name

  # Bootstrap qua S3: init-cfg.txt + bootstrap.xml
  #
  # KHONG boc base64encode: aws_instance.user_data TU ma hoa base64.
  # Boc them la ma hoa hai lan, PAN-OS doc ra mot chuoi base64 thay vi
  # chuoi khoa=gia tri, va no bo qua bootstrap - im lang.
  user_data = "vmseries-bootstrap-aws-s3bucket=${aws_s3_bucket.pa_bootstrap.id}"

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project}-pa-${each.key}" }
}

resource "aws_security_group" "palo_alto" {
  provider    = aws.network
  name        = "${var.project}-pa"
  description = "Palo Alto VM-Series, target cua GWLB"
  vpc_id      = aws_vpc.ingress.id

  ingress {
    description = "GENEVE tu GWLB"
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    cidr_blocks = [aws_vpc.ingress.cidr_block]
  }

  ingress {
    description = "Health check tu GWLB"
    from_port   = var.pa_health_check_port
    to_port     = var.pa_health_check_port
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.ingress.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-pa" }
}
```

`source_dest_check = false` là bắt buộc — thiếu nó thì EC2 vứt bỏ mọi gói không có đích là chính nó, và firewall sẽ không chuyển tiếp được gì.

#### Bốn thứ mà thiếu một cái là bootstrap bị bỏ qua — im lặng

Cài đặt thật ở [`demo/network-lz-full/appliances.tf`](../demo/network-lz-full/appliances.tf) cùng hai template `templates/pa-init-cfg.txt.tftpl` và `templates/pa-bootstrap.xml.tftpl`. Bốn điều dưới đây đều cho ra **cùng một triệu chứng**: thiết bị lên bình thường với cấu hình gốc, GWLB báo target `unhealthy` mãi mãi, không log, không lỗi.

| | |
|---|---|
| **`user_data` không phải script** | PAN-OS đọc nó như chuỗi `khoá=giá trị`. Một script bash ở đó bị bỏ qua hoàn toàn |
| **Ba thư mục rỗng phải tồn tại** | `license/`, `software/`, `content/`. Thiếu **bất kỳ** cái nào là PAN-OS bỏ qua **cả gói** bootstrap. S3 không có thư mục thật, nên phải tạo ba object rỗng kết thúc bằng `/` |
| **`s3:ListBucket` là quyền trên bucket** | Không phải trên object. Thiếu nó thì `GetObject` vẫn chạy mà bootstrap vẫn bị bỏ qua, vì PAN-OS không liệt kê được bốn thư mục |
| **Phải có hai ENI** | Xem dưới |

#### Hai giao diện, và vì sao một cái không đủ

> **GWLB gửi GENEVE tới ENI *chính* của instance.** Mặc định PAN-OS lấy `eth0` làm giao diện **quản trị**. Nên với một ENI duy nhất, lưu lượng cần quét đến một cổng không xử lý được gói tin, còn mặt phẳng dữ liệu thì nằm ở một ENI không tồn tại.

Cách sửa là `op-command-modes=mgmt-interface-swap` trong `init-cfg.txt`, cộng một ENI thứ hai:

| ENI | Subnet | Sau khi swap |
|---|---|---|
| `eth0` | appliance | `ethernet1/1` — dữ liệu, GWLB gửi vào đây |
| `eth1` | mgmt | giao diện quản trị |

#### Mật khẩu: cố ý không đặt

`bootstrap.xml` không đặt mật khẩu admin. VM-Series trên AWS đăng nhập lần đầu bằng key pair (`ssh -i key.pem admin@<ip mgmt>`), rồi tự đặt.

Một phash viết sẵn trong XML sẽ nằm trong S3 **và** trong state, và nó sẽ sống lâu hơn ý định của người viết nó.

#### `plan` không đọc file XML

`templatefile()` chỉ ghép chuỗi. `bootstrap.xml` có thể thiếu thẻ đóng hay thiếu cả một khối bắt buộc — `plan` xanh, `apply` xanh, object vẫn lên S3. PAN-OS mới là thứ đọc nó, và nó đọc lúc **boot**.

Nên `plan-check.sh` tự phân tích template thành XML và đòi sáu khối phải có mặt, gồm cả `interface-management-profile` — thiếu nó thì health check của GWLB không bao giờ đạt, dù mọi thứ khác đúng.

### 6.3. Ingress routing – gắn route table vào IGW

Đây là tính năng làm cho thanh tra trong suốt hoạt động:

```hcl
# Route table gắn TRỰC TIẾP vào Internet Gateway (edge association)
resource "aws_route_table" "igw_edge" {
  provider = aws.network
  vpc_id   = aws_vpc.ingress.id

  tags = { Name = "${var.project}-igw-edge-rt" }
}

# Traffic vào tới public subnet phải rẽ qua GWLBe trước
resource "aws_route" "igw_edge_to_gwlbe" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.igw_edge.id
  destination_cidr_block = aws_subnet.public[each.key].cidr_block
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[each.key].id
}

resource "aws_route_table_association" "igw_edge" {
  provider       = aws.network
  gateway_id     = aws_internet_gateway.ingress.id
  route_table_id = aws_route_table.igw_edge.id
}

########################
# Public subnet: đường VỀ cũng phải qua PA
########################

resource "aws_route_table" "public" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.ingress.id

  tags = { Name = "${var.project}-public-rt-${each.key}" }
}

# KHÔNG trỏ thẳng IGW - đó là lỗi làm luồng bất đối xứng
resource "aws_route" "public_default_to_gwlbe" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.public[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[each.key].id
}

########################
# GWLBe subnet: sau khi thanh tra xong thì ra IGW
########################

resource "aws_route_table" "gwlbe" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.ingress.id

  tags = { Name = "${var.project}-gwlbe-rt-${each.key}" }
}

resource "aws_route" "gwlbe_default_to_igw" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.gwlbe[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ingress.id
}
```

---

## 7. Terraform – tầng F5

```hcl
# 5-network/f5.tf

# NLB nhận traffic sau khi PA thanh tra xong, chuyển xuống F5.
# TCP passthrough - KHÔNG terminate TLS ở đây, để dành cho F5.
resource "aws_lb" "ingress_nlb" {
  provider           = aws.network
  name               = "${var.project}-nlb"
  load_balancer_type = "network"
  internal           = false
  security_groups    = [aws_security_group.nlb_ingress.id]

  subnets = [for k in ["a", "b"] : aws_subnet.public[k].id]

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = true

  tags = { Name = "${var.project}-nlb" }
}

resource "aws_lb_target_group" "f5" {
  provider    = aws.network
  name        = "${var.project}-f5"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.ingress.id
  target_type = "instance"

  # Giữ IP nguồn để F5 ghi log đúng client thật
  preserve_client_ip = true

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "nlb_443" {
  provider          = aws.network
  load_balancer_arn = aws_lb.ingress_nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.f5.arn
  }
}

########################
# F5 BIG-IP VE
########################

data "aws_ami" "f5" {
  provider    = aws.network
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = [var.f5_ami_name_pattern] # vd "F5 BIGIP-17.1*BYOL*All Modules*"
  }
}

resource "aws_instance" "f5" {
  provider = aws.network
  for_each = toset(["a", "b"])

  ami           = var.f5_ami_id != "" ? var.f5_ami_id : data.aws_ami.f5.id
  instance_type = var.f5_instance_type # m5.xlarge trở lên cho Advanced WAF

  subnet_id              = aws_subnet.f5[each.key].id
  vpc_security_group_ids = [aws_security_group.f5.id]

  iam_instance_profile = aws_iam_instance_profile.f5.name

  # Khai báo ban đầu bằng F5 Declarative Onboarding + AS3.
  # Cấu hình WAF policy nên quản bằng AS3 declaration trong Git,
  # đừng cấu hình tay trên GUI rồi quên mất.
  user_data = templatefile("${path.module}/templates/f5-runtime-init.yaml", {
    admin_secret_arn = aws_secretsmanager_secret.f5_admin.arn
    app_pool_members = var.app_pool_members
    origin_verify    = var.origin_verify_secret
  })

  root_block_device {
    volume_size = 82
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project}-f5-${each.key}" }
}

resource "aws_security_group" "f5" {
  provider    = aws.network
  name        = "${var.project}-f5"
  description = "F5 BIG-IP Advanced WAF"
  vpc_id      = aws_vpc.ingress.id

  ingress {
    description = "HTTPS tu NLB o public subnet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for k in ["a", "b"] : aws_subnet.public[k].cidr_block]
  }

  ingress {
    description = "Quan tri tu mgmt subnet"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [for k in ["a", "b"] : aws_subnet.mgmt[k].cidr_block]
  }

  egress {
    description = "Toi app trong spoke"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.spoke_supernet]
  }

  tags = { Name = "${var.project}-f5" }
}

########################
# F5 đi xuống app qua TGW
########################

resource "aws_route_table" "f5" {
  provider = aws.network
  for_each = toset(["a", "b"])
  vpc_id   = aws_vpc.ingress.id

  tags = { Name = "${var.project}-f5-rt-${each.key}" }
}

resource "aws_route" "f5_to_spokes" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.f5[each.key].id
  destination_cidr_block = var.spoke_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.ingress]
}

# Traffic ra Internet của F5 (update, license) cũng qua PA
resource "aws_route" "f5_default_to_gwlbe" {
  provider = aws.network
  for_each = toset(["a", "b"])

  route_table_id         = aws_route_table.f5[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[each.key].id
}
```

> **Cấu hình bên trong F5** — Declarative Onboarding, AS3, WAF policy, vòng đời transparent → blocking — nằm ở [18 – Cấu hình F5 BIG-IP Advanced WAF](./18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md). Doc đó cũng chỉ cách **học F5 bằng bản PAYG theo giờ (~$10/buổi) mà không cần mua license trước**.

### 7.1. Kiểm tra header bí mật tại F5

Đặt trong AS3 declaration hoặc iRule, chặn request không đi qua CDN:

```tcl
when HTTP_REQUEST {
    if { [HTTP::header value "X-Origin-Verify"] ne $static::origin_secret } {
        log local0. "Bo qua CDN tu [IP::client_addr] toi [HTTP::host][HTTP::uri]"
        HTTP::respond 403 content "Forbidden"
        return
    }
}
```

Bí mật này nên xoay vòng định kỳ — Lambda cập nhật đồng thời `custom_header` của CloudFront và secret bên F5.

---

## 8. TLS terminate ở đâu

Ba lần bắt tay TLS trong chuỗi này, mỗi lần một quyết định:

| Chặng | Cert | Ai giữ key | Ghi chú |
|---|---|---|---|
| Client → CDN | Public cert (ACM ở **us-east-1**) | AWS | Bắt buộc us-east-1 cho CloudFront |
| CDN → NLB/F5 | Cert cho `origin.acme.com` | F5 | Cert phải khớp tên origin, không dùng được DNS name của NLB |
| F5 → App | Cert nội bộ, hoặc HTTP | App | HTTP chấp nhận được nếu mạng đã tin cậy; HTTPS nếu tuân thủ yêu cầu mã hoá đầu-cuối |

Cạm bẫy hay gặp: trỏ CloudFront origin thẳng vào **DNS name của NLB** rồi đặt `origin_protocol_policy = "https-only"`. Cert trên F5 không thể khớp `*.elb.amazonaws.com`, và CloudFront sẽ báo lỗi xác thực cert. Cách đúng: tạo bản ghi Route 53 `origin.acme.com` trỏ tới NLB và cấp cert cho chính tên đó.

---

## 9. Nếu bắt buộc Palo Alto phải thấy plaintext

Khi tuân thủ yêu cầu IPS phải thanh tra nội dung HTTP:

```text
Cách B - SSL Inbound Inspection trên PA
  - Nạp cert + private key của origin.acme.com vào PA
  - Bật decryption policy hướng inbound
  - PA giải mã, thanh tra, mã hoá lại rồi chuyển tiếp

Cần chuẩn bị:
  - Quy trình quản lý key ở hai nơi (PA và F5) - đây là rủi ro thật
  - PA cần instance lớn hơn: decryption tốn CPU đáng kể
  - Quy trình xoay vòng cert phải cập nhật cả hai
```

Trước khi chọn cách này, hỏi một câu: **F5 Advanced WAF đã thanh tra L7 rồi, PA thêm được gì?** Thường câu trả lời là chữ ký IPS cho lỗ hổng tầng hạ tầng (Log4Shell, lỗ hổng của web server) mà WAF policy chưa phủ. Nếu đúng vậy thì đáng làm. Nếu chỉ để "cho chắc" thì cái giá vận hành không xứng.

---

## 10. HA và kịch bản hỏng

| Thành phần hỏng | Chuyện gì xảy ra | Chuẩn bị |
|---|---|---|
| Một instance PA | GWLB đưa ra khỏi target group, dồn sang instance còn lại | Tối thiểu 2 instance, khác AZ; theo dõi `UnHealthyHostCount` |
| **Cả tầng PA** | Toàn bộ ingress **chết** — không có đường vòng | Alarm nghiêm trọng; cân nhắc quy trình khẩn tạm gỡ PA khỏi route |
| Một F5 | NLB dồn sang F5 còn lại; phiên đang chạy bị đứt | 2 instance; bật connection draining |
| Một AZ | GWLB cross-zone giữ luồng chạy | Bật `enable_cross_zone_load_balancing` |
| GWLB endpoint | Route trong AZ đó gãy | Endpoint ở mọi AZ |
| CDN | Origin vẫn sống nhưng prefix list chặn hết | Có sẵn kịch bản mở tạm |

Điểm nghiêm trọng nhất: **tầng PA là điểm chết đơn lẻ của toàn bộ luồng vào**. Khác với egress (mất Internet, khó chịu nhưng nội bộ vẫn chạy), mất ingress nghĩa là khách hàng không truy cập được. Nên có:

- Alarm trên `UnHealthyHostCount` của target group PA, ngưỡng ở mức **1** chứ không phải 0.
- Runbook đã viết sẵn và **đã diễn tập** cho tình huống gỡ PA khỏi đường route khẩn cấp (đổi route ở edge route table trỏ thẳng public subnet).
- Diễn tập định kỳ, vì đây là thao tác ít khi làm nên rất dễ sai lúc đang có sự cố.

---

## 11. Chi phí – phần nặng nhất của cả LZ

| Thành phần | Ghi chú | Ước tính/tháng |
|---|---|---|
| Gateway Load Balancer | ~$0.0125/giờ + phí GLCU | ~$10 + traffic |
| GWLB endpoint × 2 AZ | ~$0.01/giờ/AZ + ~$0.0035/GB | ~$15 + traffic |
| **Palo Alto VM-Series × 2** | EC2 (m5.xlarge trở lên) + **license** | **$700–2.000** |
| **F5 BIG-IP VE × 2** | EC2 + **license Advanced WAF** | **$700–2.000** |
| NLB | ~$0.0225/giờ + LCU | ~$20 |
| CloudFront | Theo lưu lượng và request | Tuỳ |
| **Cộng** | | **~$1.500–4.000/tháng** |

Giá license Marketplace của Palo Alto và F5 dao động rất lớn theo model, bundle và hình thức (BYOL với PAYG khác nhau đáng kể). **Kiểm tra giá thực tế trên AWS Marketplace** cho đúng phiên bản bạn định dùng, và nếu công ty đã có license BYOL thì chi phí chỉ còn phần EC2.

Đặt trong bối cảnh: phần này thường **đắt hơn toàn bộ phần còn lại của Landing Zone cộng lại**. Vài câu hỏi đáng đặt ra trước khi cam kết:

1. Đã có license PA/F5 dùng chung với on-premise chưa? Nếu có, chi phí giảm mạnh.
2. Có bao nhiêu ứng dụng thật sự cần chuỗi đầy đủ này? Ứng dụng nội bộ có thể chỉ cần ALB + AWS WAF.
3. AWS WAF + Shield Advanced có phủ được phần nào không? Rẻ hơn nhiều, dù không sâu bằng.

Kiến trúc phân tầng hợp lý: chuỗi đầy đủ cho ứng dụng công khai quan trọng, đường ngắn (CDN → ALB + AWS WAF → app) cho phần còn lại.

---

## 12. Demo rẻ – thay appliance bằng stand-in

AMI của Palo Alto và F5 cần subscribe Marketplace và tính tiền theo giờ, nên không hợp để dựng đi dựng lại. Muốn kiểm chứng **định tuyến** trước khi bỏ tiền:

| Tầng thật | Stand-in khi demo | Kiểm chứng được gì |
|---|---|---|
| CloudFront | CloudFront (rẻ, theo lưu lượng) | Khoá origin, custom header |
| Palo Alto + GWLB | Bỏ GWLB, route thẳng | Chưa kiểm chứng được ingress routing |
| Palo Alto + GWLB | EC2 chạy trình xử lý GENEVE mẫu của AWS | Kiểm chứng được đầy đủ đường GWLB |
| F5 | nginx làm reverse proxy + TLS | Chuỗi hop, TLS termination, header check |
| App | nginx trong spoke | Toàn tuyến |

Chuỗi stand-in khoảng **$0.15/giờ** thay vì ~$3/giờ. Kiểm chứng được đúng những thứ hay sai nhất: edge route table, đường về qua GWLBe, security group giữa các tầng, và việc F5 với tới được app qua TGW.

Khi định tuyến đã đúng, thay stand-in bằng AMI thật — phần Terraform hạ tầng giữ nguyên, chỉ đổi `ami` và `instance_type`.

---

## 13. Bẫy hay gặp

| Triệu chứng | Nguyên nhân |
|---|---|
| Bắt tay TCP xong rồi treo | Public subnet trỏ `0.0.0.0/0` thẳng IGW → luồng bất đối xứng, PA drop |
| PA không nhận được gói nào | Quên `source_dest_check = false` |
| GWLB target luôn unhealthy | Sai port/path health check, hoặc SG chưa mở port đó |
| Traffic vào không qua PA | Quên edge association route table vào IGW |
| Phiên đứt quãng ngẫu nhiên | Chưa bật stickiness trên target group GENEVE |
| CloudFront báo lỗi cert origin | Origin trỏ vào DNS name của NLB thay vì tên có cert |
| Gọi thẳng origin vẫn vào được | Thiếu prefix list CloudFront hoặc thiếu kiểm tra header ở F5 |
| F5 ghi log toàn IP của NLB | Chưa bật `preserve_client_ip` |
| `OptInRequired` khi apply | Chưa subscribe AMI trên Marketplace |
| App thấy IP của F5, không thấy IP client | Cần `X-Forwarded-For` từ F5 và app phải đọc header đó |
| Hoá đơn cao bất ngờ | License PA/F5 tính theo giờ, chạy 24/7 kể cả khi không có traffic |

---

## 14. Lộ trình

```text
Giai đoạn 1 - Định tuyến (dùng stand-in, ~$0.15/giờ)
  ✔ Ingress VPC với đủ 6 tầng subnet
  ✔ IGW edge route table
  ✔ GWLB + endpoint + EC2 stand-in
  ✔ NLB + nginx thay F5
  ✔ Đường xuống app qua TGW
  ✔ Kiểm chứng bằng Reachability Analyzer và curl thật

Giai đoạn 2 - Appliance thật
  ✔ Subscribe Marketplace cho PA và F5
  ✔ Thay AMI, giữ nguyên phần hạ tầng
  ✔ Bootstrap PA (S3 + init-cfg.txt)
  ✔ Onboard F5 (Declarative Onboarding + AS3 trong Git)

Giai đoạn 3 - CDN và khoá origin
  ✔ CloudFront + ACM ở us-east-1
  ✔ Prefix list + header bí mật
  ✔ AWS WAF ở edge cho rate limit và bot

Giai đoạn 4 - Vận hành
  ✔ Alarm UnHealthyHostCount ngưỡng 1
  ✔ Runbook gỡ PA khẩn cấp + DIỄN TẬP
  ✔ Log PA và F5 đẩy về log-archive account
  ✔ Xoay vòng bí mật origin tự động
```

Đừng làm ngược giai đoạn 1 và 2. Debug định tuyến GWLB **và** cấu hình Palo Alto cùng lúc là cách chắc chắn để mất một tuần mà không biết vấn đề nằm ở tầng nào.
