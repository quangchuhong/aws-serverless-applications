#!/usr/bin/env bash
#
# Bat/tat prevent_destroy tren moi layer thuong truc.
#
# VI SAO CAN SCRIPT NAY: prevent_destroy la lop chan DUY NHAT khong
# bien nao go duoc. Terraform khong cho dung bien trong khoi
# lifecycle - phai la hang so viet thang trong file. Moi lop chan
# con lai da gom vao bien allow_destroy.
#
#   ./unlock-destroy.sh                  xem trang thai hien tai
#   ./unlock-destroy.sh --unlock         true  -> false  (mo khoa)
#   ./unlock-destroy.sh --lock           false -> true   (khoa lai)
#   ./unlock-destroy.sh --unlock tf-backend org-trail    chi vai layer
#
# KHONG goi mot API AWS nao. prevent_destroy song hoan toan trong
# Terraform, nen mo khoa xong co the destroy NGAY, khong can apply
# xen giua. Khac han allow_destroy - bien do co phan doi that phia
# AWS (delete_protection cua firewall) nen BAT BUOC apply truoc.
#
# Doi thanh "false" chu khong xoa han khoi lifecycle: git diff nhin
# ra ngay, va --lock dao nguoc duoc chinh xac.
#
set -uo pipefail

cd "$(dirname "$0")"

LAYERS=(tf-backend organization control-tower config-detective org-trail account-baseline)

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }
grey()  { printf '\033[90m%s\033[0m' "$*"; }

MODE="status"
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --unlock) MODE="unlock" ;;
    --lock)   MODE="lock" ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^#//;s/^ //'
      exit 0
      ;;
    -*)
      printf '%s tham so khong hieu: %s\n' "$(red 'LOI')" "$arg" >&2
      exit 2
      ;;
    *) TARGETS+=("$arg") ;;
  esac
done

if [ ${#TARGETS[@]} -gt 0 ]; then
  for t in "${TARGETS[@]}"; do
    found=0
    for l in "${LAYERS[@]}"; do [ "$l" = "$t" ] && found=1; done
    if [ "$found" -eq 0 ]; then
      printf '%s layer "%s" khong co prevent_destroy. Co: %s\n' \
        "$(red 'LOI')" "$t" "${LAYERS[*]}" >&2
      exit 2
    fi
  done
  LAYERS=("${TARGETS[@]}")
fi

########################################
# Chi khop dong CHINH XAC la "  prevent_destroy = <bool>".
#
# Trong repo nay chuoi "prevent_destroy" con xuat hien trong comment
# va trong description cua bien - neo dau dong (^) va cuoi dong ($)
# de khong dung vao chung.
########################################
RE_TRUE='^([[:space:]]*)prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$'
RE_FALSE='^([[:space:]]*)prevent_destroy[[:space:]]*=[[:space:]]*false[[:space:]]*$'

count_in() {  # $1 = layer, $2 = regex -> so dong khop
  grep -rEc "$2" --include='*.tf' "$1" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}'
}

########################################
# Trang thai
########################################

n_true=0
n_false=0

printf '\n'
for l in "${LAYERS[@]}"; do
  t=$(count_in "$l" "$RE_TRUE")
  f=$(count_in "$l" "$RE_FALSE")
  n_true=$((n_true + t))
  n_false=$((n_false + f))

  printf '  %-18s ' "$l"
  if [ "$t" -gt 0 ] && [ "$f" -gt 0 ]; then
    printf '%s  %s khoa, %s mo\n' "$(amber 'MOT NUA')" "$t" "$f"
  elif [ "$t" -gt 0 ]; then
    printf '%s     %s prevent_destroy\n' "$(green 'KHOA')" "$t"
  elif [ "$f" -gt 0 ]; then
    printf '%s   %s prevent_destroy\n' "$(red 'MO KHOA')" "$f"
  else
    printf '%s\n' "$(grey '-')"
  fi
done
printf '\n'

if [ "$MODE" = "status" ]; then
  if [ "$n_false" -gt 0 ]; then
    printf '%s %s resource dang MO KHOA. Neu khong con teardown thi:\n' \
      "$(red '!')" "$n_false"
    printf '    ./unlock-destroy.sh --lock\n\n'
  fi
  printf '  --unlock de mo khoa, --lock de khoa lai\n\n'
  exit 0
fi

########################################
# Doi
########################################

if [ "$MODE" = "unlock" ]; then
  from="$RE_TRUE";  to='false'; n=$n_true
else
  from="$RE_FALSE"; to='true';  n=$n_false
fi

if [ "$n" -eq 0 ]; then
  printf '  %s khong co gi de doi.\n\n' "$(grey 'Bo qua:')"
  exit 0
fi

if [ "$MODE" = "unlock" ]; then
  printf '%s sap go %s lop chan cuoi cung tren %s layer.\n\n' \
    "$(red 'CANH BAO')" "$n" "${#LAYERS[@]}"
  cat <<'EOT'
  Sau buoc nay, "terraform destroy" o cac layer do se xoa that:
  bucket state, bucket CloudTrail, OU, va dang ky delegated admin.
  Khong co xac nhan nao nua.

  Ba thu KHONG lay lai duoc:
    - state cua moi layer (bucket tf-backend)
    - lich su CloudTrail va Config
    - email cua account da dong (chay vinh vien tren toan AWS)

EOT
  printf '  Go dung chu %s de tiep tuc: ' "$(amber 'unlock')"
  read -r ans
  if [ "$ans" != "unlock" ]; then
    printf '  %s\n\n' "$(grey 'Huy.')"
    exit 1
  fi
  printf '\n'
fi

changed=0
for l in "${LAYERS[@]}"; do
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # \1 giu nguyen thut dau dong cua file goc
    sed -i -E "s/$from/\\1prevent_destroy = $to/" "$file"
    hits=$(grep -Ec "^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*$to[[:space:]]*$" "$file")
    printf '  %-40s %s\n' "$file" "$(grey "-> $to  ($hits)")"
    changed=$((changed + 1))
  done < <(grep -rlE "$from" --include='*.tf' "$l" 2>/dev/null)
done

printf '\n  %s %s file.\n\n' "$(green 'Xong:')" "$changed"

if [ "$MODE" = "unlock" ]; then
  cat <<'EOT'
  Con lai:

    1. Bao ve phia AWS la bien RIENG, script nay khong cham toi:

         terraform apply -var allow_destroy=true    # RIENG mot lan

       Bat buoc voi layer network (delete_protection cua firewall goi
       API that). Voi bucket thi force_destroy phai nam trong state
       TRUOC khi destroy moi co tac dung.

    2. Destroy theo dung thu tu o TEARDOWN.md muc 1. Nguoc chieu
       dung, tf-backend CUOI CUNG.

    3. Doi y giua chung:

         ./unlock-destroy.sh --lock
         terraform apply -var allow_destroy=false

EOT
else
  printf '  Nho apply lai de dong not cong phia AWS:\n\n'
  printf '    terraform apply -var allow_destroy=false\n\n'
fi
