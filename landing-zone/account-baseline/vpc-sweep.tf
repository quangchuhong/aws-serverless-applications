########################################
# XOA DEFAULT VPC - trien khai qua STACKSET
#
# AWS tao san mot default VPC o MOI region cua MOI account moi, kem
# Internet Gateway da gan san. network_lock SCP chan TAO IGW moi,
# nhung khong dung toi cai da co - nen moi account moi mo ra la mot
# duong internet truc tiep, dung cai ma thiet ke noi la khong co.
#
# MOT stack instance moi account, khong phai moi account x region:
# Lambda ben trong tu quet cac region trong sweep_regions. Lam theo
# region thi so stack instance nhan len va khong duoc gi.
########################################

locals {
  # Ham Lambda de INLINE trong template.
  #
  # CloudFormation gioi han ZipFile o 4096 ky tu, va tu cung cap
  # module cfnresponse cho ham inline - nen khong phai dong goi zip
  # rieng, va cung khong can S3 trung gian.
  sweep_code = <<-PY
    import boto3, cfnresponse

    def handler(event, ctx):
        out = []
        try:
            if event['RequestType'] != 'Delete':
                for r in event['ResourceProperties']['Regions']:
                    # Bat loi TUNG REGION. region_lock SCP tu choi moi
                    # hanh dong ngoai allowed_regions, va mot region bi
                    # chan khong duoc lam hong ca stack.
                    try:
                        ec2 = boto3.client('ec2', region_name=r)
                        f = [{'Name': 'isDefault', 'Values': ['true']}]
                        for v in ec2.describe_vpcs(Filters=f)['Vpcs']:
                            vid = v['VpcId']
                            gf = [{'Name': 'attachment.vpc-id', 'Values': [vid]}]
                            for g in ec2.describe_internet_gateways(Filters=gf)['InternetGateways']:
                                gid = g['InternetGatewayId']
                                ec2.detach_internet_gateway(InternetGatewayId=gid, VpcId=vid)
                                ec2.delete_internet_gateway(InternetGatewayId=gid)
                            sf = [{'Name': 'vpc-id', 'Values': [vid]}]
                            for s in ec2.describe_subnets(Filters=sf)['Subnets']:
                                ec2.delete_subnet(SubnetId=s['SubnetId'])
                            ec2.delete_vpc(VpcId=vid)
                            out.append(r + '/' + vid)
                    except Exception as e:
                        # Ghi lai chu KHONG nuot. Xem trong stack output.
                        out.append(r + '/SKIP:' + type(e).__name__)
            cfnresponse.send(event, ctx, cfnresponse.SUCCESS,
                             {'Result': (', '.join(out) or 'khong co default VPC nao')[:900]})
        except Exception as e:
            print('FATAL', e)
            cfnresponse.send(event, ctx, cfnresponse.FAILED, {'Result': str(e)[:900]})
  PY

  sweep_template = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "LZ account baseline - xoa default VPC (config-detective/account-baseline)"

    Resources = {
      SweepRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName = "${var.project}-default-vpc-sweep"
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "lambda.amazonaws.com" }
              Action    = "sts:AssumeRole"
            }]
          }
          ManagedPolicyArns = [
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
          ]
          Policies = [{
            PolicyName = "DeleteDefaultVpc"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [{
                Effect = "Allow"
                # CHI Describe va Delete. Khong co Create nao - ham nay
                # khong duoc phep dung them thu gi, va network_lock SCP
                # cung se chan neu no thu.
                Action = [
                  "ec2:DescribeVpcs",
                  "ec2:DescribeSubnets",
                  "ec2:DescribeInternetGateways",
                  "ec2:DetachInternetGateway",
                  "ec2:DeleteInternetGateway",
                  "ec2:DeleteSubnet",
                  "ec2:DeleteVpc",
                ]
                Resource = "*"
              }]
            }
          }]
        }
      }

      SweepFn = {
        Type      = "AWS::Lambda::Function"
        DependsOn = "SweepRole"
        Properties = {
          FunctionName = "${var.project}-default-vpc-sweep"
          Handler      = "index.handler"
          Runtime      = "python3.12"
          Timeout      = 300
          Role         = { "Fn::GetAtt" = ["SweepRole", "Arn"] }
          Code         = { ZipFile = local.sweep_code }
        }
      }

      # Custom resource CHI chay lai khi thuoc tinh doi - do la ly do
      # co Version. Khong co no thi them region vao sweep_regions cung
      # khong lam gi ca.
      Sweep = {
        Type      = "AWS::CloudFormation::CustomResource"
        DependsOn = "SweepFn"
        Properties = {
          ServiceToken = { "Fn::GetAtt" = ["SweepFn", "Arn"] }
          Regions      = var.sweep_regions
          Version      = var.sweep_version
        }
      }
    }

    Outputs = {
      SweepResult = {
        Description = "Default VPC da xoa, hoac SKIP kem ly do"
        Value       = { "Fn::GetAtt" = ["Sweep", "Result"] }
      }
    }
  })
}

resource "aws_cloudformation_stack_set" "baseline" {
  count = local.enabled ? 1 : 0

  name        = "${var.project}-account-baseline"
  description = "Xoa default VPC o moi account trong OU dich"

  permission_model = "SERVICE_MANAGED"

  auto_deployment {
    enabled = true

    # Account roi khoi OU thi go stack. Khong giu lai gi - stack nay
    # khong tao ra resource ton tai lau dai, chi co role va Lambda.
    retain_stacks_on_account_removal = false
  }

  capabilities  = ["CAPABILITY_NAMED_IAM"]
  template_body = local.sweep_template

  operation_preferences {
    failure_tolerance_percentage = 10
    max_concurrent_percentage    = 25
    region_concurrency_type      = "PARALLEL"
  }

  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

resource "aws_cloudformation_stack_set_instance" "baseline" {
  count = local.enabled && length(var.baseline_target_ous) > 0 ? 1 : 0

  stack_set_name = aws_cloudformation_stack_set.baseline[0].name

  deployment_targets {
    organizational_unit_ids = var.baseline_target_ous
  }

  # Provider v5 dung "region"; v6 doi thanh "stack_set_instance_region"
  # vi v6 them meta-argument "region" cho moi resource.
  region = var.region

  operation_preferences {
    failure_tolerance_percentage = 10
    max_concurrent_percentage    = 25
  }

  # Trien khai tuan tu xuong tung account nen cham. 30 phut mac dinh
  # cua provider khong du cho to chuc vai chuc account, va vuot timeout
  # thi Terraform danh dau TAINTED mot thu dang chay binh thuong.
  timeouts {
    create = "90m"
    update = "90m"
    delete = "90m"
  }
}

########################################
# KIEM TRA CHEO
########################################

check "baseline_targets_declared" {
  assert {
    condition     = !local.enabled || length(var.baseline_target_ous) > 0
    error_message = "enable = true nhung baseline_target_ous rong - StackSet duoc tao ma khong trien khai di dau. Lay OU ID: cd ../organization && terraform output ou_ids"
  }
}

check "sweep_regions_include_home" {
  assert {
    condition     = !local.enabled || contains(var.sweep_regions, var.region)
    error_message = "sweep_regions khong chua ${var.region} - region dat StackSet ma khong duoc quet la gan nhu chac chan sot."
  }
}
