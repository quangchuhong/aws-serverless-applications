# Vận hành chuỗi ingress và appliance

Tài liệu 26: vận hành hằng ngày cho chiều **vào** — CloudFront, WAF, Palo Alto, F5, NLB.

Thiết kế và lý do chọn từng tầng ở [14 – Ingress chain](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md). Cấu hình chi tiết F5 ở [18](./18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md). Bài này chỉ nói: **ai sửa gì, ở đâu, và đọc gì khi hỏng.**

Tương đương [25 – Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md), nhưng cho chuỗi ingress.

---

## 0. Trạng thái

| | |
|---|---|
| **Code** | [`demo/network-lz-full/`](../demo/network-lz-full/) — `vpc-ingress.tf`, `cdn.tf`, `appliances.tf` |
| **Bật bằng** | `enable_ingress` · `enable_cdn` · `enable_appliances` — ba công tắc độc lập |
| **Cấu hình appliance** | `templates/f5-runtime-init.yaml`, `templates/pa-init-cfg.txt.tftpl`, `templates/pa-bootstrap.xml.tftpl` |
| **Đã kiểm** | `plan-check.sh` — **26 đạt, 0 lỗi** trên 9 tổ hợp biến, tổ hợp đầy đủ 179 resource |
| **Chưa apply** | Palo Alto và F5 **chưa chạy thật lần nào**. Xem mục 6 |
| **Chi phí** | +~$3.03/giờ khi bật appliance — xem mục 7 |

> **Đọc mục 6 trước khi apply.** Phần này khác mọi phần khác của repo ở một điểm: hai thiết bị đắt nhất chạy cấu hình mà **không công cụ nào trong chuỗi kiểm được**, và cách chúng hỏng là im lặng.

---

## 1. Bốn tầng, ai sở hữu tầng nào

| Tầng | Chặn được gì | Sửa ở đâu | Đổi bao lâu một lần |
|---|---|---|---|
| **CloudFront** | Phân phối, cache, chặn theo địa lý | `cdn.tf` | vài tháng |
| **AWS WAF** | OWASP, rate limit, IP reputation, bot | `cdn.tf` — `waf_managed_rule_groups` | **hằng tuần** |
| **Palo Alto** | App-ID, IPS, antivirus, DNS security | `templates/pa-bootstrap.xml.tftpl` | hằng tháng |
| **F5** | WAF L7 sâu, TLS, bảo vệ API | `templates/f5-runtime-init.yaml` | hằng tháng |

**Điểm quan trọng nhất:** ba tầng đầu chặn theo *dấu hiệu*, tầng F5 chặn theo *hành vi của ứng dụng*. Bỏ tầng nào cũng còn ba tầng — nhưng bỏ F5 thì mất tầng duy nhất biết ứng dụng của bạn trông ra sao.

### Vì sao không có catalog YAML như lớp `ops/`

Lớp `ops/` (doc 25) tồn tại vì rule firewall đông-tây đổi **hằng ngày** và luôn cùng một hình dạng: `từ app A tới app B, cổng C`. Cấu hình appliance không như vậy:

- Rule WAF quản lý là **danh sách tên** — sửa một biến Terraform là xong, không cần lớp trung gian.
- Policy Palo Alto và F5 là **tài liệu cấu hình của nhà cung cấp**, không phải cặp IP/port. Một lớp catalog bọc lên chúng sẽ vừa mất khả năng biểu đạt vừa thêm một chỗ để lệch nhau.

Nên chúng nằm thẳng trong Terraform và trong template. Đừng dựng catalog cho phần này — nó không phải cùng bài toán.

---

## 2. Runbook — thêm một rule group WAF

Thao tác hay xin nhất, và rẻ nhất.

```hcl
# terraform.tfvars
waf_managed_rule_groups = [
  "AWSManagedRulesCommonRuleSet",
  "AWSManagedRulesKnownBadInputsRuleSet",
  "AWSManagedRulesAmazonIpReputationList",
  "AWSManagedRulesSQLiRuleSet",        # thêm dòng này
]
```

