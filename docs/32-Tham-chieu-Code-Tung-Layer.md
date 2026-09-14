# Tham chiếu code từng layer — 413 resource, 126 check, 22 script

[Doc 31](./31-Ban-do-Code-Landing-Zone.md) là bản đồ: layer nào là gì, ai apply. [Doc 30](./30-Khuon-mau-Code-Layer-va-Caller-Pipeline.md) là khuôn mẫu: cách dùng. Tài liệu này là **tham chiếu**: mở ra khi bạn đứng trước một thư mục và không biết file nào làm gì.

**Nguyên tắc đọc code của repo này: tên file là một đơn vị công việc.** Không có `main.tf` khổng lồ. `vpc-egress.tf` dựng đường ra Internet, `partner.tf` dựng đường tới đối tác, `firewall.tf` dựng tường lửa. Muốn biết một layer làm những gì thì `ls` nó trước khi đọc dòng nào.

---

## 0. Bốn con số, và một tỷ lệ

| | |
|---|---|
| **413** | `resource` trong toàn repo |
| **126** | `check` block |
| **5** | `module` block — và chỉ **một** module tự viết |
| **22** | script (`.sh` và `.py`) |

Tỷ lệ đáng chú ý: **gần một `check` cho mỗi ba resource.** Đó không phải thừa. `check` là cách viết ra một điều kiện **không làm apply thất bại** — nó tồn tại cho những chỗ "hợp lệ nhưng phải là một lựa chọn", và phần lớn 126 cái đó sinh ra sau một lần hỏng im lặng.

`5 module block` nhưng chỉ **một** module tự viết: `modules/tf-pipeline`, gọi từ năm caller `ops-pipeline*`. Mọi layer khác viết resource trực tiếp — không có lớp trừu tượng nào ở giữa, cố ý.

---

## 1. Ba loại file trong mọi layer

| File | Chứa gì | Điều bất ngờ |
|---|---|---|
| `versions.tf` | `required_version`, provider, `required_providers` | **Không khai backend.** `tf-backend/wire-backends.sh` sinh `backend.tf` riêng — hai khối `backend` trong một module là lỗi |
| `variables.tf` | biến, `validation` | Ở repo này nó **cũng chứa `check`** — vì `check` phải nằm ở đâu đó, và điều kiện về biến thì nằm gần biến |
| `outputs.tf` | output | Cũng chứa `check`, và output ở đây thường là **văn bản hướng dẫn người** (`next_steps`), không phải giá trị cho máy |
| file theo chức năng | resource của một việc | tên file = việc |

---

## 2. 22 script, chia ba loại

**Loại 1 — lint: đọc catalog, offline, không gọi AWS.** Chạy được ngay sau khi gõ, và stage `Lint` của pipeline chạy đúng lệnh này.

| Script | Layer |
|---|---|
| `organization/lint.sh` + `test-lint.sh` | SCP catalog — **và một test cho chính lint** |
| `network/ops/lint.sh` | 6 file catalog mạng |
| `account-baseline/lint.sh` | catalog account |
| `permission-sets/validate-policies.sh` | policy JSON của permission set |

**Loại 2 — verify: đọc AWS, không đọc state.** Đây là lớp trả lời *"thực tế có đúng như ta tưởng không"*. `terraform plan` ra `No changes` ở cả hai trạng thái đã-xác-nhận và chưa, nên state không trả lời được.

| Script | Đọc gì từ AWS |
|---|---|
| `organization/kiem-to-chuc.sh` | SCP **đang gắn thật**, cây OU |
| `org-trail/kiem-trail.sh` | trail, log file validation, bucket |
| `permission-sets/kiem-quyen.sh` | assignment thật theo từng account |
| `config-detective/kiem-config.sh` | org config rule, `excluded_accounts` |
| `network/kiem-mang.sh` | rule group, `StatefulDefaultActions`, alarm, subscription |
| `network/verify.sh` | 850 dòng phép kiểm cho cả layer mạng nền |
| `ops-gate/kiem-log.sh` | log của **lần chạy pipeline vừa rồi** — [doc 29](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) |

