#!/usr/bin/env python3
"""Deploy the loopback matching API on a small Linux Docker host."""

import argparse
import base64
import hashlib
import hmac
import json
import os
import platform
from pathlib import Path
import re
import secrets
import subprocess
import sys
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from matching_db import migration_script

ENV_FILE = HERE / ".env"
COMPOSE = ["docker", "compose", "-p", "chenbot-matching", "--project-directory", str(HERE),
           "--env-file", str(ENV_FILE), "-f", str(HERE / "compose.yaml")]


# Docker image IDs are digests of the image config, which includes the ordered
# rootfs layer diff IDs. Values come from the pinned upstream OCI indices.
IMAGE_IDS = {
    "amd64": {
        "PG_IMAGE": "sha256:6b75136145ddabf3d9a4b69660402082de7c56b734cfe50555b0674774dd742a",
        "AUTH_IMAGE": "sha256:68f9d8079dbfc35e784a97faeb39e36918aa662e3f1b5ea326cdda5c4b042993",
        "REST_IMAGE": "sha256:e58a8520c6a74b78db98a1e7bbe9cc578ea500009c81ff68b9cc2b7eff4987db",
        "CADDY_IMAGE": "sha256:aac61abc4024c323602ccb9ee38bd68b147601f518626b2a055e06944e01c510",
    },
    "arm64": {
        "PG_IMAGE": "sha256:97106b46c3da2dcd9bcdb89cfb4b9dec61ff62a6f17e77bee6c5487145696e46",
        "AUTH_IMAGE": "sha256:92d92d3298eed4a0071268535073a30b1130a124f7be36212f5b92f8b3b8fe31",
        "REST_IMAGE": "sha256:85ff73f0ee2c23e1b06f0d20ab9819d1394ddd49daab95b58eb92c689d788c8a",
        "CADDY_IMAGE": "sha256:8f5619aac3ed45304632491507becd99711bcaed375aee3e6317c7b703902969",
    },
}

def anon_key(secret):
    def b64(data):
        return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")

    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    claims = b64(b'{"role":"anon","iss":"chenbot","aud":"authenticated"}')
    signed = (header + "." + claims).encode("ascii")
    return signed.decode("ascii") + "." + b64(hmac.new(secret.encode("ascii"), signed, hashlib.sha256).digest())


