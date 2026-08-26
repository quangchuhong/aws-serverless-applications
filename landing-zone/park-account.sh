#!/usr/bin/env bash
#
# Dua account vao OU Suspended (dong bang), va dua tro lai.
#
#   ./park-account.sh --list                    xem ai dang bi dong bang
#   ./park-account.sh lz-app-dev                dong bang mot account
#   ./park-account.sh 169873795883              bang ID cung duoc
#   ./park-account.sh --restore lz-app-dev      tha ra, ve dung OU cu
#
# VI SAO CO SCRIPT NAY: account AWS khong xoa duoc, chi dong duoc -
# va dong la quyet dinh khong lui duoc (90 ngay moi roi to chuc, email
# chay vinh vien). OU Suspended la duong o giua: account van ton tai,
# nhung SCP chan moi hanh dong.
#
# KHONG PHAI TERRAFORM, CO CHU DICH. Viec account nam o OU nao la
# trang thai VAN HANH, khong phai mo ta ha tang. Dua no vao Terraform
# nghia la moi lan park phai sua code + commit + apply, va bat ky ai
# chay apply voi tfvars cu se lang le keo account tro lai.
#
# Script doc trang thai THAT tu AWS chu khong doc terraform output -
# nen no dung ke ca khi state nam o may khac.
#
set -uo pipefail

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }
grey()  { printf '\033[90m%s\033[0m' "$*"; }

TAG_FROM="lz:parked-from"
TAG_AT="lz:parked-at"

MODE="park"
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --list)    MODE="list" ;;
    --restore) MODE="restore" ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^#//;s/^ //'; exit 0 ;;
    -*)
      printf '%s tham so khong hieu: %s\n' "$(red 'LOI')" "$arg" >&2
      exit 2
      ;;
    *)
      if [ -n "$TARGET" ]; then
        printf '%s chi nhan MOT account moi lan.\n' "$(red 'LOI')" >&2
        exit 2
      fi
      TARGET="$arg"
      ;;
  esac
done

########################################
# 1. Dung account chua?
#
# SCP khong bao gio ap len management account, nen park no la thao
# tac vo nghia - nhung no VAN CHAY va van doi cay OU. Chan tu day.
########################################

CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  printf '\n%s khong goi duoc sts:GetCallerIdentity. Kiem credential.\n\n' "$(red 'LOI')"
  exit 1
}

MGMT=$(aws organizations describe-organization \
  --query 'Organization.MasterAccountId' --output text 2>/dev/null) || {
  printf '\n%s khong doc duoc to chuc. Script nay chay tu MANAGEMENT account.\n\n' "$(red 'LOI')"
  exit 1
}

if [ "$CALLER" != "$MGMT" ]; then
  printf '\n%s dang o account %s, management la %s.\n' "$(red 'LOI')" "$CALLER" "$MGMT"
  printf '  Thu: unset AWS_PROFILE\n\n'
  exit 1
fi

ROOT=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

########################################
# 2. OU Suspended co that su dong bang khong?
#
# Truong hop nguy hiem nhat KHONG phai la thieu OU - la co OU ma
# khong co SCP. Khi do script chay tron, bao thanh cong, va account
# van chay binh thuong trong mot OU ten "Suspended". Kiem thuc te,
# khong tin vao ten.
########################################

SUS=$(aws organizations list-organizational-units-for-parent \
  --parent-id "$ROOT" \
  --query "OrganizationalUnits[?Name=='Suspended'].Id | [0]" \
  --output text 2>/dev/null)

if [ -z "$SUS" ] || [ "$SUS" = "None" ]; then
  printf '\n%s khong tim thay OU "Suspended" duoi root.\n' "$(red 'LOI')"
  printf '  Chay: cd organization && terraform apply\n\n'
  exit 1
fi

FROZEN=0
while IFS=$'\t' read -r pid pname; do
  [ -n "$pid" ] || continue
  [ "$pname" = "FullAWSAccess" ] && continue
  body=$(aws organizations describe-policy --policy-id "$pid" \
    --query 'Policy.Content' --output text 2>/dev/null)
  # jsonencode sap xep key theo alphabet -> "Action":"*" va
  # "Effect":"Deny" nam canh nhau trong cung mot statement.
  case "$body" in
    *'"Action":"*"'*) case "$body" in *'"Effect":"Deny"'*) FROZEN=1 ;; esac ;;
  esac
