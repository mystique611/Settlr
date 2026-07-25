-- Settlr — stop trusting the client's per-member owed_amount at face
-- value. Until now, add_expense_by_token/update_expense_by_token stored
-- whatever split the client computed and sent, which means a buggy (or
-- malicious) client could store numbers that don't actually reconcile
-- against the expense's total — and since expense_splits.owed_amount is
-- what OTHER trip members see as "you owe $X", that's a real integrity
-- gap, not just a display quirk.
--
-- Design: recompute what's algorithmically determined (equal/percentage
-- splits), and validate what's inherently manual (exact splits, where
-- the person typed specific dollar amounts) still adds up to the total.
-- This intentionally does NOT try to replicate the frontend's own
-- rounding-remainder-distribution logic exactly — it uses its own simple,
-- deterministic rule (every split gets the rounded share except the
-- last, which absorbs whatever's left) so the stored amounts always sum
-- to the expense total exactly, regardless of what the client sent.

create or replace function public._recompute_expense_splits(
  p_amount numeric,
  p_split_type text,
  p_splits jsonb
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  n int;
  i int := 0;
  result jsonb := '[]'::jsonb;
  split jsonb;
  base numeric;
  running numeric := 0;
  total_shares numeric := 0;
  total_exact numeric := 0;
  member_id uuid;
  share_value numeric;
  owed numeric;
begin
  n := jsonb_array_length(p_splits);
  if n = 0 then
    raise exception 'An expense needs at least one split' using errcode = '22023';
  end if;

  if p_split_type = 'equal' then
    base := round(p_amount / n, 2);
    for split in select * from jsonb_array_elements(p_splits) loop
      i := i + 1;
      member_id := (split->>'trip_member_id')::uuid;
      if i = n then
        owed := p_amount - running;
      else
        owed := base;
        running := running + owed;
      end if;
      result := result || jsonb_build_object('trip_member_id', member_id, 'share_value', 0, 'owed_amount', owed);
    end loop;

  elsif p_split_type = 'percentage' then
    for split in select * from jsonb_array_elements(p_splits) loop
      total_shares := total_shares + coalesce((split->>'share_value')::numeric, 0);
    end loop;
    if total_shares < 99 or total_shares > 101 then
      raise exception 'Split percentages must add up to 100%% (got %)', total_shares using errcode = '22023';
    end if;
    for split in select * from jsonb_array_elements(p_splits) loop
      i := i + 1;
      member_id := (split->>'trip_member_id')::uuid;
      share_value := coalesce((split->>'share_value')::numeric, 0);
      if i = n then
        owed := p_amount - running;
      else
        owed := round(p_amount * share_value / 100, 2);
        running := running + owed;
      end if;
      result := result || jsonb_build_object('trip_member_id', member_id, 'share_value', share_value, 'owed_amount', owed);
    end loop;

  elsif p_split_type = 'exact' then
    for split in select * from jsonb_array_elements(p_splits) loop
      total_exact := total_exact + coalesce((split->>'owed_amount')::numeric, 0);
    end loop;
    if abs(total_exact - p_amount) > 0.01 then
      raise exception 'Exact split amounts must add up to the total expense amount (got % vs %)', total_exact, p_amount using errcode = '22023';
    end if;
    for split in select * from jsonb_array_elements(p_splits) loop
      member_id := (split->>'trip_member_id')::uuid;
      owed := coalesce((split->>'owed_amount')::numeric, 0);
      share_value := coalesce((split->>'share_value')::numeric, 0);
      result := result || jsonb_build_object('trip_member_id', member_id, 'share_value', share_value, 'owed_amount', owed);
    end loop;

  else
    raise exception 'Unknown split_type: %', p_split_type using errcode = '22023';
  end if;

  return result;
end;
$$;

revoke all on function public._recompute_expense_splits(numeric, text, jsonb) from public;
-- Intentionally no grants — this is only ever called from inside the
-- other SECURITY DEFINER functions below, which execute as their owner
-- (not the original anon/authenticated caller), so it needs no direct
-- callers of its own.

-- ── add an expense + its splits (now server-validated) ──
create or replace function public.add_expense_by_token(
  p_token text,
  p_description text,
  p_category text,
  p_amount numeric,
  p_currency text,
  p_exchange_rate numeric,
  p_paid_by uuid,
  p_split_type text,
  p_splits jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_expense_id uuid;
  v_splits jsonb;
  split jsonb;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  v_splits := public._recompute_expense_splits(p_amount, p_split_type, p_splits);

  insert into public.expenses (
    trip_id, description, category, amount, currency, exchange_rate, paid_by, split_type
  ) values (
    v_trip_id, p_description, p_category, p_amount, p_currency, p_exchange_rate, p_paid_by, p_split_type
  ) returning id into v_expense_id;

  for split in select * from jsonb_array_elements(v_splits) loop
    insert into public.expense_splits (expense_id, trip_member_id, share_value, owed_amount)
    values (
      v_expense_id,
      (split->>'trip_member_id')::uuid,
      (split->>'share_value')::numeric,
      (split->>'owed_amount')::numeric
    );
  end loop;

  return v_expense_id;
end;
$$;

-- ── update an existing expense + replace its splits (server-validated) ──
create or replace function public.update_expense_by_token(
  p_token text,
  p_expense_id uuid,
  p_description text,
  p_category text,
  p_amount numeric,
  p_currency text,
  p_exchange_rate numeric,
  p_paid_by uuid,
  p_split_type text,
  p_splits jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_splits jsonb;
  split jsonb;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  v_splits := public._recompute_expense_splits(p_amount, p_split_type, p_splits);

  update public.expenses set
    description = p_description,
    category = p_category,
    amount = p_amount,
    currency = p_currency,
    exchange_rate = p_exchange_rate,
    paid_by = p_paid_by,
    split_type = p_split_type
  where id = p_expense_id and trip_id = v_trip_id;

  delete from public.expense_splits where expense_id = p_expense_id;

  for split in select * from jsonb_array_elements(v_splits) loop
    insert into public.expense_splits (expense_id, trip_member_id, share_value, owed_amount)
    values (
      p_expense_id,
      (split->>'trip_member_id')::uuid,
      (split->>'share_value')::numeric,
      (split->>'owed_amount')::numeric
    );
  end loop;
end;
$$;

-- Grants for add_expense_by_token/update_expense_by_token are unchanged
-- from where they were first granted (0003/0007) — CREATE OR REPLACE
-- keeps existing GRANTs, so nothing to re-run for those two.
