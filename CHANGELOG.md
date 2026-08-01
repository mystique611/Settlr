# Changelog

All notable changes to Settlr, newest first. Dates reflect when each milestone was built.

## 2026-08-01 — Shared bill items, item/expense notes, and "Add a Bill" inside a Trip

Showed a mockup of all three pieces (grouped item rows, the note field, and the new trip flow) before building, per the usual pattern. Backed up to `260801-v02` before this batch, including a full snapshot of the migrations folder given the scale of the schema changes.

- New migration `0019_notes_and_shared_items.sql`: adds `bill_items.note`/`split_group_id` and `expenses.note`; updates `add_bill_item_by_token`/`update_bill_item_by_token`/`add_expense_by_token`/`update_expense_by_token` with the new trailing params. Validated with pglite (8 checks): notes round-trip, grouped items share one `split_group_id`, "Duplicate Amount" items stay ungrouped.
- New migration `0020_trip_linked_bills.sql`: adds `bills.trip_id`/`linked_expense_id`, `expenses.linked_bill_id`, `bill_members.trip_member_id`; new `create_trip_bill_by_token()` (mirrors a trip's mates into a fresh bill's members) and `link_trip_bill_expense()`; `get_trip_by_token` now exposes the trip's own linked bills (with share tokens); `delete_bill_by_token` now cascades to the mirrored expense. Validated with pglite (12 checks).
- **Bill Split: items split equally across more than one person now show as a single row** — "Shared by Alex, Jordan, Priya" instead of one line per person — while still writing one `bill_items` row per person underneath (so every existing total/settle calculation needed zero changes). "Duplicate Amount" items (everyone ordered the same thing) are deliberately never grouped, since those really are separate items. Editing or deleting a shared row now acts on the whole group — growing, shrinking, or ungrouping a shared item reconciles against the previous group's rows in place rather than delete-and-recreate, so unaffected rows keep their position.
- **Optional note field** on Bill Split items (manual add and Scan Receipt review) and on trip expenses — shown as small italic text under the description/subtitle wherever that item appears (bill dashboard, trip expense list).
- **"Add a Bill" inside a Trip**: a new button below Add Expense opens a lightweight itemized bill scoped to the trip — its members come straight from the trip's own mates (no separate people-picker) and its currency is restricted to the trip's home/travel currencies. Once it has any items, its total is mirrored live into a normal trip expense (`split_type: 'exact'`, reusing `add_expense_by_token`/`update_expense_by_token` unchanged) — so Settle Up, balances, and CSV export never need to know an expense is bill-backed. The trip's expense list shows it as one collapsed row ("Bill · Paid by X"); tapping it opens the bill's own itemized dashboard with the full per-item and per-person breakdown, and Back returns to the trip.
- Verified the sync math with a standalone simulation (equal splits with odd cents, discount + exact tip, single-payer bills): rounding remainder always lands the split sum exactly on the mirrored expense total, matching what `_recompute_expense_splits`' 1-cent tolerance requires server-side.

## 2026-08-01 — Save as Image: label the payable amount as tax/GST-inclusive

- The "Payable to X" line in the Save as Image export now reads "Payable to Alex (incl. tax & GST)" — a smaller, lighter suffix drawn right after the bold name so it doesn't overlap regardless of name length.

## 2026-08-01 — Bill Split fixes: discount persistence, stable item order, Settle Up layout

