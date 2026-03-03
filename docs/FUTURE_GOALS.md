# WaitTicket — Future Goals (High Complexity)

These features were explicitly deferred from MVP. Each entry includes recommended approach and trigger conditions.

---

## 1. Multilingual Support

**What:** Server speaks English; capture and handle non-English customer requests. Potentially localize the app UI for non-English-speaking staff.

**Approach:**
- `NLLanguageRecognizer` for on-device language detection (iOS 15+)
- `NLTranslator` for on-device translation (limited language pairs)
- Fallback: DeepL API or Google Translate API for broader coverage
- Localized menu data: add `name_translations: { "es": "...", "fr": "..." }` to `MenuItem`
- Server locale setting in Supabase profile (Phase 2)

**Dependencies:** Supabase backend, localized menu schema, translator API credentials

**Trigger:** First restaurant partner in a non-English-speaking market

---

## 2. POS Integration (Toast, Square, Clover)

**What:** Push confirmed ticket directly to the restaurant's POS system, eliminating manual re-entry.

**Approach:**
- Define `POSExportServiceProtocol` with `exportTicket(_ ticket: Ticket) async throws`
- Implement per-POS adapters:
  - Toast REST API (`/orders`)
  - Square Orders API
  - Clover Orders API
- Map `TicketV1` schema to each POS order format
- Restaurant provides API credentials, stored encrypted in Supabase

**Dependencies:** Supabase backend (for credential storage), POS API access, per-restaurant onboarding

**Trigger:** First restaurant partner explicitly requests it

---

## 3. Fraud / Void Analytics (Manager View)

**What:** Track voided items, comps, and anomaly patterns per server per shift. Provide a manager dashboard.

**Approach:**
- Add fields to `TicketItem`: `voidedAt: Date?`, `voidReason: String?`, `isComped: Bool`
- Add manager-role auth (Supabase RLS policy)
- Supabase aggregate queries: voids per server, comp rate, shift summary
- New `ManagerDashboardView` (iPad-optimized): shift overview, per-server stats, anomaly flags
- Export shift report as CSV/PDF

**Dependencies:** Supabase backend (Phase 2), manager auth role, void/comp UI in TicketEditor

**Trigger:** Restaurant requests manager reporting or notices unexplained inventory discrepancies

---

## 4. Training Mode (New Staff Validation)

**What:** Real-time coaching for new servers: validates order completeness, prompts for upsell attempts, confirms allergy protocol was followed.

**Approach:**
- `TrainingEvaluatorService` protocol with scoring rubric:
  - Did server attempt upsell? (check if upsell suggestion was shown + accepted/declined)
  - Was allergy confirmed? (check `allergyConfirmed` flag)
  - Were all required modifiers captured? (check items with `required: true` modifier groups)
- Training mode flag on server profile (Supabase)
- Overlay coaching tips during `LiveSessionView`
- Post-session report: score + specific feedback

**Dependencies:** Supabase backend (server profiles), upsell playbook (already implemented), allergy guardrail (already implemented)

**Trigger:** Restaurant requests onboarding tool for new staff

---

## 5. Table QR / NFC Auto-Select

**What:** Server scans QR code or taps NFC tag at the table to instantly select table number — eliminates manual entry.

**Approach:**
- QR: `AVFoundation` `AVCaptureMetadataOutput` for QR scanning within `TableSelectView`
- NFC: `CoreNFC` `NFCTagReaderSession` (requires `NFCReaderUsageDescription` entitlement)
- Payload format: `waitticket://table/{tableNumber}` deep link or plain text
- Restaurant provides QR stickers or NFC tags per table

**Dependencies:** `NFCReaderUsageDescription` entitlement (paid Apple Developer account required for NFC), restaurant prints/programs tags

**Trigger:** Restaurant wants sub-2-second table selection

---

## 6. Kitchen Display Mode

**What:** Second-screen view (iPad) showing live tickets with course pacing controls for kitchen staff, updated in real time.

**Approach:**
- iPad-optimized `KitchenDisplayView`: ticket grid sorted by opened_at, color-coded by course state
- Real-time updates via Supabase Realtime subscriptions
- Kitchen staff can mark items "ready" without access to full ticket editor
- Optionally show `time_since_sent` countdown per ticket

**Dependencies:** Supabase backend with Realtime enabled, iPad hardware, separate kitchen login

**Trigger:** Restaurant has a kitchen display screen and wants to eliminate paper dupe tickets

---

## 7. Printer Support (ESC/POS)

**What:** Print ticket to receipt printer (Star Micronics, Epson) over Bluetooth or Wi-Fi.

**Approach:**
- Star Micronics: Star SDK for iOS (StarIO framework)
- Epson: Epson ePOS SDK
- Format ticket items as ESC/POS commands: item name, qty, mods, seat, course
- Use `ticketAbbreviation` for compact print style
- Print triggered from `TicketEditorView` via toolbar button

**Dependencies:** Physical printer, vendor SDK integration, printer discovery (Bonjour/BLE)

**Trigger:** Restaurant requests paper ticket output for kitchen or customer receipt

---

## Implementation Priority (when the time comes)

| # | Feature | Effort | Impact |
|---|---------|--------|--------|
| 5 | QR/NFC table select | Low | High |
| 7 | Printer support | Medium | High |
| 2 | POS integration | High | Very High |
| 6 | Kitchen display | Medium | High |
| 3 | Fraud analytics | Medium | Medium |
| 4 | Training mode | Medium | Medium |
| 1 | Multilingual | High | Market-dependent |
