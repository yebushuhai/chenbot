-- Requires 002_matching. Apply once as a trusted migration owner.
begin;
-- Venue provider contract: an audited public venue, its daily local opening window
-- and upward-rounded distances from fixed area reference points. Missing distances
-- are unknown, never zero. The client has no access to this catalog.
create table matching.blind_areas (
  name text primary key,
  reference_point text not null
);
insert into matching.blind_areas values
  ('静安','静安寺'),('徐汇','徐家汇'),('黄浦','人民广场'),('长宁','中山公园'),('浦东','世纪大道地铁站');

create table matching.blind_venue_policy (
  singleton boolean primary key default true check(singleton),
  demo_enabled boolean not null default false
);
insert into matching.blind_venue_policy default values;
create table matching.blind_venues (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 100),
  address text not null check (length(btrim(address)) between 1 and 200),
  atmosphere text not null check (atmosphere in ('quiet','lively')),
  weekdays smallint[] not null check(cardinality(weekdays)>0 and array_position(weekdays,null) is null and weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),
  opens time not null, closes time not null check(closes > opens),
  is_public boolean not null default false,
  accessible boolean not null default false,
  safety_reviewed boolean not null default false,
  verified_until timestamptz not null,
  demo boolean not null default false
);
create table matching.blind_reach (
  venue uuid not null references matching.blind_venues on delete cascade,
  area text not null references matching.blind_areas,
  distance_km integer not null check(distance_km between 1 and 100),
  primary key(venue,area)
);
create view matching.blind_eligible_venues as
 select v.* from matching.blind_venues v cross join matching.blind_venue_policy p
 where v.demo = p.demo_enabled and v.is_public and v.accessible and v.safety_reviewed and v.verified_until > clock_timestamp();

create table matching.blind_meetings (
  id uuid primary key default gen_random_uuid(),
  venue uuid references matching.blind_venues on delete set null,
  starts_at timestamptz not null,
  confirm_by timestamptz not null check(confirm_by < starts_at)
);
create index blind_venue_slots on matching.blind_meetings(venue,starts_at);
create table matching.blind_requests (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references matching.members(user_id) on delete cascade,
  nonce uuid not null,
  area text not null references matching.blind_areas,
  available_from timestamptz not null, available_to timestamptz not null,
  distance_km integer not null check(distance_km between 1 and 50),
  preference text not null check(preference in ('any','quiet','lively')),
  meeting uuid references matching.blind_meetings,
  status text not null default 'waiting' check(status in ('waiting','proposed','confirmed','completed','connected','cancelled','expired')),
  agreed boolean not null default false, opted_in boolean not null default false,
  created_at timestamptz not null default clock_timestamp(), ended_at timestamptz,
  unique(owner_id,nonce), check(available_to-available_from between interval '1 hour' and interval '8 hours')
);
create unique index blind_one_active on matching.blind_requests(owner_id)
 where status in ('waiting','proposed','confirmed','completed');
create index blind_queue on matching.blind_requests(available_to,created_at) where status='waiting';
create index blind_meeting_members on matching.blind_requests(meeting) where meeting is not null;
create index blind_retention on matching.blind_requests(ended_at) where ended_at is not null;

-- Venue imports and RPCs take the same transaction lock BEFORE any row locks.
-- A reviewer may change or close a venue while users are accepting a proposal.
create function matching.blind_lock_catalog() returns trigger language plpgsql set search_path='' as $$
begin
  perform pg_advisory_xact_lock(69383720414::bigint);
  return null;
end $$;
create trigger blind_catalog_lock before insert or update or delete on matching.blind_venues
  for each statement execute function matching.blind_lock_catalog();
create trigger blind_reach_lock before insert or update or delete on matching.blind_reach
  for each statement execute function matching.blind_lock_catalog();
create trigger blind_mode_lock before insert or update or delete on matching.blind_venue_policy
  for each statement execute function matching.blind_lock_catalog();

-- Venue safety or access edits invalidate pending/upcoming proposals. This
-- avoids revealing a changed address under an earlier consent.
create function matching.blind_venue_changed() returns trigger language plpgsql set search_path='' as $$
declare key uuid;
begin
  if tg_table_name='blind_venues' then key:=old.id; else key:=old.venue; end if;
  update matching.blind_requests r set status='cancelled',ended_at=clock_timestamp()
  from matching.blind_meetings m where r.meeting=m.id and m.venue=key and
    m.starts_at+interval '1 hour'>clock_timestamp() and r.status in ('proposed','confirmed');
  return old;
