# Changelog

All notable changes to Settlr, newest first. Dates reflect when each milestone was built.

## 2026-07-26 — Split validation, rate limiting, claim-to-account, bill tax defaults

- New migration `0009_expense_split_validation.sql`: `add_expense_by_token`/`update_expense_by_token` no longer trust the client's per-member `owed_amount` at face value. Equal and percentage splits are recomputed server-side; exact splits are validated to still add up to the expense total, rejecting ones that don't.
- New migration `0010_rate_limiting.sql`: every anon-facing guest RPC now rate-limits by caller IP (60 requests/5 min for the two bootstrap reads, 30/5 min for every mutation), closing out the last item on the backend's "still to do" list.
- New migration `0011_bill_tax_defaults.sql`: new bill splits default to Service Tax 10% / GST 9% instead of 0/0, covering both the guest RPC and the authenticated direct-insert creation path via a single column-default change.
- Wired the "Save to My Account" button (Trip Link / Bill Link screens) to the existing `claim_trip`/`claim_bill` RPCs — shown only when signed in and viewing a guest-created record, and removes the record from this device's local guest list once claimed.
- Backed up to `260726-v04` before this batch.

## 2026-07-26 — Require at least one mate, payer-initial bill icons

- Create Trip and Create Bill Split now block submission with an alert if no trip mate/person has been added, instead of silently creating the record anyway (trips) or falling back to a hidden "Alex" placeholder (bills).
- Bill Split cards (in both "Your Bills" and "Your Bills on This Device") and the Bill Split dashboard header now show a colored initial badge for whoever is set as the payer (e.g. "D" for Deniece) instead of the generic "$" mark — updates live if the payer is changed from the dashboard's dropdown. Trip cards/dashboards are unchanged and still show the "$" mark.

## 2026-07-26 — Landing page rework, Font Awesome icons, guest-list bug fix

- Removed the logo/"Get Started" splash screen entirely — "How do you want to continue?" is now the landing page, with its old "Next" eyebrow label and back button replaced by a plain "Settlr" label (nowhere to go back to anymore).
- Added a small persistent Settlr mark centered at the top of every screen (between Back, when present, and the light/dark toggle), implemented once at the shared nav-row level rather than duplicated per screen.
- Replaced every icon in the app (nav arrows, chevrons, category icons, plus/pen/trash, OAuth brand marks, theme toggle, etc.) with Font Awesome, loaded via CDN — the Settlr "$" brand mark is the only icon that's still custom.
- Create Trip / Create Bill Split now default to SGD instead of USD, and no longer pre-fill a sample trip/bill name or sample mates (Alex/Jordan/Priya) — both forms open empty and reset properly every time you navigate to them.
- Fixed a bug where a brand-new guest trip never got saved to this device's local list (bill creation already saved correctly; trip creation was missing the equivalent call), so it never showed up under "Your Trips on This Device" despite existing fine in Supabase.
- Renamed guest mode's "Your Bills" section to "Your Bills on This Device", matching the naming and empty-state phrasing of "Your Trips on This Device" above it.
- Added a bill-link info button to the Bill Split dashboard (mirroring the trip dashboard's info button), opening a new Bill Link screen with the shareable link and copy button.
- "Your Trips" and "Your Bills" on the account home screen no longer scroll independently in their own small boxes — both lists show everything, and the whole page scrolls instead.
- Backed up the pre-change app to `260726-v02` before making any of the above edits.

## 2026-07-26 — Google/Microsoft sign-in, forgot password, real website layout

- Wired the "Continue with Google" and "Continue with Microsoft" buttons to `sb.auth.signInWithOAuth`, reusing the existing session-restore logic (supabase-js parses the OAuth callback automatically on page load — no separate handling needed).
- Added a "Forgot your password?" link on the Sign In tab, wired to `sb.auth.resetPasswordForEmail`, plus a recovery-session handler that prompts for a new password and calls `sb.auth.updateUser` when the reset link is followed back into the app.
- Removed the phone-mockup chrome (fixed-size device border, rounded bezel, fake 9:41/signal/battery status bar) — the app now renders as a normal responsive website, capped at a comfortable reading width rather than floating as a fake phone frame on the page.
- Moved the app from `prototypes/settlr-onboarding-prototype.html` to `index.html` at the repo root, so GitHub Pages serves it directly at the site's base URL instead of falling back to a rendered README.
- Introduced a dated-backup convention (`YYMMDD-vNN` subfolders) — a snapshot of the app is taken before each editing session going forward, starting with `260726-v01`.

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
