# Nhật ký triển khai LZ bản DIY

Ví dụ 22: Ghi lại **lần dựng thật đầu tiên** — làm gì, vấp ở đâu, sửa thế nào.

> Khác với [RUNBOOK](../landing-zone/RUNBOOK.md) (*làm gì, theo thứ tự nào*) và các doc thiết kế (*vì sao*). File này ghi **cái đã thật sự xảy ra** — thứ mà không tài liệu thiết kế nào bắt được, vì phải chạy mới biết.
>
> Mọi lỗi dưới đây đều đã sửa và push. Cột "Commit" là bằng chứng.

---

## 0. Kết quả

Dựng từ một account trắng đến LZ có guardrail hoạt động, kiểm chứng được.

| Thành phần | Kết quả |
|---|---|
| Organization | `o-tvkzhcq3yh`, root `r-o5ci` |
| Cây OU | 8 OU — 6 cấp 1 + 2 cấp 2 |
| SCP | 4 policy: `baseline` + `region_lock` ở root, `network_lock` ở 3 OU, `prod_guard` ở `Production` |
| Remote state | S3 + versioning + Object Lock + khoá DynamoDB, 16 resource |
| Account | 6 ACTIVE — management, network, security, logarchive, app-dev, app-prod |
| Kiểm chứng SCP | 4/4 policy — kể cả `prod_guard`, sau 3 lần phép thử hỏng (mục 5c) |
| Identity Center | `ssoins-8210168ac3d88c11`, identity store `d-9667ae9e62` |
| Permission set | 17 set, 15 group, 53 assignment — 115 resource |
| Billing guard | Budget $20, SNS alert (đã xác nhận), anomaly detection — us-east-1 |
| Default VPC | Xoá tay ở `ap-southeast-1` — **và chỉ ở đó**, xem mục 6d |
| Config detective | 4/4 recorder đang ghi, aggregator, 8 org rule — 26 resource |
| Đăng nhập SSO | Kiểm chứng thật — portal hiện đúng 5 account, không có management |
| Org trail | CloudTrail toàn tổ chức, multi-region, log file validation — 8 resource |
| Account baseline | StackSet + Lambda, `auto_deployment`, 5/5 stack instance CURRENT |
| **Vòng khép kín** | `cloud-trail-enabled`: NON_COMPLIANT ×4 → dựng `org-trail` → **COMPLIANT ×4** |
| **Tự động bắt lỗi tay** | `account-baseline` xoá **5 default VPC ở `us-east-1`** mà lần dọn tay bỏ sót |
| Đường cảnh báo | `plan-all.sh` bắt được email cảnh báo bảo mật **không tới ai** — xem mục 6e |
| **Xoá và dựng lại** | 158 resource xoá / 5 layer, rồi 162 dựng lại — kiểm chứng cả hai chiều, xem mục 7 |

**Thời gian thật:** ~3 giờ, trong đó phần lớn là gỡ 34 lỗi dưới đây. Đường đi sạch thì khoảng 1 giờ.

**Chi phí đo được:** $0.29 một lần cho lần quét đầu của AWS Config, sau đó ~$0/ngày. Sáu layer còn lại không tốn gì — S3 vài trăm KB, DynamoDB `PAY_PER_REQUEST`, Organizations/OU/SCP miễn phí.

---

## 1. Bảng lỗi

Xếp theo thứ tự gặp phải.

| # | Lỗi | Nguyên nhân | Loại | Commit sửa |
|---|---|---|---|---|
| 1 | `InvalidInputException: unrecognized service principal` | `reports.billing.amazonaws.com` không hợp lệ | **Lỗi code** | `fd49be8` |
| 2 | `Backend initialization required` | Bật backend trước khi apply | Thiết kế bẫy người dùng | `977f057`, `5434ea7` |
| 3 | `Khong doc duoc output backend_hcl` | Script nuốt stderr của Terraform | **Lỗi code** | `1e5a39a` |
| 4 | Git branch diverged | Bắt sửa file được git track để bật backend | **Lỗi thiết kế** | `5434ea7` |
| 5 | `Unsetting the previously set backend "s3"` | `backend.tf` mất, state vẫn ở S3 | Vòng lặp thứ hai do #4 | `27dfc65` |
| 6 | `grey: command not found` | Hàm được gọi mà chưa khai | **Lỗi code** | `5434ea7` |
| 7 | Script bảo migrate cả 6 layer | Không phân biệt layer đã/chưa có state | Lỗi logic | `df67624`, `15abb10` |
| 8 | `Instance cannot be destroyed` | `create_organization` đổi `true`→`false` | Tên biến gây hiểu nhầm | `cad896f` |
| 9 | `is tainted, so must be replaced` | Apply lỗi giữa chừng để lại taint | Hệ quả của #1 | `3410e1a` |
| 10 | `Inconsistent conditional result types` | `?:` trả về tuple 2 vs tuple 0 trong `permission-sets` | **Lỗi code** | *(mục 2.5)* |
| 11 | `validate-policies.sh` in bảng rỗng rồi thoát 0 | Mã thoát pipeline là của `sed`, `set -e` không nổ | **Lỗi code** | *(mục 2.5)* |
| 12 | `Limit exceeded on dimensional spend monitor creation` | Mỗi account chỉ được 1 dimensional monitor, AWS đã tạo sẵn | **Lỗi code** | *(mục 2.6)* |
| 13 | `Daily or weekly frequencies only support Email subscriptions` | `frequency` và `subscriber.type` ràng buộc nhau | **Lỗi code** | *(mục 2.6)* |
| 14 | `InvalidAccessException: not an administrator` | Security Hub cần chỉ định riêng, Organizations chưa đủ | Thiếu tài liệu | `a48f8a6` |
| 15 | `Unsupported argument: stack_set_instance_region` | Dùng tên tham số của provider v6 trong layer khai `~> 5.0` | **Lỗi code** | `688f3db` |
| 16 | `'Days' in Expiration must be greater than Transition` | Transition ghi cứng 90/180, expiration lấy từ biến | **Lỗi code** | `a397c29` |
| 17 | `You must enable organizations access` | CloudFormation có lời gọi kích hoạt riêng | Thiếu tài liệu | `a397c29` |
| 18 | `InsufficientDeliveryPolicyException` | Sai condition key: `SourceOrgID` thay vì `SourceAccount` | **Lỗi code** | `24836dc` |
| 19 | `InsufficientDeliveryPolicyException` *(vẫn)* | **Object Lock** chặn Config ghi — policy hoàn toàn đúng | **Lỗi thiết kế** | `ee6ebd3` |
| 20 | `explicit deny ... p-2oni53yp` khi rollback | SCP chặn chính CloudFormation | **Lỗi thiết kế** | `150c013` |
| 21 | `NoAvailableDeliveryChannelException` | Vòng lặp giữa hai API Config | **Lỗi code** | `f8754fe` |
| 22 | `NoAvailableConfigurationRecorder` + `UnableToAssumeServiceLinkedRoleException` | `excluded_accounts` không khớp `recorder_target_ous` | **Lỗi thiết kế** | `4e3a406` |
| 23 | User SSO không đăng nhập được, **không lỗi nào** | `CreateUser` không gửi thư mời — tài liệu nói như thể tự động | Thiếu tài liệu | `161c8e7` |
| 24 | `wire-backends.sh` ghi thiếu một layer, im lặng | `backend_hcl` là output nằm trong state — thêm layer phải apply lại `tf-backend` | **Lỗi thiết kế** | `1b67012` |
| 25 | `InsufficientS3BucketPolicyException` | Organization trail ghi vào **hai** prefix, policy chỉ cho một | **Lỗi code** | `e5281e5` |
| 26 | `Runtime.ImportModuleError: No module named 'cfnresponse'` | Module đó **không có** trong `python3.12` — Lambda chết lúc khởi tạo nên không gửi được phản hồi, CloudFormation treo **một giờ** | **Lỗi code** | `cf66390` |
| 27 | Lệnh kiểm chứng in ra **rỗng** dù output vẫn ở đó | Hai bộ lọc JMESPath liên tiếp tạo projection lồng, `--output text` in ra dòng trống | **Lỗi code** | `6336f81` |
| 28 | `terraform plan` **sạch**, cảnh báo bảo mật không tới ai | Email subscription bị SNS xoá; state vẫn giữ ARN thật nên `plan` không thấy gì | **Lỗi thiết kế** | `76dc5b7`, `bc0dfca` |
| 29 | `Invalid template interpolation value` ×4, ngay ở `enable = false` | `one()` trả `null` khi `count = 0`, và null không nội suy được vào string template | **Lỗi code** | `5debc69` |
| 30 | `\1 not defined in the RE` trên macOS, script chạy tốt trên Linux | `sed -i` của BSD **bắt buộc** có tham số hậu tố, nên `sed -i -E` bị đọc thành *"hậu tố = -E"* — mất chế độ ERE, ngoặc thành ký tự thường | **Lỗi code** | `6e771b6` |
| 31 | Script báo `Xong: 1 file` trong khi **không đổi được gì** | Đếm file đã mở thay vì dòng đã sửa. Trên một script chỉ có mỗi việc gỡ lớp chặn cuối cùng, báo thành công giả nguy hơn lỗi 30 | **Lỗi thiết kế** | `6e771b6` |
| 34 | `lz-server-admin` có `s3:*` **ngay trong account log archive** | 10/17 permission set khai `scope = "all"`, mà `all` suy ra từ Organizations nên gồm cả account giữ bằng chứng. `DenyTamperingWithGuardrails` chặn `cloudtrail:DeleteTrail` nhưng **không** chặn `s3:DeleteObject` | **Lỗi thiết kế** | *(mục 7i)* |
| 33 | Nguồn của đường cảnh báo **nằm ngoài code** | `notify.tf` khớp `source = aws.securityhub`, nhưng không layer nào tạo hay quản Security Hub — nó được bật bằng ba lệnh tay ở RUNBOOK giai đoạn 7. Terraform không biết nó tồn tại, nên không ai được báo nếu nó tắt | **Lỗi thiết kế** | *(mục 7h)* |
| 32 | TEARDOWN.md dặn *"giữ `create_organization = false`"* — làm theo là **xoá cả tổ chức** | Câu đó chỉ đúng khi tổ chức chưa nằm trong state. Đã nằm rồi thì đổi biến làm `count` tụt 1→0 = destroy. Mô tả biến ghi đúng, tài liệu teardown ghi ngược | **Tài liệu sai** | `d6f3d1d` |
| 35 | Mô tả biến `delegated_administrators` **mời** khai `guardduty.amazonaws.com`, trong khi layer khác đã sở hữu việc đó | Danh sách "service principal hay dùng" gộp chung hai nhóm khác hẳn nhau: nhóm chỉ đăng ký được qua Organizations, và nhóm có lệnh chỉ định riêng *(lệnh đó tự đăng ký giúp)*. Khai nhóm hai vào map = hai layer cùng sở hữu một sự thật | **Tài liệu sai** | *(mục 7j)* |

| 36 | Comment trong `securityhub.tf` khẳng định một **điều kiện tiên quyết không tồn tại** | Ghi rằng `EnableOrganizationAdminAccount` đòi Security Hub bật sẵn ở management account. Trạng thái thật bác bỏ: management `InvalidAccessException: not subscribed`, mà `list-organization-admin-accounts` vẫn trả về admin `ENABLED` | **Tài liệu sai** | *(mục 7k)* |

| 37 | `guardduty_features = []` được ghi là *"mặc định không bật cái nào"* — thực tế **năm feature tính tiền đang chạy** | Danh sách rỗng sinh ra **không resource nào**, nghĩa là *"Terraform không quản"*, không phải *"tắt"*. Mà AWS **bật sẵn** phần lớn feature khi tạo detector. `check "guardduty_features_cost_money"` đếm `length(var.guardduty_features) = 0` nên im lặng | **Lỗi thiết kế** | *(mục 7l)* |

| 38 | `AccessDeniedException` — **SCP của chính chúng ta** chặn Terraform tắt feature GuardDuty | `deny_guardrails` cấm `guardduty:UpdateDetector`, mà đó là API **duy nhất** để đổi feature. AWS không tách *"tắt detector"* khỏi *"đổi feature"*. Guardrail chặn đúng thứ nó sinh ra để chặn — kể cả khi người gọi là chính mình | **Xung đột thiết kế** | *(mục 7m)* |

| 39 | `RUNTIME_MONITORING` bị **replace ở mọi lần plan**, không bao giờ hội tụ | AWS luôn trả về ba `additional_configuration` bên trong feature đó. Config không khai → Terraform đòi gỡ → `name` là ForceNew → replace. Apply xong AWS điền lại mặc định, plan sau lại đòi replace | **Lỗi code** | *(mục 7m)* |

| 40 | Đường cảnh báo **lọc bỏ toàn bộ finding GuardDuty** | `notify.tf` khớp `Compliance.Status = ["FAILED"]`. `Compliance` là trường **chỉ có** ở finding sinh từ control tuân thủ; GuardDuty phát hiện hành vi nên không có nó — `Comp: null` trên finding thật. EventBridge gặp khoá không tồn tại thì không khớp | **Lỗi code** | *(mục 7n)* |

| 41 | `Provider produced inconsistent result after apply` khi kết nạp **management account** vào GuardDuty | Management account phải **tự bật GuardDuty trước** mới được kết nạp. AWS nói rõ điều đó trong `UnprocessedAccounts`, nhưng `CreateMembers` trả HTTP 200 nên provider coi là thành công, không đọc trường đó, rồi đọc lại thấy rỗng | **Lỗi code** *(+ bug provider)* | *(mục 7o)* |

| 42 | `4 to add, 4 to destroy` ở **mọi lần plan** — và "destroy" là gỡ account thật khỏi GuardDuty | `email` provider không đọc lại nên state rỗng, mà nó là ForceNew; `invite` provider suy từ `relationship_status` nên luôn đọc ra `true`. Cả hai chỉ có nghĩa lúc tạo | **Lỗi code** | *(mục 7o)* |

| 43 | `verify-detection.sh` báo **`SEC HUB THIEU` trên cả 5 account** — một lỗ hổng diện rộng không có thật | Hai dịch vụ có cú pháp CLI khác nhau: `guardduty list-members --only-associated false` (chuỗi) vs `securityhub list-members --no-only-associated` (cờ boolean). Lệnh sai báo `Unknown options: false` và không chạy — nhưng `\|\| true` nuốt mã lỗi, nên "lệnh hỏng" trông y hệt "không account nào được ghi danh" | **Lỗi code** | *(mục 7p)* |
| 44 | Cùng script báo `CONFIG THIEU` cho một OU **cố ý không bật recorder** | Suy phạm vi từ nơi *đã có* stack instance thì không phân biệt được "trong phạm vi mà thiếu" với "ngoài phạm vi có chủ đích" | **Lỗi thiết kế** | *(mục 7p)* |

| 45 | Security Hub **không có member nào** — `auto_enable = true` nhưng `list-members` rỗng | `auto_enable` là chính sách cho account **tạo sau**; năm account đã tồn tại từ trước chưa bao giờ được gọi `CreateMembers`. Cùng hình dạng lỗi 41 ở GuardDuty | **Lỗi thiết kế** | *(mục 7p)* |

| 46 | `plan-check.sh` báo **10 lỗi hành vi** trên một plan 175 resource có đủ mọi thứ nó tìm | `set -o pipefail` + `echo "$BIG" \| grep -q X`: `grep -q` thoát ngay khi khớp, `echo` chết vì SIGPIPE (141), `pipefail` lấy 141 làm mã thoát → **tìm thấy** đọc thành **không thấy**. Chỉ lộ khi đầu vào đủ lớn | **Lỗi code** | *(mục 7q)* |

| 47 | `InvalidRequestException: ResourceArn has invalid rule order` — apply chết giữa chừng ở phút thứ 10 | Policy đặt `rule_order = STRICT_ORDER`, nhưng rule group `egress_domains` không khai — mặc định là `DEFAULT_ACTION_ORDER`. **`terraform plan` không bắt được**: hai resource riêng biệt, plan không đối chiếu thuộc tính giữa chúng | **Lỗi code** | *(mục 7r)* |

| 48 | `verify.sh` báo **3 lỗi hạ tầng** trên một mạng đang chạy đúng | `PROJECT` gán cứng `lz-net`, còn `var.project` thật là `quh11-net`. Mọi lookup theo `tag:Name` trả về `None`, và `None` được in ra thành *"THIẾU đường về"*, *"rtb-spokes không tồn tại"* | **Lỗi code** | *(mục 7s)* |

| 49 | Spoke khai `account_id` sẽ được tạo **hai lần** — một VPC local và một VPC remote, trùng CIDR | Thêm nhánh remote nhưng để nguyên 22 chỗ `for_each = var.spokes` ở tám file khác. `var.spokes` giờ mang **hai loại** spoke, mà mọi resource cũ vẫn coi nó là một | **Lỗi thiết kế** | *(mục 7t)* |

| 50 | `Invalid for_each argument` — plan chết, không dựng được bộ khoá | Data source tìm attachment lọc theo `aws_ec2_transit_gateway.hub.id`, mà TGW được **tạo trong chính config đó**. Lần apply đầu ID chưa biết → danh sách chưa biết. Đúng điều `landing-zone/network` đã cảnh báo và tôi cho là *"sai một nửa"* | **Lỗi thiết kế** | *(mục 7u)* |

| 51 | Hướng dẫn chạy từ **management account** — đẩy toàn bộ hub mạng vào đúng account không được phép chứa nó | StackSet `SERVICE_MANAGED` cần management *hoặc* delegated admin. Tôi lấy vế đầu, quên vế sau — mà demo chỉ có **một provider**, nên TGW, security VPC, egress, firewall, NLB đều theo sang | **Lỗi thiết kế** | *(mục 7v)* |

| 52 | Ba lỗi cùng lúc lúc apply: RAM share bị từ chối ×2, `OrganizationalUnitIds are required` | StackSet `SERVICE_MANAGED` triển khai theo **cây tổ chức** — `accounts` chỉ là bộ lọc trong OU, không thay được OU. Và RAM sharing với Organizations là một bước bật **một lần ở cấp tổ chức** mà tôi không biết tới | **Lỗi code** *(+ thiếu điều kiện tiên quyết)* | *(mục 7w)* |

| 53 | RAM share vẫn hỏng dù đã bật `enable-sharing-with-aws-organization` từ hai tuần trước | ~~Member account không share được với cả tổ chức~~ — **kết luận này đã bị bác bỏ ở mục 7z**: management account cũng hỏng. Nguyên nhân thật vẫn chưa biết | **Chưa kết luận** | *(mục 7x, 7z)* |

| 54 | `Description` của template CloudFormation gây **diff vĩnh viễn** | Chuỗi có dấu tiếng Việt; CloudFormation lưu lại với `?` thay cho dấu, nên Terraform đòi sửa ở mọi lần plan và CloudFormation lại bóp méo tiếp. Cùng họ với lỗi 39 và 42 | **Lỗi code** | *(mục 7x)* |

| 55 | ~~RAM từ chối `AssociateResourceShare`~~ — **kết luận sai**, xem mục 7z | Thao tác đó chạy bình thường trên share có `allowExternalPrincipals = true`. Điều kiện thật không nằm ở lệnh nào, mà ở việc share có cần tra tổ chức hay không. Terraform cũng không bị chặn | **Chẩn đoán sai** | *(mục 7y, 7z)* |

| 56 | **RAM không phân giải được tổ chức**, kể cả từ management account | Thí nghiệm đối chứng, đổi đúng một biến: cùng account ID, `--no-allow-external-principals` hỏng / `--allow-external-principals` chạy. Account trong org bị RAM đánh dấu `"external": true`. Service-linked role có, trusted access bật, FeatureSet `ALL`, OU tồn tại, chỉ `FullAWSAccess` | **Lỗi phía AWS** *(chờ Support)* | *(mục 7z)* |

| 57 | Pha 2 báo `0 added` — attachment của spoke remote **không bao giờ** được tìm thấy | Code đối chiếu tag `Name` mà template đặt ở account đích. Tag trên resource chia sẻ thuộc về account tạo ra chúng: chủ TGW thấy attachment, `"tags": []`. Tệ hơn: thông báo của `check` khuyên "apply lại lần nữa" — một vòng lặp vô hạn. `verify.sh` cùng lúc báo 7 đạt 0 lỗi vì không mục nào nhìn qua ranh giới account | **Lỗi code** | *(mục 7aa)* |

| 58 | Cùng script, cùng hạ tầng: `17 đạt 0 lỗi` rồi `6 đạt 8 lỗi` | Shell còn credential của account spoke. Script đọc **state** từ thư mục (đúng) nhưng gọi **AWS** bằng credential trong shell (nhầm account), nên mọi câu trả lời rỗng bị đọc thành "thiếu". `teardown.sh` còn nguy hơn: destroy không xoá được gì rồi báo `DA SACH`. Vá bằng `output "account_id"` + `exit 1` ở đầu cả hai script | **Lỗi code** | *(mục 7ac)* |

| 59 | StackSet không dựng được VPC ở **management account**, và không nguồn nào nói vì sao | `SERVICE_MANAGED` triển khai theo cây tổ chức; AWS loại management account ra. Provider in `%!s(<nil>)`, CloudFormation không có `StatusReason`, và `list-stack-instances` chỉ *thiếu* một dòng. Vá bằng `manual_vpc = true` + `output "spoke_template"` | **Giới hạn dịch vụ** | *(mục 7ad)* |

| 60 | `terraform destroy` xoá 143 resource, script báo **`CON 1 muc chua xoa`** | `resourcegroupstaggingapi` trả về cả resource **đã xoá**; TGW ở `deleted`, EC2 ở `terminated` vẫn còn tag. Mười phép kiểm lọc theo trạng thái sống nên đều xanh — hai kết quả mâu thuẫn, và cái sai là lệnh quét | **Lỗi code** | *(mục 7ae)* |

| 61 | `Invalid count argument` — `count` đọc `private_ip` của EC2 | Tôi kéo một thuộc tính **chỉ biết sau apply** vào `count`, thứ phải tính được ở **plan**. Code cũ tránh được vì dùng biến trong `count` và chỉ chạm thuộc tính ở `target_id`. Vá bằng cách tách `use_local_target` (biến, biết ở plan) khỏi `nlb_target_ip` (thuộc tính, biết sau apply). Cùng họ với lỗi 50 | **Lỗi code** | *(mục 7af)* |

| 62 | Đổi tên spoke từ `app-dev` sang `probe` → **mục 1 và 2 của `verify.sh` không in một dòng nào** | Script lọc VPC theo `${PROJECT}-app-*-vpc` và tìm EC2 theo `.["app-dev"]` — một **quy ước đặt tên**, không phải sự thật. Không khớp thì vòng lặp không chạy, bảng ngắn đi hai dòng và không báo gì. Mục 7 thì bỏ qua với lý do **sai**: `enable_test_instances = false` trong khi nó đang `true`. Vá bằng `output "spoke_names"` | **Lỗi code** | *(mục 7ag)* |

| 63 | 3/4 spoke báo `khong thong` cổng 80 — mà **mạng hoàn toàn bình thường** | `UserData` chạy `dnf install nginx`, cần Internet. Nhưng pha 3 tạo EC2 xong là nó boot ngay, còn pha 4 mới nối attachment vào route table — giữa hai pha spoke **không có đường ra**. Một cuộc đua giữa cloud-init và `terraform apply`; cái duy nhất chạy được là stack instance cuối cùng. Dấu hiệu phân biệt nằm ở cổng 22: `ncat` **kết nối được** cả bốn | **Lỗi code** | *(mục 7ah)* |

| 64 | Bản vá cho lỗi 63 **làm hỏng chính phép đo đó** — cả bốn spoke trả về chuỗi rỗng | Lệnh chẩn đoán mới chứa dấu nháy kép (`echo " rc=$?"`), mà `run_remote` nhúng lệnh vào JSON của SSM. Nháy kép phá vỡ JSON, SSM từ chối, output rỗng — và chuỗi rỗng đọc y hệt "không thông". Cái đang chạy được (`logarchive`) cũng đỏ theo | **Lỗi code** | *(mục 7ai)* |

| 65 | Sửa template StackSet rồi `terraform apply` → **code cũ vẫn chạy ở bốn account** | `terraform apply` báo `1 changed`, `list-stack-set-operations` có `UPDATE SUCCEEDED`, `list-stack-instances` báo `CURRENT` — ba chỉ số đều xanh, và cả ba đều **không** nói instance đang chạy template nào. Thứ cho câu trả lời là nội dung trang HTTP: vẫn là trang nginx cũ | **Giới hạn công cụ** | *(mục 7aj)* |

| 66 | Bốn nguyên nhân khác hẳn nhau, **một thông báo duy nhất**: `HeadObject ... 403 Forbidden` | Key ngoài prefix được cấp / thiếu `role_arn` / thiếu `ListBucket` / sai danh tính — S3 trả cùng một câu cho cả bốn. Đoán ba lần đều sai. Phép đo phân biệt: `head-object` lên một key **đã tồn tại** rồi lên một key **chưa tồn tại**, cùng prefix | **Giới hạn công cụ** | *(mục 7ak)* |
| 67 | `s3:ListBucket` được cấp nhưng **không có tác dụng** khi Terraform hỏi "state đã có chưa" | Statement mang `Condition = { StringLike = { "s3:prefix" = ... } }`, mà `s3:prefix` **chỉ có trong yêu cầu list**. `HeadObject` không phải lệnh list → điều kiện không khớp → coi như không cấp. Hệ quả: key đã tồn tại đọc được, key chưa tồn tại 403 — **mọi layer mới hỏng ở lần init đầu và chỉ lần đầu** | **Lỗi thiết kế** (chính repo) | *(mục 7ak)* |
| 68 | `unset` biến môi trường rồi mà Terraform **vẫn gọi bằng danh tính cũ** | `unset` chỉ tác dụng trong đúng shell đó; thiết lập SSO đặt lại `AWS_PROFILE` từ `~/.zshrc` hoặc mỗi tab mới. Và biến môi trường **đứng trước** `profile` trong chuỗi giải credential — cùng thư mục, hai shell, hai danh tính, không có gì báo | **Giới hạn công cụ** | *(mục 7ak)* |
| 69 | `${path.module}` trong `description` của một variable → `init` hỏng | Terraform nội suy cả chuỗi trong `description`, mà `path.module` không dùng được ở đó. `terraform fmt` cho qua (cú pháp đúng), và môi trường viết code không ra được registry nên `validate` chưa từng chạy | **Lỗi code** | *(mục 7ak)* |
| 70 | So sánh hai chuỗi ngày ISO bằng `>` → `Invalid operand: a number is required` | HCL chỉ so sánh **số** bằng `>`/`<`. Thứ tự từ điển của ngày ISO đúng về mặt lịch nhưng Terraform từ chối thẳng. Đổi sang số `YYYYMMDD` | **Lỗi code** | *(mục 7ak)* |
| 71 | `x != null && f(x)` vẫn nổ vì `null` — ở **năm chỗ** | `&&` trong HCL **không short-circuit**: cả hai vế đều được tính, kể cả khi vế trái đã false. `can(...)` đặt ở vế trái làm chắn cũng vô tác dụng. Không báo lúc viết, chỉ báo khi có dữ liệu thật đi qua nhánh đó | **Lỗi code** | *(mục 7ak)* |
| 72 | `terraform output bootstrap_done` báo `false` cho một cấu hình **đã đúng** | `output` in giá trị **đã lưu trong state**, không tính lại. Giá trị đó tính từ lần apply trước, khi ARN chưa được cắm. Phải `terraform apply` để đọc lại `terraform_remote_state` | **Giới hạn công cụ** | *(mục 7ak)* |
| 73 | `wire-backends.sh` có phép kiểm "layer trên đĩa mà không có trong state" — và **không kêu** về layer mới | Vòng lặp chỉ quét `landing-zone/*/`. Một layer nằm trong `demo/` không bao giờ bị hỏi tới. Phép kiểm tồn tại, chạy, báo xanh, và không nhìn vào chỗ cần nhìn | **Lỗi code** | *(mục 7ak)* |