def initialize():
    if ENV_FILE.exists():
        print("Existing staging configuration retained.")
        return
    # Docker credentials and a matching database may survive loss of the host
    # env file. Never silently generate a new JWT secret for that deployment.
    volumes = subprocess.check_output(["docker", "volume", "ls", "--format", "{{.Name}}"], universal_newlines=True)
    if "chenbot-matching_chenbot-db" in volumes.splitlines():
        raise SystemExit("Existing Chenbot database volume: restore its original .env before starting.")
    jwt = secrets.token_hex(32)
    config = {
        "DB_PASSWORD": secrets.token_hex(32),
        "AUTH_PASSWORD": secrets.token_hex(32),
        "REST_PASSWORD": secrets.token_hex(32),
        "JWT_SECRET": jwt,
        "APP_KEY": anon_key(jwt),
        "BASE_URL": "http://127.0.0.1:18080",
        "LOOPBACK_PORT": "18080",
        "ENABLE_EMAIL": "false",
        "DISABLE_SIGNUP": "true",
    }
    with os.fdopen(os.open(ENV_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as handle:
        for key, value in config.items():
            handle.write(f"{key}={value}\n")
    print("Created protected .env. Email signup is disabled.")


def sql(script):
    subprocess.run(COMPOSE + ["exec", "-T", "db", "psql", "-Xq", "-v", "ON_ERROR_STOP=1",
                              "-U", "postgres", "-d", "chenbot"], input=script, universal_newlines=True, check=True)


def ensure_roles(auth_url, rest_url):
    # These credentials are locally generated hex and never appear in command arguments.
    auth, rest = urlsplit(auth_url).password or "", urlsplit(rest_url).password or ""
    if not all(re.fullmatch("[0-9a-f]{64}", p) for p in (auth, rest)):
        raise SystemExit("Protected service role credentials have unexpected format.")
    sql(rf"""begin;
        select pg_advisory_xact_lock(1186615734,72105);
        select 'create role anon nologin' where not exists(select 1 from pg_roles where rolname='anon') \gexec
        select 'create role authenticated nologin' where not exists(select 1 from pg_roles where rolname='authenticated') \gexec
        select 'create role service_role nologin' where not exists(select 1 from pg_roles where rolname='service_role') \gexec
        select 'create role chenbot_auth login password ''{auth}''' where not exists(select 1 from pg_roles where rolname='chenbot_auth') \gexec
        select 'create role chenbot_rest login noinherit password ''{rest}''' where not exists(select 1 from pg_roles where rolname='chenbot_rest') \gexec
        grant anon,authenticated to chenbot_rest;
        create schema if not exists auth authorization chenbot_auth;
        alter role chenbot_auth set search_path to auth,public;
        commit;""")


def checked_config():
    # Capture resolved Compose values for validation; do not print secrets.
    if ENV_FILE.stat().st_mode & 0o077:
        raise SystemExit("Protect the deployment .env with chmod 600.")
    cfg = json.loads(subprocess.check_output(COMPOSE + ["config", "--format", "json"]))
    auth = cfg["services"]["auth"]["environment"]
    base = urlsplit(auth["GOTRUE_SITE_URL"])
    enables_mail = str(auth["GOTRUE_EXTERNAL_EMAIL_ENABLED"]).lower() == "true"
    if enables_mail or str(auth["GOTRUE_DISABLE_SIGNUP"]).lower() != "true":
        if not enables_mail or not all(auth.get("GOTRUE_SMTP_" + k) for k in ("HOST","USER","PASS","ADMIN_EMAIL")):
            raise SystemExit("Configure a private SMTP account before enabling email.")
        if base.scheme != "https" or not base.hostname:
            raise SystemExit("Email login requires a configured HTTPS API domain.")
    return cfg


def select_offline_images():
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
    if not arch:
        raise SystemExit("No verified Linux image set for host architecture " + machine)
    selected = {}
    for variable, expected in IMAGE_IDS[arch].items():
        info = json.loads(subprocess.check_output(["docker", "image", "inspect", expected]))[0]
        if (info["Id"], info["Os"], info["Architecture"]) != (expected, "linux", arch):
            raise SystemExit("Loaded image failed upstream verification for " + variable)
        selected[variable] = expected
    for variable, expected in selected.items():
        label = "chenbot-verified/" + variable.split("_")[0].lower() + ":" + expected[7:19]
        subprocess.run(["docker", "tag", expected, label], check=True)
        os.environ[variable] = label


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "up", "status", "maintain", "client-config"))
    parser.add_argument("--offline", action="store_true",
                        help="use and verify images already imported using docker load")
    args = parser.parse_args()
    action = args.action
    if args.offline and action != "up":
        parser.error("--offline is for up")
    if args.offline:
        select_offline_images()
    if action == "init":
        initialize()
        return
    if not ENV_FILE.exists():
        raise SystemExit("First run manage.py init.")
    if action == "maintain":
        sql("select matching.maintain();\n")
        return
    if action == "status":
        subprocess.run(COMPOSE + ["ps"], check=True)
        return
    cfg = checked_config()["services"]
    auth = cfg["auth"]["environment"]
    if action == "client-config":
        print(json.dumps({"SUPABASE_URL": auth["GOTRUE_SITE_URL"],
                          "SUPABASE_ANON_KEY": cfg["edge"]["environment"]["APP_KEY"]}))
        return
    # Auth owns and migrates auth.users; application migrations depend on it.
    up = COMPOSE + ["up", "-d", "--wait"]
    if args.offline:
        up += ["--pull", "never"]
    subprocess.run(up + ["db", "edge"], check=True)
    ensure_roles(auth["DATABASE_URL"], cfg["rest"]["environment"]["PGRST_DB_URI"])
    subprocess.run(up + ["auth"], check=True)
    sql(migration_script())
    subprocess.run(up + ["rest"], check=True)
    sql("select count(*) as applied_migrations from chenbot_deploy.versions;\n"
        "select demo_enabled from matching.blind_venue_policy;\n")
    print("Database, authentication, matching RPCs and loopback edge started.")


if __name__ == "__main__":
    main()
