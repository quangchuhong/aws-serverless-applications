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
| 74 | `install_routes = no` viết trong `ipsec.conf` — **không có tác dụng và không có lỗi** | Đó là tuỳ chọn của `charon`, chỉ đọc từ `strongswan.conf`. Đặt nhầm file thì strongSwan bỏ qua, im lặng. Hệ quả: SA vừa lên là charon tự cắm route `0.0.0.0/0` vào bảng 220, máy mất đường ra Internet — mất luôn SSM, tức mất đường vào để xem vì sao | **Lỗi code** | *(mục 7al)* |
| 75 | `systemctl enable A \|\| systemctl enable B \|\| true` nuốt **mọi** thất bại | Dấu `true` ở cuối là để "không sao nếu tên unit khác" — nhưng nó cũng nuốt cả trường hợp **không có unit nào**. Script chạy tiếp, kết thúc bằng dòng "xong", và không có daemon nào chạy | **Lỗi code** | *(mục 7al)* |
| 76 | Tunnel `DOWN` với `StatusMessage` **rỗng** ở cả hai đầu | EIP được gắn **sau** khi instance boot. `auto=start` bắn IKE ngay từ IP công khai tạm; AWS không có customer gateway nào khớp địa chỉ đó nên vứt gói tin **và không ghi gì**. Nhìn từ phía AWS, triệu chứng này không phân biệt được với "daemon không chạy" | **Lỗi code** | *(mục 7al)* |

| 77 | `dnf install strongswan` → `Unable to find a match` trên Amazon Linux 2023 | **AL2023 không có gói `strongswan`** — không phải tên khác, không phải phiên bản khác, không có. AWS cắt phần lớn gói mạng khỏi repo AL2023. Đây là nguyên nhân **đầu tiên** của hai đường hầm `DOWN`; lỗi 74–76 nằm sau chỗ này và chưa bao giờ chạy tới | **Giới hạn nền tảng** | *(mục 7al)* |

| 78 | Đường hầm `UP`, hai SA `ESTABLISHED`, `curl` tới NLB trả về `000` | Route đặt lên interface `vti` **thiếu `src`**. Nhân chọn địa chỉ nguồn = địa chỉ đầu tiên của chính interface đó — `169.254.100.2`, **địa chỉ trong đường hầm**. NLB nhận được kết nối và trả lời về địa chỉ đó, nhưng route tĩnh của VPN chỉ công bố `172.16.0.0/16` nên gói trả lời không có đường về. Chiều đi hoàn hảo, chiều về không tồn tại | **Lỗi code** | *(mục 7am)* |
| 79 | Dải NLB công bố cho đối tác chỉ phủ **một trong hai** subnet NLB | `partner_nlb_cidr = cidrsubnet(vpc, 8, 100)` — đúng subnet ở AZ đầu, bỏ `10.9.101.0/24` ở AZ thứ hai. Chú thích cách đó ba dòng đã ghi đủ **cả hai dải**. Tên DNS của NLB trả về cả hai địa chỉ, nên gọi được hay không **tuỳ vào địa chỉ nào được chọn** | **Lỗi code** | *(mục 7am)* |
| 80 | Mục `=== IPsec SA ===` trong `vpn-check` in ra **rỗng** trong khi hai SA đang chạy | `strongswan statusall \|\| ipsec statusall`: trên Ubuntu lệnh thứ nhất tồn tại, **thoát 0**, và không in gì. `\|\|` không bao giờ chạy tới vế sau. Cùng hình dạng với lỗi 75 | **Lỗi code** | *(mục 7am)* |

| 81 | `ResourceInUse: Target group ... is currently in use by a listener` giữa `apply` | `port` của target group là thuộc tính **bắt tạo lại**. Thứ tự mặc định xoá cái cũ trước, trong khi listener vẫn trỏ vào nó. Đảo bằng `create_before_destroy` thì vấp rào thứ hai: tên target group cố định nên cái mới trùng tên cái cũ. Phải **cả hai**: ghép cổng vào tên *và* `create_before_destroy` | **Lỗi code** | *(mục 7am)* |

| 82 | Listener 8080 tạo xong, target `healthy`, `curl` **hết giờ** — cổng 80 vẫn `200` | **NLB có security group**, và nó lọc lưu lượng tới **từng listener**. SG của layer cha chỉ mở `partner_service_port`. Lớp ops sở hữu listener nhưng không sở hữu SG, nên mở cửa mà quên mở khoá. Gói tin bị vứt **trước** listener: không log, không lỗi, và mọi phép kiểm khác đều xanh | **Lỗi code** | *(mục 7am)* |

| 83 | Bỏ khối `ingress` lồng nhau đi, `apply` báo `InvalidPermission.Duplicate` | Trong provider AWS, `ingress`/`egress` của `aws_security_group` là **Optional+Computed**: bỏ hẳn khối đi nghĩa là *"thôi không quản nữa"*, **không phải** *"xoá hết rule"*. Không sinh diff, rule cũ nằm nguyên trong AWS, và resource rời đụng đúng nó. Build mới không gặp — chỉ bản đã apply mới phải gỡ tay một lần | **Giới hạn công cụ** | *(mục 7am)* |

| 84 | `plan-check.sh` báo `Khong lay duoc AMI gia` — không nói vì sao | `2>/dev/null` nuốt stderr của `aws ssm get-parameter`. Hết token, sai region và thiếu `ssm:GetParameter` cho ra **cùng một dòng**, trong khi ba cách sửa khác hẳn nhau. Lần thứ ba của cùng khuyết điểm trong một phiên (75, 80) | **Lỗi code** | *(mục 7an)* |

| 85 | `plan-check.sh` báo **7 lỗi** cho một code hoàn toàn bình thường | Mọi khẳng định của nó có dạng *"plan trên state rỗng phải tạo resource X"*. Chạy trên máy **đã apply thật**, `plan` so với hạ tầng đang chạy và trả `No changes` — đúng, nhưng không trả lời câu hỏi đang được hỏi. Bảy dòng lỗi nói về bảy resource khác nhau, đọc như bảy vấn đề độc lập | **Lỗi code** | *(mục 7an)* |

| 86 | `10.10.0.0/14` trong bảng cấp phát CIDR **không phải một CIDR hợp lệ** | Một `/14` bắt đầu ở bội số của 4 ở octet thứ hai, nên nó chỉ có thể là `10.8.0.0/14` hoặc `10.12.0.0/14`. Khoảng `10.10`–`10.13` mà bảng mô tả không viết được thành một `/14` nào. Sống sót nhiều tháng ở **sáu file** vì chưa có công cụ nào phân tích nó — con người đọc phần trong ngoặc và hiểu đúng ý | **Lỗi thiết kế** | *(mục 7ao)* |

| 87 | **Chín layer** gắn `Environment = "shared"`, trong khi tag policy do chính repo khai chỉ nhận `dev/staging/prod/sandbox` | Tag policy của AWS mặc định chỉ **báo** không tuân thủ, không chặn — nên chín layer gắn một giá trị mà chính tổ chức từ chối, và không apply nào đỏ. `billing-guard` là layer duy nhất đúng, kèm chú thích *"hạ tầng quản trị, không phải sandbox"* | **Lỗi code** | *(mục 7ao)* |

| 88 | `terraform init` báo `state data in S3 does not have the expected content` — *"Calculated checksum:"* để trống | Bảng khoá DynamoDB giữ thêm một dòng **digest** (`LockID = "<bucket>/<key>-md5"`) cho mỗi key, và dòng đó **không biến mất khi object S3 bị xoá**. Xoá state rồi tạo lại một object rỗng thì md5 tính ra khác digest cũ. Thông báo đổ lỗi cho **độ trễ của S3** và bảo đợi vài phút — đợi bao lâu cũng không hết. Chính chú thích trong `tf-backend/outputs.tf` đã dặn `aws s3 rm` mà không nhắc tới dòng digest | **Lỗi thiết kế** | *(mục 7ap)* |

| 89 | `wire-backends.sh` báo `CO 1 LAYER TREN DIA` rồi in **11 dòng** | Danh sách gom bằng dấu cách rồi in bằng `for m in $missing`. Một thư mục rác có dấu cách trong tên bị tách vụn: **con số đúng, danh sách sai** — và danh sách là thứ người ta đọc | **Lỗi code** | `07dd751` |

| 90 | `terraform plan` ở lớp `ops` báo `ResourceNotFoundException: Requested resource not found` về **bảng khoá vẫn đang tồn tại** | Backend S3 địa chỉ bảng khoá bằng **tên**, và một tên luôn được giải trong account của **người gọi**. Resource policy trên bảng cho phép account khác gọi nhưng không giúp họ **gọi tên** được. Layer cha có `profile` trỏ về account chủ nên chạy bình thường; lớp `ops` thiếu dòng đó nên hỏng — và hỏng ở `plan`, không phải `init`, vì init không lấy khoá | **Lỗi thiết kế** | *(mục 7aq)* |

| 91 | ~~`prod_guard` được gắn vào không gì cả~~ — **chẩn đoán sai của chính tôi** | Tôi đọc một bản in `ou_ids` thành cây OU phẳng rồi kết luận `"Workloads/Production"` không giải được. Cây **lồng nhau**, khoá tồn tại, và `list-policies-for-target` cho thấy `prod_guard` đang gắn. Cơ chế im lặng (`try(...,null)` + lọc `!= null`) là **có thật và vẫn đáng chặn**, nhưng nó chưa từng nổ ở đây | **Đọc sai bằng chứng** | *(mục 7ar)* |

| 92 | `lint.sh` **từ chối tên OU có thật** và chấp nhận tên không tồn tại | `OUS` liệt kê `NonProd`, `Prod`, `Analytics` — không tên nào do `ou_structure` sinh ra (thật là `Non-Production`, `Production`, `Data Analytics`). Tệ hơn: `ALLOCATED` cũng keyed như vậy và tra bằng `if alloc:` không có nhánh `else`, nên đổi catalog sang tên thật làm **tắt hẳn** phép kiểm "CIDR nằm trong dải của OU" mà không in một chữ | **Lỗi code** | *(mục 7ar)* |

| 93 | `unmapped_accounts` **rỗng ở đúng lần apply tạo account** | Nó tính từ `data.aws_organizations_organization`, mà data source được đọc **trước** khi account tồn tại. Lưới an toàn cho câu "có account nào chưa ai khai phạm vi không" trả lời "không" ở đúng lần chạy duy nhất mà câu đó quan trọng — và `paste_permission_sets` cùng lúc in ra danh sách thiếu ba account vừa tạo | **Lỗi thiết kế** | *(mục 7ar)* |

| 94 | SCP `baseline` cấm `s3:PutAccountPublicAccessBlock` cho **mọi** principal — nên **không ai bật được** account-level public access block, kể cả lớp hardening viết ra để bật nó | Đó là **một API cho cả bật lẫn tắt**: nó đặt cả bốn cờ dù true hay false, và không có condition key nào đọc được giá trị bên trong request. Chú thích ghi *"không ai được mở"* với nghĩa "không ai được tắt bảo vệ"; kết quả thật là **bảo vệ chưa bao giờ được đặt**. SCP canh một căn phòng trống, và triệu chứng duy nhất là chữ `SKIP` trong `SweepResult` của từng account | **Lỗi thiết kế** | *(mục 7as)* |

| 95 | `SweepResult` báo `SKIP:ClientError` — không nói lỗi gì | `type(e).__name__` trả về `ClientError` cho **mọi** lời từ chối của AWS. AccessDenied, SCP chặn, tham số sai, dịch vụ chưa bật — bốn nguyên nhân, bốn cách sửa, một chữ. Lần thứ **năm** của cùng khuyết điểm (75, 80, 84, và một lần của chính tôi trong cùng phiên) | **Lỗi code** | *(mục 7as)* |

**83/95 là lỗi trong code hoặc thiết kế của repo**, không phải người dùng làm sai. Đó là lý do file này tồn tại. Mục 91 là ngoại lệ theo chiều khác: không phải lỗi của repo mà là **một chẩn đoán sai của tôi**, giữ lại nguyên vẹn vì ba thay đổi nó kéo theo đã kịp vào repo trước khi bị bác bỏ.

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

`plan-check.sh` của `landing-zone/network` báo **19 lỗi**. Sau hai vòng vá, chín tổ hợp plan đều xanh với con số thật — 65, 91, 136, 139, 130, 175, 178 resource, gồm cả nhánh Palo Alto và F5 chưa từng được kiểm. Nhưng mục 3 vẫn trượt cả chín khẳng định:

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

Bốn phép đo trên đều chạy từ **management account**. Tôi lấy kết quả đó và viết code cho `landing-zone/network` — bộ code chỉ có **một** provider và bắt buộc chạy bằng credential của `lz-network`, vì lỗi 51.

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

`landing-zone/network` chỉ có **một** provider, trỏ vào `lz-network`. Nhưng bốn việc dưới đây bắt buộc phải thực thi **trong account spoke** — không phải vì thiếu quyền, mà vì chúng thuộc về chủ sở hữu tài nguyên bên đó:

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

`wire-backends.sh` có sẵn phép kiểm "layer trên đĩa mà không có trong state", đúng thứ lẽ ra phải cảnh báo rằng `landing-zone/network/ops` chưa được đăng ký. Nó không kêu, vì vòng lặp chỉ quét `landing-zone/*/`. **Một phép kiểm tồn tại, chạy, báo xanh, và không nhìn vào chỗ cần nhìn** — chủ đề lặp lại nhiều nhất trong cả tài liệu này.

> **Bài học chung của tám lỗi này:** năm trong tám không phát ra lỗi ở nơi có vấn đề. Chúng phát ở nơi *phát hiện ra* vấn đề — muộn hơn, và thường trong một layer không ai vừa sửa gì.

---

## 7al. Lỗi 74–76 — hai đường hầm `DOWN` với `StatusMessage` rỗng

`terraform apply` xong sạch: **50 added, 1 changed, 0 destroyed**. `verify.sh` báo **53 đạt, 1 lỗi** — và một lỗi duy nhất đó là VPN:

```
|  13.215.221.92 |  DOWN  |   |
|  52.77.185.28  |  DOWN  |   |
```

Cột thứ ba **rỗng**. Đó không phải chi tiết phụ, đó là toàn bộ thông tin có được. AWS ghi `StatusMessage` khi họ *nhận được* gói IKE rồi từ chối — sai PSK, lệch bộ thuật toán, không khớp traffic selector đều có chữ. Rỗng nghĩa là **chưa từng có gói IKE nào đến nơi**.

Việc đó thu hẹp phạm vi rất mạnh: mọi thứ từ IKE_SA_INIT trở đi đều **không phải** nghi phạm. Chỉ còn ba khả năng — không có daemon, gói tin không ra khỏi máy, hoặc gói tin ra nhưng mang **sai địa chỉ nguồn**.

Chưa có `/var/log/user-data.log` trong tay nên tôi chưa biết cái nào. Nhưng đọc lại chính file mình viết thì tìm được **ba khiếm khuyết, mỗi cái đủ để tự nó tạo ra đúng triệu chứng này**. Cả ba đều đã sửa; log sẽ nói cái nào đã nổ trước.

### Lỗi 74 — đúng tuỳ chọn, sai file

```
# ipsec.conf
conn %default
    installpolicy=yes
    # install_routes=no  <- KHÔNG BAO GIỜ ĐƯỢC ĐỌC Ở ĐÂY
```

`install_routes` là tuỳ chọn của **charon**, chỉ đọc từ `strongswan.conf`. Trong `ipsec.conf` nó không phải lỗi cú pháp — chỉ là một khoá không ai hỏi tới. strongSwan khởi động bình thường, không cảnh báo gì.

Điều tệ hơn: chú thích trong file **khẳng định** tuỳ chọn đó đang có tác dụng. Người đọc sau — kể cả tôi, hai tuần sau — không có lý do gì để nghi ngờ.

Hệ quả không nằm ở lúc khởi động mà ở **giây SA lên**. Với `leftsubnet=0.0.0.0/0`, charon cắm ngay một route `0.0.0.0/0` vào bảng 220. Máy mất đường ra Internet, SSM rớt, và **đường vào để chẩn đoán biến mất đúng lúc cần nó nhất**.

### Lỗi 75 — dấu `|| true` nuốt cả trường hợp không lường trước

```bash
systemctl enable strongswan 2>/dev/null || systemctl enable strongswan-starter 2>/dev/null || true
```

Ý định thì hợp lý: tên unit khác nhau giữa Debian và Fedora, thử cả hai. Nhưng `|| true` không phân biệt *"cái thứ nhất không có, cái thứ hai có"* với *"không có cái nào"*. Trường hợp thứ hai — gói cài hỏng, hoặc bản đóng gói dùng tên thứ ba — chạy qua **không một dòng nào trong log**, và script kết thúc bằng `=== xong ===`.

Đây là lỗi 27 mặc bộ đồ khác: **im lặng đúng bằng im lặng của thành công**.

Sửa: tìm tên unit **trước**, hỏng to nếu không có cái nào, và in ra mọi unit có chữ `swan` để câu hỏi tiếp theo đã có sẵn câu trả lời.

Cùng họ, cách đó vài dòng: `dnf install -y strongswan` có thể trả về 0 mà gói vẫn không nằm trên máy. Giờ hỏi lại bằng `rpm -q`.

### Lỗi 76 — địa chỉ đúng, thời điểm sai

Đây là cái tôi nghi nhất, vì nó giải thích được **chính xác cột `StatusMessage` rỗng**.

Terraform tạo instance **trước**, gắn EIP **sau** — thứ tự bắt buộc, và đúng là thứ tự đã cắt vòng phụ thuộc EIP → CGW → VPN → `user_data` → instance ở mục trước. Nhưng giữa hai bước đó, máy vẫn có một IP công khai: cái AWS tự phát vì `associate_public_ip_address = true`.

`user_data` chạy ngay khi boot. `auto=start` bắn IKE ngay khi charon lên. Nếu điều đó xảy ra trước khi EIP được gắn, gói tin đến VPN endpoint mang địa chỉ nguồn là **IP tạm**. AWS không có customer gateway nào khớp địa chỉ đó, nên họ vứt gói tin — và không ghi gì cả, vì với họ đây là gói tin lạ từ Internet, không phải một đối tác cấu hình sai.

Cả hai đầu `DOWN`, `StatusMessage` rỗng. Y hệt "daemon không chạy".

### Lỗi 77 — và điều đáng nói nhất về ba lỗi trên

Dựng lại máy giả lập xong, log trả lời trong mười dòng đầu:

```
+ dnf install -y strongswan nmap-ncat bind-utils tcpdump
No match for argument: strongswan
Error: Unable to find a match: strongswan
+ echo 'KHONG CAI DUOC strongswan tu repo mac dinh.'
+ exit 1
```

**Amazon Linux 2023 không có gói `strongswan`.** Không phải tên khác, không phải phiên bản khác — AWS cắt phần lớn gói mạng khỏi repo AL2023. Mọi máy khác trong bộ này chạy AL2023 và không sao; máy này cần một thứ AL2023 không có.

Đáng nói: **không lỗi nào trong ba lỗi 74–76 là nguyên nhân.** Cả ba nằm ở đoạn sau `dnf`, và chưa bao giờ được chạy tới. Chúng là ba khiếm khuyết thật, sẽ nổ lần lượt sau khi cái này được sửa, nhưng chúng không gây ra thứ đang nhìn thấy.

Ba lần đoán, ba lần trượt — và câu trả lời nằm trong `user-data.log` suốt từ đầu, ở dòng thứ mười. Cái `dnf install || exit 1` bản gốc đã bắt đúng và dừng đúng ngay lần chạy đầu tiên. Phép đo thì có sẵn; chỉ là chưa ai đọc nó.

> Đó là bài học lớn hơn cả ba lỗi kia gộp lại, và nó lặp lại lần thứ tư trong tài liệu này: **khi có một phép đo chưa đọc, đừng suy luận từ triệu chứng.** `StatusMessage` rỗng thu hẹp được phạm vi rất đẹp — và thu hẹp đúng — nhưng nó không bao giờ chỉ ra được "gói không tồn tại trong repo". Chỉ có log nói được điều đó.

Sửa: máy giả lập chuyển sang **Ubuntu**, nơi `strongswan` nằm trong `main` và cũng là nền tảng AWS dùng trong tài liệu cấu hình VPN của họ. Đường dẫn AMI thành biến `partner_sim_ami_ssm_parameter` để đổi được mà không sửa code.

Đây là **máy duy nhất trong cả bộ không chạy AL2023**. Ràng buộc đó ghi ở đầu `strongswan.sh.tftpl` và trong `description` của biến, vì thêm một dòng `dnf` vào file đó sau này sẽ hỏng không rõ lý do.

### Kết quả

```
|  13.215.221.92 |  UP |    |
|  52.77.185.28  |  UP |    |

Security Associations (2 up, 0 connecting):
  Tunnel1[1]: ESTABLISHED, 172.16.0.79[47.130.178.166]...13.215.221.92
  Tunnel2[2]: ESTABLISHED, 172.16.0.79[47.130.178.166]...52.77.185.28
```

Cả hai đường hầm lên, hai SA `ESTABLISHED`. Bốn lỗi, bốn vòng thay máy giả lập.

Hai dòng đó cũng xác nhận ngược lại hai chỗ trong lỗi 76: `172.16.0.79[47.130.178.166]` — interface mang IP riêng, danh tính IKE là EIP. Đúng cặp mà cuộc đua EIP–charon có thể phá, và là lý do phải chặn nó chứ không đoán sau.

Unit hoá ra là **`strongswan-starter`** — tên của Debian/Ubuntu. Nhánh thứ hai trong vòng dò của lỗi 75; với `|| true` cũ thì nhánh đó vẫn chạy đúng, nhưng nhánh "không có unit nào" thì im lặng đi qua.

Kèm theo: `apt-get -o DPkg::Lock::Timeout=600`. `cloud-init` và `unattended-upgrades` cùng chạy lúc máy vừa lên và giữ khoá `dpkg`; thiếu dòng này thì `apt-get` chết vì `Could not get lock` — và triệu chứng phía AWS lại đúng là hai đường hầm `DOWN`, không liên quan gì tới IPsec.

> **Điểm chung của lỗi 74–76:** không cái nào phát ra lỗi. Một tuỳ chọn đặt nhầm file, một `|| true` quá rộng, một cuộc đua vài chục giây — và cả ba cùng đổ về một triệu chứng duy nhất không mang thông tin. `terraform plan`, `terraform validate`, `terraform fmt` và phép quét nội suy `.tftpl` đều xanh. Cấu hình IPsec trong `user_data` là **phần duy nhất của cả repo không có gì kiểm được ngoài việc thử**.

Sửa xong, script tự trả lời ở cuối `user-data.log`: chờ SA tối đa 60 giây, rồi hoặc in `=== IKE SA DA LEN ===`, hoặc in 40 dòng `journalctl` kèm cách đọc ba thông báo hay gặp nhất. Kết luận nằm ở cuối file người ta vừa mở, không phải ở lệnh tiếp theo họ phải nghĩ ra.

**Dựng lại chỉ máy giả lập** — EIP là resource riêng nên customer gateway và VPN connection không đổi, phía AWS không biết có gì xảy ra:

