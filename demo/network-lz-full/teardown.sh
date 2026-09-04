#!/usr/bin/env bash
#
# Xoa sach demo va XAC NHAN khong con gi tinh tien.
#
set -uo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"

########################################
# CHAN: bo nay co dang duoc dung lam ha tang thuong tru khong
#
# ephemeral = false nghia la ai do da giu bo demo nay lai lam mang
# that. Luc do script nay khong con la "don dep sau khi xem" ma la
# "xoa mang dang chay".
#
# Doc tu state chu khong tu tfvars: tfvars co the da bi sua sau lan
# apply cuoi, state thi phan anh cai dang chay that.
########################################
EPHEMERAL=$(terraform output -raw ephemeral 2>/dev/null || echo "unknown")

if [[ "$EPHEMERAL" == "false" ]]; then
  echo "════════════════════════════════════════════"
  echo " DUNG LAI"
  echo "════════════════════════════════════════════"
  echo
  echo "Bo nay dang chay voi ephemeral = false, tuc no KHONG phai"
  echo "demo nua ma la ha tang thuong tru:"
  echo
  echo "  - resource khong mang tag Ephemeral"
  echo "  - firewall bat delete_protection"
  echo "  - bucket khong co force_destroy"
  echo
  echo "Script nay se khong chay. Muon xoa that thi lam co y thuc:"
  echo
  echo "  1. Doi ephemeral = true trong terraform.tfvars"
  echo "  2. terraform apply        # go bao ve, RIENG mot lan"
  echo "  3. Chay lai ./teardown.sh"
  echo
  exit 1
fi

########################################
# CHAN: lop van hanh (ops/) con dinh vao day khong
#
# ops/ tao mot Network Firewall rule group ma POLICY o layer nay tham
# chieu qua ARN. Thu tu xoa phai nguoc voi thu tu dung:
#
#   dung : ops apply -> cam ARN vao day -> apply o day
#   xoa  : go ARN khoi day -> apply o day -> ops destroy
#
# Lam sai thu tu thi destroy o day co the bi tu choi vi rule group
# dang duoc tham chieu, hoac te hon: destroy chay tron va de lai mot
# rule group mo coi khong ai quan.
#
# KIEM BANG OUTPUT, KHONG BANG FILE STATE.
#
# Ban dau cho nay kiem su ton tai cua ops/terraform.tfstate. Sai ngay
# khi ops/ chuyen sang backend S3 - luc do KHONG co file state tren
# dia, nen phep kiem im lang cho qua dung truong hop no sinh ra de
# bat. Cung ho voi loi 73: mot phep kiem chay, bao xanh, va khong
# nhin vao cho can nhin.
#
# ops_rule_group_arns la SU RANG BUOC THAT giua hai lop. Doc no tu
# state cua chinh layer nay thi dung ke ca khi ops/ dung backend nao.
########################################
OPS_ARNS=$(terraform output -json ops_handles 2>/dev/null |
  jq -r '.firewall.ops_rule_group_arns // [] | length' 2>/dev/null || echo 0)

if [[ "${SKIP_OPS_CHECK:-0}" != "1" && "${OPS_ARNS:-0}" != "0" ]]; then
  echo "════════════════════════════════════════════"
  echo " LOP VAN HANH (ops/) VAN DANG DUOC THAM CHIEU"
  echo "════════════════════════════════════════════"
  echo
  echo "Firewall policy o layer nay dang tro toi $OPS_ARNS rule group do"
  echo "thu muc ops/ so huu. Xoa theo thu tu NGUOC voi luc dung:"
  echo
  echo "  1. Go dong ops_rule_group_arns khoi terraform.tfvars"
  echo "  2. terraform apply           # policy thoi tham chieu rule group"
  echo "  3. cd ops && terraform destroy && cd .."
  echo "  4. Chay lai ./teardown.sh"
  echo
  echo "Bo qua canh bao nay (rule group da xoa tay chang han):"
  echo "  SKIP_OPS_CHECK=1 ./teardown.sh"
  echo
  exit 1
