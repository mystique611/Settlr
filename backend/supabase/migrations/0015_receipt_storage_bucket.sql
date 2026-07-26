-- Settlr — Storage bucket + RLS for receipt photos.
--
-- Receipts are authenticated-only (guests have nowhere durable to keep
-- them, and there's no account to eventually claim them into if the
-- guest never signs up) — enforced here at the Storage layer rather
-- than in the RPCs, since the RPCs never touch file bytes at all; the
-- browser uploads straight to Storage using the signed-in user's own
-- session, then only the resulting object path gets passed to
-- add_expense_by_token/update_expense_by_token (see 0014).
--
-- Path convention the frontend uses: <user_id>/<trip_id>/<uuid>.<ext>
-- — every policy below just checks that the first path segment is the
-- caller's own auth.uid(), so nobody can read or overwrite another
-- user's receipts even though they're all sitting in one bucket.
--
-- NOTE: this migration can't be exercised by the project's pglite test
-- harness — the `storage` schema/extension is a Supabase-platform
-- feature, not something a bare embedded Postgres has. Review by
-- reading, then verify live: upload a receipt as one account, confirm
-- a second account can't list or fetch it.

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

create policy "receipts_insert_own_folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "receipts_select_own_folder" on storage.objects
  for select to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "receipts_update_own_folder" on storage.objects
  for update to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "receipts_delete_own_folder" on storage.objects
  for delete to authenticated
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
