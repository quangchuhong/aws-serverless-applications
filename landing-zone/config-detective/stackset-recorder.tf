########################################
# CONFIG RECORDER - trien khai qua STACKSET
#
# Recorder phai ton tai o TUNG account x TUNG region. Khong co API
# nao bat no cho ca to chuc mot lan (tru Control Tower).
#
# StackSet voi auto_deployment: account MOI vao OU se tu duoc trien
# khai, khong can chay lai Terraform. Day chinh la co che baseline
# o doc 09.
#
# Template viet bang jsonencode chu khong phai file YAML rieng -
# tranh hoan toan bay thut le cua YAML, va duoc kiem kieu.
########################################

locals {
  recorder_template = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "LZ Config recorder - quan ly boi Terraform (config-detective)"

    Resources = {
      ConfigRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName = "${var.project}-config-recorder"
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "config.amazonaws.com" }
              Action    = "sts:AssumeRole"
            }]
          }
          ManagedPolicyArns = [
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
          ]
          Policies = [{
            PolicyName = "DeliverToCentralBucket"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [{
                Effect = "Allow"
                Action = ["s3:PutObject", "s3:GetBucketAcl"]
                Resource = [
                  "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}",
                  "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/*",
                ]
              }]
            }
          }]
        }
      }

      # THU TU: DeliveryChannel TRUOC, ConfigRecorder SAU.
      #
      # Nguoc voi truc giac, va nguoc voi ban dau cua file nay.
      # CloudFormation khong chi TAO recorder ma con KHOI DONG no, va
      # StartConfigurationRecorder doi delivery channel phai co san:
      #
      #   NoAvailableDeliveryChannelException: Delivery channel is not
      #   available to start configuration recorder
      #
      # Da kiem chung KHONG co vong lap: put-delivery-channel chay
      # duoc tren mot account CHUA CO recorder nao. Nen chi la sai
      # thu tu, khong phai phu thuoc vong tron.
      ConfigRecorder = {
        Type      = "AWS::Config::ConfigurationRecorder"
        DependsOn = ["ConfigRole", "DeliveryChannel"]
        Properties = {
          Name    = "${var.project}-recorder"
          RoleARN = { "Fn::GetAtt" = ["ConfigRole", "Arn"] }

          RecordingGroup = {
            # KHONG dung AllSupported = true. Do la cach dat nhat.
            AllSupported = false

            # Chi bat duoc khi AllSupported = true. De false va liet ke
            # thang loai IAM trong ResourceTypes.
            IncludeGlobalResourceTypes = false

            ResourceTypes = var.resource_types
          }

          RecordingMode = merge(
            { RecordingFrequency = var.recording_frequency },

            # Chi co y nghia khi tan suat chinh la DAILY
            var.recording_frequency == "DAILY" && length(var.continuous_recording_types) > 0 ? {
              RecordingModeOverrides = [{
                ResourceTypes      = var.continuous_recording_types
                RecordingFrequency = "CONTINUOUS"
                Description        = "Thay doi ve quyen va port phai biet ngay, cham mot ngay la qua lau"
              }]
            } : {},
          )
        }
      }

      # MOI ACCOUNT CHI DUOC MOT DELIVERY CHANNEL o mot region.
      # Con mot cai khac dang ton tai - ke ca cai tro vao bucket da
      # xoa - thi tao cai nay se bao:
      #   MaxNumberOfDeliveryChannelsExceededException
      # Kiem truoc khi trien khai:
      #   aws configservice describe-delivery-channels --profile <account>
      DeliveryChannel = {
        Type      = "AWS::Config::DeliveryChannel"
        DependsOn = "ConfigRole"
        Properties = {
          Name         = "${var.project}-delivery"
          S3BucketName = local.bucket_name
          ConfigSnapshotDeliveryProperties = {
            DeliveryFrequency = var.snapshot_delivery_frequency
          }
        }
      }
    }
  })
}