**Loại 3 — tiện ích và cổng chặn.**

| Script | Việc |
|---|---|
| `tf-backend/wire-backends.sh` | sinh `backend.tf` + `backend.hcl` cho **mọi** layer |
| `vending-pipeline/push-tfvars.sh` | đẩy tfvars của mọi layer lên kho S3 dùng chung |
| `vending-pipeline/log.sh` | đọc log một lần chạy pipeline |
| `ops-gate/gate.py` | cổng chặn: bản plan này làm **lỏng hơn** hay **chặt hơn** |
| `ops-gate/test-gate.py` | 43 test cho cổng chặn |
| `trigger-filter/lambda/loc.py` | bộ lọc kích hoạt (Lambda) |
| `trigger-filter/test-loc.py` | 39 test cho bộ lọc |
| `kiem-module.py` | 18 phép kiểm: module ↔ mọi caller |
| `network/teardown.sh` · `plan-check.sh` | xoá có chốt · so plan |
| `account-baseline/accept-ram.sh` · `check-sweep.sh` | nhận lời mời RAM · kiểm dọn default VPC |

**Không script nào trong loại 1 và 2 cần state.** Đó là chủ đích: chúng phải chạy được trên máy một người mới vào, chưa `terraform init`.

---

## 3. `tf-backend` — nền của mọi layer khác

17 resource, một file.

| File | Việc |
|---|---|
| `main.tf` | KMS key + **hai** bucket + bảng khoá DynamoDB |
| `outputs.tf` | `layers` (bảng khoá state), `bucket`, `lock_table` — và `check.backend_profiles_tro_dung_layer` |
| `teardown.tf` | `check.destroy_guard_still_on` |
| `wire-backends.sh` | sinh `backend.tf` cho mọi layer |

**Vì sao hai bucket:** `aws_s3_bucket.state` giữ state, `aws_s3_bucket.logs` giữ **access log của bucket state**. Ai đọc state của ai, lúc nào — đó là dấu vết duy nhất khi state bị sửa ngoài Terraform.

**`outputs.tf` là nơi khai bảng khoá state của cả hạ tầng** (`local.layers`). Một khoá sai ở đây nghĩa là Terraform mở một state **rỗng**: plan đòi tạo lại toàn bộ, và hạ tầng thật thành mồ côi. Chú thích trong file đó dài hơn code, và đáng đọc hết.

**`aws_dynamodb_resource_policy.lock`** — ít gặp, và chỉ tạo khi `var.state_writer_accounts` khác rỗng. Nó cho phép **account khác** lấy khoá state (`Sid = "AllowStateWriterAccountsToLock"`) — tức khoá state hoạt động liên account mà không phải sửa IAM ở từng bên.

---

## 4. `organization` — guardrail của tổ chức

8 file, và **15 check** — mật độ check cao nhất repo cùng `config-detective`.

| File | Việc | Resource chính |
|---|---|---|
| `organization.tf` | Tổ chức + cây OU hai tầng | `aws_organizations_organization.this`, `..._organizational_unit.level1` / `.level2` |
| `scp-catalog.tf` | **Đọc** `catalog/scp.yaml` thành dữ liệu — không tạo gì | 3 check, xem dưới |
| `scp.tf` | Tạo và gắn SCP | `aws_organizations_policy.scp`, `..._policy_attachment.scp`, `terraform_data.scp_guard` |
| `tag-policy.tf` | Tag policy (report-only) | `aws_organizations_policy.tag`, `..._attachment.tag` |
| `delegated-admin.tf` | Uỷ quyền quản trị cho security account | `aws_organizations_delegated_administrator.this` |

**`scp-catalog.tf` không tạo resource nào** — nó chỉ biến YAML thành `local`, và mang ba check kiểm **chính catalog**:

