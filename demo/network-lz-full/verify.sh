#!/usr/bin/env bash
#
# Kiem chung thiet ke network LZ theo doc 17 muc 8.
# Chay sau khi terraform apply xong (doi ~2 phut cho EC2 boot xong).
#
set -uo pipefail

REGION="${AWS_REGION:-$(terraform output -raw region 2>/dev/null || echo ap-southeast-1)}"
# Lay tu terraform output, KHONG gan cung.
#
# LOI 48: ban dau dong nay la PROJECT="${PROJECT:-lz-net}". Ai dat
# var.project khac "lz-net" thi moi lenh loc theo tag Name deu tra ve
# None, va script bao ba loi ha tang khong co that:
#   "THIEU duong ve", "Firewall status = ", "rtb-spokes khong ton tai"
# trong khi muc 7 va 8 chung minh luu luong di duoc qua chinh nhung
# resource do.
PROJECT="${PROJECT:-$(terraform output -raw project 2>/dev/null)}"
if [[ -z "$PROJECT" ]]; then
  echo "Khong doc duoc 'terraform output project'."
  echo "Chay trong thu muc da apply, hoac dat PROJECT=<ten> truoc khi chay."
  exit 1
fi

########################################
# CHAN CHAY NHAM ACCOUNT
#
# Script doc STATE tu thu muc nay (luon dung), nhung goi AWS bang
# CREDENTIAL DANG CO TRONG SHELL (co the la account bat ky). Hai nguon
# do lech nhau la chuyen rat de xay ra: chi can vua chay mot lenh o
# account spoke roi quay lai day.
#
# Khi lech, moi lenh mo ta ha tang deu tra ve rong, va script bao
# TAM loi ha tang cho mot he thong dang chay hoan hao:
#   "THIEU duong ve", "Firewall status = ", "Khong tim thay gateway
#   endpoint", "IP ra Internet = ''"
#
# Doc y het mot su co lon. Cung ho voi loi 48 va 57: mot phep do dung,
# tra loi cho mot cau hoi khac.
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
  echo "Chay tiep se bao hang loat 'loi ha tang' khong co that:"
  echo "moi lenh se hoi account $ACTUAL_ACCOUNT ve nhung resource nam"
  echo "o account $EXPECT_ACCOUNT."
  echo
  echo "Doi credential ve account $EXPECT_ACCOUNT roi chay lai."
  exit 1
fi

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

# TEN SPOKE LAY TU OUTPUT, KHONG DOAN THEO QUY UOC - loi 62.
#
# Truoc day dong nay loc "${PROJECT}-app-*-vpc". Doi ten spoke thanh
# "probe" la vong lap khong khop gi, than vong lap khong chay, va muc
# 1 + 2 KHONG IN MOT DONG NAO - khong tich, khong cheo. Bang ket qua
# ngan di hai dong ma khong cho biet la da bo qua cai gi.
SPOKES=$(terraform output -json spoke_names 2>/dev/null | jq -r '.[]' 2>/dev/null)

if [[ -z "$SPOKES" ]]; then
  skip "Khong co spoke noi bo nao (moi spoke deu o account khac)"
fi

for sp in $SPOKES; do
  vpc=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${PROJECT}-${sp}-vpc" \
    --query 'Vpcs[0].VpcId' --output text)

  if [[ "$vpc" == "None" || -z "$vpc" ]]; then
    bad "Spoke '$sp' khai trong tfvars nhung KHONG tim thay VPC ${PROJECT}-${sp}-vpc"
    continue
  fi

  name="${PROJECT}-${sp}-vpc"

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

for sp in $SPOKES; do
  rt=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=tag:Name,Values=${PROJECT}-${sp}-private-rt" \
    --query 'RouteTables[0].RouteTableId' --output text)

  if [[ "$rt" == "None" || -z "$rt" ]]; then
    bad "Spoke '$sp' khong tim thay route table ${PROJECT}-${sp}-private-rt"
    continue
  fi

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
hdr "6b. Tag chi phi da gan day du chua"
########################################

# Cost allocation tag chi huu dung khi resource THUC SU mang tag do.
# Bat tag o billing-guard ma khong gan o day = khong co du lieu de group.
missing=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=Ephemeral,Values=true" \
  --query 'ResourceTagMappingList[?!(Tags[?Key==`CostCenter`])].ResourceARN' \
  --output text 2>/dev/null)

