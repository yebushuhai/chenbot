#!/usr/bin/env python3
"""Verify this deployment through its loopback edge and a disposable, data-free DB."""
import hashlib
import json
import signal
import subprocess
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import manage

DB = manage.COMPOSE + ["exec", "-T", "db"]
PSQL = ["psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d"]


def query(db, sql):
    return subprocess.check_output(DB + PSQL + [db], input=sql.encode("utf8"))


def ensure(ok, what):
    if not ok:
        raise RuntimeError("Failed: " + what)


def check_edge(cfg):
    edge = cfg["services"]["edge"]
    port = next(item["published"] for item in edge["ports"] if item["target"] == 8080 and
                item["host_ip"] == "127.0.0.1")
    base = "http://127.0.0.1:" + str(port)
    app_key = edge["environment"]["APP_KEY"]

    def request(path, status, key=True, post=False):
        headers = {"apikey": app_key} if key else {}
        req = Request(base + path, headers=headers, data=b"{}" if post else None)
        if post:
            req.add_header("Content-Type", "application/json")
        try:
            with urlopen(req, timeout=8) as response:
                code, data = response.status, response.read()
        except HTTPError as error:
            code, data = error.code, None
        ensure(code in status, path + " HTTP " + str(code))
        return data

    request("/auth/v1/settings", (401,), key=False)
    request("/auth/v1/admin/users", (404,))
    request("/auth/v1/token?grant_type=password", (404,), post=True)
    request("/rest/v1/rpc/matching_me", (401, 403), post=True)
    auth = json.loads(request("/auth/v1/settings", (200,)))
    expected = cfg["services"]["auth"]["environment"]["GOTRUE_EXTERNAL_EMAIL_ENABLED"] == "true"
    ensure(auth["external"]["email"] is expected, "configured email availability")
    print("PASS loopback gateway, HTTP 401/403/404, Auth settings (email={}).".format(expected))


def check_database():
    migrations = sorted((manage.HERE.parents[1] / "migrations").glob("*.sql"))
    expected = [p.name + "|" + hashlib.sha256(p.read_bytes()).hexdigest() for p in migrations]
    rows = query("chenbot", "begin read only; select filename,sha256 from chenbot_deploy.versions order by version; commit;")
    ensure(len(expected) == 5 and rows.decode().splitlines() == expected, "five migration SHA-256 entries")
    ensure(query("chenbot", "select demo_enabled from matching.blind_venue_policy;").strip() == b"f", "production venue mode")

    # Keep only the deployed Auth DDL. All synthetic participants live in a
    # random scratch database on this host; no customer row or secret is copied.
    schema = subprocess.check_output(DB + ["pg_dump", "-U", "postgres", "-d", "chenbot", "-n", "auth",
                                           "--schema-only", "--no-owner", "--no-privileges"])
    name = "chenbot_smoke_" + uuid.uuid4().hex
    subprocess.run(DB + ["createdb", "-U", "postgres", "-T", "template0", "-E", "UTF8", name], check=True)
    try:
        query(name, schema.decode("utf8"))
        migrations_sql = manage.migration_script()
        query(name, migrations_sql)
        query(name, migrations_sql)
        a, b, nonce = (uuid.uuid4() for _ in range(3))
        check = """begin;
        insert into auth.users(id,email,email_confirmed_at)
          values ('{a}','a@example.test',now()),('{b}','b@example.test',now());
        set local role authenticated;
        do $$
        declare v jsonb; again jsonb; paired jsonb; code text:=encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex');
        begin
          perform set_config('request.jwt.claim.sub','{a}',true);
          perform set_config('request.jwt.claims',json_build_object('sub','{a}','role','authenticated')::text,true);
          perform public.matching_enroll(true);
          v:=public.secret_join(code,'{nonce}');
          again:=public.secret_join(code,'{nonce}');
          if v->>'status' is distinct from 'waiting' or v is distinct from again then raise exception 'invalid waiting or retry'; end if;
          perform set_config('request.jwt.claim.sub','{b}',true);
          perform set_config('request.jwt.claims',json_build_object('sub','{b}','role','authenticated')::text,true);
          perform public.matching_enroll(true);
          paired:=public.secret_join(code,gen_random_uuid());
          perform set_config('request.jwt.claim.sub','{a}',true);
          perform set_config('request.jwt.claims',json_build_object('sub','{a}','role','authenticated')::text,true);
          v:=public.secret_state();
          if paired->>'status' is distinct from 'connected' or v->>'status' is distinct from 'connected'
             or paired->>'connection_id' is null or v->>'connection_id' is distinct from paired->>'connection_id'
             then raise exception 'invalid mutual connection'; end if;
        end $$;
        rollback;"""
        query(name, check.format(a=a, b=b, nonce=nonce))
    finally:
        subprocess.run(DB + ["dropdb", "-U", "postgres", name], check=True)
    print("PASS deployment ledger, production venue mode, isolated migration replay and two-account Secret Match.")


def main():
    def interrupt(*unused):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    check_edge(manage.checked_config())
    check_database()


if __name__ == "__main__":
    main()
