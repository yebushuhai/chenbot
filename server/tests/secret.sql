-- Run with the matching migrations installed, using a disposable test database.
begin;
insert into auth.users(id,email,email_confirmed_at) values
  ('22000000-0000-4000-8000-000000000001','secret-a@example.test',now()),
  ('22000000-0000-4000-8000-000000000002','secret-b@example.test',now()),
  ('22000000-0000-4000-8000-000000000003','secret-c@example.test',now());

create function pg_temp.as_secret_user(n integer) returns void language plpgsql as $$
declare u text := '22000000-0000-4000-8000-' || lpad(n::text,12,'0');
begin
  perform set_config('request.jwt.claim.sub',u,true);
  perform set_config('request.jwt.claims',json_build_object('sub',u,'role','authenticated')::text,true);
end;
$$;
create function pg_temp.check_secret(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Secret Match assertion failed: %', label; end if;
end;
$$;

set local role authenticated;
do $$
declare
  req_a jsonb;
  req_b jsonb;
  res jsonb;
  nonce_a uuid := gen_random_uuid();
  nonce_b uuid := gen_random_uuid();
  mismatch_id uuid;
begin
  for n in 1..3 loop
    perform pg_temp.as_secret_user(n);
    perform public.matching_enroll(true);
    perform pg_temp.check_secret(public.secret_state() = '{"status":"idle"}'::jsonb, 'initial state');
  end loop;
  perform pg_temp.as_secret_user(1);
  req_a := public.secret_join(repeat('a',64), nonce_a);
  perform pg_temp.check_secret(req_a->>'status' = 'waiting', 'sole applicant waits');
  perform pg_temp.check_secret(public.secret_join(repeat('a',64),nonce_a) = req_a,'idempotent join');
  begin
    perform public.secret_join('a phrase or a surname',gen_random_uuid());
    raise exception 'raw phrase accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.secret_join(repeat('d',64),nonce_a);
    raise exception 'reused nonce allowed a different token';
  exception when invalid_parameter_value then null;
  end;
  perform pg_temp.as_secret_user(2);
  res := public.secret_join(repeat('b',64),gen_random_uuid());
  mismatch_id := (res->>'id')::uuid;
  perform pg_temp.check_secret(res->>'status' = 'waiting','different token is not a match');
  begin
    perform public.secret_act((req_a->>'id')::uuid,'withdraw');
    raise exception 'foreign request mutated';
  exception when insufficient_privilege then null;
  end;
  perform public.secret_act(mismatch_id,'withdraw');
  req_b := public.secret_join(repeat('a',64),nonce_b);
  perform pg_temp.check_secret(req_b->>'status' = 'connected','second opt-in forms connection');
  perform pg_temp.as_secret_user(1);
  res := public.secret_state();
  perform pg_temp.check_secret(res->>'status' = 'connected' and
    res->>'connection_id' = req_b->>'connection_id','both actors see same anonymous connection');
  perform pg_temp.check_secret((res - 'status' - 'id' - 'connection_id') = '{}'::jsonb, 'no extra identities or tokens');
  begin
    perform token from matching.secret_requests;
    raise exception 'raw token table readable to client';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_secret_user(3);
  perform pg_temp.check_secret(public.secret_state() = '{"status":"idle"}'::jsonb, 'unrelated account sees nothing');

  perform pg_temp.as_secret_user(2);
  perform public.secret_act((req_b->>'id')::uuid,'withdraw');
  perform pg_temp.as_secret_user(1);
  perform pg_temp.check_secret(public.secret_state()->>'status' = 'withdrawn','revocation closes both sides');
  perform pg_temp.check_secret(public.secret_join(repeat('a',64),nonce_a)->>'status' = 'withdrawn','old join never revives');
end;
$$;
reset role;

do $$
declare r jsonb; n uuid := gen_random_uuid(); b uuid;
begin
  perform pg_temp.check_secret(not exists(select 1 from matching.secret_requests where token is not null),
    'no bearer tokens on closed rows');
  perform pg_temp.as_secret_user(1);
  r := public.secret_join(repeat('e',64),n);
  perform pg_temp.check_secret(exists(
    select 1 from matching.secret_requests where id = (r->>'id')::uuid and token <> repeat('e',64)),
    'database does not store the replayable wire token');
  update matching.secret_requests set expires_at = clock_timestamp() - interval '1 second' where id = (r->>'id')::uuid;
  perform pg_temp.as_secret_user(2);
  r := public.secret_join(repeat('e',64),gen_random_uuid());
  b := (r->>'id')::uuid;
  perform pg_temp.check_secret(r->>'status' = 'waiting','expired token cannot match even before sweep');
  perform pg_temp.as_secret_user(1);
  perform pg_temp.check_secret(public.secret_join(repeat('e',64),n)->>'status' = 'expired','expired nonce cannot rejoin');
  perform pg_temp.check_secret(not exists(
    select 1 from matching.secret_requests where owner = auth.uid() and token is not null),'expired token erased');
  perform pg_temp.as_secret_user(2);
  perform public.secret_act(b,'withdraw');
end;
$$;

do $$
declare request jsonb; first_nonce uuid := gen_random_uuid(); n uuid;
begin
  perform pg_temp.as_secret_user(3);
  for submission in 1..8 loop
    n := case when submission = 1 then first_nonce else gen_random_uuid() end;
    request := public.secret_join(repeat('9',64),n);
    perform public.secret_act((request->>'id')::uuid,'withdraw');
  end loop;
  begin
    perform public.secret_join(repeat('9',64),gen_random_uuid());
    raise exception 'expected ninth creation to fail' using errcode='XX000';
  exception when raise_exception then
    if sqlerrm <> 'rate_limit' then raise; end if;
  end;
  update matching.secret_requests set expires_at = now() - interval '32 days' where nonce = first_nonce;
  perform matching.secret_sweep();
  perform pg_temp.check_secret(not exists(select 1 from matching.secret_requests where nonce = first_nonce),
                               'old terminal metadata purged');
  begin
    perform public.secret_join(repeat('9',64),first_nonce);
    raise exception 'purged nonce was revived' using errcode='XX000';
  exception when invalid_parameter_value then
    if sqlerrm <> 'stale_nonce' then raise; end if;
  end;
end;
$$;
rollback;