| Check | Bắt cái gì |
|---|---|
| `scp_catalog_sid_khong_trung` | hai statement cùng `Sid` — AWS nhận, và cái sau vô hiệu |
| `scp_catalog_moi_statement_co_reason` | một Deny không có lý do — sáu tháng sau không ai dám xoá |
| `scp_catalog_condition_co_that` | catalog gọi một `Condition` **không có trong bảng định sẵn** `scp_condition_json`. Condition cố ý **không** khai tự do được trong catalog — *"thêm một Condition vào một Deny là cách nới guardrail tinh vi nhất"* |

**Ba check về giới hạn AWS** mà người ta thường gặp lúc apply thất bại chứ không lúc plan: `scp_size_under_limit` (5120 byte/policy), `scp_count_per_target_under_limit` (5 SCP/target), `tag_policy_type_enabled`.

**Hai check về OU `Suspended`** — `suspended_ou_is_actually_frozen` và `suspended_not_silently_unattached`: một OU tên "Suspended" mà không có SCP đóng băng gắn vào là một cái tên nói dối.

`terraform_data.scp_guard` mang **2 precondition**: một SCP đang bật mà không gắn được vào OU nào, và một target không giải được thành OU ID. Xem [doc 30 mục 6](./30-Khuon-mau-Code-Layer-va-Caller-Pipeline.md).

---

## 5. `account-baseline` — thay cho AFT

| File | Việc | Resource chính |
|---|---|---|
| `accounts.tf` | Tạo account từ catalog | `aws_organizations_account.this`, `terraform_data.catalog_guard` |
| `vpc-sweep.tf` | **Dọn default VPC** ở mọi account/region qua StackSet | `aws_cloudformation_stack_set.baseline` + `_instance` |
| `spoke-network.tf` | Rải VPC spoke xuống account thành viên | `aws_cloudformation_stack_set.spoke_network` + `_instance`, `terraform_data.spoke_network_guard` |

**Vì sao StackSet chứ không Terraform:** dọn default VPC phải chạy ở **mọi account × mọi region**. Terraform sẽ cần một provider alias cho mỗi cặp — hàng trăm. StackSet là thứ AWS làm sẵn cho đúng việc đó.

`check.sweep_regions_include_home` — quét mọi region trừ region chính là một cấu hình đọc như "đã dọn hết" mà default VPC nguy hiểm nhất vẫn còn.

`accept-ram.sh` và `check-sweep.sh` là hai việc Terraform không làm được: account thành viên phải **nhận** lời mời RAM, và kết quả dọn VPC phải hỏi từng account.

---

## 6. `network` — hạ tầng nền, ~200 resource, 14 file

Layer lớn nhất. Đọc theo **nhóm file**, đừng đọc tuần tự.

### Nhóm 1 — bốn VPC, mỗi cái một file

| File | VPC | Việc |
|---|---|---|
| `vpc-security.tf` | security | Network Firewall + VPC endpoint tập trung — **mọi gói tin đi qua đây** |
| `vpc-egress.tf` | egress | NAT Gateway → Internet |
| `vpc-ingress.tf` | ingress | NLB nhận từ ngoài vào |
| `vpc-spokes.tf` | spoke | VPC của ứng dụng, **cùng account** |
| `vpc-spokes-remote.tf` | spoke | VPC của ứng dụng ở **account khác** — qua RAM + StackSet |

### Nhóm 2 — nối chúng lại

| File | Việc |
|---|---|
| `tgw.tf` | Transit Gateway + **4 route table** (spokes, egress, security, ingress) và đường giữa chúng |
| `firewall.tf` | Network Firewall, policy, 2 rule group, bucket log |
| `dns.tf` | Private hosted zone + Route53 Profile chia sẻ qua RAM |

**Câu quan trọng nhất của cả layer** nằm ở `tgw.tf`: bảng `rtb-spokes` có **đúng một dòng** `0.0.0.0/0 → security VPC`. Một dòng đó phủ mọi đích: Internet, spoke khác, ingress. Nên thêm một route spoke-to-spoke **không mở thêm kết nối nào** — nó tạo đường tắt **vòng qua firewall**, vì route cụ thể hơn thì thắng.

