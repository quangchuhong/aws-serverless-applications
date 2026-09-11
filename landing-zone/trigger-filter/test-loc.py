#!/usr/bin/env python3
"""Kiem lambda/loc.py. Khong can mang, khong can boto3 that.

    ./test-loc.py

=========================================================================
VI SAO PHAI CO BO KIEM NAY

loc.py dung GIUA su kien commit va MOI pipeline van hanh. Khi no sai theo
chieu "chan nham", khong co gi bao: pipeline khong chay trong giong het
khong co gi de chay. Mot loi o day khong lo ra o console, khong lo ra o
log ai doc, va co the nam do hang thang.

Nen ca hai chieu deu duoc kiem o day:

  chieu CHAN NHAM  - thay doi co lien quan ma pipeline khong chay
  chieu CHAY THUA  - chap nhan duoc, nhung van kiem de biet no chi xay ra
                     o duong fail-open chu khong phai moi luc

=========================================================================
BOTO3 GIA

Moi truong nay khong co boto3, va ke ca co thi goi AWS that trong mot bo
kiem cung sai. Nen sys.modules["boto3"] duoc dat TRUOC khi import loc.

Cai gia o day chi dung the: no tra ve dung nhung gi bai kiem dua vao, va
nem dung luc bai kiem bao nem. No KHONG bat chuoc API that - neu mot ngay
loc.py goi them API khac thi bo kiem nay se hong on ao, va do la dieu
mong muon.
"""

import json
import os
import sys
import types

# ---------------------------------------------------------------- gia


class KhachCodeCommit:
    def __init__(self):
        self.trang = []       # moi phan tu: list cua differences
        self.nem = None
        self.da_goi = []

    def get_paginator(self, ten):
        assert ten == "get_differences", ten
        return self

    def paginate(self, **kw):
        self.da_goi.append(kw)
        if self.nem:
            raise self.nem
        return [{"differences": d} for d in self.trang]


class KhachCodePipeline:
    def __init__(self):
        self.co_that = []
        self.nem_liet_ke = None
        self.nem_khi_khoi_dong = {}   # ten -> Exception
        self.da_khoi_dong = []

    def get_paginator(self, ten):
        assert ten == "list_pipelines", ten
        return self

    def paginate(self, **kw):
        if self.nem_liet_ke:
            raise self.nem_liet_ke
        return [{"pipelines": [{"name": n} for n in self.co_that]}]

    def start_pipeline_execution(self, name):
        if name in self.nem_khi_khoi_dong:
            raise self.nem_khi_khoi_dong[name]
        self.da_khoi_dong.append(name)


boto3_gia = types.ModuleType("boto3")
boto3_gia.client = lambda ten: None
sys.modules["boto3"] = boto3_gia

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lambda"))
import loc  # noqa: E402


# ---------------------------------------------------------------- khung

DIEM = [0, 0]


def su_kien(repo="kho", truoc="aaa", sau="bbb", nhanh="refs/heads/main"):
    d = {"repositoryName": repo, "commitId": sau, "referenceName": nhanh}
    if truoc is not None:
        d["oldCommitId"] = truoc
    if repo is None:
        d.pop("repositoryName")
    if sau is None:
        d.pop("commitId")
    return {"detail": d}


# Chot canh: `su_kien_ or su_kien()` coi su kien RONG la "khong truyen",
# nen bai kiem "su kien rong hoan toan" lang le chay tren su kien MAC
# DINH va dat vi mot ly do khac. Dung khuyet diem da ghi muoi lan trong
# du an - va lan nay no o trong chinh bo kiem di tim khuyet diem do.
KHONG_TRUYEN = object()


def chay(ban_do, doi=(), *, tien_to_phu="", co_that=None, nem_diff=None,
         nem_khoi_dong=None, nem_liet_ke=None, su_kien_=KHONG_TRUYEN, trang=None):
    """Dung mot lan goi handler. Tra ve (ket_qua, loi, da_khoi_dong)."""
    cc = KhachCodeCommit()
    cp = KhachCodePipeline()

    # Mac dinh: moi ten trong ban do deu co that o AWS. Bai kiem nao muon
    # kiem chieu "ten khong co that" thi truyen co_that.
    cp.co_that = list(ban_do) if co_that is None else co_that
    cp.nem_liet_ke = nem_liet_ke
    cp.nem_khi_khoi_dong = nem_khoi_dong or {}
    cc.trang = trang if trang is not None else [
        [{"afterBlob": {"path": p}} for p in doi]
    ]
    cc.nem = nem_diff

    loc.cc, loc.cp = cc, cp
    os.environ["BAN_DO"] = json.dumps(ban_do)
    os.environ["TIEN_TO_PHU"] = tien_to_phu

    try:
        sk = su_kien() if su_kien_ is KHONG_TRUYEN else su_kien_
        return loc.handler(sk, None), None, cp.da_khoi_dong
    except Exception as e:
        return None, f"{type(e).__name__}: {e}", cp.da_khoi_dong