```bash
terraform apply -replace='aws_instance.partner_sim[0]'
```

---

## 7at. Lỗi 96–98 — pipeline chạy lần đầu, và ba cách hỏng nằm sau một cái `cd`

Lần chạy đầu của CodePipeline vending. `Nguon` xanh, `Lint` xanh, `A_tao_account / Plan` đỏ.

### Lỗi 96 — build chết sau `init`, log đọc như là `plan` hỏng

CodeBuild in ra khối lệnh đã hỏng. Khối đó chứa cả `terraform plan` lẫn `terraform apply`, nên đọc thoáng qua thì đây là một lỗi của Terraform. Nó không phải.

Lọc log theo mốc:

```
== Layer: landing-zone/account-baseline
== init  (key: account-baseline/terraform.tfstate)
   14 resource trong state
```

Rồi hết. `== plan` — dòng đầu tiên bên trong khối bị tố cáo — **không bao giờ được in**. Nghĩa là khối đó chết ở lệnh trước nó:

```bash
cd "${LAYER_DIR}"
```

`LAYER_DIR` là đường dẫn tương đối. CodeBuild chạy **mọi lệnh trong cùng một shell**, nên `cd` ở khối trước vẫn còn hiệu lực. Khối thứ hai `cd landing-zone/account-baseline` lần nữa, từ bên trong chính thư mục đó, tìm `landing-zone/account-baseline/landing-zone/account-baseline`.

Sửa: `cd "${CODEBUILD_SRC_DIR}/${LAYER_DIR}"` ở cả hai khối.

Điều đáng ghi không phải cái `cd`. Là chuyện **CodeBuild in ra khối lệnh chứ không in ra dòng lệnh**, nên một lỗi ở dòng đầu hiện ra mang hình dạng của dòng cuối. Cách đọc đúng là tìm dòng `echo` **cuối cùng thật sự được in**, rồi xem cái gì đứng ngay sau nó trong code — chứ không phải đọc khối lệnh mà CodeBuild trưng ra.

### Lỗi 97 — `terraform.tfvars` không có trong repo, và điều đó *không* gây lỗi

Tìm ra khi kiểm tại sao stage A hỏng. Không phải nguyên nhân của lỗi 96, nhưng sẽ là nguyên nhân của lần chạy ngay sau khi vá 96.

`.gitignore` loại `terraform.tfvars` — đúng, nó chứa account ID, email, mã phòng ban. Nên bản checkout của CodeBuild không có nó.

Với `backend.tf` thì thiếu là hỏng ngay và chốt chặn state rỗng bắt được. Với tfvars thì:

| Layer | Biến bắt buộc |
|---|---|
| account-baseline | *không có* |
| network | *không có* |
| config-detective | *không có* |
| permission-sets | `management_account_id` |

Ba trong bốn layer mọi biến đều có `default`. `terraform plan` chạy **thành công** với `catalog = {}`, `ou_ids = {}`, `spokes = {}` trên **đúng state thật** — tức mô tả việc xoá mọi thứ đang có. Chốt chặn state rỗng không thấy gì lạ: state có đủ 14 resource, chỉ có biến là rỗng.

Đây là kiểu hỏng tệ nhất trong tập: không thông báo, không cảnh báo, và kết quả *hợp lệ*. Thứ duy nhất đứng giữa nó và một lần xoá thật là một người đọc `Plan: 0 to add, 0 to change, 14 to destroy` và hiểu con số đó có nghĩa gì.

Chữa: bucket riêng (`tfvars_bucket`, bật versioning), buildspec kéo về trước `init`, **thiếu file là lỗi cứng**. Đẩy bằng `./push-tfvars.sh`.

Bài học lặp lại từ lỗi 88 và 90: **một giá trị mặc định hợp lý là một cách hỏng im lặng.** `default = {}` trên `catalog` trông vô hại khi đọc file khai báo biến; nó chỉ nguy hiểm khi có một đường chạy nào đó quên nạp tfvars, và đường đó ra đời sau.

### Lỗi 98 — hai statement "thu hẹp" không thu hẹp gì

Kiểm lại IAM khi thêm quyền đọc bucket tfvars, và thấy hai chỗ trong cùng policy `chay-terraform`:

```hcl
# statement rộng
Action = [..., "s3:*", "sts:AssumeRole", ...]
Resource = ["*"]

# statement hẹp, viết sau, kèm comment giải thích tại sao nó hẹp
Sid      = "SangAccountMang"
Action   = ["sts:AssumeRole"]
Resource = [var.network_deploy_role_arn]
```

IAM là **hợp** của các Allow. Statement hẹp không hạn chế được statement rộng trong cùng policy — nó chỉ *đọc như* một ràng buộc. Cũng vậy với `DocGhiState`, cái được viết ra để giới hạn pipeline vào đúng bốn khoá state.

Đã sửa: gỡ `sts:AssumeRole` khỏi statement rộng, nên `SangAccountMang` giờ là nguồn cấp duy nhất và thêm một account đích là thêm một dòng hiện ra trong code review. Với bucket tfvars, dùng **Deny tường minh** thay vì trông chờ vào việc không khai Allow. Với `s3:*` và bốn khoá state: chưa sửa được nếu không biết chính xác bốn layer tạo những bucket nào, nên comment đã được viết lại để nói đúng sự thật thay vì nói đúng ý định.

Dạng lỗi: **một comment mô tả ý định của tác giả, đặt cạnh code không thực hiện ý định đó.** Nguy hiểm hơn không có comment, vì người đọc sau sẽ tin nó và không kiểm.

### Lỗi 99 — thu hẹp quyền state xuống từng khoá S3, và quên hẳn bảng khoá

Sau khi vá 96 và 97, stage A đi qua được `init`, in `158 dong` tfvars, `14 resource trong state`, `== plan` — rồi hỏng:

```
Error: Error acquiring the state lock
Error message: operation error DynamoDB: PutItem, https response error
PLAN HONG
```

Trong toàn bộ policy `chay-terraform` không có **một dòng DynamoDB nào**. Tôi viết `DocGhiState` để giới hạn pipeline vào đúng bốn khoá state, viết `ListState` cho `s3:ListBucket`, viết `MaHoaState` cho KMS — và không viết gì cho bảng khoá.

Điều làm nó khó thấy: **`terraform init` không lấy khoá.** Nên mọi thứ trước đó đều xanh, state đọc được, số resource đếm đúng, và lỗi chỉ nổ ở `plan`. Cùng một hình dạng với lỗi 90, chỉ khác nguyên nhân: lần đó bảng nằm ở account khác, lần này quyền không tồn tại.

Và thông báo không nhắc gì tới quyền. Ba dòng đều nói về DynamoDB, nên nó đọc như **một khoá đang bị ai đó giữ** — cách hiểu tự nhiên nhất, và sai. Nếu thật sự có khoá bị giữ, Terraform in thêm một khối `Lock Info` với `ID / Path / Who / Created`; không có khối đó nghĩa là chưa bao giờ có khoá nào, tức là không đọc được bảng chứ không phải bảng đang bận.

Chữa: thêm `dynamodb:GetItem/PutItem/DeleteItem/DescribeTable` trên đúng ARN bảng khoá. `DeleteItem` là cần chứ không phải cho đủ — thiếu nó thì lần chạy đầu tiên bị huỷ giữa chừng sẽ để lại một khoá không ai gỡ được, và `terraform force-unlock` cũng không gỡ nổi.

**Bài học:** "quyền đọc/ghi state" trong backend S3 không phải một thứ, mà là **bốn** — object S3, `ListBucket` trên bucket, KMS key, và bảng khoá DynamoDB. Ba lần liên tiếp trong dự án này (lỗi 85, 90, 99) chi phí đến từ việc chỉ nghĩ tới một hoặc hai trong bốn.

### Lỗi 100 — `profile` đúng trên laptop là `profile` sai trong CodeBuild

Stage A xanh, `No changes`. Stage B — stage đầu tiên đi sang account mạng — hỏng:

```
Error: failed to get shared config profile, default
```

Câu này không nhắc gì tới `vending_state`, tới `terraform_remote_state`, hay tới CodeBuild. Nó đến từ `var.vending_state` trong `network/terraform.tfvars`, khối cấu hình để layer `network` đọc state của `account-baseline`:

```hcl
vending_state = {
  backend = "s3"
  bucket  = "qh11-lz-tfstate-609320954321"
  key     = "account-baseline/terraform.tfstate"
  region  = "ap-southeast-1"
  profile = "default"        # <-- dòng này
}
```

Dòng `profile` **đúng** khi một người chạy: họ dùng credential của account mạng, nên đọc bucket state ở account management cần một profile khác. Trong CodeBuild thì ngược hẳn — credential gốc của nó *đã* là management, và provider mới là cái nhảy sang account mạng. Ở đó không những không cần profile, mà còn không thể có: container không có `~/.aws/config`.

Đây là dạng lỗi khác với 96–99. Không có gì viết sai. Cùng một file cấu hình phải phục vụ **hai danh tính khác nhau**, và giá trị đúng cho danh tính này là giá trị sai cho danh tính kia. Kho tfvars-qua-S3 (lỗi 97) giải quyết được chuyện *đưa* file tới CodeBuild, nhưng không giải quyết chuyện file đó **nên khác nhau** giữa hai nơi.

Chữa: `vending.tf` bỏ khoá `profile` khi `var.assume_role_arn != ""`. Điều kiện đó là dấu hiệu chắc chắn "đang chạy trong pipeline" — chính nó là thứ tách hai danh tính ra — nên không phải thêm một biến nữa để người ta phải nhớ đặt.

### Lỗi 101 — Route 53 Profiles là một namespace IAM thứ ba

Cùng một lần chạy stage B, sau khi qua được lỗi 100:

```
AccessDeniedException: User: arn:aws:sts::436908791055:assumed-role/
quh11-net-pipeline-deploy/lz-network-pipeline is not authorized to perform:
route53profiles:GetProfile ... because no identity-based policy allows
the route53profiles:GetProfile action
```

Policy của role đã có `route53:*` **và** `route53resolver:*`. Không đủ: `route53profiles:` là namespace thứ ba, dù trên console cả ba nằm dưới một tên dịch vụ.

Thông báo của AWS ở đây tốt — nó nói đúng tên action thiếu, nên sửa mất ba mươi giây. Cái khó là **đoán trước** rằng có một namespace thứ ba, và không có cách nào đoán ra ngoài việc chạy thử. Đó là lập luận cho việc lần chạy khô phải đi hết sáu stage trước khi một account thật đi qua: những lỗi kiểu này chỉ lộ ra khi có người thực sự gọi API.

### Lỗi 102 — bản vá của lỗi 98 làm hỏng stage E, và cái nó làm lộ ra

Stage B, C, D xanh. Stage E dừng với ba lỗi cùng lúc:

```
Error: failed to get shared config profile, default

Error: Cannot assume IAM Role
  with provider["...aws"].security, on versions.tf line 56
  IAM Role (arn:aws:iam::458195083898:role/OrganizationAccountAccessRole)
  cannot be assumed.
  ... is not authorized to perform: sts:AssumeRole on resource:
      arn:aws:iam::458195083898:role/OrganizationAccountAccessRole

Error: Cannot assume IAM Role
  with provider["...aws"].log_archive, on versions.tf line 68
  ... arn:aws:iam::654560867047:role/OrganizationAccountAccessRole
```

Lỗi thứ nhất là **lỗi 100 lặp lại** ở một layer khác: `config-detective/terraform.tfvars` cũng có `profile` trong `vending_state`. Bản vá hôm trước chỉ áp cho layer `network`, vì nó dùng `assume_role_arn != ""` làm tín hiệu "đang chạy trong pipeline" — tín hiệu đó không tồn tại ở đây.

Hai lỗi sau là **hậu quả trực tiếp của bản vá lỗi 98**. Hôm trước tôi gỡ `sts:AssumeRole` khỏi statement rộng và viết rằng đây là thay đổi duy nhất có rủi ro: *"nếu một layer nào đó assume một role tôi chưa biết, stage đó sẽ báo AccessDenied"*. `config-detective` có hai provider alias assume `OrganizationAccountAccessRole` ở account security và log archive.

Điều đáng ghi không phải là bản vá làm hỏng một stage. Là **cái nó làm lộ ra**: trước bản vá, policy cấp `sts:AssumeRole` trên `Resource = ["*"]`, nghĩa là pipeline này assume được `OrganizationAccountAccessRole` ở **mọi account trong tổ chức** — quyền admin đầy đủ ở khắp nơi, cấp cho một đường tự động, và không ai nhìn thấy vì nó ẩn trong một danh sách hai mươi action.

Việc thu hẹp không tạo ra quyền đó, nó chỉ khiến quyền đó phải được viết ra. Và ngay khi phải viết ra thì câu hỏi đúng hiện lên: *pipeline có nên assume `OrganizationAccountAccessRole` không?* Câu trả lời tốt hơn là tạo ở hai account đó một role hẹp, chỉ đủ cho Security Hub aggregator và bucket snapshot, rồi trỏ `cross_account_role` vào đó. Chưa làm, đã ghi lại trong mô tả biến `member_assume_role_arns`.

**Dạng lỗi:** một `Resource = ["*"]` không chỉ là quyền rộng — nó còn là **một câu hỏi không bao giờ được hỏi**. Thu hẹp nó gây ra vài lần hỏng ngắn, và đổi lại một danh sách mà người ta phải đọc.

Chữa lỗi 100 lần này theo hướng khác với layer `network`: hai layer `config-detective` và `permission-sets` chạy ở **chính** account management, nơi state nằm — nên `profile` không bao giờ cần, chứ không phải cần-tuỳ-ngữ-cảnh. Thêm `validation` từ chối thẳng khoá đó, để nó hỏng trên máy người khai kèm tên khoá, thay vì hỏng ở stage E vài ngày sau.

### Lỗi 103 — thứ tự stage không tách được hai việc trong cùng một `terraform apply`

Hai account đầu tiên đi qua pipeline. Stage A tạo xong cả hai trong 14 giây, rồi treo ba phút rưỡi ở `aws_cloudformation_stack_set_instance.spoke_network` trước khi hỏng.

Thiết kế sáu stage nói:

```
A tạo account  →  B chia sẻ TGW  →  C dựng VPC + attachment
```

Nhưng **A và C là cùng một layer** (`landing-zone/account-baseline`). Buildspec chạy `terraform apply` trên cả layer, nên stage A tạo luôn `spoke_network` — trước khi stage B kịp chia sẻ TGW. Stack ở account đích chờ một lời mời RAM chưa được gửi, hết `RamWaitSeconds`, rollback.

Thứ tự giữa các stage là thật. Thứ tự **bên trong** một stage thì không tồn tại: Terraform xếp theo phụ thuộc tài nguyên, và `spoke_network` phụ thuộc vào `aws_organizations_account` — nên nó chạy ngay sau, trong cùng một apply. Không có chỗ nào cho stage B chen vào.

Tôi đã viết trong README và doc 27 rằng *"khối `network:` khai được ngay từ đầu vì pipeline giải quyết bằng thứ tự stage"*, và cùng ngày còn sửa chú thích trong `accounts.yaml` để **gỡ** cảnh báo cũ về việc để trống khối đó. Cảnh báo cũ đúng; tôi gỡ nó dựa trên một niềm tin về thứ tự stage mà chưa bao giờ kiểm.

**Cách chữa đầu tiên tôi đưa ra cũng sai.** Tôi bảo bỏ khối `network:`, chạy một lượt để stage B chia sẻ TGW, rồi thêm lại. Nhưng `vending_handles.tgw_share` được suy ra từ `local.spokes_can_wire` — tức **chỉ những account có khối `network:`**. Bỏ khối đó đi là tự cắt mất đầu vào của chính bước mình cần. Lượt hai sẽ hỏng y hệt lượt một.

Chữa thật: stage A chạy `terraform apply -target=aws_organizations_account.this`. Đây là trường hợp `-target` sinh ra để giải quyết — một ràng buộc thứ tự **thật** giữa hai layer, không phải một lần chạy nhầm. Terraform in cảnh báo "plan không đầy đủ", và cảnh báo đó nên để nguyên: người duyệt stage A cần thấy rõ nó chỉ tạo account.

**Dạng lỗi:** một sơ đồ đúng ở mức khái niệm, sai ở mức thực thi. `A → B → C` mô tả đúng thứ tự *mong muốn*, và mọi tài liệu viết theo sơ đồ đó đều nhất quán với nhau — nhưng không có dòng code nào bắt buộc A dừng lại trước phần việc của C. Ba tài liệu cùng nói một điều sai không làm nó đúng hơn; chúng chỉ làm nó khó nghi ngờ hơn.

---

### Lỗi 104 — lớp chặn cuối trước cổng duyệt, chết im lặng từ ngày đầu

Buildspec có một cảnh báo dành cho trường hợp nguy hiểm nhất:

```bash
if grep -qE '^Plan: .* to destroy' tfplan.txt \
   && ! grep -qE '^Plan: .* 0 to destroy' tfplan.txt; then
  echo "!!! PLAN NAY CO RESOURCE BI XOA - doc tfplan.txt truoc khi duyet"
fi
```

`tfplan.txt` sinh ra từ `terraform show -no-color tfplan`. Và **`terraform show` trên một file plan không in dòng `Plan: N to add, ...`** — dòng đó do `terraform plan` in ra màn hình, không nằm trong bản `show`.

Nên điều kiện không bao giờ đúng. Cảnh báo chưa từng chạy một lần nào, kể cả nếu plan đòi xoá sạch hạ tầng.

Phát hiện ra nhờ một triệu chứng nhỏ: dòng `== tom tat` in ra rồi không có gì theo sau. Cái trống rỗng đó là thứ duy nhất lộ ra ngoài — và nó trông hoàn toàn bình thường, vì `grep ... || true` nuốt mã thoát.

Chữa: đếm theo `will be created` / `will be updated in-place` / `will be destroyed` / `must be replaced`, những chuỗi **thật sự** có trong bản `show`. Tính cả `must be replaced` ngang với xoá: một stack instance bị thay thế là stack ở account đích bị xoá rồi dựng lại — VPC, subnet, attachment đều ID mới.

**Dạng lỗi:** đây là lần thứ năm trong hai ngày, và là lần đắt nhất. Bốn lần trước — `--query` trả `None`, `sed` với `\|` trên BSD, mốc kết thúc chỉ phủ trường hợp hỏng, `describe-stack-set` thiếu tiền tố `StackSet.` — chỉ làm mất thời gian. Lần này thì một lớp kiểm soát an toàn báo "sạch" trong khi nó chưa bao giờ nhìn.

Điểm chung của cả năm: **một phép lọc không khớp trả về rỗng, và rỗng được đọc thành một câu trả lời.** Cách phòng duy nhất đã dùng được ở đây là thử ngược: viết một `tfplan.txt` giả có đủ bốn loại thay đổi rồi chạy đoạn đếm trên đó. Ba mươi giây, và nó nói ngay điều mà sáu tuần chạy thật không nói.

---

### Lỗi 105 — vá đúng một nửa: `DependsOn` gắn cho một resource, quên resource kia

Hai account mới đi qua stage C. `NhanRam` chạy đúng — không còn lỗi nào về Transit Gateway. Stack chết ở chỗ khác:

```
ResourceLogicalId:DnsProfile, ResourceType:AWS::Route53Profiles::ProfileAssociation
[RSLVR-05007] Can't find the resource with ID "rp-25f333fc9d924548"
```

DNS profile nằm **cùng một RAM share** với TGW (`quh11-net-tgw`) — một chủ ý có ghi rõ trong `network/dns.tf`: một share, một lời mời, account bấm nhận một lần là được cả hai. Nên lời mời đã được nhận đúng.

Vấn đề là **thứ tự bên trong CloudFormation**. Tôi gắn `DependsOn: NhanRam` cho `Attachment` và **quên `DnsProfile`**. CloudFormation tạo song song mọi thứ không có phụ thuộc, nên `DnsProfile` khởi chạy trước khi `NhanRam` kịp nhận lời mời.

Câu lỗi `[RSLVR-05007] Can't find the resource with ID rp-...` không nhắc gì tới RAM — **y hệt** câu `Transit Gateway was deleted or does not exist` mà toàn bộ cơ chế `NhanRam` được viết ra để tránh. Bản vá loại bỏ một câu nói dối và để nguyên câu thứ hai, y hệt nó.

Chữa ba chỗ cùng lúc, vì sửa riêng `DependsOn` chỉ là vá tiếp một nửa:

1. Điều kiện của khối RAM đổi từ `DoAttach` sang `DoRam = DoAttach OR DoDns` — stack dùng DNS mà không dùng TGW vẫn phải chờ.
2. `DnsProfile` khai `DependsOn: NhanRam`.
3. Hàm Lambda kiểm **mọi** tài nguyên được khai, không chỉ TGW: `describe_transit_gateways` cho TGW, `get_profile` cho profile. Điều kiện dừng là "không còn cái nào thiếu", và thông báo hết giờ nói rõ cái nào.

**Dạng lỗi:** một bản vá đúng về cơ chế nhưng áp thiếu chỗ. Điều làm nó khó thấy là bản vá **có chạy** — `NhanRam` thành công, log sạch, và thứ hỏng nằm ở một resource khác với một mã lỗi khác. Không có gì trong log nói rằng hai chuyện đó liên quan.

Cách đáng lẽ phải làm ngay từ đầu: liệt kê **mọi** resource trong template phụ thuộc vào một tài nguyên đến từ account khác, rồi đối chiếu từng cái với `DependsOn`. Hai cái, và tôi kiểm một.

---

### Lỗi 106 — `-target` tạo được resource nhưng không ghi output, và triệu chứng nằm ba stage sau

Hai account mới đi qua pipeline lần thứ hai. Stage A, B xanh. Stage C hỏng: `NhanRam` chờ 240 giây rồi báo hết giờ ở cả hai account.

Kiểm từ trong account đích: **không lời mời RAM, không TGW, không DNS profile.** Không có gì được chia sẻ tới đó. `NhanRam` chờ một thứ chưa bao giờ được gửi — nó làm đúng việc của nó.

Ngược lên stage B: `KHONG CO THAY DOI`, và refresh chỉ thấy 9 `aws_ram_principal_association` cũ. Nhưng đọc state ở máy thì `vending_handles.tgw_share` có đủ **6** account, kể cả hai cái mới. Hai dữ kiện mâu thuẫn nhau, và chỗ mâu thuẫn chính là nguyên nhân.

Giải thích duy nhất khớp cả hai: **`terraform apply <file plan>` chỉ thực hiện đúng plan đã lưu, và với `-target` Terraform loại output khỏi plan.** Nên stage A tạo hai account rồi ghi state với resource **mới** và output **cũ**. Đo trên chính bản state mà A ghi (S3 versioning, bản `08:42:22Z`):

```
accounts : 5  ['app-nonprod-2','app-payments-prod','app-prod-2','app-uat','sandbox-thu-nghiem']
tgw_share: 4
```

`app-nonprod-3` và `app-prod-3` không xuất hiện ở đâu cả — output không được tính lại chút nào, chứ không phải cập nhật một phần. Giá trị 6 mà ta đọc được do stage C Apply ghi — nó apply cả layer nên tính lại mọi output, nhưng lúc đó B đã plan xong từ lâu.

