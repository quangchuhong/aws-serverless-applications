# Control Tower vs DIY

Ví dụ 21: Hai cách dựng nền tảng Landing Zone, code cả hai để đối chiếu.

> Code: [`landing-zone/organization/`](../landing-zone/organization/) (DIY) và [`landing-zone/control-tower/`](../landing-zone/control-tower/) (mặc định tắt).
>
> **Bản dùng thật cho lab trong repo này là DIY.** Bản Control Tower viết sẵn để so sánh và để chuyển sang khi cần.

---

## 0. Trạng thái triển khai

| Phần | Trạng thái |
|---|---|
| DIY: Organization + cây OU 2 cấp | ✅ Đã viết |
| DIY: 4 SCP, gom theo giới hạn của AWS | ✅ Đã viết |
| DIY: `check` bắt vượt giới hạn ký tự/số lượng | ✅ Đã viết |
| CT: landing zone + version + manifest | ✅ Đã viết, **mặc định tắt** |
| CT: hai account lõi, controls theo OU | ✅ Đã viết, **mặc định tắt** |
| `plan-all.sh` chạy cả 5 layer | ✅ Đã viết |
| Kiểm chứng kích thước SCP | ✅ Đã chạy — lớn nhất 29% giới hạn |
| Kiểm chứng tham chiếu `var.`/`local.` | ✅ Đã chạy — 0 lỗi trên 5 layer |
| `terraform validate` / `plan` | ⏸ Chưa chạy được — `registry.terraform.io` bị chặn (403 ở gateway) |
| Control identifier của CT | ⬜ Phải tự liệt kê bằng `aws controltower list-controls` |

---

## 1. Khác nhau ở đâu

| | **DIY** | **Control Tower** |
|---|---|---|
| Bản chất | Terraform gọi thẳng API Organizations | Dịch vụ quản trị, có state riêng |
| OU | Bạn tự tạo, tuỳ ý | CT tạo sẵn Security + Sandbox |
| Guardrail | SCP bạn viết | *Controls* — SCP **và/hoặc** Config rule |
| Tạo account | Doc 09 | Account Factory / AFT |
| Nâng cấp | Không có khái niệm | Đổi `landing_zone_version` rồi apply |
| Drift | `terraform plan` | CT có drift detection riêng |
| Gỡ ra | `terraform destroy` | Quy trình thủ công nhiều bước |
| **Chi phí nền** | **$0** | **AWS Config chạy liên tục** |

### Điểm khác quan trọng nhất

DIY dùng SCP — **SCP miễn phí và chỉ đánh giá lúc gọi API**. Control Tower có nhiều control dựa trên **AWS Config**, và Config **tính tiền theo configuration item ghi được + rule evaluation**, chạy liên tục bất kể bạn có gọi API hay không.

Đó là lý do một bên $0 và một bên không.

Đổi lại, control dựa trên Config làm được thứ SCP không làm được: **phát hiện** vi phạm đã xảy ra. SCP chỉ **ngăn** hành động; nó không cho bạn biết "hiện có 3 security group đang mở port 22 ra Internet".

| | SCP (DIY) | Config rule (CT) |
|---|---|---|
| Ngăn hành động | ✅ | ❌ |
| Phát hiện vi phạm đã có | ❌ | ✅ |
| Chi phí | $0 | Theo lượng |

Muốn cả hai mà vẫn DIY: bật AWS Config riêng ở những account cần, thay vì bật toàn bộ qua CT. Bạn kiểm soát được phạm vi và chi phí.

---

## 2. Vì sao repo này chọn DIY cho lab

Không phải vì DIY tốt hơn. Vì nó khớp với ràng buộc đã đặt ra từ đầu:

> *"build xong sẽ xoá đi để không tốn chi phí, khi nào cần tôi lại deploy lại"*

| Ràng buộc | DIY | Control Tower |
|---|---|---|
| ~$0 khi không dùng | ✅ | ❌ Config chạy liên tục |
| Xoá giữa các buổi | ✅ `terraform destroy` | ❌ Decommission thủ công |
| Dựng lại nhanh | ✅ vài phút | ❌ hàng giờ |
| Đọc được toàn bộ cơ chế | ✅ SCP nằm trong code | ⚠️ Một phần do CT quản |

Điểm cuối đáng nói riêng: với DIY, mọi thứ chặn bạn đều nằm trong file `scp.tf` đọc được. Với Control Tower, một phần hành vi do dịch vụ quyết định — tốt cho production, nhưng học thì DIY rõ hơn.

