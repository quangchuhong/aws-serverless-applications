+---------------------+         +----------------------+         +------------------------+
|  Người dùng / Dev   |         |     Jira Service     |         |   Jenkins / GitLab CI  |
|  Ops / Business     |         |   Management (JSM)   |         |   (Pipeline Engine)    |
+----------+----------+         +----------+-----------+         +-----------+------------+
           |                               |                                 |
           | 1. Tạo ticket:                |                                 |
           |    - Deploy app               |                                 |
           |    - Change config (values)   |                                 |
           |    - Ops AWS/Win/RHEL/K8s     |                                 |
           |    - Đính kèm values_jira.yml |                                 |
           |------------------------------>|                                 |
           |                               |                                 |
           |                               | 2. Workflow + Approval          |
           |                               |    Open -> In Review ->         |
           |                               |    -> Approved / Rejected       |
           |                               +------------------------------+  |
           |                                                              |  |
           |                               3. Khi "Approved"              |  |
           |                               Jira Automation (Rule):        |  |
           |                               - Trigger: issue transitioned  |  |
           |                                 to Approved                 |  |
           |                               - Action: Send Web Request    |  |
           |                                 (Webhook)                   |  |
           |                               |                             |  |
           |                               |  body: {                    |  |
           |                               |    issueKey, requestType,   |  |
           |                               |    service, env, action,    |  |
           |                               |    version,...               |  |
           |                               |                             |  |
           |                               +------------HTTP------------->| 4. CI nhận params
           |                                                             |    từ webhook
           |                                                             |    -> chọn pipeline
           |                                                             |
           |                                                             | 5. CI dùng Jira REST API:
           |                                                             |    - GET issue attachments
           |                                                             |    - Download values_jira.yml
           |                                                             |
           |                                                             | 6. CI merge values bằng yq:
           |                                                             |    - values_base.yml (repo)
           |                                                             |    - values_jira.yml (từ Jira)
           |                                                             | -> values_final.yml
           |                                                             |
           |                                                             | 7. (Optional) Git commit/push:
           |                                                             |    - Commit values vào GitLab repo
           |                                                             |
           |                                                             | 8a. Nếu request là "Deploy app":
           |                                                             |    - Build & Test
           |                                                             |    - SonarQube
           |                                                             |    - Trivy / BlackDuck
           |                                                             |    - Push image -> Nexus
           |                                                             |    - Deploy (Helm/kubectl/oc/ArgoCD)
           |                                                             |
           |                                                             | 8b. Nếu request là "Ops":
           |                                                             |    - AWS CLI/Terraform/CFN
           |                                                             |    - PowerShell (Windows)
           |                                                             |    - Bash/Ansible (RHEL)
           |                                                             |    - kubectl/oc/Helm (K8s/OCP)
           |                                                             |
           |                                                             | 9. CI đánh giá kết quả:
           |                                                             |    - success / failed
           |                                                             |
           |                                                             | 10. CI gọi Jira REST API:
           |                                                             |    - Add comment (log, link build)
           |                                                             |    - Update custom fields
           |                                                             |    - Transition: In Progress ->
           |                                                             |        Deployed/Done/Failed
           |                                                             +------------------------------+
           |                               |                                 |
           | 11. Xem kết quả:              |                                 |
           |     - Trạng thái ticket       |                                 |
           |     - Log, version, env       |                                 |
           |<------------------------------+                                 |
           |                                                                 |
+----------+----------+         +----------------------+         +-----------+------------+
|  Hệ thống đích      |                                                     |
|  AWS / Win / RHEL   |<----------------------------------------------------+
|  K8s / OpenShift    |
+---------------------+