**63/73 là lỗi trong code hoặc thiết kế của repo**, không phải người dùng làm sai. Đó là lý do file này tồn tại.

> Mười ba lỗi cuối đến từ **vòng xoá–dựng lại và phần rà lại guardrail** (mục 7), không phải lần dựng đầu. Chúng chỉ lộ ra khi đi ngược chiều — và lỗi 32 là loại đáng sợ nhất: một câu dặn nghe hợp lý, trong tài liệu do chính tôi viết, mà làm theo thì mất tổ chức.

> Lỗi 27 là loại tệ nhất trong cả bảng: nó không báo hỏng. Nó nói *"không có gì"* — và "không có gì" đúng là câu trả lời mình **mong đợi** sau khi đã dọn tay. Suýt nữa thì viết vào tài liệu rằng lớp mới không tìm thấy gì, trong khi nó vừa xoá năm cái VPC thật.

---

## 2. Bảy lỗi đáng học nhất

### 2.1. Một service principal sai làm hỏng cả resource

```
Error: enabling AWS Service Access (reports.billing.amazonaws.com):
InvalidInputException: You specified an unrecognized service principal.
```

`aws_organizations_organization` nhận một **danh sách** service principal. Sai một phần tử là AWS từ chối cả lời gọi — và **không nói cái nào sai**.

Tệ hơn: **organization đã được tạo** trước khi bước bật service access lỗi. Nên lần plan sau ra `AlreadyInOrganizationException`, và resource bị đánh dấu **tainted** (lỗi #9).

Bài học: với resource có danh sách "bật/tắt dịch vụ", giữ danh sách **tối thiểu và đã kiểm chứng**. Nay nó là biến, sửa `terraform.tfvars` chứ không sửa resource:

```bash
aws organizations list-aws-service-access-for-organization
```

### 2.2. Vòng lặp con gà – quả trứng, và cái thứ hai tôi tự tạo ra

Layer `tf-backend` **tạo ra chính cái bucket** nó dùng để cất state. Lần đầu bắt buộc chạy state local.

Ban đầu tôi giải bằng một dòng comment trong `versions.tf`, kèm ghi chú *"bỏ comment ở bước 3"*. Ba thứ hỏng theo:

| | |
|---|---|
| Bỏ comment sớm | `terraform init` hỏi nhập bucket, mọi lệnh sau báo `Backend initialization required` |
| `versions.tf` được git track | Bật backend thành một commit riêng của máy — **branch diverged ngay lần pull đầu** |
| Clone mới | Có sẵn backend đang bật — sai hoàn toàn cho lần chạy đầu |

Sửa gốc: backend chuyển sang **`backend.tf` do script sinh**, gitignore.

```
Khong co backend.tf  ->  Terraform tu dung state local
Chay wire-backends   ->  backend.tf xuat hien  ->  remote state
```

Thứ tự tự đúng, không phải nhớ. **Không còn file track nào phải sửa.**

Nhưng nó đẻ ra vòng lặp thứ hai: script cần **đọc state** để biết tên bucket, mà đọc state lại **cần `backend.tf`**. Mất `backend.tf` (nó gitignore nên `git reset --hard` quét phải) là không có đường quay lại.

Gỡ bằng cách nhận diện đúng hình dạng — *không có `backend.tf`, còn `backend.hcl`, state đọc không được* — rồi dựng lại từ `backend.hcl`, file sống sót qua cùng những thao tác đó.

> **Bài học chung:** mỗi lần "giải quyết" một phụ thuộc vòng bằng cách dời nó đi, kiểm tra xem có tạo ra vòng mới không.

### 2.3. Thông báo lỗi đoán mò tệ hơn không có thông báo

Script cũ:

```bash
if ! configs=$(terraform output -json backend_hcl 2>/dev/null); then
  red "Khong doc duoc output backend_hcl. Da apply chua?"
```

`2>/dev/null` vứt đi thứ duy nhất hữu ích — Terraform nói gì. Ba tình huống rất khác nhau (state rỗng / apply dở dang / backend chưa init) đều ra **một câu đoán mò**.

Sửa: tách ba nhánh, và **in nguyên văn** Terraform nói gì.

```bash
if ! state_out=$(terraform state list 2>&1); then
  if echo "$state_out" | grep -q "Backend initialization required"; then
    # tinh huong cu the -> huong dan cu the
```

### 2.4. `create_organization` — tên biến nói dối

Bảng preflight ghi: *`describe-organization` ra kết quả → đặt `false`*. Đúng cho **lần chạy đầu**.

Nhưng sau khi Terraform đã tạo org, đổi về `false` nghĩa là `count` 1 → 0 → **Terraform lên kế hoạch xoá organization**, kéo theo mọi account con ra khỏi tổ chức.

`prevent_destroy` chặn được — đúng lúc, đúng việc. Nhưng thông báo `Instance cannot be destroyed` đọc như lỗi, không như lưới an toàn.

Tên biến sai ngay từ đầu: nó không phải *"có tạo mới không"* mà là **"Terraform có quản lý resource này không"** — và một khi đã `true` thì phải giữ `true`.

> Muốn thật sự chuyển sang chỉ đọc thì gỡ khỏi state trước, **không** đổi biến:
> ```bash
> terraform state rm 'aws_organizations_organization.this[0]'
> ```

### 2.5. Viết cảnh báo về cái bẫy rồi vẫn ngã vào nó

Giai đoạn 5, lệnh đầu tiên ở layer `permission-sets` đã dừng:

```
Error: Inconsistent conditional result types
  The 'true' tuple has length 2, but the 'false' tuple has length 0.
```

Đoạn gây lỗi:

```hcl
deny_create_without_boundary = var.enforce_security_admin_boundary ? [
  { Sid = "...", Action = [...], Resource = "*", Condition = { ... } },   # CO Condition
  { Sid = "...", Action = [...], Resource = "arn:...:policy/lz-boundary" } # KHONG co Condition
] : []
```

Terraform kiểm kiểu **cả hai nhánh**, kể cả khi biến là `false` — nên lỗi xuất hiện bất kể cấu hình. Layer này chưa từng `plan` được lần nào.

Cơ chế: hai object có bộ thuộc tính khác nhau (một có `Condition`, một không) nên không quy được về `list(object)` chung. Kết quả giữ nguyên kiểu **tuple**. Tuple độ dài 2 và tuple độ dài 0 là hai kiểu khác nhau, không thống nhất được — trong khi `list(X)` độ dài 2 và độ dài 0 thì thống nhất bình thường.

> Đây chính là hạn chế mà comment đầu `permission-sets.tf` đã mô tả và đã có cách vòng tránh — `jsonencode` từng statement thành **chuỗi**, rồi ghép `list(string)`. Cách vòng tránh được áp dụng đúng ở file này, nhưng file `locals-policies.tf` bên cạnh vẫn còn một chỗ dùng list object thô.

Thứ khiến nó sống sót lâu: **hai công tắc cho một việc**. `local.guard_bound` trong `permission-sets.tf` đã quyết định có dùng hai statement này hay không; điều kiện trong `locals-policies.tf` là thừa. Cách chữa là bỏ cái thừa — tách thành hai local riêng, không điều kiện, không đánh chỉ số list:

```hcl
deny_create_without_boundary = { Sid = "DenyCreatePrincipalWithoutBoundary", ... }
deny_boundary_tampering      = { Sid = "DenyRemovingOrEditingTheBoundaryItself", ... }
```

**Lỗi thứ hai lộ ra ngay sau đó.** `validate-policies.sh` đáng lẽ phải bắt được chuyện này từ lâu, nhưng nó im lặng:

```bash
sets=$(terraform console <<<'keys(local.permission_sets)' | tr -d '[]",' | tr ' ' '\n' | sed '/^$/d')
```

Mã thoát của một pipeline là mã thoát của **lệnh cuối** — tức `sed`, luôn bằng 0. `set -e` không bao giờ nổ, lỗi của Terraform chỉ hiện trên stderr rồi script in tiếp một bảng rỗng và thoát 0. Một script kiểm tra báo "đạt" khi không kiểm được gì thì tệ hơn là không có script.

Bản viết lại gọi `terraform console` **một lần** (thay vì ~100 lần, mỗi statement một lần), bắt stderr ra file, và kiểm tra mã thoát tường minh. Thêm hai chi tiết cụ thể của `terraform console` phi tương tác, phải thoả **đồng thời**:

| Ràng buộc | Vi phạm thì báo |
|---|---|
| Đánh giá **từng dòng** — không nhận biểu thức nhiều dòng | `Missing expression` |
| HCL cần newline **hoặc dấu phẩy** giữa các thuộc tính object | `Missing attribute separator` |

Ép biểu thức về một dòng thoả điều 1 thì vi phạm điều 2. Nên phải viết nhiều dòng *có dấu phẩy sau mỗi thuộc tính*, rồi `tr '\n' ' '`.

Kiểm chứng bản mới bằng một **test âm** — nhân đôi một mảnh statement để tạo `Sid` trùng:

```
lz-billing    1331    3    TRUNG Sid
CO LOI - khong apply.        EXIT=1
```

Bắt đúng và thoát khác 0. Bài học: mỗi lưới an toàn phải được thử bằng một trường hợp *chắc chắn sai*, nếu không thì không biết nó có còn hoạt động hay không.

### 2.6. Hai cấu hình mà không giá trị nào làm cho đúng được

`billing-guard` hỏng hai lần liên tiếp, và cả hai đều cùng một dạng: code yêu cầu một thứ **AWS không bao giờ chấp nhận**, bất kể điền gì vào biến.

**Lần một** — mỗi account chỉ được **một** dimensional anomaly monitor, và AWS thường đã tự tạo sẵn một cái tên "Services" khi Cost Explorer được bật:

```
ValidationException: Limit exceeded on dimensional spend monitor creation
```

Code vô điều kiện xin cái thứ hai. Cách chữa là **mượn thay vì tạo** — thêm `service_anomaly_monitor_arn`, để rỗng thì tạo mới, điền ARN thì bỏ qua bước tạo và gắn thẳng subscription vào cái sẵn có.

Vì sao không `terraform import`? Import cũng chạy được, nhưng nó trao cho Terraform quyền sở hữu một thứ Terraform không tạo ra — ngày `destroy` layer này thì monitor mặc định của account bị xoá theo. Ranh giới đúng: Terraform quản lý subscription, còn monitor thì mượn.

**Lần hai** — `frequency` và `subscriber.type` không độc lập với nhau:

```
ValidationException: Daily or weekly frequencies only support Email subscriptions
```

| `frequency` | Subscriber nhận được |
|---|---|
| `DAILY` / `WEEKLY` | **chỉ** `EMAIL` |
| `IMMEDIATE` | `SNS` (và `EMAIL`) |

Code ghép `DAILY` với `SNS`. Cách chữa **không phải** đổi thành `IMMEDIATE` rồi thôi — hai trường ràng buộc nhau nhưng nằm cách nhau mấy dòng, để nguyên thì lần sau lại ghép sai. Thay bằng một biến đặt cả hai:

```hcl
anomaly_alert_mode = "sns_immediate"   # IMMEDIATE + SNS
anomaly_alert_mode = "email_daily"     # DAILY + EMAIL
```

Và đây là khác biệt thật, không chỉ cú pháp: ở chế độ `email_daily`, Cost Explorer gửi **thẳng** tới từng địa chỉ, **không qua SNS topic**. Muốn đẩy cảnh báo bất thường sang Slack sau này thì phải làm lại từ đầu. `sns_immediate` giữ mọi cảnh báo chi phí đi chung một cửa.

> **Dạng lỗi này đáng nhận ra:** khi hai trường của cùng một resource ràng buộc lẫn nhau, để chúng là hai biến riêng nghĩa là mời người dùng ghép sai. Gộp thành một biến với danh sách giá trị hợp lệ thì tổ hợp sai không tồn tại.

**Và điều cả hai lỗi này nói về repo:** không lỗi nào bị `terraform validate` bắt được — cú pháp đúng, kiểu đúng, tham chiếu đúng. Chỉ AWS mới biết. Nghĩa là **layer nào chưa apply thật thì chưa tin được**, và đó là thông tin nên có khi đọc repo này:

| Layer | Đã chạy thật |
|---|---|
| `tf-backend`, `organization`, `permission-sets`, `billing-guard` | ✔ |
| `config-detective`, `control-tower` | ✘ — và `config-detective` là layer duy nhất tốn tiền |

---

## 3. Ba lưới an toàn đã cứu bài

Những thứ này chặn đúng lúc — đáng giữ lại trong mọi thiết kế sau:

| Lưới | Chặn gì |
|---|---|
| `prevent_destroy` trên organization | Kế hoạch xoá org (2 lần) |
| `scp_dry_run = true` mặc định | SCP gắn nhầm trước khi kịp đọc nội dung |
| Kiểm tra **"phải chạy được"** cạnh "phải bị chặn" | Siết quá tay — lỗi im lặng nhất |

Cái thứ ba đáng nói riêng. Ba lệnh kiểm chứng SCP đầu tiên đều là *"phải bị từ chối"*. Nếu chỉ có chúng thì một SCP chặn **quá tay** vẫn "pass" hết. Nên phải luôn có ít nhất một lệnh *"phải chạy được"*:

```bash
aws ec2 describe-vpcs --region ap-southeast-1 --profile lz-network   # PHAI THANH CONG
```

---

## 4. Phát hiện không phải lỗi: default VPC

Lệnh kiểm chứng "phải chạy được" lộ ra thứ đáng chú ý:

```json
"VpcId": "vpc-0f37e24fbed5a5b38",
"CidrBlock": "172.31.0.0/16",
"IsDefault": true
```

AWS tạo **default VPC ở mọi region** cho mọi account mới, và nó **có sẵn Internet Gateway**.

Đây đúng là thứ phá vỡ thiết kế *"không account nào ra Internet trực tiếp"* ở [doc 13](./13-Centralized-Ingress-Egress-Network.md): SCP chặn **tạo mới** IGW, nhưng cái có sẵn từ lúc account ra đời thì không.

Phải xoá cho **mọi region** trong `allowed_regions`, và lặp lại cho **mọi account mới**:

```bash
REGION=ap-southeast-1; PROFILE=lz-network; VPC=vpc-xxxx

for s in $(aws ec2 describe-subnets --region $REGION --profile $PROFILE \
    --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id $s --region $REGION --profile $PROFILE
done

IGW=$(aws ec2 describe-internet-gateways --region $REGION --profile $PROFILE \
  --filters Name=attachment.vpc-id,Values=$VPC \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC --region $REGION --profile $PROFILE
aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $REGION --profile $PROFILE

aws ec2 delete-vpc --vpc-id $VPC --region $REGION --profile $PROFILE
```

Đây chính là việc [doc 09](./09-Account-Vending-Tu-Dong.md) gọi là **account baseline** và giao cho StackSet làm tự động. Layer đó **chưa có code** — nên tạm thời làm tay, và nó là ứng viên số một cho lần bổ sung tiếp theo.

> **Đính chính, viết sau khi lớp tự động chạy (mục 6d).** Đoạn trên nói "phải xoá cho **mọi** region". Thực tế lần dọn tay chỉ chạy ở `ap-southeast-1` — cái region đang mở terminal. `us-east-1` **cũng nằm trong `allowed_regions`** mà không ai đụng tới, và cả **năm** account thành viên vẫn còn nguyên default VPC ở đó, kèm Internet Gateway, cho tới khi `account-baseline` xoá chúng.
>
> Câu "đã xoá ở mọi region" được viết ra vì vòng lặp bash lúc đó chỉ có một region trong biến. Không lệnh nào báo sai — nó làm đúng cái được bảo làm.

---

## 5. Kiểm chứng cuối

Ba lệnh, chạy từ account con đầu tiên:

```bash
aws ec2 describe-vpcs --region eu-west-1 --profile lz-network
# UnauthorizedOperation ... explicit deny in a service control policy: p-93vo2yro   <- region_lock

aws ec2 describe-vpcs --region ap-southeast-1 --profile lz-network
# tra ve VPC  <- dung, khong siet qua tay

aws iam create-user --user-name test --profile lz-network
# AccessDenied ... explicit deny in a service control policy: p-2oni53yp   <- baseline
```

Thông báo lỗi của AWS **chỉ đích danh policy ID** — rất hữu ích khi có nhiều SCP chồng nhau. Ghi lại ID lúc `terraform output scp_summary` để đối chiếu.

### 5b. Giai đoạn 5 — permission-sets

Apply sạch sau khi sửa lỗi #10 và #11: **115 resource**.

| Resource | Số lượng |
|---|---|
| `aws_ssoadmin_permission_set` | 17 |
| `aws_ssoadmin_permission_set_inline_policy` | 16 |
| `aws_ssoadmin_managed_policy_attachment` | 12 |
| `aws_identitystore_group` | 15 |
| `aws_identitystore_user` + membership | 2 |
| `aws_ssoadmin_account_assignment` | **53** |

`lz-account-admin` không có inline policy — chỉ dùng `AdministratorAccess` managed. Đó là lý do 16 chứ không phải 17.

**53 assignment tính ra sao**, với 5 account trong phạm vi `all` (6 ACTIVE trừ management):

| Nhóm | Assignment |
|---|---|
| 10 group phạm vi `all` × 5 account | 50 |
| `lz-app-teams`: `lz-app-admin` (1 nonprod) + `lz-app-operator` (1 prod) | 2 |
| `lz-billing-team` → management | 1 |
| 3 group analytics/datalake — chưa có account | 0 |

Mỗi assignment làm Identity Center tự tạo một IAM role `AWSReservedSSO_<set>_<hash>` trong account đích. 53 assignment = 53 role.

> **Tính trước con số rồi mới apply.** Plan ra đúng 115 nghĩa là phần locals, ma trận group và phạm vi account đều khớp nhau. Ra khác 115 thì có gì đó lệch — và lúc đó dễ tìm hơn nhiều so với sau khi apply.

**Cảnh báo đúng, không phải lỗi:**

```
Warning: Cac pham vi sau dang RONG nen khong sinh assignment nao: analytics
```

Chưa có account Data Analytics. Ba group `lz-analytics-*` và `lz-datalake-admins` vẫn được tạo nhưng chưa gán đi đâu. `check` block chỉ cảnh báo, không chặn apply — cố ý.

**Ba việc Terraform không làm được**, phải vào console:

| Việc | Không làm thì sao |
|---|---|
| Billing → *IAM user and role access to Billing information* → Activate | `lz-billing` bị `AccessDenied` dù policy đúng hoàn toàn |
| Identity Center → Settings → Authentication → *Require MFA every time* | Không có MFA |
| Bật Identity Center lần đầu | Data source trả list rỗng, apply lỗi ở `tolist(...)[0]` |

Việc đầu là thứ khó đoán nhất: policy đúng, permission set đúng, assignment đúng, vẫn `AccessDenied`.

> **Đừng** đặt điều kiện `aws:MultiFactorAuthPresent` trong policy của permission set để thay cho việc bật MFA ở console. Phiên Identity Center không mang claim đó một cách đáng tin, thêm vào chỉ sinh `AccessDenied` khó hiểu.

**Một mâu thuẫn thiết kế lộ ra khi đọc `assignment_matrix`:** `lz-db-admin` và `lz-server-admin` có phạm vi `all`, tức có quyền ghi ở cả `lz-app-prod` — trong khi `lz-app-admin` cố ý chỉ có nonprod với lý do *"không người nào ghi được lên prod application"*. `dynamodb:Scan` trong `lz-db-admin` còn đọc được toàn bộ dữ liệu production.

Với lab thì chấp nhận được. Với môi trường thật thì phải chọn: hoặc hạ hai set đó xuống `nonprod` và thêm breakglass tương ứng, hoặc thừa nhận câu "không ai ghi được lên prod" chỉ đúng với tầng application. Xem [doc 19 mục 4.3](./19-Permission-Set-cho-Landing-Zone.md).

### 5c. Ba lần hỏng một phép thử SCP

Mục 3 nói *phải luôn có một lệnh "phải chạy được" bên cạnh các lệnh "phải bị chặn"*. Đúng, nhưng chưa đủ. Kiểm chứng `prod_guard` hỏng **ba lần liên tiếp**, mỗi lần một lý do khác, và cả ba lần đều "ra lỗi" trông rất thuyết phục.

Ý tưởng ban đầu vẫn đúng: chạy cùng một lệnh ở hai account chỉ khác nhau ở OU. Prod bị SCP chặn, dev thì không. Không cần tạo tài nguyên gì vì **SCP được đánh giá trước khi AWS kiểm tra tài nguyên có tồn tại** — nên `NotFound` ở dev chính là bằng chứng request đã đi lọt qua tầng SCP.

Cái sai nằm ở việc chọn lệnh.

| Lần | Lệnh | Kết quả | Vì sao vô nghĩa |
|---|---|---|---|
| 1 | `kms schedule-key-deletion --key-id alias/aws/ebs` | `InvalidArnException` | KMS từ chối alias trước khi tới phân quyền; AWS-managed key vốn không xoá được |
| 2 | `ec2 delete-snapshot --snapshot-id snap-00000000000000000` | `InvalidSnapshotID.Malformed` ở **cả hai** | ID toàn số 0 không qua kiểm tra định dạng |
| 3 | `backup delete-backup-vault --backup-vault-name khong-ton-tai-test` | `AccessDeniedException` ở **cả hai**, dù principal là `OrganizationAccountAccessRole` | AWS Backup trả `AccessDenied` cho vault **không tồn tại** thay vì `ResourceNotFoundException` — nó không tiết lộ tài nguyên có tồn tại hay không. Thông báo cũng không nêu tên policy |

Rút ra ba điều kiện, thiếu cái nào cũng hỏng:

| # | Điều kiện | Vi phạm thì |
|---|---|---|
| 1 | Tham số **hợp lệ về định dạng** | Request dừng ở tầng kiểm tham số, không bao giờ chạm tới phân quyền |
| 2 | Principal **vốn được phép** nếu không có SCP | Đang đo identity policy của chính mình, không đo SCP |
| 3 | Service **phân biệt được** "không có quyền" với "không tồn tại", và **nêu tên policy** | Không phân biệt được deny đến từ SCP hay từ đâu khác |

Điều kiện 3 là cái tinh vi nhất, và là cái đã lừa được lần thứ ba. Ai cũng ngầm giả định rằng gọi API lên một tài nguyên không tồn tại thì sẽ ra `NotFound`. **AWS Backup thì không**: nó trả `AccessDenied` cho vault không tồn tại, cố ý không tiết lộ tài nguyên có tồn tại hay không. Cả hai account ra cùng một câu, dù ở dev chẳng có SCP nào chặn `backup:` — chỉ `prod_guard` nhắc tới nó trong toàn bộ 4 SCP.

Điều kiện 2 thì chưa vấp lần nào, nhưng vẫn phải nhớ: ba phép thử ở mục 5 chạy đúng một phần **nhờ hoàn cảnh** — lúc đó chưa có Identity Center nên buộc phải dùng `OrganizationAccountAccessRole`. Sau giai đoạn 5, nếu đăng nhập bằng permission set hẹp thì cùng một lệnh sẽ cho cùng một lỗi ở mọi account và chẳng chứng minh gì. Chạy `aws sts get-caller-identity` trước để biết mình đang là ai.

> **Dấu hiệu nhận biết, kiểm trước tiên:** hai account cho ra **cùng một** thông báo lỗi. Cặp lệnh chỉ khác nhau ở OU — kết quả giống nhau nghĩa là chưa cái nào chạm tới SCP. Dấu hiệu này bắt được cả ba lần hỏng, kể cả lần đầu nếu lúc đó tôi chạy đủ cả cặp.

Nêu tên policy trong lỗi và phân biệt `NotFound` với `AccessDenied`: EC2, IAM, S3. Không phân biệt: AWS Backup, và nhiều service mới hơn cũng theo hướng không tiết lộ sự tồn tại. Ưu tiên nhóm đầu.

Lệnh cuối cùng dùng được:

```bash
aws sts get-caller-identity --profile <prod>    # xac nhan la admin TRUOC da

aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0 --profile <prod>
# AccessDenied ... explicit deny in a service control policy: p-xxxx

aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0 --profile <dev>
# InvalidSnapshot.NotFound
```

**Bài học rộng hơn cả SCP:** một phép kiểm chứng bảo mật báo "đạt" vì lý do sai thì nguy hiểm hơn không kiểm gì — nó tạo niềm tin không có cơ sở. Mọi phép thử "phải bị chặn" cần một cách phân biệt *bị chặn đúng chỗ mình nghĩ* với *bị chặn ở đâu đó khác*.

### 5d. Cùng một `tainted`, hai cách xử lý ngược nhau

Taint xuất hiện hai lần trong buổi, và cách đúng lần sau **ngược hẳn** lần trước.

| | Lỗi #9 — organization | Giai đoạn 7 — 8 org config rule |
|---|---|---|
| Vì sao tainted | Bật service access lỗi *sau khi* org đã tạo xong | `create` gọi được, waiter hết 5 phút |
| Ở AWS thì sao | **Lành lặn** — org đủ dùng | **Hỏng dở** — kẹt `CREATE_IN_PROGRESS` vì chưa account nào có recorder |
| Cách đúng | `terraform untaint` | **Cứ để thay thế** |
| Untaint sai ở đâu | — | Chỉ giấu vấn đề: rule vẫn kẹt, và không bao giờ tự thoát |

Câu hỏi phải trả lời trước khi gõ lệnh không phải *"làm sao hết tainted"* mà là:

> **Resource đó ở phía AWS đang lành hay đang hỏng dở?**

`untaint` chỉ nói với Terraform *"tôi đã kiểm, nó ổn"*. Nếu chưa kiểm thì đó là nói dối, và cái giá là một resource hỏng nằm im trong state — Terraform không bao giờ đụng lại nữa vì nó tin bạn.

Cách kiểm: hỏi thẳng AWS, đừng hỏi Terraform.

```bash
aws organizations describe-organization                          # loi #9
aws configservice describe-organization-config-rule-statuses \
  --profile <security> --region <region>                         # giai doan 7
```

Với 8 rule kia, để Terraform thay thế lại là điều **mong muốn**: kèm `depends_on` mới, nó xoá rule đang kẹt, dựng recorder qua StackSet, rồi tạo lại rule khi đã có dữ liệu để đọc — đúng thứ tự lẽ ra phải có ngay từ đầu.

### 5e. Giai đoạn 7 — sáu lớp lỗi chồng lên một nguyên nhân

`config-detective` là layer khó nhất trong repo, và lý do không phải vì nó phức tạp. Nguyên nhân gốc bị **sáu lớp khác che**, và mỗi lớp báo lỗi trỏ sai hướng.

Nguyên nhân gốc, phát hiện ở lần apply đầu tiên:

```
NoAvailableDeliveryChannelException: Delivery channel is not available
to start configuration recorder
```

Nhưng phải gỡ hết năm lớp khác mới quay lại được chỗ đó.

| Lớp | Lỗi | Trỏ vào đâu | Thực ra là gì |
|---|---|---|---|
| 1 | `You must enable organizations access` | Organizations | CloudFormation có lời gọi kích hoạt riêng |
| 2 | `InsufficientDeliveryPolicyException` | Bucket policy | Sai condition key: `SourceOrgID` thay vì `SourceAccount` |
| 3 | `InsufficientDeliveryPolicyException` *(vẫn)* | Bucket policy | **Object Lock** — policy hoàn toàn đúng |
| 4 | `explicit deny ... p-2oni53yp` | SCP chặn kẻ xấu | SCP chặn chính CloudFormation rollback |
| 5 | `MaxNumberOfDeliveryChannelsExceededException` | Giới hạn AWS | Rác từ chính phép thử chẩn đoán |
| 6 | `NotStabilized` / `NoAvailableDeliveryChannel` | Thứ tự template | Vòng lặp thật giữa hai API |

**Lớp 3 tốn nhiều thời gian nhất**, vì tên exception nói dối. `InsufficientDeliveryPolicyException` dẫn thẳng tới bucket policy, và bucket policy không hề sai. Chỉ khi dựng hai bucket giống hệt nhau — cùng policy, cùng `BucketOwnerEnforced`, cùng account nguồn, khác **duy nhất** Object Lock — mới thấy: bucket không khoá thì Config ghi được `ConfigWritabilityCheckFile` ngay, bucket khoá thì không.

#### Vòng lặp không giải được bằng thứ tự

Lớp 6 là cái đáng học nhất về kỹ thuật. AWS CLI làm ba bước:

```
put-configuration-recorder  ->  put-delivery-channel  ->  start-configuration-recorder
```

CloudFormation gộp bước 1 và 3 vào `AWS::Config::ConfigurationRecorder`. Kết quả là hai API đòi nhau:

```
PutDeliveryChannel   -> NoAvailableConfigurationRecorderException
Start (CFN tu goi)   -> NoAvailableDeliveryChannelException
```

Cả hai chiều `DependsOn` đều chết. Đã thử cả hai.

Lời giải là **bỏ hẳn `DependsOn` giữa chúng** — để cả hai chỉ phụ thuộc `ConfigRole` và chạy song song:

```
recorder Put -> Start hong -> cho, thu lai
                                ^
channel Put thanh cong (recorder da ton tai) -> Start dat
```

Handler của recorder thử lại bước start trong lúc chờ ổn định, và đến lượt thử sau thì delivery channel đã có. Delivery channel chỉ cần recorder **tồn tại**, không cần nó **đang chạy**.

> Đó là lý do template mẫu của AWS không đặt `DependsOn` giữa hai resource này — nhìn như sơ suất cho tới khi vấp phải.

Kết quả cuối: 4/4 account `CURRENT`, 4/4 recorder `recording: true`, `lastStatus: SUCCESS`.

#### Phép thử sai vì tôi đọc nhầm một lỗi trước đó

Giữa chừng tôi kết luận "không có vòng lặp" dựa trên việc `put-delivery-channel` chạy được trong `lz-network`. Sai: `lz-network` **vẫn còn recorder** — lệnh xoá recorder trước đó đã bị SCP từ chối, mà tôi đọc như thể nó thành công.

Phép thử chỉ chứng minh "tạo được delivery channel khi *đã có* recorder" — đúng điều kiện mà account cần thử không thoả. Chạy lại trong `lz-logarchive`, account chưa từng có recorder, thì ra ngay `NoAvailableConfigurationRecorderException`.

> **Bài học:** một phép thử chỉ có giá trị khi điều kiện đầu vào đã được **xác nhận**, không phải giả định. Ở đây điều kiện là "account không có recorder", và nó sai vì một lệnh trước đó thất bại lặng lẽ.

#### SCP chặn nhầm công cụ của chính mình

Lớp 4 đáng ghi riêng. `baseline` chặn `config:DeleteConfigurationRecorder` — đúng ý đồ. Nhưng CloudFormation rollback cũng gọi đúng API đó, nên mọi lần triển khai hỏng để lại một stack `DELETE_FAILED` không ai dọn được.

**SCP chặn hành động, không phân biệt được ý định.** "Xoá recorder" khi kẻ tấn công làm và khi rollback làm là cùng một lời gọi API; chỉ danh tính người gọi mới phân biệt được. Nên mọi SCP bảo vệ hạ tầng đều cần một đường miễn trừ cho chính công cụ quản lý hạ tầng — và đường đó thành thứ phải canh giữ.

Role cần miễn trừ là `stacksets-exec-*`, **không** phải `AWSServiceRoleForCloudFormationStackSetsOrgMember` (cái sau là service-linked role phía quản trị). Tên thật luôn nằm trong `StatusReason` của stack instance, ở dòng `assumed-role/<ten>/...`.

#### Ba lần timeout, ba con số

| Resource | Mặc định | Thực tế | Đặt lại |
|---|---|---|---|
| `aws_config_organization_managed_rule` | 5 phút | > 30 phút | 90 phút |
| `aws_cloudformation_stack_set_instance` | 30 phút | ~29 phút với 4 account | 90 phút |

Với 6 account và 8 rule, cả 8 rule chạm mốc 30 phút **cùng lúc** — AWS triển khai từng rule xuống từng account, và 8 rule chạy song song nên chúng cùng chậm như nhau.

Vượt timeout **không phải thất bại** — AWS vẫn chạy tiếp. Nhưng Terraform đánh dấu tainted, và lần apply sau đòi thay thế một thứ đang hoạt động bình thường.

#### Cần gạt chi phí và phạm vi rule là hai biến ở hai file

Lỗi cuối cùng của giai đoạn, và là hệ quả trực tiếp của một quyết định **đúng**.

`recorder_target_ous` cố ý bỏ `Non-Production` — cần gạt chi phí số hai, vì dev là nơi resource đổi nhiều nhất. Nhưng organization rule đẩy xuống **mọi account thành viên, kể cả management**, bất kể biến đó:

| Account | Lỗi |
|---|---|
| `lz-app-dev` — ngoài `recorder_target_ous` | `NoAvailableConfigurationRecorder` |
| management — chưa từng bật Config | `UnableToAssumeServiceLinkedRoleException` |

Hai biến ràng buộc nhau mà không có gì trong code nối lại:

```hcl
recorder_target_ous = [...]   # account nao CO recorder
excluded_accounts   = []      # account nao KHONG bi ap rule
```

Và nó hỏng **chậm**: rule ngồi `CREATE_IN_PROGRESS` hàng chục phút rồi mới thành `CREATE_FAILED`, kéo cả lần apply theo — rồi lại không xoá được vì còn đang tạo.

Nay có `check` block bắt trường hợp management account (layer chạy ở đó nên `data.aws_caller_identity` biết ID). Các account khác không suy ra được nếu không phụ thuộc dữ liệu OU, nên thành quy tắc trong mô tả biến:

> Mọi account ACTIVE không nằm trong `recorder_target_ous` **phải** có mặt trong `excluded_accounts`. Luôn bao gồm management account.

**Kết quả cuối giai đoạn 7:** 26 resource, 4/4 recorder đang ghi, aggregator gom 2 region, 8 organization rule áp cho 4 account.

---

## 6. Sổ tay rút gọn

Nếu chỉ đọc một mục của file này, đọc mục này.

| Triệu chứng | Làm gì |
|---|---|
| `unrecognized service principal` | Rút `aws_service_access_principals` về tối thiểu, apply, thêm dần |
| `Backend initialization required` | Có `backend.tf` mà layer chưa apply → `rm backend.tf`, `init -reconfigure`, apply |
| `Unsetting the previously set backend` | Mất `backend.tf` → chạy `./wire-backends.sh`, nó tự dựng lại |
| `-backend-config was used without a "backend" block` | Như trên |
| `is tainted, so must be replaced` | **Hỏi trước: resource đó ở AWS lành hay hỏng dở?** Lành → `terraform untaint '<address>'`. Hỏng dở → cứ để thay thế. Xem mục 5d |
| `Instance cannot be destroyed` (không có "tainted") | `create_organization` bị đổi về `false` → đặt lại `true` |
| Plan ra số resource **ít bất thường** | Thường là taint: thứ phụ thuộc nó thành *known after apply* nên rơi khỏi plan |
| SCP apply xong không thấy tác dụng | `scp_dry_run = true` — đúng thiết kế |
| Phép thử SCP ra **cùng lỗi ở cả hai** account | Phép thử hỏng, không phải SCP hỏng — xem mục 5c |
| `AccessDenied` mà không nêu tên policy | Có thể là identity policy chứ không phải SCP. Thử lại bằng principal admin |
| Branch diverged sau `git pull` | Đã commit file môi trường? Nay không cần sửa file track nào nữa |

---

## 6b. Sau 24 giờ — số đo thật, và lỗ hổng đầu tiên bị bắt

Ba con số thay cho ba ước tính đã nằm trong file này từ đầu.

### Chi phí: thấp hơn ước tính một bậc

| Ngày | AWS Config |
|---|---|
| 20/8 — chưa bật | $0 |
| 21/8 — ngày dựng | **$0.292** |
| 22/8 — ổn định | $0 |

$0.292 là chi phí **một lần**: recorder khởi động và ghi một configuration item cho mọi resource đang tồn tại thuộc 13 loại, ở 4 account. Sau đó chỉ ghi khi có **thay đổi**.

Ước tính ban đầu là $2–10/tháng, và nó **sai một bậc**. Lý do: tôi tính theo *số resource* mà quên rằng `DAILY` chỉ phát sinh chi phí khi có thay đổi. Lab tĩnh thì gần như không có gì đổi.

> Con số này sẽ khác hẳn khi có workload thật — mỗi lần deploy sinh một loạt configuration item. Nhưng mức nền thì nay đã đo được, không còn phải đoán.

### Giao file: 4/4 SUCCESS

Cả bốn account `lastStatus: SUCCESS`, đã lên lịch lần giao kế tiếp. Đường ống recorder → delivery channel → S3 ở account log archive hoạt động đầy đủ.

### Một báo động sai của tôi, và trường đã giải thích nó

Danh sách S3 có `ConfigHistory` cho `AWS::Athena::WorkGroup`, `AWS::Cassandra::Keyspace`, `AWS::IoT::DomainConfiguration`, `AWS::Scheduler::ScheduleGroup` — **không loại nào nằm trong 13 loại đã khai**. Tôi kết luận ngay là cần gạt chi phí số bốn không hoạt động.

Sai. `describe-configuration-recorders` cho thấy cấu hình hoàn toàn đúng:

```json
"allSupported": false,
"recordingStrategy": { "useOnly": "INCLUSION_BY_RESOURCE_TYPES" },
"resourceTypes": [ ...dung 13 loai... ],
"recordingScope": "PAID"
```

Trường quyết định là **`recordingScope: PAID`**. AWS Config ghi một nhóm loại resource **miễn phí**, ngoài phạm vi tính tiền, bất kể `resourceTypes` khai gì. Chúng chiếm chỗ trong S3 nhưng không tính vào hoá đơn.

> Lại đúng cái lỗi suy luận của mục 5e: nhìn triệu chứng rồi kết luận, thay vì đọc cấu hình thật. Danh sách file trong S3 **không phải** nguồn đáng tin để suy ra phạm vi ghi — `describe-configuration-recorders` mới là.

### Lỗ hổng đầu tiên bị bắt: không có CloudTrail nào

| Rule | Kết quả |
|---|---|
| `iam-root-access-key-check` | COMPLIANT × 4 |
| **`cloud-trail-enabled`** | **NON_COMPLIANT × 4** |
| `s3-bucket-*` | COMPLIANT, chỉ ở account có bucket |

Đây không phải lỗi Config. Toàn bộ repo **không có một resource `aws_cloudtrail` nào**, trong khi:

- `baseline` SCP chặn `cloudtrail:StopLogging`, `DeleteTrail`, `UpdateTrail` — bảo vệ một thứ không tồn tại
- `aws_service_access_principals` đã bật `cloudtrail.amazonaws.com` cho org trail
- `lz-auditor` và `lz-security-operator` được cấp quyền đọc CloudTrail

Ba tầng chuẩn bị cho CloudTrail, không tầng nào tạo ra nó. **Không tài liệu thiết kế nào bắt được điều này** — phải có lớp phát hiện chạy thật mới lộ ra, và nó lộ ra trong ngày đầu tiên.

Đó chính là lý do lớp phát hiện tồn tại: SCP nói *ai được làm gì*, Config nói *thực tế đang thế nào*, và hai câu đó lệch nhau nhiều hơn người ta tưởng.

### Bốn rule vắng mặt — và vì sao đó không phải "đạt"

`encrypted-volumes`, `rds-storage-encrypted`, `vpc-sg-open-only-to-authorized-ports` và các rule S3 ở 3 account không xuất hiện trong bảng. Không có resource nào thuộc loại đó để đánh giá — không EBS, không RDS, và không security group vì default VPC đã bị xoá hết.

> **Vắng mặt ≠ tuân thủ.** Nó nghĩa là "không có gì để kiểm". Khi dựng workload thật, các rule đó sẽ hiện ra và có thể mang màu khác.

---

## 6c. Vòng khép kín — thứ đáng giá nhất của cả dự án

Lỗ hổng CloudTrail ở mục 6b được vá bằng layer [`org-trail`](../landing-zone/org-trail/). Điều đáng ghi không phải bản vá, mà là **cách nó được xác nhận**.

```
config-detective  →  "cloud-trail-enabled NON_COMPLIANT o 4 account"
                         │
                     dung org-trail
                         │
config-detective  →  "COMPLIANT o 4 account"
```

Không ai khẳng định trail chạy. Một hệ thống **độc lập**, dựng từ trước và không biết gì về layer mới, tự phát hiện chỗ thiếu rồi tự xác nhận chỗ vá.

Đó là khác biệt giữa *"tôi đã cấu hình đúng"* và *"có bằng chứng nó đúng"* — và cả hai mươi chín lỗi trong file này đều xoay quanh khoảng cách đó.

### Rule định kỳ không phản ứng với thay đổi

Sau khi trail chạy, aggregator vẫn báo `NON_COMPLIANT` ở cả 4 account. Không phải sai — chỉ là kết quả **cũ**.

| Loại rule | Đánh giá lại khi |
|---|---|
| Configuration change | Resource thay đổi — vài phút |
| **Periodic** | Theo lịch, mặc định **24 giờ** |

`CLOUD_TRAIL_ENABLED` thuộc loại thứ hai. Bạn vá xong, Config vẫn báo sai suốt cả ngày, và rất dễ tưởng bản vá không có tác dụng.

Ép chạy ngay, trong **account thành viên**:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names OrgConfigRule-<ten-rule>-<hash> \
  --profile <account> --region <region>

# hoi thang account do, khong qua aggregator - nhanh hon
aws configservice describe-compliance-by-config-rule \
  --config-rule-names OrgConfigRule-<ten-rule>-<hash> \
  --profile <account> --region <region> \
  --query 'ComplianceByConfigRules[0].Compliance.ComplianceType' --output text
```

`StartConfigRulesEvaluation` có giới hạn tốc độ — gọi lại quá sớm cho cùng một rule sẽ ra `LimitExceededException`. Đó là hạn chế, không phải lỗi.

> **Trộn hai loại rule trong một dashboard mà không biết loại nào là loại nào** thì mọi bản vá đều trông như không có tác dụng trong tối đa 24 giờ. Khi vận hành, luôn hỏi rule đang xem thuộc loại nào trước khi kết luận bản vá hỏng.

---

## 6d. Giai đoạn 9 — `account-baseline`, và bằng chứng rằng việc tay không đủ

Không dùng Control Tower thì không có **AFT**. Layer [`account-baseline`](../landing-zone/account-baseline/) làm phần việc đó: một StackSet `SERVICE_MANAGED` với `auto_deployment`, mỗi account một stack instance, bên trong là một Lambda tự quét các region trong `sweep_regions`.

Điểm mấu chốt không phải sáu account hiện có — dọn tay được. Là **account thứ bảy**: `auto_deployment` khiến account vừa vào OU tự được dọn, không phải chạy lại gì.

### Kết quả: năm default VPC chưa ai biết là còn

Mục 4 kết luận default VPC "đã xoá ở mọi account × mọi region". Lớp tự động trả lời khác:

```
lz-network       us-east-1/vpc-05d7cc1ef6007e805
lz-security      us-east-1/vpc-00ca7292432c5ff23
lz-logarchive    us-east-1/vpc-0b3933a8423ea26d6
lz-app-dev       us-east-1/vpc-09e5a7ecc087170f0
lz-app-prod      us-east-1/vpc-00e86d924d937405a
```

**Năm trên năm.** Lần dọn tay chỉ chạy ở `ap-southeast-1`, và không ai nhận ra vì `describe-vpcs` cũng chỉ được hỏi ở `ap-southeast-1`. Câu kiểm chứng dùng đúng cái giả định mà nó đáng ra phải kiểm.

Và đây **không phải** trường hợp `SKIP` vô hại:

| | |
|---|---|
| `us-east-1` có trong `allowed_regions` không? | **Có** — bắt buộc, `variables.tf` có validation ép phải có, vì service toàn cầu neo ở đó |
| Vậy `region_lock` có chặn `RunInstances` ở đó không? | **Không** |
| Nghĩa là | Năm account có sẵn đường ra Internet ở một region **được phép chạy EC2**, suốt cả tuần |

Nếu `us-east-1` nằm ngoài `allowed_regions` thì Lambda đã ghi `us-east-1/SKIP:ClientError` và đó mới là chuyện vô hại — không ai tạo được gì ở region bị khoá. Ở đây thì ngược lại.

### Lỗi 26 — treo một giờ, không phải "lỗi"

Ví dụ Lambda inline của AWS dùng `import cfnresponse`. Module đó có với một số runtime; với `python3.12` thì không.

Hỏng ở đây hỏng theo kiểu tệ nhất: Lambda chết ngay lúc **khởi tạo**, trước khi vào `try`, nên **không nhánh nào gửi được phản hồi**. Triệu chứng không phải thông báo lỗi mà là:

```
Still creating... [4m50s elapsed]
Still creating... [37m40s elapsed]
```

CloudFormation chờ **hết một giờ** rồi mới bỏ cuộc. Stack treo `CREATE_IN_PROGRESS`, các account còn lại xếp hàng `PENDING` phía sau, và stack hỏng rơi vào `DELETE_FAILED` — trạng thái chỉ gỡ được bằng:

```bash
aws cloudformation delete-stack --stack-name <ten> \
  --retain-resources <LogicalId>     # chi hop le khi dang DELETE_FAILED
```

Bản sửa: tự gửi phản hồi bằng `urllib`, không phụ thuộc module nào ngoài thư viện chuẩn. Dài thêm 12 dòng.

> **Quy tắc chung cho custom resource:** phải trả lời được CloudFormation **kể cả khi chính nó hỏng**. Cả nhánh `FAILED` cũng phải bọc `try` — không gửi được phản hồi thì triệu chứng là "treo một giờ", khó chẩn đoán hơn hẳn một dòng lỗi.

Thêm một điểm dễ quên: custom resource **chỉ chạy lại khi thuộc tính đổi**. Thêm region vào `sweep_regions` mà không đổi `sweep_version` thì không có gì xảy ra — và cũng không có gì báo.

### Lỗi 27 — lệnh kiểm chứng nói dối một cách êm ái

Sau khi apply xong, lệnh tôi tự viết trong README in ra **rỗng** ở cả năm account:

```bash
# SAI - in ra dong trong
--query 'Stacks[?...].Outputs[?OutputKey==`SweepResult`].OutputValue'

# DUNG
--query "Stacks[?...].Outputs[] | [?OutputKey=='SweepResult'].OutputValue"
```

Hai bộ lọc liên tiếp tạo một **projection lồng**. Với `--output json` nó hiện ra `[[{...}]]`; với `--output text` nó in một dòng trống — trông y hệt stack không có output nào.

Cái bẫy nằm ở chỗ **"rỗng" là câu trả lời hợp lý**: đã dọn tay rồi thì không tìm thấy gì là đúng. Suýt nữa thì ghi vào nhật ký rằng lớp mới chạy sạch và không phát hiện gì.

> **Bài học:** khi một lệnh kiểm chứng trả về đúng cái mình mong đợi, đó là lúc phải nghi ngờ **chính lệnh đó** nhất — chứ không phải lúc nó trả về thứ bất ngờ. Cách rẻ nhất: đổi sang `--output json` một lần. `[[...]]` là dấu hiệu của projection lồng.

### Kiểm độc lập

Không tin stack output — hỏi thẳng AWS:

```bash
for p in lz-network lz-security lz-logarchive lz-app-dev lz-app-prod; do
  printf '%-16s ' "$p"
  for r in ap-southeast-1 us-east-1; do
    printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r --profile $p \
      --filters Name=isDefault,Values=true --query 'length(Vpcs)' --output text)"
  done; echo
