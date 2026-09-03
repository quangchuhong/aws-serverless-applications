# Triển khai Network LZ cross-account — nhật ký thao tác

Ghi lại **lần triển khai thật**: dựng hub mạng ở một account, spoke VPC ở ba account khác, tất cả tự động nối vào Transit Gateway và nhận DNS tập trung — rồi xoá sạch.

| Tài liệu | Vai trò |
|---|---|
| [17 – Design Guide](./17-Network-LZ-Design-Guide.md) | **Vì sao** — kiến trúc, CIDR, bảng chân lý TGW |
| [22 – Nhật ký lỗi](./22-Nhat-ky-Trien-khai-LZ-DIY.md) | **Vấp ở đâu** — 60 lỗi, mục 7y–7ae là phần network |
| **24 (tài liệu này)** | **Làm gì, theo thứ tự nào** — lệnh thật, kiểm chứng thật, chi phí thật |
| [`demo/network-lz-full`](../demo/network-lz-full/) | Code |

---

## 0. Kết quả đo được

Toàn bộ số liệu dưới đây lấy từ lần chạy thật, không ước tính.

| | |
|---|---|
| Account | 5 account thấy TGW, 4 có VPC nối vào |
| Transit Gateway | `tgw-082f15acfc5988a70`, 4 route table |
| Spoke ở account khác | 3 — `app-prod`, `security`, `logarchive` |
| Kiểm chứng | `verify.sh` **28 đạt, 0 lỗi, 0 bỏ qua** |
| Chi phí | `~$1.397/giờ` = **~$33.52/ngày** ở 2 AZ, đủ firewall + ingress + endpoint |
| Xoá | `143 destroyed`, mười phép kiểm sạch |
| Thời gian | ~45 phút dựng, ~20 phút xoá |

Bản đồ account:

```
609320954321  management     thay TGW, KHONG co spoke (xem muc 6)
436908791055  lz-network     HUB: TGW, security VPC, egress VPC, firewall, NLB
                             + spoke local app-dev  10.10.0.0/16
761558631239  lz-app-prod    spoke  10.20.0.0/16     <- StackSet
458195083898  lz-security    spoke  10.8.0.0/16      <- StackSet
654560867047  lz-logarchive  spoke  10.100.0.0/16    <- StackSet
169873795883  lz-app-dev     thay TGW, chua dung VPC
```

---

## 1. Bốn mắt xích, và chúng không cùng một phía

Đây là ý quan trọng nhất của cả phần cross-account. Ranh giới account chia việc thành bốn, và **hai chiều ngược nhau**:

| Mắt xích | Chỉ ai làm được | Giải bằng |
|---|---|---|
| Chấp nhận lời mời RAM | Account nhận | CLI, một lần mỗi account |
| Tạo VPC + subnet + attachment | Chủ sở hữu VPC | StackSet chạy CloudFormation **bên trong** account đó |
| Gắn Route 53 Profile vào VPC | Chủ sở hữu VPC | `AWS::Route53Profiles::ProfileAssociation` trong cùng template |
| Nối attachment vào route table | Chủ sở hữu **TGW** | Terraform ở account hub |

Ba dòng đầu cùng một bài toán. **CloudFormation giải được hai trong ba** chỉ vì nó vốn đã chạy bên trong account đích — đó mới là lý do dùng StackSet ở đây, không phải "triển khai hàng loạt".

Dòng thứ tư đi ngược chiều nên không thể gộp vào template.

> Terraform trong bộ code này chỉ có **một** provider, trỏ vào account hub. Mọi thứ nó không với tới được đều rơi vào ba dòng đầu.

---

## 2. Điều kiện tiên quyết — làm một lần cho cả tổ chức

Ba việc, đều chạy từ **management account**. Thiếu cái nào cũng hỏng ở một chỗ không nhắc gì tới nguyên nhân.

```bash
# 1. Account hub lam delegated administrator cua CloudFormation StackSets
aws organizations register-delegated-administrator \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com \
  --account-id 436908791055

# Kiem:
aws organizations list-delegated-administrators \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com

# 2. RAM sharing voi Organizations
aws ram enable-sharing-with-aws-organization

# 3. OU cua tung account spoke - StackSet trien khai theo CAY TO CHUC
for A in 761558631239 458195083898 654560867047; do
  printf '%s  ' "$A"
  aws organizations list-parents --child-id "$A" --query 'Parents[0].Id' --output text
done
```

