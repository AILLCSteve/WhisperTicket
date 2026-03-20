# Restaurant Server Workflow Research

_Research conducted March 2026. Informs the seat-first ordering architecture in WhisperTicket._

---

## 1. The Auction Problem

**Finding:** The single most reported friction point in restaurant service is food delivery without seat-level attribution — servers must ask the table "who had the chicken?" every time, causing guest discomfort and perceived incompetence.

**Industry term:** "The Auction" — food sits on the tray while the server polls guests.

**Implication for WhisperTicket:** Every item captured by voice must be stamped with a seat number _at the moment of capture_, not after the fact. The `DraftItem.seatNumber` field and the `activeSeatNumber` on `LiveSessionViewModel` exist precisely to prevent the auction problem.

**Codebase anchor:** `LiveSessionViewModel.activeSeatNumber` → stamps new items in `parsedDraft` after each transcription.

---

## 2. Pivot Point System

**Finding:** Fine dining and high-volume restaurants use a standardized "pivot point" seat numbering system. Seat 1 is defined as the chair closest to a fixed landmark (the kitchen door or a permanent fixture), and numbering proceeds clockwise around the table.

**Why it matters:** This is a transferable convention that experienced servers already know. WhisperTicket's seat chips can adopt this pattern to reduce onboarding friction for experienced staff.

**Current state:** WhisperTicket uses auto-numbered seats (1, 2, 3…). Servers can rename them to mnemonics ("Mom", "Blue shirt") at order time. The pivot point convention could be offered as a setup option in `FloorPlanEditorView` — generate seats in clockwise order from a designated pivot.

**Implication:** Low-complexity addition to `TableConfigSheet` — a "Use pivot point numbering" option that relabels seats 1–N clockwise from seat 1 at the top/kitchen side.

---

## 3. Person-by-Person Sweep

**Finding:** Experienced servers take the table person-by-person rather than category-by-category. They collect the full order from Seat 1 (apps, entree, drink, modifications), then move to Seat 2, etc. This:
- Minimizes re-engagement with each guest
- Reduces cognitive load on the server (one guest at a time)
- Creates natural pauses for voice capture per seat

**Implication for WhisperTicket:** The seat-first ordering workflow in `TableOrderEntryView` matches this pattern exactly. The seat chip strip is the UI manifestation of the person-by-person sweep. Servers tap a seat chip, record the full order for that guest, then advance to the next chip.

**Validated design decision:** The existing UX is correct. Do not change the chip-per-seat interaction model.

---

## 4. Modifier Parsing — The Hardest Technical Problem

**Finding:** Modifiers are the most linguistically complex part of restaurant orders. Servers use compressed natural language:
- "the salmon no butter sauce on the side"
- "burger medium well, no onion, extra pickles, cheddar"
- "she wants the pasta but gluten free if possible and no cream"

These chains include:
- Negations (`no`, `without`, `hold the`)
- Substitutions (`swap X for Y`, `instead of`)
- Quantity modifiers (`extra`, `light`, `double`)
- Uncertainty markers (`if possible`, `can you do`)
- Guest-specific allergy qualifiers (`she's allergic to`)

**Current state:** `FuzzyMenuOrderParser` handles basic modifier extraction but struggles with complex chains and negation-with-substitution patterns.

**Priority:** HIGH. This is the single feature that most determines whether servers trust the app's output.

**Next step:** Improve the parser or (when OpenAI integration lands) delegate modifier parsing to GPT-4o with a structured schema output.

---

## 5. Section Sizing in Real Restaurants

**Finding:** Server section sizing varies by venue type:
- **Fast casual / high-volume:** 4–6 tables per server
- **Full-service mid-market:** 3–5 tables per server
- **Fine dining:** 2–4 tables per server, with food runners

Sections are rarely perfectly rectangular — they account for:
- Table proximity (minimizes walking)
- Kitchen/bar access lanes
- High-traffic zones (near entrance, near restrooms)

**Implication for WhisperTicket:** `ServerSection` model supports arbitrary table assignment (not just rectangular blocks). The canvas drag editor lets managers carve out organic sections. This is the right model.

**Gap identified:** No server identity/login yet. Sections are defined but not filtered per server on `FloorView`. This means all servers see the entire floor. Adding a "My Section" toggle would immediately reduce cognitive noise for the server.

---

## 6. Competitive POS Friction Map

**Finding:** The major POS systems (Toast, Square for Restaurants, Clover, Aloha) share a common friction pattern: **item selection is category-browse or search, not voice**. The server must:
1. Navigate to the category
2. Scroll to find the item
3. Tap modifiers one by one from modifier lists
4. Repeat for each item