if [[ -z "$missing" ]]; then
  ok "Moi resource deu co tag CostCenter"
else
  cnt=$(echo "$missing" | tr '\t' '\n' | grep -c . || true)
  bad "$cnt resource THIEU tag CostCenter - se hien la 'No CostCenter' trong Cost Explorer"
  echo "$missing" | tr '\t' '\n' | head -5 | sed 's/^/      /'
fi

########################################
hdr "6c. Spoke o ACCOUNT KHAC da duoc noi vao route table chua"
#
# Muc 1-3 va muc 7 chi kiem spoke NOI BO. Mot spoke o account khac co
# the co attachment State=available ma khong thuoc route table nao -
# khong loi, khong canh bao, va khong mot goi tin nao di qua. Thieu
# muc nay thi bang ket qua bao "0 loi" cho mot mang chua thong.
#
# Khong doi chieu tag: tag tren resource chia se thuoc ve account da
# tao chung, nen chu so huu TGW co the khong thay tag do account spoke
# dat. Doi chieu theo ResourceOwnerId - thu luon nhin thay.
########################################

TGW_ID=$(tfout transit_gateway_id)
SELF=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

if [[ -z "$TGW_ID" || -z "$SELF" ]]; then
  skip "Khong lay duoc transit_gateway_id hoac account id"
else
  remote_atts=$(aws ec2 describe-transit-gateway-attachments --region "$REGION" \
    --filters "Name=transit-gateway-id,Values=$TGW_ID" \
              "Name=resource-type,Values=vpc" \
              "Name=state,Values=available" \
    --query "TransitGatewayAttachments[?ResourceOwnerId!='$SELF'].[TransitGatewayAttachmentId,ResourceOwnerId,Association.TransitGatewayRouteTableId]" \
    --output text 2>/dev/null)

  if [[ -z "$remote_atts" ]]; then
    skip "Khong co spoke o account khac"
  else
    # Route table lo DUONG VE: rtb-security khi bat firewall, rtb-egress
    # khi tat. Association va propagation la HAI viec khac nhau.
    RET_NAME=$([[ "$FW_ENABLED" == "yes" ]] && echo "rtb-security" || echo "rtb-egress")
    RET_RTB=$(aws ec2 describe-transit-gateway-route-tables --region "$REGION" \
      --filters "Name=transit-gateway-id,Values=$TGW_ID" \
                "Name=tag:Name,Values=${PROJECT}-${RET_NAME}" \
      --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text 2>/dev/null)

    while read -r att owner rtb; do
      [[ -z "$att" ]] && continue

      if [[ -z "$rtb" || "$rtb" == "None" ]]; then
        bad "$att (account $owner) KHONG thuoc route table nao - dat wire_remote_attachments = true roi apply"
        continue
      fi
      ok "$att (account $owner) da noi vao $rtb"

      # ASSOCIATION KHONG PHAI PROPAGATION.
      #
      # Association cho spoke biet duong RA. Propagation cho duong VE
      # biet CIDR cua spoke. Co cai dau ma thieu cai sau thi goi di
      # duoc, goi tra loi lac - luong bat doi xung, va KHONG trang thai
      # resource nao hien ra dieu do. Phai hoi chinh bang dinh tuyen.
      [[ "$RET_RTB" == "None" || -z "$RET_RTB" ]] && { skip "Khong tim thay ${PROJECT}-${RET_NAME}"; continue; }

      prop=$(aws ec2 search-transit-gateway-routes --region "$REGION" \
        --transit-gateway-route-table-id "$RET_RTB" \
        --filters "Name=type,Values=propagated" "Name=state,Values=active" \
        --query "Routes[?TransitGatewayAttachments[0].TransitGatewayAttachmentId=='$att'].DestinationCidrBlock" \
        --output text 2>/dev/null)

      if [[ -n "$prop" && "$prop" != "None" ]]; then
        ok "  duong ve ($RET_NAME) da hoc CIDR $prop"
      else
        bad "  duong ve ($RET_NAME) CHUA hoc CIDR cua $att - goi di duoc, goi tra loi lac"
      fi
    done <<<"$remote_atts"
  fi
fi

