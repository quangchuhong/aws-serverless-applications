#!/usr/bin/env python3
"""Test cong chan gate.py.

=========================================================================
FIXTURE VIET BANG TAY - KHONG SINH TU BANG LUAT

Day la dieu quan trong nhat ve file nay. Neu fixture duoc sinh ra tu
LUAT trong gate.py thi no mang dung nhung gia dinh ma gate.py mang, va
moi test se xanh ke ca khi ca hai cung sai. Do la loi 115 trong doc 22:
22 test xanh tren mot loi that, vi ban chup duoc dung tu cung nguon voi
code can kiem.

Nen moi fixture duoi day la mot ban plan viet tay, va ket qua mong doi
duoc khai bao boi NGUOI viet test, khong tra cuu tu LUAT.

=========================================================================
DIEU CAN CHUNG MINH NHAT: CHIEU KHONG DOI XUNG

    XOA mot policy attachment  -> NOI
    XOA mot account assignment -> SACH
    TAO mot account assignment -> NOI
    TAO mot policy attachment  -> SACH

Bon dong tren la bon test rieng. Mot cong chan chi biet "co thay doi hay
khong" se trot ca bon, va no se trot trong im lang.
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "gate.py")

R = "\033[31m"
G = "\033[32m"
N = "\033[0m"

dat = 0
truot = 0


def rc(address, type_, actions, before=None, after=None):
    """Mot muc resource_changes, viet tay."""
    return {
        "address": address,
        "type": type_,
        "change": {"actions": actions, "before": before, "after": after},
    }


def plan(*changes):
    return {"format_version": "1.2", "resource_changes": list(changes)}


def chay(ten, mong, noi_dung, stage="sec-scp", loosen=None, strict=False):
    """noi_dung = dict plan, hoac chuoi tho, hoac None de khong tao file."""
    global dat, truot
    d = tempfile.mkdtemp()
    p = os.path.join(d, "tfplan.json")

    if noi_dung is not None:
        with open(p, "w") as f:
            if isinstance(noi_dung, str):
                f.write(noi_dung)
            else:
                json.dump(noi_dung, f)

    cmd = [sys.executable, GATE, "--plan", p, "--layer", "thu", "--stage", stage]
    if loosen is not None:
        lp = os.path.join(d, "ops-loosen.yaml")
        with open(lp, "w") as f:
            f.write(loosen)
        cmd += ["--loosen", lp]
    if strict:
        cmd += ["--strict"]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == mong:
        print(f"  {G}v{N} {ten}  (thoat {r.returncode})")
        dat += 1
    else:
        print(f"  {R}x{N} {ten}  (thoat {r.returncode}, mong doi {mong})")
        for line in (r.stdout + r.stderr).splitlines():
            print("        " + line)
        truot += 1


NO_OP = rc("aws_organizations_policy.scp[\"baseline\"]",
           "aws_organizations_policy", ["no-op"])

KHAI_DU = """
loosen:
  - address: aws_organizations_policy_attachment.scp["baseline|ROOT"]
    ticket: SEC-1
    reason: go thu nghiem
    approved_by: a@b.c
"""

print()
print("════════════════════════════════════════════")
print(" Test cong chan van hanh")
print("════════════════════════════════════════════")
print()
print("── Doc duoc hay khong doc duoc ──")

chay("khong co thay doi gi        -> sach", 0, plan(NO_OP))

# Do tren ban plan THAT cua layer organization: mot plan khong co thay
# doi van liet ke du 25 muc voi actions ["no-op"]. Nen rong KHONG phai
# "sach" - la chua doc duoc.
chay("resource_changes RONG      -> thoat 1", 1,
     {"format_version": "1.2", "resource_changes": []})
chay("thieu han resource_changes -> thoat 1", 1, {"format_version": "1.2"})
chay("khong co file plan         -> thoat 1", 1, None)
chay("file khong phai JSON       -> thoat 1", 1, "day khong phai json")

print()
print("── CHIEU: xoa guardrail la NOI, xoa mot quyen la THAT ──")

XOA_ATTACH = rc('aws_organizations_policy_attachment.scp["baseline|ROOT"]',
                "aws_organizations_policy_attachment", ["delete"],
                before={"policy_id": "p-1", "target_id": "r-1"}, after=None)

chay("XOA policy attachment      -> NOI, thoat 1", 1, plan(NO_OP, XOA_ATTACH))

chay("XOA co khai bao day du     -> sach", 0, plan(NO_OP, XOA_ATTACH),
     loosen=KHAI_DU)

chay("khai bao thieu approved_by -> thoat 1", 1, plan(NO_OP, XOA_ATTACH),
     loosen="""
