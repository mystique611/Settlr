# Settlr — Supabase backend (guest-mode + RLS)

Seventeen migrations, run in order:

1. `0001_schema.sql` — core trip tables: `trips`, `trip_members`, `expenses`, `expense_splits`, `settlements`, `favorites`. Requires `extensions` to be on the search path (see note below) since `gen_random_bytes()` lives there on hosted Supabase projects.
2. `0002_rls_policies.sql` — enables RLS, locks `anon` out of every table, and adds `auth.uid()`-based policies so authenticated users can only see trips they own or belong to.
3. `0003_guest_rpc_functions.sql` — the original guest-mode API surface for trips (superseded by `0004` below — kept as-is since migrations are layered on top of, never edited after being written).
4. `0004_single_share_token.sql` — collapses `trips.edit_token`/`trips.view_token` into one `trips.share_token`, matching the frontend, which no longer has an editor/viewer distinction — every guest with a trip's link gets full access. Rewrites every function from `0003` to use the new column.
5. `0005_bill_splits.sql` — schema, RLS, and guest-token API for Bill Split (`bills`, `bill_members`, `bill_items`) — the single-receipt quick-split feature, separate from a full trip.
6. `0006_hex_share_tokens.sql` — switches `share_token` generation from base64 to hex. Base64 output can contain `/`, `+`, `=`, and a `/` in particular breaks the `settlr.app/t/<token>` URL scheme. Hex is always `[0-9a-f]`, matching the format the frontend's own local token generator already uses.
7. `0007_expense_edit_and_settlement_undo.sql` — adds `update_expense_by_token` and `delete_settlement_by_token` (two of the parity gaps noted below), and makes `get_trip_by_token` return expenses/settlements newest-first.
8. `0008_trip_edit_and_bill_item_edit.sql` — closes out the remaining parity gaps: `update_trip_by_token` (rename + change currencies), `delete_trip_by_token`, `update_trip_member_by_token` / `delete_trip_member_by_token` (rename/remove a mate), `update_bill_item_by_token`, and `delete_bill_by_token`. This was the last of the guest RPC gaps.
9. `0009_expense_split_validation.sql` — `add_expense_by_token`/`update_expense_by_token` no longer trust the client's per-member `owed_amount` as-is. A new `_recompute_expense_splits()` helper recomputes equal/percentage splits server-side and validates that exact splits still add up to the expense total, rejecting anything that doesn't reconcile.
10. `0010_rate_limiting.sql` — a `_rpc_attempt_log` table + `_check_rate_limit()` helper, keyed on the caller's IP (read from the request headers PostgREST forwards) rather than the token being tried. Applied to every anon-facing guest RPC: 60 requests/5 minutes for the two bootstrap reads (`get_trip_by_token`/`get_bill_by_token`), 30 requests/5 minutes for every mutation (create/add/update/delete/claim).
11. `0011_bill_tax_defaults.sql` — changes `bills.service_pct`/`bills.gst_pct` column defaults from 0 to 10/9, so a new bill split starts with sensible tax defaults instead of every guest typing them in manually. Only affects bills created from here on.
12. `0012_rotate_token_on_claim.sql` — `claim_trip`/`claim_bill` now generate a fresh `share_token` at the moment of claiming and write it in the same update, returning it in the response. The pre-claim guest link stops working immediately once a record belongs to an account, closing the access-leak risk of an old link staying live forever.
13. `0013_bill_edit_parity.sql` — adds `update_bill_by_token` (rename + change currency) and `add_bill_member_by_token` / `update_bill_member_by_token` / `delete_bill_member_by_token`, giving bills the same post-creation edit parity trips have had since `0008`. Backs the frontend's new Edit Bill screen (which reuses Create Bill Split).
14. `0014_expense_receipts.sql` — `add_expense_by_token`/`update_expense_by_token` gain a `p_receipt_path` param (`update_expense_by_token` also gets `p_clear_receipt`) so they can record the Storage object path from an uploaded receipt against `expenses.receipt_path` (a column that's existed since `0001` but was never wired up until now). Both functions are explicitly dropped before being recreated, since adding a parameter changes the function's signature — `create or replace` alone would've left the old signature behind as a separate overload instead of actually replacing it.
15. `0015_receipt_storage_bucket.sql` — creates the private `receipts` Storage bucket and RLS policies restricting every operation to `(storage.foldername(name))[1] = auth.uid()::text`, i.e. everyone can only touch objects under their own user-id folder. **Can't be exercised by this project's pglite test harness** — the `storage` schema is a Supabase-platform feature, not something a bare embedded Postgres has — so this one needs a live check after deploying: upload a receipt as one account, confirm a second account can't list or fetch it.
16. `0016_receipt_scan_rate_limit.sql` — creates `receipt_scan_log` (client IP + timestamp) with RLS enabled and **no policies at all**, so `anon`/`authenticated` get zero access and only the service role can touch it. This backs the `scan-receipt` Edge Function's own IP-based rate limit (see below) — a separate mechanism from `_check_rate_limit`/`_rpc_attempt_log` (`0010`), since that one only guards RPCs called through PostgREST, not an Edge Function calling out to a third-party API. Also adds `_prune_receipt_scan_log()`, a standalone helper (not currently scheduled) that deletes log rows older than 7 days.
17. `0017_bill_discount.sql` — adds `discount_mode`/`discount_percent`/`discount_exact` to `bills` (same percent-or-exact pattern as `tip_mode`/`tip_percent`/`tip_exact`), for a discount taken off the item subtotal before service tax/GST/tip are calculated. `update_bill_settings_by_token` gains the three new params — its signature changed, so the old one is dropped before being recreated, same reasoning as `0014`. Per-item discounts (as opposed to this bill-level one) don't touch the schema at all: the discounted amount is just what gets written to `bill_items.amount`, computed client-side before the item is ever saved.

Note on `extensions.gen_random_bytes()`: on hosted Supabase projects, pgcrypto's functions are installed into the `extensions` schema rather than `public`. `0001` and `0005` each run `set search_path = public, extensions;` before creating anything that calls `gen_random_bytes()`, since every migration file runs in its own session and doesn't inherit an earlier file's `SET`.

## How it fits together

- **Authenticated users** → normal Supabase client calls (`supabase.from('trips').select()`, etc.) — RLS in `0002` filters everything automatically. Bills use the same pattern but are owner-only (a bill isn't shared across accounts the way a trip is). Creating a trip/bill while signed in is a direct insert with `owner_user_id` set to `auth.uid()` (authorized by `trips_insert_self_owned`/`bills_insert_self_owned`), not `create_guest_trip`/`create_guest_bill` (those have no owner param — they're the guest entry point). Listing "my trips" is a lightweight `select('id, share_token, updated_at')` per table, then one `get_trip_by_token`/`get_bill_by_token` call per row — reusing the exact same RPC and frontend adapter guests use rather than a bespoke nested-select shape. A useful side effect: every trip/bill still gets a `share_token` regardless of who created it, so an authenticated user's trip already has full edit/delete/expense/settle-up support for free, through the same guest RPCs — no separate authenticated-only mutation path was needed for this pass.
- **Guests** → call the RPC functions with the token from the URL. Every guest read/write goes through a `SECURITY DEFINER` function that looks the record up by token and treats a valid token as full read+write authorization — there's no separate view-only mode.

  ```js
  const { data } = await supabase.rpc('get_trip_by_token', { p_token: tokenFromUrl });
  ```

  ```js
  await supabase.rpc('add_expense_by_token', {
    p_token: tokenFromUrl,
    p_description: 'Dinner',
    p_category: 'food',
    p_amount: 68.5,
    p_currency: 'USD',
    p_exchange_rate: 1,
    p_paid_by: memberId,
    p_split_type: 'equal',
    p_splits: [{ trip_member_id: idA, share_value: 0, owed_amount: 34.25 }, ...]
  });
  ```

  Editing a trip in place (name, home currency, travel currencies) and managing its mates:

  ```js
  await supabase.rpc('update_trip_by_token', {
    p_token: tokenFromUrl,
    p_name: 'Bali Trip 2026',
    p_home_currency: 'SGD',
    p_travel_currencies: ['USD', 'IDR']
  });

  await supabase.rpc('update_trip_member_by_token', { p_token: tokenFromUrl, p_member_id: idA, p_display_name: 'Alexander' });
  await supabase.rpc('delete_trip_member_by_token', { p_token: tokenFromUrl, p_member_id: idB });
  // add_trip_member_by_token (0004) covers adding a brand-new mate.

  await supabase.rpc('delete_trip_by_token', { p_token: tokenFromUrl }); // permanent — cascades to everything in the trip
  ```

  Bill Split mirrors this exactly, just with `_bill_` in place of `_trip_`:

  ```js
  const { data } = await supabase.rpc('create_guest_bill', {
    p_name: 'Dinner at Nobu',
    p_currency: 'USD',
    p_member_names: ['Alex', 'Jordan', 'Priya'],
    p_payer_name: 'Alex'
  });
  // data.share_token goes in the shareable link

  await supabase.rpc('add_bill_item_by_token', {
    p_token: shareToken,
    p_description: 'Wagyu Steak',
    p_amount: 68.00,
    p_owed_by: jordanMemberId
  });

  await supabase.rpc('update_bill_settings_by_token', {
    p_token: shareToken,
    p_payer_member_id: alexMemberId,
    p_tax_included: false,
    p_service_pct: 10,
    p_gst_on_service: true,
    p_gst_pct: 9,
    p_tip_mode: 'percent',
    p_tip_percent: 0,
    p_tip_exact: 0,
    p_discount_mode: 'percent',
    p_discount_percent: 5,
    p_discount_exact: 0
  });

  await supabase.rpc('update_bill_item_by_token', {
    p_token: shareToken,
    p_item_id: itemId,
    p_description: 'Wagyu Steak (extra)',
    p_amount: 75.00,
    p_owed_by: priyaMemberId
  });

  await supabase.rpc('delete_bill_by_token', { p_token: shareToken }); // permanent — cascades to members + items
  ```

- **Claiming a guest record** → once a guest signs in, `claim_trip` / `claim_bill` with the same token attaches it to their account (their session JWT is picked up automatically by the Supabase client):

  ```js
  await supabase.rpc('claim_trip', { p_token: tokenFromUrl });
  await supabase.rpc('claim_bill', { p_token: tokenFromUrl });
  ```

  This only succeeds if the record hasn't already been claimed by someone else, so it's safe to expose to anyone who has the link. The frontend now calls this from a "Save to My Account" button on the Trip Link / Bill Link screens, shown whenever a signed-in user is viewing a guest-created trip/bill. Since `0012`, both functions also rotate `share_token` and return the new one (`{ trip_id, name, share_token }` / `{ bill_id, name, share_token }`) — the pre-claim link stops resolving right away, so the frontend swaps in the new token to keep the Trip Link / Bill Link screen showing a link that still works.

- **Editing a bill in place** (name, currency) and managing its people, mirroring `update_trip_by_token`/the trip member functions above:

  ```js
  await supabase.rpc('update_bill_by_token', { p_token: shareToken, p_name: 'Dinner at Nobu v2', p_currency: 'SGD' });
  await supabase.rpc('add_bill_member_by_token', { p_token: shareToken, p_display_name: 'Priya' });
  await supabase.rpc('update_bill_member_by_token', { p_token: shareToken, p_member_id: priyaId, p_display_name: 'Priya S.' });
  await supabase.rpc('delete_bill_member_by_token', { p_token: shareToken, p_member_id: priyaId });
  // Fails with a 23503 foreign-key violation if that person owes a bill item —
  // bill_items.owed_by is ON DELETE RESTRICT, same reasoning as trip mates above.
  // Only set as the payer (bills.payer_member_id, ON DELETE SET NULL)? Clears quietly instead.
  ```

- **Removing a trip mate** (`delete_trip_member_by_token`) fails with a foreign-key violation (`23503`) if that person is referenced as an expense's `paid_by` — that FK is `ON DELETE RESTRICT` (see `0001`) specifically so removing someone doesn't silently orphan an expense's meaning. The frontend surfaces this as an alert rather than swallowing it. Their `expense_splits` and `settlements` rows, by contrast, cascade-delete along with them.

## Edge Functions

- **`scan-receipt`** (`backend/supabase/functions/scan-receipt/index.ts`) — the only Edge Function in the project. Called directly from the browser with a receipt photo (base64 + mime type); forwards it to Gemini's `generateContent` API with a prompt asking for strict JSON (one entry per line item, plus subtotal/tax/service/tip/total if present), and returns the parsed result. It never touches trip/bill data and needs no share token — it's a stateless OCR proxy, not part of the guest-token API surface above.

  Why this has to be a server-side function rather than a plain `fetch()` from `index.html`: the Gemini API key is a secret, and anything in the HTML/JS is visible to anyone who views source (unlike the Supabase anon key, which is deliberately safe to expose because RLS is the real gate). The key lives only as an Edge Function secret, read via `Deno.env.get('GEMINI_API_KEY')`.

  Deploy and configure:
  ```
  supabase secrets set GEMINI_API_KEY=<your key> --project-ref <ref>
  supabase functions deploy scan-receipt --project-ref <ref>
  ```
  Optional secret `GEMINI_MODEL` overrides the default model (`gemini-2.5-flash`) without a redeploy — useful since Google's model lineup moves fast.

  Rate limiting: every call first checks `receipt_scan_log` (via the service role client, bypassing RLS) for more than 15 scans from the same IP in the last hour, and rejects with a 429 if so — protecting the project's Gemini quota from being burned by one visitor or a script, independent of the Postgres-side rate limiter that guards `.rpc()` calls.

  **Not testable via the pglite harness or in this sandbox** — Edge Functions require the Deno runtime and a real network call to Gemini, neither of which the local migration test harness has. Verify live after deploying: scan an actual receipt from the Bill Split dashboard and confirm the Review Scanned Items screen populates correctly.

## Still to do before this is production-ready

- **Guest RPC parity is complete** — every mutation the frontend supports for trips and bill splits has a corresponding guest-token RPC as of `0008`, plus bill rename/currency/member-management parity as of `0013`.
- **Rate limiting is done (`0010`)** — every anon-facing guest RPC now throttles by caller IP.
- **Server-side split validation is done (`0009`)** — `expense_splits.owed_amount` is recomputed/validated server-side rather than trusted from the client.
- **Claiming a guest record into an account is wired up, and the old link is rotated dead (`0012`)** — the "Save to My Account" button on Trip Link / Bill Link calls `claim_trip`/`claim_bill`, which now also regenerates `share_token` so the pre-claim link stops working immediately.
- **Receipt photo uploads are wired up (`0014`/`0015`)** — authenticated-only, uploaded client-side straight to the `receipts` Storage bucket, path recorded on `expenses.receipt_path` via the two expense RPCs. This was the last item on this list.
- The rate limiter's IP-extraction (`request.headers` → `x-forwarded-for`) depends on PostgREST forwarding that header — worth a quick live check after deploying `0010` that it's actually populated on your project rather than silently falling back to the shared `'unknown'` bucket for every caller.
- `0015`'s Storage bucket + RLS policies can't be exercised by the pglite harness (no `storage` schema in a bare embedded Postgres) — verify live: upload a receipt as one account, confirm a second account can't fetch or list it.
- **AI receipt scanning is wired up (`0016` + the `scan-receipt` Edge Function)** — this was the last item on this list. Requires a Gemini API key and a manual `supabase functions deploy` (see "Edge Functions" above); not exercised by any automated test, so verify live with a real receipt photo after deploying.
