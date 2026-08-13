-- Settlr — completely remove "Add a Bill" (trip-linked bills), per
-- explicit request: it should never have been a hybrid feature, and any
-- bill/expense data it already created should be cleaned up, not just
-- hidden in the frontend.
--
-- Order matters: delete data first (while the linking columns this
-- migration is about to drop are still around to identify what to
-- delete), then drop the RPCs that only existed for this feature, then
-- revert the three RPCs 0020/0021 modified back to their pre-0020
-- shape, then drop the columns themselves.

set search_path = public, extensions;

-- ── 1. Clean up existing data ──
-- Delete the mirrored trip expenses first (their own row, not just the
-- pointer), then the trip-linked bills (cascades to bill_members/
-- bill_items via the existing on-delete-cascade FKs from 0005).
delete from public.expenses
  where id in (select linked_expense_id from public.bills where trip_id is not null and linked_expense_id is not null);

delete from public.bills where trip_id is not null;

-- ── 2. Drop the RPCs that only existed for this feature ──
drop function if exists public.create_trip_bill_by_token(text, text, text, uuid);
drop function if exists public.link_trip_bill_expense(text, uuid, uuid);

-- ── 3. Revert get_trip_by_token to its pre-0020 shape (drops the
-- 'bills' key; same signature as before, no drop needed) ──
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
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ── 4. Revert get_bill_by_token to its pre-0021 shape (drops the
-- trip_share_token key; same signature, no drop needed) ──
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
  perform public._check_rate_limit('bill_read', 60, interval '5 minutes');

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
      select jsonb_agg(to_jsonb(i) order by i.created_at, i.id) from public.bill_items i where i.bill_id = b.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ── 5. Revert delete_bill_by_token to its pre-0020 shape (no more
-- mirrored-expense cleanup — there's nothing left to mirror) ──
create or replace function public.delete_bill_by_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_id uuid;
begin
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  delete from public.bills where id = v_bill_id;
end;
$$;

-- ── 6. Drop the linking columns themselves ──
drop index if exists idx_bills_trip_id;

alter table public.bills
  drop column if exists trip_id,
  drop column if exists linked_expense_id;

alter table public.expenses
  drop column if exists linked_bill_id;

alter table public.bill_members
  drop column if exists trip_member_id;
