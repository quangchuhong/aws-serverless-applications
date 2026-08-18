"""
Day finding cua Security Hub sang Slack.

Webhook URL doc tu Secrets Manager, KHONG tu bien moi truong -
bien moi truong cua Lambda hien ra trong console va trong
terraform state o dang ro.

Chi dung thu vien co san trong runtime Python cua Lambda: khong
can build layer, khong can dong goi dependency.
"""

import json
import os
import urllib.request
import urllib.error

import boto3

SECRET_NAME = os.environ["SECRET_NAME"]

_secrets = boto3.client("secretsmanager")

# Cache giua cac lan goi. Lambda giu container song mot luc, nen
# khong phai goi Secrets Manager moi lan - vua cham vua tinh tien.
_webhook_cache = None

COLOR = {
    "CRITICAL": "#d32f2f",
    "HIGH": "#f57c00",
    "MEDIUM": "#fbc02d",
    "LOW": "#7cb342",
}


def _webhook_url():
    global _webhook_cache
    if _webhook_cache is None:
        raw = _secrets.get_secret_value(SecretId=SECRET_NAME)["SecretString"]
        try:
            # Chap nhan ca hai dang: JSON {"webhook_url": "..."} hoac chuoi tran
            _webhook_cache = json.loads(raw)["webhook_url"]
        except (json.JSONDecodeError, KeyError, TypeError):
            _webhook_cache = raw.strip()
    return _webhook_cache


def _block(finding):
    severity = finding.get("Severity", {}).get("Label", "UNKNOWN")
    resources = finding.get("Resources") or [{}]

    fields = [
        ("Account", finding.get("AwsAccountId", "-")),
        ("Region", finding.get("Region", "-")),
        ("Resource", resources[0].get("Id", "-")),
        ("Rule", finding.get("GeneratorId", "-")),
    ]

    return {
        "color": COLOR.get(severity, "#9e9e9e"),
        "title": f"[{severity}] {finding.get('Title', 'Khong co tieu de')}",
        "text": finding.get("Description", "")[:500],
        "fields": [
            {"title": k, "value": str(v), "short": True} for k, v in fields
        ],
    }


def handler(event, _context):
    findings = event.get("detail", {}).get("findings", [])

    if not findings:
        print("Khong co finding trong event, bo qua")
        return {"sent": 0}

    # Mot event co the mang nhieu finding. Gioi han so luong gui di
    # de khong lam ngap kenh Slack khi co dot vi pham lon.
    payload = {"attachments": [_block(f) for f in findings[:10]]}

    if len(findings) > 10:
        payload["text"] = f"(con {len(findings) - 10} finding nua khong hien o day)"

    req = urllib.request.Request(
        _webhook_url(),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except urllib.error.HTTPError as exc:
        # In ra body cua loi - Slack tra ve ly do cu the
        # (invalid_payload, channel_not_found, ...)
        print(f"Slack tu choi: {exc.code} {exc.read().decode('utf-8', 'replace')}")
        raise

    print(f"Da gui {min(len(findings), 10)}/{len(findings)} finding")
    return {"sent": min(len(findings), 10)}