resource "aws_cloudformation_stack_set" "recorder" {
  count = local.enabled ? 1 : 0

  name        = "${var.project}-config-recorder"
  description = "Config recorder cho moi account trong OU dich"

  # SERVICE_MANAGED = Organizations tu lo IAM role hai dau,
  # khong phai tu tao AWSCloudFormationStackSetExecutionRole
  #
  ####################################
  # DIEU KIEN TIEN QUYET THU CONG
  #
  #   ValidationError: You must enable organizations access to
  #   operate a service managed stack set
  #
  # Bat "member.org.stacksets.cloudformation.amazonaws.com" trong
  # aws_service_access_principals la CHUA DU. CloudFormation co loi
  # goi kich hoat RIENG, chay MOT LAN tu management account:
  #
  #   aws cloudformation activate-organizations-access --region <region>
  #
  # Kiem tra:
  #   aws cloudformation describe-organizations-access --region <region>
  #   -> Status: ENABLED
  #
  # Cung khuon voi Security Hub va GuardDuty: dang ky o tang
  # Organizations la mot chuyen, dich vu tu kich hoat la chuyen khac.
  ####################################
  permission_model = "SERVICE_MANAGED"

  auto_deployment {
    enabled = true

    # Account roi khoi OU thi go luon recorder - neu giu lai no se
    # tiep tuc ghi va tiep tuc tinh tien ma khong ai quan.
    retain_stacks_on_account_removal = false
  }

  capabilities  = ["CAPABILITY_NAMED_IAM"]
  template_body = local.recorder_template

  operation_preferences {
    # Trien khai tung it mot: sai thi dung lai som, khong lam hong
    # ca to chuc mot luot
    failure_tolerance_percentage = 10
    max_concurrent_percentage    = 25
    region_concurrency_type      = "PARALLEL"
  }

  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

resource "aws_cloudformation_stack_set_instance" "recorder" {
  count = local.enabled && length(var.recorder_target_ous) > 0 ? 1 : 0

  stack_set_name = aws_cloudformation_stack_set.recorder[0].name

  deployment_targets {
    organizational_unit_ids = var.recorder_target_ous
  }

  # Config la per-region. Moi region them vao nhan chi phi len
  # theo so account.
  #
  # TEN THAM SO DOI THEO BAN PROVIDER:
  #   provider v5  ->  region
  #   provider v6  ->  stack_set_instance_region
  #
  # v6 them meta-argument "region" cho MOI resource nen phai doi ten
  # cai cu de tranh dung do. Layer nay khai ~> 5.0 (versions.tf) nen
  # dung "region". Nang len v6 thi phai doi dong nay, neu khong se ra:
  #   An argument named "region" is not expected here
  region = var.region

  # 25% voi 4 account = TUNG ACCOUNT MOT. Do la chu y - sai thi dung
  # som. Doi lai la cham: moi account vai phut, cong don len nhanh.
  operation_preferences {
    failure_tolerance_percentage = 10
    max_concurrent_percentage    = 25
  }

  ####################################
  # 30 PHUT MAC DINH KHONG DU
  #
  # Trien khai tuan tu xuong tung account, moi account phai dung
  # CloudFormation stack rieng. 4 account da gan cham 30 phut; 10
  # account thi chac chan vuot.
  #
  # Vuot timeout KHONG phai that bai - StackSet van chay tiep o phia
  # AWS. Nhung Terraform danh dau resource TAINTED, va lan apply sau
  # se doi thay the mot thu dang hoat dong binh thuong.
  #
  # Gap taint o day thi kiem tra AWS TRUOC khi quyet dinh:
  #   aws cloudformation list-stack-instances \
  #     --stack-set-name <ten> --call-as SELF
  #   Tat ca CURRENT -> terraform untaint, dung thay the.
  ####################################
  timeouts {
    create = "90m"
    update = "90m"
    delete = "90m"
  }
}

########################################
# KIEM TRA CHEO
########################################

check "recorder_targets_declared" {
  assert {
    condition     = !local.enabled || length(var.recorder_target_ous) > 0
    error_message = "enable = true nhung recorder_target_ous rong -> khong account nao duoc trien khai recorder. Lay OU ID bang: terraform output ou_ids (layer organization)."
  }
}

check "accounts_declared" {
  assert {
    condition     = !local.enabled || (var.security_account_id != "" && var.log_archive_account_id != "")
    error_message = "Phai dien security_account_id va log_archive_account_id truoc khi bat."
  }
}

check "global_resources_recorded_once" {
  assert {
    condition = !anytrue([
      for t in var.resource_types : startswith(t, "AWS::IAM::")
    ]) || length(var.aggregator_regions) <= 2

    error_message = join(" ", [
      "resource_types co loai IAM (toan cau).",
      "Neu ban trien khai recorder o NHIEU region thi moi region se ghi lai",
      "cung mot resource IAM -> tra tien nhieu lan cho cung mot thu.",
      "Chi trien khai recorder o MOT region, hoac bo loai IAM khoi cac region con lai.",
    ])
  }
}
