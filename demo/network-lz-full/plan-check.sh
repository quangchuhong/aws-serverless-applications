#!/usr/bin/env bash
#
# Kiem chung TOAN BO code bang terraform plan, KHONG apply gi.
#
# Chay het cac to hop bien, gom ca Palo Alto + F5 (phase sau).
# Muc dich: bat loi cu phap, tham chieu sai, cycle... truoc khi
# den luc thuc su can dung.
#
# Can AWS credential (plan phai goi API doc), nhung KHONG tao resource nao.
#
set -uo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"

# AMI gia de plan phan appliance ma KHONG can subscribe Marketplace.
# Lay AMI Amazon Linux bat ky - plan chi can mot AMI ID hop le.
DUMMY_AMI="${DUMMY_AMI:-}"

PASS=0; FAIL=0

hdr()  { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "════════════════════════════════════════════════════"
echo " Kiem chung code bang terraform plan (khong apply)"
echo "════════════════════════════════════════════════════"

########################################
hdr "0. Chuan bi"
########################################

if [[ -z "$DUMMY_AMI" ]]; then
  DUMMY_AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text 2>/dev/null)
fi

if [[ -n "$DUMMY_AMI" && "$DUMMY_AMI" != "None" ]]; then
  ok "AMI gia cho plan appliance: $DUMMY_AMI"
else
  bad "Khong lay duoc AMI gia - dat bien DUMMY_AMI=ami-xxxx roi chay lai"
  exit 1
fi

terraform init -input=false -upgrade >/dev/null 2>&1 \
  && ok "terraform init" \
  || { bad "terraform init that bai"; exit 1; }

terraform fmt -check -recursive >/dev/null 2>&1 \
  && ok "terraform fmt" \
  || bad "terraform fmt - chay 'terraform fmt -recursive' de sua"

terraform validate >/dev/null 2>&1 \
  && ok "terraform validate" \
  || { bad "terraform validate that bai:"; terraform validate; }

########################################
run_plan() {
  local label="$1"; shift
  local out
  out=$(terraform plan -input=false -lock=false -refresh=false "$@" 2>&1)
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    bad "$label"
    echo "$out" | grep -E '^(Error|│)' | head -20 | sed 's/^/      /'
    return
  fi

  # DEM HAI CACH, VI MOT CACH DA TUNG IM LANG TRA VE RONG.
  #
  #   n   doc dong tong ket "Plan: N to add" - gon, nhung phu thuoc
  #       dinh dang cua ban Terraform dang chay
  #   n2  dem dong "will be created" - Terraform in cho TUNG resource,
  #       on dinh qua cac ban
  #
  # Hai so lech nhau la dau hieu output bi cat giua chung (pipe dong
  # som, plan bi ngat) - va do la thu can biet, khong phai thu de doan.
  local n n2
  n=$(echo "$out" | grep -oE '^Plan: [0-9]+ to add' | grep -oE '[0-9]+' | head -1)
  n2=$(echo "$out" | grep -c 'will be created')

  if [[ -z "$n" && "$n2" -gt 0 ]]; then
    bad "$label  (co $n2 resource nhung KHONG co dong 'Plan:' - output bi cat?)"
    echo "$out" | tail -6 | sed 's/^/      /'
    return
  fi

  # KHONG BAO CAO 0 LA DAT.
  #
  # Mot to hop bat ca firewall lan ingress lan CDN ma plan ra 0 resource
  # thi khong phai "code dung", ma la plan KHONG NHIN THAY config -
  # state cu, sai thu muc, hoac plan in ra "No changes" vi mot ly do
  # khac han. Ban dau ham nay in "(0 resource se duoc tao)" kem dau ✓,
  # va ca chin muc kiem tra hanh vi ben duoi truot theo ma khong ai
  # hieu vi sao.
  #
  # Cung kieu hong voi `|| true` trong verify-detection.sh: mot so
  # khong bi doc thanh mot thanh cong.
  if [[ -z "$n" || "$n" -eq 0 ]]; then
    bad "$label  (plan khong tao resource nao)"
    echo "      Plan tren state RONG phai tao resource - aws_vpc.egress"
    echo "      khong co count/for_each nao ca. Sau day la 6 dong cuoi:"
    echo "$out" | tail -6 | sed 's/^/      /'
    return
  fi

  ok "$label  ($n resource se duoc tao)"
}

hdr "1. Cac to hop khong co appliance"
########################################

