#!/usr/bin/env bash
#
# Kiem chung thiet ke network LZ theo doc 17 muc 8.
# Chay sau khi terraform apply xong (doi ~2 phut cho EC2 boot xong).
#
set -uo pipefail

REGION="${AWS_REGION:-$(terraform output -raw region 2>/dev/null || echo ap-southeast-1)}"
PROJECT="${PROJECT:-lz-net}"

PASS=0; FAIL=0; SKIP=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m-\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

tfout() { terraform output -raw "$1" 2>/dev/null || echo ""; }

FW_ENABLED=$([[ -n "$(tfout security_vpc_id)" ]] && echo yes || echo no)

echo "════════════════════════════════════════════"
echo " Kiem chung network LZ  (firewall: $FW_ENABLED)"
echo "════════════════════════════════════════════"

########################################
hdr "1. Spoke khong co duong ra Internet rieng"
########################################

for vpc in $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-app-*-vpc" \
  --query 'Vpcs[].VpcId' --output text); do

  name=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$vpc" \
    --query 'Vpcs[0].Tags[?Key==`Name`]|[0].Value' --output text)

  igw=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query 'InternetGateways[].InternetGatewayId' --output text)
  [[ -z "$igw" ]] && ok "$name khong co IGW" || bad "$name CO IGW: $igw"

  nat=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=available" \
    --query 'NatGateways[].NatGatewayId' --output text)
  [[ -z "$nat" ]] && ok "$name khong co NAT" || bad "$name CO NAT: $nat"
done

########################################
hdr "2. Route mac dinh cua spoke tro Transit Gateway"
########################################

for rt in $(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-app-*-private-rt" \
  --query 'RouteTables[].RouteTableId' --output text); do

  tgw=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].TransitGatewayId|[0]' --output text)

  [[ "$tgw" != "None" && -n "$tgw" ]] \
    && ok "$rt: 0.0.0.0/0 → $tgw" \
    || bad "$rt: 0.0.0.0/0 KHONG tro TGW"
done

########################################
hdr "3. Duong VE trong egress VPC (loi hay gap nhat)"
########################################

egress_rt=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-egress-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)

back=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$egress_rt" \
  --query 'RouteTables[0].Routes[?TransitGatewayId!=null].DestinationCidrBlock|[0]' --output text)

[[ "$back" != "None" && -n "$back" ]] \
  && ok "Public subnet co duong ve: $back → TGW" \
  || bad "THIEU duong ve! Spoke ra duoc Internet nhung khong nhan duoc goi tra loi"

########################################
hdr "4. Security VPC va Network Firewall"
########################################

if [[ "$FW_ENABLED" == "yes" ]]; then
  SEC_VPC=$(tfout security_vpc_id)

  am=$(aws ec2 describe-transit-gateway-vpc-attachments --region "$REGION" \
    --filters "Name=vpc-id,Values=$SEC_VPC" "Name=state,Values=available" \
    --query 'TransitGatewayVpcAttachments[0].Options.ApplianceModeSupport' --output text)
  [[ "$am" == "enable" ]] \
    && ok "appliance_mode_support = enable" \
    || bad "appliance_mode_support = $am (PHAI la enable)"

  st=$(aws network-firewall describe-firewall --region "$REGION" \
    --firewall-name "${PROJECT}-fw" \
    --query 'FirewallStatus.Status' --output text 2>/dev/null)
  [[ "$st" == "READY" ]] && ok "Firewall READY" || bad "Firewall status = $st"

  # Security VPC khong duoc co IGW/NAT - no chi la tram trung chuyen
  igw=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$SEC_VPC" \
    --query 'InternetGateways[].InternetGatewayId' --output text)
  [[ -z "$igw" ]] && ok "Security VPC khong co IGW" || bad "Security VPC CO IGW"
else
  skip "Firewall tat (enable_firewall = false)"
fi

########################################
hdr "5. TGW route table - tim duong lot firewall"
########################################

TGW=$(tfout transit_gateway_id)

if [[ "$FW_ENABLED" == "yes" ]]; then
  SEC_ATT=$(aws ec2 describe-transit-gateway-attachments --region "$REGION" \
    --filters "Name=tag:Name,Values=${PROJECT}-tgwa-security" "Name=state,Values=available" \
    --query 'TransitGatewayAttachments[0].TransitGatewayAttachmentId' --output text)

  for n in rtb-spokes rtb-egress rtb-ingress; do
    RTB=$(aws ec2 describe-transit-gateway-route-tables --region "$REGION" \
      --filters "Name=transit-gateway-id,Values=$TGW" "Name=tag:Name,Values=${PROJECT}-${n}" \
      --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)
    [[ "$RTB" == "None" || -z "$RTB" ]] && { skip "$n khong ton tai"; continue; }

    bypass=0
    while read -r cidr att; do
      [[ -z "$cidr" ]] && continue
      [[ "$att" != "$SEC_ATT" ]] && { bad "$n: $cidr → $att (LOT FIREWALL)"; bypass=1; }
    done < <(aws ec2 search-transit-gateway-routes --region "$REGION" \
      --transit-gateway-route-table-id "$RTB" \
      --filters "Name=state,Values=active" \
      --query 'Routes[].[DestinationCidrBlock,TransitGatewayAttachments[0].TransitGatewayAttachmentId]' \
      --output text)

    [[ $bypass -eq 0 ]] && ok "$n: moi route deu qua security VPC"
  done

  # rtb-security PHAI co route tinh ve ingress, khong chi 0.0.0.0/0
  RTB_SEC=$(aws ec2 describe-transit-gateway-route-tables --region "$REGION" \
    --filters "Name=transit-gateway-id,Values=$TGW" "Name=tag:Name,Values=${PROJECT}-rtb-security" \
    --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)

  routes=$(aws ec2 search-transit-gateway-routes --region "$REGION" \
    --transit-gateway-route-table-id "$RTB_SEC" \
    --filters "Name=state,Values=active" \
    --query 'Routes[].DestinationCidrBlock' --output text)

  if [[ -n "$(tfout nlb_dns_name)" ]]; then
    [[ "$routes" == *"10.0.0.0/16"* ]] \
      && ok "rtb-security co route tinh ve ingress VPC" \
      || bad "rtb-security THIEU route ve ingress → goi tra loi se lac sang egress VPC"
  fi
