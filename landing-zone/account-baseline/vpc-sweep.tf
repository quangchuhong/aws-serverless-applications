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
  # Ham Lambda de INLINE trong template (gioi han 4096 ky tu).
  #
  # ---------------------------------------------------------------
  # KHONG DUNG `import cfnresponse`.
  #
  # Vi du cua AWS dung module do, va no CO san voi mot so runtime.
  # Voi python3.12 thi KHONG:
  #
  #   Runtime.ImportModuleError: Unable to import module 'index':
  #   No module named 'cfnresponse'
  #
  # Va hong o day la hong theo kieu te nhat: Lambda chet ngay luc
  # KHOI TAO, truoc khi vao try, nen khong nhanh nao gui duoc phan
  # hoi. CloudFormation ngoi cho HET MOT GIO roi moi bo cuoc - stack
  # treo CREATE_IN_PROGRESS, va cac account con lai xep hang PENDING
  # dang sau.
  #
  # Tu gui phan hoi bang urllib thi khong phu thuoc module nao ngoai
  # thu vien chuan. Dai them 12 dong, doi lai khong co gi de thieu.
  # ---------------------------------------------------------------
  sweep_code = <<-PY
    import json, urllib.request, boto3

    def send(event, ctx, status, data):
        body = json.dumps({
            'Status': status,
            'Reason': 'Xem CloudWatch log: ' + ctx.log_stream_name,
            'PhysicalResourceId': ctx.log_stream_name,
            'StackId': event['StackId'],
            'RequestId': event['RequestId'],
            'LogicalResourceId': event['LogicalResourceId'],
            'Data': data,
        }).encode()
        req = urllib.request.Request(
            event['ResponseURL'], data=body, method='PUT',
            headers={'content-type': '', 'content-length': str(len(body))})
        urllib.request.urlopen(req)

    def harden_account(h, acct, out):
        # Hai muc nay la CAP ACCOUNT, khong theo region. Goi mot lan.
        if h.get('PasswordPolicy') == 'yes':
            try:
                boto3.client('iam').update_account_password_policy(
                    MinimumPasswordLength=int(h['MinPasswordLength']),
                    RequireSymbols=True, RequireNumbers=True,
                    RequireUppercaseCharacters=True,
                    RequireLowercaseCharacters=True,
                    AllowUsersToChangePassword=True,
                    MaxPasswordAge=int(h['MaxPasswordAge']),
                    PasswordReusePrevention=int(h['PasswordReuse']))
                out.append('iam/password-policy')
            except Exception as e:
                out.append('iam/password-policy:SKIP:' + type(e).__name__)

        if h.get('S3PublicAccessBlock') == 'yes':
            try:
                boto3.client('s3control').put_public_access_block(
                    AccountId=acct,
                    PublicAccessBlockConfiguration={
                        'BlockPublicAcls': True, 'IgnorePublicAcls': True,
                        'BlockPublicPolicy': True, 'RestrictPublicBuckets': True})
                out.append('s3/public-access-block')
            except Exception as e:
                out.append('s3/pab:SKIP:' + type(e).__name__)

    def harden_region(h, ec2, r, out):
        # Hai muc nay theo TUNG REGION. Bo sot mot region la de lai
        # dung cai lo hong dang bit o cac region khac.
        if h.get('EbsEncryption') == 'yes':
            try:
                ec2.enable_ebs_encryption_by_default()
                out.append(r + '/ebs-encryption')
            except Exception as e:
                out.append(r + '/ebs:SKIP:' + type(e).__name__)

        if h.get('LockDefaultSg') == 'yes':
            # Default security group KHONG XOA DUOC. No luon ton tai va
            # mac dinh cho phep moi luu luong giua cac ENI dung chung no
            # - tuc mot mang phang an trong moi VPC, ke ca VPC do minh
            # tu tao. Cach duy nhat la go sach rule cua no.
            try:
                f = [{'Name': 'group-name', 'Values': ['default']}]
                for g in ec2.describe_security_groups(Filters=f)['SecurityGroups']:
                    gid = g['GroupId']
                    if g.get('IpPermissions'):
                        ec2.revoke_security_group_ingress(
                            GroupId=gid, IpPermissions=g['IpPermissions'])
                    if g.get('IpPermissionsEgress'):
                        ec2.revoke_security_group_egress(
                            GroupId=gid, IpPermissions=g['IpPermissionsEgress'])
                    out.append(r + '/default-sg:' + gid)
            except Exception as e:
                out.append(r + '/default-sg:SKIP:' + type(e).__name__)

    def handler(event, ctx):
        out = []
        try:
            if event['RequestType'] != 'Delete':
                props = event['ResourceProperties']
                h = props.get('Harden') or {}
                # Account ID lay tu ARN cua chinh ham - khong can quyen
                # sts:GetCallerIdentity cho mot thu da nam san trong ctx.
                acct = ctx.invoked_function_arn.split(':')[4]
                harden_account(h, acct, out)

                for r in props['Regions']:
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

                    # try RIENG, khong dung chung voi khoi xoa VPC o
                    # tren. Mot default VPC khong xoa duoc - con ENI
                    # gan vao chang han - se nem loi, va neu hai viec
                    # dung chung mot try thi hardening cua CA REGION do
                    # bi bo qua vi mot ly do khong lien quan gi toi no.
                    try:
                        harden_region(h, boto3.client('ec2', region_name=r), r, out)
                    except Exception as e:
                        out.append(r + '/harden:SKIP:' + type(e).__name__)
            send(event, ctx, 'SUCCESS',
                 {'Result': (', '.join(out) or 'khong co default VPC nao')[:900]})
        except Exception as e:
            print('FATAL', repr(e))
            # Gui FAILED cung phai bao ve: khong gui duoc thi
            # CloudFormation treo mot gio.
            try:
                send(event, ctx, 'FAILED', {'Result': repr(e)[:900]})
            except Exception as e2:
                print('KHONG GUI DUOC PHAN HOI', repr(e2))
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
                Action = concat([
                  "ec2:DescribeVpcs",
                  "ec2:DescribeSubnets",
                  "ec2:DescribeInternetGateways",
                  "ec2:DetachInternetGateway",
                  "ec2:DeleteInternetGateway",
                  "ec2:DeleteSubnet",
                  "ec2:DeleteVpc",
                  ],
                  # Quyen hardening chi cap khi thuc su bat. Bat mot
                  # muc rieng le thi role khong nhan quyen cua ba muc
                  # con lai - va no khong the lam nhung viec do ke ca
                  # khi ai do sua code Lambda.
                  var.harden_password_policy ? [
                    "iam:GetAccountPasswordPolicy",
                    "iam:UpdateAccountPasswordPolicy",
                  ] : [],
                  var.harden_s3_public_access_block ? [
                    "s3:GetAccountPublicAccessBlock",
                    "s3:PutAccountPublicAccessBlock",
                  ] : [],
                  var.harden_ebs_encryption ? [
                    "ec2:GetEbsEncryptionByDefault",
                    "ec2:EnableEbsEncryptionByDefault",
                  ] : [],
                  var.harden_default_security_group ? [
                    "ec2:DescribeSecurityGroups",
                    "ec2:RevokeSecurityGroupIngress",
                    "ec2:RevokeSecurityGroupEgress",
                  ] : [],
                )
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

          # Cau hinh nam TRONG thuoc tinh custom resource, khong phai
          # trong code Lambda: CloudFormation chi goi lai ham khi
          # THUOC TINH doi. Doi mot bien hardening ma khong doi thuoc
          # tinh nao thi stack khong lam gi ca - va do la kieu hong im
          # lang, cung ho voi Version o tren.
          Harden = {
            PasswordPolicy      = var.harden_password_policy ? "yes" : "no"
            S3PublicAccessBlock = var.harden_s3_public_access_block ? "yes" : "no"
            EbsEncryption       = var.harden_ebs_encryption ? "yes" : "no"
            LockDefaultSg       = var.harden_default_security_group ? "yes" : "no"
            MinPasswordLength   = tostring(var.password_min_length)
            MaxPasswordAge      = tostring(var.password_max_age_days)
            PasswordReuse       = tostring(var.password_reuse_prevention)
          }
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
  description = "Baseline moi account: xoa default VPC + hardening cap account"

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
