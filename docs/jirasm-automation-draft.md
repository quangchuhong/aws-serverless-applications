# Jira Service Management → CI/CD automation (bản nháp)

> **Lưu ý:** tài liệu này **không thuộc chủ đề AWS serverless** của repo. Giữ
> lại ở đây vì cùng nhóm chủ đề automation, nhưng nội dung độc lập hoàn toàn
> với doc 00–05.
>
> Đây là **bản nháp** — mới có sơ đồ luồng, chưa có code hay cấu hình cụ thể.

## Bài toán

Cho phép người dùng (dev/ops/business) yêu cầu deploy hoặc thao tác hạ tầng
thông qua **ticket Jira Service Management**, thay vì gọi trực tiếp Jenkins.
Mục đích:

- Có **quy trình phê duyệt** trước khi chạy (workflow của JSM).
- Có **audit trail**: ai yêu cầu, ai duyệt, chạy lúc nào, kết quả ra sao —
  tất cả nằm trong ticket.
- Người dùng không cần quyền trực tiếp trên Jenkins/GitLab/cluster.

## Các thành phần

| Thành phần | Vai trò |
|------------|---------|
| **Jira Service Management** | Nhận yêu cầu, workflow phê duyệt, lưu `values_jira.yml` dưới dạng attachment |
| **Jira Automation Rule** | Trigger webhook sang CI khi ticket chuyển sang `Approved` |
| **Pipeline 1 (Jenkins)** | Nhận webhook → clone repo → tải values từ Jira → merge bằng `yq` → commit & push |
| **GitLab repo** | Nguồn sự thật cho cấu hình (GitOps) |
| **Pipeline 2 (Jenkins/GitLab CI)** | Trigger bởi push → build/test/scan/deploy hoặc chạy ops task |
| **Jira REST API** | Pipeline 2 comment kết quả và transition ticket về `Succeeded`/`Failed` |

`JIRA_ISSUE_KEY` (ví dụ `OPS-123`) là sợi dây xuyên suốt: dùng để tải
attachment, đặt trong commit message, và để update ngược lại ticket.

## Sơ đồ luồng

