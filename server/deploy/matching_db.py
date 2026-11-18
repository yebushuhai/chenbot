#!/usr/bin/env python3
"""Apply Chenbot migrations or run the trusted matching retention task."""
import argparse
import hashlib
import re
import subprocess
from pathlib import Path


MIGRATIONS = Path(__file__).resolve().parents[1] / "migrations"
FILE_NAME = re.compile(r"(\d{3})_[a-z0-9_]+\.sql")
WRAPPER = re.compile(r"\A(?:\s|--[^\n]*(?:\n|$))*begin;\s*\n(?P<body>.*)\ncommit;\s*\Z", re.S | re.I)


def migration_script():
    script = [
        "begin;",
        """do $$ begin if current_setting('server_encoding') <> 'UTF8' then
             raise exception 'Chenbot requires a UTF8 database'; end if; end $$;""",
        "select pg_advisory_xact_lock(1186615734, 72105);",
        "create schema if not exists chenbot_deploy;",
        "revoke all on schema chenbot_deploy from public, anon, authenticated;",
        """create table if not exists chenbot_deploy.versions (
             version integer primary key, filename text not null unique, sha256 text not null,
             applied_at timestamptz not null default clock_timestamp());""",
        "revoke all on chenbot_deploy.versions from public, anon, authenticated;",
    ]
    versions = []
    for path in sorted(MIGRATIONS.glob("*.sql")):
        filename = FILE_NAME.fullmatch(path.name)
        if not filename or int(filename[1]) != len(versions) + 1:
            raise ValueError(f"unexpected migration name or nonconsecutive version: {path.name}")
        version = int(filename[1])
        versions.append(version)
        data = path.read_bytes()
        wrapper = WRAPPER.fullmatch(data.decode("utf-8"))
        if not wrapper:
            raise ValueError(f"migration must have a single outer begin/commit: {path.name}")
        digest = hashlib.sha256(data).hexdigest()
        script += [
            f"select exists(select 1 from chenbot_deploy.versions where version={version}) as applied,",
            f"exists(select 1 from chenbot_deploy.versions where version={version} and filename='{path.name}' and sha256='{digest}') as same \\gset",
            "\\if :applied",
            "\\if :same",
            f"\\echo verified {path.name}",
            "\\else",
            f"do $$ begin raise exception 'migration checksum mismatch for {path.name}'; end $$;",
            "\\endif",
            "\\else",
            f"\\echo applying {path.name}",
            wrapper["body"],
            f"insert into chenbot_deploy.versions(version,filename,sha256) values({version},'{path.name}','{digest}');",
            "\\endif",
        ]
    if not versions:
        raise ValueError("missing migrations")
    script += [
        f"do $$ begin if exists(select 1 from chenbot_deploy.versions where version not between 1 and {versions[-1]}) then",
        "raise exception 'database contains migrations unknown to this revision'; end if; end $$;",
        "commit;",
    ]
    return "\n".join(script) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["migrate", "maintain"])
    parser.add_argument("--compose-dir", type=Path,
                        help="official Supabase Docker directory; otherwise psql uses PG* environment")
    args = parser.parse_args()
    command = []
    if args.compose_dir:
        root = args.compose_dir.resolve()
        command = ["docker", "compose", "--project-directory", str(root), "-f", str(root / "docker-compose.yml"),
                   "-f", str(root / "chenbot-deploy/compose.matching.yml"), "exec", "-T", "db"]
    command += ["psql", "-X", "--no-password", "-q", "-v", "ON_ERROR_STOP=1"]
    if args.compose_dir:
        command += ["--username=postgres"]  # The db container sets PGDATABASE and PGPASSWORD.
    sql = migration_script() if args.action == "migrate" else "select matching.maintain();\n"
    return subprocess.run(command, input=sql, text=True, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
