-- Phase 1. Authenticated clients only execute the three public RPCs. Never
-- enable parameter or request-body logging for these bearer-token endpoints.
begin;

create table matching.secret_requests (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references matching.members(user_id) on delete cascade,
  nonce uuid not null,
  token text check (octet_length(token) = 64 and token ~ '^[0-9a-f]{64}$'),
  state text not null check (state in ('waiting','connected','withdrawn','expired')),
  connection_id uuid references matching.connections(id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp() + interval '24 hours',
  unique(owner, nonce),
  check ((state = 'waiting') = (token is not null)),
  check (connection_id is null or state = 'connected')
);

comment on column matching.secret_requests.token is
  'Server-domain SHA-256 equality index. Null outside waiting; never the client bearer.';
alter table matching.secret_requests enable row level security;
revoke all on matching.secret_requests from public, anon, authenticated;
create unique index secret_one_waiter on matching.secret_requests(owner) where state = 'waiting';
create index secret_token_waiters on matching.secret_requests(token, created_at) where state = 'waiting';
create index secret_waiting_expiry on matching.secret_requests(expires_at) where state = 'waiting';
create index secret_owner_history on matching.secret_requests(owner, created_at desc);
create index secret_connection on matching.secret_requests(connection_id) where connection_id is not null;

create function matching.secret_sweep() returns void language sql
set search_path = '' as $$
  update matching.secret_requests set state = 'expired', token = null
   where state = 'waiting' and expires_at <= clock_timestamp();
  -- Account-level nonce receipts continue to reject old HTTP requests.
  delete from matching.secret_requests
   where expires_at < clock_timestamp() - interval '30 days'
     and state <> 'waiting' and connection_id is null;
$$;

create function matching.secret_peer(p_actor uuid, p_request uuid) returns uuid language sql stable
set search_path = '' as $$
  select case when c.lo = p_actor then c.hi else c.lo end
    from matching.secret_requests r join matching.connections c on c.id = r.connection_id
   where r.id = p_request and r.owner = p_actor and p_actor in (c.lo, c.hi);
$$;

-- Called before the shared connection is removed, in the same transaction.
create function matching.secret_invalidate(a uuid, b uuid) returns void language sql
set search_path = '' as $$
  update matching.secret_requests r set state = 'withdrawn', connection_id = null
    from matching.connections c
   where c.id = r.connection_id and c.lo = least(a,b) and c.hi = greatest(a,b);
$$;

create function matching.secret_view(r matching.secret_requests) returns jsonb language sql stable
set search_path = '' as $$
  select case
    when r.id is null then jsonb_build_object('status','idle')
    when r.state = 'waiting' and r.expires_at > statement_timestamp() then
      jsonb_build_object('status','waiting','id',r.id,'expires_at',r.expires_at)
    when r.state = 'connected' and r.connection_id is not null then
      jsonb_build_object('status','connected','id',r.id,'connection_id',r.connection_id)
    else jsonb_build_object('id',r.id,'status',case
      when r.state = 'waiting' then 'expired'
      when r.state = 'connected' then 'withdrawn'
      else r.state end)
  end;
$$;

create function public.secret_state() returns jsonb language plpgsql security definer
set search_path = '' as $$
declare
  me uuid := matching.actor();
  r matching.secret_requests;
begin
  update matching.secret_requests set state = 'expired', token = null
   where owner = me and state = 'waiting' and expires_at <= clock_timestamp();
  select * into r from matching.secret_requests where owner = me
   order by created_at desc, id desc limit 1;
  return matching.secret_view(r);
end;
$$;

create function public.secret_join(p_token text, p_nonce uuid) returns jsonb language plpgsql security definer
set search_path = '' as $$
declare
  me uuid := matching.actor();
  r matching.secret_requests;
  candidate matching.secret_requests;
  lookup_hash text;
  link uuid;
begin
  if p_nonce is null or p_token is null or octet_length(p_token) <> 64
     or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_secret_request' using errcode='22023';
  end if;

  -- Store a separate hash of the wire token. A database read cannot supply
  -- this index value to the RPC and impersonate a holder of the code.
  lookup_hash := encode(sha256(convert_to('chenbot/secret-match/index/v1','UTF8') ||
                              decode('00' || p_token,'hex')),'hex');

  -- actor() serializes all matching state transitions. Expire before deciding
  -- whether a retry or an unexpired request already exists for this owner.
  update matching.secret_requests set state = 'expired', token = null
   where owner = me and state = 'waiting' and expires_at <= clock_timestamp();
  select * into r from matching.secret_requests where owner = me and nonce = p_nonce;
  if found then
    if r.state = 'waiting' and r.token <> lookup_hash then
      raise exception 'nonce_reused' using errcode='22023';
    end if;
    return matching.secret_view(r);
  end if;

  if not matching.consume_nonce(me,'secret_join',p_nonce) then
    raise exception 'stale_nonce' using errcode='22023';
  end if;
  perform matching.throttle(me,'secret_join',8,86400);
  if exists (select 1 from matching.secret_requests where owner = me and state = 'waiting') then
    raise exception 'withdraw_active_secret_first' using errcode='22023';
  end if;
  insert into matching.secret_requests(owner,nonce,token,state)
    values(me,p_nonce,lookup_hash,'waiting') returning * into r;

  select q.* into candidate from matching.secret_requests q
   where q.owner <> me and q.state = 'waiting' and q.token = lookup_hash
     and q.expires_at > clock_timestamp()
     and not matching.blocked(me,q.owner)
     and not exists (select 1 from matching.connections c
                      where c.lo = least(me,q.owner) and c.hi = greatest(me,q.owner))
   order by q.created_at, q.id limit 1 for update;
  if found then
    link := matching.connect(me,candidate.owner,'secret');
    update matching.secret_requests set state = 'connected', token = null, connection_id = link
     where id in (r.id,candidate.id);
    select * into strict r from matching.secret_requests where id = r.id;
  end if;
  return matching.secret_view(r);
end;
$$;

create function public.secret_act(p_id uuid, p_action text) returns jsonb language plpgsql security definer
set search_path = '' as $$
declare
  me uuid := matching.actor();
  r matching.secret_requests;
begin
  if p_action is distinct from 'withdraw' then
    raise exception 'invalid_secret_action' using errcode='22023';
  end if;
  select * into r from matching.secret_requests where id = p_id and owner = me;
  if not found then raise exception 'request_unavailable' using errcode='42501'; end if;
  if r.state = 'connected' and r.connection_id is not null then
    update matching.secret_requests set state = 'withdrawn', connection_id = null
     where connection_id = r.connection_id;
    delete from matching.connections where id = r.connection_id;
  elsif r.state = 'waiting' then
    update matching.secret_requests
       set token = null, state = case when expires_at <= clock_timestamp() then 'expired' else 'withdrawn' end
     where id = r.id;
  end if;
  select * into strict r from matching.secret_requests where id = p_id;
  return matching.secret_view(r);
end;
$$;

revoke all on function matching.secret_sweep(), matching.secret_peer(uuid,uuid),
  matching.secret_invalidate(uuid,uuid), matching.secret_view(matching.secret_requests)
  from public, anon, authenticated;
revoke all on function public.secret_state(), public.secret_join(text,uuid), public.secret_act(uuid,text)
  from public, anon, authenticated;
grant execute on function public.secret_state(), public.secret_join(text,uuid), public.secret_act(uuid,text)
  to authenticated;

commit;