**Không đăng ký delegated administrator** thì `CreateStackSet` báo `AccessDenied` — và lỗi đó không nhắc gì tới uỷ quyền. Đừng vượt qua bằng cách chạy code từ management account: bộ này một provider, làm vậy sẽ tạo **toàn bộ hub** trong management, nơi SCP không bao giờ áp được.

### Uỷ quyền không thu hồi quyền của management

Câu hỏi hay gặp: *đăng ký `lz-network` làm delegated admin rồi thì management còn dùng StackSet được không?*

**Còn, đầy đủ.** Uỷ quyền là **thêm** một account được phép, không phải chuyển quyền đi. Bằng chứng trong chính repo này: [`landing-zone/account-baseline`](../landing-zone/account-baseline/) có StackSet `SERVICE_MANAGED` **không khai `call_as`** — mặc định `SELF`, chạy từ management — và nó hoạt động bình thường suốt lúc StackSet của demo chạy bằng `DELEGATED_ADMIN` từ `lz-network`.

Nhưng hai bên là **hai không gian tên riêng biệt**:

| | |
|---|---|
| `--call-as SELF` | StackSet do management sở hữu |
| `--call-as DELEGATED_ADMIN` | StackSet do delegated admin sở hữu |

StackSet tạo ở bên này **không nhìn thấy được** từ bên kia:

```bash
aws cloudformation list-stack-sets --call-as SELF            # tu management
aws cloudformation list-stack-sets --call-as DELEGATED_ADMIN # tu delegated admin
```

Cùng một **tên** có thể tồn tại độc lập ở hai bên. Nghe tiện, nhưng là cái bẫy: hai StackSet trùng tên, deploy hai template khác nhau, và không lệnh nào cho thấy cả hai cùng lúc.

`call_as` cũng phải **khớp giữa stack set và stack instance**. Lệch nhau thì CloudFormation báo không tìm thấy stack set — một câu không nhắc gì tới `call_as`.

> **Thứ tự khi gỡ uỷ quyền:** xoá StackSet ở phía delegated admin **trước**, rồi mới `deregister-delegated-administrator`. Gỡ uỷ quyền trước thì StackSet do account đó tạo vẫn tồn tại mà không còn ai quản được — management không thấy chúng, và account kia mất quyền. Chưa đo trong tổ chức này, nên đây là thứ tự an toàn chứ không phải sự thật đã kiểm chứng.

---

## 3. Cấu hình

```hcl
project   = "quh11-net"
ephemeral = true

enable_firewall = true
firewall_mode   = "alert"          # KHONG bao gio dat "drop" o lan dau

enable_interface_endpoints = true
enable_internal_dns        = true
enable_dns_profile         = true
enable_test_instances      = true

# --- RAM ---
ram_use_external_principals                 = true    # doc muc 5 truoc khi bat
ram_sharing_with_organization_enabled       = true
network_account_is_stackset_delegated_admin = true
ram_invitations_accepted                    = false   # bat sau khi da nhan
wire_remote_attachments                     = false   # bat o pha cuoi

# Account chi CAN THAY TGW, chua dung VPC
share_tgw_with_accounts = [
  "609320954321",   # management
  "458195083898",   # lz-security
  "654560867047",   # lz-logarchive
  "169873795883",   # lz-app-dev
]

spokes = {
  "app-dev"    = { cidr = "10.10.0.0/16" }             # LOCAL - giu lai

  "app-prod"   = { cidr = "10.20.0.0/16",  account_id = "761558631239", ou_id = "ou-..." }
  "security"   = { cidr = "10.8.0.0/16",   account_id = "458195083898", ou_id = "ou-o5ci-g5rv7do1" }
  "logarchive" = { cidr = "10.100.0.0/16", account_id = "654560867047", ou_id = "ou-..." }
}
```

**Chia sẻ ≠ có VPC.** `share_tgw_with_accounts` mở cửa cho account tự cắm sau; `spokes` mới dựng VPC. Đừng bịa spoke giả chỉ để share.