This process takes 30–90 seconds per guest at a table of 4 — meaning 2–6 minutes of screen-staring per table.

**WhisperTicket's differentiator:** Voice capture compresses this to a single 15–30 second recording per seat, with the server looking at the guest, not a screen.

**Risk:** Voice accuracy drops with:
- Background noise (loud restaurants, bars)
- Accents
- Non-standard menu names (creative naming like "The Weekend Warrior Burger")

**Mitigation already in place:** `noiseLevel` indicator in `TableOrderEntryView.transcriptSection`, allergy confirmation banners, manual item override button, editable seat items in `orderSummarySection`.

---

## 7. Voice Seat Switching (Phase 2 Opportunity)

**Finding:** Servers in table-for-many situations sometimes naturally say "for seat two, the salmon" — embedding seat attribution in their spoken order.

**Opportunity:** Parse seat references from the transcript ("seat 2", "for her", "she wants", "he'll have") to auto-advance the active seat chip without requiring the server to tap.

**Complexity:** Medium. Requires:
- A pre-parse pass in `FuzzyMenuOrderParser` or `LiveSessionViewModel` that detects seat indicators
- Mapping "she/he" to contextual seat (fragile without prior context)
- "seat N" / "for seat N" is reliable; pronoun resolution is not

**Recommendation:** Implement "seat N" / "table N seat N" detection first. Skip pronoun resolution until there's actual server feedback data.

---

## 8. Guest Count as Operational Signal

**Finding:** In restaurant operations, the number of covers (guests) at a table is a key signal used for:
- Kitchen pacing (fire timing)
- Inventory tracking
- Staff workload planning
- Tip splitting at checkout

**Current state:** `table.seats.count` captures this. `ActiveTableCard` displays it with 👤 icon.

**Gap:** Cover count isn't surfaced on the kitchen-facing `TicketEditorView`. When WhisperTicket adds kitchen display mode, the cover count should appear prominently.

---

## 9. Modifications vs. Allergen Flags — Different Risk Levels

**Finding:** Restaurants legally and operationally distinguish between:
- **Preference modifications** (hold the onions, dressing on the side) — low stakes, server discretion
- **Allergen restrictions** (no peanuts, celiac, shellfish allergy) — high stakes, kitchen must know

**Current state:** `DraftItem.hasAllergyFlag` and `AllergyAlertBanner` implement this distinction. Allergy items get a confirmation step.

**Gap:** Allergen items should propagate to the ticket with a visual indicator that survives into the kitchen view. Currently the flag exists on `DraftItem` but its visibility in `TicketEditorView` is not highlighted.

**Recommended addition:** A red pill/badge on allergy-flagged items in `TicketEditorView` so it's unmissable when a server reviews the ticket before sending.

---

## 10. Implications for OpenAI Integration (AI Fill Button)

**Finding:** The AI Fill button placeholder in `TableOrderEntryView` maps to a real workflow opportunity: given a partial transcript, infer the full structured order with modifiers, seat attribution, and course assignment.

**Recommended schema for the future OpenAI call:**
```json
{
  "items": [
    {
      "name": "string",
      "quantity": 1,
      "modifiers": ["string"],
      "negations": ["string"],
      "course": "appetizer|entree|beverage|dessert",
      "seat_number": 1,
      "has_allergy_flag": false
    }
  ]
}
```

**Integration point:** `LiveSessionViewModel.addManualItem(name:)` could be extended to accept a structured `DraftItem` from an OpenAI response, or a new `AIOrderParser` service implementing the existing `OrderParserProtocol` could slot in alongside `FuzzyMenuOrderParser`.

---

## Summary of Prioritized Findings

| Priority | Finding | Action |
|---|---|---|
| 🔴 HIGH | Modifier parsing is the core trust signal | Improve `FuzzyMenuOrderParser` or connect OpenAI |
| 🔴 HIGH | Allergy flags need visual persistence into ticket view | Add red badge to allergen items in `TicketEditorView` |
| 🟡 MEDIUM | No per-server section filtering on `FloorView` | Add server identity + "My Section" toggle |
| 🟡 MEDIUM | Voice seat switching ("seat 2, the salmon") | Parse seat indicators in transcript pre-pass |
| 🟢 LOW | Pivot point seat numbering option | Option in `TableConfigSheet` to relabel seats clockwise |
| 🟢 LOW | Cover count on kitchen-facing view | Add to future kitchen display mode |
