"""Run against a disposable local Supabase Auth, PostgREST and Mailpit stack.

AUTH_URL, REST_URL and MAILPIT_URL are loopback endpoints (direct services or
Supabase local API routes). Optionally set SUPABASE_ANON_KEY for the local
gateway. Configure SMTP delivery to Mailpit, disable auto-confirmation, and
include {{ .Token }} in the confirmation and magic-link templates. Set
TEST_OTP_RESEND_WAIT to the local SMTP resend cooldown plus a small margin
when not using local_otp_stack.py. Two addresses
under example.test are created per run. Discard the test DB and inbox afterward.
"""

import hashlib
import json
import os
import re
import secrets
import time
import uuid
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def local_endpoint(name):
    url = os.environ[name].rstrip("/")
    if urlsplit(url).hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError(f"{name} must point to the disposable local stack")
    return url


def request(url, params=None, token=None, expected=(200,), gateway=False):
    headers = {"Content-Type": "application/json"}
    if gateway and os.getenv("SUPABASE_ANON_KEY"):
        headers["apikey"] = os.environ["SUPABASE_ANON_KEY"]
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if params is None else json.dumps(params).encode()
    try:
        with urlopen(Request(url, data=data, headers=headers), timeout=15) as result:
            status, raw = result.status, result.read()
    except HTTPError as error:
        status, raw = error.code, error.read()
    if status not in expected:
        # Auth/SQL errors may echo sensitive data. Never print response bodies.
        raise AssertionError(f"{urlsplit(url).path} returned HTTP {status}")
    return json.loads(raw) if raw.strip() else None


def delivered_code(mailpit, email, previous_id=None):
    for _ in range(30):
        search = request(mailpit + "/api/v1/search?" + urlencode({"query": "to:" + email}))
        for summary in search["messages"]:
            if summary["ID"] == previous_id:
                continue
            if not any(entry["Address"] == email for entry in summary["To"]):
                continue
            msg = request(mailpit + "/api/v1/message/" + summary["ID"])
            match = re.search(r"(?<!\w)\d{6,10}(?!\w)", msg.get("Text", ""))
            if match:
                return summary["ID"], match.group(0)
        time.sleep(0.3)
    raise AssertionError("Numeric OTP missing from test email")


def run():
    auth, rest, mail = (local_endpoint(name) for name in ("AUTH_URL", "REST_URL", "MAILPIT_URL"))

    def rpc(fn, token, args=None, expected=(200,)):
        return request(f"{rest}/rpc/{fn}", args or {}, token, expected, gateway=True)

    def sign_in(email, previous_id=None):
        receipt = request(auth + "/otp", {"email": email, "create_user": previous_id is None},
                          expected=(200, 202), gateway=True)
        assert not receipt or not receipt.get("access_token")
        message_id, code = delivered_code(mail, email, previous_id)
        wrong = ("0" if code[0] != "0" else "1") + code[1:]
        request(auth + "/verify", {"email": email, "token": wrong, "type": "email"},
                expected=(400, 401, 403, 422), gateway=True)
        session = request(auth + "/verify", {"email": email, "token": code, "type": "email"}, gateway=True)
        assert session["user"]["email_confirmed_at"]
        return session, message_id

    def enroll():
        username = "chenbot-test-" + uuid.uuid4().hex[:12]
        email = username + "@example.test"
        session, message_id = sign_in(email)
        token = session["access_token"]
        assert rpc("matching_me", token) == {"enrolled": False, "name": username}
        rpc("secret_state", token, expected=(401, 403))
        rpc("matching_enroll", token, {"p_adult": False}, expected=(400,))
        rpc("matching_enroll", token, {"p_adult": True})
        assert rpc("matching_me", token)["enrolled"]
        return token, email, session["user"]["id"], message_id

    a, email, account_id, first_email = enroll()
    b = enroll()[0]
    # The disposable runner sets the per-inbox resend cooldown to one second.
    time.sleep(float(os.getenv("TEST_OTP_RESEND_WAIT", "1.1")))
    returning, _ = sign_in(email, first_email)
    assert returning["user"]["id"] == account_id
    a = returning["access_token"]
    assert rpc("matching_me", a)["enrolled"]
    digest = hashlib.sha256(b"chenbot/secret-match/token/v1\x00" + secrets.token_bytes(16)).hexdigest()

    def join(token):
        return rpc("secret_join", token, {"p_nonce": str(uuid.uuid4()), "p_token": digest})

    assert join(a)["status"] == "waiting"
    matched = join(b)
    assert matched["status"] == "connected"
    link = matched["connection_id"]
    assert rpc("secret_state", a)["connection_id"] == link
    message = {"p_id": link, "p_body": "本地端到端测试", "p_nonce": str(uuid.uuid4())}
    assert rpc("matching_send", a, message)
    received = rpc("matching_messages", b, {"p_id": link})
    assert len(received) == 1 and not received[0]["mine"] and received[0]["body"] == message["p_body"]
    rpc("matching_delete", a)
    assert rpc("matching_connections", b) == []
    rpc("matching_delete", b)
    print("PASS: real registration and returning-user SMTP OTP, wrong-code and adult checks, match, chat and deletion")


if __name__ == "__main__":
    run()
