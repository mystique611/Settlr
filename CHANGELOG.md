# Changelog

All notable changes to Settlr, newest first. Dates reflect when each milestone was built.

## 2026-07-25 — Real accounts (Supabase Auth)

- Wired real email/password sign-up, sign-in, and sign-out via Supabase Auth, replacing the old fake `window.isAuthenticated = true` toggle. Sessions persist across reloads (restored automatically on load) and stay in sync via `onAuthStateChange`.
- Creating a trip or bill while signed in now does a real, owned insert (`owner_user_id` set to the signed-in user), authorized by the RLS policies already in place — not the guest RPC path, which has no concept of an owner.
- "Your Trips" / "Your Bills" on the Account Mode home screen now load from Supabase (`loadMyTrips`/`loadMyBills`), reusing the exact same `get_trip_by_token`/`get_bill_by_token` RPCs and adapters the guest flows already use, rather than a separate nested-query code path.
- Every trip/bill still gets a `share_token` regardless of who created it — so an authenticated user's own trips already support edit/delete/expenses/settle-up for free, through the same guest-RPC mutation code, with no separate authenticated-only write path needed.
- Old hardcoded demo trips/bills (used to populate Account Mode before real auth existed) are now flagged `isDemo` and excluded from the real "Your Trips"/"Your Bills" lists, so a real signed-in user only ever sees their own data.
- Added a Sign Out control and "Signed in as ..." label to the Account Mode home screen.
- Google/Microsoft sign-in buttons remain decorative for now — real OAuth needs provider credentials configured in Google Cloud / Azure plus the corresponding Supabase dashboard setup, which is an external, per-deployment setup step rather than something to hardcode into the prototype.

## 2026-07-25 — Trip editing, trip deletion, and full Bill Split parity

- New migration `0008_trip_edit_and_bill_item_edit.sql`: `update_trip_by_token`, `delete_trip_by_token`, `update_trip_member_by_token`, `delete_trip_member_by_token`, `update_bill_item_by_token`, `delete_bill_by_token`. This closed out every remaining guest-RPC parity gap.
- Edit Trip now diffs the mates list against real member ids (stamped on each row when the edit screen loads) so a rename, an add, and a remove can all happen in the same save — each hits the right RPC instead of guessing identity from name alone.
- Delete Trip and Delete Bill Split now actually delete server-side before clearing local state, instead of only ever deleting the local copy.
- Bill Split went from fully local-only to fully wired: creating a bill, adding/editing/deleting items, and the tax/service/GST/tip/payer settings (debounced so typing doesn't fight a save-triggered UI refresh) all sync to Supabase.
- Fixed a latent bug where a trip/bill opened from its local device list could carry a stale cached snapshot (missing newer fields like `memberIds`) into the dashboard; opening a trip or bill now always refreshes from Supabase first when it has a `share_token`.

## 2026-07-25 — Expense editing and settlement undo

- New migration `0007_expense_edit_and_settlement_undo.sql`: `update_expense_by_token` and `delete_settlement_by_token`, plus `get_trip_by_token` now returns expenses and settlements newest-first.
- Add/Edit Expense and the Settle Up "Undo" button are now wired end-to-end for guest trips.

## 2026-07-25 — Guest-mode trips wired to a live backend

- Migrations `0001`–`0006`: core schema (trips, trip members, expenses, expense splits, settlements, favorites), Row Level Security for authenticated access, the original guest RPC surface, collapsing separate edit/view tokens into one `share_token`, Bill Split's schema + RLS + guest API, and switching share tokens from base64 to hex (base64's `/` could break the `settlr.app/t/<token>` URL scheme).
- Wired guest trip creation, joining via link, adding/deleting expenses, and settle-up (mark paid / partial) to the real Supabase backend via `supabase-js`, replacing local-only mock state for these flows.
- Verified end-to-end against a real embedded Postgres (via `pglite`) before every push to the live project, and again live in a real browser against the deployed database — including a from-scratch session test (cleared local storage/IndexedDB, rejoined purely via share link) to confirm persistence wasn't just a same-browser-profile illusion.

## Earlier — Frontend prototype

- Built the onboarding flow (splash → guest/account mode choice → sign in/create account) and the guest-mode "start, join, or split a bill" hub, backed entirely by local mock state at this stage.
- Trip dashboard: mates, recent expenses, category stats, all-expenses view, and trip info/share-link screen.
- Add/Edit Expense with equal, percentage, and exact splits across multiple currencies, plus a live percentage-split preview.
- Settle Up: simplified debt suggestions, mark-paid-in-full or partial, and an undo history.
- Bill Split: a lighter one-receipt sibling to a full trip — per-item ownership, tax/service/GST/tip handled at the bill level, and a shareable settle-up breakdown exportable as a PNG.
- Revision pass: Edit Trip now reuses the Create Trip screen instead of a separate form; added a default-currency selector (separate from "which currencies are in play"); fixed a split-currency display bug; free-text (rather than slider-only) split inputs; a live running-total preview for percentage splits; confirmation dialogs before deleting a trip or bill split; and a fix for joined trips not persisting locally.
