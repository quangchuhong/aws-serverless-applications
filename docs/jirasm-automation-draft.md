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
           |                                                                         |
+----------+----------+         +----------------------+         +-------------------+--------+
|  Hệ thống đích      |                                                     |
|  AWS / Win / RHEL   |<----------------------------------------------------+
|  K8s / OpenShift    |
+---------------------+

```
