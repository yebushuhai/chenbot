"""Two-device REST scenario against a disposable PostgREST + PostgreSQL instance.

Set MATCH_TEST_DSN, MATCH_TEST_REST_URL and MATCH_TEST_JWT_SECRET (only for the
local test gateway). Requires psql on PATH. Incorporates the real signature
check, authenticated role and separate pooled transactions, not actual mail.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from uuid import uuid4


def required_local(name):
    url = os.environ[name]
    if urlsplit(url).hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError(f"{name} must point at a disposable local instance")
    return url


def encoded(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def jwt(actor, signing_key):
    header = encoded(b'{"alg":"HS256","typ":"JWT"}')
    payload = encoded(json.dumps({"role": "authenticated", "sub": actor,
                                  "exp": int(time.time()) + 300}).encode())
    unsigned = header + b"." + payload
    return (unsigned + b"." + encoded(hmac.digest(signing_key, unsigned, "sha256"))).decode()


def call(base, bearer, rpc, data=None, denied=False, rejected=False):
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    req = Request(f"{base}/rpc/{rpc}", data=json.dumps(data or {}).encode(), headers=headers)
    try:
        with urlopen(req, timeout=12) as response:
            raw = response.read()
    except HTTPError as error:
        if rejected and error.code == 400:
            return
        if denied and error.code in (401, 403):
            return
        # Don't print the request body or JWT.
        error_data = json.loads(error.read())
        raise AssertionError(f"{rpc}: HTTP {error.code}, SQLSTATE {error_data.get('code')}") from None
    if denied or rejected:
        raise AssertionError(f"{rpc} unexpectedly accepted the request")
    return json.loads(raw) if raw else None


def check(ok, message):
    if not ok:
        raise AssertionError(message)


def main():
    dsn = required_local("MATCH_TEST_DSN")
    base = required_local("MATCH_TEST_REST_URL").rstrip("/")
    if not urlsplit(dsn).path.endswith("_test"):
        raise ValueError("Use a disposable database ending in _test")
    secret = os.environ["MATCH_TEST_JWT_SECRET"].encode()
    ids = [str(uuid4()) for _ in range(4)]
    tokens = [jwt(actor, secret) for actor in ids]

    def sql(statement):
        subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", dsn], input=statement,
                       text=True, check=True, stdout=subprocess.DEVNULL)

    def invoke(n, rpc, data=None, denied=False, rejected=False):
        return call(base, tokens[n], rpc, data, denied=denied, rejected=rejected)

    def match_in_parallel(requests, token):
        # All workers enter together, each through a distinct HTTP request.
        barrier = threading.Barrier(len(requests))

        def join(item):
            n, nonce = item
            barrier.wait(timeout=8)
            return invoke(n, "secret_join", {"p_token": token, "p_nonce": nonce})

        with ThreadPoolExecutor(max_workers=len(requests)) as executor:
            return list(executor.map(join, requests))

    try:
        for n, actor in enumerate(ids):
            verified = "null" if n == 3 else "now()"
            # Only generated UUIDs and hard-coded literals reach SQL.
            sql(f"insert into auth.users(id,email,email_confirmed_at) values "
                f"('{actor}','{actor}@example.test',{verified})")
        call(base, None, "secret_state", denied=True)
        call(base, jwt(ids[0], secrets.token_bytes(32)), "secret_state", denied=True)
        invoke(3, "matching_enroll", {"p_adult": True}, denied=True)
        invoke(0, "secret_state", denied=True)
        for n in range(3):
            invoke(n, "matching_enroll", {"p_adult": True})
        nonce_a, nonce_b = str(uuid4()), str(uuid4())
        submissions = [(0, nonce_a), (0, nonce_a), (1, nonce_b), (1, nonce_b)]
        token = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
        answers = match_in_parallel(submissions, token)
        states = [invoke(n, "secret_state") for n in range(2)]
        check({r["status"] for r in states} == {"connected"}, "both opt-ins required")
        check(states[0]["connection_id"] == states[1]["connection_id"], "duplicate connection")
        check(all(answer["id"] == states[n]["id"] for (n, _), answer in zip(submissions, answers)),
              "nonce replay created requests")
        check(all(set(r) == {"status", "id", "connection_id"} for r in states), "identity leak")
        check(invoke(2, "secret_state") == {"status": "idle"}, "unrelated state changed")
        invoke(2, "secret_act", {"p_id": states[0]["id"], "p_action": "withdraw"}, denied=True)
        invoke(2, "matching_messages", {"p_id": states[0]["connection_id"]}, denied=True)
        message = "private-test-message-" + str(uuid4())
        body = {"p_id": states[0]["connection_id"], "p_body": message, "p_nonce": str(uuid4())}
        invoke(0, "matching_send", body)
        invoke(0, "matching_send", body)
        received = invoke(1, "matching_messages", {"p_id": states[0]["connection_id"]})
        check(len(received) == 1 and received[0]["body"] == message and not received[0]["mine"],
              "anonymous conversation was not readable or a retry duplicated the message")
        invoke(0, "matching_safety", {"p_kind": "secret", "p_id": states[0]["id"],
                                     "p_action": "block", "p_reason": ""})
        check(all(invoke(n, "secret_state")["status"] == "withdrawn" for n in range(2)),
              "blocked pair retained connection")
        second = match_in_parallel([(n, str(uuid4())) for n in range(2)],
                                   hashlib.sha256(secrets.token_bytes(32)).hexdigest())
        check(all(r["status"] == "waiting" for r in second), "blocked pair matched again")
        invoke(0, "matching_delete")
        check(invoke(1, "secret_state")["status"] == "waiting", "deleted user rematched")
        invoke(0, "matching_enroll", {"p_adult": True})
        invoke(0, "secret_join", {"p_token": token, "p_nonce": nonce_a}, rejected=True)
        check(invoke(0, "secret_state")["status"] == "idle", "replayed deleted consent")
        # Optional black-box tripwire for the gateway/database under test. No test
        # output echoes markers, including on failure. An external logging agent
        # is outside this check and needs its own audit before deployment.
        for path in filter(None, os.environ.get("MATCH_TEST_LOG_FILES", "").split(os.pathsep)):
            log = Path(path).read_bytes()
            markers = [token, message, *tokens, *(a + "@example.test" for a in ids)]
            check(not any(marker.encode() in log for marker in markers),
                  "sensitive test payload present in an inspected service log")
        print("PostgREST two-account matching, concurrent retries, authorization, "
              "block and delete scenarios passed.")
    finally:
        sql("delete from auth.users where id in (" + ",".join("'" + x + "'" for x in ids) + ")")


if __name__ == "__main__":
    main()
