-- Settlr — Bill Split schema, RLS, and guest-token API
--
-- Bill Split is a lighter-weight sibling of a full trip: one
-- receipt, a payer, and a set of items each owed by exactly one
-- person (no multi-person expense splitting like trips have).
-- Unlike trips, a bill isn't a shared multi-account object — only
-- its creator ever views/edits it — so RLS here is owner-only
-- rather than the trip's owner-or-member check.

-- pgcrypto's functions live in the `extensions` schema on hosted
-- Supabase projects, not `public` — needed here for share_token's
-- gen_random_bytes() default. Each migration file runs in its own
-- session, so this has to be set again even though 0001 sets it too.
set search_path = public, extensions;

-- ─────────────────────────────────────────────────────────
-- Bills
-- ─────────────────────────────────────────────────────────
create table public.bills (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  currency          text not null default 'USD',
  payer_member_id   uuid, -- fk added below, once bill_members exists
  owner_user_id     uuid references auth.users(id) on delete set null,
  share_token       text unique not null default encode(gen_random_bytes(9), 'base64'),
  tax_included      boolean not null default false,
  service_pct       numeric(5,2) not null default 0,
  gst_on_service    boolean not null default true,
  gst_pct           numeric(5,2) not null default 0,
  tip_mode          text not null default 'percent' check (tip_mode in ('percent', 'exact')),
  tip_percent       numeric(5,2) not null default 0,
  tip_exact         numeric(12,2) not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on column public.bills.share_token is 'Grants full guest read+write access to this bill split.';
comment on column public.bills.gst_on_service is 'Whether service tax is included in the GST base — a per-bill choice, since some jurisdictions tax it and some don''t.';
comment on column public.bills.tip_mode is 'Whether tip_percent or tip_exact is the active tip value.';

-- ─────────────────────────────────────────────────────────
-- Bill members — who's splitting this receipt
-- ─────────────────────────────────────────────────────────
create table public.bill_members (
  id            uuid primary key default gen_random_uuid(),
  bill_id       uuid not null references public.bills(id) on delete cascade,
  display_name  text not null,
  created_at    timestamptz not null default now()
);

alter table public.bills
  add constraint bills_payer_member_fk
  foreign key (payer_member_id) references public.bill_members(id) on delete set null;

-- ─────────────────────────────────────────────────────────
-- Bill items — each item is owed by exactly one person
-- (unlike expenses, bill items aren't split across the group)
-- ─────────────────────────────────────────────────────────
create table public.bill_items (
  id            uuid primary key default gen_random_uuid(),
  bill_id       uuid not null references public.bills(id) on delete cascade,
  description   text not null,
  amount        numeric(12,2) not null check (amount > 0),
  owed_by       uuid not null references public.bill_members(id) on delete restrict,
  created_at    timestamptz not null default now()
);

create index idx_bill_members_bill_id on public.bill_members(bill_id);
create index idx_bill_items_bill_id on public.bill_items(bill_id);

-- ─────────────────────────────────────────────────────────
-- RLS — authenticated (owner-only; see note above on why this
-- doesn't need the trip's owner-or-member pattern)
-- ─────────────────────────────────────────────────────────
alter table public.bills        enable row level security;
alter table public.bill_members enable row level security;
alter table public.bill_items   enable row level security;

revoke all on public.bills, public.bill_members, public.bill_items from anon;

grant select, insert, update, delete on public.bills        to authenticated;
grant select, insert, update, delete on public.bill_members to authenticated;
grant select, insert, update, delete on public.bill_items   to authenticated;

create or replace function public.is_bill_owner(p_bill_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.bills b where b.id = p_bill_id and b.owner_user_id = auth.uid()
  );
$$;

create policy "bills_select_owner" on public.bills
  for select to authenticated
  using (owner_user_id = auth.uid());

create policy "bills_insert_self_owned" on public.bills
  for insert to authenticated
  with check (owner_user_id = auth.uid());

create policy "bills_update_owner" on public.bills
  for update to authenticated
  using (owner_user_id = auth.uid())
  with check (owner_user_id = auth.uid());

create policy "bills_delete_owner" on public.bills
  for delete to authenticated
  using (owner_user_id = auth.uid());

create policy "bill_members_all" on public.bill_members
  for all to authenticated
  using (public.is_bill_owner(bill_id))
  with check (public.is_bill_owner(bill_id));

create policy "bill_items_all" on public.bill_items
  for all to authenticated
  using (public.is_bill_owner(bill_id))
  with check (public.is_bill_owner(bill_id));

-- ─────────────────────────────────────────────────────────
-- Guest-token API — same pattern as trips in 0003/0004:
-- SECURITY DEFINER functions, token is the authorization check,
-- guests never touch the tables directly.
-- ─────────────────────────────────────────────────────────

create or replace function public.get_bill_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bills%rowtype;
  v_result jsonb;
begin
  select * into b from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  select jsonb_build_object(
    'bill', to_jsonb(b) - 'share_token',
    'members', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.bill_members m where m.bill_id = b.id
    ), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(to_jsonb(i)) from public.bill_items i where i.bill_id = b.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- p_payer_name must match one of p_member_names (case-sensitive).
create or replace function public.create_guest_bill(
  p_name text,
  p_currency text,
  p_member_names text[],
  p_payer_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.bills%rowtype;
  m_name text;
  v_new_member_id uuid;
  v_payer_id uuid;
begin
  insert into public.bills (name, currency) values (p_name, p_currency) returning * into b;

  foreach m_name in array p_member_names loop
    insert into public.bill_members (bill_id, display_name)
    values (b.id, m_name)
    returning id into v_new_member_id;
    if m_name = p_payer_name then
      v_payer_id := v_new_member_id;
    end if;
  end loop;

  update public.bills set payer_member_id = v_payer_id where id = b.id;

  return jsonb_build_object('bill_id', b.id, 'share_token', b.share_token);
end;
$$;

create or replace function public.add_bill_item_by_token(
  p_token text,
  p_description text,
  p_amount numeric,
  p_owed_by uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
  v_id uuid;
begin
  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  insert into public.bill_items (bill_id, description, amount, owed_by)
  values (v_bill_id, p_description, p_amount, p_owed_by)
  returning id into v_id;

  update public.bills set updated_at = now() where id = v_bill_id;
  return v_id;
end;
$$;

create or replace function public.delete_bill_item_by_token(p_token text, p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
begin
  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  delete from public.bill_items where id = p_item_id and bill_id = v_bill_id;
  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

-- Covers payer + all tax/service/GST/tip fields in one call, since
-- the Bill Split screen edits them together as the bill's settings.
create or replace function public.update_bill_settings_by_token(
  p_token text,
  p_payer_member_id uuid,
  p_tax_included boolean,
  p_service_pct numeric,
  p_gst_on_service boolean,
  p_gst_pct numeric,
  p_tip_mode text,
  p_tip_percent numeric,
  p_tip_exact numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
begin
  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  update public.bills set
    payer_member_id = coalesce(p_payer_member_id, payer_member_id),
    tax_included = p_tax_included,
    service_pct = p_service_pct,
    gst_on_service = p_gst_on_service,
    gst_pct = p_gst_pct,
    tip_mode = p_tip_mode,
    tip_percent = p_tip_percent,
    tip_exact = p_tip_exact,
    updated_at = now()
  where id = v_bill_id;
end;
$$;

create or replace function public.claim_bill(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  b public.bills%rowtype;
begin
  if v_uid is null then
    raise exception 'You must be signed in to claim a bill split' using errcode = '28000';
  end if;

  select * into b from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid bill link' using errcode = '28000';
  end if;

  if b.owner_user_id is not null and b.owner_user_id <> v_uid then
    raise exception 'This bill split has already been claimed by another account' using errcode = '28000';
  end if;

  update public.bills set owner_user_id = v_uid, updated_at = now() where id = b.id;

  return jsonb_build_object('bill_id', b.id, 'name', b.name);
end;
$$;

-- ── lock functions down, then open exactly what's needed ─
revoke all on function public.get_bill_by_token(text) from public;
revoke all on function public.create_guest_bill(text, text, text[], text) from public;
revoke all on function public.add_bill_item_by_token(text, text, numeric, uuid) from public;
revoke all on function public.delete_bill_item_by_token(text, uuid) from public;
revoke all on function public.update_bill_settings_by_token(text, uuid, boolean, numeric, boolean, numeric, text, numeric, numeric) from public;
revoke all on function public.claim_bill(text) from public;

grant execute on function public.get_bill_by_token(text) to anon, authenticated;
grant execute on function public.create_guest_bill(text, text, text[], text) to anon, authenticated;
grant execute on function public.add_bill_item_by_token(text, text, numeric, uuid) to anon, authenticated;
grant execute on function public.delete_bill_item_by_token(text, uuid) to anon, authenticated;
grant execute on function public.update_bill_settings_by_token(text, uuid, boolean, numeric, boolean, numeric, text, numeric, numeric) to anon, authenticated;

-- claim_bill requires a session, so only authenticated gets it.
grant execute on function public.claim_bill(text) to authenticated;