```bash
terraform plan && terraform apply
```

**Bật ở chế độ `count` trước.** `waf_mode = "count"` cho WAF ghi log mà không chặn — cùng ý đồ với `firewall_mode = "alert"` của Network Firewall. Rule group quản lý của AWS chặn nhầm hàng thật là chuyện thường; đọc log một tuần rồi mới `block`.

Mỗi rule group thêm ~$1/tháng cộng WCU. Web ACL có giới hạn **1500 WCU** — vượt là `apply` hỏng, và thông báo nói về WCU chứ không nói rule group nào vừa thêm.

---

## 3. Runbook — sửa policy Palo Alto

Sửa `templates/pa-bootstrap.xml.tftpl`, rồi:

```bash
./plan-check.sh          # kiểm XML TRƯỚC
terraform plan && terraform apply
```

**`apply` chỉ cập nhật object trên S3 — nó không cấu hình lại thiết bị đang chạy.** PAN-OS đọc bootstrap **một lần, lúc boot**. Muốn cấu hình mới có hiệu lực:

```bash
terraform apply -replace='aws_instance.palo_alto[0]'
```

Đó là một khoảng gián đoạn chuỗi ingress. Với môi trường thật, cách đúng là sửa qua giao diện quản trị hoặc Panorama và coi `bootstrap.xml` là **cấu hình khởi tạo cho thiết bị mới**, không phải nguồn sự thật đang chạy.

> Đây là ranh giới đáng nhớ nhất của cả bài: `bootstrap.xml` trả lời *"một thiết bị mới bắt đầu từ đâu"*, không phải *"thiết bị đang chạy có gì"*. Nhầm hai câu đó dẫn tới việc sửa file, `apply` xanh, và không có gì thay đổi.

### Ba biến sửa được mà không đụng XML

| Biến | Làm gì |
|---|---|
| `pa_allowed_applications` | App-ID được cho qua. Khai bằng **tên ứng dụng**, không phải cổng — đó là lý do dùng Palo Alto thay vì một ACL |
| `pa_security_profile_group` | Nhóm profile quét gắn vào rule cho qua. Cho qua mà không gắn profile thì thiết bị chỉ làm việc của một ACL |
| `pa_default_action` | Rule cuối: `allow` để đọc log trước, `deny` khi đã biết cái gì thật sự đi qua |

---

## 4. Runbook — sửa cấu hình F5

Sửa `templates/f5-runtime-init.yaml` (declaration AS3/DO — xem [doc 18](./18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md)), rồi thay instance như với Palo Alto.

Cùng ranh giới: Runtime Init chạy **lúc boot**. Với thiết bị đang chạy, đẩy declaration qua API:

```bash
curl -sk -u admin:<mat khau> -X POST \
  https://<ip f5>/mgmt/shared/appsvcs/declare \
  -H 'Content-Type: application/json' -d @as3.json
```

Mật khẩu admin nằm trong Secrets Manager, không hardcode:

```bash
aws secretsmanager get-secret-value --region ap-southeast-1 \
  --secret-id $(terraform output -json appliances | jq -r .f5_admin_secret) \
  --query SecretString --output text
```

---

## 5. Runbook — chỉ cho CloudFront vào origin

Khi `enable_cdn = true`, NLB **chỉ** nhận từ CloudFront. Hai lớp cùng lúc:

| Lớp | Cơ chế |
|---|---|
| Mạng | Security group của NLB dùng **prefix list `com.amazonaws.global.cloudfront.origin-facing`** — AWS tự cập nhật dải |
| Ứng dụng | Header bí mật `origin_verify`, F5 kiểm và từ chối nếu thiếu |

Chỉ lớp mạng thì chưa đủ: prefix list cho phép **mọi** phân phối CloudFront trên thế giới, kể cả của người khác. Header bí mật là thứ phân biệt phân phối *của bạn*.

