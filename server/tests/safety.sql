-- Test only. Exercise authorization as PostgREST's authenticated role, then
-- use the fixture owner to inspect retention, TTL and FK cleanup. Roll back all.
begin;
create function pg_temp.safety_uid(n integer) returns uuid language sql immutable as $$
  select ('48000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid
$$;
create function pg_temp.as_safety_user(n integer) returns void language plpgsql as $$
declare u uuid := pg_temp.safety_uid(n);
begin
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',json_build_object('role','authenticated','sub',u)::text,true);
end;
$$;
create function pg_temp.require_safety(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'safety assertion failed: %', label; end if;
end;
$$;
create function pg_temp.check_history(p_kind text, p_source text, p_id uuid) returns void language plpgsql as $$
declare history jsonb := public.matching_safety_history(); item jsonb := history->0;
begin
  perform pg_temp.require_safety(jsonb_array_length(history)=1 and item->>'kind'=p_kind
    and item->>'source'=p_source and (item->>'id')::uuid=p_id and item ? 'created_at',
    'retained handle belongs to the original relationship');
  perform pg_temp.require_safety((item - 'kind' - 'source' - 'id' - 'created_at')='{}'::jsonb,
    'history discloses only opaque handle, source and time');
end;
$$;

insert into auth.users(id,email,email_confirmed_at)
select pg_temp.safety_uid(n),'safety-'||n||'@example.test',now() from generate_series(1,7) n;
insert into matching.blind_venues(id,name,address,atmosphere,weekdays,opens,closes,is_public,accessible,safety_reviewed,verified_until,demo)
values('48999999-0000-4000-8000-000000000001','SAFETY FIXTURE','FICTIONAL ADDRESS',
 'quiet','{1,2,3,4,5,6,7}','09:00','18:00',true,true,true,now()+interval '7 days',true);
insert into matching.blind_reach(venue,area,distance_km) values('48999999-0000-4000-8000-000000000001','静安',1);
update matching.blind_venue_policy set demo_enabled=true;

set local role authenticated;
do $$
declare
  a jsonb;
  b jsonb;
  link uuid;
  meeting uuid;
  starts timestamptz := (((now() at time zone 'Asia/Shanghai')::date+2)+time '12:00') at time zone 'Asia/Shanghai';
begin
  for n in 1..7 loop
    perform pg_temp.as_safety_user(n);
    perform public.matching_enroll(true);
  end loop;

  -- Secret connection: B deletes discovery. A can still file a single report,
  -- but neither the former chat nor any identity fields are returned.
  perform pg_temp.as_safety_user(1);
  a := public.secret_join(repeat('1',64),gen_random_uuid());
  perform pg_temp.as_safety_user(2);
  b := public.secret_join(repeat('1',64),gen_random_uuid());
  link := (b->>'connection_id')::uuid;
  perform pg_temp.require_safety(b->>'status'='connected','secret pair created');
  perform public.matching_delete();
  perform public.matching_enroll(true);
  perform pg_temp.require_safety(public.matching_safety_history()='[]'::jsonb,'deleted own history erased');
  perform pg_temp.as_safety_user(1);
  perform pg_temp.check_history('connection','secret',link);
  perform pg_temp.require_safety(public.matching_connections()='[]'::jsonb,'no live chat after deletion');
  begin
    perform public.matching_messages(link);
    raise exception 'retained handle reopened chat';
  exception when insufficient_privilege then null;
  end;
  perform public.matching_safety('connection',link,'block','');
  perform public.matching_safety('connection',link,'report','harassment');
  perform public.matching_safety('connection',link,'report','other');
  perform pg_temp.check_history('connection','secret',link);

  -- C is not in the pair, even if the connection or request UUID is known.
  perform pg_temp.as_safety_user(3);
  perform pg_temp.require_safety(public.matching_safety_history()='[]'::jsonb,'outsider cannot list history');
  begin
    perform public.matching_safety('connection',link,'report','harassment');
    raise exception 'outsider used foreign history';
  exception when insufficient_privilege then null;
  end;
  begin
    perform peer from matching.safety_contexts;
    raise exception 'safety table readable';
  exception when insufficient_privilege then null;
  end;

  -- Unconfirmed Blind proposal. D must still be able to report after E
  -- deletes discovery. The retained handle cannot disclose the venue.
  perform pg_temp.as_safety_user(4);
  a := public.blind_join('静安',starts,starts+interval '2 hours',3,'quiet',gen_random_uuid());
  meeting := (a->>'id')::uuid;
  perform pg_temp.as_safety_user(5);
  b := public.blind_join('静安',starts,starts+interval '2 hours',3,'quiet',gen_random_uuid());
  perform pg_temp.require_safety(b->>'status'='proposed','blind pair proposed');
  perform public.matching_delete();
  perform pg_temp.as_safety_user(4);
  perform pg_temp.check_history('blind','blind',meeting);
  a := public.blind_state();
  perform pg_temp.require_safety(a->>'status'='cancelled' and not(a ?| array['venue_address','starts_at','venue_name']),
    'deleted proposal permanently conceals location');
  perform public.matching_safety('blind',meeting,'report','unsafe');
  perform public.matching_safety('blind',meeting,'report','unsafe');
  perform pg_temp.as_safety_user(3);
  begin
    perform public.matching_safety('blind',meeting,'report','unsafe');
    raise exception 'outsider reported a foreign proposal';
  exception when insufficient_privilege then null;
  end;

  -- Verify that a hard owner-side auth deletion of a participant in a live
  -- connection (not just discovery deletion) remains a valid FK cascade.
  perform pg_temp.as_safety_user(6);
  perform public.secret_join(repeat('f',64),gen_random_uuid());
  perform pg_temp.as_safety_user(7);
  b := public.secret_join(repeat('f',64),gen_random_uuid());
  perform pg_temp.require_safety(b->>'status'='connected','hard-delete fixture connected');
end;
$$;
reset role;
select pg_temp.require_safety(
  (select count(*)=1 and bool_and(subject=pg_temp.safety_uid(2) and reason='harassment')
   from matching.reports where reporter=pg_temp.safety_uid(1)) and
  (select count(*)=1 and bool_and(subject=pg_temp.safety_uid(5) and reason='unsafe')
   from matching.reports where reporter=pg_temp.safety_uid(4)), 'report delivery and idempotency');
select pg_temp.require_safety(
  (select count(*)=1 from matching.blocks where by_user=pg_temp.safety_uid(1) and against=pg_temp.safety_uid(2)),
  'block and report share durable safety block');

delete from auth.users where id in(pg_temp.safety_uid(2),pg_temp.safety_uid(7));
select pg_temp.require_safety(
  not exists(select 1 from matching.safety_contexts
             where peer in(pg_temp.safety_uid(2),pg_temp.safety_uid(7))
                or owner in(pg_temp.safety_uid(2),pg_temp.safety_uid(7))) and
  (select count(*)=1 and bool_and(subject is null) from matching.reports where reporter=pg_temp.safety_uid(1)),
  'hard auth deletion removes identifying handles and anonymizes existing report');
set local role authenticated;
select pg_temp.as_safety_user(6);
select pg_temp.require_safety(public.matching_connections()='[]'::jsonb and
                             public.matching_safety_history()='[]'::jsonb,
                             'hard-deleted peer leaves no active or dangling history');
reset role;

-- Simulate 31 days of retention elapsing. Read and action must both deny a
-- stale handle before the periodic physical sweep runs.
update matching.safety_contexts set created_at=now()-interval '32 days' where owner=pg_temp.safety_uid(4);
do $$
declare ref_id uuid;
begin
  select ref into strict ref_id from matching.safety_contexts where owner=pg_temp.safety_uid(4);
  perform pg_temp.as_safety_user(4);
  perform pg_temp.require_safety(public.matching_safety_history()='[]'::jsonb,'retention window enforced on reads');
  begin
    perform public.matching_safety('blind',ref_id,'report','unsafe');
    raise exception 'expired retained handle accepted';
  exception when insufficient_privilege then null;
  end;
  perform matching.maintain();
  perform pg_temp.require_safety(not exists(select 1 from matching.safety_contexts where owner=pg_temp.safety_uid(4)),
                               'expired handle physically purged');
end;
$$;
rollback;
