# Network hub

TGW + security VPC + egress VPC. Chạy ở **management account**, tạo mọi thứ trong **account network** qua `assume_role`.

**Mặc định TẮT** (`enable = false`) — `terraform plan` ra 0 resource.

> **Đây là layer duy nhất trong `landing-zone/` tốn tiền đáng kể.** Bảy layer kia ~$0/ngày. Đọc bảng chi phí bên dưới trước khi bật.

---

## Chi phí — đọc trước

Giá tham khảo `ap-southeast-1`, **2 AZ**, chưa tính lưu lượng:

| Thành phần | Số lượng | ~USD/tháng |
|---|---:|---:|
| **Network Firewall endpoint** | 2 | **~570** |
| NAT Gateway | 2 | ~66 |
| TGW attachment (security, egress) | 2 | ~72 |
| TGW attachment mỗi spoke | mỗi cái | ~36 |
| Interface endpoint (4 dịch vụ × 2 AZ) | 8 | ~58 |
| Elastic IP gắn NAT | 2 | $0 |
| Transit Gateway | 1 | $0 |
| **Tổng, chưa có spoke nào** | | **~770** |

Cộng lưu lượng: NAT ~$0.045/GB, firewall ~$0.065/GB, TGW ~$0.02/GB mỗi chặng.

**Bốn cần gạt, theo thứ tự tác động:**

| Cần gạt | Tiết kiệm | Đánh đổi |
|---|---:|---|
| `availability_zones` còn 1 | ~335 | Mất HA hoàn toàn — AZ đó hỏng là cả LZ mất Internet và mất east-west |
| `enable_firewall = false` | ~570 | Mất thanh tra **và** mất cách ly east-west. Đây là đổi kiến trúc, không phải tiết kiệm |
| `enable_interface_endpoints = false` | ~58 | Spoke không dùng được SSM Session Manager |
| Bớt `interface_endpoint_services` | ~15/cái | Tuỳ dịch vụ |

> Để **thử code**, `availability_zones = ["ap-southeast-1a"]` là đủ: đúng mọi đường đi, chỉ không có dự phòng. ~$435/tháng thay vì ~$770 — và nhớ `terraform destroy` sau khi thử.

---

## Phạm vi — giai đoạn 1 theo [doc 17 mục 2.1](../../docs/17-Network-LZ-Design-Guide.md)

| | Có | Chưa |
|---|---|---|
| TGW + 3 route table + RAM share | ✅ | |
| security VPC + Network Firewall | ✅ | |
| egress VPC + IGW + NAT | ✅ | |
| Interface endpoint + PHZ | ✅ | |
| Nối attachment của spoke | ✅ | |
| ingress VPC (Palo Alto + F5) | | ⏸ chờ license Marketplace |
| 3rd-party VPC + VPN | | ⬜ |
| Route 53 Profile | | ⬜ |

Doc 17 mục 2.1 nói rõ: phần định tuyến TGW/security/egress/spoke **giữ nguyên từng dòng** khi thêm appliance. Nên làm giai đoạn 1 trước là kiểm chứng được chỗ khó nhất mà không phải chờ license.

---

## Vì sao spoke VPC không nằm trong layer này

Spoke ở account workload, mỗi account một provider — mà **provider không sinh động được bằng `for_each`**. Sáu account là sáu alias viết tay, và account thứ bảy là sửa code.

Nên chia thế này:

```
layer nay          TGW (share qua RAM) + hub VPC + route table
account workload   tu tao VPC, tu attach vao TGW da share
layer nay          noi attachment do vao rtb-spokes + rtb-security
```

Bước cuối **bắt buộc** ở đây: chỉ chủ sở hữu TGW mới `associate` và `propagate` được.

```bash
terraform output -raw paste_spoke_vpc   # khoi HCL cho account workload
```

> **Bỏ bước nối = attachment tồn tại, `State: available`, và không thuộc route table nào.** Không lỗi, không cảnh báo, không một gói tin nào đi qua. Có `check` block báo khi `spoke_attachments` rỗng — nhưng nó không biết bạn vừa tạo thêm cái thứ ba.

---

## Bảng chân lý TGW

[Doc 17 mục 4](../../docs/17-Network-LZ-Design-Guide.md) gọi đây là bảng quan trọng nhất của cả thiết kế — sai một ô là có luồng lọt firewall hoặc đứt kết nối.

| Route table | Associate | Propagate | Route tĩnh |
|---|---|---|---|
| `rtb-spokes` | mọi spoke | *(không)* | `0.0.0.0/0` → security |
| `rtb-security` | security | **mọi spoke** | `10.0.0.0/16` → ingress<br>`0.0.0.0/0` → egress |
| `rtb-egress` | egress | *(không)* | `10.0.0.0/8` → security |

**Bốn quy tắc bất biến:**

| | |
|---|---|
| **QT1** | Chỉ `rtb-security` được propagate. Propagate ở `rtb-egress` khiến gói trả về đi thẳng tới spoke, bỏ qua firewall — và luồng bất đối xứng thì firewall stateful drop luôn |
| **QT2** | Route tĩnh cho mọi đích **không phải spoke** phải đặt trước `0.0.0.0/0`. Thiếu `10.0.0.0/16 → ingress` thì gói trả lời của app rơi vào egress VPC; client không bao giờ nhận được phản hồi |
| **QT3** | `appliance_mode_support = "enable"` trên attachment của security VPC. Thiếu thì luồng east-west cross-AZ đi qua hai endpoint khác nhau và bị drop |
| **QT4** | Thêm VPC mới vào network account = thêm route tĩnh vào `rtb-security` → `extra_security_routes` |

