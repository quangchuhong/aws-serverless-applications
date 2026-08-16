# Thiết kế Network Landing Zone – Guide tổng hợp

Tài liệu thiết kế **chuẩn** cho phần network của Landing Zone. Đây là nguồn sự thật duy nhất về kiến trúc, CIDR và định tuyến.

| Tài liệu | Vai trò |
|---|---|
| **17 (tài liệu này)** | **Thiết kế tổng thể — chốt kiến trúc, CIDR, routing, chi phí** |
| [12 – DNS & VPC Endpoint](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) | Chi tiết PHZ, Route 53 Profile, endpoint |
| [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) | Chi tiết SCP khoá Internet, egress VPC |
| [14 – Ingress Chain](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | Chi tiết GWLB, Palo Alto, F5 |
| [15 – Security VPC](./15-Security-VPC-Network-Firewall.md) | Chi tiết Network Firewall, rule group |
| [16 – Kết nối đối tác](./16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) | Chi tiết VPN, private NAT, 3rd-party VPC |

Khi có mâu thuẫn giữa tài liệu này và docs 12–16, **tài liệu này thắng**.

---

## 1. Yêu cầu thiết kế

Chốt từ trao đổi, đây là ràng buộc đầu vào:

| # | Yêu cầu | Hệ quả thiết kế |
|---|---|---|
| R1 | Multi-account, tự build Terraform (không Control Tower) | Organizations + SCP + StackSet |
| R2 | Thuần AWS — không AD on-premise, không M365 | **Không** cần Route 53 Resolver endpoint |
| R3 | Mọi account workload **không có** đường ra Internet | SCP chặn IGW/NAT/EIP; chỉ private subnet |
| R4 | Chỉ network account có Internet | IGW chỉ ở ingress VPC và egress VPC |
| R5 | Tách **ingress VPC** và **egress VPC** | Hai VPC riêng, hai bài toán riêng |
| R6 | Egress đi qua NAT Gateway | NAT ở egress VPC, 2 AZ |
| R7 | Ingress qua chuỗi CDN → Palo Alto → F5 WAF → App | GWLB cho PA, NLB cho F5 |
| R8 | **Mọi** traffic in/out **và VPC-to-VPC** qua Network Firewall | **security-vpc** riêng, TGW routing đối xứng |
| R9 | Kết nối đối tác qua 3rd-party VPC + VPN | Partner VPC làm vùng đệm |
| R10 | VPC endpoint tập trung | Interface endpoint **trong security VPC** (R8) |
| R11 | Demo dựng được rồi xoá, không phát sinh chi phí | Không tạo account; stand-in cho PA/F5 |

R8 là ràng buộc mạnh nhất và nó chi phối gần như mọi quyết định còn lại.

---

## 2. Kiến trúc tổng thể

```text
┌─────────────────────── AWS ORGANIZATION ────────────────────────────┐
│                                                                      │
│  Management ──── Log Archive ──── Security ──── Identity Center      │
│                                                                      │
│  ┌──────────────── OU: Infrastructure ──────────────────────────┐   │
│  │                                                               │   │
│  │  ┌──────────── NETWORK ACCOUNT ─────────────────────────┐    │   │
│  │  │                                                       │    │   │
│  │  │  INGRESS VPC 10.0.0.0/16        EGRESS VPC 10.2.0.0/16│    │   │
│  │  │  ┌─────────────────────┐        ┌──────────────────┐ │    │   │
│  │  │  │ IGW                 │        │ IGW              │ │    │   │
│  │  │  │ ↓ edge route table  │        │ ↑                │ │    │   │
│  │  │  │ GWLBe → GWLB        │        │ NAT GW × 2 AZ    │ │    │   │
│  │  │  │       → Palo Alto   │        │ ↑                │ │    │   │
│  │  │  │ NLB → F5 BIG-IP     │        │ TGW attach       │ │    │   │
│  │  │  │ TGW attach          │        └────────▲─────────┘ │    │   │
│  │  │  └─────────┬───────────┘                 │           │    │   │
│  │  │            │                             │           │    │   │
│  │  │  SECURITY VPC 10.1.0.0/16                │           │    │   │
│  │  │  ┌─────────▼─────────────────────────────┴────────┐  │    │   │
│  │  │  │ KHÔNG IGW · KHÔNG NAT                          │  │    │   │
│  │  │  │                                                 │  │    │   │
│  │  │  │  TGW attach (appliance_mode = enable)          │  │    │   │
│  │  │  │        ↓                                        │  │    │   │
│  │  │  │  AWS Network Firewall (endpoint × 2 AZ)        │  │    │   │
│  │  │  │        ↓                                        │  │    │   │
│  │  │  │  Interface VPC Endpoints (ssm, kms, logs…)     │  │    │   │
│  │  │  └────────────────────▲───────────────────────────┘  │    │   │
│  │  │                       │                               │    │   │
│  │  │  3RD-PARTY VPC 10.9.0.0/16                           │    │   │
│  │  │  ┌────────────────────┴───────────────────────────┐  │    │   │
│  │  │  │ VGW ← IPsec VPN ← Đối tác A, B                 │  │    │   │
│  │  │  │ Private NAT (xử lý trùng CIDR)                 │  │    │   │
│  │  │  │ TGW attach                                      │  │    │   │
│  │  │  └─────────────────────────────────────────────────┘  │    │   │
│  │  └───────────────────────┬───────────────────────────────┘    │   │
│  └──────────────────────────┼────────────────────────────────────┘   │
│                             │                                        │
│                    ╔════════▼═════════╗                              │
│                    ║ TRANSIT GATEWAY  ║  5 route table              │
│                    ╚════════┬═════════╝                              │
│                             │                                        │
│  ┌──────────── OU: Workloads ──────────────────────────────────┐    │
│  │   app-dev        app-prod        data-prod                   │    │
│  │   10.10.0.0/16   10.20.0.0/16    10.21.0.0/16               │    │
│  │   KHÔNG IGW      KHÔNG IGW       KHÔNG IGW                   │    │
│  │   KHÔNG NAT      KHÔNG NAT       KHÔNG NAT                   │    │
│  │   Gateway EP: S3 + DynamoDB (miễn phí, mọi VPC)             │    │
│  └───────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

Bốn VPC trong network account, mỗi cái một vai duy nhất:

| VPC | Có IGW? | Có NAT? | Vai trò |
|---|---|---|---|
| `ingress-vpc` | ✅ | ❌ | Nhận traffic từ Internet, chuỗi PA → F5 |
| `security-vpc` | ❌ | ❌ | **Thanh tra mọi luồng** + interface endpoint |
| `egress-vpc` | ✅ | ✅ | Đường ra Internet duy nhất |
| `3rd-party-vpc` | ❌ | ✅ (private) | Vùng đệm cho đối tác |

---

## 2.1. Giai đoạn 1 – kiến trúc khi chưa có Palo Alto và F5

Palo Alto và F5 cần license Marketplace, thường mất vài tuần tới vài tháng để mua và cấp phát. Trong thời gian đó **vẫn dựng được phần lớn thiết kế** — và nên dựng, vì phần khó nhất không nằm ở appliance.

### Cái gì đổi, cái gì không

```text
GIAI ĐOẠN 1 (bây giờ)                    GIAI ĐOẠN 2 (khi có license)

  Internet                                  Internet
     │                                         │
     ▼                                         ▼
  CloudFront + AWS WAF  ← tạm thời          CloudFront + AWS WAF
     │                                         │
     ▼                                         ▼
┌─────────────────────┐                  ┌─────────────────────┐
│ INGRESS VPC         │                  │ INGRESS VPC         │
│                     │                  │                     │
│  IGW                │                  │  IGW                │
│   │                 │                  │   │ edge route      │
│   ▼                 │                  │   ▼                 │
│  ALB (+ AWS WAF)    │      ═══>        │  GWLBe → Palo Alto  │
│   │                 │                  │   │                 │
│   │                 │                  │  NLB → F5 WAF       │
│   ▼                 │                  │   │                 │
│  TGW attachment     │                  │  TGW attachment     │
└─────────┬───────────┘                  └─────────┬───────────┘
          │                                        │
          ▼                                        ▼
   ══════════════ KHÔNG ĐỔI ══════════════════════════
     TGW (4 route table) → SECURITY VPC (Network Firewall)
     → EGRESS VPC (NAT) → SPOKE (không IGW/NAT)
   ═══════════════════════════════════════════════════
```

Chỉ **phần trên của ingress VPC** thay đổi. Toàn bộ định tuyến TGW, security VPC, egress VPC và spoke **giữ nguyên từng dòng**.

Đó là lý do làm giai đoạn 1 trước có ý nghĩa thật: bạn kiểm chứng được chỗ khó nhất và dễ sai nhất (bảng định tuyến ở mục 4) mà không phải chờ license.

### Khoảng trống bảo mật – cần biết rõ

Đừng nghĩ giai đoạn 1 là "an toàn, chỉ thiếu vài thứ". Thiếu PA và F5 nghĩa là:

| Mất gì | Hệ quả |
|---|---|
| **WAF tầng ứng dụng** | Không chặn SQLi, XSS, path traversal, các lỗi OWASP Top 10 |
| **IPS / chữ ký mối đe doạ** | Không phát hiện khai thác lỗ hổng đã biết (Log4Shell, lỗi web server) |
| **Bot defense** | Không phân biệt bot xấu với người dùng thật |
| **TLS termination có kiểm soát** | Không thanh tra được nội dung HTTPS ở tầng ingress |

Còn giữ được gì: Network Firewall **vẫn nằm trong đường đi** của luồng ingress → spoke (mục 5, luồng 5–6), nên vẫn có L3/L4, SNI allowlist và log tập trung. Không phải là không có gì, nhưng **không phải WAF**.

### Bù tạm bằng AWS WAF

Cách rẻ và nhanh nhất để lấp phần lớn khoảng trống trong lúc chờ:

| Việc | Chi phí | Bù được gì |
|---|---|---|
| **AWS WAF + managed rule groups** trên ALB hoặc CloudFront | ~$10–40/tháng | OWASP Top 10, bot cơ bản, rate limit |
| AWS Shield Standard | $0 (tự động) | DDoS L3/L4 |
| CloudFront | Theo lưu lượng | Hấp thụ DDoS thể tích, TLS đầu vào |

Ba managed rule group nên bật ngay:

```hcl
# AWSManagedRulesCommonRuleSet          - OWASP co ban
# AWSManagedRulesKnownBadInputsRuleSet  - payload khai thac da biet
# AWSManagedRulesSQLiRuleSet            - SQL injection
```

> **Quyết định kiến trúc quan trọng cho giai đoạn 1: dùng ALB, không dùng NLB.**
>
> AWS WAF **không gắn được vào NLB**. Nếu giai đoạn 1 dùng NLB thì bạn không có WAF nào cả. Dùng ALB để gắn được AWS WAF.
>
> Sang giai đoạn 2, kiến trúc quay lại NLB (vì NLB làm TCP passthrough cho F5 terminate TLS — doc 14 mục 7). Đây là một thay đổi có chủ đích giữa hai giai đoạn, không phải thiết kế lại.

### Giai đoạn 1 có đủ để chạy production không?

| Loại ứng dụng | Giai đoạn 1 có đủ? |
|---|---|
| Nội bộ, không ra Internet | ✅ Đủ — không có bề mặt tấn công từ ngoài |
| Public, không xử lý dữ liệu nhạy cảm | ⚠️ Tạm được với AWS WAF, chấp nhận rủi ro có ý thức |
| Public, có dữ liệu cá nhân/thanh toán | ❌ Không — chờ đủ PA + F5, hoặc nâng AWS WAF lên mức đầy đủ |
| Chịu ràng buộc tuân thủ (PCI-DSS…) | ❌ Không — kiểm toán sẽ hỏi về WAF và IPS |

Ghi lại quyết định này thành ADR, kèm ngày dự kiến có license. Khoảng trống tạm thời được chấp nhận có thời hạn là chuyện bình thường; khoảng trống bị quên mới là vấn đề.

---

## 3. Quy hoạch CIDR – bảng chuẩn

**Bảng này thay thế mọi bảng CIDR trong docs 12–16.**

| Vùng | CIDR | Ghi chú |
|---|---|---|
| `ingress-vpc` | `10.0.0.0/16` | |
| `security-vpc` | `10.1.0.0/16` | |
| `egress-vpc` | `10.2.0.0/16` | |
| Dự phòng hub | `10.3.0.0/16` – `10.7.0.0/16` | DR, region thứ hai |
| `3rd-party-vpc` | `10.9.0.0/16` | |
| **NonProd spokes** | `10.10.0.0/14` | `10.10` – `10.13` |
| **Prod spokes** | `10.20.0.0/14` | `10.20` – `10.23` |
| **Sandbox** | `10.60.0.0/14` | Không attach TGW |
| Dự phòng mở rộng | `10.100.0.0/12` | |

Subnet trong từng VPC hub:

| VPC | Tầng | AZ-a | AZ-b |
|---|---|---|---|
| ingress | `gwlbe` | `10.0.10.0/28` | `10.0.11.0/28` |
| ingress | `appliance` (PA) | `10.0.20.0/24` | `10.0.21.0/24` |
| ingress | `public` (NLB) | `10.0.0.0/24` | `10.0.1.0/24` |
| ingress | `f5` | `10.0.30.0/24` | `10.0.31.0/24` |
| ingress | `tgw` | `10.0.40.0/28` | `10.0.41.0/28` |
| ingress | `mgmt` | `10.0.50.0/24` | `10.0.51.0/24` |
| security | `tgw` | `10.1.20.0/28` | `10.1.21.0/28` |
| security | `firewall` | `10.1.10.0/28` | `10.1.11.0/28` |
| security | `endpoints` | `10.1.30.0/24` | `10.1.31.0/24` |
| egress | `public` (NAT) | `10.2.0.0/24` | `10.2.1.0/24` |
| egress | `tgw` | `10.2.20.0/28` | `10.2.21.0/28` |
| 3rd-party | `vpn` | `10.9.0.0/24` | `10.9.1.0/24` |
| 3rd-party | `nat` | `10.9.10.0/24` | — |
| 3rd-party | `services` | `10.9.100.0/24` | — |
| 3rd-party | `tgw` | `10.9.20.0/28` | `10.9.21.0/28` |

> **Đổi so với doc 13**: doc 13 gán `10.1.0.0/16` cho egress VPC. Vì security VPC được chèn vào, egress chuyển sang `10.2.0.0/16` và `10.1.0.0/16` dành cho security. Dùng bảng này.

Ba dải quan trọng dùng trong route và rule:

```hcl
variable "internal_supernet"   { default = "10.0.0.0/8" }      # moi thu noi bo
variable "ingress_vpc_cidr"    { default = "10.0.0.0/16" }
variable "partner_vpc_cidr"    { default = "10.9.0.0/16" }
```

---

## 4. Transit Gateway – bảng chân lý duy nhất

Năm route table. **Đây là bảng quan trọng nhất của cả thiết kế** — sai một ô là có luồng lọt firewall hoặc đứt kết nối.

| Route table | Associate | Propagate | Route tĩnh (theo thứ tự ưu tiên) |
|---|---|---|---|
| `rtb-spokes` | Mọi spoke | *(không có)* | `0.0.0.0/0` → **security** |
| `rtb-security` | security | **Mọi spoke** | `10.0.0.0/16` → ingress<br>`10.9.0.0/16` → partner<br>`0.0.0.0/0` → egress |
| `rtb-egress` | egress | *(không có)* | `10.0.0.0/8` → **security** |
| `rtb-ingress` | ingress | *(không có)* | `10.0.0.0/8` → **security** |
| `rtb-partner` | 3rd-party | *(không có)* | `0.0.0.0/0` → **security** |

Bốn quy tắc bất biến, vi phạm là hỏng:

**QT1 — Chỉ `rtb-security` được propagate.** Bốn bảng còn lại dùng route tĩnh. Propagate ở `rtb-egress` khiến gói trả về đi thẳng tới spoke, bỏ qua firewall.

**QT2 — `rtb-security` phải có route tĩnh cho mọi đích không phải spoke, đặt trước `0.0.0.0/0`.** Thiếu `10.0.0.0/16 → ingress` thì gói trả lời của app cho F5 rơi vào egress VPC; client không bao giờ nhận được phản hồi.

**QT3 — `appliance_mode_support = "enable"` trên attachment của security VPC.** Thiếu thì luồng east-west cross-AZ đi qua hai firewall endpoint khác nhau và bị drop.

**QT4 — Thêm VPC mới vào network account = thêm route tĩnh vào `rtb-security`.** Đây là bước hay quên nhất khi mở rộng.

### 4.1. Route trong từng VPC

| VPC | Subnet | Route mặc định | Route bổ sung |
|---|---|---|---|
| spoke | `private` | `0.0.0.0/0` → **TGW** | *(gateway endpoint tự thêm prefix list)* |
| security | `tgw` | `0.0.0.0/0` → **firewall endpoint** | |
| security | `firewall` | `0.0.0.0/0` → **TGW** | |
| security | `endpoints` | *(chỉ local)* | `10.0.0.0/8` → TGW |
| egress | `tgw` | `0.0.0.0/0` → **NAT** (cùng AZ) | |
| egress | `public` | `0.0.0.0/0` → **IGW** | `10.0.0.0/8` → **TGW** ← đường về |
| ingress | `gwlbe` | `0.0.0.0/0` → **IGW** | |
| ingress | `public` | `0.0.0.0/0` → **GWLBe** | |
| ingress | `f5` | `0.0.0.0/0` → **GWLBe** | `10.0.0.0/8` → TGW |
| ingress | *(IGW edge)* | — | `10.0.0.0/24` → **GWLBe** |
| 3rd-party | `tgw` | `0.0.0.0/0` → **TGW** | |
| 3rd-party | `services` | `0.0.0.0/0` → **TGW** | |

Ô in đậm ở `egress/public` là lỗi hay gặp nhất trong toàn bộ thiết kế: thiếu route `10.0.0.0/8 → TGW` thì gói ra được Internet nhưng gói về không biết đường quay lại spoke.

---

## 5. Ma trận luồng – kiểm chứng đầy đủ

| # | Từ | Tới | Qua firewall | Đường đi |
|---|---|---|---|---|
| 1 | Spoke | Internet | ✅ | spoke → TGW → **FW** → TGW → egress → NAT → IGW |
| 2 | Internet | Spoke (trả lời) | ✅ | IGW → NAT → TGW → **FW** → TGW → spoke |
| 3 | Spoke A | Spoke B | ✅ | spoke A → TGW → **FW** → TGW → spoke B |
| 4 | Spoke B | Spoke A (trả lời) | ✅ | như trên, ngược chiều |
| 5 | Internet | App (ingress) | ✅ | CDN → IGW → GWLBe → **PA** → NLB → **F5** → TGW → **FW** → TGW → spoke |
| 6 | App | Client (trả lời) | ✅ | spoke → TGW → **FW** → TGW → F5 → NLB → GWLBe → **PA** → IGW |
| 7 | Đối tác | Spoke | ✅ | VPN → 3rd-party → TGW → **FW** → TGW → spoke |
| 8 | Spoke | Đối tác | ✅ | spoke → TGW → **FW** → TGW → 3rd-party → NAT → VPN |
| 9 | Spoke | Interface endpoint | ✅ | spoke → TGW → **FW** → local → endpoint |
| 10 | Spoke | S3/DynamoDB | ❌ | Gateway endpoint, không rời VPC |
| 11 | Subnet ↔ subnet cùng VPC | | ❌ | Không chạm TGW |
| 12 | Lambda ngoài VPC | Bất kỳ | ❌ | Hạ tầng AWS quản lý |

**9/12 luồng được thanh tra.** Ba luồng còn lại là giới hạn kỹ thuật của AWS, không phải thiếu sót cấu hình — mục 9 nói cách bù.

Luồng 5 và 6 đi qua **ba** tầng kiểm soát (PA, F5, Network Firewall). Cân nhắc: firewall ở chặng cuối chủ yếu để thống nhất chính sách và log tập trung, giá trị bảo mật tăng thêm là hạn chế. Nếu cần giảm chi phí, đây là chặng có thể bỏ trước tiên (đổi `rtb-ingress` sang propagate từ spoke).

---

## 6. Cấu trúc Terraform và thứ tự deploy

```text
aws-landing-zone/
  0-bootstrap/          S3 state + DynamoDB lock
  1-organization/       OU, account, SCP
  2-logging/            Org CloudTrail → log-archive
  3-security/           GuardDuty, Security Hub, Config
  4-identity-center/    Permission set, assignment
  5-network/
    5a-tgw/             TGW + 5 route table
    5b-security-vpc/    Network Firewall + interface endpoint
    5c-egress-vpc/      IGW + NAT
    5d-ingress-vpc/     GWLB + PA + NLB + F5
    5e-partner-vpc/     VGW + VPN + private NAT
    5f-dns/             PHZ + Route 53 Profile
  6-account-baseline/   Áp cho từng account
  7-scp-network/        SCP khoá Internet (áp CUỐI CÙNG)
```

Thứ tự bắt buộc và lý do:

| Bước | Layer | Vì sao phải sau bước trước |
|---|---|---|
| 1 | `0-bootstrap` | Cần state backend |
| 2 | `1-organization` | Cần account ID cho mọi thứ sau |
| 3 | `2-logging` → `4-identity-center` | Nền tảng, độc lập với network |
| 4 | `5a-tgw` | Mọi VPC cần TGW ID để attach |
| 5 | `5b-security-vpc` | Route table khác cần security attachment ID |
| 6 | `5c-egress-vpc` | `rtb-security` cần egress attachment ID |
| 7 | `5d`, `5e`, `5f` | Độc lập nhau, chạy song song được |
| 8 | `6-account-baseline` | Sau khi network sẵn sàng |
| 9 | **`7-scp-network`** | **CUỐI CÙNG** — xem cảnh báo dưới |

> **Cảnh báo thứ tự.** SCP chặn tạo IGW/NAT/EIP phải áp **sau khi** đã dọn hết IGW/NAT cũ ở spoke. Áp trước thì Terraform của các team fail giữa chừng lúc cần recreate resource, và bạn mất nhiều tuần lấy lại niềm tin của họ.

---

## 7. Mô hình chi phí

### 7.1. Cố định hằng tháng

| Hạng mục | Số lượng | Đơn giá | Tháng |
|---|---|---|---|
| TGW attachment | 4 hub + 3 spoke = 7 | ~$0.05/giờ | ~$256 |
| NAT Gateway | 2 AZ | ~$0.045/giờ | ~$66 |
| **Network Firewall endpoint** | 2 AZ | ~$0.395/giờ | **~$576** |
| GWLB + endpoint | 1 + 2 | | ~$25 |
| **Palo Alto VM-Series** | 2 | EC2 + license | **~$700–2.000** |
| **F5 BIG-IP Advanced WAF** | 2 | EC2 + license | **~$700–2.000** |
| NLB | 1 | ~$0.0225/giờ | ~$20 |
| Interface endpoint | 6 svc × 2 AZ | ~$0.01/giờ | ~$88 |
| VPN connection | 2 đối tác | ~$0.05/giờ | ~$73 |
| Private NAT | 1 | ~$0.045/giờ | ~$33 |
| Gateway endpoint | mọi VPC | **$0** | **$0** |
| **Cộng cố định** | | | **~$2.540–5.140** |

### 7.2. Theo lưu lượng (ví dụ 10 TB/tháng egress)

| Hạng mục | Đơn giá | Ghi chú | Tháng |
|---|---|---|---|
| Network Firewall data | ~$0.065/GB | | ~$650 |
| TGW data | ~$0.02/GB | **× 4 lần** (spoke→sec→egress và ngược lại) | ~$800 |
| NAT data | ~$0.045/GB | | ~$450 |
| **Cộng data** | | | **~$1.900** |

### 7.3. Tổng

> **~$4.400 – 7.000/tháng**, phần lớn là license Palo Alto/F5 và Network Firewall.

Giá license Marketplace dao động rất lớn theo model và bundle — **kiểm tra giá thực tế** cho phiên bản bạn dùng. Nếu công ty đã có license BYOL dùng chung với on-premise thì chi phí giảm mạnh.

### 7.4. Bốn đòn bẩy giảm chi phí

Xếp theo hiệu quả:

| # | Việc | Tiết kiệm |
|---|---|---|
| 1 | **Gateway endpoint S3/DynamoDB ở mọi VPC** | Cắt phần lớn lưu lượng NAT + firewall + TGW. Miễn phí. Không có lý do bỏ qua |
| 2 | Interface endpoint cho ECR nếu dùng container | Image layer là nguồn tiêu thụ lớn nhất ở đa số môi trường |
| 3 | Bỏ chặng firewall cho luồng ingress | PA + F5 đã thanh tra; đổi `rtb-ingress` sang propagate |
| 4 | Đường ngắn cho ứng dụng nội bộ | CDN → ALB + AWS WAF thay vì chuỗi đầy đủ |

Đòn bẩy 1 quan trọng nhất và hay bị bỏ qua: **không có VPC endpoint nghĩa là bạn trả $0.065/GB firewall + $0.08/GB TGW + $0.045/GB NAT để thanh tra traffic đi tới chính AWS** — thứ mà endpoint policy với `aws:PrincipalOrgID` kiểm soát tốt hơn và miễn phí.

---

## 8. Checklist kiểm chứng

Chạy sau mỗi lần thay đổi hạ tầng mạng.

### 8.1. Cấu hình

```bash
# 1. appliance mode BAT BUOC bat
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=vpc-id,Values=$SECURITY_VPC_ID" \
  --query 'TransitGatewayVpcAttachments[].Options.ApplianceModeSupport' --output text
# => enable

# 2. Moi route table TGW deu tro ve security (tru rtb-security)
#    Script day du o doc 15 muc 6.2

# 3. rtb-security co route tinh ve ingress TRUOC 0.0.0.0/0
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$RTB_SECURITY" \
  --filters "Name=state,Values=active" \
  --query 'Routes[].DestinationCidrBlock' --output text
# => phai co 10.0.0.0/16 va 10.9.0.0/16, khong chi 0.0.0.0/0

# 4. Duong VE trong egress VPC
aws ec2 describe-route-tables --route-table-id "$EGRESS_PUBLIC_RT" \
  --query 'RouteTables[0].Routes[?TransitGatewayId!=null].DestinationCidrBlock'
# => 10.0.0.0/8

# 5. Spoke KHONG co IGW/NAT
for vpc in $SPOKE_VPCS; do
  aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query 'InternetGateways[].InternetGatewayId' --output text
done
# => tat ca rong
```

### 8.2. Luồng thực tế

Từ EC2 trong spoke (vào bằng SSM):

```bash
# Egress cho phep
curl -sI https://www.amazonaws.com | head -1

# Egress bi chan (ngoai allowlist)
curl -sm 5 https://example.com ; echo "exit=$?"

# IP ra Internet = NAT cua egress VPC
curl -s https://checkip.amazonaws.com

# East-west cho phep
nc -zv 10.21.1.20 5432

# East-west bi chan
nc -zvw 5 10.21.1.20 22

# DNS di thang ra Internet -> bi chan
dig @8.8.8.8 example.com ; echo "exit=$?"

# Endpoint resolve ve IP private
dig +short ssm.ap-southeast-1.amazonaws.com
```

Từ Internet:

```bash
curl -sI https://api.acme.com/healthz          # qua chuoi CDN→PA→F5
curl -sI https://origin.acme.com/healthz       # PHAI bi chan (bo qua CDN)
```

### 8.3. Điều tra khi có sự cố

**Reachability Analyzer** là công cụ tốt nhất — chỉ ra chính xác gói bị chặn ở hop nào thay vì phải đoán qua timeout:

```bash
aws ec2 create-network-insights-path \
  --source "$SPOKE_INSTANCE_ID" --destination 8.8.8.8 \
  --protocol tcp --destination-port 443
aws ec2 start-network-insights-analysis --network-insights-path-id "$PATH_ID"
```

---

## 9. Ba luồng không thanh tra được – cách bù

| Luồng | Vì sao | Bù bằng |
|---|---|---|
| Gateway endpoint (S3/DynamoDB) | Không rời VPC | Endpoint policy `aws:ResourceOrgID` + CloudTrail data event |
| Trong cùng một VPC | Không chạm TGW | Security group + VPC Flow Logs; hoặc **tách tier thành VPC riêng** |
| Lambda ngoài VPC | Hạ tầng AWS quản lý | SCP ép Lambda vào VPC, hoặc chấp nhận + giới hạn IAM role |

Cách bù cho luồng 2 đáng cân nhắc ở tầng kiến trúc: tách `app-prod` và `data-prod` thành **hai VPC** thay vì hai subnet cùng VPC. Traffic giữa chúng tự động thành east-west và được firewall thanh tra. Đây là lý do chia VPC theo **tier**, không chỉ theo môi trường — thiết kế ở mục 2 đã theo hướng này.

Ba luồng này cần ghi rõ trong tài liệu tuân thủ. Đừng báo cáo "100% traffic được thanh tra" — điều đó không đúng và sẽ lộ ra khi bị audit.

---

## 10. Quyết định đã chốt

| # | Quyết định | Lý do | Phương án đã loại |
|---|---|---|---|
| D1 | Tự build Terraform, không Control Tower | Cần tuỳ biến network sâu | AFT (bám Control Tower) |
| D2 | Không Route 53 Resolver endpoint | Không có on-premise (R2) | Hybrid DNS — tiết kiệm ~$360/tháng |
| D3 | security-vpc **tách khỏi** egress VPC | Ranh giới trách nhiệm; đội security quản riêng | Gộp firewall vào egress — rẻ hơn ~$436/tháng |
| D4 | Palo Alto qua **GWLB**, không NLB inline | Giữ IP nguồn, đối xứng luồng, scale ngang | NLB inline |
| D5 | F5 terminate TLS, PA thấy traffic mã hoá | Phân vai rõ, vận hành đơn giản | SSL Inbound Inspection trên PA |
| D6 | Interface endpoint đặt **trong security VPC** | Được thanh tra mà không thêm chặng TGW | Shared services VPC riêng |
| D7 | Spoke-to-spoke qua firewall, không TGW trực tiếp | Yêu cầu R8 | Propagate spoke lẫn nhau |
| D8 | Đối tác qua 3rd-party VPC, không VPN thẳng vào TGW | Vùng đệm, xử lý được trùng CIDR | VPN → TGW attachment |
| D9 | Ưu tiên PrivateLink hơn VPN cho đối tác | Rẻ hơn ~10×, cách ly tốt hơn | VPN cho mọi đối tác |

Mỗi quyết định nên có một ADR riêng khi đưa vào tổ chức. Bảng này là bản tóm tắt.

---

## 11. Lộ trình build

```text
GIAI ĐOẠN 1 — Nền tảng (chưa có network)
  □ 0-bootstrap, 1-organization, 2-logging, 3-security, 4-identity-center
  □ Gateway endpoint S3/DynamoDB trong mọi VPC (miễn phí)
  □ PHZ + Route 53 Profile
  → LZ chạy được, chi phí ~$40–100/tháng

GIAI ĐOẠN 2 — Xương sống network
  □ 5a-tgw với đủ 5 route table
  □ 5b-security-vpc, firewall ở chế độ ALERT-ONLY
  □ 5c-egress-vpc
  □ Attach spoke, đổi default route sang TGW
  □ Kiểm chứng bằng checklist mục 8
  → Traffic đã tập trung, chưa chặn gì

GIAI ĐOẠN 3 — Dọn dẹp và khoá
  □ Xoá NAT/IGW cũ ở từng spoke  ← thu hồi vốn ~$33/NAT
  □ SCP khoá Internet: Sandbox → NonProd → Prod

GIAI ĐOẠN 4 — Thanh tra thật
  □ Bật FLOW log, dựng Athena, lập bản đồ luồng (2–4 tuần)
  □ Viết rule allow cho luồng hợp lệ đã phát hiện
  □ Chuyển firewall sang DROP: Sandbox → NonProd → Prod

GIAI ĐOẠN 5 — Ingress, phần làm được ngay (xem mục 2.1)
  □ 5d-ingress-vpc: IGW + ALB
  □ AWS WAF + 3 managed rule group gắn vào ALB  ← lấp khoảng trống tạm
  □ Kiểm chứng: ingress → TGW → firewall → spoke, và đường về
  → Public app chạy được với mức bảo vệ chấp nhận tạm

GIAI ĐOẠN 6 — Ingress, phần chờ license
  □ Subscribe Marketplace cho Palo Alto và F5
  □ Chèn GWLB + PA vào giữa IGW và NLB
  □ Đổi ALB sang NLB, thêm F5 phía sau
  □ CDN + khoá origin
  → Định tuyến TGW/security/egress/spoke KHÔNG đổi ở bước này

GIAI ĐOẠN 7 — Đối tác
  □ 5e-partner-vpc
  □ Đối tác đầu tiên = đối tác **ít quan trọng nhất**

GIAI ĐOẠN 8 — Vận hành
  □ Alarm: firewall endpoint, VPN tunnel, NAT
  □ Runbook bypass firewall + DIỄN TẬP
  □ Drift detection
```

Bốn nguyên tắc xuyên suốt:

1. **Alert trước, drop sau.** Áp dụng cho cả Network Firewall, DNS Firewall và SCP.
2. **Sandbox → NonProd → Prod.** Mỗi bậc sống ít nhất 1–2 tuần.
3. **Dọn resource cũ trước khi khoá.** Ngược lại là gây sự cố cho các team.
4. **Không chờ license mới bắt đầu.** Giai đoạn 1–5 chiếm phần lớn công sức và toàn bộ rủi ro định tuyến; Palo Alto và F5 chèn vào sau mà không đụng tới chúng.

---

## 12. Demo – dựng, kiểm chứng, xoá

Mục tiêu: kiểm chứng **định tuyến** với chi phí tối thiểu, rồi xoá sạch.

### 12.1. Đã có

| Demo | Nội dung | Chi phí |
|---|---|---|
| **[`demo/network-lz-full`](../demo/network-lz-full/)** | **Giai đoạn 1 đầy đủ**: TGW 4 route table, security VPC + Network Firewall, egress VPC, ingress NLB, spoke, gateway endpoint | **~$0.34–0.77/giờ** |
| [`demo/centralized-network`](../demo/centralized-network/) | Bản tối giản: TGW + egress + cách ly spoke | ~$0.21/giờ |
| [`demo/centralized-network-multiaccount`](../demo/centralized-network-multiaccount/) | Ba account: RAM share TGW, cross-account PHZ | ~$0.22/giờ |

`network-lz-full` là bộ chính. Nó có kịch bản 5 bước, mỗi bước bật thêm một phần bằng biến:

| Bước | Bật gì | ~$/giờ | Kiểm chứng được |
|---|---|---|---|
| 1 | Chưa có firewall | $0.34 | Spoke không IGW/NAT, egress tập trung, ingress |
| 2 | Firewall chế độ `alert` | $0.74 | Mọi luồng qua security VPC, đọc được log |
| 3 | Firewall chế độ `drop` | $0.74 | Chặn thật: port có rule vs không có rule |
| 4 | Sửa `east_west_rules` | $0.74 | **Mở/đóng luồng VPC-to-VPC mà không đụng route** |
| 5 | Interface endpoint | $0.77 | Endpoint trong security VPC, vẫn được thanh tra |

Kèm `verify.sh` (8 nhóm kiểm tra, chạy lệnh thật trên EC2 qua SSM) và `teardown.sh` (destroy + xác nhận không còn gì tính tiền).

### 12.2. Chưa có trong demo

| Thành phần | Vì sao | Khi nào thêm |
|---|---|---|
| **Palo Alto (GWLB)** | Cần license Marketplace | Giai đoạn 2 |
| **F5 BIG-IP** | Cần license Marketplace | Giai đoạn 2 |
| CloudFront + khoá origin | Cần domain và ACM cert | Giai đoạn 2 |
| 3rd-party VPC + VPN | Cần customer gateway thật | Sau khi xong giai đoạn 1 |
| SCP khoá Internet | Làm `terraform destroy` kẹt | Chỉ áp ở môi trường thật |

Buổi thực hành 4 tiếng ≈ **$3**. Quên xoá một tháng ≈ **$540** — nên phần kiểm tra sau khi destroy là bắt buộc, không phải tuỳ chọn.

### 12.3. Nguyên tắc cho code demo

| Nguyên tắc | Lý do |
|---|---|
| **Không tạo AWS account** | Account không xoá được, chỉ đóng được; email không tái dùng |
| **Không attach SCP** | SCP chặn IGW/NAT làm `terraform destroy` kẹt |
| **Không bật deletion protection** | Chặn destroy |
| **Tag `Ephemeral=true` mọi thứ** | Tìm được resource sót |
| **1 AZ thay vì 2** | Giảm nửa chi phí NAT và firewall endpoint |
| **Stand-in cho appliance Marketplace** | PA/F5 tính license theo giờ, rất đắt |

---

## 13. Việc còn lại

Phần đã xong và phần cần làm tiếp:

| Hạng mục | Trạng thái |
|---|---|
| Thiết kế network (tài liệu này + 12–16) | ✅ Xong |
| **Demo giai đoạn 1: TGW + security VPC + firewall + egress + ingress** | ✅ **Xong** — [`demo/network-lz-full`](../demo/network-lz-full/) |
| **Script verify (8 nhóm, chạy lệnh thật qua SSM)** | ✅ Xong |
| **Script teardown + xác nhận sạch** | ✅ Xong |
| Demo multi-account, RAM share | ✅ Xong |
| Demo 3rd-party VPC + VPN | ⬜ Cần làm |
| AWS WAF + ALB cho giai đoạn 1 (mục 2.1) | ⬜ Cần làm |
| Palo Alto + F5 | ⏸ **Chờ license** |
| CloudFront + khoá origin | ⏸ Chờ domain và ACM cert |
| Terraform layer `1-organization` → `4-identity-center` | ⬜ Mới có trong doc, chưa thành code chạy được |
| `6-account-baseline` thành module dùng được | ⬜ Cần làm |
| `7-scp-network` | ⬜ Cần làm |

Đề xuất thứ tự làm tiếp:

1. **Chạy demo giai đoạn 1** — 5 bước trong [`demo/network-lz-full/README.md`](../demo/network-lz-full/README.md), xác nhận `verify.sh` xanh hết. Đây là lúc phát hiện sai sót thiết kế rẻ nhất.
2. **Thay NLB bằng ALB + AWS WAF** — lấp phần lớn khoảng trống bảo mật trong lúc chờ PA/F5 (mục 2.1).
3. **Các layer LZ còn lại** — organization, logging, security, identity center thành code chạy được.
4. **3rd-party VPC + VPN** — khi có thông tin customer gateway của đối tác.
5. **Palo Alto + F5** — khi có license. Phần định tuyến không đổi, chỉ thêm vào giữa IGW và TGW attachment của ingress VPC.

Mục 1 nên làm trước tiên vì nó kiểm chứng bảng định tuyến ở mục 4 — chỗ mà một ô sai sẽ gây ra sự cố rất khó lần ra nguyên nhân khi đã lên môi trường thật.
