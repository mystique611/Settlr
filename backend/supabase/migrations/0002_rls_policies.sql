-- Settlr — Row Level Security for authenticated access
--
-- Design: authenticated users are governed entirely by RLS
-- (auth.uid()-based policies below). Guests have NO direct
-- table grants at all — they only reach data through the
-- SECURITY DEFINER token functions in 0003_guest_rpc_functions.sql,
-- which enforce edit/view token checks themselves and bypass
-- RLS internally. This keeps one authorization model per
-- access path instead of trying to force both into one set
-- of policies.

alter table public.trips           enable row level security;
alter table public.trip_members    enable row level security;
alter table public.expenses        enable row level security;
alter table public.expense_splits  enable row level security;
alter table public.settlements     enable row level security;
alter table public.favorites       enable row level security;

-- Revoke everything from anon; guests only get EXECUTE on the
-- RPC functions (granted at the end of 0003).
revoke all on public.trips, public.trip_members, public.expenses,
  public.expense_splits, public.settlements, public.favorites
  from anon;

-- authenticated gets normal table grants; RLS filters rows.
grant select, insert, update, delete on public.trips           to authenticated;
grant select, insert, update, delete on public.trip_members    to authenticated;
grant select, insert, update, delete on public.expenses        to authenticated;
grant select, insert, update, delete on public.expense_splits  to authenticated;
grant select, insert, update, delete on public.settlements     to authenticated;
grant select, insert, update, delete on public.favorites       to authenticated;

-- Helper: is this trip visible to the current authenticated user?
create or replace function public.is_trip_member(p_trip_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.trips t
    where t.id = p_trip_id
      and (
        t.owner_user_id = auth.uid()
        or exists (
          select 1 from public.trip_members m
          where m.trip_id = t.id and m.linked_user_id = auth.uid()
        )
      )
  );
$$;

-- ── trips ───────────────────────────────────────────────
create policy "trips_select_owner_or_member" on public.trips
  for select to authenticated
  using (
    owner_user_id = auth.uid()
    or id in (select trip_id from public.trip_members where linked_user_id = auth.uid())
  );

create policy "trips_insert_self_owned" on public.trips
  for insert to authenticated
  with check (owner_user_id = auth.uid());

create policy "trips_update_owner" on public.trips
  for update to authenticated
  using (owner_user_id = auth.uid())
  with check (owner_user_id = auth.uid());

create policy "trips_delete_owner" on public.trips
  for delete to authenticated
  using (owner_user_id = auth.uid());

-- ── trip_members ────────────────────────────────────────
create policy "members_select" on public.trip_members
  for select to authenticated
  using (public.is_trip_member(trip_id));

create policy "members_insert" on public.trip_members
  for insert to authenticated
  with check (public.is_trip_member(trip_id));

create policy "members_update" on public.trip_members
  for update to authenticated
  using (public.is_trip_member(trip_id))
  with check (public.is_trip_member(trip_id));

create policy "members_delete" on public.trip_members
  for delete to authenticated
  using (public.is_trip_member(trip_id));

-- ── expenses ────────────────────────────────────────────
create policy "expenses_select" on public.expenses
  for select to authenticated
  using (public.is_trip_member(trip_id));

create policy "expenses_insert" on public.expenses
  for insert to authenticated
  with check (public.is_trip_member(trip_id));

create policy "expenses_update" on public.expenses
  for update to authenticated
  using (public.is_trip_member(trip_id))
  with check (public.is_trip_member(trip_id));

create policy "expenses_delete" on public.expenses
  for delete to authenticated
  using (public.is_trip_member(trip_id));

-- ── expense_splits (scoped via parent expense's trip) ───
create policy "splits_select" on public.expense_splits
  for select to authenticated
  using (
    exists (select 1 from public.expenses e where e.id = expense_id and public.is_trip_member(e.trip_id))
  );

create policy "splits_insert" on public.expense_splits
  for insert to authenticated
  with check (
    exists (select 1 from public.expenses e where e.id = expense_id and public.is_trip_member(e.trip_id))
  );

create policy "splits_update" on public.expense_splits
  for update to authenticated
  using (
    exists (select 1 from public.expenses e where e.id = expense_id and public.is_trip_member(e.trip_id))
  );

create policy "splits_delete" on public.expense_splits
  for delete to authenticated
  using (
    exists (select 1 from public.expenses e where e.id = expense_id and public.is_trip_member(e.trip_id))
  );

-- ── settlements ─────────────────────────────────────────
create policy "settlements_select" on public.settlements
  for select to authenticated
  using (public.is_trip_member(trip_id));

create policy "settlements_insert" on public.settlements
  for insert to authenticated
  with check (public.is_trip_member(trip_id));

create policy "settlements_delete" on public.settlements
  for delete to authenticated
  using (public.is_trip_member(trip_id));

-- ── favorites (private to the owning user) ──────────────
create policy "favorites_all_own" on public.favorites
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
