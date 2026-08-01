-- Settlr — persist per-item discount %, stop items reordering on edit
--
-- Two related fixes to Bill Split items, both reported against the
-- discount feature added in 0017:
--
-- 1. Per-item discount % was applied to the saved amount but never
--    itself recorded, so reopening a discounted item for edit (or
--    looking at a committed scanned item) always showed 0% — the
--    discount's *effect* survived, its *value* didn't. Fixed by adding
--    bill_items.discount_pct. The already-discounted amount is still
--    what's stored in `amount` (nothing about totals/split math
--    changes) — discount_pct is purely so the frontend can show it
--    again and reconstruct the pre-discount amount for editing
--    (original = amount / (1 - discount_pct/100), safe since a 100%
--    discount is rejected client-side before it ever reaches here).
--
-- 2. Editing an item visibly jumped it to a different position in the
--    list. Two compounding causes: update_bill_item_by_token existed
--    but the frontend used delete-then-recreate for every edit
--    (getting a new id/created_at), AND get_bill_by_token's items
--    query had no ORDER BY at all, so jsonb_agg's row order was
--    whatever Postgres felt like on a given read. This migration fixes
--    the second half (a stable order by created_at); the frontend
--    fix (using update_bill_item_by_token in place instead of
--    delete+recreate) is the other half, done alongside this.

set search_path = public, extensions;

alter table public.bill_items
  add column discount_pct numeric(5,2) not null default 0;

comment on column public.bill_items.discount_pct is 'Discount applied to this row before it was saved — amount is already net of it. Stored only so the frontend can show/re-edit the percent; original = amount / (1 - discount_pct/100).';

-- ── add_bill_item_by_token: new discount_pct param ──
drop function if exists public.add_bill_item_by_token(text, text, numeric, uuid);

create or replace function public.add_bill_item_by_token(
  p_token text,
  p_description text,
  p_amount numeric,
  p_owed_by uuid,
  p_discount_pct numeric default 0
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
  perform public._check_rate_limit('bill_write', 30, interval '5 minutes');

  select id into v_bill_id from public.bills where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired bill link' using errcode = '28000';
  end if;

  insert into public.bill_items (bill_id, description, amount, owed_by, discount_pct)
  values (v_bill_id, p_description, p_amount, p_owed_by, coalesce(p_discount_pct, 0))
  returning id into v_id;

  update public.bills set updated_at = now() where id = v_bill_id;
  return v_id;
end;
$$;

-- ── update_bill_item_by_token: new discount_pct param — this is the
-- one the frontend now calls for a same-person-count edit, so the row
-- (and its position) stays exactly where it was. ──
drop function if exists public.update_bill_item_by_token(text, uuid, text, numeric, uuid);

create or replace function public.update_bill_item_by_token(
  p_token text,
  p_item_id uuid,
  p_description text,
  p_amount numeric,
  p_owed_by uuid,
  p_discount_pct numeric default 0
)
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

  update public.bill_items set
    description = p_description,
    amount = p_amount,
    owed_by = p_owed_by,
    discount_pct = coalesce(p_discount_pct, 0)
  where id = p_item_id and bill_id = v_bill_id;

  update public.bills set updated_at = now() where id = v_bill_id;
end;
$$;

-- ── get_bill_by_token: same signature, just adding an ORDER BY so
-- item position is deterministic and stable across reads. ──
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

-- ── lock functions down, then open exactly what's needed ─
revoke all on function public.add_bill_item_by_token(text, text, numeric, uuid, numeric) from public;
revoke all on function public.update_bill_item_by_token(text, uuid, text, numeric, uuid, numeric) from public;

grant execute on function public.add_bill_item_by_token(text, text, numeric, uuid, numeric) to anon, authenticated;
grant execute on function public.update_bill_item_by_token(text, uuid, text, numeric, uuid, numeric) to anon, authenticated;