done
```

Kết quả thật:

```
lz-network       ap-southeast-1=0 us-east-1=0
lz-security      ap-southeast-1=0 us-east-1=0
lz-logarchive    ap-southeast-1=0 us-east-1=0
lz-app-dev       ap-southeast-1=0 us-east-1=0
lz-app-prod      ap-southeast-1=0 us-east-1=0
```

Mười ô, mười số `0`, hỏi thẳng EC2 chứ không đọc `SweepResult`. Đây là điểm khác biệt đáng giữ: `SweepResult` là **stack tự khai về chính nó**, còn bảng trên là AWS trả lời một câu hỏi không liên quan gì tới CloudFormation.

Lần này lặp **cả hai** region — đúng cái mà lần dọn tay không làm, và cũng đúng cái mà câu kiểm chứng của lần đó không làm.

---

## 6e. Lỗi 28 — ba thứ cùng nói "ổn", không ai nhận được gì

Chạy `./plan-all.sh` sau khi xong giai đoạn 9. Tám layer, bảy cái `khong doi`, một cái lệch:

```
config-detective     ok        ok        Plan: 1 to add, 0 to change, 0 to destroy
```

Một resource: `aws_sns_topic_subscription.email`. Địa chỉ có trong `terraform.tfvars`, nhưng lần apply cuối chạy trước khi thêm nó. Và vì `tfvars` nằm trong `.gitignore`, **không commit nào lộ ra sự lệch này** — chỉ `plan` mới thấy.

`terraform apply`. Thư xác nhận về hộp. Hỏi SNS:

```
quang.hong.0991@gmail.com    Deleted
```

### Ba lời khai đều sai

| Nguồn | Nói gì | Thực tế |
|---|---|---|
| `terraform apply` | `1 added` | Subscription không tồn tại |
| `terraform plan` | `No changes` | State giữ một ARN đã chết |
| `aws sns publish` | `MessageId: a8872013-...` | Không có subscriber nào |

`sns publish` là cái độc nhất: nó **luôn** trả `MessageId` miễn topic tồn tại. Lệnh báo OK, số hiệu thư có thật, thư rơi vào hư không.

Nặng hơn lỗi 23 (user SSO không có thư mời): ở đó ít nhất **không có gì tuyên bố thành công**. Ở đây có ba thứ cùng khẳng định đường cảnh báo bảo mật của cả tổ chức đang chạy.

### Bốn giả thuyết, bốn lần sai

Đây mới là phần đáng ghi.

| # | Tôi nói | Bằng chứng bác bỏ |
|---|---|---|
| 1 | `assume-role` hỏng vì credential là **root user** | `get-caller-identity` → IAM user có quyền admin, và lời gọi đó chạy rời thì thành công |
| 2 | Subscription hết hạn sau **3 ngày** | Thư xác nhận về **vài phút** trước khi listing báo `Deleted`, không phải vài ngày |
| 3 | Provider lưu ID là chuỗi `pending confirmation` | Log apply cho thấy state giữ **ARN thật kết thúc bằng UUID** |
| 4 | Địa chỉ bị chặn — *(đúng, nhưng đo sai)* | Tôi đọc phép thử khi bản ghi cũ vẫn còn trong bảng, nên không phân biệt được "bị chặn" với "bản ghi chưa dọn" |

Mỗi lần tôi lại nói chắc hơn mức bằng chứng cho phép. Giả thuyết 4 **về sau hoá ra đúng** — nhưng lúc phát biểu thì nó chưa được chứng minh, và "đoán trúng" không phải là "đo được".

### Cái giải được nó

Phép thử hai nhánh, giống hệt nhau, khác đúng một biến — cùng khuôn đã dùng cho lỗi 19 (hai bucket y hệt để chứng minh Object Lock chặn Config):

```bash
aws sns subscribe --topic-arn <cung mot topic> --protocol email \
  --notification-endpoint quang.hong.0991+lztest@gmail.com ...
```

```
quang.hong.0991@gmail.com          Deleted                 <- chan
quang.hong.0991+lztest@gmail.com   PendingConfirmation     <- binh thuong
```

Cùng topic, cùng account, cùng phút. Một bảng loại trừ đồng thời cả ba thứ mà bốn lượt suy luận không loại được: **không phải Terraform** (subscribe trực tiếp), **không phải bản ghi cũ** (đã dọn sạch trước), **không phải topic hay account** (dòng thứ hai đứng ngay cạnh).

### Hai điều phép thử dạy thêm

**Chặn theo topic, không theo địa chỉ.** Cùng địa chỉ đó vẫn đăng ký bình thường vào topic khác, kể cả account khác. Chính điều này làm giả thuyết trông vô lý suốt mấy lượt — *"email này tôi dùng đăng ký khá nhiều SNS topic ở các account"* nghe như bằng chứng loại trừ, mà không phải.

**Thứ tự quyết định phép thử đọc được hay không.** `Subscribe` cho endpoint còn bản ghi cũ sẽ **khớp vào bản ghi cũ** thay vì tạo mới — đó là lý do `-replace` trả về **đúng UUID cũ** và không gửi thư nào. Phải `unsubscribe`, chờ dòng đó **biến mất khỏi bảng** (không phải chờ tới khi nó ghi `Deleted`), rồi mới thử.

### Kết cục

Đổi `alert_emails` sang một địa chỉ khác:

```
quangchutcb@gmail.com   arn:aws:sns:ap-southeast-1:458195083898:quh11-lz-security-findings:1a0f73d2-ec42-4784-9715-0d1e8c1f8929
```

ARN thật, kết thúc bằng UUID. Không có API gỡ chặn cho email — địa chỉ cũ phải qua AWS Support mới lấy lại được ở topic này.

> **Terraform không thể tự bắt lỗi này.** Nó không có data source đọc subscription của SNS, nên không `lifecycle` hay `check` block nào cứu được. Đây không phải drift mà `plan` phát hiện được — là drift mà `plan` **khẳng định là không có**. Lưới duy nhất là layer tự nhắc người vận hành đi hỏi thẳng SNS, và đó là thứ đã thêm vào `README`, `notify.tf`, `next_steps`.

> **Bài học rộng hơn cả SNS:** mọi đường cảnh báo đều phải kiểm bằng cách **hỏi đầu nhận**, không phải hỏi đầu gửi. `plan` sạch, `apply` xanh, `publish` trả `MessageId` — cả ba đều là đầu gửi.

---

## 6f. Giai đoạn 10 — `network`, và lỗi do chính bản vá an toàn gây ra

> **Mục này khác mọi mục trên: `network` MỚI CÓ CODE, CHƯA AI APPLY.** Đo được ở đây chỉ có `terraform plan`. Đừng đọc nó như bảy giai đoạn kia — chúng có số đo thật từ AWS, mục này thì chưa.

Layer [`network`](../landing-zone/network/) làm giai đoạn 1 của [doc 17](./17-Network-LZ-Design-Guide.md): TGW + security VPC + Network Firewall + egress VPC, chia sẻ TGW cho cả tổ chức qua RAM. Chưa có ingress VPC (Palo Alto và F5 cần license Marketplace), chưa có 3rd-party VPC, chưa có Route 53 Profile.

### Layer đầu tiên phá vỡ mẫu "~$0/ngày"

| Layer | Chi phí |
|---|---|
| Bảy layer trước | ~$0/ngày |
| `network`, 2 AZ | **~$770/tháng** |

Trong đó **$570 là Network Firewall endpoint** — $0.395/giờ **mỗi AZ**, chạy 24/7 dù có gói tin nào đi qua hay không. Đây là quyết định khác hẳn `enable = true` ở mọi layer trước, nên README của layer mở đầu bằng bảng chi phí chứ không phải bằng kiến trúc.

### Lỗi 29 — bản vá an toàn tự tạo ra lỗ hổng của nó

Soát tay trước khi commit, tôi tìm ra một chỗ: `[0].id` trên resource `count = 0` là *Invalid index*, **kể cả ở nhánh không được chọn**. Sửa thành `one(...[*].id)` cho an toàn.

`one()` trả về `null` khi `count = 0`. Với một phép gán thì null vô hại. Trong string template thì:

```
Error: Invalid template interpolation value
  aws_ec2_transit_gateway.hub is empty tuple
  The expression result is null. Cannot include a null value in a string template.