### Nhóm 3 — đối tác và thiết bị

| File | Việc | Lưu ý |
|---|---|---|
| `partner.tf` | VPN tới đối tác + NLB công bố dịch vụ | 4 check, gồm `partner_cidr_does_not_overlap_lz` |
| `partner-sim.tf` | **Giả lập** phía đối tác để thử đường hầm | VPC riêng, có EIP — chỉ dùng khi test |
| `appliances.tf` | Palo Alto + F5 + GWLB | File lớn nhất repo. ~$1.3/giờ cho một thiết bị **không làm gì** |
| `cdn.tf` | CloudFront + WAF | `random_password.origin_verify` — header bí mật để origin từ chối request không qua CDN |

### Nhóm 4 — cổng chặn của chính layer

| File | Việc |
|---|---|
| `account-guard.tf` | `terraform_data.account_guard` — chặn apply vào **sai account** |
| `pipeline-access.tf` | `aws_iam_role.pipeline_deploy` — role để pipeline ở account khác vào đây |
| `vending.tf` | đọc state `account-baseline`, 3 check |
| `notify.tf` | SNS topic `netops` + `check.netops_topic_co_nguoi_nhan` |

`check.ops_rule_groups_are_attached` trong `firewall.tf` là cầu nối tới layer `ops`: nó kêu khi `ops_rule_group_arns` có ARN mà `enable_firewall = false` — rule group vẫn tồn tại, vẫn tính phí capacity, và **không policy nào đọc nó**.

---

## 7. `network/ops` — lớp vận hành, 16 resource, 6 file catalog

| File | Việc | Resource | Catalog nó đọc |
|---|---|---|---|
| `main.tf` | đọc 6 catalog, giải tên app → CIDR, và chốt an toàn | `terraform_data.catalog_guard` (**31 precondition**) | cả 6 |
| `firewall.tf` | sinh luật Suricata từ catalog | `aws_networkfirewall_rule_group.ops_east_west` | `firewall-rules.yaml`, `apps.yaml` |
| `dns.tf` | tên nội bộ | `aws_route53_record.ops` | `dns-records.yaml` |
| `endpoints.tf` | VPC endpoint + PHZ + wildcard | `aws_vpc_endpoint.ops`, `aws_route53_zone.ops_endpoint` | `endpoints.yaml` |
| `routes.tf` | route ngoại lệ, gồm blackhole | `aws_ec2_transit_gateway_route.ops` | `routes.yaml` |
| `vpn.tf` | dịch vụ công bố cho đối tác + alarm VPN | `aws_lb_*.partner_service`, `aws_vpc_security_group_ingress_rule.partner_service`, 2 alarm | `partners.yaml` |

**`main.tf` là phần đáng đọc nhất**, và lý do chính của cả lớp nằm ở đó: **giải tên app thành CIDR**. Catalog viết `from: probe`, không viết `10.11.0.0/16`. Một người xin mở port không cần biết CIDR, và khi CIDR đổi thì catalog không phải sửa.

**13 check, và bốn cái đáng biết:**

| Check | Bắt cái gì |
|---|---|
| `no_firewall_bypass_routes` | một route trong catalog tạo đường tắt vòng qua firewall |
| `firewall_mode_makes_rules_meaningful` | firewall ở `alert` → rule được nạp mà **không quyết định gì** |
| `icmp_rules_are_shadowed` | một rule ICMP bị rule khác phủ — nó đọc như đang có tác dụng |
| `rule_group_is_referenced` | rule group tồn tại mà không policy nào đọc |

**`routes.tf` và `firewall.tf` đều có `*_have_an_owner`** — mọi mục catalog phải có `ticket`. Một luật không có chủ là một luật không ai dám xoá.

---

## 8. `org-trail` — 9 resource, và 8 trong số đó là một cái bucket

