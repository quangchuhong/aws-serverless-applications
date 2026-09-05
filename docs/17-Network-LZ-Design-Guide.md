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
| **[24 – Triển khai cross-account](./24-Trien-khai-Network-LZ-Cross-Account.md)** | **Làm gì, theo thứ tự nào** — lệnh thật, kiểm chứng thật, chi phí thật |
| **[25 – Vận hành hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md)** | **Sau khi mạng đã chạy** — mở port, route ngoại lệ, endpoint, DNS |

Khi có mâu thuẫn giữa tài liệu này và docs 12–16, **tài liệu này thắng**.

---

## 0. Trạng thái triển khai

Bảng này trả lời: *cái gì đã có code chạy được, cái gì mới có trên giấy.*

| Ký hiệu | Nghĩa |
|---|---|
| ✅ | Code chạy được, đã `apply` và `destroy` được |
| ⏸ | Code viết sẵn, `plan` kiểm chứng được, **chưa bật** (chờ license) |
| ⏳ | Code viết xong, `fmt`/`lint` sạch, **chưa apply lần nào** |
| ⬜ | Mới có thiết kế trong doc, chưa thành code |

### Tầng network

| Thành phần | Thiết kế | Code | Trạng thái |
|---|---|---|---|
| Transit Gateway + 4 route table | [17 mục 4](#4-transit-gateway--bảng-chân-lý-duy-nhất) | `tgw.tf` | ✅ |
| security VPC + Network Firewall | [15](./15-Security-VPC-Network-Firewall.md) | `vpc-security.tf`, `firewall.tf` | ✅ |
| egress VPC + NAT Gateway | [13](./13-Centralized-Ingress-Egress-Network.md) | `vpc-egress.tf` | ✅ |
| Spoke không IGW/NAT | [13](./13-Centralized-Ingress-Egress-Network.md) | `vpc-spokes.tf` | ✅ |
| Gateway endpoint S3/DynamoDB | [12](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) | `vpc-spokes.tf` | ✅ |
| Interface endpoint trong security VPC | [15 mục 6.3](./15-Security-VPC-Network-Firewall.md) | `vpc-security.tf` | ✅ |
| ingress VPC + NLB | [14](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | `vpc-ingress.tf` | ✅ |
| CloudFront + AWS WAF + khoá origin | [14 mục 5](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | `cdn.tf` | ✅ |
| **Palo Alto qua GWLB** | [14 mục 6](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | `appliances.tf` | **⏸ chờ license** |
| **F5 BIG-IP Advanced WAF** | [14 mục 7](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md), [18](./18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md) | `appliances.tf`, `templates/` | **⏸ chờ license** |
| Route 53 PHZ nội bộ | [12 mục 4](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) | `dns.tf` | ✅ |
| **Spoke VPC ở account khác** | [mục 4b](#4b-spoke-vpc-ở-account-khác) | `vpc-spokes-remote.tf` | ✅ |
| **Route 53 Profile share cross-account** | [12 mục 4](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) | `dns.tf` + template StackSet | ✅ |
| **RAM share Transit Gateway** | [mục 4b](#4b-spoke-vpc-ở-account-khác) | `vpc-spokes-remote.tf` | ⚠️ chạy được, nhưng **phải đi đường vòng**² |
| **3rd-party VPC + Site-to-Site VPN** | [16](./16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) | `partner.tf`, `partner-sim.tf` | ⏳ code xong, đối tác **giả lập** để đo được cả tuyến, chưa apply⁵ |
| SCP khoá Internet | [13 mục 4](./13-Centralized-Ingress-Egress-Network.md) | — | ⬜ cố ý không đưa vào demo¹ |
| **Lớp vận hành (route/port/endpoint/DNS)** | [25](./25-Van-hanh-Network-Hang-Ngay.md) | `landing-zone/network/ops/` | ✅ apply thật, policy đọc rule group ở ưu tiên 150⁴ |

¹ SCP chặn IGW/NAT làm `terraform destroy` kẹt giữa chừng. Chỉ áp ở môi trường thật, sau khi đã dọn NAT/IGW cũ.

⁵ Phần dễ hỏng nhất là cấu hình strongSwan trong `templates/strongswan.sh.tftpl` — nó không được `terraform validate` hay `plan` kiểm chứng, chỉ đường hầm lên hay không mới trả lời. `verify.sh` mục 10 đọc trạng thái tunnel từ AWS nên nó nói ngay, không phải đoán từ việc ping không thông.

⁴ State riêng trong S3 qua `tf-backend`, chạm vào layer chính đúng một điểm (`var.ops_rule_group_arns`). Catalog YAML khai bằng **tên app** chứ không phải CIDR: gõ nhầm một chữ số trong CIDR thì apply vẫn xanh và rule không khớp gì trọn đời — cùng loại im lặng với lỗi 62. `lint.sh` chạy không cần AWS.

² Share trong phạm vi tổ chức (`allow_external_principals = false`, principal là account ID hoặc OU) **không chạy** trên tổ chức này: RAM không phân giải được organization, kể cả khi gọi từ management account. Đang chờ AWS Support. Đường vòng hiện dùng là `allow_external_principals = true` — nới rào chắn và mỗi account phải bấm nhận lời mời một lần. Chi tiết và phép đo đối chứng: [doc 22 lỗi 56](./22-Nhat-ky-Trien-khai-LZ-DIY.md).

### Tầng nền tảng LZ

Bảng này từng nói *"chưa thành code"* cho gần như mọi dòng. Nó đã lạc hậu: [doc 22](./22-Nhat-ky-Trien-khai-LZ-DIY.md) ghi lại lần dựng thật, và bảy trong tám layer đã apply lẫn destroy được.

| Thành phần | Thiết kế | Trạng thái |
|---|---|---|
| Organizations, OU, SCP, account | [06](./06-Aws-Landing-Zone.md) | ✅ [`landing-zone/organization/`](../landing-zone/organization/) — 8 OU, 4 SCP, 6 account |
| Org CloudTrail → log-archive | [06 mục 8](./06-Aws-Landing-Zone.md) | ✅ [`landing-zone/org-trail/`](../landing-zone/org-trail/) |
| GuardDuty, Security Hub, Config | [06 mục 9](./06-Aws-Landing-Zone.md), [23](./23-Lop-Phat-Hien-GuardDuty-SecurityHub-Log-Archive.md) | ✅ [`landing-zone/config-detective/`](../landing-zone/config-detective/) — 5/5 member, đường cảnh báo đã nhận được email thật |
| IAM Identity Center + permission set | [06 mục 10](./06-Aws-Landing-Zone.md), [19](./19-Permission-Set-cho-Landing-Zone.md) | ✅ [`landing-zone/permission-sets/`](../landing-zone/permission-sets/) — 17 set, 15 group, 53 assignment |
| Đồng bộ AD | [08](./08-Dong-bo-User-AD-sang-IAM-Identity-Center.md) | ⬜ |
| Account baseline (thay AFT) | [09](./09-Account-Vending-Tu-Dong.md) | ✅ [`landing-zone/account-baseline/`](../landing-zone/account-baseline/) — StackSet + Lambda xoá default VPC³ |
| CI/CD OIDC | [10](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) | ⏳ mới có `network-ops.yml` (lint + expiry chạy được ngay, plan chờ OIDC role). Chưa có job apply |
| **Billing guard** (cost allocation tag, budget, anomaly) | [11](./11-Tag-Policy-va-Cost-Allocation.md) | ✅ [`landing-zone/billing-guard/`](../landing-zone/billing-guard/) |
| Tag policy + SCP + Cost Categories + CUR | [11](./11-Tag-Policy-va-Cost-Allocation.md) | ⬜ |
| Remote state (S3 + Object Lock + khoá) | [20](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | ✅ [`landing-zone/tf-backend/`](../landing-zone/tf-backend/) |

³ **Không với tới management account.** StackSet `SERVICE_MANAGED` triển khai theo cây tổ chức và AWS loại management account ra khỏi mọi đợt triển khai đó — khai thêm root id cũng không tới. Default VPC ở management phải xoá bằng tay. Xem [doc 22 lỗi 59](./22-Nhat-ky-Trien-khai-LZ-DIY.md).

### Script kiểm chứng

| Script | Làm gì | Trạng thái |
|---|---|---|
| `plan-check.sh` | `terraform plan` cho 9 tổ hợp biến (gồm cả appliance), kiểm tra plan đúng hành vi. **Không tạo gì** | ✅ 24 đạt |
| `verify.sh` | 12 nhóm kiểm chứng sau khi apply, gồm chạy lệnh thật trên EC2 qua SSM và ba nhóm nhìn **qua ranh giới account** | ✅ 28 đạt trên lần dựng 4 account |
| `teardown.sh` | Destroy + xác nhận không còn resource nào tính tiền | ✅ |

Cả ba script đều **dừng ngay** nếu credential trong shell không thuộc account đã tạo hạ tầng. Không có cổng đó thì `verify.sh` báo 8 lỗi hạ tầng cho một hệ thống chạy hoàn hảo, và `teardown.sh` in "đã sạch" cho một hạ tầng vẫn đang tính tiền — cả hai đã xảy ra thật, [doc 22 lỗi 58](./22-Nhat-ky-Trien-khai-LZ-DIY.md).

Toàn bộ code ở [`landing-zone/network/`](../landing-zone/network/).

### Đọc bảng này thế nào

- **Phần ✅** dựng lên chạy thử được ngay, ~$0.78/giờ. Đây là toàn bộ xương sống network.
- **Phần ⏸** đã có code và `plan` kiểm chứng được; khi có license chỉ đổi `enable_appliances = true`. Phần định tuyến TGW/security/egress/spoke **không đổi** khi bật.
- **Phần ⬜** còn ở dạng thiết kế trong doc, chưa thành Terraform chạy được.

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
| `security-account-vpc` | `10.8.0.0/16` | Account `lz-security` — công cụ chạy *trong* VPC: scanner, SIEM collector, bastion |
| `3rd-party-vpc` | `10.9.0.0/16` | |
| **NonProd spokes** | `10.10.0.0/15` + `10.12.0.0/15` | `10.10` – `10.13` |
<!-- Hai /15, khong phai mot /14: xem ghi chu ngay sau bang -->
| **Prod spokes** | `10.20.0.0/14` | `10.20` – `10.23` |
| **Sandbox** | `10.60.0.0/14` | Không attach TGW |
| `logarchive-account-vpc` | `10.100.0.0/16` | Account `lz-logarchive` |
| `management-account-vpc` | `10.101.0.0/16` | Account management — **xem cảnh báo bên dưới** |
| Dự phòng mở rộng | `10.102.0.0/15` trở đi | Phần còn lại của `10.100.0.0/12` |

> **`10.10.0.0/14` không phải một CIDR hợp lệ.** Một `/14` bắt đầu ở bội số của 4 ở octet thứ hai, nên nó chỉ có thể là `10.8.0.0/14` (phủ `10.8`–`10.11`) hoặc `10.12.0.0/14` (`10.12`–`10.15`). Khoảng `10.10`–`10.13` mà bảng này cấp phát **không viết được thành một `/14` nào** — phải là hai `/15`.
>
> Bảng cũ ghi `10.10.0.0/14`, và nó sống sót nhiều tháng vì **chưa có công cụ nào phân tích nó**: con người đọc phần trong ngoặc và hiểu đúng ý, còn phần CIDR chưa ai chạy. Nó chỉ nổ khi `landing-zone/account-baseline/lint.sh` gọi `ipaddress.ip_network()` lên chính chuỗi đó. Các dải khác (`10.20.0.0/14`, `10.60.0.0/14`) hợp lệ — chỉ dòng này sai.

**Ba dải cuối là account nền tảng, không phải workload.** Chúng không nằm trong bảng gốc vì thiết kế ban đầu không hình dung security/logarchive/management là spoke — GuardDuty, Security Hub, Config đều là dịch vụ quản lý, và logarchive chỉ chứa S3, thứ không sống trong VPC. Cấp phát ở đây để tránh ai đó sáu tháng sau cấp trùng `10.8`.

> **VPC trong management account đi ngược một nguyên tắc của chính tài liệu này.** Management là account SCP không áp được, và [doc 22 lỗi 51](./22-Nhat-ky-Trien-khai-LZ-DIY.md) ghi lại đúng một lần hạ tầng mạng lọt vào đó rồi phải gỡ ra. Dải `10.101.0.0/16` tồn tại vì đã có người **chủ động chọn** dựng nó, không phải vì thiết kế khuyến nghị.
>
> Thêm một giới hạn kỹ thuật: StackSet `SERVICE_MANAGED` triển khai theo cây tổ chức và **AWS loại management account** khỏi các đợt triển khai đó. Management nằm trực tiếp dưới root, không thuộc OU nào. Nên VPC ở đó nhiều khả năng phải dựng bằng stack thường (`aws cloudformation create-stack`) chạy tại chỗ, không qua StackSet.

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

## 4b. Spoke VPC ở account khác

Hub nằm ở `lz-network`. Spoke nằm ở account workload. Ranh giới account chia công việc thành **bốn mắt xích**, và điều đáng nhớ là chúng không cùng một phía:

| Mắt xích | Ai làm được | Cách giải |
|---|---|---|
| Chấp nhận lời mời RAM | Chỉ account nhận | CLI, một lần mỗi account |
| Tạo VPC + subnet + attachment | Chỉ chủ sở hữu VPC | StackSet `SERVICE_MANAGED` chạy CloudFormation **bên trong** account đó |
| Gắn Route 53 Profile vào VPC | Chỉ chủ sở hữu VPC | `AWS::Route53Profiles::ProfileAssociation` trong chính template đó |
| Nối attachment vào route table | Chỉ chủ sở hữu **TGW** | Ngược lại — bắt buộc ở `lz-network` |

Ba dòng đầu cùng một bài toán, và **CloudFormation giải được hai trong ba** chỉ vì nó vốn đã chạy bên trong account đích. Đó là lý do thật để dùng StackSet ở đây — không phải "triển khai hàng loạt".

Dòng thứ tư đi ngược chiều nên không thể gộp vào template: chỉ chủ sở hữu TGW mới `associate` và `propagate` được.

### Ba lần apply, và vì sao không gộp được

```
apply 1   TGW + RAM share + principal association
          -> moi account bam nhan loi moi (ngoai Terraform)
apply 2   StackSet dung VPC + attachment o account dich
apply 3   noi attachment vao rtb-spokes, propagate vao rtb-security
```

Lần 2 cần lời mời **đã** được nhận. Lần 3 cần attachment **đã** tồn tại — data source lọc theo ID của TGW, mà TGW được tạo trong chính config này, nên lần đầu `for_each` không dựng được bộ khoá.

`check` block chỉ **cảnh báo**, không chặn apply. Nên nếu chạy thẳng `terraform apply` đầy đủ ngay từ đầu, StackSet sẽ chạy trước khi account kịp nhận lời mời và hỏng với một câu không nhắc gì tới RAM: `Transit Gateway tgw-xxx was deleted or does not exist`. Dùng `-target` cho lần đầu để tránh hẳn.

### Hai giới hạn đã đo được

**RAM không phân giải được tổ chức.** Share với principal trong phạm vi tổ chức — account ID hoặc OU ARN, `allow_external_principals = false` — bị từ chối, kể cả khi gọi từ management account. Thí nghiệm đối chứng đổi đúng một biến:

| Share | Principal | Kết quả |
|---|---|---|
| `--no-allow-external-principals` | account ID trong org | `OperationNotPermittedException` |
| `--allow-external-principals` | **cùng account ID đó** | `ACTIVE` |

RAM còn đánh dấu một account **đang ở trong** tổ chức là `"external": true`. Đường vòng hiện dùng là `allow_external_principals = true`: nới rào chắn tổ chức, và mỗi account phải bấm nhận lời mời. Đó là **khoản nợ chờ AWS Support**, không phải một lựa chọn thiết kế.

**StackSet không với tới management account.** `SERVICE_MANAGED` triển khai theo cây tổ chức và AWS loại management ra. Không thông báo nào nói vậy: `list-stack-instances` chỉ đơn giản thiếu một dòng. Muốn có VPC ở đó thì dùng stack thường chạy tại chỗ — và nên cân nhắc kỹ, vì đó là account SCP không áp được.

Chi tiết từng lỗi: [doc 22 mục 7y–7ad](./22-Nhat-ky-Trien-khai-LZ-DIY.md).

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

### 7.5. Chi phí cho mô hình dựng – xoá – dựng lại

Nếu bạn không chạy LZ thường trực mà **dựng khi cần rồi xoá đi**, bài toán chi phí khác hẳn mục 7.1–7.3.

#### Không có chi phí khởi tạo

| Hạng mục | Phí ban đầu |
|---|---|
| Tạo AWS account, OU, SCP | **$0** |
| IAM Identity Center | **$0** |
| Subscribe Marketplace (Palo Alto, F5) | **$0** — chỉ tính tiền khi instance chạy |
| Transit Gateway (bản thân nó) | **$0** — chỉ tính phí attachment |
| Internet Gateway | **$0** |
| Gateway endpoint (S3, DynamoDB) | **$0** |
| Terraform, code | **$0** |

Gần như **toàn bộ** hạ tầng network tính theo **giờ**. Xoá xong là ngừng tính tiền ngay. Không có phí cam kết, không có phí thiết lập.

#### Chi phí một phiên làm việc

Giai đoạn 1 (chưa có Palo Alto/F5, 1 AZ, 2 spoke):

| Thời lượng phiên | Không firewall<br>$0.34/giờ | Có firewall<br>$0.74/giờ |
|---|---|---|
| 2 giờ | $0.7 | $1.5 |
| **4 giờ** (điển hình) | **$1.4** | **$3.0** |
| 8 giờ (một ngày làm việc) | $2.7 | $5.9 |
| 24 giờ | $8 | $18 |
| **Quên xoá 3 ngày cuối tuần** | $25 | **$53** |
| **Quên xoá 1 tháng** | $248 | **$540** |

Mỗi phiên có khoảng **30 phút hao phí**: `apply` ~10–15 phút (Network Firewall chiếm ~5 phút), `destroy` ~10–15 phút. Nên phiên ngắn hơn 1 tiếng thì phần lớn thời gian là chờ.

Khi có Palo Alto và F5, license tính theo giờ sẽ đẩy con số lên **~$3–6/giờ** — phiên 4 tiếng thành $12–25. Lúc đó nên cân nhắc `terraform apply -target` để chỉ dựng phần đang cần thử.

#### Cái gì nên giữ, cái gì nên xoá

Đây là phần quan trọng nhất. **Đừng xoá hết** — có những lớp gần như miễn phí để giữ nhưng rất phiền khi dựng lại.

| Lớp | Giữ hay xoá | Chi phí nếu giữ | Lý do |
|---|---|---|---|
| Organizations, OU, SCP | **Giữ** | $0 | Miễn phí, và SCP không tốn gì |
| AWS account | **Giữ** (không xoá được) | $0 | Đóng account có hạn mức, email không tái dùng |
| IAM Identity Center | **Giữ** | $0 | Đổi identity source làm mất hết assignment |
| S3 state bucket + DynamoDB lock | **Giữ** | ~$0.10/tháng | Mất state là mất khả năng destroy |
| CloudTrail org trail | Tuỳ | ~$1–3/tháng | Chỉ tốn phí lưu S3 |
| **AWS Config** | **Xoá khi rảnh** | ~$10–30/tháng | Tính theo configuration item |
| **GuardDuty** | **Xoá khi rảnh** | ~$15–40/tháng | |
| **Security Hub** | **Xoá khi rảnh** | ~$10–25/tháng | |
| **Toàn bộ lớp network** | **Xoá** | **~$540/tháng** | Khoản lớn nhất, và thuần theo giờ |

Hai cấu hình nền:

```text
Giu nen tang + xoa network:        ~$35–100/thang
Xoa het tru Organizations/SSO/S3:  ~$1–3/thang
```

Khuyến nghị: **giữ Organizations + Identity Center + S3 state, xoá phần còn lại.** Dựng lại lớp network chỉ mất 15 phút; dựng lại Identity Center và account thì không.

#### Bốn cái bẫy của mô hình dựng–xoá

| Bẫy | Chi tiết | Cách tránh |
|---|---|---|
| **Route 53 hosted zone** | ~$0.50/zone và **không tính theo giờ** | AWS không tính phí nếu xoá trong vòng 12 giờ kể từ khi tạo — phiên ngắn thì miễn phí, phiên dài thì mất $0.50/zone |
| **KMS CMK** | ~$1/tháng, và **xoá phải chờ 7–30 ngày** | Vẫn tính tiền trong thời gian chờ. Dùng key AWS-managed cho demo |
| **AWS Config ghi lại từ đầu** | Mỗi lần dựng lại là ghi lại toàn bộ configuration item | ~$0.30–0.60 mỗi lần rebuild. Nhỏ nhưng khác 0 |
| **EIP mồ côi** | Destroy fail giữa chừng để lại EIP | ~$3.6/tháng âm thầm. `teardown.sh` có kiểm tra mục này |

Bẫy Route 53 đáng nhớ nhất vì nó phá vỡ giả định "mọi thứ tính theo giờ": một PHZ tạo lúc sáng và xoá lúc tối cùng ngày thì miễn phí, nhưng để qua đêm thành $0.50 cho cả tháng đó.

#### Rủi ro thật không phải là giá theo giờ

$0.74/giờ là rẻ. Rủi ro là **quên xoá**: một tháng là $540 cho thứ bạn không dùng.

Ba lớp bảo vệ:

1. **`teardown.sh`** — destroy xong tự kiểm tra không còn NAT, EIP, firewall, TGW, endpoint, load balancer nào sót.
2. **Budget cảnh báo** — đặt ngưỡng thấp, ví dụ $20/tháng, cảnh báo qua email:

```hcl
resource "aws_budgets_budget" "demo_guard" {
  name         = "lz-demo-guard"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["ban@example.com"]
  }
}
```

Cả ba đã có code chạy được ở [`landing-zone/billing-guard/`](../landing-zone/billing-guard/) — dựng một lần ở management account, tốn ~$0, **không nằm trong teardown của demo**.

3. **Quét theo tag** — mọi resource demo gắn `Ephemeral=true`, quét định kỳ:

```bash
aws resourcegroupstaggingapi get-resources --region ap-southeast-1 \
  --tag-filters "Key=Ephemeral,Values=true" \
  --query 'length(ResourceTagMappingList)' --output text
```

Đặt lệnh này vào một cron hằng ngày trên máy bạn, khác 0 thì nhắc. Rẻ hơn nhiều so với đọc hoá đơn cuối tháng.

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
| **[`landing-zone/network`](../landing-zone/network/)** | **Giai đoạn 1 đầy đủ**: TGW 4 route table, security VPC + Network Firewall, egress VPC, ingress NLB, spoke, gateway endpoint | **~$0.34–0.77/giờ** |
| [`demo/centralized-network`](../demo/centralized-network/) | Bản tối giản: TGW + egress + cách ly spoke | ~$0.21/giờ |
| [`demo/centralized-network-multiaccount`](../demo/centralized-network-multiaccount/) | Ba account: RAM share TGW, cross-account PHZ | ~$0.22/giờ |

`network-lz-full` là bộ chính. Kịch bản **6 bước**, mỗi bước bật thêm một phần bằng biến:

| Bước | Bật gì | ~$/giờ | Kiểm chứng được |
|---|---|---|---|
| 1 | Chưa có firewall | $0.34 | Spoke không IGW/NAT, egress tập trung, ingress |
| 2 | Firewall chế độ `alert` | $0.74 | Mọi luồng qua security VPC, đọc được log |
| 3 | Firewall chế độ `drop` | $0.74 | Chặn thật: port có rule vs không có rule |
| 4 | Sửa `east_west_rules` | $0.74 | **Mở/đóng luồng VPC-to-VPC mà không đụng route** |
| 5 | Interface endpoint | $0.77 | Endpoint trong security VPC, vẫn được thanh tra |
| 6 | CloudFront + AWS WAF | $0.78 | Khoá origin, WAF chặn SQLi |

Ba script đi kèm:

| Script | Khi nào chạy |
|---|---|
| `plan-check.sh` | **Trước khi apply** — 9 tổ hợp biến, không tạo gì |
| `verify.sh` | Sau khi apply |
| `teardown.sh` | Khi xong |

### 12.2. Palo Alto và F5 – code sẵn, chưa bật

`appliances.tf` đã có đầy đủ Terraform cho GWLB + Palo Alto + F5, `enable_appliances = false` mặc định.

Bật lên là **rewire đường ingress**, không phải chỉ thêm resource:

| | Tắt | Bật |
|---|---|---|
| Public subnet `0.0.0.0/0` | → IGW | → **GWLBe** (gói về cũng bị PA thanh tra) |
| NLB `target_type` | `ip` (app trong spoke) | `instance` (F5) |
| Edge route table gắn vào IGW | không có | có |

`plan-check.sh` kiểm chứng được phần này **ngay bây giờ** mà chưa cần subscribe Marketplace — nó lấy một AMI Amazon Linux làm AMI giả, vì `plan` chỉ cần một AMI ID hợp lệ. Script còn kiểm tra plan có chứa đúng các thiết lập dễ sai: `appliance_mode_support = enable`, `source_dest_check = false`, edge route table, và NLB trỏ vào F5 chứ không trỏ thẳng app.

Chi phí khi bật: **~$3–6/giờ** (license Marketplace tính theo giờ chiếm phần lớn).

### 12.3. Còn thiếu trong demo

| Thành phần | Vì sao |
|---|---|
| 3rd-party VPC + VPN | Cần customer gateway thật của đối tác |
| SCP khoá Internet | Làm `terraform destroy` kẹt — chỉ áp ở môi trường thật |
| Domain riêng + ACM | Demo dùng hostname mặc định `*.cloudfront.net` |
| NAT/firewall nhiều AZ | Demo 1 AZ để tiết kiệm |

Buổi thực hành 4 tiếng ≈ **$3**. Quên xoá một tháng ≈ **$550** — nên phần kiểm tra sau khi destroy là bắt buộc, không phải tuỳ chọn.

### 12.4. Nguyên tắc cho code demo

| Nguyên tắc | Lý do |
|---|---|
| **Không tạo AWS account** | Account không xoá được, chỉ đóng được; email không tái dùng |
| **Không attach SCP** | SCP chặn IGW/NAT làm `terraform destroy` kẹt |
| **Không bật deletion protection** | Chặn destroy |
| **Tag `Ephemeral=true` mọi thứ** | Tìm được resource sót |
| **1 AZ thay vì 2** | Giảm nửa chi phí NAT và firewall endpoint |
| **Appliance mặc định tắt** | License PA/F5 tính theo giờ, rất đắt |
| **Mọi phần đắt tiền đều có công tắc** | Bật đúng thứ đang cần thử |

---

## 13. Việc còn lại

Trạng thái đầy đủ ở [mục 0](#0-trạng-thái-triển-khai). Phần này là **thứ tự nên làm tiếp**.

```text
1. CHAY DEMO GIAI DOAN 1                          ← lam truoc tien
   ./plan-check.sh   -> kiem chung code, khong tao gi
   terraform apply   -> 6 buoc trong landing-zone/network/README.md
   ./verify.sh       -> phai xanh het
   ./teardown.sh
   Chi phi: ~$3 cho buoi 4 tieng

2. THAY NLB BANG ALB + AWS WAF cho giai doan 1
   Ly do: AWS WAF khong gan duoc vao NLB (muc 2.1).
   Lap phan lon khoang trong bao mat trong luc cho PA/F5.

3. CAC LAYER LZ CON LAI thanh code chay duoc
   DA XONG: tf-backend (state), organization (OU + 4 SCP),
            permission-sets (17 set), billing-guard
            + ban Control Tower de doi chieu, mac dinh tat
   CON LAI: logging, security tooling, account-baseline

4. 3RD-PARTY VPC + VPN
   Khi co thong tin customer gateway cua doi tac.

5. PALO ALTO + F5
   Code da san (appliances.tf). Khi co license chi doi
   enable_appliances = true.
   Hoac hoc ngay bang ban PAYG theo gio - doc 18 muc 0.
```

> **Cập nhật mục 3:** bốn layer nền tảng đã thành code chạy được trong [`landing-zone/`](../landing-zone/) — xem [doc 20](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) (state, quy trình thay đổi), [doc 19](./19-Permission-Set-cho-Landing-Zone.md) (permission set) và [doc 21](./21-Control-Tower-vs-DIY.md) (OU + SCP, cả hai hướng). Kiểm chứng cả 5 layer: `cd landing-zone && ./plan-all.sh`.
>
> Riêng **network vẫn chỉ có bản demo** — `landing-zone/network` gắn `Ephemeral = "true"` và được thiết kế để xoá. Nâng nó thành layer thường trực multi-account là việc còn lại lớn nhất của tài liệu này.

**Vì sao mục 1 trước tiên:** nó kiểm chứng bảng định tuyến ở [mục 4](#4-transit-gateway--bảng-chân-lý-duy-nhất) — chỗ mà một ô sai gây ra sự cố rất khó lần ra nguyên nhân khi đã lên môi trường thật. Phát hiện lúc demo tốn $3; phát hiện lúc production tốn nhiều hơn thế rất nhiều.

**Vì sao mục 5 để cuối:** bật Palo Alto và F5 **không đụng** tới định tuyến TGW, security VPC, egress VPC hay spoke. Chúng chỉ chèn vào phần trên của ingress VPC ([mục 2.1](#21-giai-đoạn-1--kiến-trúc-khi-chưa-có-palo-alto-và-f5)). Làm sau không phải trả giá bằng việc sửa lại phần đã dựng.