fi

# Phong khi output khong doc duoc: van con dau vet cua ops/
if [[ "${SKIP_OPS_CHECK:-0}" != "1" && "${OPS_ARNS:-0}" == "0" ]]; then
  OPS_DIR="$(dirname "$0")/ops"
  if [[ -s "$OPS_DIR/terraform.tfstate" || -f "$OPS_DIR/backend.tf" ]]; then
    echo "Luu y: thu muc ops/ da duoc noi backend hoac con state."
    echo "Policy o layer nay khong con tham chieu rule group nao, nen"
    echo "destroy o day chay duoc. Nhung rule group ben ops/ VAN CON:"
    echo
    echo "  cd ops && terraform destroy"
    echo
    echo "Khong chan - chi nhac. Rule group khong tinh tien theo gio."
    echo
  fi
fi

########################################
# CHAN CHAY NHAM ACCOUNT
#
# O day nguy hiem hon verify.sh: script nay goi `terraform destroy`.
# Chay bang credential cua account khac thi destroy khong xoa duoc
# nhung gi trong state, va phan xac nhan ben duoi se bao "DA SACH"
# - vi no dang hoi mot account khong co gi de mat.
#
# Ket qua: ban tin la da xoa xong, trong khi ~$30/ngay van chay.
########################################
EXPECT_ACCOUNT=$(terraform output -raw account_id 2>/dev/null || echo "")
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

if [[ -n "$EXPECT_ACCOUNT" && -n "$ACTUAL_ACCOUNT" && "$EXPECT_ACCOUNT" != "$ACTUAL_ACCOUNT" ]]; then
  echo "════════════════════════════════════════════"
  echo " SAI ACCOUNT - dung lai"
  echo "════════════════════════════════════════════"
  echo
  echo "  Ha tang nay o account : $EXPECT_ACCOUNT"
  echo "  Credential dang dung  : $ACTUAL_ACCOUNT"
  echo
  echo "destroy se khong xoa duoc gi, va phan xac nhan se bao DA SACH"
  echo "cho mot ha tang van dang chay va van dang tinh tien."
  echo
  echo "Doi credential ve account $EXPECT_ACCOUNT roi chay lai."
  exit 1
fi

########################################
# ATTACHMENT MA TERRAFORM KHONG QUAN LY
#
# KHONG XOA DUOC TRANSIT GATEWAY khi con attachment. Attachment do
# StackSet tao thi terraform destroy go duoc - no xoa stack instance.
# Nhung attachment cua spoke khai manual_vpc = true thi KHONG: VPC do
# duoc dung bang stack thuong chay o account kia, ngoai tam voi cua
# state nay.
#
# Gap phai thi destroy chay ~15 phut roi chet o aws_ec2_transit_gateway
# voi mot cau ve dependency - dung luc ban tuong sap xong.
########################################
TGW_ID=$(terraform output -raw transit_gateway_id 2>/dev/null || echo "")
PROJECT=$(terraform output -raw project 2>/dev/null || echo "<project>")

if [[ -n "$TGW_ID" ]]; then
  foreign=$(aws ec2 describe-transit-gateway-attachments --region "$REGION" \
    --filters "Name=transit-gateway-id,Values=$TGW_ID" \
              "Name=resource-type,Values=vpc" \
              "Name=state,Values=available" \
    --query "TransitGatewayAttachments[?ResourceOwnerId!='$ACTUAL_ACCOUNT'].[TransitGatewayAttachmentId,ResourceOwnerId]" \
    --output text 2>/dev/null)

  # Attachment cua StackSet cung hien o day, va chung KHONG phai van de
  # - destroy go duoc. Nen day la CANH BAO de doc, khong phai cong chan.
  if [[ -n "$foreign" ]]; then
    echo
    echo "  Attachment thuoc account khac dang gan vao $TGW_ID:"
    echo "$foreign" | sed 's/^/      /'
    echo
    echo "  Cai nao do StackSet tao thi destroy tu go. Cai nao do stack"
    echo "  THUONG tao (spoke khai manual_vpc = true) thi PHAI xoa truoc,"
    echo "  tu chinh account do:"
    echo "      aws cloudformation delete-stack --stack-name ${PROJECT}-spoke-vpc"
    echo
    echo "  Con sot lai thi destroy se chet o buoc xoa Transit Gateway."
  fi
