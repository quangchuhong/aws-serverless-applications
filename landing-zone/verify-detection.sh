#!/usr/bin/env bash
#
# KIEM TRA LOP PHAT HIEN - GuardDuty, Security Hub, AWS Config
#
# Tra loi HAI cau hoi khac nhau:
#
#   1. Account DANG CO trong to chuc co duoc phu song khong?
#   2. Account THEM SAU NAY co tu duoc phu song khong?
#
# Cau thu hai khong suy ra duoc tu cau thu nhat. Da do tren to chuc
# that: GuardDuty co auto_enable_organization_members = ALL, uy quyen
# tron ven, va sau HON 25 PHUT khong account nao duoc ghi danh.
# Xem loi 41 doc 22.
#
#   ./verify-detection.sh
#   ./verify-detection.sh --security lz-security --region ap-southeast-1
#   ./verify-detection.sh --mgmt lz-management
#
# CAN HAI CREDENTIAL:
#   management account  - danh sach account, cay OU, StackSet, uy quyen
#   security account    - danh sach member cua GuardDuty va Security Hub
#
# Script nay CHI DOC. Khong tao, khong sua, khong xoa gi.
#
# MA THOAT
#   0  moi account duoc phu song boi ca ba dich vu
#   1  co khoang trong, hoac mot lenh AWS that bai
#
set -uo pipefail

cd "$(dirname "$0")"

MGMT_PROFILE=""
SEC_PROFILE="lz-security"
REGION="ap-southeast-1"
PROJECT="quh11-lz"

# LUU Y BASH 3.2 (ban mac dinh cua macOS): khong co mang ket hop
# (associative array). Nen tra cuu bang file tam + grep thay vi ${map[$k]}.
while [ $# -gt 0 ]; do
  case "$1" in
    --mgmt)     MGMT_PROFILE="${2:-}"; shift ;;
    --security) SEC_PROFILE="${2:-}";  shift ;;
    --region)   REGION="${2:-}";       shift ;;
    --project)  PROJECT="${2:-}";      shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Khong hieu tham so: $1"; exit 1 ;;
  esac
  shift
