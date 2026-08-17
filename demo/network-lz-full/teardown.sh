#!/usr/bin/env bash
#
# Xoa sach demo va XAC NHAN khong con gi tinh tien.
#
set -uo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"

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

echo
echo "── Quet theo tag Ephemeral=true ──"
remaining=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=Ephemeral,Values=true" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)

if [[ -z "$remaining" ]]; then
  printf '  \033[32m✓\033[0m Khong con resource nao gan tag Ephemeral\n'
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
