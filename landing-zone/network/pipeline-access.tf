########################################
# ROLE CHO PIPELINE TRIEN KHAI VAO ACCOUNT NAY
#
# Layer landing-zone/vending-pipeline chay o account MANAGEMENT. Hai
# trong sau stage cua no la layer nay - chia se TGW, va noi attachment
# vao route table - va ca hai deu phai chay bang danh tinh cua ACCOUNT
# MANG.
#
# Management khong tao duoc IAM role trong account khac. Nen role nay
# duoc tao TU CHINH DAY, boi credential cua account mang, va no chi
# ton tai khi co ai khai var.pipeline_trusted_role_arns.
#
# ---------------------------------------------------------------
# VI SAO KHONG PHAI OrganizationAccountAccessRole
#
# Role do co san, quyen day du, va management assume duoc ngay - dung
# no thi khoi phai viet file nay.
#
# Ba ly do khong:
#
#   1. No la duong khan cap cua CON NGUOI. Tron duong tu dong hoa vao
#      do thi trong CloudTrail khong con phan biet duoc "pipeline
#      trien khai" voi "ai do vao sua tay luc 2 gio sang".
#   2. Quyen cua no la TOAN BO account. Role nay chi can nhung gi
#      layer network dung toi.
#   3. Go quyen cua pipeline = go mot dong tfvars. Go quyen cua
#      OrganizationAccountAccessRole = mot cuoc hop.
#
# ---------------------------------------------------------------
# PHAM VI QUYEN - noi thang la RONG
#
# Layer network so huu TGW, ba VPC ha tang, moi VPC spoke noi bo,
# Network Firewall, NAT, Route 53 Profile, RAM share va StackSet.
# Mot role trien khai duoc no la mot role sua duoc gan het mang cua
# to chuc.
#
# Do la cai gia cua viec tu dong hoa buoc 2 va buoc 5. Neu thay dat
# qua thi lua chon khac la de hai stage do chay tay - pipeline van
# lo bon stage con lai. Xem doc 27.
########################################

locals {
  pipeline_access_on = length(var.pipeline_trusted_role_arns) > 0
}

data "aws_iam_policy_document" "pipeline_trust" {
  count = local.pipeline_access_on ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.pipeline_trusted_role_arns
    }

    # ExternalId KHONG dung o day.
    #
    # No sinh ra cho bai toan "deputy bi lua" - khi mot ben THU BA
    # assume role thay ban. Ca hai account nay cung mot to chuc va
    # cung mot chu, nen khong co ben thu ba nao, va them ExternalId
    # chi tao cam giac an toan kem mot chuoi phai giu dong bo o hai
    # noi.
    #
    # Thu that su thu hep pham vi la danh sach principal o tren: dung
    # MOT role cu the, khong phai :root cua account management.
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.pipeline[0].id]
    }
  }
}

data "aws_organizations_organization" "pipeline" {
  count = local.pipeline_access_on ? 1 : 0
}

resource "aws_iam_role" "pipeline_deploy" {
  count = local.pipeline_access_on ? 1 : 0

  name               = "${var.project}-pipeline-deploy"
  description        = "Pipeline vending trien khai layer network. Xem pipeline-access.tf"
  assume_role_policy = data.aws_iam_policy_document.pipeline_trust[0].json

  # Mot gio: du cho mot lan apply cua layer nay (~20-30 phut khi dung
  # ca firewall), va ngan mot phien bi bo quen thanh mot duong vao
  # song mai.
  max_session_duration = 3600

  tags = { Name = "${var.project}-pipeline-deploy" }
}

# Quyen: rong, va noi ro la rong.
#
# KHONG dung AdministratorAccess. Khac biet nghe nhu hinh thuc, nhung
# no thuc: role nay khong tao duoc IAM user, khong doi duoc chinh
# trust policy cua no, va khong cham duoc vao Organizations. Ba thu
# do la nhung gi mot role bi chiem se dung de o lai.
resource "aws_iam_role_policy" "pipeline_deploy" {
  count = local.pipeline_access_on ? 1 : 0

  name = "trien-khai-network"
  role = aws_iam_role.pipeline_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HaTangMang"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "elasticloadbalancing:*",
          "network-firewall:*",
          "route53:*",
          "route53resolver:*",

          # Route 53 Profiles la mot NAMESPACE IAM RIENG.
          #
          # `route53:*` va `route53resolver:*` khong phu no, du ba cai
          # cung nam duoi mot ten dich vu tren console. Thieu dong nay
          # thi plan cua layer chay den `aws_route53profiles_profile`
          # roi dung:
          #
          #   AccessDeniedException: ... not authorized to perform:
          #   route53profiles:GetProfile ... because no identity-based
          #   policy allows the route53profiles:GetProfile action
          #
          # Thong bao noi dung ten action, nen no de sua - cai kho la
          # doan TRUOC rang co mot namespace thu ba.
          "route53profiles:*",
          "ram:*",
          "logs:*",
          "cloudwatch:*",
          "s3:*",
          "kms:*",
          "ssm:GetParameter*",
          "sts:GetCallerIdentity",
          "organizations:Describe*",
          "organizations:List*",
          "cloudformation:*",
          "servicequotas:Get*",
          "servicequotas:List*",
        ]
        Resource = "*"
      },
      {
        # IAM: chi nhung gi layer nay that su tao - instance profile
        # cho EC2 do duong, role cho VPC flow log. KHONG co
        # iam:CreateUser, khong co iam:CreateAccessKey.
        Sid    = "IamHepPhamVi"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:PassRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:CreateServiceLinkedRole",
        ]
        Resource = "*"
      },
      {
        # Chan role tu sua chinh no. Khong co dong nay thi mot phien
        # bi chiem co the noi rong trust policy va o lai vinh vien.
        Sid    = "KhongTuSuaChinhMinh"
        Effect = "Deny"
        Action = [
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
        ]
        Resource = aws_iam_role.pipeline_deploy[0].arn
      },
    ]
  })
}

output "pipeline_deploy_role_arn" {
  description = <<-EOT
    Dan vao assume_role_arn cua chinh layer nay, o phia pipeline.

    Rong = chua bat. Bat bang cach khai pipeline_trusted_role_arns.
  EOT
  value       = local.pipeline_access_on ? aws_iam_role.pipeline_deploy[0].arn : ""
}

########################################
# KIEM TRA CHEO
########################################

check "pipeline_role_khong_tro_ve_chinh_no" {
  assert {
    condition = (
      !local.pipeline_access_on
      || !contains(var.pipeline_trusted_role_arns, try(aws_iam_role.pipeline_deploy[0].arn, ""))
    )
    error_message = "pipeline_trusted_role_arns chua chinh role vua tao - mot vong tin cay khong dan toi dau. Dien ARN role CodeBuild ben vending-pipeline."
  }
}
