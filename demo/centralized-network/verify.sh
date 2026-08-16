#!/usr/bin/env bash
#
# Kiem chung mo hinh network tap trung.
# Chay sau khi terraform apply xong.
#
set -uo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"
PROJECT="${PROJECT:-lz-net-demo}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
info() { printf '  ....  %s\n' "$1"; }

FAILED=0

echo
echo "=== 1. Spoke VPC khong duoc co Internet Gateway ==="

for vpc_id in $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-app-*-vpc" \
  --query 'Vpcs[].VpcId' --output text); do

  name=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$vpc_id" \
    --query 'Vpcs[0].Tags[?Key==`Name`].Value' --output text)

  igw=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$vpc_id" \
    --query 'InternetGateways[].InternetGatewayId' --output text)

  if [[ -z "$igw" ]]; then
    pass "$name khong co IGW"
  else
    fail "$name CO IGW: $igw"
  fi

  nat=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available" \
    --query 'NatGateways[].NatGatewayId' --output text)

  if [[ -z "$nat" ]]; then
    pass "$name khong co NAT Gateway"
  else
    fail "$name CO NAT: $nat"
  fi
done

echo
echo "=== 2. Route mac dinh cua spoke phai tro Transit Gateway ==="

for rt in $(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-app-*-private-rt" \
  --query 'RouteTables[].RouteTableId' --output text); do

  target=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].TransitGatewayId' \
    --output text)

  igw_target=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
    --output text)

  if [[ -n "$target" && "$target" != "None" ]]; then
    pass "$rt: 0.0.0.0/0 -> $target"
  else
    fail "$rt: 0.0.0.0/0 khong tro TGW (dang tro: ${igw_target:-khong co})"
  fi
done

echo
echo "=== 3. Duong VE trong egress VPC (loi hay gap nhat) ==="

egress_rt=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-egress-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)

back_route=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$egress_rt" \
  --query 'RouteTables[0].Routes[?TransitGatewayId!=null].DestinationCidrBlock' --output text)

if [[ -n "$back_route" && "$back_route" != "None" ]]; then
  pass "Public subnet co duong ve spoke: $back_route -> TGW"
else
  fail "THIEU duong ve! Spoke se ra duoc Internet nhung khong nhan duoc goi tra loi."
fi

echo
echo "=== 4. TGW route table - cach ly spoke-to-spoke ==="

tgw_id=$(aws ec2 describe-transit-gateways --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-tgw" "Name=state,Values=available" \
  --query 'TransitGateways[0].TransitGatewayId' --output text)

spokes_rtb=$(aws ec2 describe-transit-gateway-route-tables --region "$REGION" \
  --filters "Name=transit-gateway-id,Values=$tgw_id" "Name=tag:Name,Values=${PROJECT}-rtb-spokes" \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)

info "rtb-spokes = $spokes_rtb"

routes=$(aws ec2 search-transit-gateway-routes --region "$REGION" \
  --transit-gateway-route-table-id "$spokes_rtb" \
  --filters "Name=state,Values=active" \
  --query 'Routes[].DestinationCidrBlock' --output text)

info "Route trong rtb-spokes: $routes"

if [[ "$routes" == *"0.0.0.0/0"* ]]; then
  pass "Co default route ra egress VPC"
else
  fail "Thieu default route 0.0.0.0/0"
fi

spoke_cidr_count=$(echo "$routes" | tr '\t' '\n' | grep -c '^10\.[12]0\.' || true)
if [[ "$spoke_cidr_count" -eq 0 ]]; then
  pass "Khong co route spoke-to-spoke (cach ly dung)"
else
  info "Co $spoke_cidr_count route toi spoke khac - kiem tra lai neu muon cach ly"
fi

echo
echo "=== 5. Gateway endpoint (mien phi) ==="

gw_count=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=vpc-endpoint-type,Values=Gateway" "Name=tag:Ephemeral,Values=true" \
  --query 'length(VpcEndpoints)' --output text)

if [[ "$gw_count" -gt 0 ]]; then
  pass "Co $gw_count gateway endpoint (S3/DynamoDB)"
else
  fail "Khong tim thay gateway endpoint"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf '\033[32mTAT CA KIEM TRA DAT.\033[0m\n\n'
else
  printf '\033[31mCO KIEM TRA THAT BAI - xem o tren.\033[0m\n\n'
fi

echo "Nho chay: terraform destroy -auto-approve"
echo

exit "$FAILED"
