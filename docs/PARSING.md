# WaitTicket Order Parsing

## Pipeline Overview

```
Raw transcript text
       ↓
1. Normalize (lowercase, strip fillers, number-word → digit)
       ↓
2. Split into segments (on commas, periods)
       ↓
3. For each segment:
   a. Detect course marker (e.g. "apps:", "entrees:")
   b. Detect seat marker (e.g. "seat 2")
   c. Fuzzy-match menu items (token overlap score ≥ 0.4)
   d. Extract quantity (leading digit or "two")
   e. Extract modifiers (temperature, negations, option names)
   f. Flag allergy keywords
       ↓
4. Add to TicketDraft (dedup by menuItemId + modifiers)
       ↓
5. Advance consumedCursor to prevent re-parsing
```

## Fuzzy Matching

Token overlap scoring:
- Normalize both strings (lowercase, remove punctuation)
- Filter tokens shorter than 3 chars
- Score = |intersection| / |query tokens|
- Threshold: 0.4 to add item, 0.5 for modifiers

## Known Limitations

- Single-language (English) only in MVP
- Relies on waiter repeating order clearly
- Temperature detection is phrase-based (check longer phrases first to avoid "medium" matching "medium rare")
- Seat detection requires explicit "seat N" phrasing
- Course detection requires explicit course keywords

## Voice Macros

| Phrase | Action |
|--------|--------|
| "repeat last order" / "same as last time" | Copy items from previous draft |
| "add side salad" / "side salad" | Auto-add Side Salad item |
| "split check" / "split the check" / "split bill" | Flag ticket for split |

## Demo Scenarios

**Scenario 1:**
> "Table twelve. Two burgers, one no onion add bacon, the other medium rare. One fries, one side salad. Two cokes."

Expected: 2x Classic Burger (one: No Onion + Add Bacon; one: Medium Rare), 1x French Fries, 1x Side Salad, 2x Coca-Cola

**Scenario 2:**
> "Table six. App: mozzarella sticks with ranch. Entrees: salmon no butter, steak medium, extra asparagus."

Expected: 1x Mozzarella Sticks (Ranch) [course: APP], 1x Grilled Salmon (No Butter) [course: ENT], 1x Ribeye Steak (Medium) [course: ENT]

**Scenario 3:**
> "Table three. She's gluten free — no croutons on the Caesar."

Expected: 1x Caesar Salad (No Croutons) [allergyFlag if "gluten free" detected]
