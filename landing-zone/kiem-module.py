#!/usr/bin/env python3
"""Kiem khop giua module tf-pipeline va caller cua no.

VI SAO CAN, KHI DA CO `terraform validate`

validate bat het nhung thu duoi day - nhung no doi provider tai duoc tu
registry.terraform.io. Trong moi truong bi chan mang (va trong mot CI
khong co quyen ra ngoai) thi khong chay duoc, va luc do thu duy nhat con
lai la doc bang mat.

File nay kiem sau thu, khong can mang:

  1. dung var.X ma khong khai
  2. module khai var khong ai dung
  3. caller truyen input ma module khong co
  4. bien module BAT BUOC ma caller khong truyen
  5. caller doc module.pipeline.X ma module khong xuat
  6. dung local.X ma khong khai

DUONG TINH GIA LA KE THU O DAY: mot bo kiem hay bao sai se bi bo qua, va
luc do no khong bat duoc cai that. Nen no bo CHU THICH va HEREDOC (van
xuoi) truoc khi doc, va GIU chuoi thuong - noi suy Terraform nam trong
chuoi, nen strip chung se lam moi ${var.x} bien mat.

Doi lai: van xuoi trong chuoi MOT DONG van bi doc thanh tham chieu. Cach
chua khong phai noi bo kiem, ma la viet van xuoi khong mang tien to
`var.` - dung "bien tag_policy_keys" thay vi "var.tag_policy_keys".
"""

import os, re, glob, sys

# Duong dan tinh tu GOC REPO, khong tu thu muc dang dung: chay tu cho
# khac thi glob ra RONG, va mot bo kiem tren 0 file se bao "khop het".
GOC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M = os.path.join(GOC, 'modules/tf-pipeline')
C = os.path.join(GOC, 'landing-zone/ops-pipeline')

def boc(t):
    """Bo CHU THICH va HEREDOC (van xuoi). GIU chuoi thuong - noi suy
    Terraform nam trong chuoi, nen strip chung se lam moi `${var.x}` bien
    mat va bao dung-khong-khai thanh khai-khong-dung."""
    t = re.sub(r'#[^\n]*', '', t)
    t = re.sub(r'<<-?EOT.*?\n\s*EOT', '""', t, flags=re.S)
    return t

def doc(d, tru=()):
    return "".join(open(f).read() for f in sorted(glob.glob(d+'/*.tf'))
                   if f.split('/')[-1] not in tru)

def locals_khai(raw):
    """MOI khoi locals, khong chi khoi dau - module co locals o ca
    codebuild.tf va main.tf."""
    ra=set()
    for m in re.finditer(r'^locals \{(.*?)^\}', raw, re.S|re.M):
        ra |= set(re.findall(r'^\s{2}([a-z_]+)\s*=', m.group(1), re.M))
    return ra

mt_raw, ct_raw = doc(M), doc(C, tru=('moved.tf',))

# CHOT CHAN: 0 file KHONG phai "khong co gi sai".
#
# Truoc ban nay, chay script tu mot thu muc khac lam glob ra rong, va bo
# kiem chay het 6 phep tren chuoi rong roi in "Khop het". Dung khuyet
# diem da lap muoi lan trong du an nay, lan nay trong chinh cong cu kiem.
for ten, d, raw in (('module', M, mt_raw), ('caller', C, ct_raw)):
    if not raw.strip():
        print(f"  LOI  khong doc duoc file .tf nao o {ten}: {d}")
        print("       Day KHONG phai 'khong co gi sai' - la CHUA DOC DUOC.")
        sys.exit(1)
mt, ct = boc(mt_raw), boc(ct_raw)
khai=lambda t:set(re.findall(r'variable "([a-z_]+)"', t))
dung=lambda t:set(re.findall(r'\bvar\.([a-z_]+)', t))
outs=lambda t:set(re.findall(r'output "([a-z_]+)"', t))
loi=[]

for ten,raw,cl in (('module',mt_raw,mt),('caller',ct_raw,ct)):
    if dung(cl)-khai(raw): loi.append(f"{ten}: dung var khong khai: {sorted(dung(cl)-khai(raw))}")
    thieu_lc = set(re.findall(r'\blocal\.([a-z_]+)', cl)) - locals_khai(raw)
    if locals_khai(raw) and thieu_lc:
        loi.append(f"{ten}: dung local khong khai: {sorted(thieu_lc)}")
if khai(mt_raw)-dung(mt): loi.append(f"module: khai var khong dung: {sorted(khai(mt_raw)-dung(mt))}")

blk = re.search(r'module "pipeline" \{(.*?)\n\}', ct_raw, re.S).group(1)
truyen = set(re.findall(r'^\s{2}([a-z_]+)\s*=', blk, re.M)) - {'source'}
if truyen-khai(mt_raw): loi.append(f"caller truyen input module khong co: {sorted(truyen-khai(mt_raw))}")

bat_buoc={m.group(1) for m in re.finditer(r'variable "([a-z_]+)" \{(.*?)\n\}\n', mt_raw, re.S)
          if not re.search(r'^\s+default\s*=', m.group(2), re.M)}
if bat_buoc-truyen: loi.append(f"bien module BAT BUOC ma caller khong truyen: {sorted(bat_buoc-truyen)}")

ref=set(re.findall(r'module\.pipeline\.([a-z_]+)', ct))
if ref-outs(mt_raw): loi.append(f"caller doc output module khong co: {sorted(ref-outs(mt_raw))}")

print(f"module: {len(khai(mt_raw))} bien ({len(bat_buoc)} bat buoc), {len(outs(mt_raw))} output, {len(locals_khai(mt_raw))} local")
print(f"caller: truyen {len(truyen)} input, {len(locals_khai(ct_raw))} local")
if loi: print("\n".join("  LOI  "+l for l in loi)); sys.exit(1)
print("  Khop het: bien, input, output, local - o ca module va caller.")