**Giữ ít nhất một spoke local.** Template StackSet tạo VPC + attachment, **không tạo EC2**. Mà mục 7 của `verify.sh` — mục duy nhất đo luồng thật — chạy lệnh trên EC2 qua SSM.

CIDR lấy từ [doc 17 mục 3](./17-Network-LZ-Design-Guide.md#3-quy-hoạch-cidr--bảng-chuẩn). Trùng CIDR trong lưới TGW thì route table không phân biệt được hai spoke, và sửa thì phải xoá VPC.

---

## 4. Trình tự — bốn pha, không gộp được

### Pha 1 — chỉ RAM share

```bash
terraform init
terraform apply \
  -target=aws_ram_resource_association.tgw \
  -target=aws_ram_principal_association.spoke_accounts
```

Tạo 4 resource: TGW + share + hai association. **Chưa có NAT, chưa có attachment — gần như $0.**

`-target` bị Terraform cảnh báo là *"không dùng cho việc thường ngày"*, và cảnh báo đó đúng ở mọi hoàn cảnh khác. Ở đây có một **bước thủ công bắt buộc nằm giữa** hai nửa config, nên chia apply theo phụ thuộc thật lại là cách trung thực nhất.

Không dùng `-target` thì `apply` dựng cả hub rồi mới chết ở StackSet, vì **`check` block chỉ cảnh báo chứ không chặn**.

### Pha 2 — mỗi account nhận lời mời

Share ngoài tổ chức **không tự động được chấp nhận**. Chạy ở **từng** account trong `share_tgw_with_accounts` và `spokes`:

```bash
# Cong chan - dan ca khoi, no tu dung neu sai account
EXPECT=761558631239
ACTUAL=$(aws sts get-caller-identity --query Account --output text)
if [ "$ACTUAL" != "$EXPECT" ]; then
  echo "SAI ACCOUNT: dang o $ACTUAL, can $EXPECT"
else
  ARN=$(aws ram get-resource-share-invitations --region ap-southeast-1 \
    --query "resourceShareInvitations[?status=='PENDING' && resourceShareName=='quh11-net-tgw'].resourceShareInvitationArn" \
    --output text)
  [ -n "$ARN" ] && aws ram accept-resource-share-invitation \
    --region ap-southeast-1 --resource-share-invitation-arn "$ARN"
  aws ec2 describe-transit-gateways --region ap-southeast-1 \
    --query 'TransitGateways[].[TransitGatewayId,OwnerId]' --output text
fi
```

Dòng cuối là **bằng chứng thật**. `status: ACCEPTED` phía RAM chỉ nói lời mời đã nhận, không nói TGW đã hiện ra bên đó.

Kiểm cả năm cùng lúc, từ account hub — không phải đăng nhập vào từng cái:

```bash
aws ram get-resource-share-associations --region ap-southeast-1 \
  --association-type PRINCIPAL \
  --resource-share-arns $(aws ram get-resource-shares --resource-owner SELF \
    --region ap-southeast-1 --name quh11-net-tgw \
    --query 'resourceShares[?status==`ACTIVE`].resourceShareArn' --output text) \
  --query 'resourceShareAssociations[].[associatedEntity,status]' --output text
```

Mọi dòng phải là `ASSOCIATED`. `ASSOCIATING` = account đó chưa bấm nhận, và **nó không thấy TGW**.

### Pha 3 — StackSet dựng VPC ở account đích

```hcl
ram_invitations_accepted = true
```

```bash
terraform apply     # ~10-15 phut
```

Mỗi stack instance mất **~5 phút**. Kiểm:

```bash
aws cloudformation list-stack-instances --region ap-southeast-1 \
  --stack-set-name quh11-net-spoke-vpc --call-as DELEGATED_ADMIN \
  --query 'Summaries[].[Account,Status,StatusReason]' --output text
```

Mọi dòng `CURRENT`. **Account nào có trong `spokes` mà không có dòng nào ở đây** là dấu hiệu duy nhất báo StackSet không với tới nó — xem mục 6.

`check "remote_attachments_wired"` sẽ báo `0/3` ở lần apply này. Bình thường: data source đọc attachment **trước** khi StackSet tạo xong.

### Pha 4 — nối attachment vào route table

```hcl
wire_remote_attachments = true
```

```bash
terraform apply
./verify.sh
```

Phải tách pha vì data source tìm attachment lọc theo ID của TGW, mà TGW được tạo trong chính config này. Lần apply đầu, ID đó chưa biết nên `for_each` không dựng được bộ khoá và plan chết với `Invalid for_each argument`.

---

## 5. Khoản nợ: `allow_external_principals = true`

Đường **đúng** là share trong phạm vi tổ chức: `allow_external_principals = false`, principal là account ID hoặc OU ARN. Trên tổ chức này đường đó **không chạy**.

Thí nghiệm đối chứng, cùng management account, cùng principal, cùng phút, đổi **đúng một biến**:

| Share | Principal | Kết quả |
|---|---|---|
| `--no-allow-external-principals` | account ID trong org | `OperationNotPermittedException` |
| `--no-allow-external-principals` | OU ARN đầy đủ | `UnknownResourceException: unknown organization` |
| `--allow-external-principals` | **cùng account ID đó** | `ACTIVE` |

RAM còn đánh dấu một account **đang ở trong** `o-tvkzhcq3yh` là `"external": true`.

Bảy điều kiện tiên quyết đều đã kiểm và loại: `enable-sharing-with-aws-organization` trả `true`, service-linked role `AWSServiceRoleForResourceAccessManager` tồn tại, trusted access bật từ `2026-08-20`, FeatureSet `ALL`, chỉ `FullAWSAccess` trên root và OU, caller là management với quyền admin, OU tồn tại.

**Ba hệ quả phải biết trước khi bật:**

| | |
|---|---|
| Nới rào chắn | Share về nguyên tắc nhận được principal **ngoài tổ chức**. Danh sách account trong `var.spokes` và `var.share_tgw_with_accounts` là thứ duy nhất còn chặn |
| Mất tự động | Mỗi account phải bấm nhận lời mời một lần — chính là pha 2 |
| Là tạm thời | Khi AWS Support sửa, đổi `ram_use_external_principals` về `false`, và pha 2 biến mất |

> Đây **không phải một lựa chọn kiến trúc**. Ghi nó vào tài liệu như "cách share TGW" thì sáu tháng nữa không ai còn nhớ vì sao rào chắn bị nới, và sẽ không ai đổi lại.

Nội dung ticket AWS Support: [doc 22 mục 7z](./22-Nhat-ky-Trien-khai-LZ-DIY.md).

---

## 6. Management account: StackSet không với tới

`SERVICE_MANAGED` triển khai theo cây tổ chức, và **AWS loại management account ra khỏi mọi đợt triển khai đó**. Management nằm trực tiếp dưới root, không thuộc OU nào; khai thêm root id cũng không tới.

Cách nó báo lỗi rất tệ — ba nguồn, không nguồn nào chỉ đúng chỗ:

```
terraform apply        unexpected state 'FAILED' ... last error: %!s(<nil>)
list-stack-instances   ba dong CURRENT, KHONG co dong nao cho account do
CloudFormation         khong co StatusReason
```

Dấu hiệu duy nhất trỏ đúng chỗ là **sự vắng mặt** — và muốn thấy nó thì phải biết trước là nó đáng lẽ phải có ở đó.

**Muốn có VPC ở management** thì đặt `manual_vpc = true` cho spoke đó (Terraform vẫn share RAM và vẫn nối route khi attachment xuất hiện), rồi dựng bằng stack thường chạy tại chỗ:

```bash
terraform output -raw spoke_template > spoke-vpc.json
# roi tu chinh management account:
aws cloudformation create-stack --region ap-southeast-1 \
  --stack-name quh11-net-spoke-vpc \
  --template-body file://spoke-vpc.json \
  --parameters ParameterKey=VpcCidr,ParameterValue=10.101.0.0/16 ...
```

> **Nên cân nhắc kỹ trước khi làm.** Management là account SCP không áp được, và [doc 22 lỗi 51](./22-Nhat-ky-Trien-khai-LZ-DIY.md) ghi lại đúng một lần hạ tầng mạng lọt vào đó rồi phải gỡ ra. Cùng lý do, `account-baseline` cũng không quét được default VPC ở management — nó dùng chính cơ chế StackSet này.

---

## 7. Kiểm chứng

```bash
./verify.sh
```

12 nhóm, **28 phép kiểm**. Ba nhóm nhìn qua ranh giới account:

| Mục | Kiểm gì |
|---|---|
| `6c` | Mỗi attachment thuộc account khác **nằm trong route table nào**, và **đường về đã học CIDR chưa** |
| `6d` | Cả năm account đã `ASSOCIATED` chưa |
| `7b` | `dig` từ trong spoke: tên dịch vụ AWS phải ra IP trong security VPC |

**Association không phải propagation.** Association cho spoke biết đường **ra**; propagation cho đường **về** biết CIDR của spoke. Có cái đầu mà thiếu cái sau thì gói đi được, gói trả lời lạc — luồng bất đối xứng, firewall stateful drop luôn, và **không trạng thái resource nào hiện ra**. Mục `6c` kiểm cả hai.

Phần cross-account chỉ kiểm được từ đúng chỗ đứng:

```bash
# Route 53 Profile - chay tu ACCOUNT SPOKE, khong phai account hub
aws route53profiles list-profile-associations --region ap-southeast-1 \
  --query 'ProfileAssociations[].[Name,ResourceId,Status]' --output text
# quh11-net-app-prod   vpc-09f0b15348602d8d0   COMPLETE
```

Kết quả thật của lần chạy này:

```
Loi moi RAM                  5/5 ASSOCIATED
StackSet                     3/3 CURRENT
app-prod    tgw-attach-0ae14ea9   10.20.0.0/16    active
security    tgw-attach-0da4b75e   10.8.0.0/16     active
logarchive  tgw-attach-0dfe8596   10.100.0.0/16   active
DNS profile cross-account    COMPLETE
Endpoint tap trung           ec2messages -> 10.1.31.184, 10.1.30.12
Gateway endpoint S3          IP cong khai (dung - no lam viec o route table)
Khong lot firewall           rtb-spokes / rtb-egress / rtb-ingress sach
Ingress                      NLB -> TGW -> firewall -> app, HTTP 200
verify.sh                    28 dat, 0 loi, 0 bo qua
```

---

## 8. Bảy cái bẫy không phát ra lỗi nào

Đây là phần đáng đọc nhất. Mỗi mục dưới đây **không** sinh ra lỗi, cảnh báo, hay trạng thái resource sai — và mỗi mục đều đã xảy ra thật.

| # | Bẫy | Triệu chứng duy nhất |
|---|---|---|
| 1 | Attachment tồn tại nhưng không thuộc route table nào | `State: available`, và không một gói tin nào đi qua |
| 2 | Association có, propagation thiếu | Gói đi được, gói trả lời lạc |
| 3 | Account chưa bấm nhận lời mời RAM | Apply xanh, share `ACTIVE`, account đó **không thấy TGW** |
| 4 | StackSet không với tới management | `list-stack-instances` **thiếu một dòng** |
| 5 | PHZ endpoint chưa tới spoke | Mọi thứ vẫn chạy — qua Internet. Endpoint tính tiền mà không ai đi qua |
| 6 | Script chạy nhầm account | Báo hàng loạt "lỗi hạ tầng" cho hệ thống hoàn hảo, hoặc "đã sạch" cho hạ tầng đang tính tiền |
| 7 | API tag trả về resource đã xoá | Một lần dọn sạch bị báo là thất bại |

Bốn cái cuối cùng một họ: **một phép đo đúng, trả lời cho một câu hỏi khác.** Không cái nào phát hiện được bằng cách nhìn kỹ hơn vào kết quả. Cách duy nhất hiệu quả là hỏi *"lệnh này thật ra trả lời điều gì"* — và cách sửa bền là để **script tự hỏi câu đó**:

- `verify.sh` và `teardown.sh` dừng ngay nếu credential không thuộc account đã tạo hạ tầng
- `verify.sh` mục 6c/6d/7b kiểm đúng ba cái bẫy đầu
- `teardown.sh` không còn báo lỗi khi mười phép kiểm sạch mà API tag còn chậm

---

## 9. Xoá — đúng thứ tự

```bash
# 1. Stack THUONG o account khac (neu co spoke manual_vpc) - TRUOC TIEN
#    Tu chinh account do:
aws cloudformation delete-stack --stack-name quh11-net-spoke-vpc

# 2. Roi moi den hub
./teardown.sh
```

**Không xoá được Transit Gateway khi còn attachment.** Attachment do StackSet tạo thì `terraform destroy` gỡ được — nó xoá stack instance. Attachment của spoke `manual_vpc` thì không: nằm ngoài state. Gặp phải thì destroy chạy đủ 15 phút rồi chết ở bước cuối, đúng lúc trông như sắp xong.

Kết quả thật: **`143 destroyed`**, mười phép kiểm sạch.

Lệnh quét theo tag sẽ liệt kê ~19 ARN — **dương tính giả**. `resourcegroupstaggingapi` trả về cả resource đã xoá trong một khoảng. Xác nhận:

```bash
aws ec2 describe-transit-gateways --transit-gateway-ids <tgw-id> \
  --query 'TransitGateways[].State' --output text     # deleted
aws ram get-resource-shares --resource-owner SELF \
  --query 'resourceShares[].[name,status]' --output text   # DELETED, khong ACTIVE
```

**Trạng thái đã-chấp-nhận của lời mời RAM không quay lại được.** Dựng lại sinh share mới, lời mời mới, và mỗi account phải nhận lại — share cũ và share mới là hai resource khác nhau.

---

## 10. Chi phí đo được

| Cấu hình | ~USD/giờ | ~USD/ngày |
|---|---:|---:|
| Không firewall, không ingress, 2 spoke | 0.252 | 6.04 |
| Đủ bộ: firewall + ingress + endpoint, 4 spoke | 1.397 | **33.52** |

Chênh lệch gần như toàn bộ là **Network Firewall endpoint**: ~$0.395/giờ mỗi endpoint, một endpoint mỗi AZ. Hai AZ là ~$570/tháng, chạy 24/7 dù có gói tin hay không.

Mỗi spoke thêm ~$36/tháng cho TGW attachment — **kể cả spoke chưa có gì trong đó**.

Cách rẻ để kiểm chứng cả chuỗi cross-account mà không trả tiền firewall:

```bash
terraform apply -var enable_firewall=false -var enable_ingress=false
```

Route table **đổi** khi bật firewall sau đó — `0.0.0.0/0` của spoke chuyển từ attachment egress sang attachment security, propagation chuyển từ `rtb-egress` sang `rtb-security`. Coi đó là một thay đổi mạng có cửa sổ gián đoạn, không phải bật một cờ.

---

## 11. Còn lại

| | |
|---|---|
| Ticket AWS Support | Lỗi 56 — RAM không phân giải được tổ chức. Trả xong nợ này thì mục 5 và pha 2 biến mất |
| `firewall_mode = "drop"` | Chạy `alert` ít nhất một tuần, đọc log tìm `UNMATCHED east-west`, viết `east_west_rules` từ thực tế rồi mới chuyển |
| `landing-zone/network` | Layer thường trực, chưa ai apply — và bước RAM của nó dùng đúng đường đã đo là hỏng |
| Palo Alto + F5 | Code sẵn, chờ license Marketplace |

---

## Liên quan

| | |
|---|---|
| [17 – Design Guide](./17-Network-LZ-Design-Guide.md) | Kiến trúc, CIDR, bảng chân lý TGW. Mục 4b là bản tóm tắt cross-account |
| [22 – Nhật ký lỗi](./22-Nhat-ky-Trien-khai-LZ-DIY.md) | Mục 7y–7ae: từng lỗi của phần này, và cách phát hiện |
| [13](./13-Centralized-Ingress-Egress-Network.md) · [15](./15-Security-VPC-Network-Firewall.md) · [12](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) | Chi tiết egress, firewall, DNS |
| [RUNBOOK giai đoạn 10](../landing-zone/RUNBOOK.md) | Bản thường trực của layer network |