run_plan "Toi thieu: khong firewall, khong ingress" \
  -var='enable_firewall=false' -var='enable_ingress=false' \
  -var='enable_cdn=false' -var='enable_appliances=false'

run_plan "Co ingress, chua co firewall" \
  -var='enable_firewall=false' -var='enable_ingress=true' \
  -var='enable_cdn=false' -var='enable_appliances=false'

run_plan "Firewall che do alert" \
  -var='enable_firewall=true' -var='firewall_mode=alert' \
  -var='enable_ingress=true' -var='enable_cdn=false' -var='enable_appliances=false'

run_plan "Firewall che do drop" \
  -var='enable_firewall=true' -var='firewall_mode=drop' \
  -var='enable_ingress=true' -var='enable_cdn=false' -var='enable_appliances=false'

run_plan "Them interface endpoint" \
  -var='enable_firewall=true' -var='enable_interface_endpoints=true' \
  -var='enable_ingress=true' -var='enable_cdn=false' -var='enable_appliances=false'

run_plan "Them CloudFront + WAF" \
  -var='enable_firewall=true' -var='enable_ingress=true' \
  -var='enable_cdn=true' -var='waf_mode=count' -var='enable_appliances=false'

########################################
hdr "2. PHASE SAU: Palo Alto + F5"
########################################

echo "  (dung AMI gia de khong can subscribe Marketplace)"

run_plan "Appliance, khong firewall" \
  -var='enable_firewall=false' -var='enable_ingress=true' \
  -var='enable_cdn=false' -var='enable_appliances=true' \
  -var="pa_ami_id=$DUMMY_AMI" -var="f5_ami_id=$DUMMY_AMI"

run_plan "Appliance + firewall" \
  -var='enable_firewall=true' -var='firewall_mode=drop' \
  -var='enable_ingress=true' -var='enable_cdn=false' -var='enable_appliances=true' \
  -var="pa_ami_id=$DUMMY_AMI" -var="f5_ami_id=$DUMMY_AMI"

run_plan "DAY DU: appliance + firewall + CDN" \
  -var='enable_firewall=true' -var='firewall_mode=drop' \
  -var='enable_ingress=true' -var='enable_cdn=true' -var='waf_mode=block' \
  -var='enable_appliances=true' \
  -var="pa_ami_id=$DUMMY_AMI" -var="f5_ami_id=$DUMMY_AMI"

########################################
hdr "3. Kiem tra hanh vi mong doi trong plan day du"
########################################

FULL=$(terraform plan -input=false -lock=false -refresh=false -no-color \
  -var='enable_firewall=true' -var='enable_ingress=true' \
  -var='enable_cdn=false' -var='enable_appliances=true' \
  -var="pa_ami_id=$DUMMY_AMI" -var="f5_ami_id=$DUMMY_AMI" 2>&1)

check_in_plan() {
  local pattern="$1" label="$2"
  echo "$FULL" | grep -q "$pattern" \
    && ok "$label" \
    || bad "$label  (khong thay '$pattern' trong plan)"
}

check_in_plan "aws_ec2_transit_gateway_vpc_attachment.security"  "TGW attachment cua security VPC"
check_in_plan "appliance_mode_support *= *\"enable\""            "appliance_mode_support = enable"
check_in_plan "aws_networkfirewall_firewall.main"                "Network Firewall"
check_in_plan "aws_lb.gwlb"                                      "Gateway Load Balancer"
check_in_plan "aws_vpc_endpoint.gwlbe"                           "GWLB endpoint"
check_in_plan "source_dest_check *= *false"                      "PA tat source_dest_check"
check_in_plan "aws_route_table_association.igw_edge"             "Edge route table gan vao IGW"
check_in_plan "aws_instance.f5"                                  "Instance F5"
check_in_plan "aws_lb_target_group_attachment.app_via_f5"        "NLB tro vao F5 (khong tro thang app)"

# Khi co appliance thi KHONG duoc con attachment tro thang vao app
echo "$FULL" | grep -q "aws_lb_target_group_attachment.app_direct" \
  && bad "Van con attachment tro THANG vao app - dang le phai di qua F5" \
  || ok "Khong con attachment tro thang vao app"

########################################
echo
echo "════════════════════════════════════════════════════"
printf " \033[32m%d dat\033[0m   \033[31m%d loi\033[0m\n" "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo " Code san sang. Chua tao resource nao."
else
  echo " Xem lai cac muc loi o tren."
fi
echo

exit $(( FAIL > 0 ? 1 : 0 ))