Chuỗi nhân quả dài ba stage:

```
A apply -target  →  state: 7 resource account, output van la 5/4 cu
B doc state      →  thay 4, khong co gi de share  →  "KHONG CO THAY DOI"
C dung stack     →  NhanRam cho loi moi chua ai gui  →  het gio
```

Không có gì trong log của C nói rằng nguyên nhân ở A. Và stage B — stage thật sự sai — báo **thành công**.

Chữa: sau một apply có `-target`, chạy thêm `terraform apply -refresh-only`. Lệnh đó không đổi hạ tầng, chỉ đọc lại thực tế và ghi state kèm output. Chỉ chạy khi có target, vì apply không target đã cập nhật output đầy đủ.

**Cách đúng hơn về lâu dài** là bỏ `-target` hẳn: tách `spoke_network` sang một layer riêng đọc state của `account-baseline`. Lúc đó stage A apply cả layer (account + output), stage B share, stage C apply layer mới — không cần `-target`, không cần `-refresh-only`. Chưa làm vì nó là một lần di chuyển state.

**Dạng lỗi:** một bản vá đúng ý định nhưng có tác dụng phụ ở lớp khác. Lỗi 103 sinh ra `-target` để tách thứ tự; `-target` cắt luôn đường bàn giao mà thứ tự đó phục vụ. Và đường bàn giao ấy đi qua **state**, không qua biến — nên không có `plan` nào của stage A cho thấy nó bị thiếu.

Điều đáng học nhất không phải `-target`. Là chuyện tôi đã đoán sai bốn lần liên tiếp trước khi đo: đoán `-target` không cập nhật output (state ở máy chứng minh ngược), đoán `vending_state` không được đọc (cảnh báo `vending_khong_de_len_tfvars` chứng minh nó có đọc), đoán tfvars trong bucket cũ (`LastModified` là hôm nay), đoán stage B bị nhảy qua (`list-action-executions` cho thấy nó chạy). Mỗi lần một lệnh đo là đủ để loại một giả thuyết, và tôi đưa giả thuyết trước khi đo.

---

### Lỗi 107 — hai bức tường ẩn trong rule east-west, cả hai lớn theo số account

Bản vá lỗi 106 chạy đúng: stage B tạo được hai `aws_ram_principal_association` còn thiếu. Rồi apply chết ở dòng tiếp theo:

```
InvalidRequestException: StatefulRules capacity exceeded, parameter: [116]
  with aws_networkfirewall_rule_group.east_west[0]
```

**Bức tường thứ nhất: `capacity = 100` gán cứng.** Rule mesh sinh theo `N×(N−1)×P` — bình phương số spoke:

| Spoke | Rule mesh (1 port) |
|---|---|
| 8 | 56 |
| 10 | **90** |
| 15 | 210 |
| 20 | 380 |

Cộng ~6 rule hạ tầng. Con số 100 vừa đủ ở 8 spoke và vỡ ở 10. Nó sống sót nhiều tháng vì hệ thống chưa bao giờ vượt 8 — và thứ làm nó vượt chính là cái pipeline sinh ra để thêm account dễ dàng hơn.

**Bức tường thứ hai, chưa ai chạm: sid của mesh.** Công thức cũ đóng gói ba chỉ số vào một số thập phân:

```hcl
sid: 1700 + pi * 100 + i * 10 + j
```

`i*10 + j` chỉ nằm gọn khi có **tối đa 10** spoke. Ở spoke thứ 11, `i = 10` cho `1700 + 100 + 0 = 1800` — đúng sid của `INFRA nlb to app`. Network Firewall không nhận sid trùng.

Nghĩa là kể cả khi nâng capacity, hệ thống vẫn sẽ vỡ ở account tiếp theo, vì một lý do hoàn toàn khác và một thông báo hoàn toàn khác. Hai bức tường cách nhau đúng một account.

Chữa:
- `capacity` thành biến, mặc định 2000. Capacity **không** bị tính phí riêng (AWS tính theo giờ endpoint và theo GB) nên rộng rãi gần như không tốn gì.
- Tên rule group mang hậu tố `-c<capacity>` kèm `create_before_destroy`. `capacity` là thuộc tính ForceNew, và thay thế một rule group **đang được policy tham chiếu** với tên không đổi thì Terraform phải xoá trước khi tạo — AWS từ chối xoá rule group đang dùng, và apply bế tắc. Tên khác nhau thì thứ tự thành: tạo mới → policy trỏ sang → xoá cũ.
- Sid mesh dùng **chỉ số phẳng** từ base 10000, không đóng gói thập phân.
- Thêm `check` cảnh báo khi rule vượt 70% capacity, thay vì đợi tới lúc vỡ.

**Dạng lỗi:** một hằng số hợp lý khi viết, trở thành giới hạn cứng khi hệ thống lớn lên — và cái làm nó lớn lên chính là công cụ ta vừa xây để nó lớn lên dễ hơn. Hai bức tường ở 10 và 11 spoke cho thấy điều đáng lo hơn: chúng không nằm trong tài liệu, không có phép đo nào theo dõi, và chỉ lộ ra bằng cách đâm vào.

---

### Lỗi 108 — vòng phụ thuộc về thời điểm giữa recorder và bucket policy

Stage E hỏng: org config rule không áp được vì hai account prod mới không có configuration recorder.

```
Account ID (353007002364): NoAvailableConfigurationRecorder
Account ID (687259232009): NoAvailableConfigurationRecorder
```

`list-stack-instances` của StackSet recorder cho thấy cả hai ở `OUTDATED`:

```
ResourceLogicalId:DeliveryChannel  →  "Exceeded attempts to wait"  (NotStabilized)
```

Recorder **đã** được triển khai — và hỏng ở `DeliveryChannel`, tức nó không ghi được vào bucket snapshot ở account log-archive.

Vòng phụ thuộc:

```
stage A tạo account  →  StackSet recorder TỰ triển khai ngay
                        bucket policy chưa có account này → DeliveryChannel hỏng
stage E cập nhật bucket policy  →  giờ mới đủ, nhưng recorder đã hỏng
                        và StackSet không tự thử lại
```

Bucket policy phải liệt kê **từng account** qua `AWS:SourceAccount`: Config gọi S3 với tư cách dịch vụ, và `SourceOrgID` không được điền cho luồng gọi này — điều đã ghi sẵn trong `config-detective/s3-log-archive.tf` từ trước, kèm câu *"thêm account mới thì PHẢI apply lại layer này"*. Cảnh báo đúng; chỉ là không ai nối nó với việc tự động hoá.

Vòng này **không sắp xếp lại được**, vì thứ thiết lập điều kiện (bucket policy) và thứ cần điều kiện (recorder) nằm ở hai cơ chế khác nhau, một của Terraform và một của StackSet auto-deployment.

Chữa: action `Cho_recorder` trước plan của stage E — cùng khuôn với `NhanRam`. Đọc `list-stack-instances`, gọi `update-stack-instances` cho đúng những account chưa `CURRENT` (gom theo OU, `AccountFilterType=INTERSECTION`), rồi **chờ tới khi tất cả `CURRENT`**. Thử lại một lần; hỏng lần hai là nguyên nhân khác và lặp mãi chỉ làm mờ nó.

**Dạng lỗi:** giống hệt lời mời RAM (lỗi 105) — một điều kiện tiên quyết **bất đồng bộ**, thiết lập muộn hơn thứ cần nó, và triệu chứng hiện ra ở một dịch vụ khác với một thông báo không nhắc gì tới nguyên nhân. Cả hai đều được chữa bằng cùng một khuôn: **hành động, rồi kiểm điều kiện thật** — không tin rằng hành động đã đủ.

---

### Lỗi 109 — đổi một tag làm chết `for_each`, và cách sửa hiển nhiên xoá mất route của cả 10 spoke

Việc rất nhỏ: đặt `ephemeral = false` ở layer `network` để bỏ tag `Ephemeral = "true"` — cái tag mà `teardown.sh` quét theo để xoá sạch. Bản đếm nhanh cho kết quả yên tâm:

```
Plan: 0 to add, 106 to change, 0 to destroy
```

Nhưng plan đầy đủ **không chạy xong**:

```
Error: Invalid for_each argument
  on vpc-spokes-remote.tf line 835, in resource
     "aws_ec2_transit_gateway_route_table_association" "remote_spokes":
 835:   for_each = local.remote_attachments_ready
     │ local.remote_attachments_ready is a set of dynamic,
     │ known only after apply
```

Và một lỗi y hệt cho `aws_ec2_transit_gateway_route_table_propagation.remote_to_security`.

Chuỗi nhân quả dài hơn vẻ ngoài của nó:

```
ephemeral = false
  → tag Ephemeral bỏ khỏi default_tags (versions.tf)
  → default_tags áp cho MỌI resource → 106 cái "đang bị sửa"
  → trong đó có aws_ec2_transit_gateway.hub
  → data "aws_ec2_transit_gateway_attachments" "remote_by_account"
      lọc theo values = [aws_ec2_transit_gateway.hub.id]
  → cấu hình của data source phụ thuộc vào một resource ĐANG BỊ SỬA
  → Terraform hoãn việc đọc sang lúc apply
  → local.remote_attachments_ready "known only after apply"
  → for_each không có bộ khoá → chết ở plan
```

Không có gì trong câu lệnh gợi ý rằng đổi một cái *tag* lại đụng tới *route*. `default_tags` là thứ nối hai việc đó, và nó nằm ở một file khác.

Đây đúng là hình dạng của **lỗi 50** — thứ mà biến `wire_remote_attachments` sinh ra để chữa. Nên phản xạ đầu tiên là đặt nó về `false`, apply một pha, rồi bật lại.

**Phản xạ đó sai, và sai theo hướng đắt nhất.** `vpc-spokes-remote.tf:107`:

```hcl
wire = local.has_remote && var.wire_remote_attachments
```

```hcl
remote_attachments_ready = local.wire ? toset(flatten([...])) : toset([])
```

`wire = false` cho tập rỗng, mà tập rỗng là `for_each` rỗng, mà `for_each` rỗng nghĩa là **xoá**: 10 association và 10 propagation của spoke remote biến mất. Attachment vẫn `available`, không lỗi, không cảnh báo — và không một gói tin nào đi qua, đúng như chính mô tả của biến đó đã ghi. Biến này dựng cho lần apply **đầu tiên**, khi chưa có gì để mất; dùng lại nó trên hạ tầng đang chạy thì cái giá hoàn toàn khác.

Cách đúng nằm ngay trong thông báo lỗi của Terraform — *"you could use the `-target` planning option to first apply only the resources that the `for_each` value depends on"*:

```bash
terraform apply -target=aws_ec2_transit_gateway.hub   # pha 1: hub hết "đang bị sửa"
terraform apply                                       # pha 2: cả layer
```

Pha 1 làm hub thôi thay đổi, nên ở pha 2 `hub.id` đã biết tại thời điểm plan, data source đọc được, `for_each` có bộ khoá. Cả hai pha đều `0 to destroy`, và route không đứt lúc nào.

Một điểm cần nhớ từ **lỗi 106**: `-target` không tính lại output. Ở đây không phải chữa riêng, vì pha 2 là apply toàn layer nên output được tính lại ở đó — nhưng chỉ đúng **nếu pha 2 chạy tới cùng**. Dừng giữa hai pha thì state có tag mới và output cũ.

**Dạng lỗi:** một biến cờ được viết cho *một tình huống* (bootstrap lần đầu) và sau đó được dùng như *một công tắc chung*. Mô tả của nó nói rõ nó làm gì, chỉ không nói ở trạng thái nào thì việc đó là vô hại. Chỗ sửa: mô tả của `ephemeral` giờ nói thẳng cách đi hai pha và nói thẳng **đừng** đụng `wire_remote_attachments` — cảnh báo đặt ở nơi người ta sẽ đứng khi phạm lỗi, không phải ở nơi nó được định nghĩa.

---

### Lỗi 110 — bỏ một tag làm công cụ kiểm chứng vừa báo hỏng giả vừa báo đạt giả

Ngay sau khi `ephemeral = false` apply xong (`0 added, 105 changed, 0 destroyed`), `verify.sh` tụt từ **69 đạt / 0 lỗi** xuống **68 đạt / 1 lỗi**:

```
6. Gateway endpoint (mien phi) o moi spoke
  ✗ Khong tim thay gateway endpoint
```

Không có gì bị xoá. Mục 7 ngay bên dưới vẫn phân giải `s3.ap-southeast-1.amazonaws.com` qua chính cái gateway endpoint đó. Endpoint còn nguyên; thứ hỏng là câu hỏi.

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-endpoint-type,Values=Gateway" \
            "Name=tag:Ephemeral,Values=true"      # ← tag vừa bị bỏ có chủ đích
```

Nhưng cái đáng ghi không phải mục 6. Là mục 6b, ngay dưới nó, lọc **cùng một tag**:

```bash
missing=$(... --tag-filters "Key=Ephemeral,Values=true" \
              --query 'ResourceTagMappingList[?!(Tags[?Key==`CostCenter`])]...')
if [[ -z "$missing" ]]; then
  ok "Moi resource deu co tag CostCenter"    # ← in ra khi KHÔNG nhìn gì cả
```

Cùng một nguyên nhân, hai kết cục ngược nhau: mục 6 báo **hỏng giả**, mục 6b báo **đạt giả**. Và trong hai cái đó, cái được in bằng dấu ✓ mới là cái nguy hiểm — một phép kiểm hỏng mà kêu to thì được sửa trong mười phút, một phép kiểm hỏng mà im lặng nói "đạt" thì sống qua mọi lần chạy sau. Nếu hôm nay có resource thật sự thiếu `CostCenter`, `verify.sh` đã che nó đi.

Đây là **lần thứ ba trong cùng một file**. Header của chính `verify.sh` đã liệt kê sẵn `"Khong tim thay gateway endpoint"` làm triệu chứng kinh điển của lọc-không-khớp, viết ra sau lỗi 48 và lỗi 57. Cảnh báo đúng, đặt đúng chỗ, và vẫn không chặn được lần thứ ba — vì hai lần trước sai ở **giá trị** của khoá lọc (`PROJECT` gán cứng, credential lệch account), còn lần này sai ở **chính khoá**: lọc theo một tag mà sự tồn tại của nó là một *lựa chọn vận hành*.

Chữa hai phần:

1. Lọc theo `Project` thay vì `Ephemeral`. `Project` có mặt ở cả hai chế độ (`versions.tf`), nên nó nhận dạng được resource của bộ này mà không phụ thuộc vào việc người ta chọn `ephemeral` bằng gì.
2. Mục 6b **đếm tổng trước**. `total == 0` là phép lọc hỏng, và nó được báo là **lỗi**, không phải là một bản khai sạch. Dòng đạt giờ in cả số đã kiểm — `"11 resource deu co tag CostCenter"` — vì một con số buộc phép kiểm phải thừa nhận nó đã nhìn bao nhiêu.

`teardown.sh` cũng quét theo `Ephemeral=true` và **không sửa**: ở đó, không tìm thấy gì chính là lớp bảo vệ, và dòng 29 của nó đã nói thẳng điều đó.

**Dạng lỗi:** một phép lọc không khớp trả về rỗng, và rỗng bị đọc thành một câu trả lời — lần thứ sáu được ghi lại. Điểm mới lần này: cùng một khuyết điểm sinh ra **cả** dương tính giả **lẫn** âm tính giả tuỳ theo `if` viết theo chiều nào, nên đếm số dòng ✗ không đo được mức độ hỏng của một bộ kiểm chứng. Phép kiểm phải nói được **nó đã nhìn bao nhiêu thứ**, không chỉ nói **nó thấy bao nhiêu vấn đề**.

---

### Lỗi 111 — thứ mà phép kiểm hỏng đã che, hiện ra ngay khi nó chịu nhìn

Sửa xong lỗi 110, `verify.sh` chạy lại. Mục 6 và mục 9 xanh, và mục 6b — cái vừa được dạy cách đếm — báo:

```
6b. Tag chi phi da gan day du chua
  ✗ 6/104 resource THIEU tag CostCenter
      arn:...:cloudwatch:...:alarm:quh11-net-partner-vpn-mat-du-phong
      arn:...:network-firewall:...:stateful-rulegroup/quh11-net-ops-east-west
      arn:...:ec2:...:security-group-rule/sgr-090447cfb1a825945
      arn:...:elasticloadbalancing:...:targetgroup/quh11-net-p-sim-api-80
      arn:...:cloudwatch:...:alarm:quh11-net-partner-vpn-DUT
```

Sáu resource, **một** nguyên nhân, và cả sáu đều thuộc layer `ops/`. `ops/versions.tf` khai `default_tags` **riêng**:

```hcl
default_tags {
  tags = {
    Project   = local.hub.project
    ManagedBy = "terraform"
    Repo      = "...network/ops"
    Layer     = "network-ops"
  }                              # ← khong co CostCenter
}
```

Layer cha có `CostCenter` (`versions.tf`), layer con thì không. Không có gì nối hai bộ tag ấy với nhau, và không có gì bắt buộc chúng giống nhau — hai `provider "aws"` ở hai thư mục là hai khai báo độc lập.

Hậu quả không phải là hạ tầng hỏng. Là ba mục chi phí — alarm VPN đối tác, rule group firewall, target group dịch vụ đối tác — rơi vào nhóm `No CostCenter` trong Cost Explorer, tức **không quy được về đâu**. Tiền vẫn tính, chỉ là không ai nhận.

Chữa: truyền `cost_center` / `owner` / `environment` qua output `ops_handles` của layer cha, và `ops/` merge chúng vào `default_tags`. Không khai lại ở `ops/terraform.tfvars` — hai nơi gõ tay cùng một giá trị thì một ngày nào đó chúng lệch, và **không có gì báo cả**: số liệu chi phí vẫn hiện bình thường, chỉ là chia nhầm cột. Một sai số im lặng thì tệ hơn một lỗi.

Một quyết định nhỏ nhưng đáng ghi: khi layer cha chưa apply lại, `try()` trả `{}` và tag **biến mất hẳn** — chứ không phải `CostCenter = ""`.

Chuỗi rỗng nghe vô hại hơn, và tệ hơn hẳn. Với `resourcegroupstaggingapi`, một tag giá trị rỗng vẫn là một tag **có mặt**, nên mục 6b sẽ báo **đạt**. Tức lựa chọn "an toàn" ấy sẽ làm im đúng cái phép kiểm vừa được sửa để phát hiện chuyện này, và bịt lại lỗi 110 lần thứ hai — lần này bằng chính tay người đi vá nó. Tag thiếu thì ồn ào và được sửa; tag rỗng thì yên lặng và sống mãi.

**Dạng lỗi:** hai lớp cấu hình cùng mô tả một chính sách, không lớp nào biết lớp kia. Nhưng điều đáng nhớ hơn nằm ở thứ tự thời gian: khuyết điểm này **có sẵn từ ngày `ops/` ra đời**, và mục 6b lẽ ra phải bắt được ngay hôm đó. Nó không bắt, vì bản thân nó đang lọc theo một tag không tồn tại và đọc kết quả rỗng thành "mọi thứ đều ổn". Lỗi 110 không chỉ là một phép kiểm sai — nó là **lý do lỗi 111 sống được lâu đến vậy**. Một phép kiểm hỏng không phải là mất một phép kiểm; nó là một khoảng mù có người canh gác, và người ta thôi nhìn vào đó.

---

### Lỗi 112 — bản vá lỗi 108 chờ đúng thứ mà chính nó đang chặn

Hai account hoàn toàn mới (`app-nonprod-4`, `app-prod-4`) được thêm vào catalog để đo đúng một điều chưa từng được chứng minh: **một** execution tạo account *và* dựng xong mọi thứ cho nó. Pipeline chạy tới stage E rồi đứng 15 phút:

```
== StackSet: quh11-lz-config-recorder
   con 1 instance chua CURRENT:
     302805792678 ou-o5ci-75f3uqe6 OUTDATED
   khong co operation nao chay va instance van hong -> THU LAI
     OU ou-o5ci-75f3uqe6: 302805792678
       operation 097b74f0-...
   ...
HET GIO sau 15 phut.
```

Action `Cho_recorder` — chính là bản vá của lỗi 108 — hết giờ. Nó thử lại một lần, operation chạy xong, và instance vẫn `OUTDATED`.

Bốn phép đo, theo thứ tự chúng được chạy:

```
StatusReason   DeliveryChannel  "Exceeded attempts to wait"  (NotStabilized)
bucket         SSE-S3, khong KMS  → khong co key policy nao la nghi pham thu hai
lich su chay   E_config_detective|Apply|Succeeded lan cuoi khi app-prod-4
               CHUA ton tai; tu do toi nay ca hai luot deu chet o Cho_recorder