- Showed a mockup of the dashboard item row (with the discount line) and the reordered Save as Image layout before building.
- New migration `0018_bill_item_discount_and_order.sql`: adds `bill_items.discount_pct`, and a `p_discount_pct` param on both `add_bill_item_by_token` and `update_bill_item_by_token`. Validated with pglite: the column round-trips through `get_bill_by_token`, and items keep their position after an in-place edit.
- **Discount % now persists.** Yesterday's discount feature applied the discount to the saved amount but never recorded the percent itself — reopening any discounted item (scanned or manually added) always showed 0%. Fixed at the root: the percent is now stored per item, and the Amount field reconstructs the pre-discount value on reopen (`amount / (1 - discount_pct / 100)`) so editing shows exactly what was typed in originally, not the discounted result.
- **Editing an item no longer moves it.** Two compounding bugs: `get_bill_by_token` had no `ORDER BY` on items at all, and every edit — even a simple rename — went through delete-then-recreate, which got the row a new id and pushed it to wherever an unordered read happened to put it. Fixed both: items now come back ordered by `created_at`, and editing calls `update_bill_item_by_token` to change the row in place. (Splitting one item into several people still has to add new rows for the extra people — no way around that — but the first person keeps the original row and position.)
- **Dashboard item rows now show the discount.** A small green "−$1.00 (10%)" line appears above the price whenever an item has a discount, so the value and the percent are both visible without opening Edit.
- **Save as Image leads with the payable summary.** "Payable to X" now draws right after the header, before the item list and breakdown, instead of at the very bottom — matches the mockup shown before building.
- Backed up to `260801-v02` before this batch.

## 2026-08-01 — Bill Split discounts (per-item and bill-level)

- Showed a mockup of both entry points (Add Item, scanned-receipt review, and the dashboard's tax section) before building, per the usual pattern.
- New migration `0017_bill_discount.sql`: adds `discount_mode`/`discount_percent`/`discount_exact` to `bills` — same percent-or-exact pattern as the existing tip fields — and updates `update_bill_settings_by_token` with three new params (its signature changed, so the old function is dropped before being recreated, same as `0014`). Validated with the pglite harness: defaults, both discount modes, the RLS lockout, and the `discount_mode` CHECK constraint all pass.
- **Per-item discount %** on the Add/Edit Item screen and the scanned-receipt review screen: a discount percent field with a live "$X − Y% = $Z to split" preview. Applied once, at save time — the discounted amount is what actually gets split and written, the same way an entered amount already gets divided into per-person pieces. No schema change needed for this one; editing an already-saved item later starts its discount back at 0%, since the discount's already baked into the amount shown. A 100% discount that would leave a $0 item is blocked (manual Add Item) or silently skipped with a note (scanned items, since a batch of several items shouldn't fail entirely over one).
- **Bill-level discount** in the "Discount, tax, service & tip" section: a percent-of-subtotal or exact-amount field, applied before service tax/GST/tip are calculated — regardless of whether item prices already include tax, since a discount is a separate concept from that. `computeBillTotalsFor()` now returns `discountAmt`/`netSubtotal` alongside the existing totals, and allocates the discount back per item proportionally (same ratio already used for tip) so each person's payable amount reflects their fair share.
- Settle Up's on-screen breakdown and the "Save as Image" PNG export both gained a green "Discount" line (only shown when a discount is actually applied) between Subtotal and the rest of the breakdown.
- Backed up to `260801-v01` before this batch.

## 2026-07-31 — Scan Receipt: allow uploading an existing photo, not just camera capture

- Dropped the `capture="environment"` attribute from the Scan Receipt file input. That attribute was forcing mobile browsers straight into the camera app, with no way to pick an existing photo from the library/files instead. Without it, tapping "Scan Receipt" now shows the phone's normal picker (camera **or** photo library **or** files, depending on OS/browser) — same input, same `handleScanReceiptFileSelected()` handler, no other logic changed.
- No redeploy needed beyond the usual GitHub Pages re-upload of `index.html` — this is a frontend-only change.

## 2026-07-31 — Receipt scanning: multi-model fallback + retry (live deploy troubleshooting)

