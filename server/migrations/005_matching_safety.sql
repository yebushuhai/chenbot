begin;
-- Retain an opaque context handle briefly so reporting AFTER blocking and
-- retrying a successful safety action work even after the connection is gone.
create table matching.safety_contexts (
  owner uuid not null references auth.users on delete cascade,
  kind text not null, ref uuid not null, source text not null check(source in ('blind','secret')), peer uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(), primary key(owner,kind,ref)
);
alter table matching.safety_contexts enable row level security;
revoke all on matching.safety_contexts from public, anon, authenticated, service_role;

-- Record minimal pair-scoped capabilities only when a connection/meeting ends.
-- Both foreign keys must still exist during an auth.users cascade.
create function matching.remember(a uuid,k text,r uuid,s text,b uuid) returns void
language sql set search_path='' as $$
  insert into matching.safety_contexts(owner,kind,ref,source,peer)
    select a,k,r,s,b where exists(select 1 from auth.users where id=a)
                       and exists(select 1 from auth.users where id=b)
    on conflict do nothing;
$$;
create function matching.on_disconnect() returns trigger language plpgsql set search_path='' as $$
begin
  perform matching.remember(old.lo,'connection',old.id,old.source,old.hi);
  perform matching.remember(old.hi,'connection',old.id,old.source,old.lo);
  return old;
end $$;
create trigger remember_connection before delete on matching.connections
  for each row execute function matching.on_disconnect();

create function matching.on_blind_end() returns trigger language plpgsql set search_path='' as $$
declare peer_id uuid;
begin
  if old.meeting is not null then
    select p.owner_id into peer_id from matching.blind_requests p
      where p.meeting=old.meeting and p.owner_id<>old.owner_id;
    if peer_id is not null then
      perform matching.remember(old.owner_id,'blind',old.id,'blind',peer_id);
    end if;
  end if;
  return new;
end $$;
create trigger remember_encounter before update of status on matching.blind_requests
  for each row when (old.status<>new.status and new.status in ('expired','cancelled','connected'))
  execute function matching.on_blind_end();
create function public.matching_safety_history() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id',ref,'kind',kind,'source',source,
    'created_at',created_at) order by created_at desc, ref),'[]') from (
    select ref,kind,source,created_at from matching.safety_contexts where owner=u
      and kind in ('blind','connection') and created_at>now()-interval '31 days'
      order by created_at desc,ref limit 30) as recent);
end $$;

create function public.matching_safety(p_kind text,p_id uuid,p_action text,p_reason text) returns boolean
language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.actor(); other_id uuid;
begin
  if p_action is null or p_action not in ('block','report') or
     (p_action='report' and (p_reason is null or p_reason not in ('unsafe','harassment','impersonation','other'))) then
    raise exception 'invalid_action' using errcode='22023';
  end if;
  case p_kind
    when 'connection' then other_id:=matching.peer(u,p_id);
    when 'blind' then other_id:=matching.blind_peer(u,p_id);
    when 'secret' then other_id:=matching.secret_peer(u,p_id);
    else raise exception 'invalid_context' using errcode='22023';
  end case;
  if other_id is null then
    select peer into other_id from matching.safety_contexts
      where owner=u and kind=p_kind and ref=p_id and created_at>now()-interval '31 days';
  end if;
  if other_id is null then raise exception 'unavailable' using errcode='42501'; end if;
  perform matching.remember(u,p_kind,p_id,coalesce(
    (select source from matching.connections where id=p_id and p_kind='connection'),
    (select source from matching.safety_contexts where owner=u and kind=p_kind and ref=p_id),
    p_kind),other_id);
  if p_action='report' then
    insert into matching.reports(reporter,subject,context_kind,context_id,reason)
      values(u,other_id,p_kind,p_id,p_reason) on conflict do nothing;
    if found then perform matching.throttle(u,'report',10,86400); end if;
  end if;
  insert into matching.blocks(by_user,against) values(u,other_id) on conflict do nothing;
  perform matching.secret_invalidate(u,other_id);
  perform matching.blind_invalidate(u,other_id);
  delete from matching.connections where lo=least(u,other_id) and hi=greatest(u,other_id);
  return true;
end $$;

create function public.matching_delete() returns boolean language plpgsql security definer set search_path='' as $$
declare u uuid:=matching.verified();
begin
  -- Retire peer proposals before removing enrollment, including proposals
  -- whose venue had already been disclosed. The other user keeps only a receipt.
  update matching.blind_requests p set meeting=null,status='cancelled',ended_at=now()
    where p.owner_id<>u and exists(select 1 from matching.blind_requests mine
                    where mine.owner_id=u and mine.meeting=p.meeting);
  -- Capture surviving participants' report handles before member FK cascades.
  delete from matching.connections where u in(lo,hi);
  delete from matching.members where user_id=u;
  delete from matching.safety_contexts where owner=u;
  perform matching.blind_sweep();
  return true;
end $$;

-- Run at least hourly from a restricted scheduler; never expose this as RPC.
create function matching.maintain() returns void language plpgsql set search_path='' as $$
begin
  perform pg_advisory_xact_lock(69383720414::bigint);
  perform matching.blind_sweep();
  perform matching.secret_sweep();
  delete from matching.connections where created_at<=now()-interval '90 days';
  delete from matching.messages where created_at<=now()-interval '30 days';
  delete from matching.safety_contexts where created_at<=now()-interval '31 days';
  delete from matching.reports where created_at<=now()-interval '90 days';
end $$;
revoke all on function matching.remember(uuid,text,uuid,text,uuid),matching.on_disconnect(),matching.on_blind_end(),matching.maintain() from public,anon,authenticated,service_role;
revoke all on function public.matching_safety(text,uuid,text,text),public.matching_delete(),public.matching_safety_history() from public,anon;
grant execute on function public.matching_safety(text,uuid,text,text),public.matching_delete(),public.matching_safety_history() to authenticated;
notify pgrst,'reload schema';
commit;