bucket policy  grep -c 302805792678  →  0
```

Mảnh thứ ba là mảnh quyết định: stage E apply là **thứ duy nhất** ghi bucket policy, và nó chưa chạy lần nào kể từ khi account ra đời. Mảnh thứ tư chỉ để đóng lại mọi nghi ngờ còn sót.

Nguyên nhân không nằm trong log. Nó nằm trong thứ tự:

```
Cho_recorder   cho recorder o account moi -> CURRENT
recorder       can bucket Config o log-archive cho account moi GHI
bucket policy  do apply cua stage E viet ra
stage E apply  nam SAU Cho_recorder
```

`config-detective/s3-log-archive.tf` tính `delivery_account_ids` từ **mọi account ACTIVE** của tổ chức, và dùng `AWS:SourceAccount` chứ không `SourceOrgID` — vì Config gọi S3 với tư cách dịch vụ và `SourceOrgID` không được điền. Danh sách ấy được đọc lúc stage E **plan**, nhưng chỉ được ghi vào policy lúc stage E **apply** — mà apply đó đứng sau `Cho_recorder`.

Với một account chưa từng đi qua một lần stage E apply nào, `Cho_recorder` chờ một điều kiện mà chỉ chính nó đang chặn. Không phải chậm. **Không bao giờ xong.**

Điều đáng ghi nhất là **vì sao lỗi 108 nghiệm thu được**. Khi vá 108, hai account `353007002364` và `687259232009` đã tồn tại từ lượt chạy trước, và bucket policy khi đó đã liệt kê 13 account — điều chính tôi đã đo và dán lại. `Cho_recorder` chờ, StackSet thử lại, và thành công **vì điều kiện đã sẵn có từ trước**, không phải vì thứ tự đúng. Bản vá được nghiệm thu trong đúng hoàn cảnh che mất khuyết điểm mà nó lẽ ra phải phơi ra.

Đó là lý do phép đo này đáng giá: bảy account trước đều đi qua ít nhất hai lượt, và **hai lượt che được mọi lỗi thứ tự trong một lượt**. Lượt thứ hai luôn thấy thế giới mà lượt thứ nhất để lại. Một quy trình chỉ đúng khi chạy hai lần thì không phải quy trình tự động — nó là quy trình thủ công có máy làm hộ, và điều đó chỉ lộ ra khi bắt nó làm một lần.

Chữa: tách stage E làm hai, cắt vòng bằng thứ tự chứ không bằng chờ lâu hơn.

```
D  ->  E0 (chinh sach bucket, -target)  ->  Cho_recorder  ->  E (ca layer)  ->  F
```

`E0` chỉ `-target=aws_s3_bucket_policy.config`. Cố ý không apply cả layer: org config rule nằm trong chính layer đó và sẽ hỏng với `NoAvailableConfigurationRecorder` — đúng cái đang tránh. Và vì `delivery_account_ids` đọc mọi account ACTIVE, `E0` không cần biết gì về account vừa tạo; nó chỉ cần chạy **sau** stage A.

#### Hai lần suýt đi chệch, đáng ghi hơn cả bản sửa

**Một.** Hai account mới được tạo, nhưng chỉ **một** kẹt. Tôi lấy đó làm bằng chứng chống lại chính giả thuyết của mình: nếu bucket policy là nguyên nhân, cả hai phải kẹt như nhau. Lập luận nghe chặt và **sai** — `list-stack-instances` cho thấy `791359099343` (app-nonprod-4) *không có trong StackSet*, vì `recorder_target_ous` chỉ phủ Prod và hạ tầng. Con số 1 không mâu thuẫn với gì cả; nó chỉ nói một trong hai account nằm ngoài phạm vi.

Bài học không phải "đừng nghi ngờ giả thuyết của mình" — mà là **một suy luận bác bỏ cũng cần được đo như một suy luận khẳng định**. Tôi đã suýt bỏ một chẩn đoán đúng vì một phép trừ trong đầu.

**Hai.** Sau khi thêm stage E0, lượt chạy tiếp theo vẫn hỏng y hệt. Trong khoảnh khắc đó nó đọc như bằng chứng bản sửa vô dụng. `list-action-executions` nói khác:

```
E_config_detective | Cho_recorder | Failed
D_noi_route_table  | Apply        | Succeeded
...                                            ← khong co E0_chinh_sach_bucket
```

Stage E0 **chưa từng chạy**. Layer `vending-pipeline` là thứ định nghĩa các stage, nên sửa `main.tf` rồi push code là chưa đủ — phải `terraform apply` chính layer đó thì CodePipeline mới có stage mới. Lượt hai chạy lại đúng pipeline cũ, và nó không phủ định gì hết.

Cả hai lần đều là cùng một dạng: **một quan sát được đọc thành bằng chứng cho một mệnh đề mà nó không nói tới**. Giống hệt lỗi 110, chỉ khác là ở đây cái đọc sai là tôi chứ không phải một đoạn script.

**Dạng lỗi:** một cơ chế chờ đặt sai phía của thứ nó chờ. Nhìn từ trong log thì không phân biệt được với "AWS chậm" — cùng một dòng lặp lại, cùng một trạng thái `OUTDATED`, và tăng `wait_recorder_minutes` sẽ không bao giờ cứu được. Chẩn đoán chỉ đến từ việc đọc xem **ai viết ra** điều kiện đang được chờ. Bài học lặp lại từ lỗi 108, giờ ở cấp cao hơn một bậc: *hành động rồi kiểm điều kiện thật* vẫn chưa đủ — còn phải hỏi thứ tạo ra điều kiện đó có được phép chạy trước hay không.

---

### Lỗi 113 — thứ tự sáu stage do phép sắp chuỗi quyết định, và không ai biết

Bản vá lỗi 112 thêm stage `E0-chinh-sach-bucket` vào `stages_all`, giữa `D` và `E`. Đọc lại `pipeline.tf` trước khi chạy thì thấy:

```hcl
dynamic "stage" {
  for_each = { for i, s in local.stages : s.key => merge(s, { thu_tu = i }) }
```

`for_each` chạy trên một **map**. Terraform duyệt map theo **thứ tự sắp xếp khoá**, không theo thứ tự phần tử trong danh sách. Và:

```
"E-config-detective"   vs   "E0-chinh-sach-bucket"
 ^^                          ^^
 ky tu thu hai: "-" = 0x2D   <   "0" = 0x30
```

`E-` sắp **trước** `E0`. Stage E0 sẽ nằm **sau** stage E — đúng phía sai, tái tạo lại y nguyên vòng phụ thuộc mà nó được viết ra để cắt. Bản vá sẽ chạy xanh, `Cho_recorder` vẫn hỏng, và log sẽ không nói gì về thứ tự.

Sáu khoá cũ `A` `B` `C` `D` `E` `F` **tình cờ** sắp đúng thứ tự mong muốn. Nên trong suốt thời gian pipeline hoạt động, thứ tự stage — thứ mà cả thiết kế dựa vào, và cả một mục README giải thích *"thứ tự là một phần của thiết kế"* — thực ra do phép sắp chuỗi quyết định, không phải do thứ tự khai trong `stages_all`. Chú thích đầu `main.tf` nói *"thêm một stage là thêm một dòng"*. Câu đó đúng, có điều kiện, và điều kiện ấy không được viết ra ở đâu: **chỉ khi tên stage tình cờ sắp đúng.**

Chữa:

```hcl
for_each = {
  for i, s in local.stages :
  format("%02d-%s", i, s.key) => merge(s, { thu_tu = i })
}
```

`%02d` chứ không `%d`: mười stage thì `"10"` phải sắp sau `"9"`, mà theo chuỗi thì `"10" < "9"`. Cùng một cái bẫy, một tầng sâu hơn.

**Dạng lỗi:** một bất biến quan trọng được giữ bởi **sự trùng hợp**, không bởi cơ chế. Nó không phải bug cho tới lúc có người thêm phần tử thứ bảy — và người đó không có cách nào biết mình đang bước vào đâu, vì năm năm dữ liệu trước đó đều nói cơ chế hoạt động tốt. Đây là loại khuyết điểm mà số lần chạy thành công **không** đo được: sáu stage chạy đúng hàng trăm lượt không nói gì về stage thứ bảy.

Đáng để ý là nó được tìm ra bằng cách **đọc code trước khi chạy**, không phải bằng log. Nếu tôi cứ apply rồi đợi, triệu chứng nhận được sẽ giống hệt lỗi 112 — `Cho_recorder` hết giờ, `OUTDATED`, không một dòng nào nhắc tới thứ tự stage — và bước tiếp theo hợp lý nhất sẽ là nghi ngờ chẩn đoán 112 vốn đã đúng.

---

### Kết quả của 111–113, và điều vẫn chưa chứng minh được

Sau ba bản vá, pipeline chạy hết bảy stage. Đo lại:

```
pipeline.stages[].name
  Nguon  Lint  A_tao_account  B_chia_se_tgw  C_mang_nen
  D_noi_route_table  E0_chinh_sach_bucket  E_config_detective  F_permission_sets
                     ^^^ dung giua D va E - loi 113 da an

list-stack-instances
  302805792678  CURRENT      ← truoc do OUTDATED suot hai luot
  ...           CURRENT      (8/8)
```

Chuỗi nhân quả đóng kín: E0 ghi bucket policy → `DeliveryChannel` ổn định → recorder `CURRENT` → E và F chạy tiếp. Chẩn đoán lỗi 112 đúng, và được nghiệm thu bằng phép đo chứ không bằng việc "chạy xanh".

**Nhưng mệnh đề ban đầu vẫn chưa được chứng minh.** Hai account mới đi qua ba lượt:

```
Luot 1   A TAO hai account   → B → C → D → E hong
Luot 2   A khong tao gi      → B → C → D → E hong
Luot 3   A khong tao gi      → B → C → D → E0 → E → F  xanh
```

Không lượt nào đi từ *tạo account* tới hết. Lượt xanh chạy trên hai account **đã tồn tại sẵn** — tức vẫn đúng mô hình hai-lượt mà phép đo này được dựng ra để thoát khỏi.

Điều đó không làm ba bản vá mất giá trị: chúng có thật, và stage B–F đều chạy sạch. Nhưng nó đáng ghi rõ, vì đây chính xác là loại kết luận mà một bản ghi cẩu thả sẽ viết thành *"đã chứng minh pipeline làm trọn vẹn trong một lượt"* — và câu đó sai.

Phần còn thiếu bây giờ rất hẹp: chỉ còn câu hỏi *stage A tạo account xong thì B trở đi có chạy liền được trong cùng lượt không*. Ba lỗi vừa sửa đều nằm ở nhánh E, không nằm ở nhánh A→B. Rủi ro còn lại nhỏ — nhưng không bằng không, và chính lỗi 112 là loại chỉ hiện ra trong một-lượt.

**Điều đáng giữ lại:** ba lỗi (111, 112, 113) đều được sinh ra bởi cùng một quyết định — bắt hệ thống làm **một lần** thay vì hai. Hai lượt che được mọi lỗi thứ tự trong một lượt, vì lượt thứ hai luôn thấy thế giới mà lượt thứ nhất để lại. Một quy trình chỉ đúng khi chạy hai lần không phải quy trình tự động; nó là quy trình thủ công có máy làm hộ, và cách duy nhất để biết là thử làm một lần.

---

### Lỗi 114 — cảnh báo của Terraform đi ra stdout, và ba chốt chặn hỏng theo ba kiểu khác nhau

Sau khi destroy layer `network` xong, `./teardown.sh` in ra:

```
════════════════════════════════════════════
 SAI ACCOUNT - dung lai
════════════════════════════════════════════

  Ha tang nay o account : ╷
│ Warning: No outputs found
│
│ The state file either has no outputs defined, or all the defined outputs
│ are empty. ...
╵
  Credential dang dung  : 436908791055
```

Credential **đúng**. Thứ sai là biến `EXPECT_ACCOUNT`: nó chứa trọn khối cảnh báo của Terraform.

Dòng sinh ra nó đã có sẵn chuyển hướng:

```bash
EXPECT_ACCOUNT=$(terraform output -raw account_id 2>/dev/null || echo "")
```

`2>/dev/null` có. `|| echo ""` có. Cả hai vô dụng, vì **`terraform output -raw` trên một state rỗng in khối `Warning: No outputs found` ra STDOUT chứ không phải stderr, và thoát mã 0.** Đây là đo chứ không phải suy đoán: chuyển hướng đã nằm sẵn trong code mà văn bản vẫn lọt vào biến.

Một khuyết điểm, ba chốt chặn, ba kiểu hỏng khác nhau — và kiểu nguy hiểm nhất là kiểu im lặng nhất:

| Chốt chặn | Kiểu hỏng | Hậu quả |
|---|---|---|
| `ephemeral == "false"` | **mở** | Văn bản cảnh báo khác `"false"` → chốt chặn **cho qua**. Một lớp bảo vệ mạng thật, tự mở cửa vì không đọc được đầu vào của chính nó |
| `EXPECT_ACCOUNT != ACTUAL` | **đóng** | So rác với `436908791055` → từ chối chạy, kèm thông báo không đọc nổi |
| `if [[ -n "$PROJECT" ]]` quanh phần quét | **im lặng** | `PROJECT` rỗng → **mọi** phép quét resource mồ côi bị bỏ qua, không in gì. Và "không in gì" đọc y hệt "không có vấn đề" |

Cái thứ ba đáng sợ nhất về mặt vận hành: phần quét mồ côi tồn tại để chạy **ngay sau destroy**, đúng lúc state vừa rỗng, tức đúng lúc nó tự tắt.

Chữa: một hàm `tf_out()` trả **mã lỗi 1** khi không đọc được giá trị thật, để nơi gọi phân biệt được *"đọc được giá trị X"* với *"không đọc được gì"* — điều mà `|| echo ""` cố tình xoá nhoà.

Rồi mỗi chốt chặn xử lý "không đọc được" theo cách riêng, có chủ đích:

- **`ephemeral` không đọc được** → hỏi tiếp `terraform state list`. State rỗng = đã destroy xong, nói ra rồi chạy tiếp. State **có** resource mà output mất = có gì đó sai, **từ chối chạy**. Không đoán.
- **`account_id` không đọc được** → bỏ phép so sánh, không in rác.
- **`project` không đọc được** → in hẳn một dòng nói *"BỎ QUA phần quét — đây KHÔNG phải 'đã sạch', mà là CHƯA NHÌN"*, kèm `LZ_PROJECT=<tên>` để quét được cả khi state đã rỗng.

#### Lỗi 114b — mười ba dấu ✓, và khoản tốn kém nhất không có dấu nào

Sau khi sửa xong, `teardown.sh` chạy sạch: mười ba phép kiểm xanh, `DA SACH. Khong con gi phat sinh chi phi.` Lưới vớt theo tag liệt kê 28 ARN, và script tự giải thích rằng đó là dữ liệu tag còn lưu của resource đã xoá.

Đọc kỹ 28 ARN đó thì thấy ba thứ:

```
vpn-connection/vpn-07442f48fdbc6ddd4
vpn-gateway/vgw-0c7c16e5374d5f2cd
customer-gateway/cgw-06ee3116dbbff2c0c
```

Trong mười ba phép kiểm có dòng `Canh bao duong ham VPN` — nhưng đó là **CloudWatch alarm**, không phải đường hầm. **Không phép kiểm nào nhìn vào chính VPN connection**, mà một VPN connection tính ~$0.05/giờ (~$36/tháng) *dù không một gói tin nào đi qua*.

Nghĩa là mười ba dấu ✓ và dòng "DA SACH" có thể **đúng hết** mà vẫn bỏ lại khoản tốn kém nhất còn sống. Lần này nó thật sự đã sạch — kiểm trực tiếp cho bảng rỗng — nhưng đó là may, không phải nhờ phép kiểm nào.

Nguyên nhân: phần mạng đối tác được thêm vào sau, và phần xác nhận chỉ được thêm theo cho *alarm*. Đúng chỗ dễ nghĩ tới nhất, không phải chỗ đắt nhất.

Đây **không phải một phép kiểm hỏng** — mà là một thứ tính tiền chưa từng có phép kiểm nào. Khác biệt quan trọng: cả bảy lần trước, khuyết điểm nằm trong một phép kiểm *đã tồn tại* và có thể phát hiện bằng cách đọc nó. Ở đây không có gì để đọc. Một danh sách dấu tích chỉ bao phủ những gì có người nghĩ tới lúc viết nó, và **nó không tự nói ra mình thiếu gì** — số dấu ✓ càng nhiều thì cảm giác đã bao phủ hết càng mạnh.

Cái duy nhất bắt được nó là **lưới vớt theo tag**: thứ liệt kê thô, không lọc theo một danh sách định trước. Chính cái mà chú thích trong code gọi là *"lưới vớt, không phải phép đo chính xác"* và mô tả như một nguồn báo động giả. Nó ồn ào đúng vì nó không giả định trước phải tìm gì — và đó là lý do nó thấy được thứ mười ba phép kiểm chính xác không thấy.

Chữa: thêm `check` cho VPN connection, VPN gateway và customer gateway. VGW/CGW không tính phí theo giờ, nhưng để lại thì lần dựng sau dễ dùng nhầm cái cũ, và một VGW còn gắn vào VPC thì chặn việc xoá VPC đó.

**Dạng lỗi:** lần thứ bảy trong nhật ký này — một phép đọc thất bại được coi là một câu trả lời. Nhưng lần này có hai điều mới.

Thứ nhất, **`|| echo ""` là một mẫu chủ động phá hoại chẩn đoán**. Nó biến "không đọc được" thành "đọc được, giá trị rỗng" — hai chuyện khác hẳn nhau — và nó xuất hiện ở đây bảy lần vì trông có vẻ cẩn thận. Cái vẻ ngoài phòng thủ ấy chính là thứ làm nó khó thấy.

Thứ hai, **cùng một khuyết điểm hỏng theo ba chiều khác nhau**, nên không có cách nào "hỏng an toàn" chung. Mỗi chốt chặn phải tự trả lời câu *"nếu tôi không biết thì tôi làm gì?"*, và câu trả lời khác nhau ở từng chỗ. Một `set -e` hay một giá trị mặc định không giải quyết được chuyện đó.

---

### Lỗi 115 — 22 test xanh, và AWS thật tìm ra lỗi trong một lượt

`lint.sh` cho SCP có bộ phân loại thắt/nới, kèm 22 test tự viết. Tất cả xanh. Chạy lần đầu với dữ liệu thật:

```
PROJECT=qh11-lz ./lint.sh --aws

LOI  NOI ma khong khai bao: network_lock/DenyPublicIpOnLaunch
     - Resource THU HEP, mat: arn:aws:ec2:*:*:instance/*
LOI  NOI ma khong khai bao: prod_guard/(ca policy)
     - go khoi target: Production
```

Cả hai là **báo động giả**, và cùng một gốc: so **dạng khai** trong catalog với **dạng đã render** ở AWS.

| Catalog giữ | AWS giữ |
|---|---|
| `arn:${partition}:ec2:*:*:instance/*` | `arn:aws:ec2:*:*:instance/*` |
| `Workloads/Production` (đường dẫn, vì `local.ou_ids` đánh khoá thế) | `Production` (tên OU, từ `list-targets-for-policy`) |

Hai chuỗi khác nhau → phép trừ tập hợp thấy "mất một phần tử" → báo thu hẹp. Và nó báo ngay trên **phép kiểm quan trọng nhất của cả file**: một báo động giả ở đó sẽ được bỏ qua sau vài lần, rồi một lần nới thật cũng bị bỏ qua cùng nó.

**Nhưng điều đáng ghi không phải hai lỗi đó. Là việc 22 test không bắt được chúng.**

Bộ test sinh bản chụp "AWS" **từ chính catalog**. Nên fixture mang đúng những sai lệch mà code cần kiểm cũng mang: cả hai phía đều để `${partition}` nguyên, cả hai phía đều dùng đường dẫn OU. Hai sai lệch triệt tiêu nhau, và phép so thấy khớp hoàn hảo.

**Một fixture dựng từ cùng nguồn với code cần kiểm không thể phát hiện lệch biểu diễn.** Nó chỉ chứng minh code tự nhất quán — điều luôn đúng, và không ai cần chứng minh. Toàn bộ 22 test kiểm *logic phân loại* (thu hẹp có bị bắt không, `locked` có chặn được `loosen` không) và không một test nào kiểm *hai phía có nói cùng một ngôn ngữ không*.

Chữa hai chỗ trong `lint.sh`, và một chỗ trong bộ test: **bản chụp giờ render như AWS**, không như catalog. Sau đó kiểm bằng đột biến — bỏ từng bản chuẩn hoá và xem bộ test có đỏ:

```
bo chuan hoa partition  ->  15 dat / 7 truot
bo chuan hoa target     ->  15 dat / 7 truot
ca hai                  ->  22 dat / 0 truot
```

Lần đầu chạy phép đột biến đó, lệnh sửa file dùng `\${partition}` trong chuỗi nháy kép của bash; bash biến `\$` thành `$`, chuỗi Python đi tìm một dòng không tồn tại, phép thay thế là no-op và **không báo lỗi**. Test in ra `22 dat`, và tôi đọc thành *"test không bắt được"* trong khi sự thật là *"đột biến chưa xảy ra"*. Đúng dạng đã ghi bảy lần, lần này ở trong chính phép kiểm dùng để kiểm phép kiểm. Bản sửa: `assert old in t` trước khi thay — một phép đột biến không đột biến được phải **dừng**, không được im lặng báo xanh.

**Dạng lỗi:** test và code chia sẻ một giả định, nên test không thể kiểm giả định đó. Khác với cả bảy lần trước — ở đó phép kiểm *có thể* đúng nhưng viết sai; ở đây phép kiểm **về mặt cấu trúc** không nhìn được vào chỗ cần nhìn. Cách duy nhất phát hiện là dữ liệu thật, hoặc một fixture được dựng độc lập bằng tay.

Hệ quả thực hành: với bất kỳ phép so "của ta" với "của họ", fixture phải sinh từ **phía họ**. Và khi không có dữ liệu thật, phép đột biến là thứ gần nhất — nhưng chỉ khi nó dừng lại được lúc không đột biến nổi.

---

### Lỗi 116 — chốt chặn chặn đúng, và ngay cạnh nó là một chốt chặn chặn hụt

Lượt chạy thật đầu tiên của pipeline vận hành. Stage `A_scp`, action `Plan`, **Failed**. Log:

```
08:36:22  == lint: ./lint.sh --aws --strict
08:36:24    ⚠ --aws can ten project de tim policy o AWS, nhung khong doc duoc.
```

Đó là chốt chặn `PROJECT` của `lint.sh`. Nó dừng **trước** `terraform plan`, nên không có gì ở AWS bị chạm tới. Đây là lớp bù cho việc pipeline này cố ý không có cổng duyệt, và nó làm đúng việc của nó.

Nguyên nhân: `lint.sh --aws` lấy tên project bằng `terraform output -raw project`. Trên máy người vận hành nó luôn chạy được vì người ta gõ `PROJECT=qh11-lz ./lint.sh`. Trong CodeBuild không ai đặt biến đó, và lệnh kia trả về rỗng.

Hai lý do, và **không lý do nào sửa được bằng cách thêm một output**:

1. `terraform output` đọc **state**, tức giá trị của lần apply *trước*. lint chạy trước plan và apply. Nên đúng ở lượt quan trọng nhất — lượt đầu sau khi thêm output — state vẫn chưa có nó.
2. Layer `organization` không khai output `project`. Lệnh đó in khối `No outputs found` ra **stdout** rồi thoát 0 — lỗi 114, lần thứ hai.

`terraform.tfvars` thì ngược lại: nó là **đầu vào sinh ra chính cái tên đó**, và buildspec kéo nó về trước khi lint chạy (thiếu file thì buildspec đã thoát 1 từ trước). Không phụ thuộc vào một lần apply nào.

#### Nhưng lỗi đáng ghi là cái tìm thấy lúc đang sửa

Đọc lại đoạn phân loại để biết `PROJECT` được dùng vào đâu:

```python
ten_aws = f"{PROJECT}-{p['name'].replace('_', '-')}"
cu = aws.get(ten_aws)
if cu is None:
    # Policy moi. Them mot policy la THAT - khong can khai bao.
    continue
```

Dòng đó **đúng** khi thật sự thêm một policy mới. Nhưng nếu tên project **sai** thì không policy nào tìm thấy, nên *mọi* policy đều "mới", nên *mọi* policy đều là thắt, nên kết quả là:

```
Doi chieu AWS: 0 thay doi NOI / 13 con lai la THAT hoac khong doi
```

**Sạch.** Thoát 0. Pipeline chạy tiếp và apply.

Hai chốt chặn cạnh nhau, cùng đọc một biến, hỏng theo hai chiều ngược nhau:

| `PROJECT` | Xảy ra gì | Kiểu hỏng |
|---|---|---|
| rỗng | lint từ chối chạy, thoát 1 | **đóng** — pipeline dừng, ai cũng thấy |
| sai một ký tự | lint báo "0 thay doi NOI", thoát 0 | **mở** — lint vừa báo cáo rằng không ai nới guardrail nào, trong khi nó không nhìn thấy guardrail nào cả |

Đúng cặp đã ghi ở lỗi 114, nơi một khuyết điểm làm một chốt chặn fail-open và một chốt chặn khác fail-closed. Ở đây còn gọn hơn: **cùng một biến, chênh nhau một ký tự, và hai kết cục ngược nhau.**

Bản vá: đếm xem bao nhiêu tên mong đợi thật sự có ở AWS. 0 trên N thì chỉ có hai khả năng — tên sai, hoặc thật sự chưa từng apply SCP nào — và lint **không phân biệt được**, nên nó từ chối và bắt người chạy nói rõ bằng `LAN_DAU=yes`. Cùng hình dạng với chốt `FIRST_APPLY` ở buildspec, vì cùng một câu hỏi: *rỗng vì chưa có, hay rỗng vì nhìn nhầm chỗ?*

Kiểm bằng đột biến, vì 30 dấu ✓ tự nó không chứng minh gì (lỗi 115):

```
vô hiệu hoá chốt 0-khớp  ->  29 dat / 1 truot   ("ten project sai" thoát 0 = PASS giả)
bỏ neo ^ trong sed        ->  29 dat / 1 truot   (dòng `# project = ...` bị đọc thành giá trị)
cả hai còn nguyên         ->  30 dat / 0 truot
```

Dòng đầu là bằng chứng: **trước bản vá, một tên project sai cho ra `exit 0`.**

**Dạng lỗi:** lần thứ mười. Một phép tra cứu không khớp trả về rỗng, và rỗng được đọc thành *"không có gì để so"* thay vì *"chưa so được"*. Điểm mới: lần này rỗng còn được đọc thành một câu khẳng định **có lợi** — "mọi thứ đều là thắt" — nên nó không những không báo động, nó còn báo an toàn.

#### Kết quả — đo được, và trước/sau nằm trong cùng một lệnh grep

Lượt chạy sau bản vá, stream `11a823b0` (action `Plan` của stage `A_scp`):

```
09:10:45   project = qh11-lz  (tu terraform.tfvars)
09:11:07   Doi chieu AWS: 0 thay doi NOI / 13 con lai la THAT hoac khong doi
09:11:07    lint sach
09:11:21  == tom tat: 0 tao, 0 sua, 0 xoa, 0 thay the
```

`13` là đúng số statement của catalog — nên nó **so thật**, không phải "so với rỗng rồi báo sạch". Đó là con số phân biệt hai kết cục mà lỗi 116 làm lẫn vào nhau.

Cùng một lệnh `grep` trên cùng log group cũng in ra lượt **hỏng** trước đó, stream `47837525` lúc 08:36: ba dòng `echo "   lint sach"` và **không** dòng `project = `, **không** dòng ` lint sach`. Trước và sau bản vá nằm cạnh nhau trong một màn hình.

Và cách phân biệt echo với kết quả — điều CodeBuild bắt phải làm, vì nó in cả khối lệnh vào log trước khi chạy:

| Dòng | Là gì |
|---|---|
| `echo "   lint sach"` | script, chưa chạy |
| `   lint sach` | đầu ra thật |
| `echo "== tom tat: ${TAO} tao, ..."` | script — còn `${...}` nguyên |
| `== tom tat: 0 tao, 0 sua, 0 xoa, 0 thay the` | đầu ra thật |

Toàn tuyến **nguồn → lint đối chiếu AWS thật → plan → apply** đã thông một lượt với 0 thay đổi ở cả hai bước apply (`0 added, 0 changed, 0 destroyed`, rồi `No changes` ở bước `-refresh-only`), với `27 resource trong state` đúng khoá. Đúng thứ `next_steps` mục 3 của layer đòi: **lượt chạy đầu tiên phải là một lượt không có thay đổi** — xem được đường đi trước khi một thay đổi thật đi qua nó.

Một giới hạn đã biết, ghi để không thành nợ im lặng: bước `terraform apply -refresh-only` ghi lại output **không** bị `-target` giới hạn, nên nó refresh cả 27 resource gồm cây OU và delegated administrator. Nó không sửa được hạ tầng (refresh-only theo định nghĩa) nhưng **ghi lại state** cho những resource mà pipeline này không được phép chạm. Nếu ai xoá tay một OU, lượt chạy này ghi nhận việc xoá vào state, và lượt sau attachment gắn vào OU đó sẽ vào plan — nơi `FAIL_ON_DESTROY=yes` chặn nó ở bước plan. Có lớp bù, nên là giới hạn, không phải lỗ.

---

### Lỗi 117 — `list(any)` không phải "danh sách gì cũng được"

Tách `modules/tf-pipeline/` để hai phòng ban mỗi phòng một pipeline. Hai biến nhận IAM statement được khai:

```hcl
variable "quyen_dich_vu" { type = list(any) }
```

`terraform plan` trên máy người vận hành:

```
Error: Invalid value for input variable
  on main.tf line 290, in module "pipeline":
  quyen_dich_vu = local.quyen_dich_vu
element types must all match for conversion to list
```

`list(any)` **hợp nhất type của mọi phần tử**, và thất bại nếu chúng khác hình. IAM statement thì **luôn** khác hình: một cái có `Condition`, cái khác không; `Action` là `["a","b"]` ở chỗ này và `concat(...)` độ dài chưa biết ở chỗ kia; `Resource` là chuỗi ở chỗ này, danh sách ở chỗ kia.

Và thông báo nói về **"list"**, không nói về IAM. Đọc nó xong vẫn không biết phải sửa gì. `any` thì không hợp nhất gì — giá trị đi thẳng vào `jsonencode`, và `jsonencode` nhận mọi hình.

**Điều đáng ghi là vì sao tôi không tự bắt được.** Đây là lỗi chuyển đổi type của biến module, và chỉ `terraform validate` / `plan` thấy — cả hai đòi provider tải từ `registry.terraform.io`, bị chặn trong môi trường tôi chạy. Nên toàn bộ 2000 dòng HCL được tái cấu trúc mà không một lần `validate`.

Thứ thay thế được viết ra vì thiếu `validate`: `landing-zone/kiem-module.py`, sáu phép kiểm không cần mạng — dùng `var.X` không khai, khai không dùng, truyền input module không có, biến bắt buộc không truyền, đọc output module không có, dùng `local.X` không khai. **Nó tự sai ba lần, và cả ba đúng dạng khuyết điểm của dự án này:**

| Lỗi của bộ kiểm | Nó kết luận sai điều gì |
|---|---|
| chạy từ thư mục khác → `glob` rỗng | chạy 6 phép trên chuỗi rỗng rồi in *"Khớp hết"* |
| strip cả chuỗi thường → mọi `${var.x}` biến mất | *"khai biến không dùng"* trên 7 biến đang dùng |
| bắt `locals {` **đầu tiên** (ở `codebuild.tf`) | mọi local của `main.tf` thành *"không khai"* |

Sau khi sửa, thêm phép kiểm thứ bảy: kêu khi một biến module dùng `type = list(any)`. Bài học được mã hoá, không để trong đầu.

#### Một phép đột biến THẤT BẠI, và nó nói về code chứ không về bộ kiểm

Bỏ `layer_keys = var.layer_keys` khỏi module block → bộ kiểm báo *"Khớp hết"*. Đúng, vì module có:

```hcl
default = { "landing-zone/organization" = "organization/terraform.tfstate" }
```

Mặc định đó vô hại khi file chỉ thuộc **một** pipeline. Khi nó thành module **dùng chung** thì nó là cái bẫy: pipeline của cloudops quên truyền `layer_keys` sẽ **lặng lẽ** dùng khoá state của layer `organization`, và các stage của nó plan trên state của SCP.

Và chính mô tả của biến đó đã nói vì sao: *"Sai khoá thì Terraform mở một state RỖNG: plan đòi tạo lại toàn bộ"*. **Một mặc định ở đây là một cách sai khoá mà không ai gõ sai gì.**

Bỏ default → đột biến chạy lại → bắt được. Một đột biến không bắt được đôi khi nói về **code**, không về bộ kiểm.

#### Kết quả — `0 to destroy`, và một con số tôi đưa sai

30 khối `moved` cho 30 resource. Plan: `3 to add, 2 to change, **0 to destroy**`. Apply: `3 added, 2 changed, 0 destroyed` — KMS key giữ nguyên `7652dca8-…`, bucket artifact giữ nguyên tên.

Nhưng tôi nói *"số dòng chuyển địa chỉ phải là 30, ít hơn nghĩa là một khối không khớp"*. Thực tế **25**, và 25 là đúng: 5 khối còn lại không có nguồn trong state (`aws_sns_topic.drift` + subscription vì `drift_topic_arn` đã khai nên `count = 0`; ba resource approval vì chúng đang được **tạo**, không phải chuyển). Một `moved` trỏ vào địa chỉ không có trong state là hợp lệ và im lặng — nên phép đếm đó **không phân biệt được** "không có gì để chuyển" với "gõ sai địa chỉ". Con số nói được điều đó là `0 to destroy`.

Lần thứ hai trong cùng ngày tôi đưa một con số làm mốc mà nó sinh từ một lệnh khác: trong log CodeBuild, `gate.py` in `21 resource trong ban plan` còn tôi bảo chờ `25`. `25` lấy từ bản plan chạy tay **không có `-target`**; plan trong pipeline **có**. Chênh đúng 4, và giải được: 12 instance được target, cộng 8 OU + 1 organization mà attachment phụ thuộc vào; loại 3 `delegated_administrator` và `terraform_data.scp_guard`. `25 − 4 = 21`.

**Dạng lỗi:** so hai con số sinh từ hai lệnh khác nhau. Mốc đúng không phải con số tuyệt đối mà là quan hệ — `0 co thay doi`, `0 to destroy`.

#### Cổng duyệt: đo được là nó GIỮ, không chỉ là nó tồn tại

```
22:25:13  Plan   Succeeded
22:29:26  Duyet  Succeeded   Approved by …/AWSReservedSSO_lz-account-admin_…/quang
22:30:29  Apply  Succeeded   (run_order 3)
```

Bốn phút giữa `Plan` và `Duyet` là phép đo: cổng chặn thật, không đi qua. Và `summary` ghi **ai** duyệt — dấu vết mà `FAIL_ON_DESTROY` không bao giờ tạo được.

Một chi tiết về phương pháp: truy vấn token bằng CLI ra `None`, vì lúc đó người dùng đã duyệt trong console. Nên đường duyệt bằng CLI **chưa được kiểm**, không phải *đã sai*. Hai điều đó khác nhau, và không có cơ sở nào để chọn một trong hai.

---

### Lỗi 118 — sửa một dòng trong `docs/` làm pipeline vending chạy cả bảy stage

Người vận hành báo: *"cứ push code lên thì vending pipeline cũng chạy, vending pipeline nó chỉ nhận event ở code account-baseline thôi"*.

Đúng, và **không sửa được ở tầng luật**. Rule EventBridge lọc theo nội dung sự kiện, còn sự kiện `CodeCommit Repository State Change` mang đúng bốn trường:

```json
{ "repositoryName": "...", "commitId": "...",
  "oldCommitId": "...", "referenceName": "refs/heads/main" }
```

Danh sách file **không có trong đó**. Đây không phải "chưa ai viết luật lọc" mà là **không có dữ liệu để viết**.

Hai đường vòng đều đóng:

| Đường | Vì sao đóng |
|---|---|
| `CodePipeline V2` path filter (`triggers { … file_paths }`) | chỉ hoạt động với nguồn kiểu *connection* — GitHub, GitLab, Bitbucket. Với CodeCommit thì trường đó không có tác dụng |
| Đổi sang GitHub làm nguồn | công ty không cho dùng GitHub, chỉ nội bộ |

Thứ **có** trong sự kiện là hai commit id. Nên chỗ lọc duy nhất còn lại là một hàm đứng giữa: gọi `codecommit:GetDifferences(oldCommitId, commitId)`, lấy đường dẫn đã đổi, rồi khởi động đúng những pipeline có đường dẫn bị chạm. Đó là `landing-zone/trigger-filter/`.

#### Quyết định trung tâm: hỏng thì chạy

Khi không đọc được diff — API lỗi, hết giờ, thiếu quyền, commit bị ép đẩy — hàm khởi động **mọi** pipeline trong bản đồ.

Vì hai vế không cân nhau. Một lần chạy thừa là vài phút CodeBuild và một dòng log. Một lần **không** chạy là một thay đổi đã merge vào `main` mà không bao giờ đến AWS — và không có gì báo, vì pipeline "không chạy" trông giống hệt "không có gì để chạy".

Đúng dạng khuyết điểm đã ghi mười lần trong nhật ký này: **một phép đọc hỏng trả về rỗng, và rỗng bị đọc thành một câu trả lời.** Ở đây rỗng sẽ có nghĩa là "không file nào liên quan" — rất dễ tin và rất sai.

Ngoại lệ có chủ đích: **diff rỗng thật sự** (commit rỗng, merge không đổi gì) *không* fail-open. Đó là một kết luận đọc được, không phải một phép đọc hỏng. Hai thứ đó trông giống nhau trong code và khác hẳn nhau về ý nghĩa, nên chúng đi hai nhánh riêng.

#### Bốn cách bản đồ có thể sai, và cả bốn đều im lặng

Bộ lọc này đứng **giữa** sự kiện và mọi pipeline, nên khi nó sai theo chiều "chặn nhầm" thì không có gì báo. Bốn phép kiểm chạy ở **mỗi** lần gọi, và đều là lỗi cứng:

| Sai | Hậu quả nếu không kiểm |
|---|---|
| `BAN_DO` rỗng | chặn sạch mọi thay đổi và báo thành công |
| một pipeline có danh sách tiền tố `[]` | `str.startswith(())` luôn `False` → pipeline đó không bao giờ chạy |
| tên pipeline gõ sai | `StartPipelineExecution` bị IAM từ chối |
| **pipeline có thật nhưng thiếu trong `BAN_DO`** | sau khi tắt rule riêng, không còn đường nào đến nó |

Dòng thứ hai đáng dừng lại: trong tfvars, `vending = []` đọc giống **"chưa điền xong"** và chạy giống **"đã tắt"**. Muốn "chạy với mọi commit" thì phải viết `[""]`.

Dòng thứ tư là chiều nguy hiểm nhất của cả thiết kế — và nó là chiều mà *chính việc sửa lỗi 118 tạo ra*. Trước khi có bộ lọc, mỗi pipeline có đường kích hoạt riêng; sau khi có, bản đồ là đường **duy nhất**. Một pipeline bị quên ở đó vẫn tồn tại, vẫn xanh trong console, và không bao giờ chạy nữa. `kiem_do_phu = true` bắt nó bằng cách liệt kê pipeline thật ở AWS mỗi lần chạy.

#### Thứ tự bật — một chiều vô hại, một chiều im lặng

Bật `trigger-filter` **trước**, rồi mới đặt `tu_kich_hoat = false` ở từng pipeline.

Giữa hai lần apply mỗi pipeline bị kích hoạt **hai lần** — vô hại, CodePipeline thay bản đang chờ bằng bản mới. Làm ngược lại thì giữa hai lần apply **không có gì** kích hoạt pipeline nào, và không có triệu chứng nào.

Một chi tiết suýt sai: `tu_kich_hoat` **không** được tắt `aws_iam_role.events`. Role đó dùng chung với lịch drift, và lịch drift không liên quan gì đến commit. Buộc nó theo biến kia sẽ biến một lần "tắt rule" thành một lần **xoá role** — mà role bị xoá thì bật lại không đủ, phải tạo lại.

#### Ba phép thử, và chỉ một phép chứng minh được điều gì

| | Phép thử | Phân biệt được gì |
|---|---|---|
| (a) | push thay đổi chỉ trong `docs/` → không pipeline nào chạy | **không** — "không ai chạy" trông giống "chạy hết rồi không có gì để làm" |
| (b) | push vào `account-baseline/` → vending chạy | **không** — vẫn đạt nếu mọi pipeline đều chạy |
| (c) | push vào `organization/` → `ops` chạy **và** `vending` **không** chạy | **có** |

Chỉ (c) đòi một pipeline chạy *và* một pipeline không chạy trong cùng một lần push, nên chỉ nó phân biệt được "bộ lọc hoạt động" với "bộ lọc bị bỏ qua hoàn toàn".

#### Bộ kiểm: 28 phép, 5 đột biến

`test-loc.py` chạy không cần mạng và không cần `boto3` thật. Năm đột biến, cả năm đều làm bộ kiểm kêu:

| Đột biến | Kết quả |
|---|---|
| bỏ chốt "tiền tố rỗng" | 27/28 |
| đổi fail-open thành fail-closed khi `GetDifferences` hỏng | 26/28 |
| bỏ `beforeBlob` (đổi tên file) | 27/28 |
| bỏ chốt độ phủ | 27/28 |
| ném ngay khi một pipeline khởi động hỏng | 27/28 |

Đột biến thứ năm nói về một quyết định dễ bỏ qua: nếu `StartPipelineExecution` ném ra khỏi vòng lặp, **một tên gõ sai sẽ chặn mọi pipeline đứng sau nó trong vòng lặp** — một lỗi gõ phím thành một lần bỏ sót. Nên lỗi được **ghi lại** rồi ném ở cuối, sau khi đã thử hết.

#### Và chính bộ kiểm tự sai một lần, đúng dạng nó đi tìm

Bài kiểm *"sự kiện rỗng hoàn toàn"* đạt — vì lý do sai. Hàm dựng bài kiểm viết:

```python
loc.handler(su_kien_ or su_kien(), None)
```

`{}` là falsy, nên sự kiện rỗng bị thay bằng sự kiện **mặc định**, và bài kiểm chưa bao giờ chạy thứ nó nói nó chạy. Chữa bằng một sentinel `KHONG_TRUYEN`. **Một giá trị rỗng bị đọc thành "không truyền" — trong chính bộ kiểm đi tìm khuyết điểm đó.**

### Ghi chú — 15 ≠ 14, và con số lệch đó là đường quản trị đang dùng

Sau khi ba pipeline chạy xanh, kiểm kết quả bằng cách **hỏi thẳng AWS** chứ không hỏi Terraform.

`ops` sạch, và đây là phép đối chiếu mạnh nhất có thể cho SCP — `lint.sh --aws` đọc chính sách *đang gắn thật* ở Organizations rồi so từng statement, nên nó phủ cả chỗ `terraform plan` mù (một SCP sửa bằng tay):

```
Catalog: 5 policy, 13 statement (4 locked)
Doi chieu AWS: 0 thay doi NOI / 13 con lai la THAT hoac khong doi
```

`ops-permission-set` thì ra một con số không khớp:

```
lz-account-admin duoc provisioned o  15 account
scope_map["all"]                     14 account
chi co o AWS:                        609320954321   (management)
```

#### Không phải role sót lại

Cách đọc dễ chịu nhất là *"role `AWSReservedSSO_*` còn sót sau một lần gỡ assignment"*. Sai — một role sót lại không assume được. Và bằng chứng nằm ngay trong danh tính đang chạy mọi lệnh hôm đó:

```
arn:aws:sts::609320954321:assumed-role/AWSReservedSSO_lz-account-admin_.../quang
```

Hỏi tiếp thì ra:

```
USER  398a851c-...     <- user `quang`, gan TRUC TIEP
```

**Một người, gán trực tiếp, không qua group** — khác hẳn 14 account còn lại vốn đều gán qua `GROUP`. Tạo tay lúc dựng Identity Center, trước khi layer `permission-sets` tồn tại.

#### Khoảng trống này do thiết kế tạo ra, có chủ đích

`exclude_management_from_all` loại management khỏi phạm vi `"all"`, với lý do viết sẵn trong code: *"SCP KHÔNG áp dụng cho management account, mọi quyền cấp ở đây là quyền thật không có trần chặn."* Mà `lz-account-admin` dùng đúng phạm vi `"all"`.

Nên **theo Terraform, không ai vào được management qua Identity Center.** Thực tế có một đường, và nó nằm ngoài.

Giữ nó ngoài Terraform là có lý: pipeline `ops-permission-set` có `sso:DeleteAccountAssignment`, nên đưa đường này vào code nghĩa là một thay đổi sai ở đó xoá được lối vào của chính người vận hành. Đó là break-glass đúng nghĩa.

#### Nhưng ba tính chất của nó phải được viết ra

| | |
|---|---|
| **Không lớp kiểm nào thấy** | `terraform plan` ra `No changes` vì Terraform không biết resource nó không quản; `gate.py` đọc bản plan, mà bản plan trống. Cả hai đều **đúng** — chúng không hỏng, chúng chỉ không nhìn tới đó |
| **Một người** | user đó mất quyền, nghỉ việc, hay bị xoá là không còn ai vào được management qua Identity Center |
| **Gán trực tiếp** | không thêm người được bằng cách thêm vào group — phải gán tay lần nữa, và lần đó cũng vô hình với mọi lớp kiểm |

Đã khai vào `permission-sets/organizations.tf`, ngay cạnh `exclude_management_from_all`, kèm lệnh kiểm lại. Vì trước đó nó **trông như một chỗ bỏ sót**, và thứ phân biệt "cố ý" với "bỏ sót" chỉ có một: có ai viết nó ra hay không.

#### Và cái bẫy `--query` lại xuất hiện, lần thứ hai trong ngày

```
aws ... --query 'length(AccountIds)' --output text
10
5
```

Không phải hai kết quả — **một kết quả bị phân trang**. CLI tự phân trang và áp `--query` cho *từng trang*, nên phép đếm in ra một số mỗi trang. Đọc `10` thành câu trả lời thì sai; đọc `15` thì phải nhận ra đó là tổng.

Cùng họ với `--max-items` sáng cùng ngày (thêm một dòng `None` vào biến) và với `--query` lồng hai phép chiếu đã ghi ở lỗi 104. Cách chữa không đổi: **lấy danh sách rồi tự đếm, đừng để CLI đếm hộ.**

---

### Lỗi 122 — một lần chạy đỏ do đua tạo resource, đọc y hệt một lỗi thiếu quyền

`ops-trail` vừa dựng xong đã đỏ ngay ở stage `Nguon`:

```
qh11-lz-ops-trail-pipeline is not authorized to perform: codecommit:GetBranch
errorDetails: {"code": "PermissionError"}
```

Thông báo đó chỉ thẳng vào một chỗ: policy thiếu action. Nhưng policy **không** thiếu:

```json
{"Action": ["codecommit:GetBranch", "codecommit:GetCommit", ...],
 "Effect": "Allow",
 "Resource": "arn:aws:codecommit:ap-southeast-1:...:diy-aws-landing-zone"}
```

Thứ trả lời được nằm ở hai cái dấu thời gian, không ở nội dung policy:

| | |
|---|---|
| pipeline được tạo | `17:45:03` UTC |
| lần chạy đỏ bắt đầu | `17:45:04` UTC |

Một giây. **CodePipeline tự chạy một lần ngay khi được tạo** — không ai bấm, không có commit nào. Và `aws_codepipeline` với `aws_iam_role_policy.pipeline` cùng phụ thuộc vào `aws_iam_role.pipeline` nhưng **không phụ thuộc vào nhau**, nên Terraform được phép tạo pipeline trước rồi gắn policy sau. Lần chạy tự động rơi đúng vào khe giữa hai việc đó.

Nên nó không phải lỗi cấu hình, cũng không phải lỗi nhất thời của AWS: nó là **thứ tự tạo resource**, và nó sẽ lặp lại ở mọi pipeline mới dựng.

#### Vì sao một lần đỏ "vô hại" vẫn phải chữa

Có thể bỏ qua nó — lần chạy sau xanh. Nhưng khi đó quy ước *"pipeline đỏ nghĩa là có chuyện"* có một ngoại lệ, và ngoại lệ đó không viết ở đâu cả. Người tiếp theo thấy `codecommit:GetBranch` sẽ đi sửa IAM — sửa một thứ vốn đã đúng.

Chữa bằng một khối `depends_on` trong `aws_codepipeline`, ở **cả hai** bản sao (`modules/tf-pipeline` và `vending-pipeline`):

```hcl
depends_on = [
  aws_iam_role_policy.pipeline,
  aws_s3_bucket_policy.artifacts,
]
```

`aws_s3_bucket_policy.artifacts` có mặt vì cùng một lý do: bucket artifact cũng được gắn policy bởi một resource riêng, và lần chạy đầu ghi vào bucket đó.

Cùng họ với lỗi 120 ngay bên dưới, nhưng ở chiều ngược lại: ở đó một cấu hình **sai** đi qua plan mà không để lại dấu vết; ở đây một cấu hình **đúng** sinh ra một thông báo lỗi mô tả một sự cố không có thật.

---

### Lỗi 121 — "pipeline chạy ổn" chưa bao giờ có nghĩa là "apply được"

Thay đổi thật đầu tiên đi qua một pipeline vận hành: thêm một Config rule toàn tổ chức. `plan` xanh, `gate.py` cho qua, rồi `apply` **crash**:

```
panic: checkable object status report for unexpected checkable object
       var.security_hub_standards
       ... evalVariableValidations
```

Không phải lỗi cấu hình — một bug của lõi Terraform, sinh ra từ 1.6.0 khi `validation` của biến trở thành *checkable object* ([#34052](https://github.com/hashicorp/terraform/issues/34052), [#35525](https://github.com/hashicorp/terraform/issues/35525)).

Ba điều kiện kích hoạt **đều là thiết kế của chính pipeline này**:

| Điều kiện | Vì sao nó có mặt |
|---|---|
| `-target` | ranh giới ghi của từng stage |
| file plan lưu ra artifact | `gate.py` đọc *đúng bản plan đó*, và apply phải thực hiện *đúng nó* |
| biến có `validation` | 10 ở `config-detective`, 5 ở `permission-sets`, 4 ở `organization`, 3 ở `org-trail` |

Nên đây không phải một trường hợp biên. Đó là **đường đi bình thường của mọi thay đổi thật**.

#### Vì sao nó ẩn được lâu đến thế

Mọi lần apply xanh trước đó trong dự án này đều là **no-op**: `0 added, 0 changed, 0 destroyed`.

Quy ước *"lần chạy đầu qua một đường mới phải là một lần không có thay đổi"* là một quy ước tốt — nó kiểm đường đi trước khi một thay đổi thật đi qua. Nhưng nó cũng **che đúng khúc cuối của đường đó**: khúc mà Terraform phải *làm* gì đó.

Nên câu "pipeline chạy ổn", cho tới hôm nay, chỉ có nghĩa là **đường ống thông**. Nó chưa bao giờ có nghĩa là **apply được**. Hai điều đó khác nhau, và cái thứ hai vừa được thử lần đầu — sau khi năm pipeline đã được dựng, đo, và tuyên bố là chạy tốt.

#### Tìm bản vá bằng một lần chạy, không bằng changelog

Tôi không tra ra được bản nào sửa bug này — changelog của Terraform không có mục nào khớp, và issue thì bị đóng như trùng lặp mà không nêu bản vá.

Thứ trả lời được là một lần chạy: `terraform apply` cùng plan đó trên máy vận hành, Terraform **1.11.3**, không panic. Nên `terraform_version` đi từ `1.9.8` lên `1.11.3` ở **hai** chỗ ghim (module và `vending-pipeline`, hai bản sao độc lập).

Và ngay sau đó việc nâng thành **bắt buộc** chứ không còn là tuỳ chọn: state của `config-detective` vừa được 1.11.3 ghi, nên 1.9.8 từ chối đọc. Một lần chạy tay để chẩn đoán đã khoá luôn phương án "cứ để nguyên".

#### Hậu quả phụ: panic không nhả khoá

Lần chạy crash để lại một state lock của DynamoDB. Lần sau bất kỳ ai chạm vào layer đó — người hay pipeline — đều nhận một lỗi nói về `ConditionalCheckFailedException`, **không nhắc gì tới panic**. Nó đọc như một sự cố khác hẳn.

Hai trường phân biệt được nguồn gốc nằm trong khối `Lock Info`:

```
Who:     root@19b82b8b9864     <- CodeBuild
Version: 1.9.8                 <- ban trong pipeline
```

so với

```
Who:     laptop@MacBook-Air-...
Version: 1.11.3
```

Trong một buổi có hai khoá kẹt từ hai nguồn khác nhau. `force-unlock` là đúng cách chữa, nhưng **chỉ sau khi `pgrep -fl terraform` xác nhận không còn tiến trình nào sống** — gỡ khoá của một apply đang chạy là cách làm hỏng state thật.

#### Và một thiếu sót mà bug kia che mất

Khi panic được gỡ, apply thất bại lần nữa — lần này là quyền. Caller cấp `config:Describe*`, `Get*`, `List*` và **không một action ghi nào**. Pipeline đọc được mọi thứ và ghi được không gì.

Thứ che mất điều đó: khối `tu_choi_dich_vu` bên dưới dài và cụ thể, nên cả file **đọc như** một ranh giới ghi đã được cân nhắc kỹ. **Một danh sách Deny dài không hàm ý rằng có một danh sách Allow tương ứng.**

#### Kết quả đo được

```
aws_config_organization_managed_rule.this["cloud-trail-log-file-validation-enabled"]:
    Creation complete after 1m14s
Apply complete! Resources: 1 added, 0 changed, 0 destroyed
== ghi lai output (sau apply co -target)
organization_rules -> 10 muc
```

Bộ lọc gọi đúng một pipeline trong số năm; `gate.py` xếp "thêm một rule" là siết và cho qua; apply tạo thật; bước `-refresh-only` cập nhật output (lỗi 106 không tái diễn).

Và hỏi thẳng AWS, không qua Terraform:

```
10 organization config rule
ec2-ebs-encryption-by-default            8 account  CREATE_SUCCESSFUL
cloud-trail-log-file-validation-enabled  8 account  CREATE_SUCCESSFUL
```

**8 chứ không phải 15, và đó là đúng**: tổ chức có 15 account, `excluded_accounts` có 7 (nhóm nonprod/sandbox cộng management). 15 − 7 = 8.

Phép hỏi đó suýt đọc sai một lần: gửi từ account **management** thì cả hai rule trả về `NoSuchOrganizationConfigRuleException`. Chúng được tạo bằng `provider = aws.security`, nên chúng sống ở account delegated administrator. `NoSuchOrganizationConfigRule` ở đây nghĩa là *"không có trong account này"*, không phải *"không tồn tại"* — và hai câu đó dẫn tới hai kết luận trái ngược nhau.

---

### Lỗi 120 — một danh sách rỗng đi qua `plan` mà không để lại dấu vết nào

Bật hai pipeline vận hành còn lại (`config-rules`, `trail`). Cả hai khai:

```hcl
quyen_dich_vu = [{
  Sid      = "AssumeVaoSecurityVaLogArchive"
  Action   = ["sts:AssumeRole"]
  Resource = var.config_pipeline_role_arns    # default = []
}]
```

Tôi đặt `enable = true` và quên điền biến đó. `terraform plan`:

```
Plan: 22 to add, 0 to change, 0 to destroy.
```

Xanh. 22 resource mô tả đầy đủ. **Không một dòng nào trong bản plan nhắc tới việc statement đó có `Resource = []`** — vì rỗng không phải lỗi cú pháp, và Terraform không biết IAM nghĩ gì về nó.

Thứ tìm ra nó là một phép đếm:

```
grep -c "OrganizationAccountAccessRole" /tmp/p1.txt   ->  0
```

`0` nghĩa là cả bản plan không chứa ARN liên account nào. Nếu apply, IAM sẽ từ chối **cả policy** với một lỗi về định dạng ARN — không nhắc tới biến nào, ở bước tạo `aws_iam_role_policy`, tức sau khi plan đã xanh và người ta đã tin.

Và mô tả của chính biến đó đã cảnh báo: *"Mot danh sach rong lam statement ... co Resource rong, va IAM tu choi ca policy"*. **Một cảnh báo trong mô tả biến không chạy được.** Chữa bằng `check "bat_stage_thi_co_role"`: kêu lúc plan, nêu tên biến.

Đây là dạng đã gặp nhiều lần trong dự án này, lần này ở một chỗ mới: **rỗng đi qua mọi lớp kiểm vì không lớp nào hỏi "cái này có rỗng không"**.

#### `AuthorizationError` không phải `NotFound`, và khoảng giữa là chỗ dễ kết luận sai

Cần biết một SNS topic ở account khác có tồn tại không:

```
AuthorizationError ... is not authorized to perform: SNS:GetTopicAttributes
... because no resource-based policy allows the SNS:GetTopicAttributes action
```

Lỗi này **không** trả lời câu hỏi. SNS liên account trả cùng một thông báo cho *"topic không tồn tại"* và *"tồn tại nhưng bạn không đọc được"* — cố ý, để không lộ sự tồn tại. Đọc nó thành "topic không có" là sai; đọc thành "topic có" cũng sai.

Cách trả lời được là hỏi từ **bên trong** account đó. Và vì đường vào chính là role mà pipeline sẽ dùng, một lệnh trả lời hai câu: tên topic, và management có assume sang được không.

#### Kết quả — 5/5, đo trên một lần gọi thật

```json
{"loc": true, "da_khoi_dong": [],
 "kiem_ban_do": "DAY DU: 5 trong ban do, 5 mang tien to 'qh11-lz-', 7 tong"}
```

Năm pipeline, tất cả trong bản đồ, không cái nào mồ côi. Hai cái còn lại trong 7 (`MyImagePipeline1`, `shopping-cart-pipeline`) không thuộc landing zone.

Và một con số cũ được giải thích nhân tiện: `654560867047` từng nằm trong `unscoped_accounts` của layer `permission-sets` và bị nghi là "quên khai phạm vi". Nó là account **log-archive** — không thuộc `nonprod`/`prod`/`workloads` nào cả, giống network và security. Không có account workload nào bị quên.

#### Ba con số của một lần đo hỏng

Trong lúc làm, `plan` ra `18 to add` kèm `Error: Invalid value for input variable`, còn lần trước đó ra `22`. Chênh 4 không có lý do kiến trúc nào — và nó không cần một lý do:

```
terraform.tfvars line 72: drift_emails = "quang.hong.0991@gmail.com"
list of string required
```

`18` là bản plan **dở dang** của một lần chạy hỏng. Sau khi sửa thành `["..."]`, số về lại `22`.

Điều đáng giữ: một con số lấy từ một lần chạy **thất bại** trông giống hệt một con số lấy từ một lần chạy thành công. `grep '^Plan:'` không phân biệt được — chỉ `echo "exit=$?"` phân biệt được, và đó là lý do mọi lệnh đo trong nhật ký này đều đi kèm mã thoát.

---

#### Ghi chú — "đã commit" và "đã apply" là hai chuyện, và nó bẫy hai lần trong một buổi

Pipeline `qh11-lz-ops-permission-set` hỏng. Nghi phạm đầu tiên là lỗi 403 trên `account-baseline/terraform.tfstate` — layer `permission-sets` đọc state đó qua `terraform_remote_state`, và bản sửa (`var.state_chi_doc`) đã được viết, kiểm, commit ở `299c133`.

`terraform plan` ở layer pipeline:

```
Plan: 0 to add, 1 to change, 0 to destroy.
module.pipeline.aws_iam_role_policy.codebuild[0] will be updated in-place
  + Sid = "DocStateCuaLayerKhac"
  + "arn:aws:s3:::qh11-lz-tfstate-.../account-baseline/terraform.tfstate"
```

Bản sửa nằm trong git và **chưa bao giờ tới AWS**. Apply, chạy lại, xanh hết.

Và cùng dạng đó vừa bẫy một lần nữa, cách đấy vài phút: phép thử `tru` cho ra `"da_khoi_dong": []` — đúng kết quả mong đợi — trong khi log nói vending bị loại vì nó *chưa bao giờ* quan tâm `network/`. Hàm đang chạy cấu hình cũ; `terraform apply` chưa chạy. Kết quả đúng, lý do sai.

**Hai lần trong một buổi, cùng một khoảng trống: giữa "commit xanh" và "AWS đã biết".** Không công cụ nào trong dự án này bắc qua khoảng đó — `kiem-module.py`, `test-loc.py`, `terraform fmt` đều đọc **code**, còn drift job thì chỉ `plan` và chỉ chạy 19h mỗi ngày.

Thứ duy nhất phân biệt được là một lệnh: `terraform plan` ra `No changes`. Nên với mọi layer chưa được pipeline nào apply — mà `trigger-filter`, `ops-pipeline*`, `vending-pipeline` đều thuộc loại đó, chúng apply bằng tay — `No changes` là điều kiện phải kiểm **trước** khi tin bất cứ phép thử nào chạy trên hạ tầng đó.

---

#### Lỗi 119 — layer lồng nhau, và một phép kiểm che đúng cái nó đi tìm

Yêu cầu tiếp theo: *"phần network thì chỉ cần có code thay đổi là pipeline tự run"*.

Pipeline apply `landing-zone/network` là **vending** (stage B, D, cả hai assume role mạng), nên đường kích hoạt phải nằm trong bản đồ của vending. Một dòng.

Nhưng `landing-zone/network/ops` là một layer **riêng** — pipeline riêng, state riêng — và nó nằm **bên trong** `landing-zone/network`. So khớp là so khớp chuỗi, nên tiền tố `landing-zone/network/` cũng bắt mọi file trong `network/ops/`. Không có cách nào viết một tiền tố nghĩa là *"network/ nhưng không network/ops/"*.

Hậu quả nếu bỏ qua: mỗi lần sửa lớp vận hành mạng — thứ đổi **hằng ngày** — kéo vending chạy vô ích, kèm một cổng duyệt treo mang nhãn `A-tao-account`. Không phải lỗi, chỉ là ồn. Và ồn lâu thì người ta thôi đọc, nên nó là một lỗi chậm.

Nên `var.tru`: khoá giống `ban_do`, giá trị là tiền tố bị loại. Hai cách khai sai, cả hai im lặng, và cả hai bị bắt ở `loc.py` mỗi lần chạy **và** ở Terraform `check` lúc apply:

| Sai | Hậu quả |
|---|---|
| gọi tên pipeline không có trong `ban_do` | một ngoại lệ đã hết hạn — nó nói có ngoại lệ đang áp dụng, trong khi không |
| trừ chặn sạch một tiền tố `gom` | pipeline coi như mất tiền tố đó |

Cái thứ hai là dạng khó thấy nhất từng gặp trong dự án này: **hai dòng đều có nội dung**, và phải đọc *cả hai* mới biết cái sau vô hiệu hoá cái trước. Không có dòng nào trống để ai đó thấy là thiếu.

##### Và phép kiểm độ phủ đã che đúng cái nó đi tìm

`kiem-module.py` phép 10 (thêm ở lỗi 118) gộp tiền tố của **mọi** pipeline lại rồi hỏi *"có tiền tố nào chạm vào layer L không"*. Câu đó trả lời **sai** khi layer lồng nhau:

```
landing-zone/network/       trong ban_do cua vending
landing-zone/network/ops/   layer RIENG, pipeline rieng
```

`"landing-zone/network/ops/"` bắt đầu bằng `"landing-zone/network/"`, nên `network/ops` trông như **đã được phủ** — trong khi pipeline phủ nó (vending) *không apply layer đó*. Một dương tính giả theo chiều nguy hiểm: nó che đúng cái chỗ trống mà phép kiểm sinh ra để tìm.

Câu đúng là: layer `L` được phủ khi có **một** pipeline vừa apply `L` vừa có tiền tố chạm vào `L`.

Đột biến chứng minh phép sửa là thật, và nó chứng minh theo chiều **im lặng**: quay về logic gộp rồi bỏ `network/ops` khỏi `layer_thu_cong` → bộ kiểm **không kêu gì**. Một đột biến không làm bộ kiểm kêu thường nói về bộ kiểm; lần này nó nói rằng bản cũ đã hỏng.

##### `ten_ngan()` tự sai ngay lần đầu — lần thứ ba cùng một dạng

Để so theo từng pipeline thì phải biết thư mục nào là pipeline nào. `ops-pipeline/main.tf` có **hai** dòng khớp `ten = "..."`:

```
dong 159    ten = "SCP (catalog/scp.yaml)"   <- mot muc catalog
dong 283    ten = "ops"                      <- cai can tim
```

Khớp tràn lấy cái đầu tiên, nên bản đồ được tra bằng khoá `"SCP (catalog/scp.yaml)"` — không tồn tại — và layer `organization` bị báo là không được phủ. Chữa: neo vào khối `module "pipeline"`.

**Lần thứ ba trong cùng bộ kiểm này một phép khớp văn bản tràn bắt nhầm thứ khác** (trước đó: `modules/tf-pipeline` trong một chú thích kéo `tf-backend` vào danh sách caller; `locals {` đầu tiên ở `codebuild.tf` làm mọi local của `main.tf` thành "không khai"). Dạng lỗi không đổi: **một mẫu regex đủ lỏng để khớp đúng chỗ cần, cũng đủ lỏng để khớp một chỗ khác trước đó.**

##### Đo trên một diff thật

Commit `8fbe351` chạm 3 đường dẫn, hai trong số đó dưới `landing-zone/network/`:

```
landing-zone/network/ops/versions.tf     <- bi tru
landing-zone/network/outputs.tf          <- khop
KHOI DONG  qh11-lz-vending  (1 duong dan khop, vi du landing-zone/network/outputs.tf)
```

**1**, không phải 2. Chênh đúng một đường dẫn, và đó là toàn bộ bằng chứng — trên một diff thật đọc từ CodeCommit.

##### Một phép thử đạt vì lý do sai, lần thứ hai trong cùng ngày

Lần chạy **trước** apply cho ra `"da_khoi_dong": []` — kết quả đúng như mong đợi cho phép thử `tru`. Nhưng log nói khác:

```
bo qua  qh11-lz-vending  (khong duong dan nao khop ['landing-zone/account-baseline/'])
```

Một tiền tố, không có `landing-zone/network/`, không có phần `tru`. Hàm đang chạy cấu hình **cũ** — `terraform apply` chưa chạy. Vending bị loại vì nó chưa bao giờ quan tâm tới `network/`, không phải vì bị trừ ra.

Đọc `[]` thành *"phần trừ có tác dụng"* là đúng cái bẫy cả layer này sinh ra để chống. Thứ chữa được nó không phải cẩn thận hơn, mà là `loc.py` **in ra lý do** kèm phần `tru [...]` — nên hai trạng thái trông khác nhau, và không cần ai nhớ là phải nghi ngờ.

##### Cái giá còn lại, chưa sửa

Từ giờ mọi thay đổi code mạng sẽ chạy vending và dừng ở cổng duyệt mang nhãn `A-tao-account`, trong khi stage A thực tế là no-op. Cổng đó đang có nghĩa *"cho phép apply thay đổi mạng này"* — **nhãn nói sai việc nó đang làm**. Sửa được bằng `approve_stages`, nhưng đó là pipeline vending đã được quyết định để nguyên.

---

#### Một lỗi cũ lộ ra khi mở rộng `kiem-module.py`

Bộ kiểm HCL trước đây chỉ chạy trên **caller** của `modules/tf-pipeline`, nên một layer độc lập như `trigger-filter` không được kiểm gì cả — im lặng, không phải kết luận "không có gì sai". Thêm phép quét layer đơn (phép 9) làm lộ bốn báo sai:

```
account-baseline  var: ['harden_s']
network           var: ['f']   local: ['c_ec', 'c_f']
organization      var: ['s']
permission-sets                local: ['deny_ec']
```

Nguyên nhân: `[a-z_]+` **dừng lại ở chữ số đầu tiên**. Và nó không dừng đều hai bên — với `c_ec2 = 0.0116`, mẫu **khai** đòi `\s*=` ngay sau `c_ec`, gặp `2`, nên **không khớp gì cả**; mẫu **dùng** thì `local.c_ec2` vẫn ra `c_ec`. Hai bên cắt khác nhau nên sinh ra bốn cái tên ma: `harden_s3`, `c_ec2`, `c_f5`, `deny_ec2_*`.

Đây là dương tính giả, và dương tính giả là kẻ thù ở đây — bốn cái đủ để một người bắt đầu bỏ qua cả bộ kiểm. Sửa: `[a-z_][a-z0-9_]*`.

**Lỗi này đã nằm trong `kiem-module.py` từ đầu và không ai thấy**, vì nó chỉ lộ ra khi bộ kiểm được chỉ vào những layer có tên chứa chữ số. Mở rộng phạm vi của một bộ kiểm là một cách tìm lỗi *của chính bộ kiểm*.

---

### Ghi chú — hai lỗi của chính công cụ đọc log, cùng một dạng

`log.sh` viết ra để khỏi phải lần mò lấy log lần thứ năm. Nó hỏng hai lần, và cả hai lần đều **kết luận chắc chắn một điều sai**:

| Lỗi | Kết luận sai nó đưa ra |
|---|---|
| `--query` lồng hai phép chiếu rồi `\| [0][0]` trả `None` | *"action chưa chạy lần nào"* — trong khi nó đã chạy và đã hỏng |
| `sed` dùng `\(a\|b\)` trên macOS (BSD sed không hiểu `\|` trong biểu thức cơ bản) | *"lỗi xảy ra TRƯỚC bước plan"* — trong khi `== plan` có trong log và lỗi là lỗi Terraform |

Cùng một cơ chế: **một phép lọc không khớp trả về rỗng, và rỗng bị đọc thành một sự kiện có nghĩa.** Giống hệt lỗi 91, và giống chốt chặn state rỗng ở buildspec — chỉ khác là ở đó tôi đã lường trước nên nó hỏi lại `FIRST_APPLY`.

BSD sed đáng ghi riêng: `\|` là **phần mở rộng của GNU**. Code dùng nó chạy đúng trên CodeBuild (Linux) và im lặng sai trên máy người vận hành (macOS) — kiểu khác biệt không lộ ra trong CI. `sed -E` thì cả hai đều hiểu.

---

---

## 7as. Lỗi 94–95 — một guardrail tự khoá chính thứ nó bảo vệ

Ba account mới quét xong, `check-sweep.sh` in ra kết quả của từng account:

```
SweepResult: iam/password-policy, s3/pab:SKIP:ClientError,
             ap-southeast-1/vpc-016aa31d2867c0b53, ap-southeast-1/ebs-encryption,
             us-east-1/vpc-0f38bd69ee5f6f50a, us-east-1/ebs-encryption
```

Ba trên bốn mục hardening chạy được. Mục thứ tư trượt, **giống hệt nhau ở cả ba account** — nên là nguyên nhân hệ thống. Và `ClientError` không nói nó là gì.

### Lỗi 95 trước, vì không có nó thì không tìm ra lỗi 94

```python
except Exception as e:
    out.append('s3/pab:SKIP:' + type(e).__name__)
```

Mọi lời từ chối của AWS trong boto3 đều là `botocore.exceptions.ClientError`. AccessDenied, SCP chặn, tham số sai, dịch vụ chưa bật — **bốn nguyên nhân, bốn cách sửa, một chữ**. Đọc `SweepResult` xong vẫn không biết làm gì tiếp.

Mã lỗi thật nằm ở `e.response['Error']['Code']`, cách đó một dòng.

Đây là lần **thứ năm** của cùng khuyết điểm trong dự án này — lỗi 75 (`|| true` nuốt trường hợp thứ ba), lỗi 80 (`A || B` khi A thành công mà không làm gì), lỗi 84 (`2>/dev/null` nuốt stderr), và một lần nữa của chính tôi trong cùng phiên này, ở `accept-ram.sh`. Nó không phải một lỗi ngẫu nhiên; nó là một **thói quen**: bắt lỗi để chương trình chạy tiếp, rồi vứt đi thứ duy nhất giải thích được vì sao.

### Lỗi 94 — cái mà mã lỗi thật chỉ ra

Gọi thẳng API đó bằng tay trong một account:

```
An error occurred (AccessDenied) when calling the PutPublicAccessBlock operation:
User: arn:aws:sts::913051689123:assumed-role/OrganizationAccountAccessRole/thu-pab
is not authorized to perform: s3:PutAccountPublicAccessBlock
with an explicit deny in a service control policy: ... p-2oni53yp
```

`p-2oni53yp` là SCP `baseline` — **do chính repo này dựng ra**:

```hcl
# Khong ai duoc mo public access block o muc account
jsonencode({
  Sid      = "ProtectS3PublicAccessBlock"
  Effect   = "Deny"
  Action   = ["s3:PutAccountPublicAccessBlock"]
  Resource = "*"
}),
```

Không có `Condition` — statement **duy nhất** trong SCP đó thiếu, trong khi mọi statement khác đều mang `local.exempt_condition`.

`PutAccountPublicAccessBlock` là **một API cho cả bật lẫn tắt**. Nó đặt cả bốn cờ, dù `true` hay `false`. SCP không đọc được nội dung request và không có condition key nào cho giá trị bên trong `PublicAccessBlockConfiguration`. Nên cấm cả cụm nghĩa là:

> Account-level public access block **không bao giờ bật được** ở bất kỳ account nào trong tổ chức.

Chú thích ghi *"không ai được mở"* — ý là chặn ai đó **tắt** bảo vệ. Kết quả thật là bảo vệ **chưa bao giờ được đặt**.

### Vì sao nó sống sót lâu

| Nhìn từ đâu | Thấy gì |
|---|---|
| `scp_summary` | `baseline` tồn tại, gắn ở ROOT, 1682 byte |
| Console AWS | Chính sách có, nội dung đúng, tên nghe đúng |
| `terraform apply` của account-baseline | Xanh — Lambda bắt lỗi và ghi `SKIP`, cố ý, để một lần bị từ chối không làm hỏng cả đợt |
| Danh sách hardening trong README | Bốn mục, tất cả `true` |

Không nguồn nào nói dối. Tất cả cùng mô tả một cấu hình **có** bảo vệ. Thứ duy nhất mâu thuẫn là bảy ký tự nằm giữa một chuỗi sáu mục, trong một output của CloudFormation mà không ai đọc trừ khi đi tìm.

Và trạng thái đó **trông an toàn hơn** cả hai lựa chọn thay thế — SCP tồn tại, tên đúng, tóm tắt đầy đủ — trong khi nó là lựa chọn duy nhất không bảo vệ gì.

### Sửa, và cái giá của nó

`s3_pab_automation_roles` — một đường miễn trừ **riêng cho một API**, không dùng chung `scp_exempt_role_names` vốn miễn trừ cả SCP baseline. Không có giá trị mặc định, có chủ đích: tên role tuỳ bản triển khai (ở đây layer `organization` dùng project `qh11-lz` còn `account-baseline` dùng `quh11-lz` — **khác nhau**), và một tên đoán bừa sẽ tạo ra một Deny không áp dụng cho ai, tức một lỗ hổng im lặng thay vì một lỗi.

`check "s3_pab_co_the_bat_duoc"` kêu khi statement bật mà danh sách rỗng.

Đánh đổi, nói thẳng trong mô tả biến: **ai tạo được một role trùng tên trong một account thì tắt được public access block của account đó.** `baseline` cấm tạo IAM *user*, nhưng không cấm tạo *role*.

Đo lại sau khi vá, cùng một lệnh:

```
SweepResult: iam/password-policy, s3/public-access-block,
             ap-southeast-1/ebs-encryption,
             ap-southeast-1/default-sg:sg-03aeaedba63e2d244,
             us-east-1/ebs-encryption
```

> **Điều đáng giữ lại:** lỗi 94 không tìm ra được nếu không sửa lỗi 95 trước. Một guardrail sai nằm sau một thông báo lỗi vô dụng, và thông báo đó là thứ rẻ hơn nhiều để sửa. Chi phí thật của việc nuốt lý do không phải mười phút chẩn đoán — mà là những thứ **không bao giờ được chẩn đoán**.

---

## 7ar. Lỗi 91–93 — ba lưới an toàn, cùng một cách hỏng

Tạo ba account đầu tiên bằng catalog. Mọi thứ xanh: `lint.sh` sạch, `plan` sạch, `Apply complete! 4 added, 1 changed, 0 destroyed`. Ba lỗi lộ ra trong vòng mười phút sau đó, và cả ba đều **không phát ra tín hiệu nào**.

### Lỗi 91 — một chẩn đoán sai, và ba thứ hỏng vì nó

Người dùng dán ra `terraform output ou_ids`:

```
"Data Analytics" = "ou-o5ci-lovqpj5y"
"Infrastructure" = "ou-o5ci-popibm5d"
"Sandbox"        = "ou-o5ci-ivhzg9qe"
"Security"       = "ou-o5ci-g5rv7do1"
"Suspended"      = "ou-o5ci-k9ld7ek7"
"Workloads"      = "ou-o5ci-fz0yuca3"
"Non-Production" = "ou-o5ci-syf8rqi7"
"Production"     = "ou-o5ci-75f3uqe6"
```

Tôi đọc thành **cây phẳng** — `Production` ngang hàng với `Workloads` — rồi kết luận `prod_guard` nhắm `"Workloads/Production"` sẽ giải ra `null` và bị lọc đi im lặng, tức account production đang chạy không có guardrail nào.

**Sai.** Và bằng chứng bác bỏ nằm ngay trong khối tôi vừa đọc: `Non-Production` và `Production` in ra **sau** `Workloads`, trong khi Terraform sắp xếp khoá theo bảng chữ cái. `N` và `P` đứng trước `W`. Chúng chỉ có thể nằm sau nếu khoá thật là `Workloads/Non-Production` và `Workloads/Production` — tức cây **lồng nhau**, đúng như `ou_structure` mặc định.

Một câu lệnh dứt điểm:

```
$ aws organizations list-policies-for-target --target-id ou-o5ci-75f3uqe6 \
    --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text
FullAWSAccess   qh11-lz-prod-guard
```

Nó đang gắn, và vẫn gắn suốt từ đầu.

### Ba thứ tôi làm hỏng vì tin vào chẩn đoán đó

**1. Một check sai về nguyên lý.** Tôi thêm `check "moi_ou_deu_co_scp"`, kêu tên mọi OU không có SCP gắn **trực tiếp**. Nhưng **SCP di truyền xuống**: chính sách gắn ở `Workloads` áp dụng cho `Workloads/Production` và mọi account bên trong. Nên check đó kêu tên `Workloads/Non-Production` — một OU đang được `network_lock` phủ đầy đủ qua OU cha.

Chiều ngược lại còn tệ hơn: `baseline` và `region_lock` gắn ở ROOT, nên **không OU nào** có thể "không được chính sách nào phủ". Câu hỏi vô nghĩa, và một phép kiểm luôn đúng không phải một phép kiểm.

Repo này viết trong `wire-backends.sh` rằng *"một cảnh báo kêu mãi về thứ không sai là cách chắc chắn nhất để người ta thôi đọc cảnh báo"*. Tôi vi phạm đúng câu đó, cách vài giờ.

**2. Một bảng tóm tắt đọc như hỏng.** Tôi đổi `scp_summary` thành hai danh sách song song — `targets` là ID, `targets_khai` là TÊN. Nhưng map trong HCL duyệt theo **khoá đã sắp xếp**, còn danh sách khai giữ **thứ tự đã viết**. Hai danh sách lệch nhau, và `terraform plan` ghép chúng theo **vị trí**:

```
~ "Workloads"      -> "ou-o5ci-lovqpj5y"     <- ID của Data Analytics
~ "Data Analytics" -> "ou-o5ci-ivhzg9qe"     <- ID của Sandbox
~ "Sandbox"        -> "ou-o5ci-fz0yuca3"     <- ID của Workloads
```

Attachment hoàn toàn đúng; chỉ cách in là sai. Nhưng nó đọc y hệt một bảng ánh xạ hỏng — thứ tệ nhất mà một bảng tóm tắt về guardrail có thể làm. Giờ nó là **một map `tên → id`**, không phải hai danh sách cạnh nhau.

**3. Một chú thích khẳng định chuyện chưa xảy ra.** Tôi viết vào `scp.tf` rằng *"Đã xảy ra thật: ou_structure khai phẳng, prod_guard nhắm Workloads/Production…"*. Đúng loại chú thích mà cả tài liệu này tồn tại để chống lại — nói một điều mà code và thực tế đều không đúng.

### Cái gì còn giữ lại

Cơ chế im lặng **là có thật**: `try(local.ou_ids[t], null)` cộng với `if item.target != null` biến một target gõ sai thành zero attachment, không lỗi, không cảnh báo. Nó chưa nổ ở đây, nhưng `ou_structure` là một **biến** — đổi cây là mọi target viết theo đường dẫn đều trượt.

Nên giữ ba thứ, bỏ một:

| Giữ | |
|---|---|
| Giải target theo đường dẫn đầy đủ rồi thử đoạn cuối | Cả hai hình dạng cây đều chạy |
| Precondition: policy không còn target nào | Chặn plan thay vì biến mất |
| Precondition: target không giải được thành ID | Kèm danh sách tên OU có thật |
| ~~check "moi_ou_deu_co_scp"~~ | Bỏ — SCP di truyền, câu hỏi vô nghĩa |

> **Bài học không nằm ở SCP.** Tôi có đủ dữ liệu để bác bỏ chẩn đoán của mình ngay trong khối đầu tiên — thứ tự sắp xếp của tám dòng — và tôi đã đọc lướt qua nó. Rồi viết ba thay đổi, một chú thích khẳng định, và một mục trong nhật ký này, tất cả đứng trên một suy luận chưa ai kiểm. Câu lệnh kiểm mất bốn giây, và **chính tôi đã viết nó ra** trong cùng tin nhắn với chẩn đoán sai — nhưng viết cho người khác chạy, chứ không chờ kết quả trước khi kết luận.

### Lỗi 92 — phép kiểm quay lưng lại với thực tế

`lint.sh` giữ danh sách OU hợp lệ để chạy được offline. Danh sách đó là:

```python
OUS = {"Infrastructure", "Security", "Workloads", "NonProd", "Prod",
       "Analytics", "Sandbox", "Suspended", "Root"}
```

**Không tên nào trong `NonProd`, `Prod`, `Analytics` được `ou_structure` sinh ra.** Mặc định của nó cho `Non-Production`, `Production`, `Data Analytics`. Nên phép kiểm chấp nhận ba tên không tồn tại ở đâu cả và từ chối ba tên có thật.

Nó "chạy đúng" suốt vì bản đồ `ou_ids` được gõ tay bằng tên ngắn — hai cái sai bù nhau.

Phần nguy hiểm nằm ở bảng thứ hai, keyed y hệt:

```python
alloc = ALLOCATED.get(a.get("ou"))
if alloc:
    ...kiem CIDR co nam trong dai cua OU khong...
```

Không có nhánh `else`. Nên **sửa catalog cho đúng thực tế** — đổi `NonProd` thành `Non-Production` — làm `ALLOCATED.get()` trả `None` và tắt hẳn phép kiểm cấp phát CIDR. `lint.sh` vẫn in **"Sạch. 0 cảnh báo"**. Một `/16` đặt sai dải sẽ chỉ lộ ra khi hai spoke trùng nhau, và lúc đó sửa nghĩa là **xoá VPC**.

Đây là biến thể ác nhất của lỗi 27: không phải im lặng vì không có gì, mà im lặng vì **một hành động đúng** đã vô hiệu hoá phép kiểm.

**Sửa:** cả hai bảng nhận mọi cách viết, và một OU không có dải cấp phát giờ là **lỗi** chứ không phải phép kiểm bị bỏ qua.

### Lỗi 93 — lưới an toàn mù ở đúng lần chạy cần nó

`unmapped_accounts` tồn tại để trả lời một câu: *có account nào chưa ai khai phạm vi không* — vì account không có phạm vi thì không nằm trong `accounts_by_scope`, và **không ai vào được nó qua Identity Center**.

Sau lần apply tạo ba account:

```
unmapped_accounts = tolist([])
```

Chạy `terraform plan` lần nữa, không đổi một dòng nào:

```
~ unmapped_accounts = [
    + "598122632665",
    + "792207721718",
    + "913051689123",
  ]
```

Nó tính từ `data.aws_organizations_organization`, mà data source được đọc **trước** khi resource được tạo. Ở đúng lần chạy duy nhất mà câu hỏi đó quan trọng, câu trả lời là rỗng — và rỗng đọc y hệt "mọi thứ đều ổn".

Cùng lúc, `paste_permission_sets` in ra khối để dán sang layer permission-sets:

```
accounts_by_scope = {
  nonprod   = ["169873795883"]
  prod      = ["761558631239"]
}
```

Ba account vừa tạo **không có trong đó**. Ai dán khối này sang sẽ cấp quyền cho những account cũ và bỏ qua những account mới — và không có gì trong màn hình đó nói rằng danh sách bị thiếu.

Nguyên nhân: `by_scope` chỉ đọc `var.account_scopes` (bản đồ gõ tay), trong khi catalog **đã có** trường `scope` bắt buộc mà `lint.sh` chặn nếu thiếu. Thông tin có sẵn, chỉ là không ai nối hai đầu.

**Sửa:** gộp `scope` của catalog vào — nó lấy từ resource `aws_organizations_account`, nên đúng ngay ở lần apply đầu, không phụ thuộc thời điểm đọc data source. Và mô tả của output nói thẳng rằng "rỗng" ở lần apply tạo account **không phải bằng chứng**.

> **Cả ba cùng một hình dạng.** Không cái nào làm `apply` đỏ. Mỗi cái đều có một màn hình khẳng định điều ngược lại với sự thật — `scp_summary` in target đã khai, `lint.sh` in "Sạch", `unmapped_accounts` in rỗng. Và cả ba đều chỉ lộ ra khi hỏi **một câu khác**: OU này đang chịu chính sách nào, phép kiểm kia có thật sự chạy không, chạy lại plan lần hai xem có gì đổi không.

---

## 7aq. Lỗi 90 — "not found" về một cái bàn đang nằm giữa phòng

Nối xong backend, `init` sạch, `lint.sh` sạch. `terraform plan`:

```
Error: Error acquiring the state lock

ResourceNotFoundException: Requested resource not found
Unable to retrieve item from DynamoDB table "qh11-lz-tfstate-lock"
```

Bảng đó tồn tại. Ba phút trước chính tay tôi `delete-item` trên nó và nó nhận lệnh. `terraform output -raw lock_table` in ra đúng cái tên ấy.

### Một cái tên luôn được giải trong account của người gọi

Backend S3 khai bảng khoá bằng **tên**, không phải ARN. DynamoDB nhận `TableName` và tra trong account của người gọi — không có bước nào hỏi "có phải bảng này thuộc account khác không". Không tìm thấy thì trả `ResourceNotFoundException`.

`tf-backend` có cấp quyền chéo cho `state_writer_accounts`:

```hcl
Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
Resource = aws_dynamodb_table.lock[0].arn
```

Quyền đó **đúng và vô dụng cùng lúc**: nó cho phép account khác gọi, nhưng không giúp họ gọi được tên. Muốn dùng thì phải địa chỉ bằng ARN, mà `dynamodb_table` của backend chỉ nhận tên.

Vì sao layer cha không gặp: `backend.hcl` của nó có `profile = "default"` — mọi thao tác state chạy bằng account chủ bảng. `backend.hcl` của `ops` **không có dòng đó**, vì `backend_profiles` chưa khai lớp này.

### Ba lớp im lặng chồng lên nhau

| | |
|---|---|
| **S3 vẫn chạy** | Bucket policy cấp quyền theo prefix cho account khác, và S3 địa chỉ bằng bucket + key — không có chuyện "tên giải trong account của mình". Nên nửa S3 hoạt động, nửa DynamoDB không |
| **`init` vẫn sạch** | `init` không lấy khoá. Lỗi để dành tới `plan`, sau khi người ta đã tin là xong |
| **Thông báo nói "not found"** | Không phải "không phải của bạn". Chỗ đầu tiên ai cũng đi kiểm là bảng có tồn tại không — và nó tồn tại |

### Và cái bẫy thứ tư, nằm sẵn trong repo

`terraform.tfvars.example` đã để sẵn dòng cần thiết:

```hcl
# "demo/network-lz-full/ops" = "default"
```

Đường dẫn cũ, từ trước khi lớp đó chuyển sang `landing-zone/network/ops`. `backend_configs` tra cứu bằng `try(var.backend_profiles[dir], "")` — khoá không khớp layer nào thì **không bao giờ được đọc**. Ai bỏ chú thích dòng đó ra sẽ khai một profile không có tác dụng, và `backend.hcl` sinh ra thiếu dòng `profile` **y hệt như khi quên khai hẳn**.

Đã sửa đường dẫn, và thêm `check "backend_profiles_tro_dung_layer"` so khoá với `local.layers` để lần sau gõ sai là plan nói ngay, kèm danh sách khoá hợp lệ.

### Sửa

```hcl
# landing-zone/tf-backend/terraform.tfvars
backend_profiles = {
  "landing-zone/network"     = "default"
  "landing-zone/network/ops" = "default"
}
```

```bash
cd landing-zone/tf-backend && terraform apply && ./wire-backends.sh
cd ../network/ops && terraform init -reconfigure -backend-config=backend.hcl
```

> **Quy tắc rút ra:** với `lock_mode = "dynamodb"`, **mọi** layer có resource ở account khác đều bắt buộc có dòng `backend_profiles` trỏ về account chủ bảng khoá. Không phải tuỳ chọn cho gọn — không có nó thì `plan` không chạy được.

---

## 7ap. Lỗi 88 — dấu vết của một state đã xoá, và một thông báo đổ lỗi cho AWS

Nối lớp `ops` vào backend S3 sau khi dựng lại toàn bộ layer `network`. Object state cũ đã bị xoá trong lần teardown, key vẫn giữ nguyên như thiết kế. Tạo sẵn một object rỗng theo đúng hướng dẫn trong README, rồi `terraform init -reconfigure`:

```
Error: Error refreshing state: state data in S3 does not have the expected content.

The checksum calculated for the state stored in S3 does not match the checksum
stored in DynamoDB.

Calculated checksum:
Stored checksum:     c92a3ed1fe4984129b73c4bdb0d26846

This may be caused by unusually long delays in S3 processing a previous state
update. Please wait for a minute or two and try again.
```

Câu cuối là chỗ đáng nói. Nó **đổ lỗi cho độ trễ của S3** và bảo đợi — một lời khuyên vô hại, dễ tin, và sai hoàn toàn. Đợi bao lâu cũng không hết, vì không có gì đang trên đường tới cả.

### Bảng khoá giữ hai loại dòng, không phải một

Khi `lock_mode = "dynamodb"`, bảng khoá giữ **hai** loại bản ghi cho mỗi key:

| `LockID` | Sống bao lâu |
|---|---|
| `<bucket>/<key>` | Chỉ trong lúc một lệnh đang chạy — `apply` xong là mất |
| `<bucket>/<key>-md5` | **Vĩnh viễn**, cho tới khi có người xoá tay |

Dòng thứ hai là digest của state gần nhất, dùng để phát hiện S3 trả về bản cũ. Nó **không** bị xoá khi object S3 bị xoá — `aws s3 rm` không biết gì về DynamoDB.

Nên trình tự đã xảy ra là:

1. Teardown xoá object state → digest `c92a3ed1…` nằm lại
2. `put-object` tạo một object **rỗng** → md5 của nó là chuỗi rỗng
3. `init` so chuỗi rỗng với `c92a3ed1…` → lệch

`Calculated checksum:` để trống ngay trong thông báo — dấu hiệu rõ nhất rằng object không có nội dung, chứ không phải S3 chậm. Nhưng một trường bỏ trống đọc như một trường chưa được điền, không như một câu trả lời.

### Sửa

```bash
cd landing-zone/tf-backend
TABLE=$(terraform output -raw lock_table)

aws dynamodb delete-item --region ap-southeast-1 --table-name "$TABLE" \
  --key '{"LockID":{"S":"<bucket>/demo-network-lz-full/ops/terraform.tfstate-md5"}}'

aws s3 rm "s3://<bucket>/demo-network-lz-full/ops/terraform.tfstate"
cd ../network/ops && terraform init -reconfigure -backend-config=backend.hcl
```

Xoá cả object rỗng vì nó không còn tác dụng gì: bước `put-object` trong README có mặt để thoả điều kiện `s3:prefix` của `ListBucket` khi prefix hoàn toàn mới — mà prefix `demo-network-lz-full/` đã có sẵn state của layer cha.

### Điều đáng giữ lại

Chú thích **trong chính repo này** (`tf-backend/outputs.tf`) dặn cách đổi khoá state, và nó viết:

```
#   aws s3 rm s3://<bucket>/demo-network-lz-full/terraform.tfstate
#   sua dong nay, chay ./wire-backends.sh, terraform init -reconfigure
```

Ba bước, thiếu một. Người làm theo đúng từng chữ vẫn hỏng — và hỏng ở một thông báo nói về S3, cách xa chỗ sai ba bước. Cùng họ với lỗi 32: một câu dặn nghe hợp lý, trong tài liệu do chính mình viết.

Đã bổ sung bước xoá digest vào đúng chỗ đó, kèm nguyên văn thông báo lỗi để lần sau tìm bằng `grep` là ra.

---

## 7ao. Lỗi 86 — một dòng sai suốt nhiều tháng vì chưa ai chạy nó

Viết `lint.sh` cho catalog yêu cầu tạo account, thêm phép kiểm "CIDR phải nằm trong dải cấp phát của OU", nạp bảng ở doc 17 vào, và Python từ chối ngay dòng đầu:

```
ValueError: 10.10.0.0/14 has host bits set
```

Một `/14` bắt đầu ở **bội số của 4** ở octet thứ hai. Nên nó chỉ có thể là `10.8.0.0/14` (phủ `10.8`–`10.11`) hoặc `10.12.0.0/14` (`10.12`–`10.15`). Khoảng `10.10`–`10.13` mà bảng cấp phát mô tả **không viết được thành một `/14` nào** — phải là hai `/15`.

Các dải khác đúng: `10.20.0.0/14` (20 chia hết cho 4) và `10.60.0.0/14` (60 cũng vậy). Chỉ dòng NonProd sai.

Nó nằm ở **sáu file**: doc 06, doc 13, doc 17, `landing-zone/network/outputs.tf`, `landing-zone/network/variables.tf`, và bảng gốc. Sống sót nhiều tháng, đi qua mọi lần đọc lại, và không gây ra một sự cố nào.

Lý do nó sống lâu như vậy đáng ghi hơn bản thân lỗi:

> **Chưa có công cụ nào phân tích chuỗi đó.** Bảng ghi cả hai dạng — `10.10.0.0/14 (10.10 - 10.13)` — và con người đọc phần trong ngoặc. Phần trong ngoặc đúng, nên ý định được truyền đạt đúng, nên không ai phát hiện phần CIDR là một phép tính không tồn tại. Terraform không đọc bảng đó; nó chỉ đọc CIDR `/16` của từng spoke, và tất cả đều hợp lệ.
>
> Nó chỉ nổ khi có một phép kiểm **tự động** nạp đúng chuỗi đó vào `ipaddress.ip_network()`. Cùng họ với lỗi 69 và 77: một chuỗi hoàn toàn hợp lý trong ngữ cảnh của nó, đặt vào một ngữ cảnh khác thì thành cú pháp của thứ khác — và ở đây "ngữ cảnh khác" chỉ đơn giản là *có ai đó thật sự tính toán nó*.

Sửa: giữ nguyên khoảng `10.10`–`10.13` — mọi địa chỉ đang dùng nằm trong đó — và viết đúng thành `10.10.0.0/15` + `10.12.0.0/15`. `lint.sh` không lưu dải dưới dạng CIDR nữa mà lưu **khoảng octet**, vì đó mới là thứ con người thoả thuận với nhau.

### Lỗi 87 — chín layer vi phạm chính sách do chúng dựng ra

Thêm `local.azs` vào `account-baseline` thì đọc phải khối tag mặc định của nó:

```hcl
common_tags = {
  Environment = "shared"
  ...
}
```

Và trong `landing-zone/organization/variables.tf`:

```hcl
Environment = { allowed_values = ["dev", "staging", "prod", "sandbox"] }
```

**Chín layer** gắn `shared`. Tag policy do chính repo dựng ra không có giá trị đó.

Lý do không ai phát hiện: **tag policy của AWS mặc định chỉ báo, không chặn.** Nó đánh dấu resource không tuân thủ trong Resource Groups và trong báo cáo, nhưng nó không làm `apply` đỏ trừ khi bật enforcement cho từng loại resource cụ thể. Nên chín layer chạy bình thường suốt, và hậu quả duy nhất là: nhóm theo tag `Environment` trong Cost Explorer có một giá trị không ai mong đợi, và bảng tuân thủ có một cột đỏ mà không ai đọc.

`billing-guard` là layer **duy nhất** làm đúng, và nó còn kèm sẵn câu trả lời cho câu hỏi "vậy giá trị nào mới đúng":

```hcl
Environment = "prod" # ha tang quan tri, khong phai sandbox
```

Chín layer kia giờ theo tiền lệ đó.

> Cùng họ với lỗi 86, và cùng một phiên: **một quy tắc được viết ra ở một chỗ, và không có gì đối chiếu nó với chỗ dùng.** Ở lỗi 86 là bảng CIDR chưa ai phân tích; ở đây là danh sách giá trị hợp lệ chưa ai so. Cả hai chỉ lộ ra khi có người viết một công cụ *đọc* thứ đã nằm đó từ lâu.

---

## 7an. Palo Alto không có bootstrap — một thiết bị $1.3/giờ không làm gì

`enable_appliances = true` dựng đủ: GWLB, GWLB endpoint, target group GENEVE, security group, instance Palo Alto, và toàn bộ định tuyến ép lưu lượng vào qua thanh tra. F5 bên cạnh có `f5-runtime-init.yaml` cài DO/AS3/TS và áp declaration.

Palo Alto **không có `user_data` nào cả**.

Nghĩa là nó boot với cấu hình gốc: không interface dữ liệu, không zone, không virtual router, không một rule nào. Một VM-Series ở trạng thái đó không phải là "firewall chưa cấu hình" — nó là một EC2 `m5.xlarge` giá ~$1.3/giờ không nhận được gói tin nào.

Triệu chứng: **GWLB báo target `unhealthy` mãi mãi**, không log, không lỗi. Và đây là chỗ đáng chú ý — `terraform plan` xanh, `apply` xanh, mọi resource tồn tại đúng như khai báo. Cùng hình dạng với cấu hình strongSwan: phần duy nhất không có gì kiểm được ngoài việc thử.

### Bootstrap của VM-Series không phải là một script

```hcl
user_data = "vmseries-bootstrap-aws-s3bucket=${bucket}"
```

Đúng một dòng. PAN-OS đọc `user_data` như một chuỗi `khoá=giá trị`, **không phải shell** — viết một script bash vào đó thì nó bỏ qua, im lặng, và thiết bị lên với cấu hình gốc.

Cấu hình thật nằm trong S3, theo đúng bốn thư mục:

| | |
|---|---|
| `config/init-cfg.txt` | Thiết bị lấy IP thế nào, bật plugin nào |
| `config/bootstrap.xml` | Toàn bộ cấu hình: interface, zone, virtual router, rule |
| `license/`, `software/`, `content/` | **Rỗng, nhưng phải tồn tại** |

Ba thư mục rỗng đó là cái bẫy đầu tiên: thiếu **bất kỳ** cái nào thì PAN-OS bỏ qua **cả gói** bootstrap — và bỏ qua im lặng. S3 không có thư mục thật, nên phải tạo ba object rỗng kết thúc bằng `/`.

Cái bẫy thứ hai là quyền: `s3:ListBucket` là quyền trên **chính bucket**, không phải trên object. Thiếu nó thì `GetObject` vẫn chạy mà bootstrap vẫn bị bỏ qua, vì PAN-OS không liệt kê được bốn thư mục.

### Hai giao diện, và thứ tự của chúng

Bản cũ gắn một ENI duy nhất. Không chạy được, và lý do đáng nhớ:

> **GWLB gửi GENEVE tới ENI *chính* của instance.** Mặc định PAN-OS lấy `eth0` làm giao diện **quản trị**. Nên với một ENI, lưu lượng cần quét đến một cổng không xử lý được gói tin, còn mặt phẳng dữ liệu thì nằm ở một ENI không tồn tại.

Cách sửa là `op-command-modes=mgmt-interface-swap` trong `init-cfg.txt`, cộng một ENI thứ hai:

| ENI | Subnet | Sau khi swap |
|---|---|---|
| `eth0` | `ingress_appliance` | `ethernet1/1` — dữ liệu, GWLB gửi vào đây |
| `eth1` | `ingress_mgmt` | giao diện quản trị |

Subnet `ingress_mgmt` đã tồn tại trong code từ trước và **không ai dùng** — dấu vết của một thiết kế hai NIC chỉ đi được nửa đường.

### Mật khẩu: cố ý không đặt

`bootstrap.xml` không đặt mật khẩu admin. VM-Series trên AWS đăng nhập lần đầu bằng key pair (`ssh -i key.pem admin@<ip mgmt>`), rồi tự đặt.

Một phash viết sẵn trong XML sẽ nằm trong S3 **và** trong state, và nó sẽ sống lâu hơn ý định của người viết nó. Đổi lại: `pa_key_name` để rỗng thì instance vẫn tạo được nhưng **không ai vào được** — chấp nhận được khi chỉ chạy `plan`, không chấp nhận được khi apply thật. Mô tả biến nói thẳng điều đó.

### Phép kiểm cho thứ không kiểm được

`templatefile()` chỉ ghép chuỗi. `bootstrap.xml` có thể thiếu thẻ đóng, thiếu cả một khối bắt buộc, hay sai cấu trúc hoàn toàn — `plan` vẫn xanh, `apply` vẫn xanh, object vẫn lên S3.

Nên `plan-check.sh` mở chính file template, thay nội suy bằng giá trị giả, phân tích XML, và đòi sáu khối phải có mặt. Thử phá ba kiểu để chắc nó không phải một dấu tích trang trí:

| Phá | Kết quả |
|---|---|
| Bỏ một thẻ đóng | `bootstrap.xml SAI CU PHAP: mismatched tag: line 114` |
| Bỏ khối `<profiles>` | `THIEU: profile quan tri interface - health check cua GWLB khong bao gio dat` |
| Bỏ `plugin-op-commands` | `init-cfg.txt thieu khoa: plugin-op-commands` |

### Lỗi 85 — công cụ kiểm chứng báo sai

Chạy `plan-check.sh` trên máy đang có hạ tầng thật:

```
✓ DAY DU: appliance + firewall + CDN  (61 resource se duoc tao)
✗ Firewall che do alert  (plan khong tao resource nao)
      No changes. Your infrastructure matches the configuration.
✗ TGW attachment cua security VPC  (khong thay ... trong plan)
✗ Network Firewall  (khong thay ... trong plan)
```

**17 đạt, 8 lỗi** — cho một code không có gì sai.

Mọi khẳng định của script có dạng *"plan trên state rỗng phải tạo resource X"*. Trên một máy đã apply, `plan` so với hạ tầng đang chạy và trả về `No changes`. Câu trả lời đúng, cho một câu hỏi khác.

Điều làm nó tệ hơn một lỗi thường: **bảy dòng lỗi nói về bảy resource khác nhau**, nên nó đọc như bảy vấn đề độc lập. Người đọc sẽ đi tìm bảy nguyên nhân, và không cái nào tồn tại.

Sửa: chép code sang thư mục tạm, **gỡ khối `backend`**, plan trên state cục bộ rỗng. Không đụng vào state thật, không đụng vào hạ tầng thật, và chạy được mọi lúc.

Việc gỡ `backend` là phần bắt buộc chứ không phải tiện tay: giữ lại thì `terraform init` trong thư mục tạm nối vào **đúng cái state thật đang cố tránh** — và một script kiểm tra đọc được state thật là một script có thể sửa state thật.

Thêm một chốt chặn: sau `init`, nếu `terraform state list` không rỗng thì dừng ngay. Thiếu nó thì một khối `backend` sót lại sẽ làm mọi khẳng định đổi nghĩa mà không báo gì.

> Cùng họ với lỗi 27, 46 và 73: **một công cụ kiểm chứng sai còn đắt hơn không có công cụ nào**, vì nó tiêu thời gian của người đọc theo hướng ngược hẳn với sự thật.

### Lỗi 84 — cùng một khuyết điểm, lần thứ ba trong một phiên

Chạy `plan-check.sh` lần đầu:

```
✗ Khong lay duoc AMI gia - dat bien DUMMY_AMI=ami-xxxx roi chay lai
```

`2>/dev/null` trên lệnh `aws ssm get-parameter`. Hết token, sai region, và thiếu quyền `ssm:GetParameter` đều cho ra **đúng một dòng** đó — trong khi ba cách sửa khác hẳn nhau.

Cùng khuyết điểm với lỗi 75 (`|| true` nuốt "không có unit nào") và lỗi 80 (`A || B` khi A thoát 0 mà không in gì), cả ba trong **cùng một phiên làm việc**. Nó không phải một sai sót hiếm gặp; nó là thói quen viết shell mặc định.

Sửa: giữ `stderr` lại và in ra khi thất bại, kèm ba nguyên nhân hay gặp và cách sửa từng cái. Thêm một lối thoát thứ hai qua `ec2:DescribeImages` — quyền khác với `ssm:GetParameter`, và vài tổ chức cấp cái này mà không cấp cái kia.

> Bài học lặp lại lần thứ năm trong tài liệu này: thứ đắt nhất không phải lỗi làm `apply` đỏ, mà là cấu hình **đi qua được mọi công cụ** rồi mới sai lúc chạy. Với mỗi thứ như vậy, phải tự dựng phép kiểm — và phải thử phá nó, vì một phép kiểm chưa bao giờ thất bại thì chưa biết nó có kiểm gì không.

---

## 7am. Lỗi 78–80 — đường hầm lên rồi, và không gói tin nào về

Đường hầm `UP`, hai SA `ESTABLISHED`. Rồi:

```
=== Goi dich vu ban cong bo ===
  NLB tra ve 000
```

`000` của `curl` nghĩa là **không có kết nối nào được thiết lập** — không phải 4xx, không phải 5xx. Ở tầng dưới IPsec thì mọi thứ đều xanh.

### Lỗi 78 — địa chỉ nguồn, thứ không ai nghĩ tới

```
10.9.100.0/24 dev vti1 scope link metric 100
```

Route này thiếu `src`. Với một route đặt thẳng lên interface point-to-point, nhân **tự chọn** địa chỉ nguồn, và nó chọn địa chỉ đầu tiên của chính interface đó: `169.254.100.2` — địa chỉ **trong** đường hầm.

Gói tin đi ra bình thường. AWS giải mã bình thường. NLB nhận được kết nối và trả lời — **về `169.254.100.2`**. Bảng route của VPC không có đường nào tới dải đó: route tĩnh của VPN chỉ công bố `172.16.0.0/16`. Gói trả lời bị vứt.

> Chiều đi hoàn hảo, chiều về không tồn tại. Và mọi phép đo ở chiều đi — SA, interface, route, trạng thái đường hầm phía AWS — đều báo đúng.

Đây là biến thể thứ ba của cùng một chủ đề trong doc 16 mục 4b: **mỗi chiều là một bài toán riêng.** Ở đó là VGW và TGW không nối bắc cầu, cần hai điểm tái khởi tạo. Ở đây là địa chỉ nguồn — cũng chỉ đúng ở một chiều.

Sửa: `ip route replace <dai> dev vti1 src <ip rieng cua may> metric 100`.

### Lỗi 79 — code và chú thích của chính nó nói khác nhau

```hcl
partner_nlb_cidr = cidrsubnet(var.partner_vpc_cidr, 8, 100) # 10.9.100.0/24
...
#   nlb   10.9.100.0/24  10.9.101.0/24   dia chi ao doi tac goi toi
```

Hai dòng cách nhau **mười một dòng** trong cùng một file. Chú thích đúng; code chỉ công bố một nửa.

NLB nội bộ lấy một địa chỉ ở **mỗi** AZ, và tên DNS trả về **cả hai**. Nên gọi được hay không tuỳ vào địa chỉ nào được chọn — một phép thử thành công không chứng minh được gì, và một phép thử thất bại đọc như lỗi ngẫu nhiên.

Sửa: `/23` phủ hết, cộng một `check` so từng subnet NLB với dải công bố. Thêm AZ thứ ba là plan dừng, không phải là một nửa lưu lượng im lặng.

### Lỗi 80 — `A || B` khi A thành công mà không làm gì

`vpn-check` in mục `=== IPsec SA ===` **rỗng** trong khi hai SA đang chạy. Nguyên nhân: `strongswan statusall 2>/dev/null || ipsec statusall`. Trên Ubuntu lệnh thứ nhất tồn tại, **thoát 0**, và không in gì — nên `||` không bao giờ chạy tới vế sau.

Cùng hình dạng với lỗi 75, và cùng hậu quả: **một phép đo trả lời "không có gì" cho một hệ thống đang chạy đúng.** Sửa bằng cách kiểm output có rỗng không, chứ không kiểm mã thoát.

Nhân tiện thêm vào `vpn-check` một mục in thẳng `ip route get` tới dải NLB — đúng một dòng, và nó hiển thị địa chỉ nguồn sẽ được dùng. Lỗi 78 lẽ ra mất ba mươi giây thay vì cả một vòng suy luận.

### Lỗi 81 — đúng một nửa cách sửa là không sửa được gì

Đổi `target_port` từ 8080 sang 80 làm `apply` dừng giữa chừng:

```
Error: deleting ELBv2 Target Group ...
ResourceInUse: Target group ... is currently in use by a listener or a rule
```

`port` của target group là thuộc tính **bắt tạo lại**. Thứ tự mặc định của Terraform là xoá trước tạo sau, nên nó xoá target group cũ trong khi listener vẫn đang trỏ vào đó.

Cách sửa hiển nhiên — `create_before_destroy` — **một mình nó không đủ**, và đây là chỗ đáng nhớ: tên target group cố định, nên cái mới trùng tên cái cũ và AWS từ chối ở đúng bước tạo. Đảo thứ tự chỉ đổi thông báo lỗi.

Phải cả hai: ghép `target_port` vào tên **và** `create_before_destroy`. Tên đổi khi cổng đổi, nên hai cái tồn tại song song đủ lâu để listener trỏ sang. Tiện thể, cái tên giờ tự nói nó trỏ tới cổng nào.

> Cùng một họ với lỗi 42 và 56: một ràng buộc của AWS mà `plan` không thể thấy, vì `plan` không biết thứ tự thật của các lời gọi API. Không có cách nào bắt được cái này trước khi chạy — chỉ có cách viết đúng ngay từ đầu, hoặc gặp nó một lần rồi nhớ.

### Lỗi 82 — mở cửa mà quên mở khoá

Listener 8080 tạo xong. Target group `healthy` ở `10.10.0.10:80`. Đường hầm `UP`, route đúng, rule firewall đúng. Và:

```
http=000
exit=28
```

Cổng 80 vẫn trả `200` cùng lúc đó. Nên hỏng nằm ở chỗ chỉ khác nhau giữa hai cổng — và đó là **security group của NLB**.

NLB có security group, và nó lọc lưu lượng tới **từng listener**. SG do layer cha tạo chỉ mở đúng `partner_service_port`:

```hcl
ingress {
  from_port   = var.partner_service_port   # 80
  to_port     = var.partner_service_port
  cidr_blocks = [var.partner_sim_cidr]
}
```

Gói tin tới cổng 8080 bị vứt **trước khi tới listener**. Không log, không lỗi, và mọi phép kiểm khác đều xanh — vì mọi phép kiểm khác đo những thứ thật sự đúng.

Nguyên nhân gốc là một **đường cắt sai giữa hai layer**: lớp ops sở hữu listener, layer cha sở hữu security group. Hai nửa của cùng một thay đổi nằm ở hai nơi, nên chúng lệch nhau. Ai sở hữu listener phải sở hữu cả rule mở cổng cho nó.

Và cách sửa có một cái bẫy thứ hai, tệ hơn cái thứ nhất:

> Một khối `ingress` **lồng trong** `aws_security_group` **sở hữu toàn bộ danh sách rule**. Mỗi lần apply layer cha, Terraform xoá sạch mọi rule nó không biết — kể cả rule lớp ops vừa thêm.

Triệu chứng của việc đó là thứ tệ nhất trong cả bộ: đối tác kết nối được, rồi một hôm nào đó ai apply layer cha thì họ mất kết nối, rồi chạy lại apply ở lớp ops thì họ có lại. *"Chập chờn"* theo đúng nghĩa, và không có gì trong log nói tại sao.

Nên layer cha đổi sang `aws_vpc_security_group_ingress_rule` — resource rời — cùng lúc. Hai layer cùng thêm rule vào một security group mà không ai xoá của ai.

### Lỗi 83 — "bỏ đi" không có nghĩa là "xoá"

Và bản vá đó hỏng ngay lần apply đầu:

```
InvalidPermission.Duplicate: the specified rule
"peer: 172.16.0.0/16, TCP, from port: 80, to port: 80, ALLOW" already exists
```

`ingress`/`egress` của `aws_security_group` là **Optional+Computed**. Bỏ hẳn khối đi nghĩa là *"thôi không quản nữa"* — **không phải** *"xoá hết rule"*. Terraform không sinh diff nào, rule cũ nằm nguyên trong AWS, và resource rời được tạo ra thì đụng đúng nó.

Build mới từ đầu không gặp: security group sinh ra rỗng rồi rule được thêm vào. Chỉ bản **đã apply** mới phải gỡ tay một lần bằng `revoke-security-group-ingress`/`egress` — thủ tục ghi ngay cạnh resource trong `partner.tf`.

> Cùng họ với lỗi 72: một mặc định *"không đụng vào thứ tôi không biết"* là lựa chọn đúng của công cụ, và cũng là thứ làm người ta hiểu sai ý nghĩa của việc xoá một dòng code. **Xoá dòng code không phải là ra lệnh xoá tài nguyên.**

Tiện thể, rule của lớp ops lấy dải nguồn từ **chính đối tác sở hữu dịch vụ**, nên dịch vụ của Acme chỉ mở cho dải của Acme. Đó là lớp phân biệt **duy nhất** giữa hai đối tác ở tầng này — firewall không làm được, vì nó thấy mọi đối tác đều đến từ cùng dải NLB.

### Kết quả

```
=== Dia chi nguon di ra duong ham ===
10.9.100.1 dev vti1 src 172.16.0.136 uid 0

10.9.100.0/23 dev vti1 scope link src 172.16.0.136 metric 100

=== Goi dich vu ban cong bo ===
  NLB tra ve 200
```

`200` — một gói tin HTTP đi hết **IPsec → VGW → NLB → TGW → Network Firewall → spoke `10.10.0.10` ở account khác** rồi về.

Bảy lỗi, bảy vòng thay máy giả lập, cho một đường ống mà `terraform apply` báo thành công ngay từ vòng đầu.

Và lớp vận hành, đo riêng ở cổng 8080 do catalog sinh ra:

```
http=200
exit=0
```

Ba dòng YAML trong `partners.yaml` — tên dịch vụ, cổng ngoài, cổng trong — thành target group, listener, rule mở cổng và rule firewall, rồi thành một gói tin HTTP đi từ mạng đối tác tới ứng dụng ở một account khác. Mười lỗi (74–83) nằm giữa dòng YAML đầu tiên và con số đó.

> **Điều đáng giữ lại từ cả bảy:** không lỗi nào trong số đó làm `apply` thất bại, và không lỗi nào bị `plan`, `validate`, `fmt` hay phép quét `.tftpl` bắt được. Sáu trong bảy chỉ lộ ra bằng **một gói tin thật đi hết đường**. Đó là lý do `verify.sh` tồn tại, và là lý do dòng cuối của một quy trình dựng hạ tầng không bao giờ nên là "apply xong".

---

## Liên quan
| | |
|---|---|
| [16 – Kết nối đối tác](./16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) | 3rd-party VPC và VPN — bối cảnh của lỗi 74–80 |
| [25 – Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md) | Lớp `ops/` — bối cảnh của lỗi 66–73 |
| [23 – Lớp phát hiện](./23-Lop-Phat-Hien-GuardDuty-SecurityHub-Log-Archive.md) | Cơ chế GuardDuty / Security Hub / log archive — kết quả của mục 7h–7p |
| [TEARDOWN](../landing-zone/TEARDOWN.md) | Chiều ngược lại — hai cổng khoá, parking account |
| [RUNBOOK](../landing-zone/RUNBOOK.md) | Làm gì, theo thứ tự nào — bảng lỗi ở cuối |
| [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md) | Vì sao chọn DIY, 4 SCP |
| [20 – Vận hành LZ](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) | Remote state, quy trình thay đổi |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Quy ước email, account baseline |
| [06 mục 1b](./06-Aws-Landing-Zone.md) | Root user vs organization root |
