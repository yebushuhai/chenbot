-- Disposable test database ONLY. Production must use Supabase Auth.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema auth;
create table auth.users(id uuid primary key,email text unique,email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
   (nullif(current_setting('request.jwt.claims',true),'')::jsonb)->>'sub')::uuid;
$$;
