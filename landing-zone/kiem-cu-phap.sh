#!/usr/bin/env bash
#
# Kiem lop loi cu phap ma `terraform fmt` KHONG thay.
#
# VI SAO CAN
#
# fmt chi kiem dinh dang. validate bat duoc nhieu hon, nhung no can
# `terraform init` - tuc can mang, provider, va o mot so moi truong la
# khong chay duoc. Nen co mot khoang giua: code fmt sach, va hong ngay
# o `terraform init`.
#
# Da xay ra: description cua mot output chua ${try(...)} va ${var.region}.
# fmt sach, va init chet voi bon loi khac nhau cho cung mot nguyen nhan:
#
#   Error: Variables not allowed
#   Error: Function calls not allowed
#   Error: Unsuitable value type - value must be known
#
# Terraform danh gia description cua variable va output o giai doan
# CHUA CO BIEN NAO. Cho can gia tri dong thi dat vao `value`, hoac vao
# mot local.
#
# Chay: ./kiem-cu-phap.sh

set -uo pipefail
cd "$(dirname "$0")" || exit 1

python3 - <<'PYEOF'
import re, sys, pathlib

loi = []
for f in sorted(pathlib.Path(".").rglob("*.tf")):
    if ".terraform" in str(f):
        continue
    lines = f.read_text().splitlines()
    trong_khoi = None
    sau = 0
    for i, ln in enumerate(lines, 1):
        m = re.match(r'\s*(variable|output)\s+"', ln)
        if m and trong_khoi is None:
            trong_khoi, sau = m.group(1), ln.count("{") - ln.count("}")
            continue
        if trong_khoi:
            sau += ln.count("{") - ln.count("}")
            if re.match(r'\s*description\s*=', ln):
                hd = re.search(r'<<-?(\w+)', ln)
                quet = []
                if hd:
                    ket = hd.group(1)
                    j = i
                    while j < len(lines) and lines[j].strip() != ket:
                        quet.append((j + 1, lines[j]))
                        j += 1
                else:
                    quet = [(i, ln)]
                for n, s in quet:
                    # $${...} la dau $ da escape - mot chuoi literal,
                    # khong phai noi suy. Bo qua truoc khi tim ${.
                    if "${" in s.replace("$${", ""):
                        loi.append((f, n, s.strip()))
            if sau <= 0:
                trong_khoi = None

if loi:
    print(f"  {len(loi)} dong noi suy trong description cua variable/output:")
    for f, n, s in loi:
        print(f"    {f}:{n}  {s[:76]}")
    print()
    print("  description duoc danh gia TRUOC khi co bien. Dat gia tri dong vao")
    print("  `value` hoac vao mot local.")
    sys.exit(1)
print("  Khong co noi suy trong description cua variable/output.")
PYEOF

