-- Proposed schema, not deployed. Service-role writes must follow a verified purchase
-- or a verified recognition result inside a transaction; never grant client writes.
begin;
create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  paid_credits bigint not null default 0 check (paid_credits >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.credit_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount <> 0),
  reason text not null check (reason in ('purchase', 'recognition', 'recognition_refund', 'store_refund', 'adjustment')),
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique (reason, idempotency_key)
);
create table if not exists public.store_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  store text not null check (store in ('google_play', 'app_store', 'china_android')),
  transaction_reference text not null,
  product_id text not null,
  status text not null check (status in ('pending', 'verified', 'credited', 'refunded', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store, transaction_reference)
);
create table if not exists public.saved_words (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  language text not null check (language in ('en', 'ja')),
  word text not null check (length(word) between 1 and 200),
  reading text not null default '',
  meaning_zh text not null,
  definition_en text not null,
  example text not null,
  example_zh text not null,
  created_at timestamptz not null default now(),
  unique (user_id, language, word, reading)
);
alter table public.wallets enable row level security;
alter table public.credit_transactions enable row level security;
alter table public.store_transactions enable row level security;
alter table public.saved_words enable row level security;
revoke all on public.wallets, public.credit_transactions, public.store_transactions from anon, authenticated;
grant select on public.wallets, public.credit_transactions, public.store_transactions to authenticated;
grant select, insert, update, delete on public.saved_words to authenticated;
create policy wallet_owner_read on public.wallets for select to authenticated using ((select auth.uid()) = user_id);
create policy credit_owner_read on public.credit_transactions for select to authenticated using ((select auth.uid()) = user_id);
create policy transaction_owner_read on public.store_transactions for select to authenticated using ((select auth.uid()) = user_id);
create policy words_owner_all on public.saved_words for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
commit;
