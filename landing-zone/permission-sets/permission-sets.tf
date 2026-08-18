########################################
# VI SAO POLICY DUOC RAP TU CHUOI JSON
#
# Terraform khong ghep duoc mot list cac object co bo thuoc tinh
# KHAC NHAU (co Condition / khong co Condition) - concat() va for
# se ep kieu roi bao loi.
#
# Cach vong qua: jsonencode TUNG statement rieng le thanh chuoi,
# roi rap cac chuoi lai. Map duoi day la map<string,string> - dong
# nhat kieu, khong bao gio vuong loi ep kieu.
#
# Doi lai phai tu dam bao moi phan tu la JSON hop le. Chay
# ./validate-policies.sh de kiem tra.
########################################

locals {
  stmt = {

    ####################################
    # Allow theo mien
    ####################################

    allow_billing = jsonencode({
      Sid      = "BillingAndCostManagement"
      Effect   = "Allow"
      Action   = local.admin_actions["billing"]
      Resource = "*"
    })

    allow_billing_read = jsonencode({
      Sid      = "BillingReadOnly"
      Effect   = "Allow"
      Action   = local.read_actions["billing"]
      Resource = "*"
    })

    allow_network_admin = jsonencode({
      Sid    = "NetworkAdmin"
      Effect = "Allow"
      Action = concat(
        ["ec2:*"],
        local.admin_actions["network"],
      )
      Resource = "*"
    })

    allow_network_read = jsonencode({
      Sid    = "NetworkReadOnly"
      Effect = "Allow"
      Action = concat(
        [for v in local.read_verbs : "ec2:${v}"],
        local.read_actions["network"],
      )
      Resource = "*"
    })

    allow_security_admin = jsonencode({
      Sid    = "SecurityAdmin"
      Effect = "Allow"
      Action = concat(
        local.admin_actions["security"],
        ["organizations:Describe*", "organizations:List*"],
      )
      Resource = "*"
    })

    allow_server_admin = jsonencode({
      Sid    = "ServerAdmin"
      Effect = "Allow"
      Action = concat(
        ["ec2:*"],
        local.admin_actions["compute"],
      )
      Resource = "*"
    })

    allow_server_read = jsonencode({
      Sid    = "ServerReadOnly"
      Effect = "Allow"
      Action = concat(
        [for v in local.read_verbs : "ec2:${v}"],
        local.read_actions["compute"],
      )
      Resource = "*"
    })

    allow_db_admin = jsonencode({
      Sid      = "DatabaseAdmin"
      Effect   = "Allow"
      Action   = local.admin_actions["database"]
      Resource = "*"
    })

    allow_db_read = jsonencode({
      Sid      = "DatabaseReadOnly"
      Effect   = "Allow"
      Action   = local.read_actions["database"]
      Resource = "*"
    })

    allow_analytics_admin = jsonencode({
      Sid      = "AnalyticsAdmin"
      Effect   = "Allow"
      Action   = local.admin_actions["analytics"]
      Resource = "*"
    })

    allow_analytics_read = jsonencode({
      Sid      = "AnalyticsReadOnly"
      Effect   = "Allow"
      Action   = local.read_actions["analytics"]
      Resource = "*"
    })

    # lz-app-* = phep hop cua compute + database, sinh tu CUNG MOT
    # nguon voi server-admin va db-admin nen khong the lech.
    allow_app_admin = jsonencode({
      Sid      = "AppAdmin"
      Effect   = "Allow"
      Action   = local.actions_app_admin
      Resource = "*"
    })

    allow_app_read = jsonencode({
      Sid      = "AppReadOnly"
      Effect   = "Allow"
      Action   = local.actions_app_read
      Resource = "*"
    })

    # Ba action Lake Formation tach rieng - xem locals-policies.tf muc 5
    allow_datalake_grants = jsonencode({
      Sid    = "DataLakeAdministration"
      Effect = "Allow"
      Action = [
        "lakeformation:*",
        "glue:*",
        "s3:GetBucket*",
        "s3:ListBucket*",
        "ram:*",
      ]
      Resource = "*"
    })

    ####################################
    # Doc log - CAP RIENG
    #
    # Day la thu so mot app team can o production va la thu de bi
    # sot nhat khi siet quyen. ViewOnlyAccess KHONG cho doc noi dung
    # log event, chi thay log group ton tai.
    ####################################

    allow_logs_read = jsonencode({
      Sid    = "ReadApplicationLogs"
      Effect = "Allow"
      Action = [
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "logs:StartQuery",
        "logs:StopQuery",
        "logs:GetQueryResults",
        "logs:Describe*",
        "logs:List*",
        "cloudwatch:GetMetric*",
        "cloudwatch:Describe*",
        "cloudwatch:List*",
        "xray:Get*",
        "xray:BatchGet*",
      ]
      Resource = "*"
    })

    ####################################
    # Manh dung chung (locals-policies.tf)
    ####################################

    deny_ec2_network        = jsonencode(local.deny_ec2_network)
    deny_ec2_security       = jsonencode(local.deny_ec2_security)
    deny_iam_writes         = jsonencode(local.deny_iam_writes)
    deny_data_plane         = jsonencode(local.deny_data_plane)
    deny_interactive_access = jsonencode(local.deny_interactive_access)
    deny_lakeformation      = jsonencode(local.deny_lakeformation_grants)
    deny_guardrails         = jsonencode(local.deny_guardrails)
    passrole_workload       = jsonencode(local.passrole_workload)
    passrole_analytics      = jsonencode(local.passrole_analytics)
    iam_minimal             = jsonencode(local.iam_minimal_for_workload)

    boundary_1 = length(local.deny_create_without_boundary) > 0 ? jsonencode(local.deny_create_without_boundary[0]) : ""
    boundary_2 = length(local.deny_create_without_boundary) > 0 ? jsonencode(local.deny_create_without_boundary[1]) : ""
  }

  # Bat/tat theo bien - tra ve list ten statement (list<string>,
  # dong nhat kieu nen ghep thoai mai)
  guard_data  = var.operator_can_read_data ? [] : ["deny_data_plane"]
  guard_bound = var.enforce_security_admin_boundary ? ["boundary_1", "boundary_2"] : []
}