Xoay header:

```bash
terraform apply -replace='random_password.origin_verify'
```

Rồi thay F5 để nó nhận giá trị mới — hoặc đẩy declaration qua API trước, rồi mới xoay, để không có khoảng trống.

---

## 6. Phần không kiểm được, và cách bù

Mọi thứ khác trong repo đều có lưới: `terraform validate` bắt cấu hình sai, `plan-check.sh` bắt hành vi sai, `verify.sh` đo bằng gói tin thật.

**Cấu hình bên trong appliance thì không.** `templatefile()` chỉ ghép chuỗi; PAN-OS và F5 mới là thứ đọc nó, và chúng đọc lúc boot.

Nên `plan-check.sh` tự phân tích `pa-bootstrap.xml.tftpl` thành XML và đòi sáu khối phải có mặt:

```
✓ Cau hinh Palo Alto: XML hop le, du khoi bat buoc
```

Thử phá ba kiểu để chắc nó không phải dấu tích trang trí:

| Phá | Kết quả |
|---|---|
| Bỏ một thẻ đóng | `SAI CU PHAP: mismatched tag: line 114` |
| Bỏ khối `<profiles>` | `THIEU: profile quan tri interface - health check cua GWLB khong bao gio dat` |
| Bỏ `plugin-op-commands` | `init-cfg.txt thieu khoa: plugin-op-commands` |

Phép kiểm đó bắt được **cấu trúc**, không bắt được **ngữ nghĩa**. Một rule đúng cú pháp mà sai zone vẫn lọt. Với phần đó, không có cách nào ngoài chạy thử.

### Bốn thứ mà thiếu một cái là Palo Alto im lặng không làm gì

Tất cả cho ra **cùng một triệu chứng**: thiết bị lên bình thường, GWLB báo target `unhealthy` mãi mãi, không log, không lỗi.

| | |
|---|---|
| `user_data` là chuỗi `khoá=giá trị`, **không phải script** | Bash ở đó bị bỏ qua hoàn toàn |
| Ba thư mục rỗng `license/` `software/` `content/` | Thiếu **bất kỳ** cái nào là bỏ qua **cả gói** bootstrap |
| `s3:ListBucket` là quyền trên **bucket**, không phải object | Thiếu nó thì `GetObject` vẫn chạy mà bootstrap vẫn bị bỏ qua |
| **Hai** ENI, cộng `mgmt-interface-swap` | GWLB gửi GENEVE tới ENI **chính**, mà PAN-OS mặc định lấy `eth0` làm quản trị |

### Trước khi apply thật

```text
□ Da subscribe Marketplace CA Palo Alto lan F5
    thieu -> OptInRequired, va apply dung o giua
□ pa_key_name tro toi mot key pair CO THAT
    de rong -> instance tao duoc nhung KHONG AI VAO DUOC
□ pa_mgmt_allowed_cidrs la dai noi bo, khong phai 0.0.0.0/0
□ waf_mode = "count" cho lan dau
□ pa_default_action = "allow" cho lan dau
□ ./plan-check.sh sach
□ Da doc muc 7 - chi phi
```

---

## 7. Chi phí — phần nặng nhất của cả landing zone

| Thành phần | Giờ | Tháng |
|---|---|---|
| Palo Alto VM-Series (`m5.xlarge` + license) | ~$1.50 | ~$1,095 |
| F5 BIG-IP (`m5.xlarge` + license) | ~$1.50 | ~$1,095 |
| Gateway Load Balancer | ~$0.0125 | ~$9 |
| GWLB endpoint | ~$0.01 mỗi AZ | ~$7.30/AZ |
| CloudFront | $0 trong free tier (1 TB + 10 triệu request) | |
| WAF Web ACL | ~$5 + ~$1 mỗi rule group | ~$9 |
| **Bật appliance** | **~$3.03/giờ** | **~$2,215** |

