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

# 2>/dev/null o day tung nuot MOI nguyen nhan: het token, sai region,
# thieu quyen ssm:GetParameter deu ra cung mot dong "khong lay duoc".
# Ba nguyen nhan, ba cach sua khac han nhau, mot thong bao - cung hinh
# dang voi loi 66 va loi 75.
#
# Giu stderr lai va in ra khi that bai.
if [[ -z "$DUMMY_AMI" ]]; then
  AMI_ERR=$(mktemp)
  DUMMY_AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text 2>"$AMI_ERR")

  # Loi thoat thu hai: doc AMI truc tiep. Can ec2:DescribeImages thay
  # vi ssm:GetParameter - hai quyen khac nhau, va vai to chuc cap cai
  # nay ma khong cap cai kia.
  if [[ -z "$DUMMY_AMI" || "$DUMMY_AMI" == "None" ]]; then
    DUMMY_AMI=$(aws ec2 describe-images --region "$REGION" --owners amazon \
      --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>>"$AMI_ERR")
  fi
fi

if [[ -n "$DUMMY_AMI" && "$DUMMY_AMI" != "None" ]]; then
  ok "AMI gia cho plan appliance: $DUMMY_AMI"
else
  bad "Khong lay duoc AMI gia. Loi that su tu AWS:"
  sed 's/^/      /' "${AMI_ERR:-/dev/null}" 2>/dev/null || true
  echo
  echo "  Ba nguyen nhan hay gap, ba cach sua khac nhau:"
  echo "    ExpiredToken / InvalidClientTokenId  -> lay lai credential"
  echo "    AccessDenied                         -> thieu ssm:GetParameter"
  echo "                                            VA ec2:DescribeImages"
  echo "    Could not connect                    -> sai region (dang dung $REGION)"
  echo
  echo "  Khong sua duoc thi cho thang mot AMI bat ky trong region:"
  echo "    DUMMY_AMI=ami-xxxxxxxx ./plan-check.sh"
  echo
  echo "  AMI nao cung duoc - plan chi can MOT ID hop le, khong bao gio"
  echo "  khoi dong no. Lay mot cai tu instance dang chay:"
  echo "    aws ec2 describe-instances --region $REGION \\"
  echo "      --query 'Reservations[0].Instances[0].ImageId' --output text"
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
# CAU HINH THIET BI - thu plan KHONG NHIN VAO
#
# templatefile() chi ghep chuoi. bootstrap.xml cua Palo Alto co the
# thieu the dong, thieu ca mot khoi bat buoc, hay sai cau truc hoan
# toan - plan van xanh, apply van xanh, object van len S3. PAN-OS moi
# la thu doc no, va no doc luc BOOT.
#
# Khi cau hinh sai, trieu chung la: GWLB bao target unhealthy mai mai,
# khong log, khong loi. Cung ho voi cau hinh IPsec cua strongSwan -
# phan duy nhat cua ca bo khong co gi kiem duoc ngoai viec thu.
#
# Nen kiem o day: cu phap XML, va cac khoi ma thieu chung thi thiet bi
# len nhung khong quet gi.
########################################
python3 - <<'PYCHK'
import re, sys, xml.etree.ElementTree as ET

src = open("templates/pa-bootstrap.xml.tftpl", encoding="utf-8").read()

# Dung templatefile bang tay: gia tri gia, chi de kiem CAU TRUC.
loops = {"permitted_ips": ("cidr", ["10.0.0.0/8"]),
         "allowed_applications": ("app", ["web-browsing", "ssl"])}
for name, (var, vals) in loops.items():
    src = re.sub(r"%\{ for " + var + r" in " + name + r" ~\}(.*?)%\{ endfor ~\}\n",
                 lambda m: "".join(m.group(1).replace("${" + var + "}", v) for v in vals),
                 src, flags=re.S)
src = re.sub(r"\$\{[a-z_][a-z0-9_.]*\}", "X", src)

leftover = re.findall(r"[$%]\{[^}]*\}", src)
if leftover:
    print("  con sot noi suy chua thay the:", leftover); sys.exit(1)

try:
    root = ET.fromstring(src)
except ET.ParseError as e:
    print("  bootstrap.xml SAI CU PHAP:", e); sys.exit(1)

need = {
    "./devices/entry/network/interface/ethernet/entry": "interface du lieu",
    "./devices/entry/network/virtual-router/entry": "virtual router",
    "./devices/entry/network/profiles/interface-management-profile/entry":
        "profile quan tri interface - THIEU thi health check cua GWLB khong bao gio dat",
    "./devices/entry/vsys/entry/zone/entry": "security zone",
    "./devices/entry/vsys/entry/import/network/interface":
        "import interface vao vsys - THIEU thi zone khong gan vao interface nao",
    "./devices/entry/vsys/entry/rulebase/security/rules/entry": "rule bao mat",
}
missing = [ten for xp, ten in need.items() if not root.findall(xp)]
if missing:
    print("  bootstrap.xml THIEU:"); [print("    -", m) for m in missing]; sys.exit(1)