else
  skip "Bo qua (firewall tat)"
fi

########################################
hdr "6. Gateway endpoint (mien phi) o moi spoke"
########################################

n=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=vpc-endpoint-type,Values=Gateway" "Name=tag:Ephemeral,Values=true" \
  --query 'length(VpcEndpoints)' --output text)
[[ "$n" -gt 0 ]] && ok "$n gateway endpoint (S3 + DynamoDB)" || bad "Khong tim thay gateway endpoint"

########################################
hdr "7. Luong thuc te (chay lenh tren EC2 qua SSM)"
########################################

run_remote() {
  local iid="$1" cmd="$2"
  local cid
  cid=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$iid" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$cmd\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null) || return 1

  for _ in $(seq 1 20); do
    sleep 3
    local s
    s=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cid" --instance-id "$iid" \
      --query 'Status' --output text 2>/dev/null)
    [[ "$s" == "Success" || "$s" == "Failed" ]] && break
  done

  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cid" --instance-id "$iid" \
    --query 'StandardOutputContent' --output text 2>/dev/null
}

INSTANCES=$(terraform output -json instances 2>/dev/null || echo '{}')
DEV_ID=$(echo "$INSTANCES" | jq -r '.["app-dev"].id // empty')
PROD_IP=$(echo "$INSTANCES" | jq -r '.["app-prod"].private_ip // empty')
NAT_IP=$(tfout nat_public_ip)

if [[ -z "$DEV_ID" ]]; then
  skip "Khong co EC2 test (enable_test_instances = false)"
else
  echo "  ... dang chay lenh tren $DEV_ID qua SSM (~1 phut)"

  out=$(run_remote "$DEV_ID" "curl -s --max-time 10 https://checkip.amazonaws.com")
  if [[ "$out" == *"$NAT_IP"* ]]; then
    ok "Egress ra Internet bang NAT cua egress VPC ($NAT_IP)"
  else
    bad "IP ra Internet = '$out', ky vong '$NAT_IP'"
  fi

  if [[ -n "$PROD_IP" ]]; then
    out=$(run_remote "$DEV_ID" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://$PROD_IP/ || echo TIMEOUT")
    if [[ "$out" == *"200"* ]]; then
      ok "East-west port 80 THONG (co rule firewall + SG cho phep)"
    else
      bad "East-west port 80 khong thong (ket qua: $out)"
    fi

    # Port 22: SG CHO PHEP nhung khong co rule firewall.
    # Firewall drop mode -> phai timeout. Alert mode -> van thong (dung nhu thiet ke).
    out=$(run_remote "$DEV_ID" "timeout 8 nc -zv $PROD_IP 22 2>&1 | tail -1 || echo TIMEOUT")
    if [[ "$FW_ENABLED" == "yes" && "$(terraform output -raw mode)" == *drop* ]]; then
      [[ "$out" == *"TIMEOUT"* || "$out" == *"timed out"* ]] \
        && ok "East-west port 22 BI CHAN boi firewall (SG van mo — dung nhu thiet ke)" \
        || bad "Port 22 van thong du khong co rule firewall: $out"
    else
      skip "Port 22: firewall dang o che do alert, chua chan (ket qua: $out)"
    fi
  fi
fi

########################################
hdr "8. Ingress qua NLB"
########################################

NLB=$(tfout nlb_dns_name)
if [[ -n "$NLB" ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$NLB/" || echo 000)
  [[ "$code" == "200" ]] \
    && ok "NLB → TGW → (firewall) → app: HTTP $code" \
    || bad "NLB tra ve $code (target group co the chua healthy, doi 1-2 phut roi chay lai)"
else
  skip "Ingress tat"
fi

########################################
echo
echo "════════════════════════════════════════════"
printf " \033[32m%d dat\033[0m  \033[31m%d loi\033[0m  \033[33m%d bo qua\033[0m\n" "$PASS" "$FAIL" "$SKIP"
echo "════════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && echo " Nho chay ./teardown.sh khi xong." || echo " Xem lai cac muc loi o tren."
echo

exit $(( FAIL > 0 ? 1 : 0 ))