Hai dòng đầu là ~99% chi phí, và **cả hai tính theo giờ bất kể lưu lượng**. Giá license dao động rất lớn theo bundle — kiểm giá thật trên trang Marketplace cho đúng bundle bạn dùng.

Đây là lý do `enable_appliances` mặc định **tắt**, và là lý do doc 14 mục 12 có phần "demo rẻ — thay appliance bằng stand-in".

> Bật nhầm một đêm là ~$73. Bật nhầm một cuối tuần là ~$218. `./teardown.sh` xoá cả hai, nhưng nó chỉ chạy khi có người nhớ chạy nó.

---

## 8. Triệu chứng → nguyên nhân

Mọi dòng đều là kiểu hỏng **không phát ra lỗi**.

| Triệu chứng | Nguyên nhân |
|---|---|
| GWLB báo target `unhealthy` mãi mãi | Bootstrap Palo Alto bị bỏ qua — xem bốn nguyên nhân ở mục 6 |
| Sửa `bootstrap.xml`, `apply` xanh, thiết bị không đổi gì | PAN-OS đọc bootstrap **lúc boot**. Cần `-replace` instance |
| `apply` dừng ở `OptInRequired` | Chưa subscribe AMI Marketplace |
| `plan` xanh nhưng `apply` không tạo được instance | Cùng nguyên nhân — `plan` chỉ cần một AMI ID hợp lệ |
| Instance lên nhưng không ai SSH được | `pa_key_name` để rỗng |
| CloudFront trả `502`/`504` | NLB không nhận từ dải CloudFront (prefix list), hoặc F5 từ chối vì thiếu header `origin_verify` |
| Gọi thẳng NLB vẫn được khi `enable_cdn = true` | Security group còn rule cũ mở `ingress_allowed_cidrs` |
| WAF chặn hàng thật | Rule group quản lý đang ở `block` mà chưa qua giai đoạn `count` |
| `apply` hỏng khi thêm rule group | Vượt 1500 WCU của Web ACL — thông báo nói về WCU, không nói rule nào vừa thêm |
| `plan-check.sh` báo nhiều lỗi trên máy đã apply | Đã sửa ở lỗi 85 — script giờ plan trên state rỗng trong thư mục tạm |

---

## 9. Còn thiếu

| | |
|---|---|
| **Chưa apply thật** | Palo Alto và F5 chưa chạy lần nào. Con số duy nhất có thật là plan: 179 resource, 26/26 phép kiểm đạt |
| **Không có `verify.sh` cho tầng appliance** | `verify.sh` đo tới NLB. Chưa có phép đo nào chứng minh gói tin *đi qua* Palo Alto rồi mới tới F5 |
| **Không có HA** | Một Palo Alto, một F5, đều ở AZ đầu. AZ đó hỏng là cả chiều vào chết. Xem doc 14 mục 10 |
| **`bootstrap.xml` chỉ có hai rule** | Đủ để chứng minh đường đi, không đủ cho môi trường thật |

---

## Liên quan
| | |
|---|---|
| [14 – Ingress chain](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | Thiết kế bốn tầng, luồng gói tin, vì sao Palo Alto qua GWLB |
| [18 – Cấu hình F5](./18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md) | DO/AS3/TS declaration, WAF policy |
| [25 – Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md) | Lớp `ops/` cho mạng lõi — vai trò tương đương, cho chiều đông-tây |
| [15 – Security VPC](./15-Security-VPC-Network-Firewall.md) | Network Firewall — tầng thanh tra cho đông-tây và ra ngoài |
| [16 – Kết nối đối tác](./16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) | Chiều vào **thứ hai**: đối tác qua VPN, không qua chuỗi này |
| [22 mục 7an](./22-Nhat-ky-Trien-khai-LZ-DIY.md) | Nhật ký — lỗi 84, 85 và bootstrap Palo Alto |
