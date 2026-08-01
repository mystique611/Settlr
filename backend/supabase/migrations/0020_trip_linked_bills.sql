-- Settlr — "Add a Bill" inside a Trip.
--
-- A trip-linked bill is still a completely normal row in bills/
-- bill_members/bill_items — every existing Bill Split RPC (add/update/
-- delete item, update settings, scan-receipt review, discount, notes,
-- shared-item grouping from 0019) works on it completely unchanged.
-- Two things make it "trip-linked" rather than standalone:
--
-- 1. bills.trip_id points back at the trip, and its bill_members are
--    created by mirroring the trip's own trip_members (each getting a
--    trip_member_id back-reference) — so the payer/payable pickers on
--    the itemized bill screen show the trip's actual mates instead of
--    a separate guest list, and currency is whatever the caller passes
--    (the frontend restricts the dropdown to the trip's own
--    currencies; nothing server-side enforces that, matching how the
--    rest of this app trusts the client for currency choice).
--
-- 2. Once the bill has at least one item (so its total is > 0), the
--    frontend mirrors that total into a genuinely normal expense in
--    the trip's own expenses/expense_splits — created via the
--    existing add_expense_by_token/update_expense_by_token with
--    split_type = 'exact', splits computed from the bill's own
--    per-person totals. This is deliberate reuse rather than
--    reinventing balance math a second time: Settle Up, the balance
--    summary, CSV export — none of that code needs to know a "bill
--    expense" is special, because by the time it runs, the bill's
--    numbers are just sitting in expense_splits like any other
--    expense's. linked_expense_id / linked_bill_id are the two-way
--    pointer that lets the trip's expense list show the bill as one
--    row and open the itemized view when it's tapped, instead of the
--    normal Edit Expense form.

set search_path = public, extensions;

alter table public.bills
  add column trip_id           uuid references public.trips(id) on delete cascade,
  add column linked_expense_id uuid references public.expenses(id) on delete set null;

alter table public.expenses
  add column linked_bill_id uuid references public.bills(id) on delete set null;

alter table public.bill_members
  add column trip_member_id uuid references public.trip_members(id) on delete set null;

comment on column public.bills.trip_id is 'Set only for a bill created via Trip''s "Add a Bill" — null for a standalone Split a Bill.';
comment on column public.bills.linked_expense_id is 'The mirrored expense row (in the same trip) that carries this bill''s total into Settle Up/balances. Set once the bill has its first item.';
comment on column public.expenses.linked_bill_id is 'Set only when this expense is the mirror of a trip-linked bill — the trip expense list shows it as one row and opens the itemized bill view instead of the normal edit form.';
comment on column public.bill_members.trip_member_id is 'Set only when this bill member was auto-created from a trip mate (trip-linked bills) — null for a standalone bill''s own guest-entered members.';

create index idx_bills_trip_id on public.bills(trip_id) where trip_id is not null;