```

Bốn lần, trong hai output sinh HCL. Và nó hỏng ở **`enable = false`** — trạng thái mặc định, thứ ai cũng gặp đầu tiên, trước cả khi đọc tới TGW hay firewall.

Ba điều đáng ghi, và không điều nào nói về Terraform:

| | |
|---|---|
| **Bản vá tạo ra lỗi** | Thay đổi duy nhất tôi làm *để giảm rủi ro* là thay đổi duy nhất gây lỗi. `one()` đúng cho phép gán, sai cho template — tôi áp dụng nó ở cả hai chỗ mà không phân biệt |
| **Hỏng ở trạng thái mặc định** | Không phải góc khuất nào. `terraform plan` với cấu hình xuất xưởng là hỏng |
| **`fmt` sạch và soát tay kỹ đều không bắt được** | Tôi vừa soát ra ba lỗi khác nên thấy yên tâm. `fmt` chỉ kiểm định dạng, và mắt người không lần được `null` chảy vào đâu. `plan` thật bắt trong một giây |

Bản sửa cho cả hai giá trị đi qua `coalesce()` với một chuỗi giữ chỗ đọc được, nên khối HCL sinh ra vẫn in được trước khi hub tồn tại.

> **Vì sao tôi không tự bắt được:** layer này viết trong môi trường có chính sách mạng chặn `registry.terraform.io`, nên `terraform init` và `validate` không chạy được ở đó. Tôi nói rõ điều đó khi bàn giao — nhưng nói rõ giới hạn không làm giới hạn biến mất. **Một layer chưa ai chạy vẫn là một layer chưa ai tin được**, kể cả khi người viết đã cảnh báo trước.

### Ba quyết định thiết kế, và lý do

**Spoke VPC cố ý không nằm trong layer.** Provider không sinh động được bằng `for_each` — sáu account là sáu alias viết tay, account thứ bảy là sửa code. Nên layer sở hữu TGW, share qua RAM, và **nối** attachment do account workload tạo. Bước nối bắt buộc ở đây: chỉ chủ sở hữu TGW mới `associate`/`propagate` được.

Bỏ bước nối = attachment `State: available` và không thuộc route table nào. Không lỗi, không cảnh báo, không một gói tin nào đi qua — **đúng họ với lỗi 28**: mọi thứ báo ổn, không ai nhận được gì.

**Route table theo từng AZ**, khác bản demo một-AZ. Gói vào subnet `tgw` của AZ-a phải tới firewall endpoint của chính AZ-a. `sync_states` là một **set không có thứ tự**, nên code lập map `AZ → endpoint` chứ không lấy theo chỉ số.

**`appliance_mode_support` chỉ lộ ra từ 2 AZ trở lên.** Với một AZ nó không bao giờ sai. Nên bản một-AZ — thứ tôi khuyên dùng để thử code cho rẻ — **không kết luận được là cấu hình đúng**. Đó là một giới hạn của phép thử, phải biết trước khi tin nó.

---

## 7. Việc còn lại sau lần dựng này

Đã đi hết cả chín giai đoạn của runbook.

| # | Việc | Trạng thái |
|---|---|---|
| 1 | 6 account + chuyển vào đúng OU | **Xong** — `list-parents` xác nhận cả 5 account thành viên đúng OU |
| 2 | 4 SCP | **Xong** — kiểm chứng 4/4, kể cả `prod_guard` |
| 3 | Xoá default VPC mọi account × mọi region | **Xong** — làm tay sót `us-east-1` ở cả 5 account, `account-baseline` dọn nốt. Xem mục 6d |
| 4 | Identity Center | **Xong** — `ssoins-8210168ac3d88c11`, identity store `d-9667ae9e62`, `ap-southeast-1` |
| 5 | `permission-sets` | **Xong** — 115 resource, xem mục 5b |
| 6 | `billing-guard` | **Xong** — budget, SNS đã xác nhận, anomaly. Còn `enable_cost_allocation_tags` khi có resource mang tag |
| 7 | `config-detective` | **Xong** — $0.29 một lần, ~$0/ngày ổn định. Xem mục 6b |
| 8 | **Layer `org-trail`** | **Xong** — 8 resource, và `cloud-trail-enabled` đã chuyển sang COMPLIANT ×4. Xem mục 6c |
| 9 | **Layer `account-baseline`** | **Xong** — 5/5 stack instance CURRENT, xoá 5 default VPC lần dọn tay bỏ sót. Xem mục 6d |
| 10 | **Layer `network`** | **Mới có code** — `plan` sạch ở `enable = false`, **chưa ai apply**. Xem mục 6f |

Còn lại, không thuộc giai đoạn nào của runbook:

| Việc | Vì sao |
|---|---|
| `enable_cost_allocation_tags` ở `billing-guard` | Chỉ có nghĩa khi đã có resource mang tag |
| Xem lại pham vi `lz-db-admin` / `lz-server-admin` | Hai set này để `all`, tức có quyền ghi vào production, trong khi `lz-app-admin` chỉ nonprod. Không nhất quán — hoặc là cố ý và cần ghi rõ, hoặc là sót |
| Layer `control-tower` | **Chưa ai chạy bao giờ.** Mặc định tắt, không ảnh hưởng gì — nhưng một lớp chưa ai chạy là một lớp chưa ai tin được, đúng như lỗi 26 vừa chứng minh với code viết cùng ngày |
| Layer `network` | Có code, `plan` sạch, **chưa apply**. Và bật nó là ~$770/tháng — không phải việc "làm nốt cho đủ bộ" mà là quyết định có workload thật hay không. Xem mục 6f |

### Vì sao `org-trail` là việc tiếp theo

Lớp phát hiện bắt được ngay ngày đầu: **không có CloudTrail nào trong tổ chức**. Ba tầng đã chuẩn bị sẵn cho nó mà không tầng nào tạo ra nó — `baseline` SCP chặn `cloudtrail:StopLogging`, `aws_service_access_principals` đã bật `cloudtrail.amazonaws.com`, `lz-auditor` được cấp quyền đọc. Chi tiết ở mục 6b.

Không có trail thì không có bản ghi ai làm gì, `lz-auditor` không có gì để đọc, và điều tra sự cố không có nguồn dữ liệu.

Một **organization trail** tạo ở management account phủ mọi account hiện tại và tương lai, ghi vào cùng bucket account log archive. Management event lần đầu miễn phí; chỉ trả tiền lưu trữ S3.

### Vì sao `account-baseline` là việc sau đó

Việc 1 và việc 3 lúc đó đã làm **bằng tay**, và cả hai đều sẽ phải làm lại nguyên vẹn cho account thứ bảy:

| Việc tay | Quên thì hậu quả |
|---|---|
| `move-account` vào OU | Account chỉ còn SCP ở root — mất `network_lock` và `prod_guard` |
| Xoá default VPC ở mọi region | Một Internet Gateway mở sẵn, `network_lock` không đụng tới được |
| Thêm account ID vào `accounts_by_scope` | Không ai vào được account đó qua Identity Center |

Ba việc, không việc nào báo lỗi khi quên. Account vẫn chạy, chỉ là không có guardrail — đúng loại sai lệch lặng lẽ mà một landing zone sinh ra để ngăn.

Đó là lý do [doc 09](./09-Account-Vending-Tu-Dong.md) gọi đây là **account vending** và giao cho tự động hoá.

> Viết đoạn trên xong thì dựng luôn layer đó, và nó lập tức chứng minh lập luận mạnh hơn cả dự tính: không phải account thứ bảy mới thiếu guardrail — **sáu account hiện có đã thiếu sẵn rồi**, chỉ là không ai hỏi đúng region. Chi tiết ở mục 6d.

### Lệnh kiểm lại toàn bộ

Chạy từ management account. Ba câu hỏi: account nào sai OU, region nào còn default VPC, đường cảnh báo có thông không.

```bash
ORG_REGIONS="ap-southeast-1 us-east-1"

for id in $(aws organizations list-accounts \
              --query 'Accounts[?Status==`ACTIVE`].Id' --output text); do
  name=$(aws organizations describe-account --account-id "$id" \
           --query 'Account.Name' --output text)
  parent=$(aws organizations list-parents --child-id "$id" \
             --query 'Parents[0].[Type,Id]' --output text)
  printf '%-14s %-16s %s\n' "$id" "$name" "$parent"

  [ "$id" = "$(aws sts get-caller-identity --query Account --output text)" ] \
    && continue

  # KHONG nuot stderr - xem phan duoi vi sao
  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::$id:role/OrganizationAccountAccessRole" \
    --role-session-name vpc-audit \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text) || { echo "    ^ khong assume duoc, xem loi ngay tren"; continue; }

  read -r AK SK ST <<<"$creds"
  for r in $ORG_REGIONS; do
    n=$(AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
        aws ec2 describe-vpcs --region "$r" --filters Name=isDefault,Values=true \
          --query 'length(Vpcs)' --output text)
    [ "$n" != "0" ] && echo "    $r: CON $n default VPC"
  done
done
```

Không in dòng `CON ... default VPC` nào, và cột cuối không có `ROOT` nào ngoài management account, là sạch.

> **Đừng dán comment `#` vào zsh.** macOS mặc định dùng zsh, và zsh **tương tác** không bật `interactive_comments` — mọi dòng `#` trong khối dán vào sẽ thành `zsh: command not found: #`. Vô hại nhưng ồn. `setopt interactive_comments` một lần là hết.

> **Bản đầu của đoạn script trên có `2>/dev/null` ở cả hai lời gọi**, và khi `assume-role` hỏng nó chỉ in `(khong assume duoc)` — không nói vì sao. Đúng cùng một lỗi với #27: che mất câu trả lời rồi để người đọc tự đoán.
>
> Lần dựng này nó hỏng ở cả 5 account. Tôi đoán là do credential mặc định là root user — **đoán sai**: `get-caller-identity` cho ra một IAM user có quyền admin, và cùng lời gọi `assume-role` đó chạy rời thì thành công. Nguyên nhân thật vẫn chưa biết, vì thông báo lỗi đã bị `2>/dev/null` nuốt mất trước khi ai kịp đọc.
>
> Ghi lại đúng như vậy, không viết một nguyên nhân nghe hợp lý vào chỗ trống. Bài học nằm ở chính chỗ đó: **script nuốt stderr thì lỗi không biến mất, nó chỉ chuyển thành phỏng đoán** — và phỏng đoán đầu tiên của tôi đã sai.

> **Vòng lặp này không phải thứ bắt buộc.** Nếu đã có profile cho từng account thì bản dưới đây trả lời cùng câu hỏi với ít chỗ hỏng hơn hẳn — nó không cần `assume-role`, không cần env var tạm, không cần role nào tồn tại.

### Bản không cần assume-role

Nếu đã có profile cho từng account thì bỏ hẳn `assume-role` đi — ít chỗ hỏng hơn, và đây mới là kiểm chứng thật của mục 6d: `SweepResult` là stack tự khai về chính nó, còn cái này hỏi thẳng EC2.

```bash
for p in lz-network lz-security lz-logarchive lz-app-dev lz-app-prod; do
  printf '%-16s ' "$p"
  for r in ap-southeast-1 us-east-1; do
    printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r --profile $p \
      --filters Name=isDefault,Values=true --query 'length(Vpcs)' --output text)"
  done; echo
done
```

### Cái bẫy của việc 1

`aws organizations create-account` **không nhận tham số OU**. Account mới luôn nằm ở root, phải `move-account` thủ công. SCP thì gắn vào OU — nên một account quên chuyển là account **không có guardrail nào ngoài hai SCP gắn ở root**.

Nguy nhất là `lz-app-prod`: `prod_guard` gắn vào OU `Production`, account còn ở root thì SCP đó không chạm tới nó.

```bash
for id in $(aws organizations list-accounts --query 'Accounts[].Id' --output text); do
  printf '%-14s %-16s %s\n' "$id" \
    "$(aws organizations describe-account --account-id $id --query 'Account.Name' --output text)" \
    "$(aws organizations list-parents --child-id $id --query 'Parents[0].[Type,Id]' --output text)"
done
```

`ROOT` ở cột cuối = chưa chuyển.

---

## 7. Vòng xoá–dựng lại

Lần dựng đầu chứng minh code **dựng được**. Nó không chứng minh được code **gỡ được** — và đó là hai việc khác nhau, vì lớp bảo vệ chỉ lộ ra khi bạn đi ngược chiều.

### 7a. Số đo

| Layer | Xoá | Thời gian đáng chú ý | Dựng lại |
|---|---|---|---|
| `config-detective` | 25 | StackSet instance **1m33s**; 8 org rule 1m20s–1m46s | 25 |
| `account-baseline` | 2 | StackSet instance **2m5s** trên 6 OU | 2 |
| `org-trail` | 8 | Bucket **26 giây** | 8 |
| `billing-guard` | 5 | tức thì | **9** |
| `permission-sets` | 118 | ~2 phút | 118 |
| | **158** | | **162** |

Chênh 4 vì lần dựng lại bật thêm cost allocation tag — xem 7e.

### 7b. Hai cổng khoá, và bằng chứng chúng khác nhau thật

Hạ tầng thường trực có hai lớp chặn, khoá ở hai nơi:

| | `prevent_destroy` | `allow_destroy` |
|---|---|---|
| Khoá ở | Terraform, trong `lifecycle` | AWS, trên chính resource |
| Gọi API khi gỡ | **Không** | **Có** (firewall) |
| Cần `apply` xen giữa | Không | **Bắt buộc** |

Terraform **không cho** dùng biến trong `lifecycle`, nên lớp thứ nhất không thể thành một cờ — phải sửa file. Đó là lý do có `unlock-destroy.sh`: nó đổi `true` ↔ `false` trên 11 chỗ / 6 layer, và vì đổi giá trị chứ không xoá dòng nên `git diff` về **rỗng đúng từng byte** sau khi khoá lại.

Bằng chứng rõ nhất rằng cổng thứ hai làm việc thật nằm ở hai con số cạnh nhau:

```
aws_s3_bucket.config[0]:  Destruction complete after 3s      <- bucket rong
aws_s3_bucket.trail[0]:   Destruction complete after 26s     <- force_destroy quet version that
```

Cùng một kiểu resource, cùng bật versioning. 3 giây là bucket không có gì; 26 giây là `force_destroy` duyệt và xoá từng version cùng delete marker của log CloudTrail. Không có nó thì `destroy` dừng ở `BucketNotEmpty` — vì `aws s3 rm --recursive` chỉ tạo delete marker.

### 7c. Hai cảnh báo tôi đưa ra, cả hai đều sai

**"Bước dễ kẹt nhất là `config-detective`, phải miễn trừ role StackSet trước."** Tôi nói điều này hai lần. Nó chạy thẳng, không vướng gì. Lý do: đường miễn trừ `stacksets-exec-*` **đã nằm sẵn trong `scp_exempt_role_names`** từ lúc sửa lỗi 20, năm ngày trước. Cảnh báo đúng về nguyên tắc, thừa với org này — và tôi đã không kiểm `scp_summary` trước khi nói.

**"Vòng thử `--unlock`/`--lock` đã kiểm chứng, đảo ngược chính xác."** Vòng thử đó chạy trên Linux, nơi GNU `sed` chấp nhận `sed -i -E`. Máy người dùng là macOS. Xem lỗi 30 và 31 — tôi báo là đã kiểm chứng một thứ mà phép kiểm không phủ tới nền tảng đang dùng.

> Cả hai đều cùng một dạng: **suy luận từ thứ mình biết thay vì hỏi hệ thống**. Đúng cái mục 2.5 đã viết ra, rồi lại ngã vào.

### 7d. Ba thứ nhanh hơn lần đầu, và vì sao

| | Lần đầu | Lần dựng lại |
|---|---|---|
| 8 Config rule | Cả 8 chạm mốc timeout 30 phút, Terraform đánh dấu tainted | Xong trong giới hạn, không tainted |
| Cost allocation tag | — | `Active` **ngay lập tức** |
| CloudTrail giao file đầu | ~15 phút (ước tính) | `LatestDeliveryTime` có ngay sau apply |

Cái đầu là do bản sửa nâng timeout lên 90 phút đã ăn. Cái thứ hai đáng ghi vì `next_steps` nói *"chờ ~24 giờ"* — câu đó vẫn đúng nhưng cho **việc khác**: kích hoạt tag key có hiệu lực ngay, còn 24 giờ là để dữ liệu chi phí **nhóm theo tag** xuất hiện trong báo cáo. Hai chuyện.

### 7e. Cost allocation tag — chỗ duy nhất "muộn" tệ hơn "chưa hoàn hảo"

`enable_cost_allocation_tags` đang là `false` trong tfvars, đúng theo mô tả biến: *"tag chỉ bật được SAU KHI đã có ít nhất một resource mang tag đó"*. Lần dựng đầu chưa có gì mang chúng.

Nhưng cost allocation tag **không hồi tố**. Mỗi ngày để tắt là một ngày dữ liệu hoá đơn vĩnh viễn không chia được theo team. Và lúc dựng lại thì đã có 118 permission set + 5 SCP mang đủ 4 tag key.

Bật, apply, và cả 4 ra `Active` ngay. Câu hỏi bỏ ngỏ trước đó — *"AWS có tính tag trên resource không tính tiền không?"* — được trả lời bằng chính phép thử: **có**.

### 7f. Account không xoá được, nên đừng xoá

Điều đáng nhớ nhất của cả vòng này không phải kỹ thuật. Account AWS **chỉ đóng được**, sau đó nằm lại tổ chức 90 ngày, và email cháy vĩnh viễn trên toàn AWS.

Nên `organization` có thêm OU `Suspended` với đúng một SCP `Deny *`, cùng `park-account.sh` để chuyển account vào ra. Ba chi tiết học được khi viết nó:

- **OU không có SCP nguy hơn không có OU.** Lệnh chạy trót lọt, báo thành công, account vẫn chạy bình thường trong một OU tên `Suspended`. Script vì vậy đọc nội dung policy thật gắn trên OU và từ chối move nếu không thấy `Deny *`.
- **Ghi tag trước khi move, không phải sau.** OU cũ lưu vào `lz:parked-from`; ghi tag hỏng thì dừng, chưa move gì cả.
- **`Deny *` chặn hành động, không chặn hoá đơn.** Tài nguyên còn chạy vẫn tính tiền, và không xoá được cho tới khi `--restore`. Dọn sạch trước, park sau.

### 7g. Ba nguồn phải cùng nói một điều

Bước kiểm cuối của `account-baseline` hỏi ba nơi khác nhau về cùng một sự thật:

```
StackSet  ->  5/5 CURRENT                      (da toi noi chua)
Lambda    ->  "khong co default VPC nao" ×5    (no BAO cao xoa gi)
AWS       ->  0 / 0 ×5 accounts × 2 regions    (thuc te con gi)
```

Lệnh thứ ba là lệnh duy nhất không tin lời ai — và nó xác nhận lỗ hổng `us-east-1` ở mục 6d đã đóng. Vòng lặp **một** region chính là thứ đã tạo ra lỗ hổng đó: lần dọn tay chỉ chạy ở một region, và câu kiểm chứng cũng chỉ hỏi region đó.

### 7h. Lỗi 33 — nguồn của đường cảnh báo nằm ngoài code

Câu hỏi khởi đầu vô hại: *"guardrail của Control Tower có port sang DIY được không?"* Trả lời nó buộc phải đọc lại `notify.tf`, và ở đó có một dòng:

```hcl
event_pattern = jsonencode({
  source        = ["aws.securityhub"]
  ...
})
```

**Không layer nào tạo hay quản Security Hub.** `grep -r aws_securityhub --include=*.tf` ra rỗng.

Nghĩa là toàn bộ đường cảnh báo — EventBridge rule, SNS topic, subscription — treo trên một dịch vụ mà Terraform không biết là có tồn tại.

#### Tôi đã ghi lỗi này nặng hơn thực tế, và đây là bản sửa

Bản đầu của mục này viết rằng *"không sự kiện nào từng đi qua"*, và dựng nó thành **lỗi thứ hai trên cùng đường ống mà lỗi 28 che đi**. Cả hai đều sai.

Sự thật: Security Hub **đang chạy và có dữ liệu đổ về**. Nó được bật ở giai đoạn 7 bằng ba lệnh tay mà chính RUNBOOK ghi ra (commit `a48f8a6`), và destroy `config-detective` không tắt nó — Security Hub không nằm trong layer đó.

Tôi suy từ *"repo không bật nó"* sang *"nên nó chưa bao giờ chạy"*. Bước suy luận đó bỏ qua mất phần thủ công của chính runbook mình viết. Kiểm bằng một lệnh là ra:

```bash
aws securityhub describe-hub --profile lz-security --region ap-southeast-1
```

> **Cùng một sai lầm với lỗi 28, chỉ đổi hướng.** Lỗi 28 tôi tin `terraform plan` và không hỏi SNS. Lần này tôi tin `grep` và không hỏi Security Hub. Cả hai lần đều suy ra trạng thái vận hành từ thứ nằm trong repo — mà repo chỉ là một nửa câu chuyện, nửa kia là những bước tay runbook bảo người ta làm.

#### Vậy lỗi thật là gì

Không phải "đường cảnh báo chết". Là **một phụ thuộc không được quản lý**:

| | |
|---|---|
| Rủi ro thật | Ai đó tắt Security Hub, hoặc dựng LZ này ở tổ chức mới mà bỏ qua bước tay — đường cảnh báo im lặng, không gì báo |
| `terraform plan` thấy gì | Không gì cả. Nó không biết dịch vụ đó tồn tại |
| Vì sao vẫn là lỗi thiết kế | Một đường cảnh báo mà nguồn nằm ngoài code là đường cảnh báo không ai kiểm được bằng code |

`securityhub.tf` đưa nguồn đó vào Terraform để `plan` nhìn thấy nó. Và `check "alerts_have_a_source"` **không** khẳng định đường ống chết — nó nói rằng nguồn không do layer này quản, rồi đưa ra lệnh để hỏi thẳng dịch vụ.

Bản sửa thêm `securityhub.tf` và một `check` bắt đúng trạng thái này lúc `plan`:

```
alert_emails da khai nhung enable_security_hub = false.
notify.tf khop event theo source = aws.securityhub, nen KHONG CO
su kien nao toi rule EventBridge va khong ai nhan duoc gi -
du SNS co subscriber da xac nhan.
```

Cùng file đó cũng đưa **lỗi 14 vào code**: `aws_securityhub_organization_admin_account` là lệnh chỉ định riêng của Security Hub, và đăng ký `securityhub.amazonaws.com` ở tầng Organizations là chưa đủ — thiếu nó thì mọi lệnh gọi từ security account báo `InvalidAccessException: The account is not an administrator`, một thông báo không nhắc gì tới Organizations.

#### Đóng lại — import chứ không apply thẳng

Security Hub đang chạy thật, nên không thể apply `securityhub.tf` như dựng mới. Trình tự đã dùng:

| Bước | Kết quả |
|---|---|
| Hỏi thẳng dịch vụ, cả hai account | Ba resource đã tồn tại, hai chưa |
| `terraform plan` sau khi pull `1f94d2d` | `5 to add` — `fsbp` biến mất, `auto_enable_standards = "NONE"`, khớp live |
| Import 3 resource | — |
| `terraform plan` | **`2 to add, 0 to change`** |
| `terraform apply` | management `hub/default` + finding aggregator |

`0 to change` là con số đáng giá nhất ở bảng trên: nó nói code và trạng thái thật khớp **từng trường**, chứ không phải "apply chạy được".

Ba điểm chỉ lộ ra khi làm thật:

- **Thứ tự import có ý nghĩa.** Uỷ quyền phải vào state trước, vì hai resource sau dùng provider `aws.security` và chỉ đọc được khi account đó đang là delegated admin.
- **zsh coi `[0]` là glob.** `terraform import aws_securityhub_account.security[0]` trên macOS ra `zsh: no matches found`. Phải quote địa chỉ.
- **`-var` là cái bẫy đặt sẵn.** Ba resource nằm sau `count`. Lần nào ai đó `terraform apply` thiếu `-var enable_security_hub=true`, `count` tụt 1→0 và Terraform **destroy** cả ba — `DisableSecurityHub`, gỡ uỷ quyền, đường cảnh báo mất nguồn. Giá trị phải nằm trong `terraform.tfvars`, không phải trên dòng lệnh.

RUNBOOK giai đoạn 7 mục (2) đã thay ba lệnh CLI bằng một biến, và giữ ba lệnh cũ lại **chỉ** làm đường import cho tổ chức đã bật tay.

> Lỗi 33 đóng ở đây theo đúng nghĩa của nó: không phải "đường cảnh báo đã sống" — nó vẫn sống từ đầu — mà là **nguồn của nó giờ nằm trong code**. Ai tắt Security Hub thì `plan` sẽ nói, thay vì `notify.tf` lặng lẽ chờ một event không bao giờ tới.

### 7i. Lỗi 34 — `scope = "all"` nghĩa là *tất cả*, kể cả nơi giữ bằng chứng

Câu hỏi của người dùng: *"sao account `lz-security` lại nhận nhiều permission set đến vậy?"*

Đếm ra 10. Nguyên nhân: **10/17 permission set khai `scope = "all"`**, và `all` không phải một danh sách viết tay — nó suy ra từ Organizations:

```hcl
all_accounts = [for id in local.active_accounts : id if id != var.management_account_id]
```

Không có khái niệm "chỉ account workload". `all` là *tất cả*, kể cả hai account giữ tài sản nhạy cảm nhất.

Đó mới là câu hỏi. Câu trả lời tệ hơn nhiều.

`lz-server-admin` cũng ở `scope = "all"`. Quyền của nó sinh từ `admin_actions["compute"]`, và `svc_compute` chứa `"s3"` — nên nó có **`s3:*`**. Còn `all` gồm cả `lz-logarchive`.

Kiểm các deny của set đó: `DenyEc2NetworkApis`, `DenyEc2SecurityGroupRuleChanges`, `DenyIamWritesOutsideSecurityDomain`, `DenyTamperingWithGuardrails`. Cái cuối chặn `cloudtrail:DeleteTrail`, `config:DeleteConfigurationRecorder`… **không chặn `s3:DeleteObject`**.

> **Kết quả: cả đội hạ tầng compute xoá được bucket CloudTrail và bucket Config snapshot của cả tổ chức.**

Điều làm nó đáng ghi riêng: **hai tin nhắn trước đó tôi vừa bảo vệ chính lớp bảo mật này.** Người dùng hỏi vì sao log phải ghi vào account log archive riêng, tôi trả lời rằng nó mua được tính chất *"account phát hiện được không phải account xoá được"*, và lập luận dựa trên việc `lz-security-admin` phải đi vòng qua `iam:*`.

Lập luận đúng về ranh giới account, và **thiếu hẳn tầng permission set đâm xuyên qua nó** — không cần vòng vèo, `s3:*` là cấp thẳng. Tôi đã đọc kỹ SCP và IAM policy của một account, rồi quên hỏi *ai được gán vào account đó*.

**Bản sửa dùng hai lớp, vì một lớp là một lần sửa nhầm:**

