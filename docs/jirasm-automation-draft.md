```text
+---------------------+         +----------------------+         +------------------------+
|  Người dùng / Dev   |         |     Jira Service     |         |   Jenkins / GitLab CI  |
|  Ops / Business     |         |   Management (JSM)   |         |   (Pipeline Engine)    |
+----------+----------+         +----------+-----------+         +-----------+------------+
           |                               |                                 |
           | 1. Tạo ticket JSM:            |                                 |
           |    - Loại: Deploy / Ops       |                                 |
           |    - Chọn Department, Env,... |                                 |
           |    - Đính kèm values_jira.yml |                                 |
           |------------------------------>|                                 |
           |                               |                                 |
           |                               | 2. JSM tạo Issue Key            |
           |                               |    vd: OPS-123                  |
           |                               | (JIRA_ISSUE_KEY = "OPS-123")    |
           |                               |                                 |
           |                               | 3. Workflow & Approval          |
           |                               |    Open -> In Review ->         |
           |                               |    -> Approved / Rejected       |
           |                               +------------------------------+  |
           |                                                              |  |
           |                               4. Khi "Approved"              |  |
           |                               Jira Automation Rule:          |  |
           |                               - Trigger: status -> Approved  |  |
           |                               - Action: Send Web Request     |  |
           |                                 (Webhook)                    |  |
           |                               |                              |  |
           |                               |  body JSON gửi sang CI:      |  |
           |                               |  {                           |  |
           |                               |    "issueKey": "OPS-123",    |  |
           |                               |    "department": "...",      |  |
           |                               |    "requestType": "deploy",  |  |
           |                               |    "service": "svc-a",       |  |
           |                               |    "env": "staging",         |  |
           |                               |    "version": "v1.2.3"       |  |
           |                               |  }                           |  |
           |                               +------------HTTP------------->| 5. CI nhận webhook
           |                                                             |    - Map issueKey
           |                                                             |      -> JIRA_ISSUE_KEY
           |                                                             |    - Nhận service/env/...
           |                                                             |
           |                                                             | 6. CI: Download values từ Jira
           |                                                             |    - Dùng JIRA_ISSUE_KEY:
           |                                                             |      GET /rest/api/3/issue/OPS-123
           |                                                             |      -> đọc .fields.attachment
           |                                                             |    - Download values_jira.yaml
           |                                                             |
           |                                                             | 7. CI: Merge values bằng yq
           |                                                             |    - values_base.yaml (repo)
           |                                                             |    - values_jira.yaml (từ Jira)
           |                                                             |  -> values_final.yaml
           |                                                             |
           |                                                             | 8. (Optional) CI commit/push:
           |                                                             |    - Push values_final.yaml
           |                                                             |      vào GitLab project
           |                                                             |    - Commit message chứa
           |                                                             |      "OPS-123" để trace
           |                                                             |
           |                                                             | 9a. Nếu requestType = "deploy":
           |                                                             |    - Build & Test
           |                                                             |    - SonarQube
           |                                                             |    - Trivy / BlackDuck
           |                                                             |    - Push image -> Nexus
           |                                                             |    - Deploy (Helm/kubectl/oc/ArgoCD)
           |                                                             |
           |                                                             | 9b. Nếu requestType = "ops":
           |                                                             |    - AWS CLI/Terraform/CFN
           |                                                             |    - PowerShell (Windows)
           |                                                             |    - Bash/Ansible (RHEL)
           |                                                             |    - kubectl/oc/Helm (K8s/OCP)
           |                                                             |
           |                                                             | 10. CI đánh giá kết quả:
           |                                                             |     success / failed / timeout
           |                                                             |
           |                                                             | 11. CI update Jira bằng REST API
           |                                                             |     - Dùng JIRA_ISSUE_KEY:
           |                                                             |       POST /issue/OPS-123/comment
           |                                                             |       POST /issue/OPS-123/transitions
           |                                                             |     - Comment: log, link pipeline
           |                                                             |     - Transition status:
           |                                                             |       -> Succeeded / Failed / Timeout
           |                                                             +------------------------------+
           |                               |                                 |
           | 12. User xem kết quả          |                                 |
           |     - Ticket OPS-123:         |                                 |
           |       + status final          |                                 |
           |       + log CI, version, env  |                                 |
           |<------------------------------+                                 |
           |                                                                 |
+----------+----------+         +----------------------+         +-----------+------------+
|  Hệ thống đích      |                                                     |
|  AWS / Win / RHEL   |<----------------------------------------------------+
|  K8s / OpenShift    |
+---------------------+

```