-- ─────────────────────────────────────────────────────────
-- create_trip_bill_by_token — mirrors create_guest_bill, but the
-- members come from the trip's own trip_members instead of a list of
-- names the caller types in, and the new bill is trip_id-linked from
-- the start.
-- ─────────────────────────────────────────────────────────
create or replace function public.create_trip_bill_by_token(
  p_trip_token text,
  p_name text,
  p_currency text,
  p_payer_trip_member_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  b public.bills%rowtype;
  tm record;
  v_new_bill_member_id uuid;
  v_payer_bill_member_id uuid;
  v_first_bill_member_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_trip_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  insert into public.bills (name, currency, trip_id) values (p_name, p_currency, v_trip_id) returning * into b;

  for tm in select id, display_name from public.trip_members where trip_id = v_trip_id order by created_at loop
    insert into public.bill_members (bill_id, display_name, trip_member_id)
    values (b.id, tm.display_name, tm.id)
    returning id into v_new_bill_member_id;

    if v_first_bill_member_id is null then
      v_first_bill_member_id := v_new_bill_member_id;
    end if;
    if p_payer_trip_member_id is not null and tm.id = p_payer_trip_member_id then
      v_payer_bill_member_id := v_new_bill_member_id;
    end if;
  end loop;

  update public.bills
    set payer_member_id = coalesce(v_payer_bill_member_id, v_first_bill_member_id)
    where id = b.id;

  return jsonb_build_object('bill_id', b.id, 'share_token', b.share_token);
end;
$$;

-- ─────────────────────────────────────────────────────────
-- link_trip_bill_expense — called once, right after the mirrored
-- expense is first created (add_expense_by_token already handles
-- every update after that, since it's just editing an existing
-- expense at that point). Ownership is checked both ways: the bill
-- must already belong to the trip resolved from p_trip_token, and the
-- expense must too — a caller can't use this to splice an unrelated
-- bill/expense together.
-- ─────────────────────────────────────────────────────────
create or replace function public.link_trip_bill_expense(
  p_trip_token text,
  p_bill_id uuid,
  p_expense_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  perform public._check_rate_limit('trip_write', 30, interval '5 minutes');

  select id into v_trip_id from public.trips where share_token = p_trip_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  update public.bills set linked_expense_id = p_expense_id, updated_at = now()
    where id = p_bill_id and trip_id = v_trip_id;
  if not found then
    raise exception 'Bill does not belong to this trip' using errcode = '28000';
  end if;

  update public.expenses set linked_bill_id = p_bill_id
    where id = p_expense_id and trip_id = v_trip_id;
end;
$$;

revoke all on function public.create_trip_bill_by_token(text, text, text, uuid) from public;
revoke all on function public.link_trip_bill_expense(text, uuid, uuid) from public;

grant execute on function public.create_trip_bill_by_token(text, text, text, uuid) to anon, authenticated;
grant execute on function public.link_trip_bill_expense(text, uuid, uuid) to anon, authenticated;

-- ─────────────────────────────────────────────────────────
-- get_trip_by_token: expose this trip's bills (with their share
-- tokens, unlike get_bill_by_token which strips its own) so the
-- frontend can open a bill-backed expense's itemized view without an
-- extra round trip. Safe to include the token here: anyone holding
-- the trip's own token already has full read/write on everything in
-- the trip, same trust model as every other guest RPC in this app.
-- ─────────────────────────────────────────────────────────
create or replace function public.get_trip_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips%rowtype;
  v_result jsonb;
begin
  perform public._check_rate_limit('trip_read', 60, interval '5 minutes');

  select * into t from public.trips where share_token = p_token;

  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  select jsonb_build_object(
    'trip', to_jsonb(t) - 'share_token',
    'members', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.trip_members m where m.trip_id = t.id
    ), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at desc)
      from public.expenses e where e.trip_id = t.id
    ), '[]'::jsonb),
    'expense_splits', coalesce((
      select jsonb_agg(to_jsonb(s))
      from public.expense_splits s
      join public.expenses e on e.id = s.expense_id
      where e.trip_id = t.id
    ), '[]'::jsonb),
    'settlements', coalesce((
      select jsonb_agg(to_jsonb(st) order by st.settled_at desc)
      from public.settlements st where st.trip_id = t.id
    ), '[]'::jsonb),
    'bills', coalesce((
      select jsonb_agg(to_jsonb(bl))
      from public.bills bl where bl.trip_id = t.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ─────────────────────────────────────────────────────────
-- delete_bill_by_token: deleting a trip-linked bill also removes its
-- mirrored expense — otherwise the trip would be left with an expense
-- that claims to be bill-backed but points at nothing.
-- ─────────────────────────────────────────────────────────
create or replace function public.delete_bill_by_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
  v_linked_expense_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  select id, linked_expense_id into v_bill_id, v_linked_expense_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  delete from public.bills where id = v_bill_id;

  if v_linked_expense_id is not null then
    delete from public.expenses where id = v_linked_expense_id;
  end if;
end;
$$;