done

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }
grey()  { printf '\033[90m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

MGMT_ARGS="--region $REGION"
[ -n "$MGMT_PROFILE" ] && MGMT_ARGS="$MGMT_ARGS --profile $MGMT_PROFILE"
SEC_ARGS="--region $REGION"
[ -n "$SEC_PROFILE" ] && SEC_ARGS="$SEC_ARGS --profile $SEC_PROFILE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

problems=0
note() { problems=$((problems + 1)); }

# aws_mgmt / aws_sec: goi AWS, tra ve rong neu that bai.
# KHONG dung `|| true` truc tiep o cho goi vi no nuot mat ma loi va
# lam "that bai" trong y het "khong co du lieu" - dung kieu nham lan
# da sinh ra loi 27 va loi 41.
aws_mgmt() { aws $MGMT_ARGS "$@" 2>"$TMP/err"; }
aws_sec()  { aws $SEC_ARGS  "$@" 2>"$TMP/err"; }

fail_hint() {
  # In ra dong dau cua stderr - thuong la cau noi ro nhat AWS dua ra.
  # Loi 41 chung minh: thong bao that co the nam o cho khong ai doc.
  head -n 1 "$TMP/err" 2>/dev/null | cut -c1-160
}

echo
bold "LZ - KIEM TRA LOP PHAT HIEN"; echo
grey  "region $REGION   security-profile ${SEC_PROFILE:-<mac dinh>}   mgmt-profile ${MGMT_PROFILE:-<mac dinh>}"; echo
echo

########################################
# 0. To chuc
########################################

ORG_ID=$(aws_mgmt organizations describe-organization --query 'Organization.Id' --output text)
if [ -z "$ORG_ID" ] || [ "$ORG_ID" = "None" ]; then
  red "Khong doc duoc Organizations."; echo
  echo "  $(fail_hint)"
  echo "  Credential dang dung co phai cua MANAGEMENT ACCOUNT khong?"
  exit 1
fi
MASTER_ID=$(aws_mgmt organizations describe-organization --query 'Organization.MasterAccountId' --output text)

aws_mgmt organizations list-accounts \
  --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' --output text \
  | sort > "$TMP/accounts"

n_accounts=$(wc -l < "$TMP/accounts" | tr -d ' ')
grey "to chuc $ORG_ID   $n_accounts account ACTIVE   management $MASTER_ID"; echo
echo

########################################
# 1. Uy quyen - dieu kien tien quyet cua moi thu con lai
########################################

bold "1. UY QUYEN"; echo

GD_ADMIN=$(aws_mgmt guardduty list-organization-admin-accounts \
  --query 'AdminAccounts[?AdminStatus==`ENABLED`].AdminAccountId' --output text)
SH_ADMIN=$(aws_mgmt securityhub list-organization-admin-accounts \
  --query 'AdminAccounts[?Status==`ENABLED`].AccountId' --output text)

row_admin() {
  # $1 ten dich vu, $2 gia tri doc duoc
  if [ -n "$2" ] && [ "$2" != "None" ]; then
    printf '   %-22s %s  %s\n' "$1" "$2" "$(green ENABLED)"
  else
    printf '   %-22s %s\n' "$1" "$(red 'CHUA UY QUYEN')"
    note
  fi
}

row_admin "GuardDuty admin"    "$GD_ADMIN"
row_admin "Security Hub admin" "$SH_ADMIN"

# Config KHONG co lenh chi dinh rieng - dang ky o Organizations la cach
# duy nhat. Nguoc lai voi GuardDuty va Security Hub, hai cai do tu dang
# ky khi goi lenh chi dinh cua chinh chung. Xem loi 35 doc 22.
if [ -n "$GD_ADMIN" ] && [ "$GD_ADMIN" != "None" ]; then
  aws_mgmt organizations list-delegated-services-for-account \
    --account-id "$GD_ADMIN" \
    --query 'DelegatedServices[].ServicePrincipal' --output text > "$TMP/delegated"

  # Hai service principal KHAC NHAU va deu can. Thieu cai thu hai thi
  # aws_config_organization_managed_rule bao AccessDeniedException ma
  # khong noi ro thieu gi - loi mat nhieu thoi gian nhat cua layer
  # organization.
  check_delegated() {
    if grep -q "$1" "$TMP/delegated" 2>/dev/null; then
      printf '   %-22s %s\n' "$2" "$(green 'co')"
    else
      printf '   %-22s %s\n' "$2" "$(red "THIEU $1")"
      note
    fi
  }
  check_delegated "config.amazonaws.com"                   "Config delegated"
  check_delegated "config-multiaccountsetup.amazonaws.com" "Config multiaccount"
fi
echo

if [ -z "$GD_ADMIN" ] || [ "$GD_ADMIN" = "None" ]; then
  red "Khong co delegated admin - dung o day, moi kiem tra sau deu vo nghia."; echo
  exit 1
fi

########################################
# 2. Phu song theo tung account
#
# Doc tu delegated admin chu khong assume-role vao tung account:
# hai credential la du, va do cung la goc nhin ma nguoi van hanh
# thuc su dung hang ngay.
########################################

bold "2. PHU SONG THEO ACCOUNT"; echo

DETECTOR=$(aws_sec guardduty list-detectors --query 'DetectorIds[0]' --output text)
if [ -z "$DETECTOR" ] || [ "$DETECTOR" = "None" ]; then
  red "Khong tim thay detector o security account."; echo
  echo "  $(fail_hint)"
  exit 1
fi

# LOI TUNG MAC O DAY - dung viet lai thanh `... > file || true`.
#
# Lenh AWS THAT BAI va "khong co member nao" cho ra ket qua GIONG HET
# NHAU: file rong, ca cot bao THIEU. Do la kieu hong da sinh ra loi
# 27, 28 va 41 - va mot script kiem tra bao sai thi nguy hon khong co
# script nao.
#
# Nen: giu ma thoat, va phan biet "khong co du lieu" voi "khong hoi duoc".
gd_ok=1; sh_ok=1; cf_ok=1

if ! aws_sec guardduty list-members --detector-id "$DETECTOR" --only-associated false \
     --query 'Members[].[AccountId,RelationshipStatus]' --output text > "$TMP/gd"; then
  gd_ok=0
  red "   guardduty list-members THAT BAI - cot GUARDDUTY khong doc duoc"; echo
  echo "     $(fail_hint)"
  note
fi

if ! aws_sec securityhub list-members --only-associated false \
     --query 'Members[].[AccountId,MemberStatus]' --output text > "$TMP/sh"; then
  sh_ok=0
  red "   securityhub list-members THAT BAI - cot SEC HUB khong doc duoc"; echo
  echo "     $(fail_hint)"
  note
fi

# Config: dung stack instance cua StackSet, vi DO LA CO CHE that su
# tao recorder. Dem resource cung noi len dieu tuong tu nhung lan lon
# giua "chua co recorder" va "account thuc su rong".
if ! aws_mgmt cloudformation list-stack-instances \
     --stack-set-name "${PROJECT}-config-recorder" \
     --query 'Summaries[].[Account,Status]' --output text > "$TMP/cfg"; then
  cf_ok=0
  red "   list-stack-instances THAT BAI - cot CONFIG khong doc duoc"; echo
  echo "     $(fail_hint)"
  note
fi

# Lenh chay duoc nhung khong tra ve gi la mot ket qua KHAC - va no
# thuong co nghia: khong account nao duoc ghi danh. Noi ro ra.
[ "$sh_ok" = 1 ] && [ ! -s "$TMP/sh" ] && \
  amber "   securityhub list-members chay duoc nhung KHONG co member nao." && echo
[ "$gd_ok" = 1 ] && [ ! -s "$TMP/gd" ] && \
  amber "   guardduty list-members chay duoc nhung KHONG co member nao." && echo

lookup() { grep "^$1	" "$2" 2>/dev/null | head -n1 | cut -f2; }

printf '   %-14s %-16s %-11s %-11s %-11s\n' ACCOUNT TEN GUARDDUTY "SEC HUB" CONFIG
printf '   %s\n' "$(grey '------------------------------------------------------------------------')"

while IFS=$'\t' read -r acct name; do
  [ -z "$acct" ] && continue

  gd=$(lookup "$acct" "$TMP/gd")
  sh=$(lookup "$acct" "$TMP/sh")
  cf=$(lookup "$acct" "$TMP/cfg")

  # Security account KHONG la member cua chinh no - do la binh thuong,
  # khong phai khoang trong.
  if [ "$acct" = "$GD_ADMIN" ]; then
    gd_txt=$(grey 'admin'); sh_txt=$(grey 'admin')
  else
    if   [ "$gd_ok" = 0 ];    then gd_txt=$(grey 'khong doc duoc')
    elif [ "$gd" = "Enabled" ]; then gd_txt=$(green Enabled)
    elif [ -n "$gd" ];        then gd_txt=$(amber "$gd");     note
    else                           gd_txt=$(red 'THIEU');     note
    fi
    if   [ "$sh_ok" = 0 ];    then sh_txt=$(grey 'khong doc duoc')
    elif [ "$sh" = "Enabled" ]; then sh_txt=$(green Enabled)
    elif [ -n "$sh" ];        then sh_txt=$(amber "$sh");     note
    else                           sh_txt=$(red 'THIEU');     note
    fi
  fi

  # Management account KHONG nam trong pham vi StackSet (StackSet
  # SERVICE_MANAGED khong trien khai vao management account) - day la
  # gioi han cua AWS, khong phai loi cau hinh.
  if [ "$acct" = "$MASTER_ID" ]; then
    cf_txt=$(grey 'ngoai StackSet')
  elif [ "$cf_ok" = 0 ]; then
    cf_txt=$(grey 'khong doc duoc')
  elif [ "$cf" = "CURRENT" ]; then
    cf_txt=$(green CURRENT)
  elif [ -n "$cf" ]; then
    cf_txt=$(amber "$cf"); note
  else
    cf_txt=$(red 'THIEU'); note
  fi

  printf '   %-14s %-16s %-20s %-20s %-20s\n' "$acct" "$(echo "$name" | cut -c1-16)" "$gd_txt" "$sh_txt" "$cf_txt"
done < "$TMP/accounts"
echo

########################################
# 3. Account THEM SAU NAY
#
# Phan quan trong nhat cua ca script, va la phan khong lenh
# describe-* nao tra loi truc tiep duoc.
########################################

bold "3. ACCOUNT THEM SAU NAY"; echo

GD_AUTO=$(aws_sec guardduty describe-organization-configuration --detector-id "$DETECTOR" \
  --query 'AutoEnableOrganizationMembers' --output text)
SH_AUTO=$(aws_sec securityhub describe-organization-configuration \
  --query 'AutoEnable' --output text)
CF_AUTO=$(aws_mgmt cloudformation describe-stack-set --stack-set-name "${PROJECT}-config-recorder" \
  --query 'StackSet.AutoDeployment.Enabled' --output text)
aws_mgmt cloudformation list-stack-instances --stack-set-name "${PROJECT}-config-recorder" \
  --query 'Summaries[].OrganizationalUnitId' --output text 2>/dev/null \
  | tr '\t' '\n' | sed '/^$/d' | sort -u > "$TMP/ous"
n_ous=$(wc -l < "$TMP/ous" | tr -d ' ')

state() {
  # $1 nhan, $2 gia tri, $3 gia tri mong doi, $4 ghi chu
  #
  # DEM PADDING TRUOC KHI TO MAU. printf '%-10s' dem CA byte cua ma
  # thoat ANSI, nen to mau truoc roi mới pad se lam lech cot - dung
  # loi da thay o lan chay dau tien.
  pad=$(printf '%-10s' "${2:-<rong>}")
  if [ "$2" = "$3" ]; then
    printf '   %-16s %s %s\n' "$1" "$(green "$pad")" "$(grey "$4")"
  else
    printf '   %-16s %s %s\n' "$1" "$(red "$pad")" "$(amber "mong doi $3")"
    note
  fi
}

state "GuardDuty"    "$GD_AUTO" "ALL"  "auto_enable_organization_members"
state "Security Hub" "$SH_AUTO" "True" "auto_enable"
state "Config"       "$CF_AUTO" "True" "StackSet auto_deployment - $n_ous OU"
echo

cat <<'EOT'
   DOC KY BA DONG TREN - CHUNG KHONG CUNG MUC DO TIN CAY:

     Config        auto_deployment cua StackSet DA CHAY THAT. Account
                   moi vao mot OU dich se duoc trien khai recorder.
                   Tin duoc.

     Security Hub  auto_enable la co che AWS ghi trong tai lieu.
                   CHUA do tren to chuc nay - chua co account moi nao
                   duoc tao ke tu khi bat.

     GuardDuty     ALL, uy quyen tron ven, va DA DO: sau hon 25 phut
                   khong account nao duoc ghi danh. Loi 41 doc 22.
                   => KHONG tin dong nay. Account moi duoc phu song
                      la nho aws_guardduty_member, ma resource do lay
                      danh sach tu data.aws_organizations_organization.
EOT
echo
amber "   => Sau khi them account moi: chay terraform apply o config-detective,"; echo
amber "      roi chay lai script nay. Dung cho auto-enable."; echo
echo

# OU nao nam ngoai pham vi StackSet thi account trong do KHONG co
# recorder - im lang, va rat de nham la "moi thu deu on".
if [ "$n_ous" -gt 0 ]; then
  grey "   $n_ous OU dang co stack instance:"; echo
  sed 's/^/     /' "$TMP/ous"
  echo
  grey "   Account tao trong OU KHAC se khong co recorder. Doi chieu voi"; echo
  grey "   recorder_target_ous trong config-detective/terraform.tfvars."; echo
  echo
fi

########################################
# 4. Duong canh bao
#
# Mot account duoc phu song day du van co the khong ai nghe thay.
# Bon loi cung ho - 28, 33, 38, 40 - deu nam o day.
########################################

bold "4. DUONG CANH BAO"; echo

TOPIC=$(aws_sec sns list-topics \
  --query "Topics[?contains(TopicArn, '${PROJECT}-security-findings')].TopicArn" --output text)

if [ -z "$TOPIC" ] || [ "$TOPIC" = "None" ]; then
  printf '   %-22s %s\n' "SNS topic" "$(red 'KHONG TIM THAY')"
  note
else
  printf '   %-22s %s\n' "SNS topic" "$(grey "${TOPIC##*:}")"

  # Subscription chua xac nhan van co ARN trong state Terraform nhung
  # SNS tra ve "PendingConfirmation". Xem loi 28 doc 22.
  aws_sec sns list-subscriptions-by-topic --topic-arn "$TOPIC" \
    --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output text > "$TMP/subs" || true

  n_ok=0; n_bad=0
  while IFS=$'\t' read -r endpoint arn; do
    [ -z "$endpoint" ] && continue
    case "$arn" in
      arn:*) n_ok=$((n_ok + 1)) ;;
      *)     n_bad=$((n_bad + 1))
             printf '   %-22s %s  %s\n' "" "$endpoint" "$(red "$arn")" ;;
    esac
  done < "$TMP/subs"

  if [ "$n_ok" -gt 0 ]; then
    printf '   %-22s %s\n' "subscriber da xac nhan" "$(green "$n_ok")"
  else
    printf '   %-22s %s\n' "subscriber da xac nhan" "$(red 0)"
    note
  fi
  [ "$n_bad" -gt 0 ] && note