loosen:
  - address: aws_organizations_policy_attachment.scp["baseline|ROOT"]
    ticket: SEC-1
    reason: go thu nghiem
""")

# TAO mot attachment la gan THEM mot guardrail - THAT, khong can khai.
chay("TAO policy attachment      -> sach", 0, plan(NO_OP,
     rc('aws_organizations_policy_attachment.scp["x|Sandbox"]',
        "aws_organizations_policy_attachment", ["create"],
        before=None, after={"policy_id": "p-1", "target_id": "ou-2"})))

print()
print("── CHIEU NGUOC cua permission-set ──")
print("   (sao chep luat SCP sang day se trot ca bon test nay)")

TAO_GAN = rc('aws_ssoadmin_account_assignment.this["g|ps|111"]',
             "aws_ssoadmin_account_assignment", ["create"],
             before=None, after={"target_id": "111122223333"})

chay("TAO account assignment     -> NOI, thoat 1", 1,
     plan(NO_OP, TAO_GAN), stage="cloudops-permission-set")

# Va chieu con lai: bo mot assignment la THU HOI quyen - THAT.
chay("XOA account assignment     -> sach", 0, plan(NO_OP,
     rc('aws_ssoadmin_account_assignment.this["g|ps|111"]',
        "aws_ssoadmin_account_assignment", ["delete"],
        before={"target_id": "111122223333"}, after=None)),
     stage="cloudops-permission-set")

chay("TAO group membership       -> NOI, thoat 1", 1, plan(NO_OP,
     rc('aws_identitystore_group_membership.this["a|b"]',
        "aws_identitystore_group_membership", ["create"],
        before=None, after={"member_id": "u-1"})),
     stage="cloudops-permission-set")

chay("XOA group membership       -> sach", 0, plan(NO_OP,
     rc('aws_identitystore_group_membership.this["a|b"]',
        "aws_identitystore_group_membership", ["delete"],
        before={"member_id": "u-1"}, after=None)),
     stage="cloudops-permission-set")

print()
print("── THAY THE: xoa roi tao lai, ke ca khi ket qua giong het ──")

chay("THAY THE attachment        -> NOI, thoat 1", 1, plan(NO_OP,
     rc('aws_organizations_policy_attachment.scp["baseline|ROOT"]',
        "aws_organizations_policy_attachment", ["delete", "create"],
        before={"policy_id": "p-1"}, after={"policy_id": "p-1"})))

print()
print("── PHAM VI: chot chan cho TF_TARGETS rong ──")

# `terraform plan` KHONG bao loi khi TF_TARGETS rong - no chi plan CA
# layer. Voi organization, ca layer nghia la cay OU.
chay("OU doi trong stage B-scp   -> ngoai pham vi, thoat 1", 1, plan(NO_OP,
     rc('aws_organizations_organizational_unit.level1["Sandbox"]',
        "aws_organizations_organizational_unit", ["update"],
        before={"name": "Sandbox", "parent_id": "r-1"},
        after={"name": "Sandbox-2", "parent_id": "r-1"})))

chay("stage khong co trong bang  -> canh bao, sach", 0, plan(NO_OP),
     stage="Z-chua-khai")
chay("stage khong co + --strict  -> thoat 1", 1, plan(NO_OP),
     stage="Z-chua-khai", strict=True)

print()
print("── PHAM VI khop theo DIA CHI, khong theo type ──")
print("   (SCP va tag policy CUNG type aws_organizations_policy)")

# Neu pham_vi khop theo type thi ca bon test duoi day deu trot: hai stage
# se co pham vi giong nhau, tuc stage tagging duoc phep sua SCP.
SUA_SCP = rc('aws_organizations_policy.scp["baseline"]',
             "aws_organizations_policy", ["update"],
             before={"content": "a"}, after={"content": "b"})
SUA_TAG = rc("aws_organizations_policy.tag[0]",
             "aws_organizations_policy", ["update"],
             before={"content": "a"}, after={"content": "b"})

chay("stage B-scp sua SCP        -> trong pham vi", 0,
     plan(NO_OP, SUA_SCP), stage="sec-scp")
chay("stage B-scp sua TAG        -> NGOAI pham vi, thoat 1", 1,
     plan(NO_OP, SUA_TAG), stage="sec-scp")
chay("stage C-tagging sua TAG    -> trong pham vi", 0,
     plan(NO_OP, SUA_TAG), stage="sec-tagging")
chay("stage C-tagging sua SCP    -> NGOAI pham vi, thoat 1", 1,
     plan(NO_OP, SUA_SCP), stage="sec-tagging")

# Stage OU: chi duoc cham cay OU. Mot attachment doi trong stage nay la
# dau hieu TF_TARGETS rong.
chay("stage A-ou doi OU          -> trong pham vi", 0, plan(NO_OP,
     rc('aws_organizations_organizational_unit.level1["Sandbox"]',
        "aws_organizations_organizational_unit", ["update"],
        before={"name": "Sandbox", "parent_id": "r-1"},
        after={"name": "Sandbox2", "parent_id": "r-1"})),
     stage="sec-ou")
chay("stage A-ou doi attachment  -> NGOAI pham vi, thoat 1", 1,
     plan(NO_OP, XOA_ATTACH), stage="sec-ou")

print()
print("── tap_khong_lon: danh sach mien tru LON LEN la NOI ──")

BASE_RULE = {"name": "r", "excluded_accounts": ["111111111111"]}

chay("excluded_accounts THEM     -> NOI, thoat 1", 1, plan(NO_OP,
     rc("aws_config_organization_managed_rule.this[\"r\"]",
        "aws_config_organization_managed_rule", ["update"],
        before=BASE_RULE,
        after={"name": "r", "excluded_accounts": ["111111111111", "222222222222"]})),
     stage="cloudops-config-rules")

chay("excluded_accounts BOT      -> sach", 0, plan(NO_OP,
     rc("aws_config_organization_managed_rule.this[\"r\"]",
        "aws_config_organization_managed_rule", ["update"],
        before={"name": "r", "excluded_accounts": ["1", "2"]},
        after={"name": "r", "excluded_accounts": ["1"]})),
     stage="cloudops-config-rules")

print()
print("── thu_tu: phep so CHUOI noi nguoc, nen phai co bang xep ──")

# "NONE" > "ALL" theo thu tu chu cai. Mot cong chan so sanh chuoi thuong
# se coi viec tat GuardDuty la mot buoc THAT.
chay("auto_enable ALL -> NEW     -> NOI, thoat 1", 1, plan(NO_OP,
     rc("aws_guardduty_organization_configuration.this",
        "aws_guardduty_organization_configuration", ["update"],
        before={"auto_enable_organization_members": "ALL"},
        after={"auto_enable_organization_members": "NEW"})),
     stage="Z-bo-qua-pham-vi")

chay("auto_enable NEW -> ALL     -> sach", 0, plan(NO_OP,
     rc("aws_guardduty_organization_configuration.this",
        "aws_guardduty_organization_configuration", ["update"],
        before={"auto_enable_organization_members": "NEW"},
        after={"auto_enable_organization_members": "ALL"})),
     stage="Z-bo-qua-pham-vi")

chay("gia tri ngoai bang xep     -> thoat 1", 1, plan(NO_OP,
     rc("aws_guardduty_organization_configuration.this",
        "aws_guardduty_organization_configuration", ["update"],
        before={"auto_enable_organization_members": "ALL"},
        after={"auto_enable_organization_members": "KHONG_BIET"})),
     stage="Z-bo-qua-pham-vi")

print()
print("── so_khong_giam, bool_phai_true, va thuoc tinh BI BO ──")

OL = "aws_s3_bucket_object_lock_configuration.trail"
def ol(days_truoc, days_sau):
    def r(d):
        return {"rule": [{"default_retention": [{"days": d, "mode": "COMPLIANCE"}]}]}
    return rc(OL, "aws_s3_bucket_object_lock_configuration", ["update"],
              before=r(days_truoc), after=r(days_sau))

chay("object lock 3650 -> 365    -> NOI, thoat 1", 1,
     plan(NO_OP, ol(3650, 365)), stage="Z-bo-qua-pham-vi")
chay("object lock 365 -> 3650    -> sach", 0,
     plan(NO_OP, ol(365, 3650)), stage="Z-bo-qua-pham-vi")

chay("block_public_acls true->false -> NOI, thoat 1", 1, plan(NO_OP,
     rc("aws_s3_bucket_public_access_block.trail",
        "aws_s3_bucket_public_access_block", ["update"],
        before={"block_public_acls": True, "block_public_policy": True},
        after={"block_public_acls": False, "block_public_policy": True})),
     stage="Z-bo-qua-pham-vi")

# Bo han mot thuoc tinh khoi cau hinh: no ve MAC DINH cua AWS, va mac
# dinh cua AWS gan nhu luon long hon. Truong hop nay de sot nhat vi diff
# chi hien mot dong bi xoa.
chay("thuoc tinh BI BO khoi plan -> NOI, thoat 1", 1, plan(NO_OP,
     rc("aws_cloudtrail.this", "aws_cloudtrail", ["update"],
        before={"enable_logging": True, "is_multi_region_trail": True},
        after={"enable_logging": True})),
     stage="Z-bo-qua-pham-vi")

print()
print("── network/ops: TAO mot ingress rule la MO mot cua ──")

chay("TAO ingress rule           -> NOI, thoat 1", 1, plan(NO_OP,
     rc("aws_vpc_security_group_ingress_rule.partner_service",
        "aws_vpc_security_group_ingress_rule", ["create"],
        before=None, after={"cidr_ipv4": "0.0.0.0/0", "from_port": 443})),
     stage="cloudops-firewall")

chay("XOA ingress rule           -> sach", 0, plan(NO_OP,
     rc("aws_vpc_security_group_ingress_rule.partner_service",
        "aws_vpc_security_group_ingress_rule", ["delete"],
        before={"cidr_ipv4": "10.0.0.0/8"}, after=None)),
     stage="cloudops-firewall")

print()
print("── Khai bao con lai sau khi thay doi da di qua ──")

# Mot khai bao khong dung toi la mot cua mo bo ngo: lan sau co nguoi noi
# long dung dia chi do se khong bi chan.
chay("khai bao khong dung toi    -> canh bao, sach", 0, plan(NO_OP),
     loosen=KHAI_DU)
chay("khai bao khong dung + strict -> thoat 1", 1, plan(NO_OP),
     loosen=KHAI_DU, strict=True)

print()
print("════════════════════════════════════════════")
if truot == 0:
    print(f" {G}{dat} dat / 0 truot{N}")
    print("════════════════════════════════════════════")
    sys.exit(0)
print(f" {R}{dat} dat / {truot} truot{N}")
print("════════════════════════════════════════════")
sys.exit(1)
