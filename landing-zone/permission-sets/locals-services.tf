########################################
# NGUON SU THAT DUY NHAT VE DANH SACH SERVICE
#
# Van de duoc giai o day:
#
#   lz-app-admin = lz-server-admin  U  lz-db-admin  (dung y nguyen,
#   khong lech mot service nao)
#
# Neu viet tay ba lan thi sau vai thang chung se lech nhau: them
# Step Functions vao server-admin, quen app-admin, khong ai phat hien
# cho toi khi co nguoi bao loi permission.
#
# Dinh nghia MOT LAN o day, moi permission set tham chieu vao.
########################################

locals {
  ########################################
  # Compute / application platform
  ########################################
  svc_compute = [
    "autoscaling",
    "elasticloadbalancing",
    "elasticfilesystem",
    "s3",
    "lambda",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "sns",
    "sqs",
    "kinesis",
    "firehose",
    "apigateway",
    "cloudformation",

    # Bo sung so voi bang goc - lo`i cua repo serverless nay (doc 01-05)
    "states",    # Step Functions
    "events",    # EventBridge
    "scheduler", # EventBridge Scheduler

    # Bo sung - container. Khong co dong nay thi khong ai push duoc
    # image cho Lambda container hay ECS.
    "ecr",
    "ecs",
    "eks",

    # Bo sung - quan sat. App team khong doc duoc log cua chinh minh
    # la loi hay gap nhat khi siet quyen.
    "logs",
    "cloudwatch",
    "xray",
    "application-autoscaling",

    # Bo sung - secret. Bang goc cho security-admin quan KMS nhung
    # khong ai quan Secrets Manager -> se co nguoi nhet secret vao
    # bien moi truong.
    "secretsmanager",
  ]

  ########################################
  # Database
  ########################################
  svc_database = [
    "rds",
    "dynamodb",
    "dax",
    "elasticache",
    "memorydb",

    # Redshift co MAT O CA analytics. Xem doc 19 muc 4.1 - phai chot
    # chu so huu. Mac dinh o day: giu ca hai, ghi ro la co y.
    "redshift",
    "redshift-data",
    "redshift-serverless",
  ]

  ########################################
  # Network
  #
  # Bang goc ghi \"EC2 network APIs, Direct Connect, Route 53\".
  # Nhung thiet ke LZ (doc 13/15) con dung ba service o NAMESPACE KHAC:
  #
  #   network-firewall:*    - KHONG thuoc ec2:*
  #   route53resolver:*     - KHONG thuoc route53:*
  #   ram:*                 - can de share TGW cross-account
  #
  # Thieu ba dong do thi lz-network-admin khong dung noi chinh
  # security VPC trong doc 15.
  ########################################
  svc_network = [
    "route53",
    "route53domains",
    "route53resolver",
    "network-firewall",
    "networkmanager",
    "directconnect",
    "globalaccelerator",
    "ram",
    "elasticloadbalancing", # GWLB - thiet bi mang, de network quan
    "cloudfront",
    "wafv2",
    "shield",
  ]

  ########################################
  # Security
  ########################################
  svc_security = [
    "iam",
    "access-analyzer",
    "config",
    "cloudtrail",
    "guardduty",
    "securityhub",
    "detective",
    "inspector2",
    "macie2",
    "kms",
    "acm",
    "acm-pca",
    "cloudwatch",
    "logs",

    # KHONG dua sso / sso-directory / identitystore vao day.
    #
    # Hai ly do:
    #   1. deny_guardrails chan sso:Put*/Update*/Delete* - Deny luon
    #      thang Allow, nen dua vao chi tao mau thuan doc kho hieu.
    #   2. Identity Center nam o management account, ma pham vi "all"
    #      da loai management account ra roi.
    #
    # Quan tri Identity Center thuoc ve lz-account-admin (platform),
    # khong thuoc mien security.
  ]

  ########################################
  # Analytics
  ########################################
  svc_analytics = [
    "athena",
    "glue",
    "elasticmapreduce",
    "emr-serverless",
    "emr-containers",
    "lakeformation",
    "redshift",
    "redshift-data",
    "redshift-serverless",
    "s3",
    "sagemaker",
    "lambda",
    "kinesis",
    "firehose",
    "quicksight",
    "datazone",
    "glue",
    "logs",
    "cloudwatch",
  ]

  ########################################
  # Billing
  #
  # aws-portal:* da bi AWS NGUNG (2023) va thay bang cac namespace
  # rieng duoi day. Policy cu chi con \"billing\" + \"aws-portal\" se
  # khong con tac dung day du.
  ########################################
  svc_billing = [
    "billing",
    "payments",
    "tax",
    "consolidatedbilling",
    "invoicing",
    "freetier",
    "purchase-orders",
    "cur",
    "ce",
    "budgets",
    "cost-optimization-hub",
    "compute-optimizer",
  ]

  ########################################
  # SINH ACTION
  #
  # admin    : svc:*
  # readonly : svc:Describe*  svc:List*  svc:Get*
  ########################################

  read_verbs = ["Describe*", "List*", "Get*"]

  svc_groups = {
    compute   = local.svc_compute
    database  = local.svc_database
    network   = local.svc_network
    security  = local.svc_security
    analytics = local.svc_analytics
    billing   = local.svc_billing
  }

  admin_actions = {
    for g, svcs in local.svc_groups :
    g => sort(distinct([for s in svcs : "${s}:*"]))
  }

  read_actions = {
    for g, svcs in local.svc_groups :
    g => sort(distinct(flatten([
      for s in svcs : [for v in local.read_verbs : "${s}:${v}"]
    ])))
  }

  ########################################
  # Ghep nhom - lz-app-* dung dung phep hop cua hai nhom kia
  ########################################

  actions_app_admin = sort(distinct(concat(
    ["ec2:*"],
    local.admin_actions["compute"],
    local.admin_actions["database"],
  )))

  actions_app_read = sort(distinct(concat(
    [for v in local.read_verbs : "ec2:${v}"],
    local.read_actions["compute"],
    local.read_actions["database"],
  )))
}