| Lớp | Làm gì |
|---|---|
| **Phạm vi** | Tách `all` thành `all` / `security` / `network` / `workloads`. `workloads` = mọi account **trừ** ba account hạ tầng lõi, khai trong `core_accounts` |
| **Deny cứng** | `DenyDeletingAuditEvidence` nêu đích danh ARN của hai bucket bằng chứng, gắn **tự động** vào mọi set đã có `deny_guardrails` |

Lớp thứ hai bắt trường hợp sau này ai đó khai lại `scope = "all"`, hoặc thêm một account lõi mà quên đưa vào `core_accounts`. Một lớp thì một lần sửa nhầm là mất; hai lớp thì phải sai ở hai chỗ khác nhau cùng lúc.

Deny đó **phải nêu Resource cụ thể**, không được `"*"` — `s3:DeleteBucket` trên `"*"` sẽ chặn cả việc xoá bucket hợp lệ trong account workload, mà quản S3 ở đó đúng là việc của `lz-server-admin`. Tôi viết sai chỗ này ở bản nháp đầu và phải sửa lại trước khi commit.

Và nó được gắn **tự động** theo `contains(each.value.statements, "deny_guardrails")` chứ không khai tay ở từng set: khai tay nghĩa là phải nhớ gắn vào 10 chỗ, nhớ lại mỗi lần thêm set mới — và chỗ bị quên chính là chỗ mất bằng chứng.

**Số đo thật sau khi áp dụng:**

| | Trước | Sau |
|---|---|---|
| Tổng assignment | 53 | **29** |
| Permission set trên `lz-logarchive` | 10 | **3** |
| `lz-server-admin`, `lz-db-admin` | 5 account mỗi cái | **2** — chỉ app-dev và app-prod |
| `lz-security-admin` | 5 | **1** |
| `lz-network-admin` | 5 | **1** |

Ba set còn lại trên log archive là `lz-account-admin` (trần đã nêu ở trên), `lz-auditor` và `lz-security-operator` — hai cái sau chỉ đọc và đã chặn data-plane.

Terraform báo `16 to change`, đúng bằng 7 tag `PermissionSetScope` đổi giá trị cộng 9 inline policy nhận thêm `DenyDeletingAuditEvidence` — đúng 9 set có `deny_guardrails`.

> **Bài học:** phân quyền có hai câu hỏi, và tôi chỉ hỏi một. *"Set này cho quyền gì?"* đọc trong policy. *"Set này gán vào đâu?"* đọc ở chỗ khác hoàn toàn. Một set vô hại ở account workload thành nguy hiểm ở account log archive mà **nội dung policy không đổi một chữ**.
>
> Output `scope_map` thêm vào để câu hỏi thứ hai trả lời được bằng một lệnh.

---

### 7j. Lỗi 35 — "service principal hay dùng" gộp hai nhóm không cùng loại

Câu hỏi bắt được lỗi này rất ngắn: *đã có `config`, `config-multiaccountsetup`, `securityhub` trong `delegated_administrators` — có thêm `guardduty` không?*

Câu trả lời là **không**, và lý do cho thấy mô tả biến do tôi viết đang sai.

**Hai nhóm dịch vụ, không cùng cơ chế:**

| Nhóm | Cách chỉ định delegated admin | Khai trong `delegated_administrators`? |
|---|---|---|
| `config`, `config-multiaccountsetup`, `access-analyzer`, `storage-lens` | Đăng ký ở Organizations là **cách duy nhất** | **Có** — bắt buộc |
| `securityhub`, `guardduty` | Có lệnh chỉ định **riêng**, và lệnh đó tự đăng ký ở Organizations giúp | **Không** |

Với nhóm hai, `aws_securityhub_organization_admin_account` và `aws_guardduty_organization_admin_account` — cả hai nằm ở `config-detective` — đã làm trọn việc. Layer `organization` chỉ cần **trusted access** cho chúng, thứ đã có sẵn trong `enabled_service_principals`.

**Khai ở cả hai nơi hỏng ở đâu:** hai layer cùng sở hữu một sự thật. Bỏ khoá ra khỏi map — hoặc destroy layer `organization` — sẽ gọi `DeregisterDelegatedAdministrator`, rút admin ra **từ dưới chân** `config-detective` mà layer đó không hay biết. Nó cũng biến thứ tự apply thành chuyện phải nhớ, thay vì thứ Terraform tự lo.

**`securityhub.amazonaws.com` đang nằm trong map thật.** Nó vào từ trước khi `securityhub.tf` tồn tại, và `prevent_destroy` không cho gỡ ra một cách vô tình. Để nguyên — vô hại vì layer `organization` luôn apply trước. Nhưng nó là **ngoại lệ lịch sử, không phải tiền lệ**.

Mô tả biến giờ tách rõ hai nhóm, và có `check "guardduty_admin_belongs_to_config_detective"` cảnh báo nếu khoá `guardduty.amazonaws.com` lọt vào map.

#### Kiểm chứng: bằng chứng, không phải lập luận

Lúc viết mục này, "lệnh chỉ định riêng tự đăng ký giúp ở Organizations" mới chỉ là **khẳng định của tôi** — đúng loại thứ mà lỗi 36 và 40 dạy là phải đo. Khi `config-detective` apply GuardDuty, dấu thời gian trả lời:

```bash
aws organizations list-delegated-services-for-account --account-id <security>
```

```
config-multiaccountsetup.amazonaws.com   2026-08-21T14:13:50+07:00
config.amazonaws.com                     2026-08-21T14:13:49+07:00
guardduty.amazonaws.com                  2026-08-30T09:59:08+07:00   <- moi
securityhub.amazonaws.com                2026-08-21T14:13:50+07:00
```

Ba dòng cũ là ngày khai `delegated_administrators`. Dòng GuardDuty mang dấu thời gian của lần apply `config-detective`, và `guardduty.amazonaws.com` **chưa từng** xuất hiện trong map. `aws_guardduty_organization_admin_account` đăng ký nó ở tầng Organizations, không cần ai khai.

> Đây cũng là mẫu ngược của cả mục 7: một khẳng định tôi đưa ra **trước** khi có dữ liệu, và lần này dữ liệu xác nhận nó. Điểm đáng giữ không phải "tôi đúng" mà là lệnh kiểm tồn tại và rẻ — cùng một lệnh đó, chạy sớm hơn, đã ngăn được lỗi 36.

> **Bài học:** một danh sách gợi ý trong mô tả biến là **tài liệu có sức nặng ngang code** — nó là thứ người dùng đọc ngay lúc sắp gõ giá trị. Tôi liệt kê `guardduty.amazonaws.com` như một lựa chọn hợp lệ trong khi đang viết layer khác sở hữu chính việc đó. Danh sách phẳng che mất chuyện các mục trong nó không cùng loại.

---

### 7k. Lỗi 36 — điều kiện tiên quyết tôi tự nghĩ ra, và hai lệnh bác bỏ nó

Trước khi import Security Hub đang chạy vào state, phải biết cái gì đã tồn tại. Hai lệnh chạy từ management account:

```
aws securityhub describe-hub
  -> InvalidAccessException: Account 609320954321 is not subscribed to AWS Security Hub

aws securityhub list-organization-admin-accounts
  -> AccountId 458195083898   Status ENABLED
```

Hai dòng đó **không thể cùng đúng** nếu comment tôi viết ở `securityhub.tf` mục 1 là đúng:

> *"`EnableOrganizationAdminAccount` gọi từ management account, và đòi Security Hub đã bật ở chính account đó. Nên bước này đứng trước việc uỷ quyền, không phải sau."*

Uỷ quyền đang chạy. Management chưa từng subscribe. Điều kiện tiên quyết đó **không tồn tại** — tôi viết nó ra vì nó *nghe hợp lý*, không vì đo được.

**Điều thật sự đúng, cũng từ hai lệnh đó:** `AutoEnable: true` đã bật từ lâu ở delegated admin, mà management vẫn không subscribe. Nghĩa là **`auto_enable` không với tới management account** — nó chỉ phủ member account.

Nên resource `aws_securityhub_account.management` vẫn giữ, nhưng vì một lý do khác hẳn lý do tôi viết ban đầu: **không bật ở đó thì không ai bật nó**. Và đó là account đáng tiếc nhất nếu bỏ sót — nó giữ Organizations, SCP và hoá đơn, đồng thời là account duy nhất **SCP không bao giờ áp được**. Nó cần lớp phát hiện *hơn* các account khác, không phải kém hơn.

Hệ quả thực tế: khi import Security Hub sẵn có, ba resource import được, riêng dòng này **tạo mới** — một thay đổi thật, không phải import. Comment giờ nói thẳng điều đó và chỉ cách bỏ nếu không muốn.

`depends_on` giữ nguyên nhưng đổi lý do: không phải ràng buộc kỹ thuật lúc tạo, mà để **định thứ tự destroy** — gỡ uỷ quyền trước khi tắt Security Hub ở management.

> **Bài học:** lỗi 32 là câu dặn sai trong tài liệu vận hành; lỗi 36 là cùng loại nhưng nằm trong **comment giải thích code**, chỗ khó soi hơn nhiều vì không ai chạy comment. Cả hai đều là thứ tôi *suy ra* rồi viết như thể đã kiểm chứng. Khác biệt duy nhất giữa hai lỗi đó và phần còn lại của repo: ở đây có hai lệnh CLI hỏi thẳng dịch vụ, và tôi đã không chạy chúng trước khi viết.

---

### 7l. Lỗi 37 — "rỗng" nghĩa là *không quản*, không phải *tắt*

Câu hỏi mở đầu vẫn vô hại như mọi lần: *"GuardDuty apply xong rồi, có cách nào kiểm tra cấu hình không?"*

`get-detector` trả về:

```
S3_DATA_EVENTS          ENABLED
EKS_AUDIT_LOGS          ENABLED
EBS_MALWARE_PROTECTION  ENABLED
RDS_LOGIN_EVENTS        ENABLED
LAMBDA_NETWORK_LOGS     ENABLED
```

Năm feature tính tiền. Trong khi `guardduty.tf` mục 4 mang tiêu đề **"MẶC ĐỊNH KHÔNG BẬT CÁI NÀO"**, mô tả biến ghi **"MẶC ĐỊNH RỖNG"**, và `check "guardduty_features_cost_money"` — cái `check` dựng riêng để cảnh báo chuyện này — **im lặng hoàn toàn**, vì nó đếm `length(var.guardduty_features)` và con số đó bằng 0.

#### Bước suy luận sai

```hcl
for_each = local.gd == 1 ? toset(var.guardduty_features) : []
```

Rỗng → **không resource nào**. Và "không resource nào" nghĩa là *Terraform không đụng tới feature*, chứ không phải *feature bị tắt*. Hai câu đó nghe giống hệt nhau và khác nhau ở đúng chỗ ra hoá đơn — vì **AWS bật sẵn** phần lớn feature khi tạo detector.

Ba dòng tài liệu tôi viết đều nói *tắt*. Code làm *không quản*. Không dòng nào sai về cú pháp, và `terraform apply` xanh.

#### Bản sửa: khai cả hai chiều

Không thể chỉ sinh resource cho feature được chọn. Phải duyệt **hết** danh sách feature quản được — có trong `guardduty_features` thì `ENABLED`, không có thì `DISABLED` tường minh. Chỉ khi đó `[]` mới thật sự là "tắt hết".

Và cần **hai** resource, không phải một:

| Resource | Phạm vi |
|---|---|
| `aws_guardduty_detector_feature` | detector của **chính** security account |
| `aws_guardduty_organization_configuration_feature` | mặc định cho **account thành viên** |

Hai API khác nhau. Chỉ khai cái thứ hai thì account thành viên sạch, còn detector của security account vẫn bật đủ feature tính tiền — mà đó lại là detector **duy nhất** hiện ra khi gõ `get-detector`, nên thiếu sót này rất dễ tự ru ngủ mình.

Output `guardduty` giờ in cả `features_on` lẫn `features_off`, vì "rỗng" đã một lần bị đọc nhầm.

> **Cảnh báo áp lần đầu:** trên một detector đã chạy, apply sẽ **tắt thật** những feature đang bật. Chạy `get-detector --query 'Features'` trước và đưa cái muốn giữ vào `guardduty_features`.

#### Chẩn đoán sai của tôi trong cùng phiên đó

Thấy `list-organization-admin-accounts` trả về `AdminAccounts: []`, tôi kết luận *"apply không trọn vẹn, có resource lỗi giữa chừng"*. Sai. Hai lệnh sau đó cho câu trả lời thật:

```
terraform state list | grep guardduty   ->  (rong)
terraform plan                          ->  No changes.
```

`enable_guardduty` vẫn `false`. **Terraform chưa từng apply GuardDuty** — detector đang chạy là do bật tay, đúng khuôn Security Hub ở mục 7h.

> **Bài học:** tôi suy trạng thái Terraform từ một lệnh AWS, đúng lúc đang viết mục về việc không được suy trạng thái AWS từ repo. Cùng một lỗi, hướng ngược lại. `terraform state list` là câu hỏi rẻ nhất trong cả phiên và tôi đã đoán thay vì hỏi nó.

---

### 7m. Lỗi 38 — guardrail chặn chính người dựng ra nó

Bản sửa lỗi 37 apply, và sáu resource cùng hỏng một kiểu:

```
AccessDeniedException: User: arn:aws:sts::458195083898:assumed-role/
OrganizationAccountAccessRole/... is not authorized to perform:
guardduty:UpdateDetector ... with an explicit deny in a service
control policy: p-2oni53yp
```

`p-2oni53yp` là `deny_guardrails`, statement `ProtectAuditTrail`, do chính repo này dựng. Trong danh sách cấm có `guardduty:UpdateDetector`.

**Đây là lần đầu SCP đó chặn được một thứ thật.** Nó ngồi im từ giai đoạn 3, và bằng chứng duy nhất rằng nó hoạt động là nó vừa chặn tôi.

#### Vì sao không phải chỉ nới SCP ra

`UpdateDetector` là API **duy nhất** để đổi feature. AWS không tách *"tắt detector"* khỏi *"đổi feature"* — cùng một action.

Mà **chặn Terraform tắt feature là hành vi đúng**: tắt feature là làm yếu lớp phát hiện, đúng thứ `ProtectAuditTrail` sinh ra để chặn. Việc nó chặn luôn chiều *bật* chỉ là thiệt hại kèm theo, và AWS không cho phân biệt.

#### Đường tắt sai, và vì sao nó hấp dẫn

Cơ chế miễn trừ có sẵn: `scp_exempt_role_names`. Thêm `OrganizationAccountAccessRole` vào là hết lỗi ngay, một dòng.

Và nó sẽ **phá sập** `deny_guardrails`. Role đó là chìa khoá vạn năng vào mọi member account. Miễn trừ nó khỏi SCP baseline nghĩa là ai cầm nó cũng `StopLogging`, `DeleteTrail`, `DeleteDetector`, `DisableSecurityHub`, `CloseAccount` được — cả bốn thứ mà lỗi 34 vừa mất công bịt ở tầng permission set. Guardrail cuối cùng biến mất để một feature cost tuning chạy được.

> Đây là dạng đánh đổi nguy hiểm nhất trong cả nhật ký này: **lối thoát một dòng, hợp lệ về cú pháp, và nó gỡ đúng lớp bảo vệ mà mọi lớp khác đang dựa vào.** Không có gì trong output Terraform gợi ý điều đó — thông báo lỗi chỉ nói "explicit deny in a service control policy", nghe như một trở ngại cấu hình.

#### Điều thật sự cần biết: chi phí nằm ở đâu

| Resource | API | SCP chặn? | Phạm vi |
|---|---|---|---|
| `aws_guardduty_detector_feature` | `UpdateDetector` | **có** | detector của security account |
| `aws_guardduty_organization_configuration_feature` | `UpdateOrganizationConfiguration` | không | mặc định cho **account thành viên** |

Phần tiền thật nằm ở **account thành viên** — nhân với số account, và nhân tiếp mỗi khi tổ chức có account mới. Resource thứ hai lo đúng phần đó, gọi action khác, **không bị chặn**, và đã apply được.

Cái còn lại là detector của một account: `lz-security`, nơi không chạy workload nào.

#### Bản sửa

`guardduty_manage_admin_detector_features` mặc định `false` — Terraform không đụng detector của security account, apply chạy sạch, guardrail nguyên vẹn. Muốn bật thì phải cố ý tạo một role riêng cho pipeline và miễn trừ role **đó**, không phải `OrganizationAccountAccessRole`. `check "admin_detector_features_need_an_scp_exemption"` nói thẳng điều này lúc `plan`, kèm cả câu đừng-làm.

Output đổi tên `features_on`/`features_off` thành `member_features_on`/`member_features_off` — vì phạm vi của chúng là account thành viên, và tên cũ để người đọc tưởng nó nói về mọi detector.

> **Bài học:** khi tầng dựng guardrail và tầng cấu hình dịch vụ bị canh giữ **cùng là Terraform, chạy bằng cùng một principal**, thì sớm muộn cái này sẽ chặn cái kia. Câu hỏi đúng lúc đó không phải *"làm sao để qua được?"* mà *"cái bị chặn có phải thứ guardrail sinh ra để chặn không?"* Ở đây câu trả lời là **có**, nên đáp án đúng là lùi lại, không phải khoan thủng.

#### Lỗi 39 — cùng bản vá, một vòng lặp không hội tụ

Plan tiếp theo sạch mọi thứ trừ một dòng:

```
# aws_guardduty_organization_configuration_feature.this["RUNTIME_MONITORING"]
#   must be replaced
- additional_configuration {           # forces replacement
    - name = "ECS_FARGATE_AGENT_MANAGEMENT" -> null
    - name = "EC2_AGENT_MANAGEMENT"         -> null
    - name = "EKS_ADDON_MANAGEMENT"         -> null
  }
Plan: 1 to add, 0 to change, 1 to destroy.
```

`RUNTIME_MONITORING` không phải một công tắc — AWS **luôn** trả về ba sub-config bên trong nó. Code tôi vừa viết coi mọi feature như nhau, nên Terraform đọc ba khối đó từ API, thấy config không có, và đòi gỡ. Mà `name` là `ForceNew`, nên "gỡ" thành **replace cả resource**.

Phần tệ nằm ở chỗ nó **không hội tụ**: replace xong AWS điền lại mặc định, và lần plan sau lại đòi replace tiếp. Không lỗi nào được in ra — chỉ là mọi lần `plan` từ nay đều báo một thay đổi giả, và đó đúng là thứ làm người ta ngừng đọc plan.

Bản sửa khai ba sub-config tường minh, cùng giá trị với feature cha, qua `dynamic` block ở cả hai resource feature.

> Đây là lần thứ hai trong một mục: `[]` không phải *tắt* (lỗi 37), và một feature không phải *một công tắc* (lỗi 39). Cùng một gốc — tôi giả định hình dạng của thứ AWS trả về thay vì đọc nó.

---

### 7n. Lỗi 40 — đường cảnh báo lọc bỏ đúng thứ vừa dựng xong

GuardDuty đã nằm trọn trong Terraform, `apply` sạch, output `findings_reach_alerts = true`. Một phép thử:

```bash
aws guardduty create-sample-findings --detector-id <id> \
  --finding-types 'CryptoCurrency:EC2/BitcoinTool.B!DNS'

aws securityhub get-findings --filters ProductName=GuardDuty \
  --query 'Findings[].{Sev:Severity.Label,Comp:Compliance.Status}'
```

```json
{ "T": "The EC2 instance i-99999999 queried a Bitcoin-related domain name.",
  "Sev": "HIGH",
  "Comp": null }
```

`Comp: null`. Còn `notify.tf` khớp:

```hcl
Compliance = { Status = ["FAILED"] }
```

`Compliance` là trường **chỉ có** ở finding sinh từ control tuân thủ. GuardDuty phát hiện **hành vi** — nó không kiểm tra tuân thủ nên không có trường đó. Mà EventBridge: khoá không tồn tại trong event thì pattern **không khớp**.

Toàn bộ finding GuardDuty bị chặn tại rule. IAM Access Analyzer, Inspector, Macie sẽ y hệt.

#### Vì sao nó sống sót qua ba lần rà

`guardduty.tf` mở đầu bằng khẳng định của tôi: *"KHÔNG CẦN THÊM ĐƯỜNG CẢNH BÁO NÀO — GuardDuty tự đẩy finding sang Security Hub, và `notify.tf` đã đọc từ đó rồi."*

Nửa đầu đúng: GuardDuty **có** đẩy finding sang Security Hub, `get-findings` chứng minh. Nửa sau tôi suy ra từ nửa đầu mà không đọc lại `event_pattern`. Và output `findings_reach_alerts` củng cố niềm tin đó bằng cách tính `enable_guardduty && enable_security_hub` — nó khẳng định một điều nó **không có cách nào biết**.

> Ba nguồn cùng nói "ổn": `apply` xanh, output `true`, finding có thật trong Security Hub. Không nguồn nào trong ba nguồn đó nhìn vào `event_pattern`. Đúng khuôn lỗi 28 — nơi `plan` sạch, state có ARN thật, và SNS đã xoá subscription.

#### Bản sửa: `$or`, không phải bỏ điều kiện

Hai loại finding cần hai câu hỏi khác nhau:

| Loại | Điều kiện đúng |
|---|---|
| control tuân thủ | `Compliance.Status` ∈ `FAILED`/`WARNING` — vì Security Hub gửi cả finding `PASSED` |
| hành vi | không có `Compliance`, chỉ cần tồn tại |

Bỏ hẳn dòng `Compliance` cũng *"chạy được"*: finding `PASSED` thường mang `Severity = INFORMATIONAL` nên rơi khỏi bộ lọc severity. Nhưng đó là dựa vào một **trùng hợp**, không phải một điều kiện — và lớp cảnh báo không nên đứng trên trùng hợp.

```hcl
"$or" = [
  { Compliance = { Status = ["FAILED", "WARNING"] } },
  { Compliance = { Status = [{ exists = false }] } },
]
```

#### Đóng lại bằng thứ duy nhất đóng được nó

Apply bản vá, tạo lại đúng finding mẫu đó. Ba phút sau, trong hộp thư:

```
"[HIGH] The EC2 instance i-99999999 queried a Bitcoin-related domain name."
"Account : 458195083898"
"Region  : ap-southeast-1"
"Resource: arn:aws:ec2:ap-southeast-1:458195083898:instance/i-99999999"
```

Cả chuỗi chạy hết: **GuardDuty → Security Hub → EventBridge (`$or`) → SNS → hộp thư**.

Bản tin còn xác nhận thêm một điều chưa ai kiểm: bộ định dạng thông báo — viết cho finding **control tuân thủ** — bóc đúng severity, account, region và resource ARN từ một finding **hành vi** có cấu trúc khác hẳn. Nếu nó hỏng, email vẫn tới nhưng rỗng nội dung, và không lệnh kiểm nào bắt được.

> **Bài học:** lỗi 33 hỏi *"đường cảnh báo có nguồn không?"* và câu trả lời là có. Lỗi 40 là câu hỏi tiếp theo mà tôi chưa từng hỏi: **nguồn đó có đi lọt qua bộ lọc không?** Một đường ống có thể có đủ nguồn, đủ đích, đủ subscriber đã xác nhận — và đứt ở khúc giữa, nơi không lệnh kiểm tra thành phần nào soi tới.
>
> Cả bốn lỗi cùng họ — 28, 33, 38, 40 — đều đóng theo một cách: **một sự kiện thật, đi hết đường, tới một người thật.** Không có lệnh `describe-*` nào thay được, vì mỗi lệnh chỉ hỏi một mắt xích, còn hỏng nằm ở chỗ nối.

---

### 7o. Lỗi 41 — lỗ hổng chưa vá được, và vì sao không vá bừa

`auto_enable_organization_members = ALL` đúng ở mọi tầng, uỷ quyền trọn vẹn, mà sau **hơn 25 phút** `list-members` vẫn rỗng. GuardDuty đang giám sát đúng một account: `lz-security`, nơi không chạy gì.

`aws guardduty create-members` xong việc trong một lần. Nhưng đó là khuôn đã sinh ra lỗi 33 và 36 — một bước tay ngoài Terraform mà `plan` không thấy, và account mới vào tổ chức sẽ không được ghi danh cho tới khi có người **nhớ** chạy lại. Nên việc đó vào code: `aws_guardduty_member`, danh sách dựng từ `data.aws_organizations_organization` đã có sẵn trong layer.

Apply: **4/5 `Enabled`**, mỗi account một detector riêng. Account thứ năm hỏng:

```
Error: Provider produced inconsistent result after apply
applying aws_guardduty_member.this["609320954321"] ... produced an
unexpected new value: Root object was present, but now absent.
This is a bug in the provider...
```

#### Không viết bản vá theo giả thuyết — mà đi hỏi

Giả thuyết gọn gàng và có sức thuyết phục: GuardDuty đòi management account **tự tạo detector trước**, y hệt `aws_securityhub_account.management` bên Security Hub — một điểm mù, hai dịch vụ, cùng một hình dạng.

Nó cũng có thể sai. Và nếu viết code theo nó rồi sai, kết quả tệ nhất **không phải** apply lỗi lần nữa — mà là một detector đứng riêng trong management account, sinh finding **ở lại chính account đó**, không đi tới delegated admin, nên `notify.tf` không thấy gì. Một lớp giám sát **trông như có**: đúng hình dạng lỗi 28, 33 và 40.

Nên tạm loại management account khỏi `for_each`, dựng một `check` kêu ở mỗi lần `plan`, và đi thử bằng ba lệnh:

```bash
aws guardduty create-detector --enable --region ap-southeast-1   # tu management
aws guardduty create-members --detector-id <admin-detector> \
  --account-details AccountId=<management>,Email=<email> --profile <security>
aws guardduty get-members --detector-id <admin-detector> \
  --account-ids <management> --profile <security>
```

#### Câu trả lời, bằng chữ của chính AWS

```json
"UnprocessedAccounts": [{
  "AccountId": "609320954321",
  "Result": "Operation failed because your organization master must
             first enable GuardDuty to be added as a member"
}]
```

Giả thuyết đúng. Chạy lại sau khi detector đã lan:

```json
"Members": [{ "AccountId": "609320954321",
              "RelationshipStatus": "Enabled" }],
"UnprocessedAccounts": []
```

#### Và điều này sửa lại chính chẩn đoán ở trên

Bản đầu của mục này viết *"AWS nhận lệnh rồi lặng lẽ không tạo bản ghi. Không `UnprocessedAccounts`, không `AccessDenied` — im lặng"*, và kết luận câu *"This is a bug in the provider"* **đặt sai chỗ**. Cả hai đều sai.

AWS **không** im lặng. Nó trả về lý do chính xác, ngay lần đầu, trong `UnprocessedAccounts`. Terraform mới là chỗ nuốt mất câu đó: `CreateMembers` trả **HTTP 200** kèm `UnprocessedAccounts`, provider không kiểm trường ấy, coi là thành công, rồi đọc lại thấy rỗng.

Nên `This is a bug in the provider` **đúng** — chỉ không phải cái bug nó tự nghĩ. Bug thật là bỏ qua `UnprocessedAccounts`, và cái giá là một câu tiếng Anh nói rõ phải làm gì bị đổi thành một câu vô nghĩa.

> Đây là lần **duy nhất** trong cả nhật ký mà CLI trả lời tốt hơn Terraform. Mọi lần trước, hỏi thẳng dịch vụ là cách **kiểm chứng** thứ Terraform nói. Lần này nó là cách **đọc được** thứ Terraform nuốt mất.

#### Bản vá

`aws_guardduty_detector.management` — cùng khuôn với `aws_securityhub_account.management`, và management account quay lại `for_each` với `depends_on` trỏ vào detector đó để Terraform không lặp lại đúng thứ tự sai. `check` tạm thời gỡ bỏ: lỗ hổng đã đóng, không còn gì để nhắc.

