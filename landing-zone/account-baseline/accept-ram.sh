#!/usr/bin/env bash
#
# BUOC 3 CUA NAM BUOC: account moi chap nhan loi moi RAM.
#
# Xem README muc "Nam buoc, ba layer, va khong gop duoc".
#
# ---------------------------------------------------------------
# VI SAO CAN MOT SCRIPT CHO BA DONG LENH
#
# Vi ba dong do phai chay TRONG account khac, va cach lay credential
# vao account khac la cho de sai nhat trong ca quy trinh:
#
#   1. zsh an mat mot phan cua ARN.
#      "arn:aws:iam::$ID:role/..." -> zsh doc ":r" la MODIFIER cua
#      phep khai trien bien (bo phan mo rong ten file), nen ARN thanh
#      "arn:aws:iam::123456789012ole/...". Bash khong lam vay. Script
#      nay dung ${ID} co ngoac o moi cho.
#
#   2. Credential cua account con o lai trong shell.
#      export xong ma quen unset thi lenh terraform ke tiep chay bang
#      danh tinh cua mot account workload - va no se tao ha tang o
#      dung cho do. Da xay ra that mot lan trong du an nay: mot
#      Transit Gateway thu hai moc len o account management.
#
#      Script nay KHONG BAO GIO export gi. Moi lan goi AWS deu chay
#      trong mot moi truong rieng, nen shell cua ban khong doi.
#
# ---------------------------------------------------------------
# DUNG
#
#   ./accept-ram.sh 598122632665 913051689123
#   ./accept-ram.sh --tu-catalog          # lay ID tu terraform output
#
# Chay bang credential MANAGEMENT (hoac account co quyen assume
# OrganizationAccountAccessRole o cac account do).
########################################

set -u

REGION="${AWS_REGION:-ap-southeast-1}"
ROLE="${ORG_ROLE:-OrganizationAccountAccessRole}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

########################################
# Lay danh sach account
########################################
ids=()
if [ "${1:-}" = "--tu-catalog" ]; then
  if ! command -v terraform >/dev/null; then
    red "Khong co terraform trong PATH. Truyen thang account ID vao."
    exit 2
  fi
  # created_accounts la map ten -> { id, parent_id }
  #
  # GIU STDERR. Truoc day dong nay co 2>/dev/null, va moi nguyen nhan
  # deu cho ra CUNG MOT cau "Khong doc duoc output" - trong khi ba
  # nguyen nhan hay gap can ba cach sua khac han nhau. Do la loi 84
  # cua doc 22, lap lai lan thu tu.
  raw=$(terraform output -json created_accounts 2>&1) || {
    red "Khong doc duoc output created_accounts. Terraform noi:"
    printf '%s\n' "$raw" | sed 's/^/    /'
    echo
    echo "  Ba nguyen nhan hay gap:"
    echo
    echo "  1. Shell dang mang credential cua account KHAC."
    echo "     Layer nay doc state o bucket cua management. Vua chay lenh"
    echo "     o thu muc network xong thi rat de con AWS_* cua account mang."
    echo "       aws sts get-caller-identity --query Account --output text"
    echo "       unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"
    echo
    echo "  2. Chua init trong ban sao nay:"
    echo "       terraform init -backend-config=backend.hcl"
    echo
    echo "  3. Chua apply, hoac apply o thu muc khac."
    echo "     Dua thang account ID vao thay vi doc output:"
    echo "       $0 <account-id> <account-id>"
    exit 2
  }

  parsed=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.exit(f"khong phai JSON: {e}")
if not isinstance(d, dict):
    sys.exit(f"created_accounts khong phai mot map (nhan duoc {type(d).__name__})")
for name, a in d.items():
    if isinstance(a, dict) and a.get("id"):
        print(a["id"])
