-- Supabase/PostgREST. Run as the trusted migration owner, in order.
begin;
create schema matching;
revoke all on schema matching from public, anon, authenticated, service_role;
alter default privileges in schema matching revoke execute on functions from public;
create table matching.members (
  user_id uuid primary key references auth.users on delete cascade,
  attested_at timestamptz not null default now()
);
-- Keep blocks tied to verified accounts across discovery deletion/re-enrollment.
create table matching.blocks (
  by_user uuid references auth.users on delete cascade,
  against uuid references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key(by_user,against), check(by_user <> against)
);
create index blocks_against on matching.blocks(against);
create table matching.connections (
  id uuid primary key default gen_random_uuid(),
  lo uuid not null references matching.members on delete cascade,
  hi uuid not null references matching.members on delete cascade,
  source text not null check (source in ('blind','secret')),
  created_at timestamptz not null default now(),
  unique(lo,hi), check(lo < hi)
);
create index connections_hi on matching.connections(hi);
create table matching.messages (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references matching.connections on delete cascade,
  sender uuid not null references matching.members on delete cascade,
  nonce uuid not null, body text not null check(length(body) between 1 and 500),
  created_at timestamptz not null default clock_timestamp(),
  unique(sender,nonce)
);
create index messages_timeline on matching.messages(connection_id,created_at);
create table matching.reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid references auth.users on delete set null,
  subject uuid references auth.users on delete set null,
  context_kind text not null check(context_kind in ('blind','secret','connection')),
  context_id uuid not null,
  reason text not null check(reason in ('unsafe','harassment','impersonation','other')),
  created_at timestamptz not null default now(),
  unique(reporter,context_kind,context_id)
);
create table matching.quotas (
  owner uuid references auth.users on delete cascade,
  bucket text, window_id bigint not null, hits integer not null,
  primary key(owner,bucket)
);
-- No secret, location, or payload here. Nonce receipts survive discovery deletion.
create table matching.receipts (
  owner uuid references auth.users on delete cascade,
  digest bytea not null, primary key(owner,digest)
);
create function matching.consume_nonce(u uuid,bucket text,p_nonce uuid) returns boolean
language plpgsql set search_path='' as $$
begin
  insert into matching.receipts values(u,sha256(convert_to(bucket||':'||p_nonce::text,'UTF8')))
  on conflict do nothing;
  return found;
end $$;
create function matching.throttle(u uuid,b text,cap integer,period_seconds integer) returns void
language plpgsql set search_path='' as $$
declare w bigint := floor(extract(epoch from clock_timestamp())/period_seconds);
begin
  insert into matching.quotas as q values(u,b,w,1)
  on conflict(owner,bucket) do update set window_id=w,
    hits=case when q.window_id=w then q.hits+1 else 1 end
    where q.window_id<>w or q.hits<cap;
  if not found then raise exception 'rate_limit' using errcode='P0001'; end if;
end $$;
create function matching.verified() returns uuid language plpgsql set search_path='' as $$
declare u uuid:=auth.uid();
begin
  if not exists(select 1 from auth.users where id=u and email_confirmed_at is not null
                and nullif(email,'') is not null) then
    raise exception 'verified_email_required' using errcode='42501';
  end if;
  -- One serial order across joins, block, deletion, disclosure and maintenance.
  perform pg_advisory_xact_lock(69383720414::bigint);
  perform matching.throttle(u,'requests',180,60);
  return u;
end $$;
create function matching.actor() returns uuid language plpgsql set search_path='' as $$
declare u uuid:=matching.verified();
begin
  if not exists(select 1 from matching.members where user_id=u) then
    raise exception 'enrollment_required' using errcode='42501';
  end if;
  delete from matching.connections where u in(lo,hi) and created_at<=now()-interval '90 days';
  return u;
end $$;
create function matching.blocked(a uuid,b uuid) returns boolean language sql stable set search_path='' as $$
  select exists(select 1 from matching.blocks where (by_user=a and against=b) or (by_user=b and against=a));
$$;
create function matching.connect(a uuid,b uuid,s text) returns uuid language plpgsql set search_path='' as $$
declare link uuid;
begin
  if a=b or matching.blocked(a,b) then raise exception 'unavailable' using errcode='42501'; end if;
  insert into matching.connections(lo,hi,source) values(least(a,b),greatest(a,b),s)
    on conflict(lo,hi) do nothing returning id into link;
  if link is null then select id into strict link from matching.connections where lo=least(a,b) and hi=greatest(a,b); end if;
  return link;
end $$;
create function public.matching_me() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.verified();
begin
  return jsonb_build_object('enrolled',exists(select 1 from matching.members where user_id=u),
    'name',(select split_part(email,'@',1) from auth.users where id=u));
end $$;
create function public.matching_enroll(p_adult boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.verified();
begin
  if p_adult is distinct from true then raise exception 'adults_only' using errcode='22023'; end if;
  insert into matching.members(user_id) values(u) on conflict do nothing;
  return public.matching_me();
end $$;
create function public.matching_connections() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'source',source) order by created_at desc,id),'[]')
    from matching.connections where u in(lo,hi));
end $$;
create function matching.peer(u uuid,c uuid) returns uuid language sql stable set search_path='' as $$
  select case when lo=u then hi else lo end from matching.connections where id=c and u in(lo,hi);
$$;
create function public.matching_messages(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor();
begin
  if matching.peer(u,p_id) is null then raise exception 'unavailable' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('mine',sender=u,'body',body,'created_at',created_at)
    order by created_at,id),'[]') from
    (select * from matching.messages where connection_id=p_id and created_at>now()-interval '30 days'
     order by created_at desc,id desc limit 100) as recent);
end $$;
create function public.matching_send(p_id uuid,p_body text,p_nonce uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor(); old matching.messages;
begin
  if matching.peer(u,p_id) is null then raise exception 'unavailable' using errcode='42501'; end if;
  if p_nonce is null or p_body is null or char_length(p_body) not between 1 and 500 or p_body !~ '[^[:space:]]' then
    raise exception 'invalid_message' using errcode='22023';
  end if;
  select * into old from matching.messages where sender=u and nonce=p_nonce;
  if found then
    if old.connection_id<>p_id or old.body<>p_body then raise exception 'nonce_reused' using errcode='22023'; end if;
    return true;
  end if;
  if not matching.consume_nonce(u,'message',p_nonce) then raise exception 'request_expired' using errcode='22023'; end if;
  perform matching.throttle(u,'messages',20,600);
  insert into matching.messages(connection_id,sender,nonce,body) values(p_id,u,p_nonce,p_body);
  return true;
end $$;
do $$ declare t text;
begin
  foreach t in array array['members','blocks','connections','messages','reports','quotas','receipts'] loop
    execute format('alter table matching.%I enable row level security',t);
  end loop;
end $$;
revoke all on all tables in schema matching from public,anon,authenticated,service_role;
revoke all on all functions in schema matching from public,anon,authenticated,service_role;
revoke all on function public.matching_me(), public.matching_enroll(boolean),public.matching_connections(),
 public.matching_messages(uuid), public.matching_send(uuid,text,uuid) from public,anon;
grant execute on function public.matching_me(), public.matching_enroll(boolean),public.matching_connections(),
 public.matching_messages(uuid), public.matching_send(uuid,text,uuid) to authenticated;
commit;