```text

+---------------------+         +----------------------+         +-------------------------------+
|  Người dùng / Dev   |         |     Jira Service     |         |   Jenkins CI (Pipeline 1:     |
|  Ops / Business     |         |   Management (JSM)   |         |   Nhận từ Jira & update Git)  |
+----------+----------+         +----------+-----------+         +---------------+---------------+
           |                               |                                      |
           | 1. Tạo ticket JSM:            |                                      |
           |    - Loại: Deploy / Ops       |                                      |
           |    - Chọn Department, Env,... |                                      |
           |    - Nhập GitLab Repo, Branch |                                      |
           |    - Đính kèm values_jira.yml |                                      |
           |------------------------------>|                                      |
           |                               |                                      |
           |                               | 2. JSM tạo Issue Key                 |
           |                               |    vd: OPS-123                       |
           |                               | (JIRA_ISSUE_KEY = "OPS-123")         |
           |                               |                                      |
           |                               | 3. Workflow & Approval               |
           |                               |    Open -> In Review ->              |
           |                               |    -> Approved / Rejected            |
           |                               +------------------------------+       |
           |                                                              |       |
           |                               4. Khi "Approved"             |       |
           |                               Jira Automation Rule:         |       |
           |                               - Trigger: status -> Approved |       |
           |                               - Action: Send Web Request    |       |
           |                                 (Webhook)                   |       |
           |                               |                             |       |
           |                               | body JSON gửi sang CI:      |       |
           |                               | {                           |       |
           |                               |   "issueKey": "OPS-123",    |       |
           |                               |   "department": "...",      |       |
           |                               |   "requestType": "deploy",  |       |
           |                               |   "service": "svc-a",       |       |
           |                               |   "env": "staging",         |       |
           |                               |   "version": "v1.2.3",      |       |
           |                               |   "gitlabRepo": "https://..",|
           |                               |   "gitBranch": "develop"    |       |
           |                               | }                           |       |
           |                               +------------HTTP------------>| 5. CI nhận webhook
           |                                                              |    - Map:
           |                                                              |      issueKey -> JIRA_ISSUE_KEY
           |                                                              |      gitlabRepo/gitBranch,...
           |                                                              |
           |                                                              | 6. CI: Clone đúng GitLab repo/branch
           |                                                              |    - git clone ${gitlabRepo}
           |                                                              |    - git checkout ${gitBranch}
           |                                                              |
           |                                                              | 7. CI: Download values từ Jira
           |                                                              |    - Dùng JIRA_ISSUE_KEY:
           |                                                              |      GET /rest/api/3/issue/OPS-123
           |                                                              |      -> .fields.attachment
           |                                                              |    - Download values_jira.yaml
           |                                                              |
           |                                                              | 8. CI: Merge values bằng yq
           |                                                              |    - values_base.yaml (trong repo)
           |                                                              |    - values_jira.yaml (từ Jira)
           |                                                              |  -> values_final.yaml
           |                                                              |
           |                                                              | 9. CI: Update & push code lên GitLab
           |                                                              |    - Ghi values_final.yaml vào
           |                                                              |      đúng path (VD: values/svc/env.yaml)
           |                                                              |    - git add/commit với message
           |                                                              |      chứa "OPS-123"
           |                                                              |    - git push origin ${gitBranch}
           |                                                              +------------------------------+
           |                               |                                      |
           |                               |                                      |
           |                               |              PUSH CODE               |
           |                               +------------------------------------->|
           |                                                                      |
+----------+----------+         +----------------------+         +-------------------------------+
|          GitLab Repo          |                                      |   Jenkins / GitLab CI   |
|  (automation project)         |                                      | (Pipeline 2: Automation)|
+-------------------------------+                                      +---------------+---------+
           |                                                                      |
           | 10. GitLab webhook -> trigger Pipeline 2                            |
           |-------------------------------------------------------------------->|
                                                                                 |
                                                                                 | 11. Pipeline 2 (automation-task):
                                                                                 |   - Pull code mới (repo/branch)
                                                                                 |   - Đọc values_final.yaml / values/svc/env.yaml
                                                                                 |   - 11a. Nếu requestType = "deploy":
                                                                                 |       * Build & Test
                                                                                 |       * SonarQube
                                                                                 |       * Trivy / BlackDuck
                                                                                 |       * Push image -> Nexus
                                                                                 |       * Deploy (Helm/kubectl/oc/ArgoCD)
                                                                                 |   - 11b. Nếu requestType = "ops":
                                                                                 |       * AWS CLI/Terraform/CFN
                                                                                 |       * PowerShell (Windows)
                                                                                 |       * Bash/Ansible (RHEL)
                                                                                 |       * kubectl/oc/Helm (K8s/OCP)
                                                                                 |
                                                                                 | 12. Đánh giá kết quả:
                                                                                 |     success / failed / timeout
                                                                                 |
                                                                                 | 13. Update Jira bằng REST API
                                                                                 |     - Dùng JIRA_ISSUE_KEY (OPS-123):
                                                                                 |       POST /issue/OPS-123/comment
                                                                                 |       POST /issue/OPS-123/transitions
                                                                                 |     - Comment: log, link pipeline
                                                                                 |     - Transition:
                                                                                 |       -> Succeeded / Failed / Timeout
                                                                                 +------------------------------+
                                                                                 |
           |                               |                                      |
           | 14. User xem kết quả          |                                      |
           |     - Ticket OPS-123:         |                                      |
           |       + status final          |                                      |
           |       + log CI, version, env  |                                      |
           |<------------------------------+                                      |
           |                                                                      |
+----------+----------+                                                          |
|  Hệ thống đích      |                                                          |
|  AWS / Win / RHEL   |<---------------------------------------------------------+
|  K8s / OpenShift    |
+---------------------+

```

## Còn thiếu

Bản nháp này chưa có:

- Cấu hình cụ thể của Jira Automation Rule (payload, authentication sang CI).
- `Jenkinsfile` cho cả hai pipeline.
- Cách quản lý credentials: token Jira, deploy key GitLab, kubeconfig.
- Xử lý lỗi giữa chừng — ví dụ pipeline 1 push thành công nhưng pipeline 2
  không trigger, ticket sẽ kẹt ở trạng thái nào?
- Chống race condition khi nhiều ticket cùng sửa một file values.
- Timeout và cách hủy một job đang chạy từ phía Jira.