| File | Việc |
|---|---|
| `main.tf` | bucket log + 7 resource cấu hình nó, rồi `aws_cloudtrail.this` |
| `teardown.tf` | `check.destroy_guard_still_on` |

Tỷ lệ này nói lên bản chất của layer: **cái trail là một dòng, cái khó là bảo vệ chỗ chứa log.**

| Resource | Vì sao có |
|---|---|
| `aws_s3_bucket_object_lock_configuration.trail` | **không ai** xoá được log, kể cả người có quyền |
| `aws_s3_bucket_versioning.trail` | object lock đòi versioning |
| `aws_s3_bucket_policy.trail` | CloudTrail ghi được, và chỉ nó |
| `aws_s3_bucket_lifecycle_configuration.trail` | chuyển sang lớp lưu trữ rẻ hơn theo thời gian |

`check.log_archive_is_not_management` — bằng chứng kiểm toán nằm trong **chính account bị kiểm toán** thì nó không phải bằng chứng.

`check.data_events_cost_warning` — data event là chỗ hoá đơn CloudTrail tăng gấp trăm lần, nên bật nó phải là một lựa chọn được ghi lại.

---

## 9. `config-detective` — 75 resource, 16 check, 7 file

Layer nặng nhất, và pipeline chỉ được chạm **1 resource trên 75**.

| File | Việc | Resource chính |
|---|---|---|
| `stackset-recorder.tf` | Rải **Config recorder** xuống mọi account × region | `aws_cloudformation_stack_set.recorder` + `_instance` |
| `aggregator-rules.tf` | Aggregator + **Config rule** | `aws_config_configuration_aggregator.org`, `aws_config_organization_managed_rule.this` ← *cái duy nhất pipeline sửa được* |
| `securityhub.tf` | Security Hub: admin, member, standard, finding aggregator | 7 resource |
| `guardduty.tf` | GuardDuty: admin, detector, member, feature | 7 resource |
| `s3-log-archive.tf` | Bucket snapshot ở log-archive, có object lock | 8 resource |
| `notify.tf` | **Đường báo động**: SNS + policy + subscription + EventBridge + Lambda Slack | 10 resource |
| `vending.tf` | đọc state `account-baseline` | `check.vending_state_doc_duoc` |

**`notify.tf` là file đáng đọc nhất**, vì nó là một quyết định kiến trúc được ghi lại chứ không phải code:

> **KHÔNG làm EventBridge fan-in cross-account.** Config rule đẩy finding vào Security Hub, và Security Hub đã gom cross-account + cross-region qua delegated admin. Dùng một đường EventBridge riêng là làm lại đúng việc đó, và phải triển khai rule + IAM role ở **mọi** account × **mọi** region.

Nên chỉ có **một** rule EventBridge, đặt ngay tại security account. Lợi thêm: cùng đường đó gom luôn GuardDuty, Inspector, Macie.

`aws_sns_topic_policy.alerts` là resource của **`extra_publisher_arns`** — SNS liên account đòi **cả hai** phía cho phép, và nó nằm **ngoài** `-target` của pipeline nên phải apply tay.

**Ba check về tiền**, vì đây là layer duy nhất tốn tiền đáng kể trước giai đoạn 10: `security_hub_costs_money`, `guardduty_features_cost_money`, `rule_count_reasonable`.

`check.evidence_lives_outside_the_operated_account` và `retention_longer_than_object_lock` — cùng một ý với `org-trail`: bằng chứng phải nằm ngoài tầm người bị kiểm, và thời gian giữ phải dài hơn thời gian khoá.

---

## 10. `permission-sets` — hai thứ khác nhau trong một layer