QT3 **chỉ lộ ra khi chạy từ hai AZ trở lên**. Với một AZ nó không bao giờ sai, nên đừng dùng bản một-AZ để kết luận là đã đúng.

---

## Khác bản demo ở đâu

> **Bản trước của mục này sai ba chỗ** — nó viết rằng [`demo/network-lz-full`](../../demo/network-lz-full/) chạy *"một AZ"*, dùng chung route table, và tắt cứng `delete_protection`. Đọc code demo thì cả ba đều không đúng: demo có `validation` **từ chối** dưới 2 AZ, route table `security_tgw` / `security_firewall` / `egress_tgw` đều `for_each = local.azs`, và `delete_protection = !var.ephemeral` là một biến. Ai đọc mục cũ sẽ chọn nhầm codebase vì một lý do không có thật.

Khác biệt thật nằm ở **mô hình account**, không ở kỹ thuật định tuyến:

| | `landing-zone/network` | `demo/network-lz-full` |
|---|---|---|
| Account | Chạy từ management, tạo mọi thứ trong **account network** qua `assume_role` | **Một account** — nơi credential trỏ tới |
| Spoke VPC | Do account workload tự tạo, layer này chỉ nối attachment | Demo **tự tạo** spoke qua biến `spokes` |
| EC2 thử | không | `enable_test_instances = true` |
| ingress VPC + NLB | ⏸ chờ license | ✅ `enable_ingress = true` |
| CloudFront + WAF | không | ✅ `enable_cdn` (tuỳ chọn) |
| Palo Alto / F5 | không | ⏸ code sẵn, `enable_appliances = false` |
| Vòng đời | Hạ tầng thường trực | `ephemeral` — dựng, xem, xoá |

**Chọn cái nào:** muốn thấy **cả chuỗi** chạy end-to-end trong một buổi thì dùng demo. Muốn hạ tầng mạng **thường trực của LZ**, nằm đúng account `lz-network`, spoke ở account workload — thì dùng layer này.

Hai bộ code **không thay thế nhau** và không dùng chung state.

---

## Chạy

```bash
cd landing-zone/network
cp terraform.tfvars.example terraform.tfvars

cd ../organization && terraform output account_ids    # lay network_account_id
cd ../network
```

Điền `network_account_id`, đổi `enable = true`.

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`aws_networkfirewall_firewall` mất **vài phút** ở `PROVISIONING` — bình thường, đừng ngắt.

---

## Kiểm chứng

```bash
# 1. Hub da dung chua
aws network-firewall describe-firewall --firewall-name <project>-fw \
  --profile <network> --region <region> \
  --query 'FirewallStatus.Status' --output text
# PHAI la READY

# 2. TGW da share chua - hoi tu ACCOUNT WORKLOAD
aws ec2 describe-transit-gateways --profile <workload> --region <region> \
  --query 'TransitGateways[].TransitGatewayId' --output text
# Rong = RAM share chua toi
```

**Kiểm đường đi thật** — đừng tin route table, gửi gói tin. Tạo một EC2 trong spoke (không cần IP public, SSM đi qua interface endpoint):

```bash
aws ssm start-session --target <instance-id> --profile <workload>
# trong phien:
curl -s https://checkip.amazonaws.com
```

IP trả về **phải** nằm trong `terraform output nat_public_ips`. Ra IP khác nghĩa là có đường ra Internet nào đó không qua egress VPC — đúng thứ thiết kế này sinh ra để ngăn.

---

## Trước khi bật `firewall_mode = "drop"`

Chạy `"alert"` **ít nhất một tuần**, rồi đọc log:

```bash
aws s3 ls s3://<project>-fw-logs-<network-account>/alert/ --recursive \
  --profile <network> | tail
```

Tìm dòng `UNMATCHED east-west` — đó là **bản đồ thật** về ai đang gọi ai. Viết `east_west_rules` từ đó, rồi mới đổi sang `"drop"`.

> Bật `"drop"` ngay từ đầu là cách nhanh nhất để làm đứt một luồng không ai biết là có tồn tại — và triệu chứng sẽ xuất hiện ở chỗ chẳng liên quan gì tới network.

---

## Xoá

```bash
terraform apply   -var allow_destroy=true    # tat bao ve - RIENG mot lan
terraform destroy -var allow_destroy=true
```

`allow_destroy` gỡ ba thứ cùng lúc: `delete_protection`, `subnet_change_protection`, và `force_destroy` cho bucket log firewall.

**Bắt buộc `apply` một lần riêng.** Hai cái đầu là thuộc tính phía AWS — đổi chúng gọi `UpdateFirewallDeleteProtection` và `UpdateSubnetChangeProtection` thật. Đặt biến rồi destroy ngay thì Terraform vẫn gặp firewall đang khoá.

`plan` sẽ cảnh báo khi biến này còn bật:

```
Warning: Check block assertion failed
  allow_destroy = true: Network Firewall dang TAT delete_protection ...
```

Chi tiết cả hai cổng khoá: [TEARDOWN.md mục 2](../TEARDOWN.md#2-gỡ-chặn-trước-khi-destroy).

---

## Liên quan

| | |
|---|---|
| [doc 17](../../docs/17-Network-LZ-Design-Guide.md) | **Nguồn sự thật** — kiến trúc, bảng CIDR, bảng chân lý TGW, chi phí |
| [doc 13](../../docs/13-Centralized-Ingress-Egress-Network.md) | Vì sao khoá Internet ở mọi account |
| [doc 15](../../docs/15-Security-VPC-Network-Firewall.md) | Chi tiết Network Firewall, rule group |
| [`../organization`](../organization/) | `network_lock` SCP và phần miễn trừ cho account network |
| [`demo/network-lz-full`](../../demo/network-lz-full/) | Bản một-account để dựng thử rồi xoá |