########################################
hdr "6d. Cac account da CHAP NHAN loi moi RAM chua"
#
# Share ngoai to chuc khong tu dong duoc chap nhan. Truoc khi account
# bam nhan, principal o trang thai ASSOCIATING: share ton tai, Terraform
# apply xanh, va account do VAN KHONG THAY Transit Gateway.
#
# Chay tu chinh account so huu share, nen thay het ca nam account ma
# khong phai dang nhap vao tung cai - va do la ly do co muc nay: kiem
# bang cach doi credential qua tung account thi rat de bo sot mot cai.
########################################

SHARE_ARN=$(aws ram get-resource-shares --resource-owner SELF --region "$REGION" \
  --name "${PROJECT}-tgw" \
  --query 'resourceShares[?status==`ACTIVE`].resourceShareArn' --output text 2>/dev/null)

if [[ -z "$SHARE_ARN" || "$SHARE_ARN" == "None" ]]; then
  skip "Khong co RAM share ${PROJECT}-tgw (ram_use_external_principals = false)"
else
  assoc=$(aws ram get-resource-share-associations --region "$REGION" \
    --association-type PRINCIPAL --resource-share-arns "$SHARE_ARN" \
    --query 'resourceShareAssociations[].[associatedEntity,status]' --output text 2>/dev/null)

  if [[ -z "$assoc" ]]; then
    bad "Share ton tai nhung khong co principal nao - khong account nao thay duoc TGW"
  else
    while read -r acct st; do
      [[ -z "$acct" ]] && continue
      if [[ "$st" == "ASSOCIATED" ]]; then
        ok "$acct: $st"
      else
        bad "$acct: $st - account nay CHUA nhan loi moi, no khong thay TGW"
      fi
    done <<<"$assoc"
  fi
fi

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
# LAY EC2 DAU TIEN CO THAT, khong goi ten cung - loi 62.
#
# Truoc day hai dong nay la .["app-dev"] va .["app-prod"]. Doi ten
# spoke la ca hai thanh rong, va muc 7 bo qua voi ly do SAI:
# "enable_test_instances = false" trong khi no dang true.
DEV_ID=$(echo "$INSTANCES" | jq -r 'to_entries | sort_by(.key) | .[0].value.id // empty')
DEV_NAME=$(echo "$INSTANCES" | jq -r 'to_entries | sort_by(.key) | .[0].key // empty')
PROD_IP=$(echo "$INSTANCES" | jq -r 'to_entries | sort_by(.key) | .[1].value.private_ip // empty')
# Moi AZ mot NAT nen day la DANH SACH. EC2 ra Internet bang NAT cua
# AZ chua no, khong doan truoc duoc la cai nao.
NAT_IPS=$(terraform output -json nat_public_ips 2>/dev/null | jq -r '.[]' | tr '\n' ' ')

if [[ -z "$DEV_ID" ]]; then
  # LY DO PHAI DUNG. Truoc day dong nay luon noi
  # "enable_test_instances = false", ke ca khi bien do dang true va
  # nguyen nhan that la khong con spoke noi bo nao. Mot ly do sai
  # trong thong bao con dat hon khong co thong bao. Loi 62.
  if [[ -z "$SPOKES" ]]; then
    skip "Khong co spoke noi bo -> khong co EC2 nao o day de dieu khien phep do"
  else
    skip "Khong co EC2 test (enable_test_instances = false)"
  fi