done < <(aws organizations list-policies-for-target --target-id "$SUS" \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].[Id,Name]' --output text 2>/dev/null)

if [ "$FROZEN" -eq 0 ]; then
  printf '\n%s OU Suspended (%s) TON TAI nhung KHONG co SCP chan gi ca.\n\n' \
    "$(red 'NGUY HIEM')" "$SUS"
  cat <<'EOT'
  Account chuyen vao day se chay BINH THUONG - va ten OU lam moi
  nguoi tuong nguoc lai. Do la kieu hong te nhat: im lang va nhin
  giong nhu da xong viec.

  Kiem hai thu o layer organization:
    enable_scp.suspended = true      (khong phai false)
    scp_dry_run          = false     (true thi tao policy ma khong gan)

  Roi: cd organization && terraform apply

EOT
  exit 1
fi

########################################
# 3. --list
########################################

if [ "$MODE" = "list" ]; then
  printf '\n  OU Suspended  %s  %s\n\n' "$(grey "$SUS")" "$(green 'dong bang: co')"

  found=0
  while IFS=$'\t' read -r aid aname astatus; do
    [ -n "$aid" ] || continue
    found=1
    from=$(aws organizations list-tags-for-resource --resource-id "$aid" \
      --query "Tags[?Key=='$TAG_FROM'].Value | [0]" --output text 2>/dev/null)
    at=$(aws organizations list-tags-for-resource --resource-id "$aid" \
      --query "Tags[?Key=='$TAG_AT'].Value | [0]" --output text 2>/dev/null)
    [ "$from" = "None" ] && from="$(amber 'khong nho OU cu')"
    [ "$at" = "None" ] && at=""
    printf '  %-14s %-18s %-10s %s %s\n' "$aid" "$aname" "$astatus" "$from" "$(grey "$at")"
  done < <(aws organizations list-accounts-for-parent --parent-id "$SUS" \
    --query 'Accounts[].[Id,Name,Status]' --output text 2>/dev/null)

  [ "$found" -eq 0 ] && printf '  %s\n' "$(grey 'khong co account nao')"
  printf '\n'
  exit 0
fi

########################################
# 4. Tim account
########################################

if [ -z "$TARGET" ]; then
  printf '\n%s thieu ten hoac ID account. Xem: ./park-account.sh --help\n\n' "$(red 'LOI')"
  exit 2
fi

case "$TARGET" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
    ACCT="$TARGET" ;;
  *)
    ACCT=$(aws organizations list-accounts \
      --query "Accounts[?Name=='$TARGET'].Id | [0]" --output text 2>/dev/null)
    if [ -z "$ACCT" ] || [ "$ACCT" = "None" ]; then
      printf '\n%s khong co account ten "%s".\n' "$(red 'LOI')" "$TARGET"
      printf '  Xem danh sach: aws organizations list-accounts --query %s\n\n' \
        "'Accounts[].[Id,Name]' --output table"
      exit 1
    fi ;;
esac

NAME=$(aws organizations describe-account --account-id "$ACCT" \
  --query 'Account.Name' --output text 2>/dev/null) || {
  printf '\n%s khong doc duoc account %s.\n\n' "$(red 'LOI')" "$ACCT"
  exit 1
}

if [ "$ACCT" = "$MGMT" ]; then
  printf '\n%s day la MANAGEMENT account.\n\n' "$(red 'TU CHOI')"
  printf '  SCP khong bao gio ap len management account, nen park no khong\n'
  printf '  dong bang duoc gi - chi lam cay OU sai di.\n\n'
  exit 1
fi

CUR=$(aws organizations list-parents --child-id "$ACCT" \
  --query 'Parents[0].Id' --output text)

########################################
# 5. --restore
########################################

