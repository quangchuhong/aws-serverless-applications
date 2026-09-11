#!/usr/bin/env python3
"""Kiem khop giua module tf-pipeline va MOI caller cua no.

    ./kiem-module.py                 # tu tim moi caller
    ./kiem-module.py <thu-muc> ...   # chi kiem nhung caller da neu

=========================================================================
VI SAO CAN, KHI DA CO `terraform validate`

validate bat het nhung thu duoi day - nhung no doi provider tai duoc tu
registry.terraform.io. Trong moi truong bi chan mang (va trong mot CI
khong co quyen ra ngoai) thi khong chay duoc, va luc do thu duy nhat con
lai la doc bang mat.

Bay phep kiem, khong can mang:

  1. dung var.X ma khong khai
  2. module khai var khong ai dung
  3. caller truyen input ma module khong co
  4. bien module BAT BUOC ma caller khong truyen
  5. caller doc module.pipeline.X ma module khong xuat
  6. dung local.X ma khong khai
  7. bien module dung type = list(any)

Phep thu 7 la mot bai hoc duoc ma hoa: list(any) buoc MOI phan tu cung
mot type, va IAM statement thi luon khac hinh - mot cai co Condition, cai
khac khong. Thong bao khi vuong noi ve "list", khong noi ve IAM. Loi 117.

=========================================================================
DUONG TINH GIA LA KE THU O DAY

Mot bo kiem hay bao sai se bi bo qua, va luc do no khong bat duoc cai
that. Nen no bo CHU THICH va HEREDOC (van xuoi) truoc khi doc, va GIU
chuoi thuong - noi suy Terraform nam trong chuoi, nen strip chung se lam
moi ${var.x} bien mat.

Doi lai: van xuoi trong chuoi MOT DONG van bi doc thanh tham chieu. Cach
chua khong phai noi bo kiem, ma la viet van xuoi khong mang tien to
`var.` - dung "bien tag_policy_keys" thay vi "var.tag_policy_keys".

=========================================================================
BA LAN CHINH BO KIEM NAY TU SAI, ca ba dung dang khuyet diem cua du an

  chay tu thu muc khac -> glob RONG -> chay 7 phep tren chuoi rong roi
    in "Khop het". Chua: neo duong dan vao goc repo + chot chan 0 file.
  strip ca chuoi thuong -> moi ${var.x} bien mat -> bao "khai khong
    dung" tren 7 bien dang dung.
  bat `locals {` DAU TIEN (o codebuild.tf) -> moi local cua main.tf
    thanh "khong khai". Chua: doc MOI khoi locals.

Va mot lan thu tu, o chinh cho tim caller: ten thu muc duoc viet cung
thanh mot caller duy nhat, nen khi co them bon caller nua thi bo kiem van
in "Khop het" - tren mot caller. Gio no tim theo NOI DUNG (`source` tro
vao modules/tf-pipeline), khong theo ten.
"""

import glob
import os
import re
import sys

GOC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M = os.path.join(GOC, "modules/tf-pipeline")


def tim_caller():
    """Moi thu muc co file .tf tro vao modules/tf-pipeline."""
    ra = []
    for d in sorted(glob.glob(os.path.join(GOC, "landing-zone/*"))):
        if not os.path.isdir(d):
            continue
        for f in glob.glob(os.path.join(d, "*.tf")):
            # Khop vao `source = ".../modules/tf-pipeline"`, KHONG khop
            # cum tu tran. tf-backend/outputs.tf co nhac ten module trong
            # mot chu thich, va khop van ban tran da keo no vao danh sach
            # caller - lan thu ba trong mot ngay mot phep khop doc trung
            # van xuoi.
            if re.search(r'source\s*=\s*"[^"]*modules/tf-pipeline"', open(f).read()):
                ra.append(d)
                break
    return ra


def boc(t):
    """Bo CHU THICH va HEREDOC. GIU chuoi thuong - xem docstring."""
    t = re.sub(r"#[^\n]*", "", t)
    t = re.sub(r"<<-?EOT.*?\n\s*EOT", '""', t, flags=re.S)
    return t


def doc(d, tru=()):
    return "".join(
        open(f).read()
        for f in sorted(glob.glob(os.path.join(d, "*.tf")))
        if os.path.basename(f) not in tru
    )


def locals_khai(raw):
    """MOI khoi locals, khong chi khoi dau."""
    ra = set()
    for m in re.finditer(r"^locals \{(.*?)^\}", raw, re.S | re.M):
        ra |= set(re.findall(r"^\s{2}([a-z_]+)\s*=", m.group(1), re.M))
    return ra


