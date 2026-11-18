"""Blind Encounter end-to-end RPC flow over a disposable PostgREST instance.

Run alongside matching_http_test.py with its three environment variables.
The database must end in _test and have no real venue catalog.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import os
import subprocess
from threading import Barrier
from uuid import uuid4

from matching_http_test import call, check, jwt, required_local


def main():
    dsn = required_local("MATCH_TEST_DSN")
    url = required_local("MATCH_TEST_REST_URL").rstrip("/")
    if not dsn.split("?")[0].split("/")[-1].endswith("_test"):
        raise ValueError("Use a disposable database ending in _test")

    def sql(query):
        cmd = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", dsn]
        return subprocess.check_output(cmd, input=query, text=True).strip()

    check(sql("select count(*) from matching.blind_venues") == "0",
          "Blind HTTP scenario requires an empty disposable venue catalog")
    people = [str(uuid4()) for _ in range(4)]
    tokens = [jwt(user, os.environ["MATCH_TEST_JWT_SECRET"].encode()) for user in people]
    venue = str(uuid4())
    loc = timezone(timedelta(hours=8))
    start = (datetime.now(loc) + timedelta(days=2)).replace(hour=12, minute=0, second=0, microsecond=0)
    waiting = {"p_area": "徐汇", "p_distance": 4, "p_preference": "quiet",
               "p_start": start.isoformat(), "p_end": (start + timedelta(hours=2)).isoformat()}

    def invoke(n, fn, **body):
        return call(url, tokens[n], fn, body)

    def submit(n, nonce):
        return invoke(n, "blind_join", **waiting, p_nonce=nonce)

    def parallel(jobs):
        gate = Barrier(len(jobs))

        def run(job):
            gate.wait(timeout=8)
            return job()

        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            return list(pool.map(run, jobs))

    try:
        sql(f"""insert into matching.blind_venues(id,name,address,atmosphere,weekdays,opens,closes,
                is_public,accessible,safety_reviewed,verified_until,demo) values
                ('{venue}','TEST ONLY','FICTIONAL ADDRESS','quiet','{{1,2,3,4,5,6,7}}','09:00',
                '17:00',true,true,true,now()+interval '8 days',false);
                insert into matching.blind_reach values ('{venue}','徐汇',3);""")
        call(url, None, "blind_state", denied=True)
        for n, user in enumerate(people):
            sql(f"insert into auth.users(id,email,email_confirmed_at) values "
                f"('{user}','{user}@example.test',now())")
            invoke(n, "matching_enroll", p_adult=True)
        nonces = [str(uuid4()) for _ in people]
        parallel([lambda n=n: submit(n, nonces[n]) for n in (0, 1, 0, 1)])
        states = [invoke(n, "blind_state") for n in (0, 1)]
        check(all(s["status"] == "proposed" and "venue_address" not in s and "starts_at" not in s
                  for s in states), "simultaneous joins should form one concealed proposal")
        check(invoke(2, "blind_state")["status"] == "idle", "outsider acquired proposal")
        call(url, tokens[2], "blind_act", {"p_id": states[0]["id"], "p_action": "confirm"}, denied=True)

        def act(n, decision):
            return invoke(n, "blind_act", p_id=states[n]["id"], p_action=decision)

        confirmed = parallel([lambda: act(0, "confirm"), lambda: act(0, "confirm")])
        check(all(s["status"] == "proposed" and "venue_address" not in s for s in confirmed),
              "replayed consent disclosed a venue")
        check(act(1, "confirm").get("venue_address") == "FICTIONAL ADDRESS",
              "mutual consent must reveal venue")
        # Move only this synthetic appointment past its end, to drive post-meeting decisions.
        sql(f"""update matching.blind_meetings set starts_at=now()-interval '2 hours',
                 confirm_by=now()-interval '3 hours' where venue='{venue}';""")
        parallel([lambda: act(0, "complete"), lambda: act(1, "complete")])
        check(act(0, "continue")["status"] == "completed", "one opt-in opened a connection")
        check(act(1, "continue")["status"] == "connected", "two opt-ins failed to connect")
        invoke(0, "matching_safety", p_kind="blind", p_id=states[0]["id"],
               p_action="block", p_reason="")
        results = parallel([lambda: submit(0, str(uuid4())), lambda: submit(1, str(uuid4()))])
        check(all(s["status"] == "waiting" for s in results), "blocked pair reunited")
        for n, s in enumerate(results):
            invoke(n, "blind_act", p_id=s["id"], p_action="cancel")
        proposal = submit(2, nonces[2])
        check(proposal["status"] == "waiting", "cancelled tickets matched a new arrival")
        check(submit(3, nonces[3])["status"] == "proposed", "unrelated pair cannot match")
        invoke(3, "matching_delete")
        closed = invoke(2, "blind_state")
        check(closed["status"] == "cancelled" and "venue_address" not in closed,
              "deleted participant left a usable encounter")
        print("Blind HTTP scenario passed: two authenticated clients, concurrent consent, controlled venue disclosure, "
              "mutual continuation, block, cancellation and deletion.")
    finally:
        sql(f"delete from auth.users where id in ({','.join(repr(u) for u in people)});"
            f"delete from matching.blind_venues where id='{venue}';"
            "select matching.blind_sweep();")


if __name__ == "__main__":
    main()
