"""Run a disposable OTP E2E test or serve the same local stack to Flutter."""
import argparse
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import URLError
from urllib.request import urlopen

from email_otp_e2e import run
from local_gateway import gateway, local_anon_key

SERVER_DIR = Path(__file__).resolve().parents[1]
WORK_DIR = SERVER_DIR.parent.parent.parent / "work"


def binary(variable, command, workspace_path, directory=False):
    configured = os.getenv(variable)
    located = shutil.which(command)
    if configured:
        candidate = Path(configured).expanduser() / command if directory else Path(configured).expanduser()
    elif located:
        candidate = Path(located)
    else:
        candidate = WORK_DIR / workspace_path
    if not os.access(candidate, os.X_OK):
        raise SystemExit(f"Set {variable} to the installed {'binary directory' if directory else 'binary'} for {command}.")
    return candidate.resolve().parent if directory else candidate.resolve()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(url, process):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(f"{Path(process.args[0]).name} failed to start")
        try:
            with urlopen(url, timeout=1):
                return
        except (URLError, TimeoutError):
            time.sleep(.1)
    raise RuntimeError("Local service unavailable")


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


class EmailTemplate(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write((SERVER_DIR / "deploy" / "otp.html").read_bytes())

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="keep the isolated development services running")
    parser.add_argument("--port", default=0, type=int, help="local API port (default is a free port)")
    args = parser.parse_args()
    pg = binary("PG_BIN", "initdb", "matching-pg/bin/initdb", directory=True)
    auth_bin = binary("AUTH_BIN", "gotrue", "matching-auth/auth")
    rest_bin = binary("POSTGREST_BIN", "postgrest", "matching-rest/postgrest-arm64")
    mail_bin = binary("MAILPIT_BIN", "mailpit", "matching-auth/mailpit")
    auth_migrations = Path(os.getenv("AUTH_MIGRATIONS", str(auth_bin.parent / "migrations")))
    if not auth_migrations.is_dir():
        raise SystemExit("Set AUTH_MIGRATIONS to the migrations directory from the Supabase Auth release.")
    migrations = sorted((SERVER_DIR / "migrations").glob("*.sql"))
    with tempfile.TemporaryDirectory(prefix="chenbot-otp-") as tmp, contextlib.ExitStack() as stack:
        root = Path(tmp)
        ports = set()
        while len(ports) < 5:
            ports.add(free_port())
        db_port, auth_port, rest_port, smtp_port, mail_port = ports
        auth = f"http://127.0.0.1:{auth_port}"
        rest = f"http://127.0.0.1:{rest_port}"
        mail = f"http://127.0.0.1:{mail_port}"
        database = 'chenbot_matching_test'
        pg_args = ['-h', str(root), '-p', str(db_port), '-U', 'postgres']
        pg_data = root / "pgdata"
        password = secrets.token_hex(24)
        passwd = root / "password"
        passwd.write_text(password)
        subprocess.run([pg / "initdb", "-D", pg_data, "-U", "postgres", "--auth-local=trust",
                        "--auth-host=scram-sha-256", "--pwfile", passwd, "-E", "UTF8",
                        "--locale=C"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([pg / "pg_ctl", "-D", pg_data, "-l", root / "pg.log", "-o",
                        f"-k {root} -p {db_port} -h 127.0.0.1 -c log_statement=none -c log_min_error_statement=panic", "-w", "start"],
                       check=True, stdout=subprocess.DEVNULL)
        stack.callback(subprocess.run, [pg / "pg_ctl", "-D", pg_data, "-m", "fast", "-w", "stop"],
                       stdout=subprocess.DEVNULL, check=True)
        subprocess.run([pg / 'createdb', *pg_args, database], check=True)
        pg_args += ['-d', database]

        def sql(script):
            subprocess.run([pg / "psql", *pg_args, "-v", "ON_ERROR_STOP=1", "-Xq"],
                           input=script, text=True, check=True, stdout=subprocess.DEVNULL)

        def launch(binary, env=None, flags=()):
            process = subprocess.Popen([binary, *flags], env={**os.environ, **(env or {})},
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            stack.callback(stop, process)
            return process

        sql(f"""create role anon; create role authenticated; create role service_role;
            create role test_auth login password '{password}';
            create role test_gateway login noinherit password '{password}';
            grant anon,authenticated to test_gateway;
            create schema auth authorization test_auth;
            alter role test_auth set search_path to auth,public;""")
        mailproc = launch(mail_bin, flags=[
            "--listen", f"127.0.0.1:{mail_port}", "--smtp", f"127.0.0.1:{smtp_port}",
            "--database", str(root / "mail.db"), "--quiet", "--disable-version-check"])
        wait_for(mail + "/readyz", mailproc)
        template = ThreadingHTTPServer(("127.0.0.1", 0), EmailTemplate)
        threading.Thread(target=template.serve_forever, daemon=True).start()
        stack.callback(template.server_close)
        stack.callback(template.shutdown)
        template_url = f"http://127.0.0.1:{template.server_port}/otp"
        jwt = secrets.token_hex(32)
        anon = local_anon_key(jwt)
        proxy = gateway(auth_port, rest_port, anon, args.port)
        stack.callback(proxy.server_close)
        api = f"http://127.0.0.1:{proxy.server_port}"
        db = f"@127.0.0.1:{db_port}/{database}"
        authproc = launch(auth_bin, {
            "API_EXTERNAL_URL":api + "/auth/v1", "GOTRUE_SITE_URL":api, "GOTRUE_API_HOST":"127.0.0.1",
            "PORT":str(auth_port), "GOTRUE_DB_DRIVER":"postgres", "DB_NAMESPACE":"auth",
            "DATABASE_URL":"postgres://test_auth:" + password + db,
            "GOTRUE_DB_MIGRATIONS_PATH":str(auth_migrations),
            "GOTRUE_JWT_SECRET":jwt,"GOTRUE_JWT_AUD":"authenticated",
            "GOTRUE_JWT_DEFAULT_GROUP_NAME":"authenticated","GOTRUE_EXTERNAL_EMAIL_ENABLED":"true",
            "GOTRUE_MAILER_AUTOCONFIRM":"false", "GOTRUE_SMTP_HOST":"127.0.0.1",
            "GOTRUE_SMTP_PORT":str(smtp_port),"GOTRUE_SMTP_ADMIN_EMAIL":"sender@example.test",
            "GOTRUE_SMTP_MAX_FREQUENCY":"1s",
            "GOTRUE_MAILER_OTP_EXP":"600",
            "GOTRUE_MAILER_TEMPLATES_CONFIRMATION":template_url,
            "GOTRUE_MAILER_TEMPLATES_MAGIC_LINK":template_url,"GOTRUE_RATE_LIMIT_EMAIL_SENT":"10",
        })
        wait_for(auth + "/health", authproc)
        for migration in migrations:
            sql(migration.read_text())
        if args.serve:
            sql("set matching.environment='development';\n"
                + (SERVER_DIR / "fixtures" / "blind_shanghai_dev.sql").read_text())
        pgrest = launch(rest_bin, {
            "PGRST_DB_URI":"postgres://test_gateway:" + password + db, "PGRST_DB_ANON_ROLE":"anon",
            "PGRST_JWT_SECRET":jwt, "PGRST_SERVER_HOST":"127.0.0.1", "PGRST_SERVER_PORT":str(rest_port),
        })
        wait_for(rest + "/", pgrest)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        stack.callback(proxy.shutdown)
        if not args.serve:
            os.environ.update(AUTH_URL=api + "/auth/v1", REST_URL=api + "/rest/v1",
                              MAILPIT_URL=mail, SUPABASE_ANON_KEY=anon)
            run()
            tests = SERVER_DIR / "tests"
            for suite in ("blind.sql", "secret.sql", "safety.sql"):
                sql((tests / suite).read_text())
                print(f"PASS: {suite}", flush=True)
            environment = {
                **os.environ,
                "PATH": str(pg) + os.pathsep + os.environ.get("PATH", ""),
                "PGPASSWORD": password,
                "MATCH_TEST_DSN": "postgresql://postgres" + db,
                "MATCH_TEST_REST_URL": rest,
                "MATCH_TEST_JWT_SECRET": jwt,
                "MATCH_TEST_LOG_FILES": str(root / "pg.log"),
            }
            for suite in ("blind_http_test.py", "matching_http_test.py"):
                subprocess.run([sys.executable, tests / suite], env=environment, check=True)
            return

        defines = root / "flutter-local.json"
        defines.write_text(json.dumps({"SUPABASE_URL": api, "SUPABASE_ANON_KEY": anon}))
        print(f"本地 API {api}\n本机测试邮箱 {mail}\nFlutter 配置 {defines}", flush=True)
        android_sdk = Path(os.getenv("ANDROID_HOME") or os.getenv("ANDROID_SDK_ROOT")
                           or Path.home() / "Library" / "Android" / "sdk")
        adb = shutil.which("adb") or android_sdk / "platform-tools" / "adb"
        adb_command = shlex.quote(str(adb)) if Path(adb).is_file() else "adb"
        print(f"Android USB 或模拟器：{adb_command} reverse tcp:{proxy.server_port} tcp:{proxy.server_port}",
              flush=True)
        flutter = shutil.which("flutter") or WORK_DIR / "flutter" / "bin" / "flutter"
        flutter = str(flutter) if Path(flutter).is_file() else "flutter"
        print(f"Flutter：{shlex.quote(flutter)} run --debug --dart-define-from-file={shlex.quote(str(defines))}",
              flush=True)
        print("按 Ctrl+C 停止服务，临时账号、邮箱与匹配记录将清除。", flush=True)
        while all(p.poll() is None for p in (authproc, pgrest, mailproc)):
            time.sleep(1)
        raise SystemExit("Local service stopped; restart the development stack.")


if __name__ == "__main__":
    # SIGTERM (e.g. an IDE stop button) also unwinds the temporary service stack.
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    try:
        main()
    except KeyboardInterrupt:
        pass
