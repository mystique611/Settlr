-- Settlr — core schema
-- Run via: supabase db push  (or paste into the SQL editor)

create extension if not exists pgcrypto;

-- On hosted Supabase projects, pgcrypto's functions (gen_random_bytes,
-- etc.) live in the `extensions` schema, not `public` — without this,
-- the edit_token/view_token defaults below fail with
-- "function gen_random_bytes(integer) does not exist".
set search_path = public, extensions;

-- ─────────────────────────────────────────────────────────
-- Trips
-- Every trip has an edit_token (full access) and a
-- view_token (read-only) used by guests. owner_user_id is
-- null until an authenticated user claims the trip.
-- ─────────────────────────────────────────────────────────
create table public.trips (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  home_currency      text not null default 'USD',
  travel_currencies  text[] not null default '{}',
  owner_user_id      uuid references auth.users(id) on delete set null,
  edit_token         text unique not null default encode(gen_random_bytes(9), 'base64'),
  view_token         text unique not null default encode(gen_random_bytes(9), 'base64'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on column public.trips.edit_token is 'Grants read+write guest access. Never expose in a SELECT * to other guests.';
comment on column public.trips.view_token is 'Grants read-only guest access.';

-- ─────────────────────────────────────────────────────────
-- Trip mates
-- display_name always present; linked_user_id is set once
-- someone with an account is matched/invited to the trip.
-- ─────────────────────────────────────────────────────────
create table public.trip_members (
  id               uuid primary key default gen_random_uuid(),
  trip_id          uuid not null references public.trips(id) on delete cascade,
  display_name     text not null,
  linked_user_id   uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────
-- Expenses
-- ─────────────────────────────────────────────────────────
create table public.expenses (
  id              uuid primary key default gen_random_uuid(),
  trip_id         uuid not null references public.trips(id) on delete cascade,
  description     text not null,
  category        text not null default 'general',
  amount          numeric(12,2) not null check (amount > 0),
  currency        text not null,
  exchange_rate   numeric(14,6) not null default 1, -- currency -> trip.home_currency, user-overridable
  paid_by         uuid not null references public.trip_members(id) on delete restrict,
  split_type      text not null check (split_type in ('equal', 'percentage', 'exact')),
  receipt_path    text, -- Supabase Storage object path; authenticated accounts only
  created_at      timestamptz not null default now()
);

create table public.expense_splits (
  id               uuid primary key default gen_random_uuid(),
  expense_id       uuid not null references public.expenses(id) on delete cascade,
  trip_member_id   uuid not null references public.trip_members(id) on delete cascade,
  share_value      numeric(12,4) not null, -- % points (percentage) or raw amount (exact); ignored for equal
  owed_amount      numeric(12,2) not null, -- resolved amount in expense currency, computed by the RPC/app layer
  unique (expense_id, trip_member_id)
);

-- ─────────────────────────────────────────────────────────
-- Settlements (supports partial pay-down of a debt)
-- ─────────────────────────────────────────────────────────
create table public.settlements (
  id              uuid primary key default gen_random_uuid(),
  trip_id         uuid not null references public.trips(id) on delete cascade,
  from_member_id  uuid not null references public.trip_members(id) on delete cascade,
  to_member_id    uuid not null references public.trip_members(id) on delete cascade,
  amount          numeric(12,2) not null check (amount > 0),
  currency        text not null,
  note            text,
  settled_at      timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────
-- Favorites (authenticated users only — saved trip mates
-- they can quickly re-add to a new trip)
-- ─────────────────────────────────────────────────────────
create table public.favorites (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  display_name  text not null,
  email         text,
  created_at    timestamptz not null default now()
);

create index idx_trip_members_trip_id on public.trip_members(trip_id);
create index idx_expenses_trip_id on public.expenses(trip_id);
create index idx_expense_splits_expense_id on public.expense_splits(expense_id);
create index idx_settlements_trip_id on public.settlements(trip_id);
create index idx_favorites_user_id on public.favorites(user_id);