def kiem(nhan, dieu_kien, chi_tiet=""):
    DIEM[bool(dieu_kien)] += 1
    print(f"  {'v' if dieu_kien else 'x'} {nhan}")
    if not dieu_kien and chi_tiet:
        print(f"      {chi_tiet}")


# ---------------------------------------------------------------- bai kiem

VENDING = "qh11-lz-vending"
OPS = "qh11-lz-ops"
PS = "qh11-lz-ops-permission-set"

BAN_DO = {
    VENDING: ["landing-zone/account-baseline/"],
    OPS: ["landing-zone/organization/"],
    PS: ["landing-zone/permission-sets/"],
}


def bai_ban_do_sai():
    print("\nBAN DO SAI - bon chieu, ca bon deu la loi cung")

    _, loi, chay_gi = chay({})
    kiem("ban do rong thi nem", loi and "BAN_DO rong" in loi, loi)
    kiem("  va khong khoi dong gi", chay_gi == [], chay_gi)

    _, loi, _ = chay({VENDING: []})
    kiem("tien to rong thi nem", loi and "tien to RONG" in loi, loi)

    # Cho nay quan trong: [] va [""] TRONG GIONG NHAU trong tfvars nhung
    # chay nguoc han nhau. [""] la "chay voi moi commit".
    r, loi, chay_gi = chay({VENDING: [""]}, doi=["bat/ky/dau.tf"])
    kiem('[""] nghia la chay voi moi thay doi', chay_gi == [VENDING], (loi, chay_gi))

    _, loi, chay_gi = chay(BAN_DO, co_that=[VENDING, OPS])
    kiem("ten khong co that o AWS thi nem", loi and PS in loi, loi)
    kiem("  va khong khoi dong gi ca", chay_gi == [], chay_gi)

    # Chieu nguy hiem nhat: pipeline co that, khong ai goi.
    _, loi, _ = chay(
        {VENDING: ["landing-zone/account-baseline/"]},
        co_that=[VENDING, OPS],
        tien_to_phu="qh11-lz-",
    )
    kiem("pipeline co that ma thieu trong ban do thi nem", loi and OPS in loi, loi)

    # Khong khai TIEN_TO_PHU thi phep kiem do phu tat - phai noi ro la
    # no TAT, chu khong phai no "khong tim thay gi".
    r, loi, _ = chay(
        {VENDING: ["landing-zone/account-baseline/"]},
        doi=["landing-zone/account-baseline/x.tf"],
        co_that=[VENDING, OPS],
    )
    kiem("khong khai TIEN_TO_PHU thi phep kiem do phu tat", loi is None, loi)


def bai_loc_dung():
    print("\nLOC DUNG - cau hoi goc: push gi thi vending chay")

    r, loi, chay_gi = chay(BAN_DO, doi=["landing-zone/organization/scp.tf"])
    kiem("doi organization: ops chay", chay_gi == [OPS], (loi, chay_gi))
    kiem("doi organization: vending KHONG chay", VENDING not in chay_gi, chay_gi)

    r, loi, chay_gi = chay(
        BAN_DO, doi=["landing-zone/account-baseline/main.tf"]
    )
    kiem("doi account-baseline: vending chay", chay_gi == [VENDING], (loi, chay_gi))

    r, loi, chay_gi = chay(BAN_DO, doi=["docs/22-Nhat-ky.md"])
    kiem("doi docs: khong pipeline nao chay", chay_gi == [], chay_gi)
    kiem("  va do la ket luan, khong phai loi", loi is None, loi)

    r, loi, chay_gi = chay(
        BAN_DO,
        doi=["landing-zone/account-baseline/a.tf", "landing-zone/organization/b.tf"],
    )
    kiem("mot commit cham hai vung: ca hai chay",
         sorted(chay_gi) == sorted([OPS, VENDING]), chay_gi)

    # Tien to la tien to CHUOI, khong phai thu muc. "account-baseline/"
    # co dau / o cuoi nen khong bat nham "account-baseline-cu/".
    r, loi, chay_gi = chay(
        BAN_DO, doi=["landing-zone/account-baseline-cu/main.tf"]
    )
    kiem("thu muc ten gan giong KHONG bat nham", chay_gi == [], chay_gi)

    # Doi ten mot file cham ca beforeBlob lan afterBlob.
    r, loi, chay_gi = chay(
        BAN_DO,
        trang=[[{
            "beforeBlob": {"path": "landing-zone/organization/cu.tf"},
            "afterBlob": {"path": "landing-zone/permission-sets/moi.tf"},
        }]],
    )
    kiem("doi ten qua vung: ca hai pipeline chay",
         sorted(chay_gi) == sorted([OPS, PS]), chay_gi)

    # Phan trang: bo sot trang thu hai la bo sot mot pipeline.
    r, loi, chay_gi = chay(
        BAN_DO,
        trang=[
            [{"afterBlob": {"path": "landing-zone/organization/a.tf"}}],
            [{"afterBlob": {"path": "landing-zone/account-baseline/b.tf"}}],
        ],
    )
    kiem("doc het moi trang cua GetDifferences",
         sorted(chay_gi) == sorted([OPS, VENDING]), chay_gi)


