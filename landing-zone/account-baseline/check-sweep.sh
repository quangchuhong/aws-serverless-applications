#!/usr/bin/env bash
#
# CURRENT KHONG PHAI LA "DA XOA".
#
# `list-stack-instances` tra ve CURRENT khi stack trien khai xong. No
# khong noi gi ve viec Lambda ben trong co xoa duoc default VPC hay
# khong - Lambda bat het loi va ghi ket qua vao output SweepResult,
# chinh de mot lan bi tu choi khong lam hong ca dot trien khai.
#
# Nen co hai cau hoi khac nhau, va script nay hoi ca hai:
#
#   1. Lambda BAO no lam duoc gi        -> output SweepResult
#   2. AWS noi hien gio con gi          -> describe-vpcs
#
# Cau thu hai moi la bang chung. Doc 22 loi 27: mot lop quet bao
# "khong tim thay gi" trong khi no vua xoa nam VPC that - ke lai
# chinh no khong du.
#
# ---------------------------------------------------------------
# DUNG
#
#   ./check-sweep.sh                      # moi account trong catalog
#   ./check-sweep.sh 913051689123 ...     # chi vai account
#
# Chay bang credential MANAGEMENT.
########################################

set -u

REGIONS="${SWEEP_REGIONS:-ap-southeast-1 us-east-1}"
ROLE="${ORG_ROLE:-OrganizationAccountAccessRole}"

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }

ids=()
if [ $# -gt 0 ]; then
  ids=("$@")
else
  raw=$(terraform output -json created_accounts 2>&1) || {
    echo "Khong doc duoc created_accounts. Terraform noi:"
    printf '%s\n' "$raw" | sed 's/^/    /'
    echo "Dua thang account ID vao: $0 <id> [<id> ...]"
    exit 2
  }
  while IFS= read -r line; do
    [ -n "$line" ] && ids+=("$line")
  done < <(printf '%s' "$raw" | python3 -c '
import json, sys
for name, a in json.load(sys.stdin).items():
    if isinstance(a, dict) and a.get("id"):
        print(a["id"])')
fi

me=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "Khong goi duoc sts:GetCallerIdentity."
  exit 1
}
mgmt=$(aws organizations describe-organization \
  --query 'Organization.MasterAccountId' --output text 2>/dev/null || true)
if [ -n "$mgmt" ] && [ "$mgmt" != "None" ] && [ "$me" != "$mgmt" ]; then
  echo "SAI ACCOUNT: dang o ${me}, can ${mgmt} (${ROLE} chi tin management)."
  exit 1
fi

echo "Region kiem: $REGIONS"
echo

n_ban=0
for ID in "${ids[@]}"; do
  printf '== %s\n' "$ID"

  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${ID}:role/${ROLE}" \
    --role-session-name kiem-sweep \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>&1) || {
    printf '   %s\n' "$(red 'assume-role that bai')"
    printf '%s\n' "$creds" | sed 's/^/     /'
    continue
  }
  AK=$(printf '%s' "$creds" | awk '{print $1}')
  SK=$(printf '%s' "$creds" | awk '{print $2}')
  ST=$(printf '%s' "$creds" | awk '{print $3}')
  run() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" aws "$@"; }

  # 1. Lambda TU KE
  #
  # Dau [] sau Outputs la BAT BUOC: khong co no, JMESPath tao mot
  # projection long va --output text in ra RONG - trong y het nhu
  # stack khong co output nao, trong khi output van o do.
  sw=$(run cloudformation describe-stacks --region "${REGIONS%% *}" \
    --query "Stacks[?contains(StackName,'account-baseline')].Outputs[] | [?OutputKey=='SweepResult'].OutputValue" \
    --output text 2>/dev/null)
  printf '   SweepResult: %s\n' "${sw:-（khong doc duoc）}"

  # 2. AWS NOI HIEN GIO CON GI - day moi la bang chung
  for R in $REGIONS; do
    n=$(run ec2 describe-vpcs --region "$R" \
      --filters Name=isDefault,Values=true \
      --query 'length(Vpcs)' --output text 2>/dev/null)
    case "${n:-loi}" in
      0) printf '   %-16s %s\n' "$R" "$(green 'khong con default VPC')" ;;
      loi|"")
        # Khong doc duoc KHAC voi "con VPC". Region bi khoa bang SCP
        # tra ve loi o day, va do la trang thai binh thuong.
        printf '   %-16s %s\n' "$R" "$(amber 'khong doc duoc - region bi khoa hoac thieu quyen')" ;;
      *)
        printf '   %-16s %s\n' "$R" "$(red "con ${n} default VPC")"
        n_ban=$((n_ban + 1)) ;;
    esac
  done
  echo
done

echo "─────────────────────────────────────────────"
if [ "$n_ban" -eq 0 ]; then
  echo " Khong region nao con default VPC."
else
  echo " CON $n_ban cho van co default VPC."
  echo
  echo " SKIP o region NGOAI allowed_regions la binh thuong: region_lock"
  echo " SCP tu choi ec2:DeleteVpc, va mot default VPC o region bi khoa"
  echo " la vo hai vi khong ai tao duoc gi trong do."
  echo
  echo " SKIP o region NAM TRONG allowed_regions thi moi la van de."
fi
echo "─────────────────────────────────────────────"

[ "$n_ban" -eq 0 ]
