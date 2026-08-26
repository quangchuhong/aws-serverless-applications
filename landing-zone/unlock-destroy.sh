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
  from="$RE_TRUE";  from_bool='true';  to='false'; n=$n_true
else
  from="$RE_FALSE"; from_bool='false'; to='true';  n=$n_false
fi

if [ "$n" -eq 0 ]; then
  printf '  %s khong co gi de doi.\n\n' "$(grey 'Bo qua:')"
  exit 0
fi

if [ "$MODE" = "unlock" ]; then
  printf '%s sap go %s lop chan cuoi cung tren %s layer.\n\n' \
    "$(red 'CANH BAO')" "$n" "${#LAYERS[@]}"

  # Chi noi hau qua cua layer THAT SU duoc chon. Liet ke ca danh sach
  # khi nguoi ta mo mot layer la kieu canh bao ai cung hoc cach lo di.
  printf '  Sau buoc nay "terraform destroy" o cac layer duoi day se xoa that,\n'
  printf '  khong con xac nhan nao nua:\n\n'
  for l in "${LAYERS[@]}"; do
    case "$l" in
      tf-backend)
        printf '    %-18s bucket state - MOI layer khac mat dau vet resource\n' "$l" ;;
      organization)
        printf '    %-18s cay OU, SCP, dang ky delegated admin\n' "$l" ;;
      control-tower)
        printf '    %-18s account loi (chi go khoi state, account van con)\n' "$l" ;;
      config-detective)
        printf '    %-18s bucket log AWS Config - lich su khong khoi phuc duoc\n' "$l" ;;
      org-trail)
        printf '    %-18s bucket CloudTrail - bang chung kiem toan ca to chuc\n' "$l" ;;
      account-baseline)
        printf '    %-18s ban ghi account (account KHONG bi dong, chi roi state)\n' "$l" ;;
    esac
  done
  printf '\n'

  printf '  Go dung chu %s de tiep tuc: ' "$(amber 'unlock')"
  read -r ans
  if [ "$ans" != "unlock" ]; then
    printf '  %s\n\n' "$(grey 'Huy.')"
    exit 1
  fi
  printf '\n'
fi

########################################
# KHONG dung "sed -i".
#
# sed cua BSD (macOS) BAT BUOC co tham so hau to di kem -i, nen
# "sed -i -E" bi doc thanh "hau to = -E". Mat -E la mat che do ERE:
# dau ngoac thanh ky tu thuong, khong con nhom bat, va \1 o ve phai
# bao "not defined in the RE".
#
# Ghi ra file tam roi "cat >" de len file goc - chay giong het nhau
# tren GNU lan BSD, va giu nguyen inode cung quyen cua file goc
# (mv se thay bang quyen 600 cua mktemp).
########################################

count_line() {  # $1 = file, $2 = bool -> so dong khop
  grep -Ec "^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*$2[[:space:]]*$" "$1" 2>/dev/null || true
}

changed=0
files=0
failed=0

for l in "${LAYERS[@]}"; do
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    files=$((files + 1))

    before=$(count_line "$file" "${from_bool}")

    tmp=$(mktemp) || { printf '  %s khong tao duoc file tam\n' "$(red 'LOI')"; exit 1; }
    # \1 giu nguyen thut dau dong cua file goc
    if ! sed -E "s/$from/\\1prevent_destroy = $to/" "$file" > "$tmp"; then
      rm -f "$tmp"
      printf '  %-42s %s\n' "$file" "$(red 'sed that bai - file GIU NGUYEN')"
      failed=$((failed + 1))
      continue
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"

    after=$(count_line "$file" "$to")

    # Doi that su chua? Khong tin sed da chay la xong - doc lai file.
    if [ "$after" -lt "$before" ]; then
      printf '  %-42s %s\n' "$file" \
        "$(red "doi hut: mong $before dong -> $to, chi thay $after")"
      failed=$((failed + 1))
    else
      printf '  %-42s %s\n' "$file" "$(grey "$before dong -> $to")"
      changed=$((changed + before))
    fi
  done < <(grep -rlE "$from" --include='*.tf' "$l" 2>/dev/null)
done

printf '\n'

if [ "$failed" -gt 0 ]; then
  printf '  %s %s/%s file KHONG doi duoc. Kiem tra bang tay truoc khi destroy:\n' \
    "$(red 'THAT BAI:')" "$failed" "$files"
  printf '    grep -rn "prevent_destroy" --include=%s .\n\n' "'*.tf'"
  exit 1
fi

printf '  %s %s dong tren %s file.\n\n' "$(green 'Xong:')" "$changed" "$files"

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