fi

echo "════════════════════════════════════════════"
echo " Teardown demo network LZ"
echo "════════════════════════════════════════════"
echo
echo "Se xoa toan bo resource cua demo trong region $REGION."
read -r -p "Go 'yes' de tiep tuc: " ans
[[ "$ans" == "yes" ]] || { echo "Da huy."; exit 0; }

HAS_CDN=$(terraform output -raw cloudfront_domain 2>/dev/null || echo "")

echo
if [[ -n "$HAS_CDN" ]]; then
  echo "── terraform destroy (mat ~25-35 phut) ──"
  echo "   CloudFront phai DISABLE truoc roi moi DELETE duoc:"
  echo "     disable ~15 phut, delete ~5 phut. Terraform tu lam ca hai."
  echo "   Cong them: NAT ~2 phut, TGW attachment ~3-5 phut moi cai,"
  echo "   Network Firewall ~5 phut."
  echo
  echo "   Cu de no chay, dung Ctrl-C giua chung."
else
  echo "── terraform destroy (mat ~10-15 phut) ──"
  echo "   NAT Gateway ~2 phut, TGW attachment ~3-5 phut moi cai,"
  echo "   Network Firewall ~5 phut."
fi
echo

terraform destroy -auto-approve
rc=$?

if [[ $rc -ne 0 ]]; then
  echo
  echo "⚠  Destroy loi. Nguyen nhan thuong gap chi la timing —"
  echo "   ENI cua firewall/endpoint chua giai phong xong."
  echo "   Doi 2 phut roi chay lai: terraform destroy -auto-approve"
  echo
fi

echo
echo "── Xac nhan da sach ──"
echo

leftover=0