| File | Việc | Resource |
|---|---|---|
| `permission-sets.tf` | **Bộ quyền**: set + managed policy + inline policy | `aws_ssoadmin_permission_set.this` + 2 |
| `assignments.tf` | **Ai vào account nào** | `aws_ssoadmin_account_assignment.this` |
| `identity.tf` | Group, user, thành viên group | `aws_identitystore_*` |
| `organizations.tf` | 4 check đối chiếu với tổ chức thật — không tạo gì |
| `locals-policies.tf` · `locals-services.tf` | bảng policy và bảng dịch vụ, tách khỏi resource |
| `vending.tf` | đọc state `account-baseline` |

**Pipeline chỉ sửa được `assignments.tf` và phần membership của `identity.tf`.** Ranh giới đó là ngữ nghĩa: tạo một assignment là cho *một* group vào *một* account; đổi inline policy là đổi quyền của **mọi** người dùng set đó, ở **mọi** account, **ngay lập tức**.

`check.no_account_in_two_env_scopes` — một account vừa thuộc `dev` vừa thuộc `prod` thì mọi phép kiểm theo môi trường sau đó đều nói dối.

`check.every_permission_set_is_granted` — một permission set không gắn cho ai là một bộ quyền tồn tại mà không ai dùng: nó không hại, nhưng nó làm danh sách quyền đọc sai.

`validate-policies.sh` kiểm JSON của policy **offline** — trước khi AWS từ chối vì một dấu phẩy.

---

## 11. `billing-guard` và `service-catalog` — hai cách quản tag, ngược chiều nhau

**`billing-guard`** (13 resource): `aws_ce_cost_allocation_tag.tracked` bật tag cho báo cáo chi phí, `aws_budgets_budget.org_guard` + `.per_account` đặt ngưỡng, `aws_ce_anomaly_monitor` + `_subscription` bắt bất thường, và một dashboard + alarm.

**`service-catalog`** (8 resource): **ép tag ở thời điểm tạo**. `aws_servicecatalog_tag_option` + `_resource_association` làm người tạo resource **phải chọn** một giá trị tag; `aws_iam_role.sc_launch` là role Service Catalog dùng để tạo thay họ.

Khác biệt đáng ghi:

| | Khi nào biết thiếu tag |
|---|---|
| tag policy (`organization`) | **sau khi** resource đã tồn tại, và report-only nên không chặn |
| `service-catalog` | **trước khi** resource tồn tại — không chọn tag thì không tạo được |
| `billing-guard` | khi hoá đơn về, và tag sai nghĩa là chi phí không quy được về ai |

`check.tag_options_match_tag_policy` nối hai đầu: nếu Service Catalog ép một tập giá trị khác với tag policy thì có người tạo resource **đúng theo Service Catalog** và vẫn **vi phạm** tag policy.

---

## 12. `codecommit-guard` — ba resource, và hai trong số đó không đủ một mình

```
aws_codecommit_approval_rule_template.main       + _association
aws_iam_policy.chan_push
```

| Phần | Chặn cái gì | Một mình thì |
|---|---|---|
| approval rule template | **pull request** phải có N người duyệt | ai cũng push thẳng vào `main`, không qua review |
| `aws_iam_policy.chan_push` | Deny `codecommit:GitPush` | không còn đường hợp lệ nào để đưa code vào |

`enable = false` — layer này **chưa bật**. Hôm nay `git push codecommit HEAD:main` chạy được chính vì vậy. Bật nó đổi quy trình hằng ngày: xem [doc 31 mục 7](./31-Ban-do-Code-Landing-Zone.md).

Hai check của nó kiểm chính cấu hình duyệt: `pool_duyet_khong_rong` và `so_nguoi_duyet_khong_vuot_pool` — đòi 3 người duyệt từ một pool có 2 người là một cấu hình **không ai qua được**.

---

## 13. `trigger-filter` — 10 resource, 7 check, và Lambda là phần chính

