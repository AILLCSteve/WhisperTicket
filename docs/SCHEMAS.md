# WhisperTicket Data Schemas

## MenuV1

The restaurant menu loaded from `MenuV1.sample.json` in the app bundle.

| Field | Type | Description |
|-------|------|-------------|
| restaurant_id | String | Unique restaurant identifier |
| version | Int | Schema version (currently 1) |
| currency | String | ISO 4217 currency code (e.g. "USD") |
| categories | [MenuCategory] | Top-level menu sections |
| upsell_rules | [UpsellRule] | Rule-based suggestion triggers |

### MenuItem
| Field | Type | Description |
|-------|------|-------------|
| id | String | Unique item ID |
| name | String | Display name |
| price | Double | Base price |
| tags | [String] | Dietary/category tags (e.g. "vegetarian", "gluten_free") |
| modifier_groups | [ModifierGroup] | Available modifications |
| kitchen_note_template | String? | Pre-filled kitchen note (e.g. "Temp: ___") |
| upsell_links | [UpsellLink] | Item-specific upsell suggestions |

### UpsellRule condition fields
| Field | Type | Meaning |
|-------|------|---------|
| has_entree | Bool? | true = entree present, false = entree absent |
| has_drink | Bool? | true = drink present, false = drink absent |

---

## TicketV1 (SwiftData)

Persisted via SwiftData. Syncs to Supabase in Phase 2.

### Ticket
| Field | Type | Description |
|-------|------|-------------|
| id | String | UUID |
| table_number | String | Table identifier |
| server_id | String | Server identifier |
| opened_at | Date | When ticket was created |
| sent_to_kitchen_at | Date? | When "Send to Kitchen" was tapped |
| delivered_at | Date? | When "Mark Delivered" was tapped |
| status | String | OPEN / SENT / DELIVERED / CLOSED |
| raw_transcript | String | Full speech transcript |
| course_pacing_states | [String: String] | CourseFlag.rawValue → CoursePacingState.rawValue |

### Timing metrics (derived)
- `time_to_send = sent_to_kitchen_at - opened_at`
- `time_to_deliver = delivered_at - sent_to_kitchen_at`

---

## TicketDraft (in-memory)

Intermediate parsing state. Not persisted until user confirms.

| Field | Type | Description |
|-------|------|-------------|
| tableNumber | String | Table being ordered for |
| items | [DraftItem] | Parsed items with confidence scores |
| rawTranscript | String | Current full transcript text |
| consumedCursor | Int | Character offset — parser only processes new text after this index |

### DraftItem confidence thresholds
- >= 0.7: Displayed normally
- < 0.7: Shows "Low confidence — verify" warning chip
- hasAllergyFlag = true: Red highlight, requires confirmation tap