def bai_fail_open():
    print("\nFAIL OPEN - hong thi chay, khong phai hong thi thoi")

    r, loi, chay_gi = chay(BAN_DO, nem_diff=RuntimeError("het gio"))
    kiem("GetDifferences hong: khoi dong MOI pipeline",
         sorted(chay_gi) == sorted(BAN_DO), chay_gi)
    kiem("  va bao la KHONG loc duoc", r and r["loc"] is False, r)

    r, loi, chay_gi = chay(BAN_DO, su_kien_=su_kien(truoc=None))
    kiem("khong co oldCommitId: chay het", sorted(chay_gi) == sorted(BAN_DO), chay_gi)

    r, loi, chay_gi = chay(BAN_DO, su_kien_=su_kien(repo=None))
    kiem("thieu repositoryName: chay het", sorted(chay_gi) == sorted(BAN_DO), chay_gi)

    r, loi, chay_gi = chay(BAN_DO, su_kien_={})
    kiem("su kien rong hoan toan: chay het", sorted(chay_gi) == sorted(BAN_DO), chay_gi)

    # Diff RONG that su khac hoan toan voi diff DOC KHONG DUOC. Cai dau
    # la mot cau tra loi, cai sau la khong co cau tra loi nao.
    r, loi, chay_gi = chay(BAN_DO, doi=[])
    kiem("diff rong KHONG phai fail-open", chay_gi == [] and r["loc"] is True, (r, chay_gi))


def bai_khoi_dong_hong():
    print("\nKHOI DONG HONG - mot ten hong khong duoc chan nhung ten dung")

    r, loi, chay_gi = chay(
        BAN_DO,
        doi=["landing-zone/account-baseline/a.tf", "landing-zone/organization/b.tf"],
        nem_khoi_dong={OPS: RuntimeError("ThrottlingException")},
    )
    kiem("pipeline con lai VAN duoc khoi dong", chay_gi == [VENDING], chay_gi)
    kiem("  va Lambda bao hong (raise)", loi and "ThrottlingException" in loi, loi)

    # Thu tu goi la thu tu sap xep, nen bai kiem tren khong phu thuoc
    # vao viec OPS dung truoc hay sau VENDING trong dict.
    kiem("thu tu khoi dong la thu tu sap xep",
         sorted(BAN_DO) == [OPS, PS, VENDING], sorted(BAN_DO))


def bai_liet_ke_hong():
    print("\nLIET KE PIPELINE HONG - hai phep kiem tat, phan con lai van chay")

    r, loi, chay_gi = chay(
        BAN_DO,
        doi=["landing-zone/organization/a.tf"],
        nem_liet_ke=RuntimeError("AccessDenied"),
    )
    kiem("khong liet ke duoc thi van loc binh thuong", chay_gi == [OPS], (loi, chay_gi))

    # Nhung phep kiem KHONG can AWS thi van phai chay.
    _, loi, _ = chay({}, nem_liet_ke=RuntimeError("AccessDenied"))
    kiem("ban do rong van bi bat du khong liet ke duoc",
         loi and "BAN_DO rong" in loi, loi)


def main():
    for b in (bai_ban_do_sai, bai_loc_dung, bai_fail_open,
              bai_khoi_dong_hong, bai_liet_ke_hong):
        b()

    print(f"\n  {DIEM[1]}/{DIEM[0] + DIEM[1]} dat, {DIEM[0]} hong")
    return 1 if DIEM[0] else 0


if __name__ == "__main__":
    sys.exit(main())