end $$;
create trigger blind_catalog_updated after update or delete on matching.blind_venues
  for each row execute function matching.blind_venue_changed();
create trigger blind_reach_updated after update or delete on matching.blind_reach
  for each row execute function matching.blind_venue_changed();

create function matching.blind_peer(p_actor uuid,p_request uuid) returns uuid
language sql stable set search_path='' as $$
  select peer.owner_id from matching.blind_requests r join matching.blind_requests peer
    on peer.meeting=r.meeting and peer.id<>r.id
  where r.owner_id=p_actor and r.id=p_request
$$;

create function matching.blind_invalidate(a uuid,b uuid) returns void
language sql set search_path='' as $$
 update matching.blind_requests r set status='cancelled',ended_at=clock_timestamp()
 where r.owner_id in (a,b) and r.status in ('proposed','confirmed','completed','connected')
 and exists(select 1 from matching.blind_requests peer where peer.meeting=r.meeting and peer.owner_id in(a,b) and peer.owner_id<>r.owner_id)
$$;

create function matching.blind_sweep() returns void language plpgsql set search_path='' as $$
begin
  update matching.blind_requests set status='expired',ended_at=clock_timestamp()
    where status='waiting' and available_to < clock_timestamp()+interval '1 hour 10 minutes';
  update matching.blind_requests r set status='expired',ended_at=clock_timestamp()
    from matching.blind_meetings m where r.meeting=m.id and
    ((r.status='proposed' and m.confirm_by<=clock_timestamp()) or
     (r.status in ('confirmed','completed') and m.starts_at+interval '3 days'<=clock_timestamp()) or
     (r.status in ('proposed','confirmed','completed','connected') and
       not exists (select 1 from matching.blind_requests peer where peer.meeting=m.id and peer.owner_id<>r.owner_id
                   and not matching.blocked(peer.owner_id,r.owner_id))) or
     (r.status in ('proposed','confirmed') and m.starts_at+interval '1 hour'>clock_timestamp() and not exists (
        select 1 from matching.blind_eligible_venues v where v.id=m.venue and v.verified_until>=m.starts_at+interval '1 hour'
        and extract(isodow from m.starts_at at time zone 'Asia/Shanghai')=any(v.weekdays)
        and (m.starts_at at time zone 'Asia/Shanghai')::time>=v.opens
        and ((m.starts_at at time zone 'Asia/Shanghai')::date+v.closes) >= ((m.starts_at+interval '1 hour') at time zone 'Asia/Shanghai')
     )));
  delete from matching.blind_requests where ended_at <= clock_timestamp()-interval '31 days';
  delete from matching.blind_meetings m where not exists (select 1 from matching.blind_requests r where r.meeting=m.id);
end $$;

-- Selection interface can be replaced by a reviewed venue provider or routing
-- backend as long as it returns an eligible venue and a mutually valid slot.
create function matching.blind_options(a matching.blind_requests,b matching.blind_requests)
returns table(venue uuid,starts_at timestamptz)
language sql set search_path='' as $$
  with bounds as (
    select greatest(a.available_from,b.available_from,clock_timestamp()+interval '10 minutes') as earliest,
           least(a.available_to,b.available_to) as latest
  ), reserved as materialized (
    select m.venue,m.starts_at as start_at,m.starts_at+interval '1 hour' as finish
    from matching.blind_meetings m cross join bounds
    where m.starts_at<latest and m.starts_at+interval '1 hour'>earliest
      and exists (select 1 from matching.blind_requests r where r.meeting=m.id
        and (r.status='confirmed' or (r.status='proposed' and m.confirm_by>clock_timestamp())))
  )
  select v.id, min(slot.start_at)
    from matching.blind_eligible_venues v join matching.blind_reach ar on ar.venue=v.id and ar.area=a.area and ar.distance_km<=a.distance_km
    join matching.blind_reach br on br.venue=v.id and br.area=b.area and br.distance_km<=b.distance_km
    cross join bounds
    cross join lateral generate_series((earliest at time zone 'Asia/Shanghai')::date::timestamp,
                                       (latest at time zone 'Asia/Shanghai')::date::timestamp,
                                       interval '1 day') as day(local_day)
    cross join lateral (select greatest(earliest,(local_day::date+v.opens) at time zone 'Asia/Shanghai') as first_slot) opening
    cross join lateral (
      select first_slot as start_at union all
      select finish from reserved where reserved.venue=v.id and finish>first_slot
    ) slot
    where (a.preference='any' or a.preference=v.atmosphere) and (b.preference='any' or b.preference=v.atmosphere)
    and not exists(select 1 from reserved busy where busy.venue=v.id and
                   busy.start_at<slot.start_at+interval '1 hour' and busy.finish>slot.start_at)
    and extract(isodow from local_day)=any(v.weekdays)
    and slot.start_at+interval '1 hour'<=least(latest,(local_day::date+v.closes) at time zone 'Asia/Shanghai',v.verified_until)
    group by v.id