| Nhóm resource | Việc |
|---|---|
| `aws_lambda_function.loc` + `aws_iam_role.loc` + `_policy` + `aws_cloudwatch_log_group.loc` | chính bộ lọc |
| `aws_lambda_function_event_invoke_config.loc` | số lần EventBridge gọi lại khi Lambda ném lỗi |
| `aws_cloudwatch_event_rule.commit` + `_target.loc` + `aws_lambda_permission.events` | nối sự kiện CodeCommit vào Lambda |
| `aws_sns_topic.loi` + `_subscription.loi` | báo khi **chính bộ lọc** hỏng |

Nhóm cuối là nhóm dễ bỏ: bộ lọc là một **điểm hỏng đơn** — nó hỏng thì không pipeline nào chạy. Nên nó phải có đường báo riêng.

**7 check đều kiểm `ban_do`/`tru`**, và ba cái đáng biết:

| Check | Bắt cái gì |
|---|---|
| `khong_co_danh_sach_rong` | `[]` — pipeline **không bao giờ chạy**, mà đọc như "chưa điền" |
| `tru_khong_chan_sach` | `tru` phủ sạch một tiền tố gom → pipeline coi như mất tiền tố đó |
| `tien_to_ket_thuc_bang_gach_cheo` | `"landing-zone/network"` bắt luôn `network-cu/` |

Logic thật nằm ở `lambda/loc.py` (367 dòng) — [doc 29 phần I](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md).

---

## 14. `vending-pipeline` — pipeline viết tay, không dùng module

31 resource, 6 file. Nó **không** dùng `modules/tf-pipeline`, và nó có những thứ module không có: hai stage **chờ**, và một stage tạo account.

| File | Việc | Resource chính |
|---|---|---|
| `pipeline.tf` | CodePipeline + topic duyệt + rule EventBridge | `aws_codepipeline.vending`, `aws_sns_topic.approval` + policy |
| `codebuild.tf` | **4 project**: `terraform`, `lint`, và hai project **chờ** | `aws_codebuild_project.cho_attachment`, `.cho_recorder` |
| `iam.tf` | role cho pipeline và cho codebuild | 4 resource |
| `artifacts.tf` | bucket artifact + KMS | 8 resource |
| `tfvars-store.tf` | **kho tfvars dùng chung** — mọi pipeline đọc từ đây | 6 resource |
| `main.tf` | 5 check, không resource |

**Hai project "chờ" là thứ không có ở module:** tạo một account rồi rải baseline xuống nó không xong ngay — TGW attachment phải được chấp nhận, Config recorder phải chạy. `cho_attachment` và `cho_recorder` là hai bước **đợi và kiểm**, vì một stage apply ngay sau đó sẽ thất bại theo kiểu khó đọc.

`check.stage_tao_account_luon_co_cong_duyet` — tạo account là việc **không hoàn tác được** (account không xoá được, email không tái sử dụng được). Nên stage đó không bao giờ được chạy tự động.

---

## 15. `modules/tf-pipeline` — module duy nhất tự viết

30 biến, 10 output, 10 file `.tf`, 4 buildspec. Năm caller dùng nó.

| File | Resource | Việc |
|---|---|---|
| `pipeline.tf` | 3 | CodePipeline + rule EventBridge riêng của pipeline |
| `codebuild.tf` | 8 | **4 project** (`terraform`, `catalog`, `verify`, `drift`) + lịch drift |
| `iam.tf` | 7 | ba role: `codebuild`, `pipeline`, `events` |
| `artifacts.tf` | 8 | bucket artifact + KMS |
| `approval.tf` | 3 | topic duyệt + policy |
| `notify.tf` | 2 | topic drift (chỉ tạo khi khai `drift_emails`) |
| `main.tf` | 0 | **7 check** — phần "kiểm caller khai đúng không" |
| `outputs.tf` | 0 | `next_steps`, `drift_project`, `cong_duyet`, `stages` |

**`main.tf` không tạo gì và là file quan trọng nhất.** Bảy check của nó kiểm **caller**, không kiểm AWS:

| Check | Bắt cái gì ở caller |
|---|---|
| `khoa_stage_khong_trung` | hai stage cùng `key` — `PHAM_VI` của `gate.py` là bảng dùng chung, cái bị đè lặng lẽ nhận phạm vi cái kia |
| `khoa_state_khong_trung` | hai layer cùng khoá state |
| `moi_stage_co_lint` | stage không có `lint` **và** không có `khong_co_lint` |
| `co_verify_sau_apply` | không khai `verify` → không lớp nào đọc AWS sau apply |
| `approve_stages_la_ten_that` | `approve_stages` gọi một stage không tồn tại → **cổng duyệt không tồn tại**, và pipeline trông như đã có |

Cái cuối là kiểu hỏng tệ nhất trong danh sách: bạn tin có người duyệt, và không có.

**Bốn buildspec, bốn cái không có gì:**

| Buildspec | Cố ý KHÔNG có |
|---|---|
| `buildspec-catalog.yml` | không Terraform, không state, không gọi AWS |
| `buildspec-terraform.yml` | — (đây là cái đầy đủ: 9 bước, xem [doc 28 mục 2.3](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md)) |
| `buildspec-verify.yml` | không cài Terraform, không đọc state, không kéo tfvars |
| `buildspec-drift.yml` | **không có nhánh apply** — không phải vì một biến, mà vì đoạn code đó không tồn tại |

---

## 16. Bảng tra nhanh: tôi cần sửa X thì mở file nào

| Cần | Layer · file |
|---|---|
| Mở một port giữa hai app | `network/ops/catalog/firewall-rules.yaml` |
| Thêm một tên DNS nội bộ | `network/ops/catalog/dns-records.yaml` |
| Thêm VPC endpoint | `network/ops/catalog/endpoints.yaml` |
| Công bố một dịch vụ cho đối tác | `network/ops/catalog/partners.yaml` |
| Cách ly khẩn một dải địa chỉ | `network/ops/catalog/routes.yaml` (blackhole) |
| Thêm một Deny cấp tổ chức | `organization/catalog/scp.yaml` |
| Thêm một Config rule | `config-detective/terraform.tfvars` → `organization_rules` |
| Cho một group vào một account | `permission-sets/terraform.tfvars` |
| Đổi **quyền** của một permission set | `permission-sets/permission-sets.tf` — **tay**, không qua pipeline |
| Thêm địa chỉ nhận cảnh báo bảo mật | `config-detective/terraform.tfvars` → `alert_emails` — **tay** |
| Cho một role publish vào topic cảnh báo | `config-detective/terraform.tfvars` → `extra_publisher_arns` — **tay**, `-target` |
| Đổi ngưỡng chi phí | `billing-guard/terraform.tfvars` — **tay** |
| Thêm một pipeline | tạo `ops-pipeline-<tên>/` — [doc 28 mục 9](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) |
| Thêm một luật cho cổng chặn | `ops-gate/gate.py` → `LUAT`, và một test ở `test-gate.py` |
| Đổi pipeline nào chạy với thay đổi nào | `trigger-filter/terraform.tfvars` → `ban_do` |
| Chuyển firewall sang chế độ chặn | `network/terraform.tfvars` → `firewall_mode` — layer **cha** |

---

## Liên quan

- [Doc 31 — Bản đồ code LZ](./31-Ban-do-Code-Landing-Zone.md) — 19 layer, ai apply, ai đọc state của ai
- [Doc 30 — Khuôn mẫu code](./30-Khuon-mau-Code-Layer-va-Caller-Pipeline.md) — mười hai việc hay gặp
- [Doc 29 — Bộ lọc kích hoạt và cổng chặn](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) — `loc.py`, `gate.py`, `kiem-log.sh`
- [Doc 28 — Pipeline vận hành LZ](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) — cơ chế pipeline
- [`landing-zone/RUNBOOK.md`](../landing-zone/RUNBOOK.md) — 16 giai đoạn, từng lệnh
- [Doc 22 — Nhật ký triển khai](./22-Nhat-ky-Trien-khai-LZ-DIY.md) — từng lỗi, theo thứ tự gặp