Còn lại một khoảng đã biết và đã ghi: **feature tính tiền trên detector của management account chưa được quản.** Ở đó SCP không chặn — SCP không bao giờ áp lên management account — nên quản được, chỉ là chưa. Khác hẳn detector của security account, nơi SCP chặn thật (lỗi 38).

#### Lỗi 42 — cùng resource, một vòng lặp phá thật

Plan ngay sau đó:

```
# aws_guardduty_member.this["169873795883"] must be replaced
+ email  = "quang.hong.0991+lz-app-dev-01@gmail.com"  # forces replacement
~ invite = true -> false
Plan: 4 to add, 0 to change, 4 to destroy
```

Bốn member vừa kết nạp xong, plan đã đòi phá đi dựng lại. Và ở đây `destroy` **không phải thao tác giấy tờ** — là gỡ account thật khỏi GuardDuty rồi kết nạp lại, trên chính lớp đang giám sát toàn tổ chức.

Hai thuộc tính, hai nguyên nhân khác nhau:

| | Vì sao lệch |
|---|---|
| `email` | provider **không đọc lại** từ API. Sau refresh nó rỗng trong state, config có giá trị → khác nhau. Mà `email` là `ForceNew`, nên "khác nhau" thành **replace** |
| `invite` | provider **suy** nó từ `relationship_status`: member đã `Enabled` thì đọc ra `true`. Config khai `false` — đúng, vì account cùng tổ chức không cần thư mời — nên luôn lệch |

Cả hai chỉ có ý nghĩa **lúc tạo**. Đổi email root của một account không phải lý do để gỡ nó khỏi GuardDuty rồi mời lại.

`lifecycle { ignore_changes = [email, invite] }`.

**Đánh đổi phải nói ra:** bỏ qua hai trường đó nghĩa là Terraform **không phát hiện được** việc ai đó gỡ một member ra ngoài Terraform — `relationship_status` là computed nên nó đổi trong im lặng. Resource này bảo đảm **ghi danh lúc tạo**, không phải giám sát liên tục. Câu hỏi *"có account nào rớt ra không"* vẫn phải hỏi thẳng dịch vụ bằng `list-members`.

> Đây là lần thứ ba trong một mục cùng một gốc: `[]` không phải *tắt* (37), một feature không phải *một công tắc* (39), và một thuộc tính trong config không chắc là thuộc tính provider đọc về (42). Cả ba đều là giả định về **hình dạng thứ AWS trả về**, và cả ba chỉ lộ ra ở lần `plan` thứ hai — sau khi apply đã "thành công".

> **Bài học:** ba mục trước đóng bằng bằng chứng. Lỗ hổng management account thì không đóng được, và giá trị của nó nằm ở chỗ **nói ra điều đó** thay vì để một `for_each` lặng lẽ bỏ qua một account. Một `check` kêu mỗi lần `plan` khó chịu hơn hẳn một dòng comment — và đó chính là điều mong muốn: management account giữ Organizations, SCP và hoá đơn, đồng thời là account duy nhất SCP không bao giờ áp được. Nó là account đắt nhất để bỏ sót.

---

### 7p. Lỗi 43 và 44 — script kiểm tra mắc đúng bệnh nó sinh ra để bắt

`verify-detection.sh` viết xong, chạy thật lần đầu:

```
2. PHU SONG THEO ACCOUNT
   169873795883   lz-app-dev       Enabled     THIEU       THIEU
   436908791055   lz-network       Enabled     THIEU       CURRENT
   609320954321   quangch.cloud.9  Enabled     THIEU       ngoai StackSet
   654560867047   lz-logarchive    Enabled     THIEU       CURRENT
   761558631239   lz-app-prod      Enabled     THIEU       CURRENT
```

Cột `SEC HUB` đỏ trên **mọi** account. Đọc như một lỗ hổng diện rộng: Security Hub chỉ chạy ở `lz-security`, còn finding từ Config rule ở account thành viên không tới ai.

Tôi đã bắt đầu dựng bản vá `aws_securityhub_member` theo hướng đó. Người dùng hỏi ngược lại — *"sec-hub là ok nhỉ"* — rồi chạy thẳng lệnh:

```
$ aws securityhub list-members --only-associated false --profile lz-security
usage: aws [options] <command> <subcommand> ...
Unknown options: false
```

**Lệnh chưa từng chạy.** Hai dịch vụ có cú pháp khác nhau:

| Lệnh | Cú pháp | Kiểu |
|---|---|---|
| `guardduty list-members` | `--only-associated false` | chuỗi |
| `securityhub list-members` | `--no-only-associated` | cờ boolean |

Tôi chép cú pháp GuardDuty sang Security Hub. AWS CLI từ chối, lệnh không chạy, file kết quả rỗng — và `|| true` nuốt mã lỗi, nên **"lệnh hỏng" trông y hệt "không account nào được ghi danh"**.

#### Đây là chỗ đáng dừng lại

Script này tồn tại để bắt đúng kiểu hỏng đó. Tài liệu của nó mở đầu bằng lỗi 27, 28 và 41 — cả ba đều là *một câu trả lời rỗng bị đọc thành một sự thật*. Rồi nó lặp lại chính xác lỗi ấy, ngay ở dòng đầu tiên có ý nghĩa.

Bản vá không phải chỉ đổi cờ. Ba lệnh giờ **giữ mã thoát**: thất bại thì in dòng đầu của `stderr` và cột ghi `khong doc duoc`; chạy được mà rỗng thì nói rõ *"chay duoc nhung KHONG co member nao"*. Hai câu đó không được phép trông giống nhau nữa.

> **Bài học:** `|| true` là cách viết ra một khẳng định mà không có gì đứng sau. Trong một script kiểm tra, nó tệ hơn hẳn ở nơi khác — vì đầu ra của nó là thứ người ta **dùng thay cho** việc tự kiểm tra. Một script báo dương tính giả không chỉ sai một lần; nó dạy người ta ngừng đọc.

#### Lỗi 44 — dương tính giả thứ hai, cùng lần chạy

`lz-app-dev` báo `CONFIG THIEU`. Người dùng trả lời ngay: *"cái này đúng rồi nhé, vì không bật trong OU lz-dev"* — OU dev **cố ý** không có recorder, một quyết định chi phí.

Script suy phạm vi từ nơi *đã có* stack instance, nên không phân biệt được hai thứ:

| Trạng thái | Thực chất |
|---|---|
| OU nằm trong phạm vi, account thiếu recorder | **lỗ hổng thật** |
| OU không có instance nào cả | **lựa chọn**, không phải thiếu sót |

Bản vá thêm cột `OU` và so OU của account với tập OU đang có instance: OU nào hoàn toàn không có instance thì in `OU ngoai pham vi` màu xám, không tính là khoảng trống.

#### Lỗi 45 — chạy lại script đã vá, và lần này cột đỏ là thật

```
securityhub list-members chay duoc nhung KHONG co member nao.

   169873795883   lz-app-dev       Non-Production  Enabled   THIEU   OU ngoai pham vi
   436908791055   lz-network       Infrastructure  Enabled   THIEU   CURRENT
   458195083898   lz-security      Security        admin     admin   CURRENT
   609320954321   quangch.cloud.9  (root)          Enabled   THIEU   ngoai StackSet
   654560867047   lz-logarchive    Security        Enabled   THIEU   CURRENT
   761558631239   lz-app-prod      Production      Enabled   THIEU   CURRENT
```

Dòng đầu là câu mà bản vá lỗi 43 thêm vào, và nó làm đúng việc của mình: **lệnh chạy được, kết quả rỗng** — hai chuyện khác nhau, giờ nói bằng hai câu khác nhau. `lz-app-dev` cũng đã ra `OU ngoai pham vi` thay vì `THIEU`.

Còn lại là sự thật: **Security Hub không có account thành viên nào.**

`auto_enable = true` là chính sách cho account **tạo sau** thời điểm bật. Năm account đã tồn tại từ trước chưa bao giờ được gọi `CreateMembers` — y hệt GuardDuty ở lỗi 41, khác dịch vụ, giống hình dạng.

**Vì sao nó ẩn được lâu đến vậy:** finding của GuardDuty đi **thẳng** vào Security Hub của delegated admin, không qua Security Hub của account thành viên. Nên email cảnh báo thật vẫn tới, `alert_path_live` vẫn `true`, và cả mục 7n đóng lại được mà không ai chạm tới lỗ hổng này.

Thứ **không** tới là finding sinh trong account thành viên — điển hình là kết quả đánh giá của Config rule. Chúng trở thành finding trong chính account đó, mà account đó chưa bật Security Hub.

> Đường cảnh báo đang mang **một trong hai nguồn**. Nó hoạt động, có bằng chứng, và vẫn thiếu một nửa.

Bản vá là `aws_securityhub_member`, cùng khuôn `aws_guardduty_member` — chính sách lo tương lai, resource lo hiện tại.

Nó mang theo `ignore_changes = [email, invite]` **theo phỏng đoán**: chưa đo cho resource này, mà suy từ lỗi 42 ở resource anh em. Phép đánh đổi lệch hẳn một phía — thừa thì vô hại, thiếu thì mỗi lần plan đòi gỡ 5 account thật ra khỏi Security Hub rồi kết nạp lại. `plan` lần thứ hai sau apply ra **`No changes`**, nên phỏng đoán đúng, và giờ nó là phép đo.

> Hai lỗi trong một lần chạy, và cả hai đều **báo sai theo hướng hoảng loạn**. Với một script kiểm tra bảo mật, đó không phải phía an toàn để sai — nó tiêu đúng thứ mà công cụ loại này sống nhờ vào.

---

### 7q. Lỗi 46 — `pipefail` biến "tìm thấy" thành "không thấy"

`plan-check.sh` của `demo/network-lz-full` báo **19 lỗi**. Sau hai vòng vá, chín tổ hợp plan đều xanh với con số thật — 65, 91, 136, 139, 130, 175, 178 resource, gồm cả nhánh Palo Alto và F5 chưa từng được kiểm. Nhưng mục 3 vẫn trượt cả chín khẳng định:

```
✓ Plan day du: 175 resource - chay 10 kiem tra hanh vi
✗ Network Firewall  (khong thay 'aws_networkfirewall_firewall.main' trong plan)
✗ Gateway Load Balancer  (khong thay 'aws_lb.gwlb' trong plan)
...
```

Dòng đầu nói plan có **175 resource**. Chín dòng dưới nói không tìm thấy thứ gì trong đó. Cả tám tên resource được kiểm đều **tồn tại trong code**.

#### Nguyên nhân

```bash
set -uo pipefail          # dong 11 cua script
echo "$FULL" | grep -q "$pattern"
```

`grep -q` thoát **ngay khi khớp dòng đầu tiên**. `echo` còn đang ghi thì mất đầu đọc → chết vì `SIGPIPE`, mã thoát 141. `pipefail` lấy mã thoát **cao nhất** của cả pipeline, nên pipeline trả về 141 dù `grep` đã trả về 0.

**Khớp càng sớm thì càng chắc chắn báo sai.**

Kiểm bằng năm dòng:

```bash
set -uo pipefail
BIG=$(python3 -c "print('\n'.join('x' for _ in range(5000)))")
echo "$BIG" | grep -q x && echo "TIM THAY" || echo "BAO KHONG THAY"
# -> BAO KHONG THAY
grep -q x <<<"$BIG" && echo "TIM THAY"
# -> TIM THAY
```

#### Vì sao nó ẩn kỹ đến vậy

Nó **chỉ sai khi đầu vào đủ lớn** để `echo` chưa kịp ghi hết. Thử trên chuỗi ngắn thì luôn đúng — và đó chính là cách tôi "kiểm chứng" logic đếm ở vòng trước: chạy trên một file giả bốn dòng, thấy ra `91`, kết luận là logic đúng. File giả không đủ lớn để gây SIGPIPE, còn plan thật thì 2285 dòng.

> **Một phép thử không tái hiện được điều kiện thật thì không phải phép thử.** Tôi đã tự thuyết phục mình bằng một bài test nhỏ hơn hiện tượng cần bắt.

Cùng nguyên nhân giải thích nốt bí ẩn còn treo từ vòng trước: `n=$(... | grep -oE ... | head -1)` — `head -1` cũng đóng pipe sớm, nên dòng `Plan: 91 to add` *có thật trong output* mà script không đọc được.

#### Bản vá

Thay pipeline bằng **herestring** — `grep -q "$pattern" <<<"$FULL"` không tạo pipeline nên không có SIGPIPE. `head -1` đổi thành `sed -n '1p'`, đọc hết đầu vào.

Và một khẳng định phủ nhận vẫn "đạt" suốt cả thời gian đó: `grep -q app_direct` không khớp thật, `echo` chạy trọn, pipeline trả 1, nhánh `||` chạy → ✓. Bảng kết quả có đúng một dấu tích, đủ để mục đó trông như đã chạy.

> **Bài học:** đây là lỗi thứ **năm** trong một phiên cùng hình dạng — 27, 28, 41, 43, và giờ 46: một kết quả rỗng hoặc một mã thoát sai bị đọc thành sự thật. Bốn lần trước nguyên nhân là `|| true` hoặc quên kiểm exit code. Lần này thì ngược đời: `pipefail` — một cờ **dựng ra để tăng độ nghiêm ngặt** — chính là thứ tạo ra câu trả lời sai.

---

### 7r. Lỗi 47 — thứ `plan` không bao giờ bắt được

`plan-check.sh` vừa ra **24 đạt, 0 lỗi**. Chín tổ hợp, 136 resource cho nhánh firewall, mười khẳng định hành vi đều xanh. `terraform apply` chạy được 10 phút rồi chết:

```
Error: creating NetworkFirewall Firewall Policy (quh11-net-policy):
InvalidRequestException: ResourceArn has invalid rule order,
parameter: [.../quh11-net-egress-domains],
context: StatefulRuleGroupReferences[1].ResourceArn
```

Policy khai `stateful_engine_options { rule_order = "STRICT_ORDER" }`. Rule group `east_west` khai `stateful_rule_options { rule_order = "STRICT_ORDER" }`. Rule group `egress_domains` **không khai gì** — và mặc định của rule group là `DEFAULT_ACTION_ORDER`, nên "không khai" không phải là "thừa kế từ policy" mà là **một lựa chọn khác hẳn**.

`StatefulRuleGroupReferences[1]` là tham chiếu thứ hai, đúng `egress_domains`.

#### Vì sao mọi lớp kiểm tra đều bỏ lọt

| Lớp | Vì sao không thấy |
|---|---|
| `terraform validate` | Cú pháp đúng, tham chiếu đúng |
| `terraform plan` | Rule group và policy là **hai resource riêng**. Plan không đối chiếu thuộc tính giữa chúng — nó không biết `rule_order` của cái này phải khớp cái kia |
| `plan-check.sh` × 9 tổ hợp | Đếm resource và tìm chuỗi trong plan. Cả hai rule group **đều có mặt** trong plan, đúng như mong đợi |

Ràng buộc này sống **hoàn toàn ở phía API**. Không công cụ tĩnh nào thấy được, và chỉ `apply` thật mới hỏi tới.

> **Đây là giới hạn của mọi thứ đã làm ở mục 7q.** Sửa xong `plan-check.sh` để nó báo trung thực là việc đúng — nhưng một script chạy `plan` chỉ kiểm được thứ `plan` biết. Ranh giới đó không dịch chuyển bằng cách viết script tốt hơn.
>
> Cùng bài học với lỗi 28, 33, 40 và 45, chỉ đổi tầng: ở đó là *cấu hình đúng nhưng sự kiện không đi qua*; ở đây là *plan đúng nhưng API từ chối*. Cả hai chỉ đóng được bằng một lần chạy thật.

#### Giá của việc phát hiện muộn

Apply chết giữa chừng để lại TGW, ba route table, hai VPC, các attachment — đã tạo, đang tính tiền, và state **không đầy đủ**. Không hỏng: `terraform apply` lại sau khi vá sẽ tạo tiếp phần còn thiếu. Nhưng nếu bỏ dở lúc này thì đó là hạ tầng mồ côi mà `plan` vẫn thấy, còn người thì quên.

Sửa: thêm `stateful_rule_options { rule_order = "STRICT_ORDER" }` vào `egress_domains`.

---

### 7s. Lỗi 48 — mạng chạy đúng, script báo hỏng

Sau khi vá lỗi 47, `apply` chạy trọn. `verify.sh` báo **7 đạt, 3 lỗi, 4 bỏ qua**:

```
3. Duong VE trong egress VPC (loi hay gap nhat)
   An error occurred (InvalidRouteTableID.NotFound) ... routeTable ID 'None'
   ✗ THIEU duong ve! Spoke ra duoc Internet nhung khong nhan duoc goi tra loi

4. ✗ Firewall status =
5. - rtb-spokes khong ton tai      - rtb-egress khong ton tai
   ✗ rtb-security THIEU route ve ingress → goi tra loi se lac sang egress VPC
```

Ba lỗi đó mô tả một mạng hỏng nặng: không có đường về, firewall không tồn tại, route table TGW trống.

**Nhưng mục 7 và 8 của cùng lần chạy đó lại xanh** — và chúng là các mục duy nhất đo **lưu lượng thật**, chạy lệnh trên EC2 qua SSM:

```
7. ✓ Egress ra Internet bang NAT cua egress VPC (52.77.72.122)
   ✓ East-west port 80 THONG (co rule firewall + SG cho phep)
8. ✓ NLB → TGW → (firewall) → app: HTTP 200
```

Gói tin đi được qua **đúng những resource** mà mục 3–5 nói là không tồn tại. Hai nhóm kết quả không thể cùng đúng.

#### Nguyên nhân

```bash
PROJECT="${PROJECT:-lz-net}"          # verify.sh dong 9
```

`var.project` thật là `quh11-net` — nhìn thấy được ngay trong lỗi apply ở mục 7r: `quh11-net-policy`, `quh11-net-egress-domains`. Mọi lookup dạng

```bash
--filters "Name=tag:Name,Values=${PROJECT}-egress-public-rt"
```

lọc theo `lz-net-*`, không khớp gì, và `--query ...` trả về chuỗi `None`. Script đem `None` đi gọi API tiếp, AWS từ chối, và nhánh lỗi in ra một câu về hạ tầng.

`outputs.tf` không có `output "project"`, nên script **không có cách nào** biết tên thật.

#### Vì sao vài mục vẫn xanh

Đúng những mục không dùng tên: `appliance_mode_support` đọc từ attachment tìm theo TGW ID, gateway endpoint đếm theo VPC, tag `CostCenter` quét theo tag chứ không theo `Name`, và mục 7–8 chạy lệnh trên EC2 lấy từ `terraform output`. Bảy dấu tích đó làm bảng kết quả trông như một mạng **hỏng một phần** — dạng khó nghi ngờ hơn hẳn hỏng toàn bộ.

#### Bản vá

Thêm `output "project"`, và `verify.sh` đọc từ đó thay vì đoán; không đọc được thì **dừng hẳn** với thông báo rõ, chứ không chạy tiếp với chuỗi rỗng.

> **Bài học:** lần thứ **sáu** trong phiên này — 27, 28, 41, 43, 46, 48 — một kết quả rỗng bị đọc thành một sự thật. Nhưng lần này nguy hiểm theo chiều ngược: năm lần trước báo *"ổn"* khi có vấn đề. Lần này báo *"hỏng"* khi mọi thứ đúng.
>
> Chiều nào cũng tiêu cùng một thứ: nếu tôi tin bảng kết quả, tôi đã đi sửa route table của một mạng không hỏng — và rất có thể làm hỏng nó thật.

---

### 7t. Lỗi 49 — mở rộng một biến mà không rà nơi nó đã được dùng

Thêm `account_id` vào `spokes` để spoke nằm được ở account khác. Code mới đúng, `terraform validate` xanh. Nhưng `var.spokes` từ đó mang **hai loại** spoke, còn 22 chỗ dùng nó ở tám file khác vẫn coi nó là một:

```
versions.tf 2   vpc-spokes.tf 5   tgw.tf 5   instances.tf 2
dns.tf 3        outputs.tf 3      vpc-ingress.tf 1   vpc-security.tf 1
```

Hệ quả: một spoke khai `account_id` sẽ được tạo **hai lần** — VPC local qua `vpc-spokes.tf` và VPC remote qua StackSet, **cùng CIDR**, hai attachment vào cùng TGW. Không lỗi lúc plan; TGW nhận cả hai và route table không phân biệt được chúng.

Bản vá thêm `local.local_spokes` (spoke không khai `account_id`) và đổi 21 trong 22 chỗ sang nó.

**Chỗ thứ 22 giữ nguyên `var.spokes`, có chủ đích:**

```hcl
n_attach = length(var.spokes) + 1 + local.fw + local.ing
```

Đây là dòng ước tính chi phí. Attachment remote tính tiền y hệt attachment local, nên nó phải đếm **cả hai**. Đổi nốt cho "nhất quán" sẽ làm hoá đơn ước tính thấp hơn thực tế đúng bằng số spoke ở account khác.

> **Bài học:** mở rộng một biến là thay đổi **hợp đồng** của nó với mọi nơi đã dùng. `grep -c` cho con số 22 trong ba giây; tôi viết 385 dòng code mới trước khi chạy nó. Và điều đáng chú ý: cả `terraform validate` lẫn `terraform plan` đều **không thể** bắt lỗi này — cấu hình hoàn toàn hợp lệ, chỉ là nó tạo gấp đôi thứ cần tạo.

---

### 7u. Lỗi 50 — cảnh báo tôi đã đọc, hiểu, rồi bác bỏ

`landing-zone/network/variables.tf`, trong mô tả biến `spoke_attachments`, viết từ trước:

> *"Vì sao phải khai tay: attachment nằm ở account khác nên layer này không tạo ra chúng, và **discovery động bằng data source sẽ làm `count`/`for_each` thành "known after apply" — plan không đọc được**."*

Đầu phiên tôi đọc đúng dòng đó và kết luận nó **sai một nửa**: một data source đọc attachment *đã tồn tại* thì phân giải được lúc refresh, nên `for_each` chạy được. Rồi tôi xây `vpc-spokes-remote.tf` trên kết luận ấy.

Plan chết:

```
Error: Invalid for_each argument
The "for_each" set includes values derived from resource attributes
that cannot be determined until apply
```

#### Chỗ tôi bỏ sót

Lập luận của tôi đúng cho một data source **độc lập**. Nhưng data source này lọc theo:

```hcl
filter {
  name   = "transit-gateway-id"
  values = [aws_ec2_transit_gateway.hub.id]
}
```

TGW được **tạo trong chính config này**. Lần apply đầu tiên `hub.id` chưa biết → data source không đọc được lúc plan → danh sách ID chưa biết → Terraform không dựng được bộ khoá `for_each`.

Không lách được bằng `try()` hay `coalesce()`. Chưa biết là chưa biết.

Tôi còn tự làm nặng thêm bằng `depends_on = [aws_cloudformation_stack_set_instance.spoke]` — nó đẩy data source sang thì apply ngay cả khi mọi thứ khác đã biết.

#### Bản vá

Hai pha tường minh qua `wire_remote_attachments`:

| Pha | Giá trị | Làm gì |
|---|---|---|
| 1 | `false` *(mặc định)* | TGW, RAM share, StackSet, VPC + attachment ở account đích |
| 2 | `true` | TGW đã nằm trong state nên `hub.id` biết lúc plan → data source đọc được ID thật → nối route |

Giữa hai pha, attachment tồn tại mà không thuộc route table nào: `State` là `available`, không lỗi, và không một gói tin nào đi qua. `check "remote_attachments_wired"` canh đúng chỗ đó.

> **Bài học:** đây không phải chuyện thiếu thông tin. Cảnh báo nằm sẵn trong repo, tôi đã đọc, và tôi bác bỏ nó bằng một lập luận **đúng trong trường hợp tổng quát nhưng sai trong chính cấu hình mình đang viết**. Nguy hơn hẳn việc không biết: tôi có một lý do nghe hợp lý để bỏ qua nó.
>
> Người viết dòng đó đã trả giá để biết. Bác bỏ một cảnh báo cụ thể thì cái giá phải trả là chứng minh nó sai **trong ngữ cảnh của mình** — không phải tìm ra một ngữ cảnh khác nơi nó sai.

---

### 7v. Lỗi 51 — một nửa sự thật, và nửa còn lại phá cả thiết kế

Người dùng nhìn plan và hỏi một câu: *"sao code lại tạo network ở bên account management vậy — nhầm rồi"*.

Đúng. Và tôi là người bảo họ làm thế.

Khi viết `vpc-spokes-remote.tf`, tôi cần StackSet `SERVICE_MANAGED`, thứ chỉ tạo được từ **management account hoặc delegated administrator**. Tôi lấy vế đầu, viết hẳn một khối comment giải thích rằng đó là ràng buộc IAM chứ không phải sở thích, thêm biến `i_am_running_from_management_account`, và dựng cả một `check` để nhắc.

Nửa còn lại tôi bỏ qua: **demo chỉ có MỘT provider.** Chạy từ management nghĩa là TGW, security VPC, egress VPC, Network Firewall, NAT, NLB — 124 resource — đều được tạo trong management account.

Management account giữ Organizations, SCP và hoá đơn, và là account duy nhất **SCP không bao giờ áp được**. Đặt hạ tầng mạng ở đó là đặt nó ngoài mọi guardrail của chính tổ chức. Cả doc 22 lẫn doc 23 đã nhắc điều này nhiều lần — ở lỗi 36, 38, 41 — và tôi vẫn viết ra một hướng dẫn dẫn thẳng vào đó.

#### Cách đúng

Đăng ký account network làm delegated administrator của StackSets, chạy **một lần** từ management:

```bash
aws organizations register-delegated-administrator \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com \
  --account-id <network-account-id>
```

Rồi StackSet tạo được từ chính account network với `call_as = "DELEGATED_ADMIN"` — và hub nằm đúng chỗ.

Đây cũng là **nhóm 1** trong bảng ở lỗi 35: StackSets không có lệnh chỉ định riêng, nên đăng ký ở Organizations là cách duy nhất, và nó thuộc về `delegated_administrators` của layer `organization`.

> **Bài học:** ràng buộc tôi tìm được là *"cần management **hoặc** delegated admin"*. Tôi dừng ở vế thoả mãn được ngay và không hỏi vế kia tốn gì. Nó tốn đúng thứ mà toàn bộ Landing Zone dựng lên để bảo vệ.
>
> Và điều đáng chú ý nhất: `plan` chạy sạch, `validate` xanh, `plan-check` không liên quan. Thứ bắt được lỗi này là **một người đọc plan và thấy tên account sai**.

---

### 7w. Lỗi 52 — ba lỗi, hai nguyên nhân, một trong đó nói sai chỗ

Apply lần đầu của `vpc-spokes-remote.tf` chết với ba lỗi:

```
OperationNotPermittedException: The resource you are attempting to share
can only be shared within your AWS Organization... or that you have not
enabled sharing with your AWS organization

UnknownResourceException: Organization o-tvkzhcq3yh could not be found

ValidationError: OrganizationalUnitIds are required
```

#### Hai lỗi đầu: thiếu một bước bật ở cấp tổ chức

RAM chia sẻ với Organizations phải được **bật một lần**, và tôi không biết bước đó tồn tại:

```bash
aws ram enable-sharing-with-aws-organization      # tu management account
```

Chưa bật thì mọi lệnh share đều hỏng — nhưng **hai lỗi nói hai chuyện khác nhau**, và cái thứ hai nói sai chỗ:

> `Organization o-tvkzhcq3yh could not be found`

Đọc câu đó, phản xạ đầu tiên là đi kiểm `organization_arn` — mà ARN hoàn toàn đúng. Tổ chức tồn tại; thứ không tồn tại là **quyền của RAM để nhìn thấy nó**.