khai = lambda t: set(re.findall(r'variable "([a-z_]+)"', t))
dung = lambda t: set(re.findall(r"\bvar\.([a-z_]+)", t))
outs = lambda t: set(re.findall(r'output "([a-z_]+)"', t))
lc = lambda t: set(re.findall(r"\blocal\.([a-z_]+)", t))


def kiem_module(mt_raw, mt):
    loi = []
    if dung(mt) - khai(mt_raw):
        loi.append(f"module: dung var khong khai: {sorted(dung(mt) - khai(mt_raw))}")
    if khai(mt_raw) - dung(mt):
        loi.append(f"module: khai var khong dung: {sorted(khai(mt_raw) - dung(mt))}")
    if lc(mt) - locals_khai(mt_raw):
        loi.append(f"module: dung local khong khai: {sorted(lc(mt) - locals_khai(mt_raw))}")

    # 7. list(any) - xem docstring.
    for m in re.finditer(r'variable "([a-z_]+)" \{(.*?)\n\}\n', mt_raw, re.S):
        if re.search(r"^\s+type\s*=\s*list\(any\)", m.group(2), re.M):
            loi.append(
                f"module: var.{m.group(1)} dung type = list(any) - buoc moi phan tu "
                "cung mot type. Dung `any` neu cac phan tu khac hinh (IAM statement)."
            )
    return loi


def kiem_caller(C, mt_raw, ten_caller):
    ct_raw = doc(C, tru=("moved.tf",))
    if not ct_raw.strip():
        return [f"{ten_caller}: khong doc duoc file .tf nao. KHONG phai 'khong co gi sai' - la CHUA DOC DUOC."]

    ct = boc(ct_raw)
    loi = []

    if dung(ct) - khai(ct_raw):
        loi.append(f"{ten_caller}: dung var khong khai: {sorted(dung(ct) - khai(ct_raw))}")
    if lc(ct) - locals_khai(ct_raw):
        loi.append(f"{ten_caller}: dung local khong khai: {sorted(lc(ct) - locals_khai(ct_raw))}")

    m = re.search(r'module "pipeline" \{(.*?)\n\}', ct_raw, re.S)
    if not m:
        return loi + [f'{ten_caller}: khong tim thay khoi module "pipeline"']
    truyen = set(re.findall(r"^\s{2}([a-z_]+)\s*=", m.group(1), re.M)) - {"source"}

    if truyen - khai(mt_raw):
        loi.append(f"{ten_caller}: truyen input module khong co: {sorted(truyen - khai(mt_raw))}")

    bat_buoc = {
        x.group(1)
        for x in re.finditer(r'variable "([a-z_]+)" \{(.*?)\n\}\n', mt_raw, re.S)
        if not re.search(r"^\s+default\s*=", x.group(2), re.M)
    }
    if bat_buoc - truyen:
        loi.append(f"{ten_caller}: bien module BAT BUOC ma khong truyen: {sorted(bat_buoc - truyen)}")

    ref = set(re.findall(r"module\.pipeline\.([a-z_]+)", ct))
    if ref - outs(mt_raw):
        loi.append(f"{ten_caller}: doc output module khong co: {sorted(ref - outs(mt_raw))}")

    return loi


def main():
    callers = sys.argv[1:] or tim_caller()

    mt_raw = doc(M)
    if not mt_raw.strip():
        print(f"  LOI  khong doc duoc file .tf nao o module: {M}")
        print("       Day KHONG phai 'khong co gi sai' - la CHUA DOC DUOC.")
        return 1

    # CHOT CHAN: 0 caller khong phai "moi caller deu khop".
    if not callers:
        print("  LOI  khong tim thay caller nao cua modules/tf-pipeline.")
        print("       Day KHONG phai 'khong co gi sai' - la CHUA TIM DUOC.")
        return 1

    mt = boc(mt_raw)
    loi = kiem_module(mt_raw, mt)
    print(f"module: {len(khai(mt_raw))} bien, {len(outs(mt_raw))} output, {len(locals_khai(mt_raw))} local")

    for C in callers:
        ten = os.path.basename(C.rstrip("/"))
        l = kiem_caller(C, mt_raw, ten)
        print(f"  {'x' if l else 'v'} {ten}")
        loi += l

    print()
    if loi:
        print("\n".join("  LOI  " + x for x in loi))
        return 1
    print(f"  Khop het: module + {len(callers)} caller.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