---

## 3. Khi nào nên chuyển sang Control Tower

| Dấu hiệu | Vì sao CT hợp hơn |
|---|---|
| Cần bằng chứng tuân thủ cho kiểm toán | Config rule có lịch sử vi phạm, SCP không |
| Trên ~10 account, nhiều team tự vend | Account Factory chuẩn hoá tốt hơn script tự viết |
| Cần dashboard tuân thủ sẵn có | CT có sẵn, DIY phải tự dựng |
| Công ty đã dùng CT ở nơi khác | Nhất quán quan trọng hơn tối ưu |
| Không có người chuyên trách platform | CT gánh phần bảo trì |

Ngược lại, giữ DIY khi: cần chi phí ~$0, cần xoá–dựng lại thường xuyên, cần kiểm soát chính xác từng dòng policy, hoặc đang học.

---

## 4. Bốn SCP của bản DIY

AWS giới hạn **5 policy gắn vào một root/OU/account**, `FullAWSAccess` chiếm 1 → còn **4**. Nên không viết 10 SCP nhỏ mà gom lại.

| SCP | Gắn vào | Chặn gì |
|---|---|---|
| `baseline` | Root | Rời tổ chức, tắt CloudTrail/Config/GuardDuty, root user, tạo IAM user, mở S3 public access block |
| `region_lock` | Root | Mọi region ngoài `allowed_regions` |
| `network_lock` | Workloads, Data Analytics, Sandbox | IGW/NAT/EIP/TGW/VPN/peering, public IP lúc launch |
| `prod_guard` | Workloads/Production | Xoá snapshot/backup, xoá KMS key, tắt versioning S3 |

Kích thước thực tế (giới hạn **5120 ký tự**/SCP):

```
baseline      ~1511    29%
region_lock    ~709    14%
network_lock  ~1013    20%
prod_guard     ~649    13%
```

Số policy trên mỗi target (giới hạn 4 tự viết):

```
ROOT                    2
Workloads               1
Workloads/Production    1
Data Analytics          1
Sandbox                 1
```

Cả hai giới hạn đều có `check` block trong `scp.tf` bắt tự động.

### Ba chi tiết dễ sai

**1. `region_lock` phải có `NotAction` cho dịch vụ toàn cầu.** IAM, Organizations, Route 53, CloudFront, STS, billing… luôn gọi tới một region cố định (thường `us-east-1`). Chặn chúng theo `aws:RequestedRegion` là **tự khoá mình ra ngoài**.

**2. `allowed_regions` bắt buộc có `us-east-1`.** CloudFront, WAF scope `CLOUDFRONT`, ACM cho CloudFront và nhiều API billing chỉ tồn tại ở đó. Có `validation` chặn nếu thiếu.

**3. `Infrastructure` không bị `network_lock`.** Network account sống ở đó và cần đúng những action bị chặn. Đây là lý do cây OU phải khớp với thiết kế mạng ở doc 13.

---

## 5. Rà chéo: SCP của DIY vs controls của CT

Nếu sau này chuyển sang CT, đây là chỗ trùng lặp cần biết:

| SCP của DIY | CT có control tương đương? |
|---|---|
| `baseline` — bảo vệ CloudTrail/Config | ✅ CT bắt buộc, không tắt được |
| `baseline` — chặn root user | ✅ Control có sẵn |
| `baseline` — chặn tạo IAM user | ⚠️ Không có sẵn — **giữ SCP này** |
| `region_lock` | ✅ `governed_regions` + control region deny |
| `network_lock` | ⚠️ Có control chặn Internet cho VPC, nhưng **không phủ hết** TGW/VPN/peering — **giữ SCP này** |
| `prod_guard` | ⚠️ Rải rác nhiều control — **giữ SCP này** đơn giản hơn |

Kết luận thực dụng: chuyển sang CT thì vẫn **giữ SCP riêng cho `network_lock` và `prod_guard`**. Control Tower không cấm bạn gắn thêm SCP — nhưng nhớ giới hạn 5 policy/target, và controls của CT cũng chiếm slot.

---

## 6. Kiểm chứng cả hai bản

```bash
cd landing-zone

./plan-all.sh --no-plan     # init + validate, khong can credential
./plan-all.sh               # them plan, can credential management account
./plan-all.sh organization  # chi mot layer
```