fi

# Loi 40: rule loc Compliance.Status = FAILED se bo TOAN BO finding
# cua GuardDuty, vi finding hanh vi khong co truong do. Bat truong hop
# rule cu con song sot.
RULE="${PROJECT}-security-findings"
PATTERN=$(aws_sec events describe-rule --name "$RULE" --query 'EventPattern' --output text)

if [ -z "$PATTERN" ] || [ "$PATTERN" = "None" ]; then
  printf '   %-22s %s\n' "EventBridge rule" "$(red 'KHONG TIM THAY')"
  note
else
  case "$PATTERN" in
    *'$or'*)
      printf '   %-22s %s\n' "EventBridge rule" "$(green 'co $or - nhan ca finding hanh vi')" ;;
    *Compliance*)
      printf '   %-22s %s\n' "EventBridge rule" "$(red 'CHI NHAN FINDING TUAN THU')"
      echo "     Pattern loc Compliance.Status ma KHONG co \$or."
      echo "     Finding GuardDuty khong co truong Compliance nen bi loai het."
      echo "     Xem loi 40 doc 22."
      note ;;
    *)
      printf '   %-22s %s\n' "EventBridge rule" "$(amber 'khong loc Compliance')" ;;
  esac
fi
echo

########################################
# Ket luan
########################################

printf '%s\n' "$(grey '------------------------------------------------------------------------')"
if [ "$problems" -eq 0 ]; then
  green "Khong tim thay khoang trong."; echo
  echo
  cat <<'EOT'
NHUNG BON MUC TREN CHI HOI TUNG MAT XICH. Cho dut thuong nam o CHO NOI,
noi khong lenh describe-* nao soi toi. Phep thu duy nhat di het duong:

  aws guardduty create-sample-findings --detector-id <detector> \
    --finding-types 'CryptoCurrency:EC2/BitcoinTool.B!DNS' \
    --profile <security> --region <region>

Finding mau nay o muc HIGH nen nam trong bo loc severity.
Co email trong vai phut = ca chuoi song.
EOT
  echo
  exit 0
else
  red "$problems muc can xu ly."; echo
  echo
  grey "Doc lai cot THIEU o muc 2 truoc - mot account khong duoc giam sat"; echo
  grey "la mot cho ke tan cong o lai ma khong ai thay."; echo
  echo
  exit 1
fi