if [ "$MODE" = "restore" ]; then
  if [ "$CUR" != "$SUS" ]; then
    printf '\n%s %s (%s) khong nam trong Suspended, dang o %s.\n\n' \
      "$(amber 'BO QUA:')" "$NAME" "$ACCT" "$CUR"
    exit 0
  fi

  BACK=$(aws organizations list-tags-for-resource --resource-id "$ACCT" \
    --query "Tags[?Key=='$TAG_FROM'].Value | [0]" --output text 2>/dev/null)

  if [ -z "$BACK" ] || [ "$BACK" = "None" ]; then
    printf '\n%s khong co tag %s - script khong biet OU cu.\n' "$(amber 'CANH BAO')" "$TAG_FROM"
    printf '  Se dua ve ROOT (%s). Account o root chi con SCP gan o root:\n' "$ROOT"
    printf '  mat network_lock va prod_guard ma van chay binh thuong.\n\n'
    printf '  Muon ve dung OU thi move tay:\n'
    printf '    aws organizations move-account --account-id %s \\\n' "$ACCT"
    printf '      --source-parent-id %s --destination-parent-id <ou-dich>\n\n' "$SUS"
    printf '  Go %s de dua ve root, hoac Ctrl-C: ' "$(amber 'root')"
    read -r ans
    [ "$ans" = "root" ] || { printf '  %s\n\n' "$(grey 'Huy.')"; exit 1; }
    BACK="$ROOT"
  fi

  aws organizations move-account --account-id "$ACCT" \
    --source-parent-id "$SUS" --destination-parent-id "$BACK" || exit 1

  aws organizations untag-resource --resource-id "$ACCT" \
    --tag-keys "$TAG_FROM" "$TAG_AT" >/dev/null 2>&1

  printf '\n  %s %s (%s) -> %s\n\n' "$(green 'Da tha:')" "$NAME" "$ACCT" "$BACK"
  printf '  SCP cua OU dich co hieu luc gan nhu ngay lap tuc, nhung phien\n'
  printf '  dang mo co the con dung quyet dinh cu vai phut.\n\n'
  exit 0
fi

########################################
# 6. Park
########################################

if [ "$CUR" = "$SUS" ]; then
  printf '\n%s %s (%s) da nam trong Suspended roi.\n\n' "$(amber 'BO QUA:')" "$NAME" "$ACCT"
  exit 0
fi

printf '\n%s sap dong bang %s (%s).\n\n' "$(red 'CANH BAO')" "$NAME" "$ACCT"
printf '  Tu %s  ->  Suspended %s\n\n' "$(grey "$CUR")" "$(grey "$SUS")"
cat <<'EOT'
  Sau buoc nay MOI hanh dong trong account bi tu choi. Ke ca:
    - don dep tai nguyen dang chay
    - doc log, xem cau hinh
    - pipeline hay backup dang chay theo lich

  SCP chan HANH DONG, khong tat may. Tai nguyen dang chay VAN TINH
  TIEN - va ban khong don duoc chung cho toi khi --restore.

  => Don sach TRUOC khi park. Kiem lai bang muc 4 cua TEARDOWN.md.

EOT
printf '  Go dung ID account %s de xac nhan: ' "$(amber "$ACCT")"
read -r ans
if [ "$ans" != "$ACCT" ]; then
  printf '  %s\n\n' "$(grey 'Huy.')"
  exit 1
fi

# Tag TRUOC khi move: doc parent hien tai roi ghi lai. Move truoc ma
# tag hong thi mat luon duong ve.
aws organizations tag-resource --resource-id "$ACCT" --tags \
  "Key=$TAG_FROM,Value=$CUR" \
  "Key=$TAG_AT,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)" || {
  printf '\n%s khong ghi duoc tag - dung lai, chua move gi ca.\n\n' "$(red 'LOI')"
  exit 1
}

aws organizations move-account --account-id "$ACCT" \
  --source-parent-id "$CUR" --destination-parent-id "$SUS" || {
  printf '\n%s move that bai. Go tag vua ghi.\n\n' "$(red 'LOI')"
  aws organizations untag-resource --resource-id "$ACCT" \
    --tag-keys "$TAG_FROM" "$TAG_AT" >/dev/null 2>&1
  exit 1
}

printf '\n  %s %s (%s)\n' "$(green 'Da dong bang:')" "$NAME" "$ACCT"
printf '  %s\n\n' "$(grey "OU cu da ghi vao tag $TAG_FROM=$CUR")"
printf '  Tha ra:  ./park-account.sh --restore %s\n' "$NAME"
printf '  Xem:     ./park-account.sh --list\n\n'