Bản Control Tower có `enable_landing_zone = false` nên `plan` ra **0 resource** — kiểm chứng được cú pháp mà không tạo gì, giống cách làm với Palo Alto/F5 ở `demo/network-lz-full/appliances.tf`.

### Kiểm chứng SCP sau khi apply — quan trọng hơn kiểm chứng phần cho phép

SCP chặn sai thì **im lặng** cho tới khi có người vướng:

```bash
# Account Workloads - PHAI bi tu choi
aws ec2 create-internet-gateway --profile lz-app-dev

# Ngoai allowed_regions - PHAI bi tu choi
aws ec2 describe-vpcs --region eu-west-1 --profile lz-app-dev

# Account Infrastructure - PHAI THANH CONG
aws ec2 create-internet-gateway --profile lz-network

# SCP nao dang ap cho mot account
aws organizations list-policies-for-target \
  --target-id <account-id> --filter SERVICE_CONTROL_POLICY
```

Dòng thứ ba quan trọng ngang ba dòng kia — siết quá tay cũng là lỗi.

---

## 7. Bật SCP từng cái một

```hcl
enable_scp = {
  baseline     = true
  region_lock  = false
  network_lock = false
  prod_guard   = false
}

scp_dry_run = true    # TAO policy nhung KHONG GAN
```

`scp_dry_run = true` tạo policy để đọc trên console mà chưa chặn gì. SCP gắn nhầm có thể khoá cả tổ chức ra ngoài — bước này đáng vài phút.

Thứ tự: `baseline` → `region_lock` → `network_lock` → `prod_guard`. Sau mỗi bước, chạy lại các thao tác bình thường rồi mới bật cái tiếp theo. Bật hết một lượt rồi có gì hỏng thì không biết do cái nào.

---

## 8. Sổ quyết định

| # | Quyết định | Lý do | Đánh đổi |
|---|---|---|---|
| D1 | DIY cho lab, CT viết sẵn nhưng tắt | Giữ mô hình ~$0, dựng–xoá được | Không có Config rule để phát hiện vi phạm đã có |
| D2 | Gom thành 4 SCP thay vì nhiều SCP nhỏ | AWS giới hạn 5 policy/target | Mỗi SCP làm nhiều việc, đọc khó hơn |
| D3 | `scp_dry_run` mặc định **true** | SCP gắn nhầm khoá được cả tổ chức | Thêm một bước trước khi thật sự chặn |
| D4 | `create_organization` mặc định **false** | Đa số đã có org; đặt true khi đã có sẽ lỗi | Greenfield phải tự đổi thành true |
| D5 | `prevent_destroy` trên org và OU | Xoá org = tách mọi account con | `destroy` cần hai bước có chủ đích |
| D6 | `enable_landing_zone` mặc định **false** | CT không đảo ngược dễ | Phải đổi biến khi thật sự dùng |
| D7 | Control identifier là **biến**, không hardcode | Identifier thay đổi theo version CT | Người dùng phải tự liệt kê trước |
| D8 | `network_lock` không gắn vào Infrastructure | Network account cần đúng những action đó | Phải đặt account đúng OU |
| D9 | `check` bắt giới hạn SCP thay vì để apply lỗi | Lỗi lúc plan rẻ hơn lỗi lúc apply | `check` chỉ cảnh báo, không chặn apply |

---

## 9. Việc còn lại

| # | Việc | Chặn bởi |
|---|---|---|
| 1 | Chạy `./plan-all.sh` ở môi trường có registry | `registry.terraform.io` bị chặn khi soạn tài liệu |
| 2 | Chuyển account vào đúng OU, cập nhật `accounts_by_scope` | Cần (1) |
| 3 | Kiểm chứng 4 lệnh SCP ở mục 6 | Cần (2) |
| 4 | Thêm `landing-zone/organization` vào `local.layers` của tf-backend | — |
| 5 | Account vending có code thật | doc 09 |
| 6 | Nâng network từ demo thành layer thường trực | doc 17 |

---

## Liên quan

| Tài liệu | Quan hệ |
|---|---|
| [06 – AWS Landing Zone](./06-Aws-Landing-Zone.md) | Nền tảng — layer DIY hiện thực phần Organizations của nó |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Account Factory (CT) vs vending tự viết (DIY) |
| [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) | Nguồn của SCP `network_lock` |
| [19 – Permission set](./19-Permission-Set-cho-Landing-Zone.md) | SCP là trần trên permission set — dùng được với cả hai bản |
| [20 – Vận hành LZ](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