########################################
# DINH NGHIA 17 PERMISSION SET
#
# scope: quyet dinh gan vao account nao (xem assignments.tf)
#   all        - moi account trong organization
#   management - chi management account
#   analytics  - OU Data Analytics
#   nonprod    - OU Non-Production
#   prod       - OU Production
#   none       - KHONG gan tu dong (break-glass)
#
# session_duration phan tang theo rui ro:
#   PT1H - quyen ghi cao / cham du lieu production
#   PT4H - quyen ghi thuong ngay
#   PT8H - chi doc
########################################

locals {
  permission_sets = {

    ####################################
    # Ngang - moi mien
    ####################################

    "lz-account-admin" = {
      description      = "Full administrative access to the AWS account"
      session_duration = "PT1H"
      scope            = "all"
      managed          = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      statements       = []
    }

    "lz-billing" = {
      description      = "Billing information and cost reports (Billing, Cost Explorer)"
      session_duration = "PT4H"
      scope            = "management"
      managed          = ["arn:aws:iam::aws:policy/job-function/Billing"]
      statements       = ["allow_billing", "deny_guardrails"]
    }

    # KHAC BIET QUAN TRONG NHAT so voi bang goc:
    # dung ViewOnlyAccess chu KHONG dung ReadOnlyAccess.
    # ReadOnlyAccess bao gom s3:GetObject, dynamodb:Scan... - gan cho
    # auditor o TAT CA account la cap quyen doc toan bo du lieu prod.
    "lz-auditor" = {
      description      = "Read-only view of configuration across the account (no data plane access)"
      session_duration = "PT8H"
      scope            = "all"
      managed = [
        "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
        "arn:aws:iam::aws:policy/SecurityAudit",
      ]
      statements = concat(["allow_billing_read", "deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    ####################################
    # Mien Network
    ####################################

    "lz-network-admin" = {
      description      = "Administrative access to AWS networking services and APIs"
      session_duration = "PT4H"
      scope            = "all"
      managed          = ["arn:aws:iam::aws:policy/job-function/NetworkAdministrator"]
      statements       = ["allow_network_admin", "iam_minimal", "deny_iam_writes", "deny_guardrails"]
    }

    "lz-network-operator" = {
      description      = "Read-only access to AWS networking services and APIs"
      session_duration = "PT8H"
      scope            = "all"
      managed          = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      statements       = concat(["allow_network_read", "deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    ####################################
    # Mien Security
    #
    # CANH BAO: co iam:* nen VE KY THUAT tuong duong lz-account-admin
    # tru khi bat enforce_security_admin_boundary. Xem doc 19 muc 3.2.
    ####################################

    "lz-security-admin" = {
      description      = "Administrative access to AWS security services and APIs"
      session_duration = "PT1H"
      scope            = "all"
      managed          = []
      statements       = concat(["allow_security_admin", "deny_guardrails"], local.guard_bound)
    }

    "lz-security-operator" = {
      description      = "Read-only access to AWS security services and APIs"
      session_duration = "PT8H"
      scope            = "all"
      managed = [
        "arn:aws:iam::aws:policy/SecurityAudit",
        "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
      ]
      statements = concat(["deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    ####################################
    # Mien Server / compute
    ####################################

    "lz-server-admin" = {
      description      = "Administrative access to compute, storage and related services"
      session_duration = "PT4H"
      scope            = "all"
      managed          = []
      statements = [
        "allow_server_admin",
        "deny_ec2_network",
        "deny_ec2_security",
        "passrole_workload",
        "iam_minimal",
        "deny_iam_writes",
        "deny_guardrails",
      ]
    }

    "lz-server-operator" = {
      description      = "Read-only access to compute, storage and related services"
      session_duration = "PT8H"
      scope            = "all"
      managed          = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      statements       = concat(["allow_server_read", "allow_logs_read", "deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    ####################################
    # Mien Database
    #
    # CANH BAO: gan pham vi \"all\" nghia la co quyen GHI len database
    # production, va dynamodb:Scan = doc duoc toan bo du lieu khach
    # hang. Day la quyen co gia tri cao nhat trong ca bang.
    # Xem doc 19 muc 4.3 truoc khi giu nguyen \"all\".
    ####################################

    "lz-db-admin" = {
      description      = "Administrative access to the database services"
      session_duration = "PT1H"
      scope            = "all"
      managed          = []
      statements       = ["allow_db_admin", "passrole_workload", "iam_minimal", "deny_iam_writes", "deny_guardrails"]
    }

    "lz-db-operator" = {
      description      = "Read-only access to the database services"
      session_duration = "PT8H"
      scope            = "all"
      managed          = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      statements       = concat(["allow_db_read", "deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    ####################################
    # Mien Analytics
    ####################################

    "lz-analytics-admin" = {
      description      = "Administrative access to the data platform and analytics services"
      session_duration = "PT4H"
      scope            = "analytics"
      managed          = []
      statements = [
        "allow_analytics_admin",
        "deny_lakeformation", # tach sang lz-datalake-admin
        "passrole_analytics", # SageMaker notebook = shell that
        "iam_minimal",
        "deny_iam_writes",
        "deny_guardrails",
      ]
    }

    "lz-analytics-operator" = {
      description      = "Read-only access to the data platform and analytics services"
      session_duration = "PT8H"
      scope            = "analytics"
      managed          = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      statements       = concat(["allow_analytics_read", "deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    # Tach tu lz-analytics-admin. Cap cho rat it nguoi.
    "lz-datalake-admin" = {
      description      = "Lake Formation data lake administration (can grant data access - restricted)"
      session_duration = "PT1H"
      scope            = "analytics"
      managed          = []
      statements       = ["allow_datalake_grants", "deny_iam_writes", "deny_guardrails"]
    }

    ####################################
    # Mien Application
    #
    # QUYET DINH LON NHAT TRONG CA BANG:
    #   app-admin  -> chi Non-Production
    #   app-operator -> chi Production, chi doc
    #
    # Nghia la KHONG CON NGUOI NAO co quyen ghi len prod application.
    # Chi pipeline vao duoc. Xem doc 19 muc 2.
    ####################################

    "lz-app-admin" = {
      description      = "Application set up, deployment and maintenance - non-production only"
      session_duration = "PT4H"
      scope            = "nonprod"
      managed          = []
      statements = [
        "allow_app_admin",
        "deny_ec2_network",
        "deny_ec2_security",
        "passrole_workload",
        "iam_minimal",
        "deny_iam_writes",
        "deny_guardrails",
      ]
    }

    "lz-app-operator" = {
      description      = "Read-only access to application resources - production"
      session_duration = "PT8H"
      scope            = "prod"
      managed          = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      statements       = concat(["allow_app_read", "allow_logs_read", "deny_iam_writes", "deny_interactive_access"], local.guard_data)
    }

    # KHONG co assignment thuong truc (scope = none).
    # Tao assignment khi co su co, go sau khi xong. Xem doc 19 muc 2.2.
    "lz-app-breakglass" = {
      description      = "EMERGENCY write access to production applications - assign on demand only"
      session_duration = "PT1H"
      scope            = "none"
      managed          = []
      statements = [
        "allow_app_admin",
        "deny_ec2_network",
        "passrole_workload",
        "iam_minimal",
        "deny_iam_writes",
        "deny_guardrails",
      ]
    }
  }
}

########################################
# RESOURCE
########################################

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_sets

  name             = each.key
  description      = each.value.description
  instance_arn     = local.sso_instance_arn
  session_duration = each.value.session_duration

  # Doi permission set thi Identity Center KHONG tu day thay doi
  # xuong cac IAM role da sinh - phai provision lai. Terraform lam
  # viec do khi relay_state/session doi, nhung voi inline policy thi
  # provider da xu ly san.
  tags = merge(local.common_tags, { PermissionSetScope = each.value.scope })
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = {
    for pair in flatten([
      for ps_name, ps in local.permission_sets : [
        for arn in ps.managed : {
          key = "${ps_name}|${basename(arn)}"
          ps  = ps_name
          arn = arn
        }
      ]
    ]) : pair.key => pair
  }

  instance_arn       = local.sso_instance_arn
  managed_policy_arn = each.value.arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.ps].arn
}

resource "aws_ssoadmin_permission_set_inline_policy" "this" {
  for_each = {
    for k, v in local.permission_sets : k => v
    if length(v.statements) > 0
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn

  inline_policy = format(
    "{\"Version\":\"2012-10-17\",\"Statement\":[%s]}",
    join(",", [for n in each.value.statements : local.stmt[n]])
  )
}