else
  echo "  ... dang chay lenh tren $DEV_NAME ($DEV_ID) qua SSM (~1 phut)"

  out=$(run_remote "$DEV_ID" "curl -s --max-time 10 https://checkip.amazonaws.com")
  matched=""
  for ip in $NAT_IPS; do
    [[ "$out" == *"$ip"* ]] && matched="$ip"
  done

  if [[ -n "$matched" ]]; then
    ok "Egress ra Internet bang NAT cua egress VPC ($matched)"
  else
    bad "IP ra Internet = '$out', ky vong mot trong: $NAT_IPS"
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

  ########################################
  # 7b. VPC ENDPOINT TAP TRUNG CO THUC SU DUOC DUNG KHONG
  #
  # Day la khoan lang phi KHONG CO TRIEU CHUNG. Neu PHZ cua endpoint
  # chua toi duoc spoke, ten dich vu AWS van phan giai binh thuong -
  # ra IP CONG KHAI - va moi thu van chay, chi la chay vong ra Internet
  # qua NAT. Interface endpoint van tinh tien du khong ai di qua.
  #
  # Khong resource nao o trang thai sai, khong log nao bao gi. Chi mot
  # cau dig tu BEN TRONG spoke moi phan biet duoc.
  ########################################

  # Lay dai THAT cua security VPC, khong gan cung "10.1." - ai doi
  # security_vpc_cidr se lam moi khang dinh duoi day sai am tham.
  # Cung ho voi loi 48.
  SEC_CIDR=$(aws ec2 describe-vpcs --region "$REGION" \
    --vpc-ids "$(tfout security_vpc_id)" \
    --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null)
  SEC_CIDR_PREFIX=$(echo "$SEC_CIDR" | cut -d. -f1,2).

  ep_zones=$(terraform output -json dns 2>/dev/null | jq -r '.endpoint_zones | keys[]' 2>/dev/null)

  if [[ -z "$ep_zones" ]]; then
    skip "Khong co PHZ endpoint (enable_interface_endpoints = false)"
  else
    svc=$(echo "$ep_zones" | head -1)
    out=$(run_remote "$DEV_ID" "dig +short ${svc}.${REGION}.amazonaws.com | head -2 | tr '\\n' ' '")

    if [[ "$out" == *"$SEC_CIDR_PREFIX"* ]]; then
      ok "${svc}.${REGION}.amazonaws.com -> $out (interface endpoint noi bo)"
    else
      bad "${svc}.${REGION}.amazonaws.com -> '$out' - PHAI la IP trong security VPC. Endpoint dang tinh tien ma luu luong di vong ra Internet"
    fi

    # S3 la gateway endpoint: lam viec o tang route table, KHONG o tang
    # DNS. Ra IP cong khai o day la DUNG - va la thu de nham nhat trong
    # ca muc nay.
    out=$(run_remote "$DEV_ID" "dig +short s3.${REGION}.amazonaws.com | head -1")
    if [[ -n "$out" && "$out" != "$SEC_CIDR_PREFIX"* ]]; then
      ok "s3.${REGION}.amazonaws.com -> $out (gateway endpoint: IP cong khai la DUNG)"
    else
      bad "s3 phan giai ra '$out' - gateway endpoint khong dung DNS, ket qua nay bat thuong"
    fi
  fi
fi

########################################
hdr "7c. East-west GIUA CAC ACCOUNT (goi tu EC2 local sang spoke remote)"
#
# Muc 7 do luong ra Internet. Muc nay do luong GIUA CAC SPOKE, va la
# muc duy nhat chung minh duong cross-account cho goi tin di qua that.
#
# Cho tro: muc 6c da bao attachment nam trong route table va duong ve
# da hoc CIDR. Ca hai dung ma van co the KHONG THONG - vi con security
# group va rule firewall, hai lop khong xuat hien trong bat ky bang
# dinh tuyen nao. Ba lop deu phai cho phep thi luong moi thong.
########################################

TARGETS=$(terraform output -json test_targets 2>/dev/null || echo '{}')
REMOTE_KEYS=$(echo "$TARGETS" | jq -r 'to_entries[] | select(.value.account != "local") | .key' 2>/dev/null)

if [[ -z "$DEV_ID" ]]; then
  skip "Khong co EC2 local de goi di - can it nhat mot spoke khong khai account_id"
elif [[ -z "$REMOTE_KEYS" ]]; then
  skip "Khong co EC2 o spoke remote (remote_test_instances = false)"
