# HANDOFF — WaitTicket (2026-07-03, session 2)

## TL;DR
Three features landed on `main` this session:
1. **Confirm Order screen now has "Add from Menu"** (commit `80c5c75`).
2. **Menu import parser rewritten** — no more titles/fine-print/headings as
   items (same commit, CI green, on TestFlight).
3. **Visual overhaul** (commit `312873f`): zoom-to-table transition, seat
   swipe navigation, wall drawing in the floor editor. CI was in progress at
   handoff time — check `gh run watch 28689588375`.

## What to verify on device
1. **Confirm Order**: order something → Send → bottom bar has "Add from Menu"
   (opens searchable picker) and "Type Item". Adding keeps the sheet open and
   the item appears in the review list.
2. **Menu import**: Menu Admin → re-import the Applebee's PDF / any menu photo.
   Expect: real category names (Appetizers, Salads…), no "PRICE"/"FOOD ITEM"
   items, no title item, no fine-print items, no unselectable heading-items.
   Prices are best-effort FIFO pairing (source PDFs with scrambled column
   text can still drift a little — structure should always be right).
3. **Zoom transition** (iOS 18+ only): Floor map → tap a table → the tile
   itself zooms into the order screen; swipe down to fall back to the map.
   Works from the Tables list cards too, and into active tickets.
4. **Seat swipe**: on the order screen swipe left/right on the order area →
   moves between seats with a haptic.
5. **Walls**: Floor → Edit Map → Map tab → "Walls" tool → tap to place points
   (snaps to 20pt grid), Finish → wall appears; tap a wall → red highlight →
   Delete Wall. Walls show on the live floor map. Existing table positions
   must survive the update (walls decode is backward-compatible).

## Key implementation notes (session 2)
- `MenuTextParser.swift` — full rewrite. Algorithm + traps documented in
  `memory/debug_history.md` (2026-07-03 entry). Python mirror used for
  verification lives in the session scratchpad (parser_proto.py) — recreate
  from the debug-history notes if needed.
- `RepeatBackSheet` gained `menu:` + `onAddMenuItem:` optional params; both
  call sites (TableOrderEntryView, LiveSessionView) pass
  `services.menuStore.menu` and `vm.addMenuItem`. Adds NO LONGER dismiss the
  confirm sheet (intentional UX change).
- `FloorPlan` now has `walls: [FloorWall]` (polyline, canvas coords,
  thickness). Custom `init(from:)` uses decodeIfPresent — do NOT revert to
  synthesized Codable or every existing installation's floor plan wipes.
- `Views/Components/FloorChromeEffects.swift` (new): `tableZoomSource` /
  `tableZoomDestination` (iOS 18 `.navigationTransition(.zoom)` behind
  `#available`, no-op on 17), `ChromePressStyle`, `FloorWallsLayer`,
  `WallDraftLayer`. Zoom IDs are keyed by table NAME ("tile_<name>") so the
  order-entry and ticket-editor destinations can both match the same tile.
- Editor canvas is now 900x700 — SAME space as FloorMapEmbedView (old
  600x800 mismatch fixed). Live map offsets everything +40,+40; editor draws
  raw coordinates. Walls are stored in the shared (raw) space.
- Build 58 items (menu picker, disambiguation, record-then-transcribe ASR)
  unchanged — see previous HANDOFF content in git history (`850f678`).

## Environment facts (unchanged)
- PAID Apple Developer (team M37X5J35F8), app com.whisperticket.app.
- Windows dev box → CI (GitHub Actions macOS) is the only build verification.
- Workflow: commit → push main → `gh run watch <id>` → green auto-uploads to
  TestFlight (internal group "Dev1", auto-distribute).
- iOS deployment target 17.0; zoom transition requires iOS 18+ at runtime.
