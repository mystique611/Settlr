-- Settlr — guest-mode token access
--
-- Guests never touch tables directly. Every guest read/write
-- goes through one of these SECURITY DEFINER functions, each
-- of which:
--   1. looks up the trip by the token it was given
--   2. resolves 'editor' (edit_token) vs 'viewer' (view_token)
--   3. rejects the call if the required access level isn't met
--   4. only then performs the actual read/write
--
-- Because these run SECURITY DEFINER, they execute with the
-- privileges of the function owner (not the calling anon role)
-- and bypass RLS — which is fine, because the token check IS
-- the authorization check for this path.

-- ── bootstrap: load a trip + everything in it ───────────
create or replace function public.get_trip_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips%rowtype;
  v_role text;
  v_result jsonb;
begin
  select * into t from public.trips
  where edit_token = p_token or view_token = p_token;

  if not found then
    raise exception 'Invalid or expired trip link' using errcode = '28000';
  end if;

  v_role := case when t.edit_token = p_token then 'editor' else 'viewer' end;

  select jsonb_build_object(
    'trip', to_jsonb(t) - 'edit_token' - 'view_token',
    'role', v_role,
    'members', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.trip_members m where m.trip_id = t.id
    ), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(to_jsonb(e)) from public.expenses e where e.trip_id = t.id
    ), '[]'::jsonb),
    'expense_splits', coalesce((
      select jsonb_agg(to_jsonb(s))
      from public.expense_splits s
      join public.expenses e on e.id = s.expense_id
      where e.trip_id = t.id
    ), '[]'::jsonb),
    'settlements', coalesce((
      select jsonb_agg(to_jsonb(st)) from public.settlements st where st.trip_id = t.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ── create a brand-new guest trip ───────────────────────
create or replace function public.create_guest_trip(
  p_name text,
  p_home_currency text,
  p_travel_currencies text[],
  p_member_names text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.trips%rowtype;
  m_name text;
begin
  insert into public.trips (name, home_currency, travel_currencies)
  values (p_name, p_home_currency, p_travel_currencies)
  returning * into t;

  foreach m_name in array p_member_names loop
    insert into public.trip_members (trip_id, display_name) values (t.id, m_name);
  end loop;

  return jsonb_build_object(
    'trip_id', t.id,
    'edit_token', t.edit_token,
    'view_token', t.view_token
  );
end;
$$;

-- ── add a trip mate (requires edit access) ──────────────
create or replace function public.add_trip_member_by_token(p_token text, p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_id uuid;
begin
  select id into v_trip_id from public.trips where edit_token = p_token;
  if not found then
    raise exception 'This link does not have permission to add trip mates' using errcode = '28000';
  end if;

  insert into public.trip_members (trip_id, display_name)
  values (v_trip_id, p_display_name)
  returning id into v_id;

  return v_id;
end;
$$;

-- ── add an expense + its splits (requires edit access) ──
-- p_splits: [{ "trip_member_id": "...", "share_value": 0, "owed_amount": 0 }, ...]
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
  split jsonb;
begin
  select id into v_trip_id from public.trips where edit_token = p_token;
  if not found then
    raise exception 'This link is view-only — ask the trip owner for the editable link' using errcode = '28000';
  end if;

  insert into public.expenses (
    trip_id, description, category, amount, currency, exchange_rate, paid_by, split_type
  ) values (
    v_trip_id, p_description, p_category, p_amount, p_currency, p_exchange_rate, p_paid_by, p_split_type
  ) returning id into v_expense_id;

  for split in select * from jsonb_array_elements(p_splits) loop
    insert into public.expense_splits (expense_id, trip_member_id, share_value, owed_amount)
    values (
      v_expense_id,
      (split->>'trip_member_id')::uuid,
      coalesce((split->>'share_value')::numeric, 0),
      (split->>'owed_amount')::numeric
    );
  end loop;

  return v_expense_id;
end;
$$;

-- ── delete an expense (requires edit access) ────────────
create or replace function public.delete_expense_by_token(p_token text, p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
begin
  select id into v_trip_id from public.trips where edit_token = p_token;
  if not found then
    raise exception 'This link is view-only — ask the trip owner for the editable link' using errcode = '28000';
  end if;

  delete from public.expenses where id = p_expense_id and trip_id = v_trip_id;
end;
$$;

-- ── record a (possibly partial) settlement ──────────────
create or replace function public.record_settlement_by_token(
  p_token text,
  p_from_member uuid,
  p_to_member uuid,
  p_amount numeric,
  p_currency text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip_id uuid;
  v_id uuid;
begin
  select id into v_trip_id from public.trips where edit_token = p_token;
  if not found then
    raise exception 'This link is view-only — ask the trip owner for the editable link' using errcode = '28000';
  end if;

  insert into public.settlements (trip_id, from_member_id, to_member_id, amount, currency, note)
  values (v_trip_id, p_from_member, p_to_member, p_amount, p_currency, p_note)
  returning id into v_id;

  return v_id;
end;
$$;

-- ── claim a guest trip into the signed-in account ───────
-- Called by an authenticated client via supabase.rpc(); the
-- caller's JWT (and therefore auth.uid()) is already attached,
-- so no separate Edge Function is needed for this step.
create or replace function public.claim_trip(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  t public.trips%rowtype;
begin
  if v_uid is null then
    raise exception 'You must be signed in to claim a trip' using errcode = '28000';
  end if;

  select * into t from public.trips where edit_token = p_token or view_token = p_token;
  if not found then
    raise exception 'Invalid trip link' using errcode = '28000';
  end if;

  if t.owner_user_id is not null and t.owner_user_id <> v_uid then
    raise exception 'This trip has already been claimed by another account' using errcode = '28000';
  end if;

  update public.trips set owner_user_id = v_uid, updated_at = now() where id = t.id;

  return jsonb_build_object('trip_id', t.id, 'name', t.name);
end;
$$;

-- ── lock functions down, then open exactly what's needed ─
revoke all on function public.get_trip_by_token(text) from public;
revoke all on function public.create_guest_trip(text, text, text[], text[]) from public;
revoke all on function public.add_trip_member_by_token(text, text) from public;
revoke all on function public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb) from public;
revoke all on function public.delete_expense_by_token(text, uuid) from public;
revoke all on function public.record_settlement_by_token(text, uuid, uuid, numeric, text, text) from public;
revoke all on function public.claim_trip(text) from public;

-- Guests (anon) and signed-in users can both use token-based
-- access (e.g. a signed-in user opening someone else's shared
-- link before claiming it).
grant execute on function public.get_trip_by_token(text) to anon, authenticated;
grant execute on function public.create_guest_trip(text, text, text[], text[]) to anon, authenticated;
grant execute on function public.add_trip_member_by_token(text, text) to anon, authenticated;
grant execute on function public.add_expense_by_token(text, text, text, numeric, text, numeric, uuid, text, jsonb) to anon, authenticated;
grant execute on function public.delete_expense_by_token(text, uuid) to anon, authenticated;
grant execute on function public.record_settlement_by_token(text, uuid, uuid, numeric, text, text) to anon, authenticated;

-- claim_trip requires a session, so only authenticated gets it.
grant execute on function public.claim_trip(text) to authenticated;