#### Lỗi thứ ba: `accounts` không thay được OU

```hcl
deployment_targets {
  accounts = [each.value.account_id]     # SAI voi SERVICE_MANAGED
}
```

StackSet service-managed triển khai theo **cây tổ chức**, không theo danh sách account rời. `accounts` chỉ là **bộ lọc bên trong** các OU đã khai, và phải đi kèm `account_filter_type`.

Bản vá thêm `ou_id` vào mỗi spoke remote:

```hcl
deployment_targets {
  organizational_unit_ids = [each.value.ou_id]
  accounts                = [each.value.account_id]
  account_filter_type     = "INTERSECTION"
}
```

`INTERSECTION` là phần quan trọng nhất. Thiếu nó thì `accounts` **bị bỏ qua** và StackSet triển khai ra **cả OU** — mọi account trong đó nhận một VPC với **cùng một CIDR**. Một lỗi cú pháp thiếu sót biến thành trùng CIDR hàng loạt.

> **Bài học:** cả ba lỗi này đều chỉ tồn tại phía API — `validate` xanh, `plan` sạch, `plan-check` không chạm tới. Đây là lần thứ hai trong phiên (sau lỗi 47) mà apply là thứ duy nhất tìm ra được, và cũng là lần thứ hai một thông báo lỗi của AWS trỏ vào chỗ không phải nguyên nhân.

---

### 7x. Lỗi 53 — "could not be found" nghĩa là không được phép nhìn

Sau khi sửa lỗi 51 và chạy đúng từ account network, apply vẫn chết với **hai lỗi RAM y hệt lần trước**:

```
OperationNotPermittedException: The resource you are attempting to share
can only be shared within your AWS Organization. This error may also occur
if you have not enabled sharing with your AWS organization...

UnknownResourceException: Organization o-tvkzhcq3yh could not be found
```

Ở lỗi 52 tôi kết luận nguyên nhân là chưa chạy `aws ram enable-sharing-with-aws-organization`. Người dùng chạy, nhận `returnValue: true`, và lỗi vẫn nguyên. Tôi đoán tiếp: *"đang lan, đợi vài phút"* — dựa vào đúng vế cuối của thông báo, `or that onboarding process is still in progress`.

Một lệnh bác bỏ cả hai:

```bash
aws organizations list-aws-service-access-for-organization \
  --query "EnabledServicePrincipals[?ServicePrincipal=='ram.amazonaws.com']"
-> 2026-08-20T00:40:56  ram.amazonaws.com
```

**Bật từ gần hai tuần trước.** Không phải chưa bật, không phải đang lan.

#### Nguyên nhân tôi kết luận lúc đó — và nó SAI

**Member account không được share với cả tổ chức hoặc một OU.** Chỉ management account, hoặc một RAM delegated administrator, mới làm được. `lz-network` là member thường.

> **Đính chính (xem mục 7z).** Kết luận này bị bác bỏ sau đó: người dùng tạo Transit Gateway **từ chính management account** và share cho một OU vẫn hỏng, với thông báo khác hẳn — `OrganizationalUnit ou-o5ci-fz0yuca3 in unknown organization could not be found`. Management account thì theo định nghĩa là được phép. Nên "quyền của member account" không phải nguyên nhân, và đoạn dưới đây đọc với hiểu biết đó.
>
> Đây là lần thứ **ba** liên tiếp trong cùng một vấn đề tôi biến một thông báo lỗi thành một nguyên nhân. Cả ba lần đều nghe hợp lý, và cả ba lần đều được ghi vào tài liệu như sự thật trước khi có phép đo nào tách bạch được nó.

Và đây là chỗ thông báo dẫn đi lạc: `Organization o-tvkzhcq3yh could not be found` nghe như sai ARN — nhưng ARN hoàn toàn đúng. Tổ chức tồn tại. Thứ không tồn tại là **quyền của account này để nhìn thấy nó**. AWS nói *"không tìm thấy"* cho cả trường hợp *"không được phép"*, và tôi đã đọc nó theo nghĩa đen hai lần liên tiếp.

#### Bản vá, và vì sao nó tốt hơn cách đúng-nhưng-nặng

Có hai đường:

| Cách | Đánh đổi |
|---|---|
| Đăng ký `lz-network` làm **RAM delegated administrator** | Thêm một uỷ quyền cấp tổ chức nữa, và share TGW cho **mọi** account |
| **Share cho từng account ID** | Member account làm được, không cần uỷ quyền, và chỉ account thật sự có spoke mới thấy TGW |

Cách thứ hai đúng hơn về nguyên tắc, nên chọn nó:

```hcl
resource "aws_ram_principal_association" "spoke_accounts" {
  for_each = { for k, v in local.remote_spokes : k => v.account_id }
  principal          = each.value
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}
```

Không cần acceptance: `enable-sharing-with-aws-organization` đã bật, nên share nội bộ tổ chức tự động được chấp nhận.

> **Bài học:** tôi đoán hai lần từ **cùng một thông báo lỗi**, và cả hai lần thông báo đó đều gợi ý sai. Vế `"or that onboarding process is still in progress"` là một danh sách khả năng do AWS liệt kê, không phải chẩn đoán — nhưng nó đọc như một chẩn đoán, nên tôi dùng nó thay cho việc đi đo.
>
> Lệnh bác bỏ nó tốn ba giây, và tôi chỉ chạy nó sau khi đã đoán sai hai lần.

---

### 7y. Lỗi 55 — năm giả thuyết, và cái đúng là "không làm được"

Chuỗi này bắt đầu từ một thông báo lỗi duy nhất, lặp lại không đổi qua sáu lần apply:

```
OperationNotPermittedException: The resource you are attempting to share
can only be shared within your AWS Organization. This error may also occur
if you have not enabled sharing with your AWS organization, or that
onboarding process is still in progress.
```

Tôi đưa ra **năm** giả thuyết. Bốn cái đầu đều sai, và mỗi cái tốn một vòng apply:

| # | Giả thuyết | Bác bỏ bằng |
|---|---|---|
| 1 | Chưa chạy `enable-sharing-with-aws-organization` | Chạy rồi, `returnValue: true`, lỗi y nguyên |
| 2 | Đang lan, đợi vài phút | Trusted access bật từ **2026-08-20**, gần hai tuần |
| 3 | Member account không share được org-wide | Đổi sang share từng account — vẫn hỏng |
| 4 | Share cũ hỏng trạng thái | Share **mới tinh** cũng hỏng |
| 5 | Share chưa có principal nào | Associate principal **cũng** hỏng |

Ba giả thuyết đầu tôi lấy thẳng từ vế cuối của thông báo — `"or that onboarding process is still in progress"`. Đó là một **danh sách khả năng AWS liệt kê sẵn**, không phải chẩn đoán. Nhưng nó đọc như chẩn đoán, nên tôi dùng nó thay cho việc đo.

#### Phép đo cuối, hoàn toàn ngoài Terraform

```bash
# A. create kem resource
aws ram create-resource-share --name probe \
  --no-allow-external-principals --resource-arns "$TGW"
-> ACTIVE

# B. create rong roi associate
A=$(aws ram create-resource-share --name probe-empty \
      --no-allow-external-principals --query '...' --output text)
aws ram associate-resource-share --resource-share-arn "$A" --resource-arns "$TGW"
-> OperationNotPermittedException

aws ram associate-resource-share --resource-share-arn "$A" --principals <account>
-> OperationNotPermittedException
```

Cùng account, cùng TGW, cùng phút. **`AssociateResourceShare` bị từ chối như một thao tác** — cả cho resource lẫn principal — trong khi `CreateResourceShare` kèm `--resource-arns` chạy.

#### Vì sao không vá được bằng Terraform

`aws_ram_resource_share` của provider AWS **không có** thuộc tính `resource_arns`. Resource bắt buộc đi qua `aws_ram_resource_association`. Nghĩa là:

> Trình tự duy nhất RAM chấp nhận là trình tự Terraform **không tạo ra được**.

Không phải lỗi code, không phải cấu hình sai. Là một chỗ mô hình resource của provider không biểu diễn được hành vi của dịch vụ.

#### Bản vá: nói ra thay vì giấu

Ba resource RAM bị gỡ khỏi `vpc-spokes-remote.tf`. Việc share làm bằng **một lệnh CLI, một lần**, và `check "tgw_shared_with_spoke_accounts"` nhắc ở mỗi lần plan cho tới khi có người xác nhận đã làm.

#### Chỗ thứ hai cùng kiểu, chưa ai đi qua

`dns.tf` share Route 53 Profile bằng **đúng bộ ba resource đó** — `aws_ram_resource_share` + `aws_ram_resource_association` + `aws_ram_principal_association`. Nếu giới hạn nằm ở **account** chứ không ở loại resource thì `enable_dns_profile = true` sẽ dừng ở `aws_ram_resource_association.dns_profile` với cùng thông báo.

Chưa đo trên Route 53 Profile, nên đây là **dự đoán chứ không phải sự thật đã kiểm chứng** — phép đo ở trên chỉ làm trên TGW. Cả `enable_dns_profile` lẫn `organization_arn` đều mặc định tắt nên đường này chưa ai đi qua; đã ghi cảnh báo ngay tại `dns.tf` thay vì để người sau gặp lại từ đầu.

> **Bài học:** tôi đã đoán năm lần từ cùng một thông báo, và mỗi lần đoán đều tốn một vòng apply mười phút của người dùng. Phép đo tách bạch được hai trình tự — thứ cuối cùng cho câu trả lời — tốn **ba mươi giây**, và lẽ ra phải là việc đầu tiên chứ không phải việc cuối cùng.
>
> Khi một thông báo lỗi liệt kê nhiều nguyên nhân có thể, đó là dấu hiệu nó **không biết** nguyên nhân nào. Đọc nó như một gợi ý là tự nhận lấy sự mơ hồ của nó.

---

### 7z. Lỗi 56 — management account cũng không share được, và ba kết luận trước đó đổ

Sau khi kết thúc mục 7y, người dùng thử một đường hoàn toàn khác: tạo Transit Gateway **từ management account** và share cho một OU qua console. Kết quả:

```
OrganizationalUnit ou-o5ci-fz0yuca3 in unknown organization could not be found.
```

Một dòng này làm đổ **cả ba** kết luận trước:

| Đã ghi ở | Kết luận | Vì sao đổ |
|---|---|---|
| Lỗi 52 | Chưa chạy `enable-sharing-with-aws-organization` | Chạy rồi, `returnValue: true` |
| Lỗi 53 | Member account không được share | Management account **cũng** hỏng |
| Lỗi 55 | `AssociateResourceShare` bị chặn như một thao tác | Lần này hỏng ở `create`, không phải `associate` |

Và thông báo lần này khác về **chất**: `in unknown organization`. RAM đọc được ID của OU, đi tìm tổ chức chứa nó, và không thấy. Không có chữ nào về quyền.

#### Không đưa nguyên nhân ở đây

Bốn lần trước tôi đọc một thông báo lỗi rồi viết ra một nguyên nhân, và cả bốn lần đều sai — ba trong số đó đã kịp nằm trong tài liệu này dưới dạng sự thật. Nên mục này ghi **phép đo cần chạy**, không ghi chẩn đoán.

Ba phép đo, từ management account, xếp theo lượng thông tin trên mỗi giây:

```bash
# 1. RAM da onboard THAT chua
aws iam get-role --role-name AWSServiceRoleForResourceAccessManager
```

`enable-sharing-with-aws-organization` tạo service-linked role này. Trusted access bật **không** đảm bảo role còn tồn tại — nó có thể bị xoá sau. Không có role thì `unknown organization` là mô tả đúng theo nghĩa đen.

```bash
# 2. Principal la ACCOUNT ID thay vi OU
aws ram create-resource-share --region ap-southeast-1 \
  --name probe-acct --no-allow-external-principals \
  --resource-arns <tgw-arn> --principals <spoke-account-id>

# 3. OU bang ARN DAY DU
aws ram create-resource-share --region ap-southeast-1 \
  --name probe-ou --no-allow-external-principals \
  --resource-arns <tgw-arn> \
  --principals arn:aws:organizations::<MGMT_ID>:ou/o-tvkzhcq3yh/ou-o5ci-fz0yuca3
```

Phép đo 3 có một giả thuyết đứng sau, và nó **chỉ là giả thuyết**: principal kiểu OU cần ARN đầy đủ, mà ARN đó nhúng `o-tvkzhcq3yh` bên trong; `ou-o5ci-fz0yuca3` trần không mang thông tin tổ chức nào. Nếu console gửi ID trần thì câu chữ khớp chính xác. Chưa đo.

Loại được mà không cần chạy: `FeatureSet` của tổ chức. RAM org sharing đòi `ALL`, và tổ chức này đang chạy 4 SCP — SCP chỉ tồn tại khi FeatureSet là `ALL`.

#### Kết quả đo, và một phép đo suýt bị đọc nhầm

Phép đo 1 chạy trước, ở `lz-network`, và trả về `NoSuchEntity`. Đọc vội thì đó là *"thiếu service-linked role — đây là nguyên nhân"*. Nhưng `AWSServiceRoleForResourceAccessManager` nằm ở **management account**; hỏi nó từ một member account thì `NoSuchEntity` là câu trả lời đúng cho một câu hỏi khác. Chạy lại từ management: role **có**, tạo `2026-09-01T08:29:15Z`.

> Một phép đo chỉ có nghĩa cùng với **danh tính của người chạy nó**. `aws sts get-caller-identity` phải đi kèm, không phải chạy sau khi đã kết luận. Đây là lần thứ hai trong cùng phiên một kết quả suýt được đọc như bằng chứng cho điều nó không nói (lần trước: lỗi 48, `PROJECT` gán cứng).

Bộ đo cuối, tất cả từ **management account**, và điểm mấu chốt là **không cần Transit Gateway** — `create-resource-share` nhận share chỉ có principal, nên nó tách hẳn việc kiểm principal khỏi việc gắn resource:

| Phép đo | Kết quả |
|---|---|
| `describe-organizational-unit ou-o5ci-fz0yuca3` | `Workloads` — OU có thật |
| `create-resource-share --principals 761558631239` | `OperationNotPermittedException` |
| `create-resource-share --principals <ou-arn day du>` | `UnknownResourceException: ... in unknown organization` |

Không có resource nào trong hai lệnh sau. Nên **lỗi 55 không phải chuyện của `AssociateResourceShare`** như đã ghi — nó là chuyện RAM không phân giải được tổ chức, và `associate` chỉ tình cờ là chỗ nó lộ ra trước.

Hai thông báo khác nhau là **một điều kiện nhìn từ hai phía**: với `--no-allow-external-principals`, RAM phải tra tổ chức để xác nhận principal nằm bên trong. Không tra được thì với account ID nó nói *"chỉ share được trong tổ chức của bạn"*, với OU nó nói *"unknown organization"*.

Đã xác nhận đủ: service-linked role có, trusted access bật từ `2026-08-20`, FeatureSet `ALL`, OU tồn tại, chỉ `FullAWSAccess` trên root và OU, caller là management với quyền admin. **Nguyên nhân vẫn chưa biết** — đây là chỗ ticket AWS Support bắt đầu, và bản ticket đã được viết lại quanh phép đo tối giản này thay vì quanh Transit Gateway.

#### Thí nghiệm có đối chứng: đổi đúng một biến

| Share | Principal | Kết quả |
|---|---|---|
| `--no-allow-external-principals` | account ID trong org | `OperationNotPermittedException` |
| `--no-allow-external-principals` | OU ARN đầy đủ | `UnknownResourceException: unknown organization` |
| `--allow-external-principals` | **cùng account ID đó** | `ACTIVE` |
| `--allow-external-principals` | `associate-resource-share --principals` account thứ hai | `ASSOCIATING`, `"external": true` |

Cùng management account, cùng region, cùng phút. Biến duy nhất khác nhau là `allowExternalPrincipals`.

**Hai kết luận trước đó đổ tiếp:**

1. `AssociateResourceShare` **không** bị chặn như một thao tác — nó chạy ngay khi share không cần tra tổ chức. Lỗi 55 khoanh vùng quanh đúng cái lệnh đang thử lúc đó, chứ không quanh điều kiện thật.
2. Terraform **không** bị chặn. `aws_ram_resource_share` có `allow_external_principals`, nên cả ba resource RAM đều biểu diễn được. Câu *"trình tự duy nhất RAM chấp nhận là trình tự Terraform không tạo ra được"* ở mục 7y sai.

Và `"external": true` cho `169873795883` — một account **đang ở trong** `o-tvkzhcq3yh` — là bằng chứng trực tiếp nhất: RAM không nhận ra thành viên tổ chức của chính nó.

#### Suýt viết code cho một phép đo ở account khác

Bốn phép đo trên đều chạy từ **management account**. Tôi lấy kết quả đó và viết code cho `demo/network-lz-full` — bộ code chỉ có **một** provider và bắt buộc chạy bằng credential của `lz-network`, vì lỗi 51.

Người dùng hỏi *"chạy code terraform trên quyền account network ah"*, và câu hỏi đó lộ ra rằng đường external chưa từng được thử ở chính account sẽ chạy nó. RAM share phải do **chủ sở hữu resource** tạo, mà TGW thuộc `lz-network` — nên nếu account đó không tạo được external share thì toàn bộ commit `35ba554` là code cho một đường đi chưa ai đo.

Đo lại từ `436908791055`: `ACTIVE`. Code dùng được.

> Đây là **lần thứ ba trong cùng một phiên** một kết quả suýt được đọc tách khỏi danh tính của người chạy nó — sau `get-role` ở lz-network và `describe-transit-gateways` sau khi destroy. Ba lần, ba cơ chế khác nhau, cùng một hình dạng: phép đo đúng, câu hỏi khác.

Còn **một ô chưa chạm**: `associate-resource-share --resource-arns` trên share external, từ `lz-network`. Không đo được nếu không có TGW, nên phải để lộ ra lúc apply — và cách trả giá rẻ nhất cho phép thử đó là chạy `-target`:

```bash
terraform apply \
  -target=aws_ram_resource_association.tgw \
  -target=aws_ram_principal_association.spoke_accounts
```

Bốn resource, không NAT, không attachment, **$0/ngày**. Kết quả: `aws_ram_resource_association.tgw[0]` tạo xong sau 3 giây trên `tgw-082f15acfc5988a70`. Ô cuối cùng đóng lại, và đường external không còn chỗ nào là suy đoán.

> `-target` bị Terraform cảnh báo là *"không dùng cho việc thường ngày"*, và cảnh báo đó đúng. Nhưng ở đây có một bước **thủ công bắt buộc nằm giữa** hai nửa của config — chấp nhận lời mời RAM, làm ở account khác — nên chia apply theo phụ thuộc thật lại là cách trung thực nhất. Không có `-target`, apply đầu tiên sẽ dựng cả hub rồi mới chết ở StackSet, vì `check` block **chỉ cảnh báo chứ không chặn**.

> **Bài học cuối của chuỗi này:** năm giả thuyết đầu đều sinh ra từ việc đọc thông báo lỗi. Cái trả lời được câu hỏi sinh ra từ việc **đổi một biến và giữ nguyên mọi thứ khác** — một thí nghiệm, không phải một cách đọc.
>
> Điều kiện để làm được thí nghiệm đó: phép thử phải **rẻ**. Khi mỗi lần thử là mười phút `terraform apply`, tôi đoán. Khi phát hiện `create-resource-share` chạy được mà không cần resource nào, mỗi phép thử còn ba giây — và bốn phép thử sau đó làm xong việc mà sáu vòng apply không làm nổi.
>
> Câu hỏi đáng hỏi sớm không phải *"nguyên nhân là gì"* mà *"phép thử rẻ nhất tách được hai khả năng này là gì"*.

> **Bài học, lần thứ ba trong cùng một vấn đề:** một thông báo lỗi mô tả **triệu chứng**, và tôi liên tục đọc nó như **nguyên nhân**. Mỗi lần như vậy đều sinh ra một bản vá nhắm vào chỗ không sai, một mục tài liệu khẳng định điều không đúng, và một vòng apply mười phút.
>
> Dấu hiệu nhận ra sớm: nếu tôi viết được nguyên nhân **mà không chạy lệnh nào**, thì cái tôi vừa viết là diễn giải câu chữ, không phải kết quả đo.

---

### 7aa. Lỗi 57 — tag của account khác là thứ bạn không nhìn thấy

Pha 2 chạy xong với **`0 added, 0 changed`**, và `check "remote_attachments_wired"` báo `0/1`. Nhưng attachment thì có thật, `available`, đã kiểm bằng mắt một phút trước đó.

Code tìm attachment bằng cách đối chiếu tag `Name = "<project>-tgwa-<spoke>"` — tag mà template CloudFormation đặt ở account đích. Đo từ `lz-network`:

```
tgw-attach-0ae14ea96b14b8bcd   761558631239   "tags": []
tgw-attach-07b41c6971fdc86fe   436908791055   8 tag, Name = quh11-net-tgwa-app-dev
tgw-attach-0be8c72c6d17ba6b5   436908791055   8 tag, Name = quh11-net-tgwa-egress
```

**Tag trên resource chia sẻ thuộc về account đã tạo chúng.** Chủ sở hữu TGW nhìn thấy attachment, nhưng không nhìn thấy tag do account spoke đặt. Phép đối chiếu đó không phải chậm một nhịp — nó **không bao giờ khớp**.

Và đây là phần tệ hơn lỗi: thông báo của `check` nói *"thường chỉ là thứ tự, chạy lại `terraform apply` một lần nữa"*. Lời khuyên đó, cho nguyên nhân thật này, là một **vòng lặp vô hạn** — apply lại bao nhiêu lần cũng ra `0/1`. Một chẩn đoán sai trong thông báo lỗi còn đắt hơn không có thông báo nào, vì nó tiêu thụ đúng thứ người đọc dùng để tự tìm ra sự thật.

#### Bản vá

Đối chiếu theo `ResourceOwnerId` — thứ luôn nhìn thấy được — thay vì tag, và lọc ngay ở API bằng `resource-owner-id`. `account_id` đã có sẵn trong `var.spokes`, nên không cần nhìn sang account kia chút nào.

Một data source **mỗi account**, không phải mỗi spoke, và khoá theo chính attachment id:

```hcl
data "aws_ec2_transit_gateway_attachments" "remote_by_account" {
  for_each = local.wire ? toset(distinct([for v in local.remote_spokes : v.account_id])) : toset([])
  filter { name = "resource-owner-id"  values = [each.value] }
  ...
}

locals {
  remote_attachments_ready = local.wire ? toset(flatten([
    for d in data.aws_ec2_transit_gateway_attachments.remote_by_account : d.ids
  ])) : toset([])
}
```

Khoá theo attachment id giải quyết luôn một lỗi chưa kịp xảy ra: **hai spoke trong cùng một account**. Khoá theo tên spoke thì cả hai khoá cùng trỏ vào một attachment — một cái bị nối hai lần, một cái không bao giờ được nối.

#### `verify.sh` báo 7 đạt 0 lỗi cho một mạng chưa thông

Cùng lúc đó `./verify.sh` cho `7 dat 0 loi 3 bo qua`. Mọi mục của nó — kể cả mục 7 chạy lệnh thật qua SSM — đều nhắm vào spoke **nội bộ**. Spoke ở account khác không có mục nào, nên bảng kết quả xanh trong khi một VPC đã khai báo đang không nhận được gói tin nào.

Đã thêm mục `6c`, đối chiếu theo `ResourceOwnerId` và kiểm `Association.TransitGatewayRouteTableId` của từng attachment thuộc account khác.

> **Bài học:** hai lớp kiểm chứng — `check` block và `verify.sh` — cùng có mặt, cùng chạy, và cùng không thấy. Cái thứ nhất thấy nhưng chỉ đường sai; cái thứ hai không nhìn tới. Một bộ kiểm chứng chỉ bao được phạm vi mà người viết nó **nghĩ tới**, và ở đây phạm vi đó dừng lại đúng ở ranh giới account.

---

### 7ab. Kết quả: bốn mắt xích phải chạy ở phía account kia

Chốt lại phần cross-account, vì nó có một hình dạng lặp lại đáng nhớ hơn từng lỗi riêng lẻ.

`demo/network-lz-full` chỉ có **một** provider, trỏ vào `lz-network`. Nhưng bốn việc dưới đây bắt buộc phải thực thi **trong account spoke** — không phải vì thiếu quyền, mà vì chúng thuộc về chủ sở hữu tài nguyên bên đó:

| Việc | Ai làm được | Cách giải |
|---|---|---|
| Chấp nhận lời mời RAM | Chỉ account nhận | CLI một lần, `ram_invitations_accepted` xác nhận |
| Tạo VPC + subnet + attachment | Chỉ account chủ VPC | StackSet `SERVICE_MANAGED` chạy CloudFormation **trong** account đó |
| Gắn Route 53 Profile vào VPC | Chỉ account chủ VPC | `AWS::Route53Profiles::ProfileAssociation` trong chính template đó |
| Nối attachment vào route table | Chỉ chủ sở hữu **TGW** | Ngược lại — bắt buộc ở `lz-network`, spoke không làm được |

Ba dòng đầu cùng một bài toán, và **CloudFormation giải được hai trong ba** chỉ vì nó vốn đã chạy bên trong account đích. Đó là lý do thật để dùng StackSet ở đây, không phải vì "triển khai hàng loạt".

Dòng thứ tư đi ngược chiều, và chính vì thế nó không thể gộp vào template.

#### Đo được, không suy luận

```
RAM share (external)         quh11-net-tgw, ACTIVE
Loi moi RAM                  5/5 account ASSOCIATED
StackSet                     3/3 CURRENT

Spoke o account khac         attachment            duong ve hoc CIDR
  761558631239 app-prod      tgw-attach-0ae14ea9   10.20.0.0/16   active
  458195083898 security      tgw-attach-0da4b75e   10.8.0.0/16    active
  654560867047 logarchive    tgw-attach-0dfe8596   10.100.0.0/16  active

DNS profile cross-account    quh11-net-app-prod -> vpc-09f0b15348602d8d0, COMPLETE
Endpoint tap trung           ec2messages -> 10.1.31.184, 10.1.30.12 (trong security VPC)
Gateway endpoint S3          IP cong khai - dung, no lam viec o route table
Khong lot firewall           rtb-spokes / rtb-egress / rtb-ingress deu sach
Ingress                      NLB -> TGW -> firewall -> app, HTTP 200
verify.sh                    28 dat, 0 loi, 0 bo qua
```

Management account **không** có spoke: StackSet không với tới (lỗi 59), và account đó đang chạy một cụm EKS trong default VPC `172.31.0.0/16` mà chủ sở hữu muốn giữ. Nó vẫn nằm trong `share_tgw_with_accounts` — thấy TGW, tự cắm được khi cần. Dải `10.101.0.0/16` giữ trong bảng CIDR doc 17 như đã cấp phát nhưng chưa dùng, để không ai cấp lại cho việc khác.

> **Điều còn lại là một khoản nợ, không phải một thành tựu:** `allow_external_principals = true` trên share của Transit Gateway. Nó ở đó **chỉ vì lỗi 56** — RAM không phân giải được tổ chức. Ranh giới tổ chức không còn bảo vệ share này; danh sách account trong `var.spokes` và `var.share_tgw_with_accounts` là thứ duy nhất chặn. Khi AWS Support sửa xong, đổi `ram_use_external_principals` về `false` là gỡ cả khoản nợ đó lẫn bước bấm nhận thủ công.

---

### 7ac. Lỗi 58 — cùng một script, cùng một hạ tầng, 8 lỗi

`./verify.sh` vừa cho `17 đạt, 0 lỗi`. Chạy lại vài phút sau, không đụng gì vào hạ tầng: **`6 đạt, 8 lỗi`**.