$$;

create function matching.blind_try(p_request uuid) returns void language plpgsql set search_path='' as $$
declare me matching.blind_requests; candidate record; event_id uuid;
begin
  select * into me from matching.blind_requests where id=p_request and status='waiting';
  if not found then return; end if;
  select other.id,choice.venue,choice.starts_at into candidate
  from matching.blind_requests other cross join lateral (
    select * from matching.blind_options(me,other) order by random() limit 1
  ) choice where other.status='waiting' and other.owner_id<>me.owner_id
    and other.available_to >= me.available_from+interval '1 hour'
    and me.available_to >= other.available_from+interval '1 hour'
    and not matching.blocked(me.owner_id,other.owner_id)
    and not exists (select 1 from matching.connections c where c.lo=least(me.owner_id,other.owner_id) and c.hi=greatest(me.owner_id,other.owner_id))
  order by other.created_at,other.id limit 1;
  if not found then return; end if;
  insert into matching.blind_meetings(venue,starts_at,confirm_by)
    values(candidate.venue,candidate.starts_at,least(candidate.starts_at-interval '5 minutes',clock_timestamp()+interval '24 hours')) returning id into event_id;
  update matching.blind_requests set meeting=event_id,status='proposed' where id in(me.id,candidate.id);
end $$;

create function matching.blind_view(p_actor uuid,p_request uuid) returns jsonb language plpgsql set search_path='' as $$
declare r matching.blind_requests; result jsonb; v matching.blind_venues; m matching.blind_meetings;
begin
  select * into r from matching.blind_requests where id=p_request and owner_id=p_actor;
  if not found then return jsonb_build_object('status','idle'); end if;
  result:=jsonb_build_object('id',r.id,'status',r.status,'mine_confirmed',r.agreed,
             'mine_completed',r.status in ('completed','connected'),'mine_continue',r.opted_in,
             'had_peer',r.meeting is not null);
  if r.status in ('proposed','confirmed','completed','connected') then
    select * into m from matching.blind_meetings where id=r.meeting;
    select * into v from matching.blind_venues where id=m.venue;
    result:=result||jsonb_build_object('venue_demo',v.demo);
    -- Once the encounter finishes the address is no longer needed.
    if r.status='confirmed' and clock_timestamp()<m.starts_at+interval '1 hour' then
      result:=result||jsonb_build_object('starts_at',m.starts_at,'venue_name',v.name,'venue_address',v.address);
    elsif r.status='confirmed' then
      result:=result||jsonb_build_object('can_complete',true);
    end if;
  end if;
  return result;
end $$;

create function public.blind_state() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor(); req uuid;
begin
  perform matching.blind_sweep();
  select id into req from matching.blind_requests where owner_id=u order by created_at desc,id desc limit 1;
  perform matching.blind_try(req);
  return matching.blind_view(u,req);
end $$;