' 2>&1) || {
    red "Khong doc duoc noi dung created_accounts:"
    printf '%s\n' "$parsed" | sed 's/^/    /'
    exit 2
  }

  while IFS= read -r line; do
    [ -n "$line" ] && ids+=("$line")
  done <<EOF
$parsed
EOF

  if [ "${#ids[@]}" -eq 0 ]; then
    amber "created_accounts doc duoc nhung RONG - layer nay chua tao account nao."
    echo "  Dua thang account ID vao: $0 <account-id> ..."
    exit 2
  fi
  echo "Lay tu created_accounts: ${#ids[@]} account"
else
  if [ $# -eq 0 ]; then
    echo "Dung: $0 <account-id> [account-id ...]"
    echo "      $0 --tu-catalog"
    exit 2
  fi
  ids=("$@")
fi

########################################
# Danh tinh dang chay - in ra de khong ai doan
########################################
me=$(aws sts get-caller-identity --query Arn --output text 2>&1) || {
  red "Khong goi duoc sts:GetCallerIdentity:"
  echo "  $me"
  exit 1
}
me_acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

echo "Dang chay bang: $me"
echo "Account:        $me_acct"
echo "Region:         $REGION"
echo "Role assume:    $ROLE"

########################################
# DANH TINH PHAI O MANAGEMENT ACCOUNT
#
# OrganizationAccountAccessRole trong mot account moi co DUY NHAT mot
# principal duoc tin: management account cua to chuc. Do la trust
# policy AWS tu dat khi tao account, va no khong lien quan gi toi
# viec ban co quyen lon den dau o account khac.
#
# Kiem TRUOC khi thu, vi neu de assume-role tu bao loi thi thong bao
# la "AccessDenied ... is not authorized to perform: sts:AssumeRole" -
# mot cau doc nhu THIEU QUYEN, khien nguoi ta di cap them quyen cho
# chinh cai principal khong bao gio dung duoc. Van de khong phai
# quyen, ma la DUNG SAI ACCOUNT.
########################################
mgmt_acct=$(aws organizations describe-organization \
  --query 'Organization.MasterAccountId' --output text 2>/dev/null || true)

if [ -n "$mgmt_acct" ] && [ "$mgmt_acct" != "None" ]; then
  echo "Management:     $mgmt_acct"
  if [ "$me_acct" != "$mgmt_acct" ]; then
    echo
    red "SAI ACCOUNT. Dang o ${me_acct}, can ${mgmt_acct}."
    echo
    echo "  ${ROLE} trong account moi chi tin management account cua to chuc."
    echo "  Mot danh tinh o account khac KHONG assume duoc no, va loi tra ve la"
    echo "  'AccessDenied ... not authorized to perform: sts:AssumeRole' - doc nhu"
    echo "  thieu quyen, nhung cap them quyen o day khong sua duoc gi."
    echo
    echo "  Doi sang danh tinh o ${mgmt_acct} roi chay lai:"
    echo "    aws sso login   # hoac export credential cua management"
    echo "    aws sts get-caller-identity --query Account --output text"
    echo
    echo "  Buoc nay CHI can lam mot lan moi account. Cach khac, neu ban vao"
    echo "  duoc console cua tung account: RAM > Shared with me > Resource shares"
    echo "  > chon loi moi > Accept."
    exit 1
  fi
fi
echo

########################################
# Voi tung account
#
# MOI lenh AWS chay trong mot subshell rieng voi bien moi truong
# duoc dat NGAY TRUOC lenh do. Khong export ra shell cha.
########################################
n_ok=0
n_khong_co=0
n_loi=0

for ID in "${ids[@]}"; do
  printf '== %s  ' "$ID"

  # ${ID} co ngoac - xem chu thich ve zsh o dau file.
  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${ID}:role/${ROLE}" \
    --role-session-name lz-ram-accept \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>&1) || {
    red "assume-role that bai"
    printf '%s\n' "$creds" | sed 's/^/   /'
    case "$creds" in
      *AccessDenied*|*not\ authorized*)
        echo "   'AccessDenied' o day gan nhu luon la SAI ACCOUNT chu khong phai thieu quyen:"
        echo "   ${ROLE} chi tin management account. Xem dong 'Account:' o dau ra tren."
        ;;
      *NoSuchEntity*|*does\ not\ exist*)
        echo "   Account nay co the duoc MOI VAO to chuc chu khong phai tao boi to chuc -"
        echo "   truong hop do AWS khong tu tao ${ROLE}. Kiem:"
        echo "     aws organizations describe-account --account-id ${ID}"
        ;;
      *)
        echo "   Account vua tao co the chua san sang - doi vai phut roi chay lai."
        ;;
    esac
    n_loi=$((n_loi + 1))
    continue
  }

  # Tach ba truong. read -r ... <<< chay o ca bash lan zsh.
  AK=$(printf '%s' "$creds" | awk '{print $1}')
  SK=$(printf '%s' "$creds" | awk '{print $2}')
  ST=$(printf '%s' "$creds" | awk '{print $3}')

  if [ -z "$AK" ] || [ -z "$SK" ] || [ -z "$ST" ]; then
    red "assume-role tra ve thieu truong"
    n_loi=$((n_loi + 1))
    continue
  fi

  arn=$(AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
    aws ram get-resource-share-invitations --region "$REGION" \
    --query "resourceShareInvitations[?status=='PENDING'].resourceShareInvitationArn" \
    --output text 2>&1) || {
    red "khong doc duoc loi moi"
    echo "   $arn"
    n_loi=$((n_loi + 1))
    continue
  }

  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    # Khong co loi moi PENDING. Hai kha nang rat khac nhau - phan biet
    # bang cach hoi xem account nay co thay resource share nao khong.
    shares=$(AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
      aws ram get-resource-shares --region "$REGION" \
      --resource-owner OTHER-ACCOUNTS \
      --query 'resourceShares[].name' --output text 2>/dev/null)

    if [ -n "$shares" ] && [ "$shares" != "None" ]; then
      green "da nhan tu truoc (thay share: $shares)"
      n_ok=$((n_ok + 1))
    else
      amber "KHONG co loi moi nao"
      echo "   Nghia la buoc 2 chua chay: account nay chua nam trong"
      echo "   share_tgw_with_accounts cua layer network, hoac layer do"
      echo "   chua duoc apply sau khi them."
      n_khong_co=$((n_khong_co + 1))
    fi
    continue
  fi

  # Nhieu loi moi thi nhan het - moi dong mot ARN.
  for one in $arn; do
    st=$(AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
      aws ram accept-resource-share-invitation --region "$REGION" \
      --resource-share-invitation-arn "$one" \
      --query 'resourceShareInvitation.status' --output text 2>&1) || {
      red "accept that bai"
      echo "   $st"
      n_loi=$((n_loi + 1))
      continue 2
    }
    green "$st"
  done
  n_ok=$((n_ok + 1))
done

echo
echo "─────────────────────────────────────────────"
echo " $n_ok nhan duoc  |  $n_khong_co khong co loi moi  |  $n_loi loi"
echo "─────────────────────────────────────────────"

if [ "$n_khong_co" -gt 0 ]; then
  echo
  amber "Co account chua nhan duoc loi moi nao - do la BUOC 2, chua phai buoc 3."
  echo
  echo "  # landing-zone/network/terraform.tfvars"
  echo "  share_tgw_with_accounts = ["
  for ID in "${ids[@]}"; do echo "    \"${ID}\","; done
  echo "  ]"
  echo
  echo "  cd ../network && terraform apply"
fi

if [ "$n_ok" -gt 0 ]; then
  echo
  echo "Kiem tu phia chu so huu TGW (chay o account network):"
  echo "  cd ../network && ./verify.sh      # muc 6d"
fi

[ "$n_loi" -eq 0 ]