```
✗ THIEU duong ve! Spoke ra duoc Internet nhung khong nhan duoc goi tra loi
✗ appliance_mode_support = None (PHAI la enable)
✗ Firewall status =
✗ Khong tim thay gateway endpoint
✗ IP ra Internet = ''
```

Đọc y hệt một sự cố lớn. Thực tế: shell còn credential của `761558631239` từ lệnh `route53profiles` chạy ngay trước đó.

Script đọc **state** từ thư mục hiện tại — luôn đúng — nhưng gọi **AWS** bằng credential đang có trong shell. Hai nguồn đó lệch nhau thì mọi câu hỏi đều gửi sang nhầm account, và câu trả lời rỗng được đọc thành "thiếu".

Dấu hiệu nằm ngay trong output nếu đọc kỹ: mục 1 kiểm `quh11-net-app-prod-vpc` chứ không phải `app-dev` — VPC do StackSet tạo *trong account kia*. Và mục 6c báo "không có spoke ở account khác", đúng theo nghĩa đen: từ chỗ đứng của `app-prod`, attachment ấy là của chính nó.

#### Bản vá: chặn ngay từ dòng đầu

Thêm `output "account_id"`, và cả `verify.sh` lẫn `teardown.sh` đối chiếu nó với `aws sts get-caller-identity` rồi **dừng** nếu lệch.

`teardown.sh` nguy hiểm hơn nhiều: nó gọi `terraform destroy`. Chạy nhầm account thì destroy không xoá được gì, và phần xác nhận sẽ báo **`DA SACH`** — vì nó đang hỏi một account không có gì để mất. Bạn tin là đã xoá xong, trong khi ~$30/ngày vẫn chạy.

> **Đây là lần thứ tư trong phiên này** một phép đo đúng trả lời nhầm câu hỏi: `get-role` ở `lz-network`, `describe-transit-gateways` sau khi destroy, tag của account spoke (lỗi 57), và giờ là cả một bộ kiểm chứng.
>
> Ba lần đầu tôi sửa bằng cách nhớ hỏi thêm "chạy ở account nào". Lần này mới sửa đúng chỗ: **script tự hỏi câu đó**. Một quy ước phải nhớ thì sẽ có lần quên; một `exit 1` thì không.

---

### 7ad. Lỗi 59 — ba dấu hiệu, không cái nào chỉ đúng chỗ

Người dùng chọn dựng VPC spoke cho cả ba account nền tảng, kể cả management. Tôi đã nêu trước rằng StackSet có thể không với tới management, và apply xác nhận — nhưng **cách** nó báo mới là điều đáng ghi:

| Nguồn | Nói gì |
|---|---|
| `terraform apply` | `unexpected state 'FAILED', wanted target 'SUCCEEDED'. last error: %!s(<nil>)` |
| `list-stack-instances` | Ba dòng `CURRENT`, và **không có dòng nào** cho `609320954321` |
| CloudFormation | Không có `StatusReason` để đọc |

`%!s(<nil>)` là Go in ra một con trỏ rỗng — provider hỏi lý do, CloudFormation không trả, và chuỗi định dạng lộ ra nguyên trạng. Không nguồn nào nói *"management account không được hỗ trợ"*.

Nguyên nhân: **StackSet `SERVICE_MANAGED` triển khai theo cây tổ chức, và AWS loại management account ra khỏi mọi đợt triển khai đó.** Management nằm trực tiếp dưới root, không thuộc OU nào.

Dấu hiệu duy nhất trỏ đúng chỗ lại là dấu hiệu **vắng mặt**: một account có trong `deployment_targets` mà không có dòng nào trong `list-stack-instances`. Phải biết trước là nó *phải* có ở đó thì mới thấy nó thiếu.

#### Bản vá: tách "được StackSet dựng" khỏi "là spoke"

Thêm `manual_vpc = true` vào spoke. Spoke đó bị loại khỏi `aws_cloudformation_stack_set_instance`, nhưng **vẫn** nằm trong `remote_spokes` — nên RAM vẫn share cho nó, và attachment của nó vẫn được nối vào route table khi xuất hiện. Hai việc đó thuộc về chủ sở hữu TGW, không liên quan gì tới cách VPC được tạo ra.

VPC thì dựng bằng stack thường, chạy tại chỗ:

```bash
terraform output -raw spoke_template > spoke-vpc.json
# roi tu chinh management account:
aws cloudformation create-stack --stack-name quh11-net-spoke-vpc \
  --template-body file://spoke-vpc.json --parameters ...
```

`output "spoke_template"` đọc thẳng `aws_cloudformation_stack_set.spoke[0].template_body` chứ không giữ bản sao. Hai bản template rời nhau ra là kiểu lỗi không ai phát hiện cho tới khi một spoke được dựng khác mọi spoke còn lại.

> **Bài học:** tôi đoán đúng giới hạn này *trước* khi apply, và vẫn phải trả một vòng apply hỏng để biết nó có thật. Đó là đánh đổi chấp nhận được — điều không chấp nhận được là nếu tôi đã ghi nó vào tài liệu như một sự thật mà chưa đo.
>
> Và một lần nữa: ba nguồn thông tin, không nguồn nào chỉ đúng chỗ. Thứ giải được là **so sánh cái có với cái đáng lẽ phải có** — cùng phương pháp đã dùng ở lỗi 45 (Security Hub 0 member) và lỗi 57.

---

### 7ae. Lỗi 60 — một lần dọn sạch bị báo là thất bại

`terraform destroy` xoá 143 resource. Mười phép kiểm cụ thể của `teardown.sh` đều xanh — NAT, EIP, firewall, TGW, endpoint, load balancer, EC2. Rồi lệnh quét theo tag liệt kê **19 ARN còn lại**, trong đó có đúng những thứ vừa được báo là sạch:

```
✓ Transit Gateway
✓ NAT Gateway
✓ EC2 dang chay
...
✗ Con lai:
    .../transit-gateway/tgw-082f15acfc5988a70
    .../natgateway/nat-01a74fd61ee4e7fef
    .../instance/i-0b44a8b160aa0f8e3
```

Script kết luận `CON 1 muc chua xoa`.

**`resourcegroupstaggingapi` trả về cả resource đã xoá**, trong một khoảng sau đó. TGW đã xoá vẫn ở `deleted`, EC2 ở `terminated`, NAT ở `deleted` — không còn tính tiền, nhưng vẫn còn tag. Mười phép kiểm kia lọc theo **trạng thái đang hoạt động** nên không thấy chúng.

Đo lại từng cái:

```
tgw-082f15acfc5988a70   -> deleted
i-0b44a8b160aa0f8e3     -> terminated
quh11-net-tgw           -> DELETED   (khong con ACTIVE)
```

#### Bản vá

Khi mười phép kiểm đều xanh, lệnh quét tag chuyển thành **thông tin cần xác nhận** (vàng) thay vì lỗi (đỏ), kèm lệnh phân biệt `deleted` với `available`. Khi đã có phép kiểm hỏng, nó vẫn là manh mối để tìm tiếp.

> **Cùng họ với lỗi 48, 57 và 58** — bốn lần trong một phiên, một phép đo đúng trả lời cho một câu hỏi khác. Lần này câu hỏi lệch là: `resourcegroupstaggingapi` trả lời *"ARN nào từng mang tag này"*, còn tôi đọc nó như *"cái gì còn sống"*.
>
> Điểm chung của cả bốn: nguồn dữ liệu **đúng và đầy đủ**, chỉ là phạm vi của nó không trùng với phạm vi câu hỏi. Không có cách nào phát hiện bằng cách nhìn kỹ hơn vào kết quả — phải hỏi *"lệnh này thật ra trả lời điều gì"*.

---

### 7af. Lỗi 61 — kéo một giá trị "biết sau apply" vào chỗ "phải biết ở plan"

Khi sửa cho trường hợp không còn spoke local, tôi cho `count` của `aws_lb_target_group_attachment.app_direct` phụ thuộc vào `local.nlb_target_ip`, mà local đó đọc `aws_instance.test[...].private_ip`.

```
Error: Invalid count argument
The "count" value depends on resource attributes that cannot be
determined until apply
```

**Code cũ đã đúng và tôi làm nó sai:** nó dùng `var.enable_test_instances` trong `count` — một biến, biết ở plan — và chỉ chạm thuộc tính resource ở `target_id`, nơi giá trị chưa biết là hoàn toàn bình thường.

Bọc trong `try()` không cứu được: Terraform từ chối vì `count` **tham chiếu tới** một thuộc tính chưa biết, không phải vì giá trị đó lỗi.

#### Bản vá — tách điều kiện khỏi giá trị

```hcl
# Chi dua tren bien va cau truc var.spokes -> biet o plan
use_local_target = var.enable_test_instances && local.first_spoke != null

# Doc thuoc tinh resource -> biet sau apply, va chi dung o target_id
nlb_target_ip = local.use_local_target
  ? aws_instance.test[local.first_spoke].private_ip
  : try(values(local.remote_test_ips)[0], null)
```

> **Cùng họ với lỗi 50**, và đó mới là điều đáng ghi: lỗi 50 cũng là một `for_each` phụ thuộc vào thứ chưa biết ở plan, và tôi đã viết hẳn một mục về nó. Biết luật không ngăn được việc vi phạm luật — vì lúc sửa, tôi đang nghĩ về *"làm sao chọn đúng target"*, không nghĩ về *"biểu thức này được đánh giá lúc nào"*.
>
> Dấu hiệu nhận ra sớm, rẻ hơn một vòng plan: mỗi khi viết `count` hoặc `for_each`, đọc lại biểu thức và hỏi **"có tên resource nào trong này không"**. Có là hỏng, bất kể bọc gì quanh nó.

---

### 7ag. Lỗi 62 — hai phép kiểm biến mất, không để lại dấu vết

Đổi tên spoke local từ `app-dev` thành `probe`. `verify.sh` chạy xong, `24 đạt 0 lỗi`. Nhưng mục 1 và 2 **trống hoàn toàn** — không dấu tích, không dấu chéo, không dòng nào:

```
1. Spoke khong co duong ra Internet rieng

2. Route mac dinh cua spoke tro Transit Gateway

3. Duong VE trong egress VPC (loi hay gap nhat)
  ✓ Public subnet co duong ve: 10.0.0.0/8 → TGW
```

Script lọc VPC theo tag `${PROJECT}-app-*-vpc`. Không VPC nào khớp, `for` lặp qua tập rỗng, thân vòng lặp không chạy. Bảng kết quả **ngắn đi hai dòng** và không có gì cho biết là đã bỏ qua cái gì.

Cùng lúc, mục 7 bỏ qua với lý do **sai**:

```
7. Luong thuc te
  - Khong co EC2 test (enable_test_instances = false)
```

`enable_test_instances` đang là `true`, và EC2 `probe` tồn tại — output `instances` in ra nó ngay phía trên. Nguyên nhân thật: script tìm `.["app-dev"].id` và `.["app-prod"].private_ip`, hai tên gán cứng.

#### Vì sao đây là kiểu tệ nhất

Một phép kiểm **hỏng** thì báo đỏ. Một phép kiểm **biến mất** thì không báo gì, và tổng số vẫn là "0 lỗi". Người đọc phải nhớ rằng đáng lẽ phải có 26 dòng chứ không phải 24 — tức phải biết trước câu trả lời để phát hiện là mình không có câu trả lời.

Cùng họ với **lỗi 48** (`PROJECT` gán cứng) và **lỗi 57** (đối chiếu theo tag của account khác): cả ba đều là **đoán theo một quy ước** thay vì hỏi nguồn biết sự thật.

#### Bản vá

Thêm `output "spoke_names"` — danh sách spoke nội bộ, lấy từ chính config. `verify.sh` lặp trên đó, và **báo đỏ** nếu một spoke đã khai mà không tìm thấy VPC:

```bash
SPOKES=$(terraform output -json spoke_names | jq -r '.[]')
for sp in $SPOKES; do
  vpc=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-${sp}-vpc" ...)
  [[ "$vpc" == "None" ]] && { bad "Spoke '$sp' khai trong tfvars nhung khong tim thay VPC"; continue; }
```

EC2 điều khiển phép đo lấy **cái đầu tiên có thật**, không gọi tên cứng. Và lý do bỏ qua giờ phân biệt được "không có spoke nội bộ" với "`enable_test_instances = false`" — một lý do sai trong thông báo còn đắt hơn không có thông báo, vì nó làm người đọc đi sửa đúng thứ không hỏng.

> **Bài học:** mỗi khi script lọc theo một chuỗi có dạng tên, hỏi *"chuỗi này do ai quyết định"*. Nếu câu trả lời là "quy ước của chúng tôi" thì nó sẽ sai vào ngày ai đó đổi quy ước — và cách nó sai sẽ là **im lặng**, không phải báo lỗi.

---

### 7ah. Lỗi 63 — "mạng không thông" mà mạng không hỏng

`verify.sh` mục 7c chạy lần đầu:

```
✗ app-dev    (169873795883) 10.10.0.10:80  khong thong (000TIMEOUT)
✗ app-prod   (761558631239) 10.20.0.10:80  khong thong (000TIMEOUT)
✓ logarchive (654560867047) 10.100.0.10:80 THONG
✗ security   (458195083898) 10.8.0.10:80   khong thong (000TIMEOUT)
```

Ba trên bốn hỏng. Phản xạ đầu tiên là đi tìm lỗi định tuyến — mà mục 6c ngay phía trên đã xanh cả tám dòng.

**Câu trả lời nằm ở cổng 22**, dòng ngay dưới mỗi dòng đỏ:

```
Ncat: 0 bytes sent, 0 bytes received in 0.02 seconds.
```

Đó là thông báo `ncat` in khi **kết nối thành công** rồi đóng — timeout thì in `Connection timed out`, bị chặn thì `Connection refused`. Cổng 22 thông trên **cả bốn** spoke. Gói tin từ `probe` tới được cả bốn EC2 ở bốn account khác nhau.

Mạng không hỏng. **Nginx không chạy.**

#### Một cuộc đua không ai thiết kế

```
pha 3   StackSet tao VPC + attachment + EC2   -> EC2 boot NGAY
pha 4   moi noi attachment vao route table
```

Giữa hai pha, spoke **không có đường ra Internet**: attachment tồn tại nhưng chưa thuộc route table nào. `UserData` chạy `dnf install -y nginx` đúng vào khoảng đó và thất bại — im lặng, vì cloud-init không báo về đâu cả.

Instance vẫn `running`, SSH vẫn bật, chỉ không ai nghe cổng 80. `logarchive` chạy được vì `max_concurrent_count = 1` khiến các stack instance dựng tuần tự, và nó là cái **cuối cùng** — boot vừa lúc pha 4 xong.

Thắng thua đổi mỗi lần dựng.

#### Hai bản vá, hai loại

**Bỏ hẳn cuộc đua.** `python3` có sẵn trong AL2023, không cần mạng. Dùng `python3 -m http.server` qua systemd thay cho nginx, và phép đo không còn phụ thuộc thứ tự các pha. `dnf install` cho `nmap-ncat`/`bind-utils` giữ lại nhưng kèm `|| true` — tiện ích, không phải điều kiện.

**Làm thông báo nói đúng.** Dòng cũ là `curl ... || echo TIMEOUT`, nên "cổng bị từ chối" và "gói tin không tới nơi" in ra **y hệt nhau**. Giờ lấy mã thoát:

| | |
|---|---|
| `rc=7` | Không kết nối được → cổng đóng, **dịch vụ** chưa chạy |
| `rc=28` | Hết thời gian → gói tin không tới nơi, lỗi **mạng** |

> **Bài học:** thông báo cũ gộp hai nguyên nhân trái ngược vào một chữ, và chữ đó — `TIMEOUT` — trỏ vào cái sai. Nếu tôi tin nó, tôi đã đi sửa firewall và route table cho một hệ thống định tuyến hoàn toàn đúng.
>
> Thứ cứu được là một dòng tôi **không** thiết kế để chẩn đoán: phép thử cổng 22, vốn chỉ để chứng minh firewall chặn được thứ security group cho phép. Nó vô tình trở thành đối chứng — cùng đường đi, cùng đích, khác cổng. **Một phép đo chỉ có ý nghĩa khi có cái gì đó để so sánh.**

---

### 7ai. Lỗi 64 — bản vá cho lỗi 63 làm hỏng phép đo của lỗi 63

Lỗi 63 kết thúc bằng hai bản vá: bỏ phụ thuộc Internet lúc boot, và **làm thông báo nói đúng** bằng cách lấy mã thoát của `curl`. Chạy lại:

```
✗ app-dev    10.10.0.10:80 khong thong (ket qua: )
✗ app-prod   10.20.0.10:80 khong thong (ket qua: )
✗ logarchive 10.100.0.10:80 khong thong (ket qua: )
✗ security   10.8.0.10:80  khong thong (ket qua: )
```

Bốn trên bốn, và `logarchive` — cái **đang chạy được** ở lần trước — giờ cũng đỏ. Chuỗi kết quả **rỗng**.

Lệnh chẩn đoán mới là:

```bash
curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://$ip/; echo " rc=$?"
```

`run_remote` nhúng lệnh đó vào JSON của SSM:

```bash
--parameters "commands=[\"$cmd\"]"
```

Dấu nháy kép trong `echo " rc=$?"` phá vỡ JSON. SSM từ chối cả lệnh, `StandardOutputContent` về rỗng — và chuỗi rỗng đi qua mọi nhánh `if` để rơi vào `else`, in ra "không thông".

Sửa: bỏ nháy kép, `echo rc=$?` không cần nháy nào cả.

> **Bài học, và nó khó chịu hơn bản thân lỗi:** tôi sửa một thông báo chẩn đoán *vì nó gộp hai nguyên nhân thành một*, và bản sửa đó tạo ra **nguyên nhân thứ ba** — cũng in ra đúng dòng đỏ ấy.
>
> Dấu hiệu lẽ ra phải thấy ngay: `logarchive` chuyển từ xanh sang đỏ mà **không ai đụng vào nó**. Một phép đo đổi kết quả trong khi đối tượng đo không đổi thì thứ hỏng là phép đo, không phải đối tượng. Đó cũng chính là cách lỗi 63 được tìm ra — và tôi vẫn mất một vòng để áp dụng lại nó.
>
> Quy tắc rút ra: lệnh gửi qua `ssm send-command` **không được chứa dấu nháy kép**. Nháy đơn an toàn; tốt nhất là không cần nháy nào.

---

### 7aj. Lỗi 65 — ba chỉ số xanh, và không chỉ số nào trả lời câu hỏi

Sửa `UserData` trong template của StackSet, `terraform apply`. Bốn EC2 ở bốn account vẫn chạy code cũ.

Ba lần tôi đoán, ba lần đo, ba lần sai:

| Đoán | Đo được | Kết luận rút ra |
|---|---|---|
| Instance còn `OUTDATED` | `CURRENT` cả bốn | Rút lại — tưởng đã lan |
| `CURRENT` = đã nhận template mới | Trang HTTP vẫn là nginx cũ | `CURRENT` không nói template nào |
| Không có `UPDATE` nào chạy | Hai `UPDATE SUCCEEDED` | Operation chạy, instance không đổi |

Ba chỉ số của lớp điều phối — `terraform apply` báo `1 changed`, operation `SUCCEEDED`, instance `CURRENT` — đều **đúng theo nghĩa của chúng**, và không cái nào trả lời *"instance đang chạy template nào"*.

Thứ cho câu trả lời là **một byte dữ liệu thật từ bên trong instance**:

```
curl http://10.100.0.10/
<h1>logarchive</h1>...      <- trang nginx CU
```

#### Vì sao

`UpdateStackSet` cập nhật **định nghĩa** stack set. Nó chỉ triển khai xuống instance khi lệnh gọi kèm `DeploymentTargets` và `Regions` — mà provider Terraform không gửi. Nên operation thành công thật, chỉ là nó không chạm tới stack nào.

`UpdateStackInstances` cũng không giải quyết: nó cập nhật **giá trị tham số**, dùng lại template mà instance đang có. Chạy bốn lần, mỗi lần 19 giây, `SUCCEEDED` cả bốn, không gì thay đổi — thời gian chạy đã là dấu hiệu: thay một EC2 không thể mất 19 giây.

Đường duy nhất chắc chắn:

```bash
terraform apply -replace='aws_cloudformation_stack_set_instance.spoke["<ten>"]'
```

Xoá stack ở account đích rồi tạo lại từ template hiện tại. Đổi lại: VPC và attachment bị dựng lại, **attachment ID đổi**, nên phải `terraform apply` thêm một lần để pha 4 nối route cho ID mới.

> **Bài học:** khi ba chỉ số cùng báo xanh mà hành vi vẫn sai, đừng tìm chỉ số thứ tư. Chúng đều đo lớp điều phối; câu hỏi thì ở lớp bên dưới. Một `curl` vào chính thứ mình nghi ngờ đã kết thúc chuyện trong mười giây, sau khi bốn vòng đọc trạng thái không kết thúc được gì.
>
> Dấu hiệu để nhận ra sớm: **thời gian**. Bốn operation "thay EC2" hoàn tất trong 19 giây mỗi cái. Một thao tác vật lý mà xong nhanh hơn thời gian nó cần để xảy ra thì nó đã không xảy ra.

---

## 7ak. Lỗi 66–73 — dựng lớp vận hành, và một thông báo phủ bốn nguyên nhân

Bối cảnh: [doc 25](./25-Van-hanh-Network-Hang-Ngay.md) — lớp `ops/` có state riêng, chạm layer cha đúng một điểm.

### Cái 403 mất năm vòng

Nối lớp ops vào bucket state cho ra `HeadObject ... 403 Forbidden` năm lần liên tiếp, **cùng một chuỗi ký tự**, với bốn nguyên nhân hoàn toàn khác nhau:

| Lần | Nguyên nhân thật | Thứ tôi đoán |
|---|---|---|
| 1 | Key ở prefix mới (`network-ops/`) ngoài vùng được cấp | Đúng — nhưng chỉ là một phần |
| 2 | Prefix thật là `demo-network-lz-full/`, không phải `network/` | Tôi đoán `network/` — sai |
| 3 | Thiếu `ListBucket` cho key chưa tồn tại | Đúng cơ chế, sai ca này |
| 4–5 | **Sai danh tính** — biến môi trường đè lên `profile` | Mất ba vòng mới tới |

Không có gì trong thông báo phân biệt được bốn thứ đó. Nó không in đường dẫn đã thử, không nhắc `ListBucket`, không nhắc prefix — và 403 thì đọc y hệt "sai credential", nên chỗ đầu tiên ai cũng đi kiểm là vai trò và profile, hai thứ đang đúng.

**Phép đo phân biệt** (giá như làm từ vòng một):

```bash
aws s3api head-object --bucket <b> --key '<prefix>/terraform.tfstate'   # A: đã tồn tại
aws s3api head-object --bucket <b> --key '<prefix>/khong-ton-tai'       # B: chưa tồn tại
```

A được, B 403 → thiếu `ListBucket`. A cũng 403 → sai danh tính. Hai lệnh chia bốn nguyên nhân thành hai nhóm ngay lập tức.

> **Bài học:** khi một thông báo phủ nhiều nguyên nhân, đừng chọn nguyên nhân *hợp lý nhất*. Tìm phép đo tách chúng ra. `backend-hint.sh` giờ in sẵn phép đo này kèm cách xử lý từng nhánh.

### Lỗi 67 — điều kiện đúng cho lệnh này, vô nghĩa cho lệnh kia

`tf-backend` cấp `s3:ListBucket` kèm `Condition = { StringLike = { "s3:prefix" = ["<tên>/*"] } }` để mỗi account chỉ thấy prefix của mình. Hợp lý — cho lệnh **list**.

Nhưng `s3:prefix` chỉ tồn tại trong ngữ cảnh của yêu cầu list. `HeadObject` không phải lệnh list, nên khoá đó vắng mặt, `StringLike` không khớp, và `ListBucket` coi như không được cấp. Mà S3 chỉ trả 404 cho object không tồn tại **khi người gọi có `ListBucket`**.

Kết quả: một quyền được cấp đúng ý đồ lại tạo ra một cái bẫy chỉ nổ **một lần cho mỗi layer mới** — đúng lúc người ta đang dựng thứ gì đó lần đầu và ít có cơ sở nhất để nghi ngờ hạ tầng cũ.

Cách đi qua: tạo sẵn object rỗng một lần (`aws s3api put-object` không có `--body`). Cách sửa gốc: bỏ điều kiện, đổi lấy việc account đó nhìn thấy **tên key** của prefix khác — không đọc được nội dung. Đánh đổi nhỏ nhưng có thật, nên nó là lựa chọn chứ không phải bản vá hiển nhiên.

### Lỗi 71 — `&&` không short-circuit, và nó nằm im ở năm chỗ

```hcl
if r.expires_num != null && local.today_num > r.expires_num
```

Trong hầu hết ngôn ngữ, vế phải không chạy khi vế trái false. **HCL tính cả hai.** Nên dòng trên vẫn so sánh với `null` và dừng plan.

Cùng giả định sai đó nằm ở bốn chỗ nữa, tất cả dùng `can(...)` ở vế trái làm chắn: kiểm port, bao hàm CIDR của app, phát hiện route đi tắt, và kiểm địa chỉ nội bộ trong DNS. Không chỗ nào báo lúc viết — chúng chờ dữ liệu đi qua đúng nhánh đó.

Cách sửa không phải né `null` mà là **loại nó khỏi phép tính**: rule vĩnh viễn nhận mốc `99991231`. Bốn chỗ còn lại bọc **cả biểu thức** trong `try(..., false)`, với giá trị dự phòng chọn theo hướng báo to chứ không im lặng — CIDR không đọc được thì coi như nằm ngoài spoke, địa chỉ không đọc được thì coi như ra ngoài.

### Lỗi 72 và 73 — hai phép kiểm trả lời câu hỏi khác

`terraform output bootstrap_done` báo `false` sau khi cấu hình đã đúng: `output` in giá trị **đã lưu trong state**, tính từ lần apply trước. Nó trả lời trung thực cho *"lần chạy trước thấy gì"*, không phải *"bây giờ thế nào"* — cùng họ với lỗi 65.

`wire-backends.sh` có sẵn phép kiểm "layer trên đĩa mà không có trong state", đúng thứ lẽ ra phải cảnh báo rằng `demo/network-lz-full/ops` chưa được đăng ký. Nó không kêu, vì vòng lặp chỉ quét `landing-zone/*/`. **Một phép kiểm tồn tại, chạy, báo xanh, và không nhìn vào chỗ cần nhìn** — chủ đề lặp lại nhiều nhất trong cả tài liệu này.

> **Bài học chung của tám lỗi này:** năm trong tám không phát ra lỗi ở nơi có vấn đề. Chúng phát ở nơi *phát hiện ra* vấn đề — muộn hơn, và thường trong một layer không ai vừa sửa gì.

---

## Liên quan
| | |
|---|---|
| [25 – Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md) | Lớp `ops/` — bối cảnh của lỗi 66–73 |
| [23 – Lớp phát hiện](./23-Lop-Phat-Hien-GuardDuty-SecurityHub-Log-Archive.md) | Cơ chế GuardDuty / Security Hub / log archive — kết quả của mục 7h–7p |
| [TEARDOWN](../landing-zone/TEARDOWN.md) | Chiều ngược lại — hai cổng khoá, parking account |
| [RUNBOOK](../landing-zone/RUNBOOK.md) | Làm gì, theo thứ tự nào — bảng lỗi ở cuối |
| [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md) | Vì sao chọn DIY, 4 SCP |
| [20 – Vận hành LZ](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Quy ước email, account baseline |
| [06 mục 1b](./06-Aws-Landing-Zone.md) | Root user vs organization root |