check() {
  local label="$1" result="$2"
  if [[ -z "$result" || "$result" == "None" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$label"
  else
    printf '  \033[31m✗\033[0m %s: %s\n' "$label" "$result"
    leftover=$((leftover+1))
  fi
}

check "NAT Gateway" "$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId' --output text)"

# EIP khong gan vao dau van tinh ~$3.6/thang - khoan de quen nhat
check "Elastic IP" "$(aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[].AllocationId' --output text)"

check "Network Firewall" "$(aws network-firewall list-firewalls --region "$REGION" \
  --query 'Firewalls[].FirewallName' --output text 2>/dev/null)"

check "Transit Gateway" "$(aws ec2 describe-transit-gateways --region "$REGION" \
  --filters "Name=state,Values=available,pending,modifying" \
  --query 'TransitGateways[].TransitGatewayId' --output text)"

check "Interface endpoint" "$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text)"

check "Load balancer" "$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"

check "CloudFront distribution" "$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment!=null]|[?contains(Comment, 'lz-net')].Id" \
  --output text 2>/dev/null)"

# WAF cho CloudFront nam o us-east-1, khong phai region cua ban
check "WAF Web ACL (us-east-1)" "$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --query 'WebACLs[].Name' --output text 2>/dev/null)"

check "EC2 dang chay" "$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Ephemeral,Values=true" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"

########################################
# SPOKE O ACCOUNT KHAC
#
# Muoi cau kiem o tren deu hoi ACCOUNT NAY. VPC cua spoke remote nam o
# account khac, do StackSet tao, va mang tag Name chu khong mang tag
# Ephemeral - nen ca cau kiem lan lenh quet theo tag deu khong thay no.
#
# terraform destroy CO xoa chung (xoa stack instance -> CloudFormation
# xoa stack o account dich). Van de la khi viec do hong giua chung:
# script se in "DA SACH" cho mot thu no chua bao gio nhin thay.
#
# list-stack-instances thi hoi duoc tu day, vi account nay la delegated
# administrator cua StackSets.
########################################
PROJECT=$(terraform output -raw project 2>/dev/null || echo "")

if [[ -n "$PROJECT" ]]; then
  instances=$(aws cloudformation list-stack-instances \
    --region "$REGION" \
    --stack-set-name "${PROJECT}-spoke-vpc" \
    --call-as DELEGATED_ADMIN \
    --query 'Summaries[].[Account,Status]' --output text 2>/dev/null)

  # Loi o day KHONG phai that bai: stack set da xoa xong thi
  # ValidationError la ket qua dung. Chi CON instance moi la van de.
  check "Stack instance o account spoke" "$instances"
fi

echo
echo "── Quet theo tag Ephemeral=true ──"

# LUOI VOT, KHONG PHAI PHEP DO CHINH XAC.
#
# resourcegroupstaggingapi TRA VE CA RESOURCE DA XOA, trong mot khoang
# thoi gian sau do. TGW da xoa van o trang thai 'deleted', EC2 o
# 'terminated', NAT o 'deleted' - khong con tinh tien, nhung van con tag
# nen van hien ra day.
#
# Muoi phep kiem o tren loc theo TRANG THAI DANG HOAT DONG nen khong
# thay chung. Khi muoi cai deu xanh ma lenh nay van liet ke, thi cai
# sai la lenh nay.
#
# Da xay ra that: 143 resource destroyed, muoi muc xanh, va lenh nay
# liet ke 19 ARN - trong do co dung nhung thu vua duoc bao la da sach.
# Bao do la "CON 1 muc chua xoa" khien mot lan don dep sach bi doc
# thanh mot lan that bai.
#
# Nen: khi muoi phep kiem deu xanh, day chi la thong tin can XAC NHAN,
# khong phai loi. Khi da co phep kiem hong, no la manh moi tim tiep.
remaining=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=Ephemeral,Values=true" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)

if [[ -z "$remaining" ]]; then
  printf '  \033[32m✓\033[0m Khong con resource nao gan tag Ephemeral\n'
elif [[ $leftover -eq 0 ]]; then
  n=$(echo "$remaining" | tr '\t' '\n' | grep -c .)
  printf '  \033[33m-\033[0m %d ARN con tag, nhung muoi phep kiem o tren deu sach\n' "$n"
  echo "      API tag tra ve ca resource DA XOA trong mot luc. Nhieu kha"
  echo "      nang day la do tre, khong phai con song. Xac nhan:"
  echo
  echo "$remaining" | tr '\t' '\n' | sed 's/^/      /'
  echo
  echo "      aws ec2 describe-transit-gateways --region $REGION \\"
  echo "        --transit-gateway-ids <tgw-id> --query 'TransitGateways[].State'"
  echo "      -> 'deleted' la da xoa that. Con 'available' thi moi la van de."
else
  printf '  \033[31m✗\033[0m Con lai:\n'
  echo "$remaining" | tr '\t' '\n' | sed 's/^/      /'
  leftover=$((leftover+1))
fi

echo
echo "════════════════════════════════════════════"
if [[ $leftover -eq 0 ]]; then
  printf ' \033[32mDA SACH. Khong con gi phat sinh chi phi.\033[0m\n'
else
  printf ' \033[31mCON %d muc chua xoa — kiem tra o tren.\033[0m\n' "$leftover"
  echo ' Chay lai: terraform destroy -auto-approve'
fi
echo "════════════════════════════════════════════"
echo
echo "Van con (va la dieu mong muon): AWS account, IAM user cua ban."
echo

exit $leftover