create function public.blind_join(p_area text,p_start timestamptz,p_end timestamptz,p_distance integer,p_preference text,p_nonce uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor(); r matching.blind_requests;
begin
  perform matching.blind_sweep();
  select * into r from matching.blind_requests where owner_id=u and nonce=p_nonce;
  if found then
    if (r.area,r.available_from,r.available_to,r.distance_km,r.preference) is distinct from
       (p_area,p_start,p_end,p_distance,p_preference) then raise exception using errcode='22023',message='Request key already used'; end if;
    return matching.blind_view(u,r.id);
  end if;
  if p_nonce is null or not exists(select 1 from matching.blind_areas where name=p_area)
     or p_distance is null or p_distance not between 1 and 50 or p_preference is null or p_preference not in ('any','quiet','lively')
     or p_start is null or p_end is null or not isfinite(p_start) or not isfinite(p_end)
     or p_start<clock_timestamp()+interval '20 minutes' or p_end>clock_timestamp()+interval '30 days'
     or p_end-p_start not between interval '1 hour' and interval '8 hours' then raise exception using errcode='22023',message='Invalid encounter availability'; end if;
  if exists(select 1 from matching.blind_requests where owner_id=u and status in ('waiting','proposed','confirmed','completed')) then
    raise exception 'Cancel your active request first'; end if;
  if not matching.consume_nonce(u,'blind_join',p_nonce) then
    raise exception using errcode='22023',message='This request has already ended';
  end if;
  perform matching.throttle(u,'blind_join',6,86400);
  insert into matching.blind_requests(owner_id,nonce,area,available_from,available_to,distance_km,preference)
    values(u,p_nonce,p_area,p_start,p_end,p_distance,p_preference) returning * into r;
  perform matching.blind_try(r.id);
  return matching.blind_view(u,r.id);
end $$;

create function public.blind_act(p_id uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor(); r matching.blind_requests; m matching.blind_meetings; peer uuid;
begin
  perform matching.blind_sweep();
  select * into r from matching.blind_requests where id=p_id and owner_id=u;
  if not found then raise exception using errcode='42501',message='Encounter unavailable'; end if;
  if p_action is null or p_action not in ('confirm','complete','continue','cancel') then raise exception using errcode='22023',message='Invalid action'; end if;
  if r.status in ('cancelled','expired','connected') then return matching.blind_view(u,r.id); end if;
  if p_action='cancel' then
    update matching.blind_requests set status='cancelled',ended_at=clock_timestamp() where id=r.id or meeting=r.meeting;
  elsif p_action='confirm' then
    if r.status='waiting' then raise exception 'No proposal yet'; end if;
    if r.status='proposed' then
      update matching.blind_requests set agreed=true where id=r.id;
      if (select count(*) from matching.blind_requests where meeting=r.meeting and agreed)=2 then
        update matching.blind_requests set status='confirmed' where meeting=r.meeting;
      end if;
    end if;
  elsif p_action='complete' then
    select * into m from matching.blind_meetings where id=r.meeting;
    if r.status not in ('confirmed','completed') or clock_timestamp()<m.starts_at+interval '1 hour' then
      raise exception 'Meeting is not complete'; end if;
    update matching.blind_requests set status='completed' where id=r.id;
  elsif p_action='continue' then
    if r.status<>'completed' then raise exception 'Complete the meeting first'; end if;
    update matching.blind_requests set opted_in=true where id=r.id;
    if (select count(*) from matching.blind_requests where meeting=r.meeting and status='completed' and opted_in)=2 then
      peer:=matching.blind_peer(u,r.id);
      perform matching.connect(u,peer,'blind');
      update matching.blind_requests set status='connected',ended_at=clock_timestamp() where meeting=r.meeting;
    end if;
  end if;
  return matching.blind_view(u,r.id);
end $$;

alter table matching.blind_areas enable row level security;
alter table matching.blind_venues enable row level security;
alter table matching.blind_venue_policy enable row level security;
alter table matching.blind_reach enable row level security;
alter table matching.blind_meetings enable row level security;
alter table matching.blind_requests enable row level security;
revoke all on matching.blind_areas, matching.blind_venues, matching.blind_reach, matching.blind_venue_policy,
 matching.blind_eligible_venues, matching.blind_meetings, matching.blind_requests from public,anon,authenticated;
revoke all on function matching.blind_lock_catalog(), matching.blind_venue_changed(), matching.blind_peer(uuid,uuid),
 matching.blind_invalidate(uuid,uuid), matching.blind_sweep(),
 matching.blind_options(matching.blind_requests,matching.blind_requests), matching.blind_try(uuid),
 matching.blind_view(uuid,uuid) from public,anon,authenticated;
revoke all on function public.blind_join(text,timestamptz,timestamptz,integer,text,uuid),
  public.blind_state(), public.blind_act(uuid,text) from public,anon;
grant execute on function public.blind_join(text,timestamptz,timestamptz,integer,text,uuid),
  public.blind_state(), public.blind_act(uuid,text) to authenticated;
commit;
