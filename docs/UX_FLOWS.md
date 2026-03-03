# WaitTicket UX Flows

## Primary Flow: Take an Order

```
1. Server opens app → Tables tab
2. Taps table number (preset grid or type custom)
3. LiveSession screen opens
4. Server holds mic button and speaks order aloud
5. Transcript populates in real time (top pane)
6. Ticket Draft populates automatically (bottom pane)
7. Server releases button
8. Upsell suggestions appear (e.g. "Would you like drinks?")
9. Server taps "Confirm" → Repeat-Back sheet shows summary
10. Server taps "Edit" → TicketEditor opens
11. Server reviews items, taps "Send to Kitchen"
12. Later: taps "Mark Delivered"
```

## Secondary Flow: Edit a Ticket

- Tap any item row to expand
- Tap "Edit Note" to add/change kitchen note
- "Move Seat" to reassign item to different seat
- "View Seat Map" for drag-and-drop seat assignment
- Course Pacing section: "Fire Apps" / "Hold Entrees"

## Allergy Flow (Low Complexity)

1. Parser detects allergy keyword in transcript
2. Red banner appears: "ALLERGY: [item name]"
3. Server must tap "Confirm" before proceeding
4. Item persists with red allergy flag in ticket

## Noise Warning (Low Complexity)

- Noise level bar visible while recording
- If ambient noise > 75% threshold: orange banner "Loud environment — speak clearly"
- Server can stop and restart recording

## Voice Macros (Medium Complexity)

- Detected automatically during transcription
- Blue banner: "Voice command: [Macro Name]"
- Tap "Apply" to execute or "Dismiss" to ignore

## Upsell Playbook (Medium Complexity)

- Upsell suggestion cards show restaurant's scripted line
- e.g. "Can I start you off with something to drink? We have a great local IPA on draft."
- Server taps "Add" to insert item into draft

## Seat Map (Medium Complexity)

- Accessed via "View Seat Map" button in Ticket Editor
- Drag item chips between seat cards
- Tap "+ Add Seat" to add a new seat
