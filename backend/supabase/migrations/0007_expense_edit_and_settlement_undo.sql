-- Settlr — close two of the guest RPC parity gaps noted in the README:
-- editing an already-logged expense, and undoing a settlement. Also
-- makes get_trip_by_token return expenses/settlements newest-first,
-- matching what the frontend expects (it used to unshift new items
-- onto the front of the local array).

-- ── bootstrap: load a trip + everything in it (ordered) ─
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

-- ── update an existing expense + replace its splits ─────
-- (the frontend supports editing a logged expense in place)
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
  split jsonb;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

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

  for split in select * from jsonb_array_elements(p_splits) loop
    insert into public.expense_splits (expense_id, trip_member_id, share_value, owed_amount)
    values (
      p_expense_id,
      (split->>'trip_member_id')::uuid,
      coalesce((split->>'share_value')::numeric, 0),
      (split->>'owed_amount')::numeric
    );
  end loop;
end;
$$;

-- ── undo a settlement (frontend has an "Undo" button) ───
create or replace function public.delete_settlement_by_token(p_token text, p_settlement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  select id into v_trip_id from public.trips where share_token = p_token;
  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  delete from public.settlements where id = p_settlement_id and trip_id = v_trip_id;
end;
$$;

-- ── lock down, then open exactly what's needed ──────────
revoke all on function public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb) from public;
revoke all on function public.delete_settlement_by_token(text, uuid) from public;

grant execute on function public.update_expense_by_token(text, uuid, text, text, numeric, text, numeric, uuid, text, jsonb) to anon, authenticated;
grant execute on function public.delete_settlement_by_token(text, uuid) to anon, authenticated;