else
  for k in $REMOTE_KEYS; do
    ip=$(echo "$TARGETS" | jq -r --arg k "$k" '.[$k].ip')
    acct=$(echo "$TARGETS" | jq -r --arg k "$k" '.[$k].account')

    # LAY MA THOAT CUA CURL, khong gop tat ca thanh "TIMEOUT" - loi 63.
    #
    # Ban dau dong nay la `curl ... || echo TIMEOUT`, nen "cong bi tu
    # choi" va "goi tin khong toi noi" in ra Y HET NHAU. Hai nguyen
    # nhan hoan toan khac: mot la dich vu chua chay, mot la loi mang.
    #
    #   rc=7   khong ket noi duoc  -> cong dong, DICH VU chua chay
    #   rc=28  het thoi gian       -> goi tin khong toi noi, loi MANG
    out=$(run_remote "$DEV_ID" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://$ip/; echo \" rc=\$?\"")
    code=$(echo "$out" | grep -oE 'rc=[0-9]+' | cut -d= -f2)

    if [[ "$out" == *"200"* ]]; then
      ok "$k ($acct) $ip:80 THONG"
    elif [[ "$code" == "7" ]]; then
      bad "$k ($acct) $ip:80 BI TU CHOI - goi tin toi noi nhung khong ai nghe cong 80. Loi DICH VU, khong phai mang (xem UserData)"
    elif [[ "$code" == "28" ]]; then
      bad "$k ($acct) $ip:80 TIMEOUT - goi tin khong toi noi. Kiem east_west_mesh_ports, SG, rule firewall"
    else
      bad "$k ($acct) $ip:80 khong thong (ket qua: $out)"
    fi

    # Port 22: SG MO nhung khong co rule firewall nao cho no.
    # Che do drop  -> phai timeout. Do la bang chung firewall chan that.
    # Che do alert -> van thong, dung nhu thiet ke.
    out=$(run_remote "$DEV_ID" "timeout 8 nc -zv $ip 22 2>&1 | tail -1 || echo TIMEOUT")
    if [[ "$(terraform output -raw mode 2>/dev/null)" == *drop* ]]; then
      if [[ "$out" == *"TIMEOUT"* || "$out" == *"timed out"* ]]; then
        ok "$k ($acct) $ip:22 BI CHAN boi firewall (SG van mo)"
      else
        bad "$k ($acct) $ip:22 van thong du khong co rule firewall: $out"
      fi
    else
      skip "$k ($acct) $ip:22 - firewall dang alert, chua chan (ket qua: $out)"
    fi
  done
fi

########################################
hdr "8. Ingress"
########################################

NLB=$(tfout nlb_dns_name)
CDN=$(tfout cloudfront_domain)

if [[ -z "$NLB" ]]; then
  skip "Ingress tat"
elif [[ -n "$CDN" ]]; then
  # Co CDN: phai vao qua CloudFront, goi thang NLB phai bi chan
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://$CDN/" || echo 000)
  [[ "$code" == "200" ]] \
    && ok "CloudFront → NLB → TGW → (firewall) → app: HTTP $code" \
    || bad "CloudFront tra ve $code (distribution co the dang deploy, doi vai phut)"

  # Khoa origin: goi thang vao NLB phai timeout hoac bi tu choi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$NLB/" || echo TIMEOUT)
  [[ "$code" == "TIMEOUT" || "$code" == "000" ]] \
    && ok "Goi THANG vao NLB bi chan (origin khoa theo prefix list CloudFront)" \
    || bad "Goi thang vao NLB van vao duoc (HTTP $code) - origin chua khoa"

  # WAF: payload SQLi phai bi chan khi waf_mode = block
  WAF_MODE=$(grep -E '^\s*waf_mode' terraform.tfvars 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || echo count)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://$CDN/?id=1%27%20OR%20%271%27=%271" || echo 000)
  if [[ "$WAF_MODE" == "block" ]]; then
    [[ "$code" == "403" ]] \
      && ok "WAF chan payload SQLi (HTTP 403)" \
      || bad "WAF chua chan SQLi (HTTP $code)"
  else
    skip "WAF dang o che do count, chua chan (HTTP $code) - doi waf_mode=\"block\" de test"
  fi
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$NLB/" || echo 000)
  [[ "$code" == "200" ]] \
    && ok "NLB → TGW → (firewall) → app: HTTP $code" \
    || bad "NLB tra ve $code (target group co the chua healthy, doi 1-2 phut roi chay lai)"
fi

########################################
echo
echo "════════════════════════════════════════════"
printf " \033[32m%d dat\033[0m  \033[31m%d loi\033[0m  \033[33m%d bo qua\033[0m\n" "$PASS" "$FAIL" "$SKIP"
echo "════════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && echo " Nho chay ./teardown.sh khi xong." || echo " Xem lai cac muc loi o tren."
echo

exit $(( FAIL > 0 ? 1 : 0 ))
