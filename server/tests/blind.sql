-- RPC integration against a disposable PostgreSQL database. All test data rolls back.
begin;
insert into auth.users(id,email,email_confirmed_at)
 select ('31000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'blind-'||n||'@example.test',now() from generate_series(1,8) n;
create function pg_temp.blind_user(n int) returns void language plpgsql as $$
declare u text:='31000000-0000-4000-8000-'||lpad(n::text,12,'0');
begin
 perform set_config('request.jwt.claim.sub',u,true);
 perform set_config('request.jwt.claims',json_build_object('sub',u,'role','authenticated')::text,true);
end $$;
create function pg_temp.blind_assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Blind assertion failed: %',label; end if; end $$;
-- Run cases on a known weekday/time, irrespective of host timezone.
create function pg_temp.blind_start() returns timestamptz language sql stable as $$
 select (((now() at time zone 'Asia/Shanghai')::date+2)+time '12:00') at time zone 'Asia/Shanghai'
$$;
create function pg_temp.blind_join(area text,pref text,km int,n uuid default gen_random_uuid(),offset_hours int default 0)
returns jsonb language sql as $$
 select public.blind_join(area,pg_temp.blind_start()+offset_hours*interval '1 hour',
 pg_temp.blind_start()+(offset_hours+2)*interval '1 hour',km,pref,n)
$$;

-- Two inspected fictional test rows are never persisted to an operational database.
delete from matching.blind_reach;
delete from matching.blind_venues;
update matching.blind_venue_policy set demo_enabled=false;
insert into matching.blind_venues(id,name,address,atmosphere,weekdays,opens,closes,is_public,accessible,safety_reviewed,verified_until,demo)
 values('31999999-0000-4000-8000-000000000001','TEST','TEST ADDRESS','quiet','{1,2,3,4,5,6,7}','10:00','17:00',true,true,true,now()+interval '10 days',true);
insert into matching.blind_reach(venue,area,distance_km)
 values('31999999-0000-4000-8000-000000000001','静安',2),('31999999-0000-4000-8000-000000000001','徐汇',6);

set local role authenticated;
do $$
declare nonce_a uuid:=gen_random_uuid(); result jsonb; first_req jsonb; other_req jsonb; exposed boolean;
begin
 for i in 1..8 loop
  perform pg_temp.blind_user(i);
  perform public.matching_enroll(true);
  perform pg_temp.blind_assert(public.blind_state()='{"status":"idle"}','initial idle');
 end loop;
 perform pg_temp.blind_user(1); first_req:=pg_temp.blind_join('静安','quiet',3,nonce_a);
 perform pg_temp.blind_assert(first_req->>'status'='waiting','unmatched waits');
 perform pg_temp.blind_assert(pg_temp.blind_join('静安','quiet',3,nonce_a)=first_req,'submission retry');
 perform pg_temp.blind_user(2); other_req:=pg_temp.blind_join('徐汇','any',8);
 perform pg_temp.blind_assert(other_req->>'status'='waiting','fixture cannot match in production');
 exposed:=false;
 begin perform public.blind_act((first_req->>'id')::uuid,'cancel'); exposed:=true; exception when others then null; end;
 perform pg_temp.blind_assert(not exposed,'foreign request manipulation denied');
 begin perform address from matching.blind_venues; exposed:=true; exception when insufficient_privilege then null; end;
 perform pg_temp.blind_assert(not exposed,'raw venues cannot be queried');
end $$;
reset role;
update matching.blind_venue_policy set demo_enabled=true;
-- Reusable catalog provider must honor public-space review, opening hours and verification expiry.
do $$
declare a matching.blind_requests; b matching.blind_requests; venue uuid:='31999999-0000-4000-8000-000000000001';
begin
 select * into strict a from matching.blind_requests where owner_id='31000000-0000-4000-8000-000000000001';
 select * into strict b from matching.blind_requests where owner_id='31000000-0000-4000-8000-000000000002';
 perform pg_temp.blind_assert(exists(select from matching.blind_options(a,b)),'open verified venue available');
 update matching.blind_venues set safety_reviewed=false where id=venue;
 perform pg_temp.blind_assert(not exists(select from matching.blind_options(a,b)),'unreviewed venue excluded');
 update matching.blind_venues set safety_reviewed=true,verified_until=pg_temp.blind_start()+interval '30 minutes' where id=venue;
 perform pg_temp.blind_assert(not exists(select from matching.blind_options(a,b)),'verification must cover whole appointment');
 update matching.blind_venues set verified_until=now()+interval '10 days',closes=time '12:30' where id=venue;
 perform pg_temp.blind_assert(not exists(select from matching.blind_options(a,b)),'early closing excludes venue');
 update matching.blind_venues set opens=time '13:00',closes=time '16:00' where id=venue;
 perform pg_temp.blind_assert((select starts_at=pg_temp.blind_start()+interval '1 hour' from matching.blind_options(a,b)),
  'later opening within shared window is usable');
 update matching.blind_venues set opens=time '10:00',closes=time '17:00' where id=venue;
end $$;
set local role authenticated;
do $$
declare a jsonb; b jsonb; exposed boolean:=false;
begin
 perform pg_temp.blind_user(1); a:=public.blind_state();
 perform pg_temp.blind_assert(a->>'status'='proposed' and (a->>'venue_demo')::boolean and
   not (a ?| array['starts_at','venue_address','venue_name','peer_id','email']),'proposal conceals location, time, identity');
 a:=public.blind_act((a->>'id')::uuid,'confirm');
 perform pg_temp.blind_assert(a->>'status'='proposed' and (a->>'mine_confirmed')::boolean and
   not(a ? 'venue_address'),'one confirmation reveals nothing');
 perform pg_temp.blind_assert(public.blind_act((a->>'id')::uuid,'confirm')=a,'confirmation retry');
 perform pg_temp.blind_user(2); b:=public.blind_state();
 perform pg_temp.blind_assert(not (b ? 'starts_at') and not (b->>'mine_confirmed')::boolean,'peer still unconfirmed');
 b:=public.blind_act((b->>'id')::uuid,'confirm');
 perform pg_temp.blind_assert(b->>'venue_address'='TEST ADDRESS' and b->>'status'='confirmed','mutual disclosure');
 perform pg_temp.blind_user(1);
 perform pg_temp.blind_assert(public.blind_state()->>'venue_address'=b->>'venue_address','same proposal for both');
 begin perform public.blind_act((a->>'id')::uuid,'complete'); exposed:=true; exception when others then null; end;
 perform pg_temp.blind_assert(not exposed,'cannot complete before date');
 perform pg_temp.blind_user(3);
 perform pg_temp.blind_assert(public.blind_state()='{"status":"idle"}','outsider sees no meeting');
end $$;
reset role;
-- A second anonymous pair at a popular venue can be assigned a later, disjoint hour.
do $$
declare a matching.blind_requests; b matching.blind_requests;
begin
 select * into strict a from matching.blind_requests where owner_id='31000000-0000-4000-8000-000000000001';
 select * into strict b from matching.blind_requests where owner_id='31000000-0000-4000-8000-000000000002';
 perform pg_temp.blind_assert((select starts_at=pg_temp.blind_start()+interval '1 hour' from matching.blind_options(a,b)),
   'existing proposal reserves its venue for the entire hour');
 a.available_to:=pg_temp.blind_start()+interval '1 hour';
 perform pg_temp.blind_assert(not exists(select 1 from matching.blind_options(a,b)), 'no duplicate booking when latest time too early');
end $$;
update matching.blind_meetings set starts_at=now()-interval '2 hours',confirm_by=now()-interval '3 hours';
set local role authenticated;
do $$
declare r jsonb;
begin
 perform pg_temp.blind_user(1); r:=public.blind_state();
 perform pg_temp.blind_assert((r->>'can_complete')::boolean and not (r ? 'venue_address'),'address withdrawn after meeting');
 perform public.blind_act((r->>'id')::uuid,'complete'); r:=public.blind_act((r->>'id')::uuid,'continue');
 perform pg_temp.blind_assert(r->>'status'='completed','one vote creates no connection');
 perform pg_temp.blind_user(2); r:=public.blind_state();
 perform public.blind_act((r->>'id')::uuid,'complete'); r:=public.blind_act((r->>'id')::uuid,'continue');
 perform pg_temp.blind_assert(r->>'status'='connected','both vote to connect');
 perform pg_temp.blind_assert(public.blind_act((r->>'id')::uuid,'continue')=r,'final consent replay');
end $$;
reset role;
select pg_temp.blind_assert((select count(*) from matching.connections where source='blind')=1,'one connection');

set local role authenticated;
do $$
declare r jsonb; nonce_a uuid:=gen_random_uuid();
begin
 perform pg_temp.blind_user(3); r:=pg_temp.blind_join('静安','quiet',3,nonce_a);
 perform pg_temp.blind_user(4); r:=pg_temp.blind_join('徐汇','any',1);
 perform pg_temp.blind_assert(r->>'status'='waiting','outside travel radius');
 perform public.blind_act((r->>'id')::uuid,'cancel');
 r:=pg_temp.blind_join('徐汇','lively',8);
 perform pg_temp.blind_assert(r->>'status'='waiting','incompatible preference');
 perform public.blind_act((r->>'id')::uuid,'cancel');
 r:=pg_temp.blind_join('徐汇','any',8,gen_random_uuid(),3);
 perform pg_temp.blind_assert(r->>'status'='waiting','no overlap');
 perform public.blind_act((r->>'id')::uuid,'cancel');
 r:=pg_temp.blind_join('徐汇','any',8); perform pg_temp.blind_assert(r->>'status'='proposed','compatible');
 perform public.blind_act((r->>'id')::uuid,'cancel');
 perform pg_temp.blind_user(3); r:=pg_temp.blind_join('静安','quiet',3,nonce_a);
 perform pg_temp.blind_assert(r->>'status'='cancelled' and (r->>'had_peer')::boolean,'withdrawn proposal replay stays closed');
end $$;
reset role;
-- Proposals are invalidated if reviewers change the chosen venue.
set local role authenticated;
select pg_temp.blind_user(5); select pg_temp.blind_join('静安','quiet',3);
select pg_temp.blind_user(6); select pg_temp.blind_join('静安','quiet',3);
reset role;
update matching.blind_venues set name='TEST 2';
set local role authenticated;
select pg_temp.blind_assert(public.blind_state()->>'status'='cancelled','no venue replacement without new consent');
select pg_temp.blind_user(7); select pg_temp.blind_join('静安','quiet',3);
select pg_temp.blind_user(8); select pg_temp.blind_join('徐汇','quiet',8);
reset role;
delete from matching.members where user_id='31000000-0000-4000-8000-000000000007';
set local role authenticated;
select pg_temp.blind_assert(public.blind_state()->>'status'='expired','deleted participant cannot produce or reveal matchup');
reset role;
-- Force a live proposal past its confirmation deadline and retry previously valid consent.
set local role authenticated;
select pg_temp.blind_user(5); select pg_temp.blind_join('静安','quiet',3);
select pg_temp.blind_user(6); select pg_temp.blind_join('静安','quiet',3);
reset role;
update matching.blind_meetings set confirm_by=now()-interval '1 second'
 where id in(select meeting from matching.blind_requests where status='proposed');
set local role authenticated;
do $$
declare r jsonb;
begin
 r:=public.blind_state();
 perform pg_temp.blind_assert(r->>'status'='expired','expired confirmation deadline');
 r:=public.blind_act((r->>'id')::uuid,'confirm');
 perform pg_temp.blind_assert(r->>'status'='expired' and not(r ? 'venue_name'),'expired proposal replay never revives');
end $$;
-- Removed discovery data may be recreated; delayed HTTP retries must not re-enroll an old request.
do $$
declare nonce uuid:=gen_random_uuid(); accepted boolean:=false;
begin
 perform pg_temp.blind_join('静安','quiet',3,nonce);
 perform public.matching_delete();
 perform public.matching_enroll(true);
 begin perform pg_temp.blind_join('静安','quiet',3,nonce); accepted:=true; exception when invalid_parameter_value then null; end;
 perform pg_temp.blind_assert(not accepted and public.blind_state()->>'status'='idle','deleted request replay after re-enrollment');
end $$;
reset role;
rollback;