- After deploying the OCR feature (previous entry), real scans kept failing in production. Live debugging via the Supabase dashboard logs traced it through three distinct causes in sequence: `gemini-2.5-flash` and `gemini-2.5-flash-lite` had both lost API access for new keys (Google cut the entire 2.5 generation off around 2026-07-09, ahead of an Oct 2026 shutdown); `gemini-2.0-flash` turned out to be fully shut down as of Google's current model docs (its errors showed a `limit: 0` free-tier quota, which in hindsight was the tell); and `gemini-3.5-flash`, while a valid current-generation model, hit transient 503 "high demand" errors under free-tier load.
- Rather than keep swapping the `GEMINI_MODEL` secret by hand every time Google's lineup shifts, `scan-receipt` now tries a short list of current stable models in order (`gemini-3.5-flash` → `gemini-3.5-flash-lite` → `gemini-3.1-flash-lite`), with one quick retry on a 503 before moving to the next model. `GEMINI_MODEL`, if set, is just tried first — it no longer needs to be the *only* model tried.
- Also fixed a frontend bug found during this troubleshooting: `sb.functions.invoke()` doesn't populate its error detail on non-2xx responses by default — the app was showing a generic "could not read that receipt" message even when the Edge Function returned a specific, useful error. It now reads the real message via `error.context.json()` and shows that instead.
- **Needs a redeploy to take effect**: `supabase functions deploy scan-receipt --project-ref qdrwjkeczyualpncrdin --use-api` (the code changed; the earlier `GEMINI_API_KEY`/`GEMINI_MODEL` secrets don't need to be touched again).

## 2026-07-30 — AI receipt scanning for Bill Split (Gemini OCR)

- New migration `0016_receipt_scan_rate_limit.sql`: a `receipt_scan_log` table (client IP + timestamp) with RLS enabled and no policies at all, so only the service role can touch it — backs a new per-IP rate limit that's separate from the existing `_check_rate_limit`/`_rpc_attempt_log` (`0010`), since this one guards an Edge Function calling out to a paid (if free-tier) third-party API, not a `.rpc()` call. Also adds `_prune_receipt_scan_log()` for cleanup.
- New Edge Function `scan-receipt` (`backend/supabase/functions/scan-receipt/index.ts`): takes a receipt photo from the browser, forwards it to Gemini's vision API with a prompt requesting strict JSON (line items + subtotal/tax/service/tip/total), and returns the parsed result. Rate-limited to 15 scans/hour per IP. Requires a `GEMINI_API_KEY` secret and `supabase functions deploy scan-receipt` — see the updated README for exact setup steps. Not exercised by the pglite harness or any sandboxed test (needs the real Deno runtime + a live Gemini call) — verify live after deploying.
- New "Scan Receipt" button on the Bill Split dashboard, next to Add Item. Photographing or uploading a receipt opens a new Review Scanned Items screen: each detected line shows an editable description/amount plus the same payable-by chips as manual entry (defaulting to everyone, since the AI has no way to know who actually shared what) — nothing is written to the bill until "Add items to bill" is tapped. Works in guest mode as well as signed-in accounts, since the scan never touches trip/bill data directly; it commits through the same `add_bill_item_by_token` RPC and equal-split math as the manual Add Item flow.
- Showed a mockup of the review screen (matching the app's existing dark-theme card/chip styling) for approval before building it, same pattern as the earlier currency-selector feature.
- Housekeeping note: `ARCHITECTURE.md` (added in the previous batch) had somehow ended up saved inside `.donotupload/` instead of the repo root — likely a sync timing issue right after it was first written. Recreated it at the correct root path before starting this batch; the stray copy in `.donotupload/` was left alone rather than deleted without asking.
- Backed up to `260730-v01` before this batch.

## 2026-07-27 — PWA installability, real app icons, list-card icon fix, housekeeping audit, ARCHITECTURE.md

- The app is now installable as a PWA: new `manifest.json` (name, theme colors matching the app's dark background, standalone display) and a minimal `sw.js` service worker that only caches the static shell (manifest + icons) — it deliberately never caches the page itself or any Supabase call, since every screen depends on live data. Registered from a small snippet right after the existing auth-state listener, guarded to only run over `http(s)://`.
- Real icons everywhere: rasterized `icon/Settlr.svg` (via ImageMagick) into `favicon-32.png`, `apple-touch-icon.png` (180×180), `icon-192.png`/`icon-512.png`, and safe-zone-padded `icon-192-maskable.png`/`icon-512-maskable.png` for Android's adaptive-icon mask. Wired into `<head>` as the favicon, apple-touch-icon, and manifest icon set — the browser tab and any installed PWA now show the real Settlr mark instead of a generic default.
- Fixed the "Your Trips"/"Your Bills" **list-card** icons (account and guest "on this device" lists) — these were still showing the old "$" mark and payer-initial badge; both now show the same plane/receipt icons already used on the dashboard headers and action rows. (This supersedes the payer-initial-on-bill-cards behavior from the 2026-07-26 "Require at least one mate" entry below — that concept is now fully removed.)
- Join a Trip's link field placeholder changed to "Paste your link here", replacing the old fake-token-shaped example text.
- Full codebase housekeeping audit (JS functions + SQL RPCs, cross-referenced against every call site including the one dynamically-computed RPC name for trip/bill delete): **no dead code found.** Two near-misses worth recording: `delete_trip_by_token`/`delete_bill_by_token` looked unused to a naive literal-string search but are called via a runtime-computed variable name; the hardcoded demo trip/bill seed data looks like leftover prototype content but is load-bearing — a script-parse-time statement depends on it existing before any real data loads, so removing it would crash the app on open. Neither was touched.
- Considered restricting trip/bill deletion to the creator (or claimed account). Discussed and explicitly declined — current behavior stays as-is: anyone holding a valid share link can delete, regardless of who created or claimed it.
- Added `ARCHITECTURE.md` — a reference doc (for your own use, not user-facing) covering the frontend structure, the full Supabase backend (schema, RLS, the guest-token RPC pattern, rate limiting, Storage), Brevo SMTP, Google/Azure OAuth, GitHub Pages hosting + the backup convention, and the PWA setup.
- Backed up to `260726-v08` before this batch.

## 2026-07-26 — Receipt photo uploads, "Start a New Trip" icon fix

- New migrations `0014_expense_receipts.sql` and `0015_receipt_storage_bucket.sql`: `add_expense_by_token`/`update_expense_by_token` can now record a receipt's Storage path, and a private `receipts` bucket (RLS: everyone can only touch their own user-id folder) backs it. `0015` isn't testable via the project's pglite harness (no `storage` schema in a bare embedded Postgres) — verify live after deploying.
- Add/Edit Expense's "Attach Receipt Photo" now opens a real file picker and uploads straight to Storage as soon as a photo's chosen, with a View/Remove row once one's attached. Authenticated only, matching the column's original "authenticated accounts only" design intent from `0001`. Expenses with a receipt get a paperclip icon in the expense list to reopen it.
- Fixed "Start a New Trip"'s row icon (guest screen and "Where to next?") — was still the generic `fa-plus` create icon; now the same plane mark used on the trip dashboard, matching "Split a Bill"'s receipt icon (which was already correct).
- Backed up to `260726-v07` — taken after this batch rather than before it: these landed as follow-up bug reports mid-session, on top of an edit session already in progress and already confirmed, rather than as a new request that should have paused for a fresh backup prompt first.

## 2026-07-26 — Real clickable share links, join/edit navigation fixes

- Trip and bill links are now real URLs built from wherever the app is actually hosted (`?t=<token>` / `?b=<token>`) instead of a cosmetic, non-functional "settlr.app/..." string. Opening one loads that trip/bill straight to its dashboard on boot — no more manually copying the token into "Join a Trip".
- Fixed `joinTripFromLink()`: joining a trip while signed in previously left it in a broken in-between state — not marked guest, but never actually claimed server-side, so it showed up in no list and had no "Save to My Account" button. It now correctly stays in guest state (visible under "Your Trips on This Device", with the claim button available) unless the trip is already owned by the signed-in user. The same logic now backs bill links too, via a new `openBillByToken()` (bills previously had no token-based join path at all).
- Fixed Back from Edit Trip / Edit Bill: it previously always exited to the account/guest list, even when you'd opened Edit from a specific trip or bill's own dashboard. It now returns to that same dashboard instead, and clears the editing-id state either way so a subsequent fresh "New Trip"/"New Bill" doesn't land back in edit mode.
- Join a Trip's link field no longer comes prefilled with a realistic-looking fake link — it starts empty with an instructional placeholder, and clears itself every time you return to the screen.
- Investigated "upload receipt not working": this isn't a regression — `attachReceipt()` has only ever been a placeholder (shows a "sign in first" note for guests, an explanatory alert for signed-in users), and receipt uploads to Supabase Storage remain the one documented, not-yet-built gap. Let me know if you'd like that built out next.
- Investigated "dashboard still showing wrong icon": the trip/bill dashboard markup already has the plane/receipt icons from earlier this session — if you're still seeing the old icon, the deployed GitHub Pages copy likely just hasn't been re-uploaded since that change.
- Backed up to `260726-v06` before this batch.

## 2026-07-26 — Token rotation, bill edit parity, currency search field, multi-select bill items, settle-up polish, auth flow cleanup

- New migration `0012_rotate_token_on_claim.sql`: `claim_trip`/`claim_bill` now regenerate `share_token` the moment a record is claimed into an account, so the old guest link stops working right away instead of staying live forever. The frontend swaps in the new token so the Trip Link / Bill Link screen keeps showing a working link.
- New migration `0013_bill_edit_parity.sql`: `update_bill_by_token` (rename + change currency) and `add_bill_member_by_token`/`update_bill_member_by_token`/`delete_bill_member_by_token`, giving bills the same edit-after-creation parity trips have had since `0008`.
- Create Trip's currency field is now a tag-style search box (type to filter, tap a result to add, tap a chip's ✕ to remove) instead of a plain dropdown that only ever showed one value at a time.
- Trip mate / bill person rows start with an empty avatar circle and fill in with the typed name's first letter live, instead of showing a placeholder letter that had nothing to do with the eventual name.
- Added an Edit Bill button (left of the info button) on the Bill Split dashboard — reuses the Create Bill Split screen with the title swapped to "Edit Bill", same pattern as Edit Trip.
- Bill Split's Add Item screen: "Payable by" is now a multi-select (tap to include/exclude, same row style as the trip Add Expense split editor), with a Split Equally / Duplicate Amount toggle above it. Split Equally divides the entered amount across everyone selected, each becoming their own line item in the bill overview; Duplicate Amount gives everyone the full amount instead. Editing an existing item that becomes several is handled as delete-then-recreate under the hood.
- Settle Up's item breakdown (on-screen and in the exported image) is now grouped by person with a subtotal, instead of one flat list.
- Save-as-image now hands off to the device's native share sheet (Save to Photos, etc.) when the browser supports sharing files, instead of always triggering a plain file download — falls back to download automatically where sharing isn't supported. The exported image is credited "Generated by Settlr" at the bottom.
- Already-signed-in visitors now land straight on the account dashboard instead of briefly seeing the landing page first; the dashboard's Back button was removed since Sign Out is the only way back to the landing page.
- Trip dashboard icon is now a plane mark; Bill Split dashboard icon is now a receipt mark (Bill Split's card icons elsewhere keep showing the payer's initial, unchanged).
- Page title changed from "Settlr — Onboarding Prototype" to "Settlr"; the small centered brand mark added to every screen's nav row earlier this session has been removed entirely, per instruction not to show the logo anywhere in the app.
- Fixed a latent bug (present since Edit Trip/Edit Bill's "reuse the create screen" pattern was introduced): starting a fresh new trip/bill right after backing out of an edit could land you back in edit mode for the previous record instead of a blank form — the "New Trip"/"New Bill" entry points now explicitly clear the editing-id state first.
- Backed up to `260726-v05` before this batch.

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