# init-cfg.txt: hai khoa ma thieu chung thi thiet bi len nhung khong
# nhan duoc goi tin nao can quet.
cfg = open("templates/pa-init-cfg.txt.tftpl", encoding="utf-8").read()
for key in ("op-command-modes", "plugin-op-commands", "type=dhcp-client"):
    if key not in cfg:
        print(f"  init-cfg.txt thieu khoa: {key}"); sys.exit(1)
PYCHK
if [[ $? -eq 0 ]]; then
  ok "Cau hinh Palo Alto: XML hop le, du khoi bat buoc"
else
  bad "Cau hinh Palo Alto khong hop le - xem tren"
fi

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
  # Khong dung `| head -1` - no dong pipe som va gay dung SIGPIPE ma
  # check_in_plan mac phai. sed lay dong dau, doc het dau vao.
  n=$(grep -oE '^Plan: [0-9]+ to add' <<<"$out" | grep -oE '[0-9]+' | sed -n '1p')
  n2=$(grep -c 'will be created' <<<"$out")

  # n2 LA CON SO DUNG, n CHI LA PHU.
  #
  # Do tren Terraform v1.11.3: dong "Plan: N to add" CO THAT trong
  # output khi ghi thang ra file (tim thay o dong 2280), nhung KHONG
  # tim thay duoc khi bat qua $(... 2>&1) trong script nay. Chua giai
  # thich duoc vi sao - va khong can: dem dong "will be created" cho
  # cung con so, on dinh qua cac ban Terraform, khong phu thuoc dinh
  # dang dong tom tat.
  #
  # Bai hoc chung: dua vao dau hieu CO SAN o moi phien ban, thay vi
  # mot dong tom tat co the doi cach in.
  if [[ "$n2" -eq 0 ]]; then
    bad "$label  (plan khong tao resource nao)"
    echo "      Plan tren state RONG phai tao resource - aws_vpc.egress"
    echo "      khong co count/for_each nao ca. Sau day la 6 dong cuoi:"
    echo "$out" | tail -6 | sed 's/^/      /'
    return
  fi

  if [[ -n "$n" && "$n" != "$n2" ]]; then
    bad "$label  (dong 'Plan:' noi $n, dem duoc $n2 - output bi cat?)"
    return
  fi

  ok "$label  ($n2 resource se duoc tao)"
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
FULL_RC=$?

# KIEM MA THOAT TRUOC KHI GREP.
#
# Thieu doan nay thi mot plan HONG cho ra chuoi rong, va chin lenh
# grep ben duoi deu bao "khong thay X trong plan" - doc y het nhu
# chin loi code, trong khi thuc te la MOT loi va no o day.
#
# Te hon: khang dinh phu nhan cuoi cung ("khong con attachment tro
# thang vao app") se DAT tren chuoi rong, nen bang ket qua co mot dau
# tich lam ca muc trong nhu da chay that.
#
# Cung kieu hong voi `|| true` o verify-detection.sh: mot ket qua
# rong bi doc thanh mot su that.
FULL_N=$(grep -c 'will be created' <<<"$FULL")

if [[ $FULL_RC -ne 0 || $FULL_N -eq 0 ]]; then
  bad "Plan day du that bai - BO QUA 10 kiem tra hanh vi ben duoi"
  echo "      Chung se bao 'khong thay X' nhung nguyen nhan la o day:"
  echo "$FULL" | grep -E '^(Error|╷|│|╵)' | head -20 | sed 's/^/      /'
  [[ $FULL_RC -eq 0 ]] && echo "      (exit 0 nhung khong resource nao - xem 6 dong cuoi)" \
    && echo "$FULL" | tail -6 | sed 's/^/      /'
  echo
  echo "════════════════════════════════════════════════════"
  printf " \033[32m%d dat\033[0m   \033[31m%d loi\033[0m\n" "$PASS" "$FAIL"
  echo "════════════════════════════════════════════════════"
  exit 1
fi

ok "Plan day du: $FULL_N resource - chay 10 kiem tra hanh vi"

# DUNG HERESTRING, KHONG DUNG `echo | grep -q`.
#
# Voi `set -o pipefail` (khai o dau file), `echo "$FULL" | grep -q X`
# tra ve SAI khi $FULL lon:
#
#   grep -q thoat NGAY khi khop dau tien
#   -> echo chet vi SIGPIPE (141)
#   -> pipefail lay 141 lam ma thoat cua ca pipeline
#   -> nhanh && khong chay, bao "khong thay X"
#
# TIM THAY bi doc thanh KHONG THAY. Chin khang dinh o duoi deu truot
# vi ly do nay, tren mot plan 175 resource co du moi thu chung tim.
#
# Chi lo ra khi dau vao du lon de echo chua ghi xong - nen thu tren
# chuoi ngan thi khong bao gio thay.
#
# Herestring khong tao pipeline nen khong co SIGPIPE.
check_in_plan() {
  local pattern="$1" label="$2"
  if grep -q "$pattern" <<<"$FULL"; then
    ok "$label"
  else
    bad "$label  (khong thay '$pattern' trong plan)"
  fi
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
if grep -q "aws_lb_target_group_attachment.app_direct" <<<"$FULL"; then
  bad "Van con attachment tro THANG vao app - dang le phai di qua F5"
else
  ok "Khong con attachment tro thang vao app"
fi

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
