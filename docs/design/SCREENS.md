# MacroSIP screens

Text specification of the user interface, derived from the approved mockups in `mockups.html` and the decisions in ADR 0009. This is the primary input for the SwiftUI implementation. Where this file and the mockup differ, the decision in ADR 0009 wins; where the mockup is silent, the item is listed under **Open items**.

Vocabulary follows `docs/GLOSSARY.md` (account, registration, call, active call, held call, remote party, DTMF, blind transfer, attended transfer, conference, presence, DND, auto-answer, recording).

## How to read this document

- **`[Full]`** marks anything that exists only in the Full edition. A `[Full]` row, line, menu item, string, pane or tab is absent in Lite. Lite ships first: skip every line tagged `[Full]`. Full-only code lives under `#if FULL`.
- **`[v2]`** marks anything the notes defer beyond Full or beyond v1. These are not to be built now.
- Unmarked elements exist in both editions.
- Sizes are in points (pt) and are approximate unless stated. The main window is 340 pt wide and 520 pt tall and never grows.
- Element types use SwiftUI or AppKit names: button, text field, popup (pop-up button), segmented control, toggle (switch), checkbox, list, table, slider, stepper, label, image, menu.
- "Default button" means the button triggered by Return in a sheet or popover.
- Strings are referenced by key in the **Strings** section at the end.

## Common main-window frame

Used by screens 1 to 5 and 10. Window width 340 pt, height 520 pt, fixed.

### Layout (top to bottom)

| # | Element | Size (approx.) |
|---|---|---|
| 1 | Title bar with standard traffic lights. Title centred. | 30 pt high |
| 2 | Number row: outgoing account popup, then number field | 46 pt high, 10 pt side padding |
| 3 | Tab control (segmented, three segments) | 36 pt high incl. padding |
| 4 | Tab body | fills the rest; 392 pt in call states |
| 5 | Status bar | 26 pt high, full width |

### Title

| Edition | Title text |
|---|---|
| Lite | "MacroSIP Lite" (`main.title.lite`) |
| Full | "MacroSIP" (`main.title.full`) |

### Number row

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Outgoing account popup | popup | Shows the short account name ("Office") and a status dot for that account's registration. Max width 112 pt; name truncates with an ellipsis. Selecting an item sets the outgoing account for this call only. The initial value is the account marked "Default for outgoing calls" (see 9). Tooltip: `main.accountPicker.help`. | Disabled when there are no accounts (shows "No account", grey dot, dimmed). |
| Number field | text field, 17 pt, min height 30 pt | Accepts typed digits, letters, `+`, `*`, `#`, spaces, dashes, and pasted `sip:` or `tel:` URIs. Placeholder "Name or number". Keeps focus whenever the window is key. Return places the call (see screen 1). Letters open a suggestions dropdown (see screen 1). | Disabled when there are no accounts (dimmed). Stays enabled during a call. |

Status dot mapping for the account popup, status bar and Accounts table:

| Registration (glossary) | Dot | Text in status bar |
|---|---|---|
| `registered` | green | account name |
| `registering` | orange (not drawn in mockup; see Open items) | account name |
| `failed(reason)` | red | account name + ": " + short reason, in red |
| `unregistered` with Register off (disabled) | grey, hollow | account name, grey |

### Tab control

| Element | Type | Behaviour |
|---|---|---|
| Tabs | segmented control, 3 segments: Dialpad, Contacts, Call Log | Selects the tab body. Keeps state when switched. |
| Call Log badge | red count pill inside the third segment | Shows the number of unseen missed calls. Hidden when zero. Cleared when the Call Log tab is opened. |

Tabs are always enabled, including with no accounts.

### Status bar

| Element | Type | Behaviour |
|---|---|---|
| One item per enabled account, in account order (see 8.2) | label with dot | Click opens Settings at Accounts with that account selected. Shows the short reason for a failed account in red. |
| Empty state text | label | "No accounts" with a grey hollow dot when no accounts exist (screen 10). |

The status bar is one line; items truncate without wrapping. The mockups show at most three items. Overflow behaviour is an Open item.

### Keyboard (frame)

| Key | Action |
|---|---|
| Command-, | Opens Settings (`menu.settings`). |
| Command-F | Contacts tab: focuses the search field. |
| Command-1 / 2 / 3 | Not in the mockups; not specified. See Open items. |

---

## 1. Dialpad

Screen 01. Main window, Dialpad tab, idle, typing a number.

### Layout

| # | Element | Notes |
|---|---|---|
| 1 | Common frame (title, number row, tabs, status bar) | See above. |
| 2 | Keypad grid | 3 columns by 4 rows, 9 pt gap. Key height 50 pt, corner radius 12 pt. |
| 3 | Action row | Three equal columns: empty (left), Call button (centre), Delete button (right). |
| 4 | Hint line | 11 pt, centred, under the action row. |

### Elements

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Keys 1 to 9, `*`, 0, `#` | button (12 keys) | Appends the key to the number field. Each key shows its letters beneath the digit (2 ABC, 3 DEF, 4 GHI, 5 JKL, 6 MNO, 7 PQRS, 8 TUV, 9 WXYZ, 0 `+`; 1, `*`, `#` have none). Long-press on 0 inserts `+` instead of 0. | Enabled. |
| Call button | circular button, 58 pt, green, handset glyph | Places a call to the number field, normalised (see Behaviour below). With an empty field, redials the last number. | Disabled when the field is empty and there is no last number. |
| Delete button | circular ghost button, 36 pt, backspace glyph; accessibility label "Delete last digit" | Deletes the last character in the number field. Single click per character. | Disabled when the field is empty. |
| Hint line | label | Static text (`dialpad.hint`). | n/a |
| Number field | text field (see Common frame) | Typed letters open the contact suggestions dropdown below the field [decided Q1.1]. | Enabled. |

**Behaviour, number handling:**

- A `sip:` or `tel:` URI, or a number with spaces or dashes, is accepted when pasted or typed. The dial string is normalised when the call is placed, and resolved to a SIP URI through the outgoing account's domain (glossary: dial string).
- Return on the number field places the call, same as the Call button.
- Empty field and Call redials the last number dialled [decided Q1.2].
- Suggestions dropdown: appears under the field while the field contains letters; lists matching contacts by name; choosing one fills the field with that contact's number and the account preference applies. Behaviour of the dropdown is decided but not drawn; see Open items for the visual detail.

### States

| State | Appearance |
|---|---|
| Idle, empty | Field shows placeholder "Name or number". Call button disabled if no last number. Delete disabled. |
| Idle, typing | Field shows the typed value with a blue focus ring (3 pt tint plus 1 pt accent). Delete enabled. |
| Idle, letters typed | Suggestions dropdown below the field. |
| During a call | Dialpad tab body becomes the call panel (screen 4). Keypad and field remain live; see screen 5 for a second call. |
| No accounts | Number field and account popup disabled (dimmed). Keypad is still visible, but Call is disabled; the body is replaced by the first-launch empty state (screen 10). |

### Keyboard

| Key | Action |
|---|---|
| Digits 0 to 9, `*`, `#`, `+` | Typed into the number field. |
| Letters | Typed into the field; opens suggestions. |
| Delete (backspace) | Deletes the last character. |
| Return | Places the call (or, during a call, starts a second call and holds the first; see screen 5). |
| Escape | Not specified in the mockups; see Open items. |

### Decided

- Letters typed in the number field show contact suggestions in a dropdown under the field (Q1.1).
- Empty field + Call redials the last number (Q1.2).

---

## 2. Contacts

Screen 02. Main window, Contacts tab, right-click context menu open on a row. Includes the Edit Contact sheet.

### Layout

| # | Element | Notes |
|---|---|---|
| 1 | Common frame | Number field shows "Name or number" placeholder. |
| 2 | Search row | Full width, 8 pt padding, bottom hairline. |
| 3 | Contact list | Grouped by first letter of the name. Section header 11 pt semibold. Row height about 44 pt. Scrolls. |
| 4 | Bottom bar | 26 pt high: Add, Delete, Edit icon buttons (26 by 22 pt each), right-aligned count text. |

### Elements

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Search field | search field, placeholder "Search" | Filters the list by name and number as you type. Command-F focuses it. | Enabled. |
| Section header | label | Letter of the first name character, or "#" for numbers and URIs without a name (proposed; not drawn). | n/a |
| Contact row | list row | Avatar (32 pt circle, initials, colour per contact), name (13 pt, medium), second line number or SIP URI (11.5 pt, secondary). Double-click places a call. Selected row: blue background, white text. | Enabled. |
| Row call button | circular button, 24 pt, green handset | Visible on hover; permanently visible on the selected row. Places a call to the contact. | Enabled. |
| Presence dot `[Full]` | dot, 11 pt, overlaid on avatar bottom-right | Green available, yellow away, red busy or DND, grey offline or unknown. | Read-only. |
| Presence text `[Full]` | label, 11 pt, right of the row | "Available" or "Away" (other values: see Strings). Shown only for contacts with presence watched. | Read-only. |
| Add contact (+) | icon button | Opens the Contact sheet, empty. | Enabled. |
| Delete contact (−) | icon button | Starts the inline delete confirmation for the selected row. | Disabled when no row is selected. |
| Edit contact (pencil) | icon button | Opens the Contact sheet for the selected row. | Disabled when no row is selected. |
| Count label | label | "N contacts" (`contacts.count`). | n/a |

**Context menu** (opened by right-click on a row; the row gets a 2 pt blue inset outline):

| Item | Type | Behaviour | Shortcut |
|---|---|---|---|
| Call | menu item, highlighted in mockup | Places a call through the contact's preferred account, or the outgoing account if "Any". | Return |
| Call from ▸ | submenu | Lists enabled accounts; choosing one places the call through that account. Submenu contents are not drawn (see Open items). | none |
| Copy Number | menu item | Copies the number or URI to the pasteboard. | Command-C |
| separator | | | |
| Edit… | menu item | Opens the Contact sheet. | Command-E |
| Watch Presence `[Full]` | checkmark menu item | Toggles the contact's presence subscription. Checkmark when on. | none |
| separator | | | |
| Delete | destructive menu item, red | Starts the inline confirmation in the row. | Command-Delete |

**Inline delete confirmation:** the row is replaced in place by a confirmation strip. Text "Delete %@?" with the contact name. Buttons: Delete (destructive, default) and Cancel (Escape also cancels).

**Edit Contact sheet** (320 pt wide, attached to the main window):

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Title | label, 13 pt bold | "Edit Contact" (`contact.edit.title`). "New Contact" for Add (`contact.new.title`, proposed). | n/a |
| Name | text field | Required. Free text. | Enabled. |
| Number | text field | Required. Number or SIP URI. Normalised as on the dialpad. | Enabled. |
| Account | popup | "Any (use default)" plus each enabled account. Stored as the contact's preferred account [decided Q2.2]. | Enabled. |
| Watch presence (subscribe) `[Full]` | checkbox with label | Subscribes to presence for the contact. Default state for new contacts: see Open items. | Enabled. |
| Cancel | button | Closes without saving. Escape. | Enabled. |
| Save | button, default (accent) | Validates Name and Number (both non-empty); saves; closes. | Disabled until Name and Number are non-empty. |

### States

| State | Appearance |
|---|---|
| Empty (no contacts) | List area shows the empty message (`contacts.empty.title`, `contacts.empty.body`, proposed; not drawn). Count reads "0 contacts". Add enabled; Edit and Delete disabled. |
| Loaded | As mockup. |
| Search with no match | Empty list with `contacts.search.noResults` (proposed). |
| Row selected | Blue row, white text, call button visible. |
| Hover | Row background subtle; call button shown. |
| During a call | A summary bar appears above the search row (see screen 4, Contacts tab). |
| Inline delete | Row shows the confirmation strip. |
| Lite vs Full | Lite: no presence dot, no presence text, no Watch Presence item, no Watch presence checkbox in the sheet. Full: all four present. |

### Keyboard

| Key | Action |
|---|---|
| Return | Calls the selected contact. |
| Double-click | Calls the selected contact. |
| Command-F | Focuses the search field. |
| Command-E | Opens Edit for the selected contact. |
| Command-C | Copies the selected contact's number. |
| Command-Delete | Starts inline delete. |
| Up / Down | Moves the selection. |
| Escape (in search) | Not specified; see Open items. |
| Return (in Edit sheet) | Default button: Save, when enabled. |
| Escape (in Edit sheet) | Cancel. |

### Decided

- No import from macOS Contacts in v1 (Q2.1).
- Per-contact preferred account stays (Q2.2).
- Full: presence is subscribed per contact, through "Watch presence" in the sheet and the context menu (note on screen).

---

## 3. Call Log

Screen 03. Main window, Call Log tab, two missed calls unseen. Includes the Clear confirmation.

### Layout

| # | Element | Notes |
|---|---|---|
| 1 | Common frame | Call Log segment shows the badge (2). |
| 2 | Tool row | 8 pt padding, bottom hairline: All/Missed segmented control on the left, Clear button pushed right. |
| 3 | Log list | Date-section headers and rows. Scrolls. Row height about 44 pt. Keeps the last 1,000 entries [decided Q3.1]. |

### Elements

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| All / Missed | segmented control, 2 segments | All shows every entry. Missed shows only missed entries; date headers without missed entries are hidden; the "Today" header remains only when it has a missed entry. Switching does not clear the badge. | Enabled. |
| Clear… | button, small | Opens the confirmation alert (below). | Disabled when the log is empty. |
| Section header | label, 11 pt semibold | "Today", "Yesterday", then dates such as "Mon, 6 Oct" (system short date). | n/a |
| Call row | list row | Direction icon (see below), remote party name (bold), second line: number or URI, then "·", then the account tag (10 pt, grey chip). Right column: time (11.5 pt, tabular digits) above duration `m:ss`, or the word "missed" for missed calls. | Enabled. |
| Row, missed | list row | Icon and name in red; right column shows "missed" in place of duration. | Enabled. |
| Row, unknown remote party | list row | Name replaced by the number, second line "Unknown · account". | Enabled. |

**Direction icons:** incoming (answered): arrow into a corner, secondary colour. Outgoing: arrow out, secondary. Missed: red arrow dipping down, red name.

**Row double-click or Return:** calls back using the account the original call came in on (not the current outgoing account).

**Row context menu:**

| Item | Behaviour |
|---|---|
| Call | Calls back through the same account as the entry. |
| Call from ▸ | Submenu of enabled accounts. |
| Add to Contacts | Opens the Contact sheet prefilled with name and number. |
| Copy Number | Copies the number or URI. |
| Delete Entry | Removes this entry without confirmation. |

**Clear confirmation** (alert sheet, 300 pt wide, app icon at top; mockup labels it "inline confirm" but the notes call it an alert; see Open items):

| Element | Behaviour |
|---|---|
| Title "Clear the call log?" | Static. |
| Body "All %lld entries are removed." `[Full]` adds "Recordings stay in their folder." | Count is the number of entries. |
| Cancel | Closes; keeps the log. |
| Clear (destructive, red) | Deletes all entries. Escape cancels. |

### States

| State | Appearance |
|---|---|
| Empty | No rows. Message `calllog.empty.title` and `calllog.empty.body` (proposed; not drawn). Clear disabled. All/Missed still shown. |
| Empty, Missed filter | Message `calllog.empty.missed` (proposed). |
| Missed badge present | Call Log segment shows the count; Dock and menu bar show the same count. |
| Opened with unseen missed | Opening the tab marks them seen; badges clear (Dock, menu bar, tab). |
| During a call | Summary bar above the tool row (see screen 5). |
| Lite vs Full | Full: the Clear alert adds the recordings sentence. Recording play button is deferred `[v2]` (Q3.2); not drawn; do not build. |

### Keyboard

| Key | Action |
|---|---|
| Return | Calls back the selected entry. |
| Double-click | Calls back the selected entry. |
| Delete (backspace) | Not specified; see Open items. |
| Escape in Clear alert | Cancel. |
| Return in Clear alert | Not specified (Clear is the destructive button, so Return must not default to it). |

### Decided

- Call log keeps the last 1,000 entries (Q3.1).
- Recording play button is Full, later (Q3.2) `[v2]`.

---

## 4. Active call

Screen 04. Same window, same size. The Dialpad tab body becomes the call panel. Four mockup states: connected call (muted), keypad, Contacts tab during a call, transfer popover.

### 4.1 Connected call (Dialpad tab)

Body height 392 pt, flexible content, centred column.

| # | Element | Notes |
|---|---|---|
| 1 | Avatar, 48 pt circle, initials | Colour per contact or a neutral default. |
| 2 | Name, 17 pt semibold | Remote party display name. If none, the URI user part. |
| 3 | Number, 12 pt, secondary | Remote party number or URI. |
| 4 | Timer, 22 pt light, tabular digits | Call duration `mm:ss`; `h:mm:ss` after one hour (proposed). |
| 5 | State label, 11 pt, green, medium | "Connected" (`call.state.connected`). |
| 6 | Chip row, centred, wrapping | See chips below. |
| 7 | Control grid | 4 columns in Lite; 3 columns in Full. Gap 10 pt (rows) and 4 pt (columns). Pushed to the bottom of the body (`margin-top: auto`). |
| 8 | End Call button | Full width, 30 pt high, red, corner radius 8 pt, white label with hang-up glyph. Pinned at the bottom. |

**Chips:**

| Chip | Content | Behaviour |
|---|---|---|
| Account | "via %@" with account short name | Read-only. |
| Quality | codec name and sample rate ("Opus 48 kHz") plus 3-of-4 signal bars | Bars from RTCP loss and jitter. Hover shows the numbers (exact format not drawn; see Open items). |
| SRTP | lock glyph and "SRTP" | Shown when media is encrypted. Tooltip "Media encrypted with SRTP". Hidden when the call is unencrypted. |
| REC `[Full]` | red pill, white text, white dot, "REC %@" with the elapsed recording time | Shown while recording. |

**Control grid buttons** (icon in a 38 pt circle, label below, 10.5 pt):

| Button | Type | Behaviour | Enabled / disabled | Edition |
|---|---|---|---|---|
| Mute | toggle | Toggles the microphone for the active call. When on: circle filled with the inverse label colour and a mic-off glyph; label stays "Mute". | Enabled. | Both |
| Hold | button | Holds the active call. Hold state: see Open items. | Enabled. | Both |
| Transfer | button | Opens the transfer popover (below). | Enabled when there is a call to transfer. | Both |
| Keypad | button | Swaps the panel for the DTMF keypad (4.2). | Enabled. | Both |
| Record `[Full]` | toggle | Starts or stops recording of the active call. Circle red when on. | Enabled. | Full |
| Merge `[Full]` | button | Joins all connected calls into a local conference (screen 5). | Disabled with one call; enabled when a second call is connected. | Full |

**End Call:** ends the active call (Command-D). With two calls the button label is "End Call with %@" (screen 5).

**Transfer popover** (270 pt wide, anchored to the Transfer button, arrow pointing at the button):

| Element | Type | Behaviour |
|---|---|---|
| Title | label, 13 pt bold | "Transfer %@ to" with the remote party name (`transfer.title`). |
| Target field | text field, focused on open | Typing filters suggestions. Accepts a number, URI or a name. |
| Suggestions | list, 2 rows visible in mockup | Matching contacts and their numbers. Highlighted first row. Choosing a row fills the target. |
| Call First | button (attended) | Holds the current call and calls the target. Completion is via the banner in screen 5. Tooltip "Attended: call %@ first, then complete". |
| Transfer Now | button, default (accent) | Blind transfer: REFER the current call to the target immediately. Tooltip "Blind: hand the call over now". |
| Explanation | label, 11 pt, secondary | "Transfer Now hands the call over immediately. Call First lets you talk to %@ before you complete the transfer." |

Call First and Transfer Now are disabled until the target field is non-empty.

**Sizes:** the popover's contents are about 270 by 200 pt.

### 4.2 Keypad (DTMF)

Body height 392 pt. Replaces the call panel content; the window is otherwise the same.

| Element | Type | Behaviour |
|---|---|---|
| Back to call | link-style button with a left chevron, blue | Returns to the call panel (4.1). |
| Remote party and timer | label, 12 pt, right-aligned: name bold, then timer | Read-only. |
| Sent digits | label, 20 pt monospaced, letter spacing 0.25 em | Echoes each DTMF digit sent. Clears when the keypad closes (proposed). |
| DTMF grid | 3 by 4 buttons, 38 pt high, 18 pt label | 1 2 3 / 4 5 6 / 7 8 9 / * 0 #. A pressed key shows a pressed fill. |
| End Call | as 4.1 | Ends the call. |

Keypad digits are sent as DTMF (RFC 2833 preferred, SIP INFO fallback). Digit keys on the keyboard send DTMF while the main window is key.

### 4.3 Contacts or Call Log tab during a call

The call panel is not shown on these tabs. A one-line summary bar sits at the top of the tab body, above the search row or tool row.

| Element | Type | Behaviour |
|---|---|---|
| Summary bar | button-like row, light blue tint, 26 pt high | Click returns to the Dialpad tab (call panel). |
| Live dot | 7 pt green dot with a soft ring | Shown while connected. |
| Remote party name | label, bold, truncates | Read-only. |
| Timer | label, tabular digits, secondary | Call duration. |
| Muted icon | red mic-off glyph | Shown only when muted. Tooltip "Muted". |
| REC chip `[Full]` | small red pill, "REC" | Shown while recording. |
| End | red circle, 22 pt, hang-up glyph | Ends the active call. |

The summary bar shows "+N on hold" in orange when other calls are held (screen 5). Contacts and Call Log remain fully usable during a call.

### 4.4 Transfer completing (attended)

Covered in screen 5 (banner).

### States (screen 4 summary)

| State | Appearance |
|---|---|
| Ringing outbound (`outgoing`, `early`) | State label "Calling…" or "Ringing…" (not drawn; see Strings, proposed). Timer shows 00:00 and counts once connected. End Call available. Controls disabled except End Call (proposed). |
| Connected | As 4.1. |
| Muted | Mute control filled; muted icon in the summary bar. |
| Held (only call) | Hold control shows held state (see Open items). Timer continues. |
| Keypad | 4.2. |
| Contacts tab | 4.3. |
| Microphone access denied | Call panel shows "Microphone access is off" and a button "Open System Settings" (from the first-launch notes; not drawn; see Strings). |
| Lite vs Full | Lite: 4 control buttons, no REC chip, no Record, no Merge. Full: 6 control buttons (3 columns), REC chip. |

### Keyboard (screen 4)

| Key | Action |
|---|---|
| Return (number field) | Places a second call and holds the current one (screen 5). |
| Command-D | End the active call. |
| Command-Shift-M | Toggle mute while MacroSIP is frontmost. |
| Digits (keypad state) | Send DTMF while the main window is key. |
| Return / Escape in transfer popover | Return triggers the default button (Transfer Now). Escape closes the popover. |
| (scope note) | The two shortcuts above apply only while MacroSIP is frontmost. Global hotkeys are not in v1 [decided Q4.3]. |

### Decided

- The window does not grow; the call panel replaces the dialpad area (Q4.1).
- No volume or mic level controls in the call panel (Q4.2).
- No global hotkeys in v1 (Q4.3).
- Main window stays 340 by 520 during a call; Keypad swaps in a DTMF keypad; other tabs show a compact summary bar (ADR 0009).

---

## 5. Several calls

Screen 05. Up to four simultaneous calls. Exactly one is active; the others are held. Four mockup states: two calls on the Dialpad tab, Call Log summary bar, attended transfer in progress, and (Full) local conference.

### 5.1 Two calls (Dialpad tab)

Body height 392 pt.

| Element | Type | Behaviour |
|---|---|---|
| Heading row | label, 11 pt, secondary, semibold | "%lld calls" (uppercase in the mockup), left; "Click a row to switch", right. |
| Call rows | list of 2 rows (one per call, up to 4) | See row anatomy below. Click a held row: it becomes active and the current one is held. |
| Control grid | as 4.1 | Acts on the active call. |
| End Call with name | End Call button | Ends the active call. Label "End Call with %@" (the active call's remote party). |

**Call row anatomy:** avatar 26 pt; name (12.5 pt, semibold); second line (11 pt):

| Row state | Second line | Right side | Background |
|---|---|---|---|
| Active | "Active · %@" in blue (duration) | Codec chip with bars (Lite and Full) and a red mini end button | Blue tint |
| Held | "On hold · %@" in orange | "Resume" small button (play glyph) and red mini end button | none |
| Consulting (attended transfer) | "Consulting · %@" in blue | red mini end button | Blue tint |
| In conference `[Full]` | "In conference" | "Split" small button and red mini end button | blue tint |

Each row's mini end button (22 pt red circle, hang-up glyph) ends that call only.

**Limits:** a fifth call is rejected with SIP 486 Busy Here. The UI message for this case is not drawn; see Open items.

**Second call behaviour:** typing a number and pressing Return during a call places a second call and holds the first. The first call moves to the held state and its row appears. This behaviour was added by the designer and accepted by the orchestrator; it is not drawn in the mockup beyond the two-row state.

### 5.2 Call Log tab with a call and held calls

Summary bar (as 4.3) with the active call's name and timer, and "+1 on hold" in orange in place of the bar's muted icon. The list and the tool row sit below, as on screen 3.

### 5.3 Attended transfer in progress

Shown inside the call panel (Dialpad tab) as a state. Panel width 320 pt in the mockup.

| Element | Behaviour |
|---|---|
| Row 1: the consulting call (active) | "Boris Ivanov", "Consulting · 00:21", red mini end. |
| Row 2: the held original call | "Anna Petrova", "On hold · waiting for transfer". |
| Banner | Title "Transfer Anna Petrova to Boris Ivanov?" (bold); body "Anna and Boris will be connected and you leave both calls." |
| Cancel (small) | Cancels the transfer. Returns to the two calls with the original call active again (proposed; see Open items). |
| Complete Transfer (small, default, accent) | Completes the attended transfer (REFER with Replaces). Both remote parties are connected; the local call leg ends. |

### 5.4 Conference `[Full]`

Panel 320 pt wide.

| Element | Behaviour |
|---|---|
| Header | "CONFERENCE · %lld PARTICIPANTS" on the left; conference timer (tabular) on the right. |
| Participant rows | Each with avatar, name, "In conference", "Split" small button, red mini end. |
| Split | Takes that participant out of the conference as a held call. |
| mini end on a participant | Ends that leg. |
| End Conference | Full-width red button. Ends every leg. |

Merge (in 4.1) mixes all connected calls on this Mac (PJSIP conference bridge; not a server-side conference).

### States (screen 5)

| State | Appearance |
|---|---|
| One call | Screen 4. |
| Two calls, one held | 5.1. |
| Four calls | Row list shows four rows; the panel has no room for more. Exact layout at four rows: see Open items. |
| Attended transfer | 5.3. |
| Conference `[Full]` | 5.4. |
| Merge disabled (one call) `[Full]` | Merge button dimmed. |

### Keyboard (screen 5)

| Key | Action |
|---|---|
| Return (number field) | Places a second call and holds the active one. |
| Return on a selected row | Not specified; see Open items. |
| Command-D | Ends the active call. |

### Decided

- At most 4 simultaneous calls (Q5.1).
- Merge that auto-includes held calls is Full, later (Q5.2) `[v2]`.
- Merge joins all connected calls into a local conference; Split and Full end-all behaviour as in 5.4 `[Full]`.

---

## 6. Incoming call

Screen 06. A floating window and a system notification. Mockup shows the floating window with Auto-answer strip (Full), a notification (alert style), and the variant that arrives during a call.

### Visibility rule (decided)

| Main window state | Where the incoming call appears |
|---|---|
| Hidden, minimised or behind another app | Floating incoming window (6.1) plus system notification (6.3). |
| Visible and frontmost | Inside the main window: the call panel in the incoming state (6.4). No floating window. |

### 6.1 Floating incoming window

Non-activating floating panel, always on top, on all Spaces, 300 pt wide, rounded 14 pt, translucent menu background. Centred on the screen with the pointer by default; draggable; remembers its position.

| # | Element | Notes |
|---|---|---|
| 1 | Avatar, 48 pt circle, initials | |
| 2 | Eyebrow line, 11 pt, secondary, with bell glyph | "Incoming call on %@" with the account short name in primary colour. |
| 3 | Name, 17 pt semibold | Remote party name. |
| 4 | Number, 12.5 pt, secondary | Remote party number or URI. |
| 5 | Auto-answer strip `[Full]` | See 6.5. |
| 6 | Button row, two equal columns, 34 pt high | Decline (red, hang-up glyph) and Answer (green, handset glyph). |

| Element | Type | Behaviour | Enabled |
|---|---|---|---|
| Answer | button, green | Answers the call, makes it active; holds the current call if one exists (see 6.4 variant). | Enabled. |
| Decline | button, red | Sends SIP 486 Busy Here. The call becomes a missed call. | Enabled. |

**Behaviour:**

- The window does not take keyboard focus.
- Ringtone plays while visible. Escape silences the ringtone only (the call still rings and stays in the window).
- The window and the notification disappear when the call is answered, declined, or cancelled by the caller.
- An unanswered call becomes a missed call (badge on Dock, menu bar and the Call Log tab).

### 6.2 Keyboard (floating window)

| Key | Action |
|---|---|
| Command-Return | Answer. |
| Command-Period | Decline (486). |
| Escape | Silences the ringtone only. |

### 6.3 System notification (alert style)

Notification with alert style: stays until acted on. Title "Incoming call · %@" (account name), body with remote party name and number, and two actions: Answer and Decline. Actions also work from Notification Center and on a locked screen. Disappears when the call ends.

| Element | Content |
|---|---|
| App icon at left | 34 pt. |
| Title | "Incoming call · %@". |
| Remote party name | Second line. |
| Number | Third line, secondary. |
| Action "Answer" | Answers. Blue text in mockup. |
| Action "Decline" | Declines with 486. |

### 6.4 Incoming inside the main window (spec; no mockup picture)

Specified by the orchestrator. Shown on the Dialpad tab in place of the call panel content, in the same 392 pt body. Layout follows 6.1, minus the window chrome:

| Element | Behaviour |
|---|---|
| Avatar, name, number | As 6.1. |
| Eyebrow "Incoming call on %@" | As 6.1. |
| State label | "Ringing" in orange (proposed). |
| Answer / Decline row | Two equal columns, 34 pt high, as 6.1. Answer is the default action for Return; Decline for Command-Period. |
| No chip row, no control grid | Hidden while ringing. |

If another tab is selected, the window keeps that tab and shows the summary bar with the incoming call's name and "Incoming" state; clicking the bar returns to the Dialpad tab (proposed; see Open items).

### 6.5 Auto-answer strip `[Full]`

Shown only when auto-answer will fire (mode All, or Contacts only and the caller is a contact, or a server `answer-after` header).

| Element | Type | Behaviour |
|---|---|---|
| Countdown ring | 22 pt circular progress | Drains over the delay (Settings › Auto-answer). |
| Text | "Auto-answer in %lld s" | Counts down. |
| Cancel | link-style button, blue | Stops the auto-answer for this call; the call keeps ringing for manual answer. |

### 6.6 Variant: arrives while on a call

Floating window (or the in-window panel, 6.4) with a different layout. Width 300 pt.

| Element | Content and behaviour |
|---|---|
| Avatar, eyebrow, name, number | As 6.1. Eyebrow "Incoming call on %@" with the second account. |
| Status line, 11.5 pt, secondary | "You are on a call with %@ (%@)." (name, duration). |
| Decline | Red, half width. 486 Busy Here. |
| Hold & Answer | Green, half width, 12 pt label. Holds the current call and answers the incoming call. |
| End Current & Answer | Full width, bordered button. Ends the current call and answers the incoming call. |

Auto-answer never answers a second call while already on one (Settings › Auto-answer note).

### States (screen 6)

| State | Appearance |
|---|---|
| Ringing | 6.1. |
| Ringing, auto-answer countdown `[Full]` | 6.1 with strip. |
| Caller cancelled | Window and notification removed; missed call recorded. |
| While on a call | 6.6. |
| Main window frontmost | 6.4. |

### Keyboard (screen 6)

See 6.2. Notification actions have no keyboard shortcut beyond the system defaults.

### Decided

- The floating window appears only when the main window is not visible or not frontmost; otherwise the call shows inside the main window (Q6.1).
- Notifications use the alert style; they stay until acted on (Q6.2).
- While on a call, a second incoming offers "Hold & Answer" and "End Current & Answer"; Decline sends 486 (ADR 0009).

---

## 7. Menu bar and Dock

Screen 07. Native NSMenu (decided Q7.1). Status item in the menu bar, a Dock icon with a badge.

### 7.1 Status item icon

Monochrome template image: the handset glyph. Five visual states:

| State | Appearance | Source |
|---|---|---|
| Offline (no registration, or no accounts) | outline handset, secondary colour | glossary: no account registered |
| Registered | solid handset | at least one account registered |
| On call | solid handset with the call timer text beside it, e.g. "04:12" | a connected call exists |
| Missed | solid handset with a red count badge (12 pt pill, top right) | unseen missed calls > 0 |
| Do Not Disturb | solid handset with a moon glyph beside it | DND on |

State precedence when several apply: on call shows the timer; missed badge is always shown when there are unseen missed calls; moon shows when DND is on. (Precedence is a proposal; see Open items.)

Clicking the icon during a call brings the main window forward.

### 7.2 Status item menu

Native NSMenu, width about 286 pt. Structure, top to bottom:

| # | Item | Type | Behaviour | Enabled |
|---|---|---|---|---|
| 1 | Account line, one per enabled account | informational line with status dot and account name, address in secondary text at right | Click opens Settings at Accounts, that account selected. Failed line in red with "Failed: %@" (reason text, e.g. "403 Forbidden"). | Enabled. |
| 2 | separator | | | |
| 3 | Quick-dial row | text field plus green call button | Typing shows matching contacts as menu items below the field (proposed; see Open items). Return calls through the default account. Placeholder "Call number or name…". | Call disabled when the field is empty and there is no last number. |
| 4 | separator | | | |
| 5 | Section header "Recent Calls" | header | | |
| 6 | Recent calls, last 5 | menu items | Icon (direction), name or number, time at right. Missed entries in red. Click calls back through the entry's account. | Enabled. |
| 7 | separator | | | |
| 8 | Do Not Disturb | checkmark menu item, shortcut Option-Command-D | Toggles DND. Checkmark when on. Rejects incoming calls with 486. No timed DND in v1 [decided Q7.2]. | Enabled. |
| 9 | My Status ▸ `[Full]` | submenu item, with the current status at right ("Available ›") | See 7.4. | Full only. |
| 10 | separator | | | |
| 11 | Show MacroSIP | menu item, shortcut Command-0 | Brings up the main window. | Enabled. |
| 12 | Settings… | menu item, Command-comma | Opens Settings. | Enabled. |
| 13 | separator | | | |
| 14 | Quit MacroSIP | menu item, Command-Q | Quits. The title is "Quit %@" with the app name (Lite shows "Quit MacroSIP Lite"). | Enabled. |

"Show %@" and "Quit %@" use the bundle display name, so Lite and Full produce the correct app name.

### 7.3 Dock badge

| Element | Behaviour |
|---|---|
| Dock icon badge | Red pill, count of unseen missed calls. Hidden when zero. Clears when the Call Log tab is opened. |
| Dock icon visibility | Controlled by Settings › General "Show icon in the Dock". Hidden Dock icon: the menu bar icon and the window remain. |

### 7.4 My Status submenu `[Full]`

| Item | Behaviour |
|---|---|
| Available | Checkmark when current. Publishes `available` presence. |
| Away | Checkmark when current. Publishes `away`. Dot yellow. |
| Do Not Disturb | Checkmark when current. Publishes `dnd` and turns DND on in the menu item (kept in sync). Dot red. |

### Keyboard (menu bar)

| Shortcut | Item |
|---|---|
| Option-Command-D | Do Not Disturb |
| Command-0 | Show MacroSIP |
| Command-comma | Settings… |
| Command-Q | Quit |

### States (screen 7)

| State | Appearance |
|---|---|
| No accounts | Account lines absent; the menu shows Quick-dial (disabled) and recent calls if any. Icon offline. |
| Failed account | Red account line. |
| Missed calls | Badge on the icon; missed entries red in Recent Calls. |
| Lite vs Full | Lite: no My Status submenu. Full: My Status shown. |

---

## 8. Settings

Screen 08. Standard macOS Settings window: toolbar tabs, grouped forms, changes apply immediately (no Save button), window title follows the selected tab, width 620 pt.

### Window

| Element | Behaviour |
|---|---|
| Title | Name of the selected tab (General, Accounts, Audio, Network, Codecs, Recording, Auto-answer). |
| Toolbar | Tabs with icon above label (20 pt icon, 11 pt label). Selected tab filled. |
| Tabs | General, Accounts, Audio, Network, Codecs; `[Full]` Recording and Auto-answer. Lite: five tabs. |
| Pane body | Grouped rows on a grey background, min height 380 pt, 18 pt top and 22 pt side padding. |
| Save button | None. Changes apply immediately. |

**Grouped-form pattern** (all panes): group header above a group box (rounded 9 pt, white); rows 40 pt min height, separated by hairlines inset 12 pt; label on the left (13 pt), control on the right; optional secondary label under the row label (11.5 pt); group footer text under the box (11.5 pt, secondary).

Settings is opened from the menu (Command-comma) or the "Settings…" link on the first-launch screen.

### 8.1 General

Layout: three groups.

**Group 1, toggles:**

| Row | Type | Behaviour | Edition |
|---|---|---|---|
| Launch at login | toggle | Registers the login item. No first-run prompt [decided Q10.2]. | Both |
| Keep running in the menu bar when the window is closed | toggle | When off, closing the window quits the app. | Both |
| Show icon in the Dock | toggle | Hides or shows the Dock icon (see 7.3). | Both |

**Group 2, language:**

| Row | Type | Behaviour |
|---|---|---|
| Language (secondary label "Takes effect after MacroSIP restarts.") | popup, current value "System (English)" | Choices: System, English, Русский. Changing prompts for restart. |

Group footer: "Choices: System, English, Русский."

**Group 3, Links (header "Links"):**

| Row | Type | Behaviour | Enabled |
|---|---|---|---|
| Open sip: and tel: links with MacroSIP (secondary label with status line) | label and button "Make Default" | Registers MacroSIP for `sip:`, `sips:` and `tel:` through Launch Services. The status line (warning dot, orange) says which other app owns `tel:` when it is not MacroSIP: "Another app currently handles tel: links." | Enabled. |
| When a link is opened (secondary "Fills the number field so you can check it first.") | popup, current value "Ask before calling" | Choices beyond "Ask before calling" are not drawn; see Open items. "Ask before calling" fills the number field; it does not place the call. | Enabled. |

Language switches the app's own language (macOS per-app language) and asks to restart.

**Keyboard:** none beyond standard form navigation.

**Decided:** launch at login, language, URL handler with "ask before calling", keep running in menu bar, show icon in Dock (ADR 0009). Microphone permission is requested on the first call (see 10).

### 8.2 Accounts

Layout: one table, a footer under it, then a "last error" group. Table width fills the pane.

**Table:**

| Column | Content | Width |
|---|---|---|
| (status dot) | registration dot | 16 pt |
| Name | account short name; "Default" badge (blue) on the default outgoing account | 1.1 fr |
| Address | user@domain | 1.8 fr |
| Transport | UDP, TCP or TLS | 60 pt |
| Status | "Registered", "403" (short reason, in red), "Disabled" (grey) | 70 pt |

Rows: one per account, drag to reorder. Order is used in the account picker and the status bar. Selected row: blue, white text.

Table footer: "+" (add account), "−" (remove account, confirms), "Edit…" (opens the account editor sheet, 9). Group footer: "Double-click an account to edit it. Drag to reorder; the order is used in the account picker and the status bar."

**Last error group** (header "Backup · last error", i.e. the account name and the word "last error"):

| Row | Content | Element |
|---|---|---|
| Error label | "403 Forbidden" (monospaced), second line "REGISTER rejected at %@. Check the username and password." | label |
| Retry | button | Re-attempts registration for the account. |

**Behaviour:**

- Status updates live.
- Double-click an account: opens the editor (9).
- "−" with a row selected: confirmation before deleting; also removes the Keychain item (see Open items for the wording).
- Unchecking "Register" in the editor shows the account as Disabled here.
- Only one account is the default outgoing account; setting another as default clears the previous one (in the editor).

**States:**

| State | Appearance |
|---|---|
| No accounts | Table empty with message `accounts.empty` (proposed). "−" and "Edit…" disabled. Last error group hidden. |
| Registered | Green dot, "Registered". |
| Failed | Red dot, "403" (or short reason), last error group visible for that account. |
| Disabled | Grey hollow dot, "Disabled". |
| Registering | Orange dot (proposed; not drawn); see Open items. |

**Keyboard:** Return edits the selected row (proposed; double-click is drawn). Delete key removes the selected row after confirmation (proposed).

**Decided:** Accounts pane lists accounts with live status; add, remove, edit; last error with Retry (ADR 0009).

### 8.3 Audio

Layout: three groups: Devices, Ringtone, Processing.

**Devices:**

| Row | Type | Behaviour | Notes |
|---|---|---|---|
| Microphone | level meter (8 segments) and popup | Meter is live while this pane is open. Popup lists input devices plus "System default". | Meter: green segments, the top segment yellow when near clipping. |
| Speaker | "Test" small button and popup | Test plays a short tone on the chosen output. Popup lists output devices plus "System default". | |
| Ringtone device (secondary "Ring through the speakers even when a headset is used for calls.") | popup | Output for the ringtone only. Shows "MacBook Pro Speakers" in the mockup. | |

Group footer: "System default" follows macOS Sound settings. If a chosen device is unplugged, MacroSIP falls back to the system default and switches back when it returns.

**Ringtone:**

| Row | Type | Behaviour |
|---|---|---|
| Sound | "Play" small button with a play glyph, and popup | Popup: Classic, Digital, Soft (built-in), a separator, and "Custom file…". The mockup shows "Custom: office-bell.m4a". "Play" previews the sound. |
| Volume | slider with speaker glyph (200 pt wide) | Ringtone volume. Continuous. |

Group footer: "Built-in choices: Classic, Digital, Soft. "Custom file…" accepts WAV, AIFF, M4A, MP3."

**Processing:**

| Row | Type | Behaviour |
|---|---|---|
| Echo cancellation (secondary "Turn off only when using a headset with its own echo cancellation.") | toggle | On by default. |

**Keyboard:** none beyond standard.

**States:** device list updates live when devices are plugged or unplugged. Missing device shows the fallback (footer rule above).

**Decided:** echo cancellation lives in Audio (ADR 0009, Q8.1).

### 8.4 Network

Layout: two groups. Connection, then an info note.

**Connection:**

| Row | Type | Behaviour | Default / example |
|---|---|---|---|
| STUN server (secondary "Leave empty if you are not behind NAT.") | text field, min width 220 pt | Host and optional port. Empty disables STUN. | "stun.example.org:3478" |
| Local SIP port (secondary "0 picks a free port automatically.") | number field, 70 pt, with stepper | Range 0 to 65535. 0 picks a free port. Changing it re-registers all accounts. | 5060 |
| Keep-alive interval (secondary "Keeps NAT bindings open between registrations.") | number field, 50 pt, stepper, unit "seconds" | Positive integer. | 15 |
| Use ICE (secondary "Finds a working media path through NAT. Uses the STUN server above.") | toggle | On by default. | on |

**Info note (no box, secondary text with info glyph):** "Changing the port re-registers all accounts. Calls in progress are not interrupted. Transport and SRTP are set per account in the account editor."

Transport and SRTP are not in this pane [decided Q8.1].

**Keyboard:** Return commits a number field. Stepper arrows change the value by one.

**States:** invalid port or interval: field border red; value reverted on blur (proposed; see Open items). 

### 8.5 Codecs

Layout: one group with a table and a footer.

| Column | Content | Width |
|---|---|---|
| (check) | checkbox | 18 pt |
| Codec | name | flexible |
| Sample rate | "48 kHz", "16 kHz", "8 kHz" (tabular) | 90 pt |
| Bitrate | informational range, e.g. "6–510 kbit/s" | 90 pt |
| (grip) | drag handle | 16 pt |

Rows, in default preference order:

| Codec | Checked | Sample rate | Bitrate |
|---|---|---|---|
| Opus | on | 48 kHz | 6–510 kbit/s |
| G.722 | on | 16 kHz | 64 kbit/s |
| PCMU (G.711 µ-law) | on | 8 kHz | 64 kbit/s |
| PCMA (G.711 A-law) | off | 8 kHz | 64 kbit/s |

Only these four codecs are shown [decided Q8.3].

Footer: "Move up" and "Move down" icon buttons (chevron), "Restore Defaults" small button on the right.

Group header: "Audio codecs, in order of preference". Group footer: "Drag rows or use the arrows to reorder. Unchecked codecs are never offered. At least one codec must stay enabled."

**Behaviour:**

- Order sets SDP preference.
- Unchecking a codec removes it from offers. At least one must stay checked: unchecking the last one is refused (control disabled).
- Bitrate and sample rate are informational.
- Restore Defaults restores the four rows above, in that order, all checked except PCMA (proposed; see Open items).

**Keyboard:** Option-Up / Option-Down moves the selected row (proposed; not drawn).

### 8.6 Recording `[Full]`

Full only. Lite: no tab, no pane.

Layout: two groups.

| Row | Type | Behaviour |
|---|---|---|
| Save recordings to | popup with folder icon, current "MacroSIP Recordings" | Choose folder; the picker remembers access with a security-scoped bookmark. |
| Record all calls automatically | toggle, off | When on, every call is recorded. |

Group footer: "Recordings are saved as M4A (AAC). The temporary WAV is deleted after conversion." then "File name: 2026-10-10 14.52 Anna Petrova (in).m4a" (monospaced). Format: date and time to minutes, remote party name, direction in parentheses ("in" or "out").

Second group:

| Row | Type | Behaviour |
|---|---|---|
| Show Recordings Folder | button "Open in Finder" | Opens the folder in Finder. |

Notes: a Record button is always available in the call panel even when automatic recording is off. A recording notice is Full, later [decided Q8.2] `[v2]`.

**States:** folder missing: popup shows the folder name with a warning; choose again (proposed).

### 8.7 Auto-answer `[Full]`

Full only.

Layout: one group, one footer.

| Row | Type | Behaviour |
|---|---|---|
| Answer incoming calls automatically | segmented control: Off, All calls, Contacts only | Mode. Default Off. Selected mockup value: Contacts only. |
| Delay before answering | number field (44 pt), stepper, unit "seconds" | Positive integer. Default 5. |
| Honour the server's answer-after request (secondary: "Answers when the PBX sends Call-Info: answer-after=N (intercom, paging), even if the mode is Off.") | toggle | On by default in the mockup. |

Group footer: "Do Not Disturb wins over auto-answer. Auto-answer never answers a second call while you are already on one."

Note for incoming window: shows the countdown and Cancel whenever auto-answer will fire (6.5).

### Keyboard (settings, all panes)

| Key | Action |
|---|---|
| Command-comma | Opens Settings. |
| Command-W | Closes the window (standard). |
| Tab / Shift-Tab | Moves between controls (standard). |

### Decided (screen 8)

- Transport and SRTP only per account; Network keeps STUN, local port, keep-alive and ICE (Q8.1).
- Recording notice is Full, later (Q8.2) `[v2]`.
- Only four codecs are shown (Q8.3).

---

## 9. Account editor

Screen 09. Sheet on Settings › Accounts. 460 pt wide. Opens from "+", "Edit…" and double-click. Title "Edit Account" for existing accounts (`account.title.edit`); "New Account" for new (proposed).

### Layout (top to bottom)

| # | Section | Content |
|---|---|---|
| 1 | Title | "Edit Account", 13 pt bold. |
| 2 | Identity group | Account name, Display name. |
| 3 | Server group | SIP server, Username, Auth username, Password, Domain, Outgoing proxy. |
| 4 | Connection group | Transport, Media encryption (SRTP), Registration expiry. |
| 5 | Switches group | Register with server, Default for outgoing calls, Publish my presence `[Full]`. |
| 6 | Button row | Delete Account…, Test, status text, Cancel, Save. |

### Elements

| Element | Type | Behaviour | Required | Default |
|---|---|---|---|---|
| Account name (secondary: none) | text field | Short label used in the picker, status bar, call panel and menu bar ("Office"). | Yes (proposed; mockup gives it no marker) | empty |
| Display name (secondary "Shown to people you call.") | text field | Caller-ID presented to the remote party. | No | empty |
| SIP server | text field | Host name or IP. Validated (see States). | Yes | empty |
| Username | text field | SIP user. | Yes | empty |
| Auth username (secondary "Only if different from the username.") | text field, placeholder "Optional" | Used for digest authentication; empty means username. | No | empty |
| Password (secondary "Stored in the Keychain.") | secure text field | Stored only in Keychain. Shown as dots. | Yes | empty |
| Domain (secondary "Empty uses the SIP server.") | text field, placeholder shows "pbx.example.com" | Used to build SIP URIs. | No | empty |
| Outgoing proxy | text field, placeholder "Optional, e.g. sip:proxy.example.com;lr" | Route set for requests. | No | empty |
| Transport | segmented control: UDP, TCP, TLS | One value. | Yes | TLS in the mockup (default for new accounts: see Open items) |
| Media encryption (SRTP) | popup | Disabled, Optional, Mandatory (glossary modes). | Yes | Mandatory in the mockup |
| Registration expiry | number field, 56 pt, stepper, unit "seconds" | Expiry in seconds. | Yes | 300 |
| Register with server (secondary "Off keeps the account for outgoing calls only.") | toggle | Off: account is disabled for incoming calls; shown as Disabled in Settings. | | on |
| Default for outgoing calls | toggle | Only one account is default; turning on clears the previous one. | | on in mockup |
| Publish my presence `[Full]` (secondary "Lets contacts who watch you see Available / Away / DND.") | toggle | Per-account presence publish. | | on in mockup |
| Delete Account… | button, destructive | Asks for confirmation; removes the account and its Keychain item. | | |
| Test | button | Registers once with the values in the sheet, without saving; shows the result inline (9.2). | Enabled when Server, Username and Password are filled. | |
| Status text | label, with a dot | Live registration status of the saved account ("Registered"). For a new account: "Not saved". | | |
| Cancel | button | Closes without saving. Escape. | | |
| Save | button, default (accent) | Validates; stores password in Keychain; saves; re-registers; closes. | Enabled when valid. | |

**Behaviour:**

- Save validates the fields, stores the password in the Keychain and re-registers. The status beside the buttons updates live.
- Test does not save anything. It uses a temporary registration.
- Delete asks for confirmation and removes the Keychain item too.
- Only one account is default outgoing; turning on "Default for outgoing calls" turns it off on the previous default.
- Account name must be unique (proposed; see Open items).

### States

| State | Appearance |
|---|---|
| Validation error, SIP server | Field has a 1 pt red ring. Message under the group, red: "Enter a host name like pbx.example.com, or an IP address." |
| Test failed | Orange warning glyph, "Test failed: %@" (bold) with secondary "The server rejected the username or password. Nothing was saved." Button "Test Again" small on the right. |
| Test success | Message "Registered; expires in %@ s." (proposed; see Open items). |
| Testing in progress | Button "Test" disabled; status text "Testing…" (proposed). |
| Saved and registered | Status "Registered" with green dot. |
| Saved, failed | Status shows short reason in red. |
| Lite vs Full | Lite: no "Publish my presence" row. Full: row present. |

### Keyboard

| Key | Action |
|---|---|
| Return | Save (default button) when enabled. |
| Escape | Cancel. |
| Tab | Next field. |

### Decided

- A Test button tries to register without saving and shows the result inline (Q9.1).
- v1 adds a separate auth username and registration expiry; no voicemail number (Q9.2).
- Account editor has an "Account name" label; no voicemail number (ADR 0009).

---

## 10. First launch

Screen 10. Main window with no accounts.

### Layout

| # | Element | Notes |
|---|---|---|
| 1 | Common frame | Account popup shows "No account" (dimmed). Number field disabled. Tabs enabled. |
| 2 | Empty-state body | Centred column, 398 pt high, 24 pt padding. |
| 3 | Status bar | "No accounts" with a grey hollow dot, and "Settings… ⌘," at right. |

### Empty-state body

| Element | Type | Text / behaviour |
|---|---|---|
| App icon | image, 64 pt | |
| Heading | label, 17 pt bold | "Add a SIP account to start calling" (`firstrun.title`). |
| Body | label, 12.5 pt, secondary, max width 250 pt | "You need the server address, username and password from your phone provider or PBX administrator." |
| Add Account… | button, primary (accent), small | Opens the account editor (9) as a sheet on this window. |
| Footnote | label, 11.5 pt, secondary | "Contacts and the call log work without an account." |

After Save in the editor, the empty state disappears and the Dialpad body (screen 1) becomes live. The account popup and number field become enabled.

### States

| State | Appearance |
|---|---|
| No accounts (this screen) | As above. |
| Accounts exist | Screen 1. |
| Account added but not registered | Dialpad live; status bar shows the account in its registration state. |

### Microphone permission (first call)

Permission is requested on the first call, not at launch. System dialog (text owned by macOS, using the usage string below):

| Element | Content |
|---|---|
| System title | "MacroSIP" would like to access the microphone. (macOS) |
| Usage string (Info.plist key `NSMicrophoneUsageDescription`) | "MacroSIP needs the microphone so the other person can hear you during calls." |
| Buttons | Don't Allow, Allow (system) |

If denied, the call panel shows "Microphone access is off" with an "Open System Settings" button (see Strings; not drawn in the mockup).

### Keyboard

| Key | Action |
|---|---|
| Command-comma | Opens Settings. |
| Return | No effect while disabled. |

### Decided

- No MicroSIP .ini import in v1 (Q10.1). Not in v1: global hotkeys, macOS Contacts import, first-run launch-at-login prompt (ADR 0009).
- No launch-at-login prompt on first run; it stays in Settings › General (Q10.2).
- "Add Account…" opens the account editor as a sheet; the menu bar icon appears in the offline state from the first launch.

---

## Strings

Every user-visible English string in the mockups and notes. Keys are proposed String Catalog keys in dot notation (camelCase segments). Placeholders use `%@` (string) and `%lld` (integer); numbered `%1$@` form is required where a translation changes word order. Column **Ed.** marks `[Full]` strings.

Strings marked "(proposed)" are not in the mockups; they are needed by the spec and are in the Open items list where a decision is needed. Strings shown only as sample data (e.g. "Anna Petrova", "+7 912 555-01-23", "pbx.example.com") are not strings and are not listed.

### Common and main window

| Ed. | English | Key | Notes |
|---|---|---|---|
| | MacroSIP Lite | `main.title.lite` | Title, Lite build. |
| `[Full]` | MacroSIP | `main.title.full` | Title, Full build. |
| | Dialpad | `tabs.dialpad` | |
| | Contacts | `tabs.contacts` | |
| | Call Log | `tabs.callLog` | |
| | Name or number | `main.numberField.placeholder` | |
| | Outgoing account | `main.accountPicker.help` | Tooltip. |
| | No account | `main.accountPicker.none` | Disabled state. |
| | No accounts | `status.noAccounts` | Status bar. |
| | %@: %@ | `status.account.failed` | Account name, short reason; red. |
| | Settings… | `menu.settings` | Shown in status bar in first launch as "Settings… ⌘,". |
| | Show %@ | `menu.showApp` | Menu bar item; %@ app name. |
| | Quit %@ | `menu.quitApp` | Menu bar item; %@ app name. |

### 1 Dialpad

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Call | `dialpad.call.help` | Accessibility label of the Call button. |
| | Delete last digit | `dialpad.delete.help` | Accessibility label. |
| | Return calls · empty field + Call redials | `dialpad.hint` | Hint line. |
| | ABC, DEF, GHI, JKL, MNO, PQRS, TUV, WXYZ, + | `dialpad.key.letters.2` … `dialpad.key.letters.9`, `dialpad.key.letters.0` | Letter sets are per locale; Russian letters are an Open item. |

### 2 Contacts

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Search | `contacts.search.placeholder` | |
| | %lld contacts | `contacts.count` | Plural variants: one, few, many, other. Mockup: "6 contacts". |
| | Add contact | `contacts.add.help` | Tooltip. |
| | Delete contact | `contacts.delete.help` | Tooltip. |
| | Edit contact | `contacts.edit.help` | Tooltip. |
| | Call | `contacts.menu.call` | Menu item. |
| | Call from | `contacts.menu.callFrom` | Submenu title. |
| | Copy Number | `contacts.menu.copyNumber` | |
| | Edit… | `contacts.menu.edit` | |
| `[Full]` | Watch Presence | `contacts.menu.watchPresence` | Checkmark item. |
| | Delete | `contacts.menu.delete` | |
| | Delete %@? | `contacts.delete.confirm` | %@ contact name. |
| | Delete | `common.delete` | Destructive button. |
| | Cancel | `common.cancel` | |
| `[Full]` | Available | `presence.available` | Presence text and menu. |
| `[Full]` | Away | `presence.away` | |
| `[Full]` | Do Not Disturb | `presence.dnd` | |
| | Edit Contact | `contact.edit.title` | Sheet title. |
| | New Contact | `contact.new.title` | Proposed. |
| | Name | `contact.field.name` | |
| | Number | `contact.field.number` | |
| | Account | `contact.field.account` | |
| | Any (use default) | `contact.account.any` | |
| `[Full]` | Watch presence (subscribe) | `contact.watchPresence` | Checkbox. |
| | Save | `common.save` | |
| | No contacts yet | `contacts.empty.title` | Proposed. |
| | Add a contact to call people faster. | `contacts.empty.body` | Proposed. |
| | No matching contacts | `contacts.search.noResults` | Proposed. |

### 3 Call Log

| Ed. | English | Key | Notes |
|---|---|---|---|
| | All | `calllog.filter.all` | |
| | Missed | `calllog.filter.missed` | |
| | Clear… | `calllog.clear` | Button. |
| | Today | `calllog.section.today` | |
| | Yesterday | `calllog.section.yesterday` | |
| | missed | `calllog.row.missed` | Right column for missed rows. |
| | Unknown | `calllog.row.unknown` | Second line for unknown party. |
| | Call | `calllog.menu.call` | |
| | Call from | `calllog.menu.callFrom` | |
| | Add to Contacts | `calllog.menu.addContact` | |
| | Copy Number | `calllog.menu.copyNumber` | |
| | Delete Entry | `calllog.menu.delete` | |
| | Clear the call log? | `calllog.clear.title` | Alert title. |
| | All %lld entries are removed. | `calllog.clear.body` | |
| `[Full]` | Recordings stay in their folder. | `calllog.clear.bodyRecordings` | Appended to body in Full. |
| | Clear | `calllog.clear.confirm` | Destructive button. |
| | No calls yet | `calllog.empty.title` | Proposed. |
| | Calls you make and receive appear here. | `calllog.empty.body` | Proposed. |
| | No missed calls | `calllog.empty.missed` | Proposed. |

### 4 Active call

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Connected | `call.state.connected` | |
| | Calling… | `call.state.outgoing` | Proposed. |
| | Ringing… | `call.state.early` | Proposed. |
| | Ringing | `call.state.ringing` | Incoming, inside window. Proposed. |
| | On hold | `call.state.held` | Proposed as call-panel state label. |
| | via %@ | `call.via` | %@ account name. |
| | %@ %@ | `call.quality.codec` | Codec and sample rate, e.g. "Opus 48 kHz". |
| | SRTP | `call.srtp.label` | |
| | Media encrypted with SRTP | `call.srtp.help` | Tooltip. |
| `[Full]` | REC %@ | `call.rec.chip` | %@ elapsed time. |
| | Mute | `call.mute` | |
| | Hold | `call.hold` | |
| | Transfer | `call.transfer` | |
| | Keypad | `call.keypad` | |
| `[Full]` | Record | `call.record` | |
| `[Full]` | Merge | `call.merge` | |
| | End Call | `call.end` | |
| | End Call with %@ | `call.endWith` | %@ remote party name. |
| | Back to call | `keypad.back` | |
| | %@ · %@ | `keypad.who` | Name, timer. |
| | Click to return to the call | `callbar.help` | Tooltip. |
| | Muted | `callbar.muted.help` | Tooltip. |
| | +%lld on hold | `callbar.moreHeld` | |
| | Transfer %@ to | `transfer.title` | %@ remote party name. |
| | Call First | `transfer.callFirst` | |
| | Attended: call %@ first, then complete | `transfer.callFirst.help` | %@ target name. |
| | Transfer Now | `transfer.now` | |
| | Blind: hand the call over now | `transfer.now.help` | |
| | Transfer Now hands the call over immediately. Call First lets you talk to %@ before you complete the transfer. | `transfer.explanation` | %@ target name. |
| | Microphone access is off | `call.mic.denied` | From first-launch notes. |
| | Open System Settings | `call.mic.openSettings` | From first-launch notes. |

### 5 Several calls

| Ed. | English | Key | Notes |
|---|---|---|---|
| | %lld calls | `calls.count` | Heading, displayed uppercase. |
| | Click a row to switch | `calls.switchHint` | |
| | Active · %@ | `calls.row.active` | %@ duration. |
| | On hold · %@ | `calls.row.held` | %@ duration. |
| | Consulting · %@ | `calls.row.consulting` | %@ duration. |
| | On hold · waiting for transfer | `calls.row.waitingTransfer` | |
| | Resume | `calls.resume` | |
| | End | `calls.end.help` | Mini end button, accessibility label. |
| `[Full]` | In conference | `calls.row.inConference` | |
| `[Full]` | Split | `calls.split` | |
| | +1 on hold | `callbar.moreHeld` | See 4; plural form. |
| | Transfer %@ to %@? | `transfer.banner.title` | Anna to Boris. |
| | %@ and %@ will be connected and you leave both calls. | `transfer.banner.body` | |
| | Cancel | `common.cancel` | |
| | Complete Transfer | `transfer.complete` | Default button. |
| `[Full]` | CONFERENCE · %lld PARTICIPANTS | `conference.header` | Displayed uppercase. |
| `[Full]` | End Conference | `conference.end` | |

### 6 Incoming call

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Incoming call on %@ | `incoming.eyebrow` | %@ account name. |
| | Answer | `incoming.answer` | |
| | Decline | `incoming.decline` | |
| | Incoming call · %@ | `incoming.notification.title` | %@ account name. |
| `[Full]` | Auto-answer in %lld s | `incoming.autoAnswer.countdown` | |
| `[Full]` | Cancel | `incoming.autoAnswer.cancel` | Link-style button. |
| | You are on a call with %@ (%@). | `incoming.onCall.status` | %@ name, %@ duration. |
| | Hold & Answer | `incoming.holdAnswer` | |
| | End Current & Answer | `incoming.endCurrentAnswer` | |
| | Ringing | `incoming.state.ringing` | Main-window variant; proposed. |

### 7 Menu bar and Dock

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Failed: %@ | `menu.account.failed` | %@ reason, e.g. "403 Forbidden". |
| | Call number or name… | `menu.quickDial.placeholder` | |
| | Recent Calls | `menu.recentCalls` | Section header. |
| | Do Not Disturb | `menu.dnd` | Shortcut Option-Command-D. |
| `[Full]` | My Status | `menu.myStatus` | Submenu title. |
| `[Full]` | Available › | `menu.myStatus.current` | Shows current value at right. |
| | Away | `menu.status.away` | Submenu item (Full). |
| | Available | `menu.status.available` | Submenu item (Full). |
| `[Full]` | Do Not Disturb | `menu.status.dnd` | Submenu item. |
| | Show %@ | `menu.showApp` | Repeated from Common; Command-0. |
| | Settings… | `menu.settings` | Command-comma. |
| | Quit %@ | `menu.quitApp` | Command-Q. |
| | Offline | `menubar.state.offline.help` | Accessibility; proposed. |

### 8 Settings

| Ed. | English | Key | Notes |
|---|---|---|---|
| | General | `settings.tab.general` | Toolbar and title. |
| | Accounts | `settings.tab.accounts` | |
| | Audio | `settings.tab.audio` | |
| | Network | `settings.tab.network` | |
| | Codecs | `settings.tab.codecs` | |
| `[Full]` | Recording | `settings.tab.recording` | |
| `[Full]` | Auto-answer | `settings.tab.autoAnswer` | |
| | Launch at login | `settings.general.launchAtLogin` | |
| | Keep running in the menu bar when the window is closed | `settings.general.keepRunning` | |
| | Show icon in the Dock | `settings.general.showInDock` | |
| | Language | `settings.general.language` | |
| | Takes effect after MacroSIP restarts. | `settings.general.language.help` | |
| | System (English) | `settings.general.language.system` | Value shown; key includes the resolved language name. |
| | Choices: System, English, Русский. | `settings.general.language.footer` | |
| | Links | `settings.general.links.header` | |
| | Open %@ and %@ links with MacroSIP | `settings.general.links.title` | %@ values sip: and tel:. Shown with monospaced scheme. |
| | Another app currently handles tel: links. | `settings.general.links.otherHandler` | Warning line. |
| | Make Default | `settings.general.links.makeDefault` | |
| | When a link is opened | `settings.general.links.onOpen` | |
| | Fills the number field so you can check it first. | `settings.general.links.onOpen.help` | |
| | Ask before calling | `settings.general.links.askBeforeCalling` | Popup value. |
| | Accounts list header and footer: "Double-click an account to edit it. Drag to reorder; the order is used in the account picker and the status bar." | `accounts.list.footer` | |
| | Name, Address, Transport, Status | `accounts.column.name`, `accounts.column.address`, `accounts.column.transport`, `accounts.column.status` | Table headers. |
| | Default | `accounts.badge.default` | |
| | Registered | `accounts.status.registered` | |
| | Disabled | `accounts.status.disabled` | |
| | 403 Forbidden | `accounts.lastError.title` | Monospaced in mockup. %@ reason. |
| | REGISTER rejected at %@. Check the username and password. | `accounts.lastError.body` | %@ time. |
| | Backup · last error | `accounts.lastError.header` | Mockup group header; %@ account name. |
| | Retry | `accounts.retry` | |
| | Edit… | `accounts.edit` | |
| | No accounts | `accounts.empty` | Proposed for empty table. |
| | Devices | `settings.audio.devices.header` | |
| | Microphone | `settings.audio.microphone` | |
| | Speaker | `settings.audio.speaker` | |
| | Test | `settings.audio.test` | |
| | Ringtone device | `settings.audio.ringtoneDevice` | |
| | Ring through the speakers even when a headset is used for calls. | `settings.audio.ringtoneDevice.help` | |
| | System default | `settings.audio.systemDefault` | Popup item. |
| | "System default" follows macOS Sound settings. If a chosen device is unplugged, MacroSIP falls back to the system default and switches back when it returns. | `settings.audio.devices.footer` | |
| | Ringtone | `settings.audio.ringtone.header` | |
| | Sound | `settings.audio.ringtoneSound` | |
| | Play | `settings.audio.ringtonePlay` | |
| | Classic, Digital, Soft | `settings.audio.ringtone.classic`, `.digital`, `.soft` | Built-in choices. |
| | Custom file… | `settings.audio.ringtone.custom` | |
| | Custom: %@ | `settings.audio.ringtone.customName` | %@ file name. |
| | Volume | `settings.audio.ringtoneVolume` | |
| | Built-in choices: Classic, Digital, Soft. "Custom file…" accepts WAV, AIFF, M4A, MP3. | `settings.audio.ringtone.footer` | |
| | Processing | `settings.audio.processing.header` | |
| | Echo cancellation | `settings.audio.echoCancellation` | |
| | Turn off only when using a headset with its own echo cancellation. | `settings.audio.echoCancellation.help` | |
| | Connection | `settings.network.connection.header` | |
| | STUN server | `settings.network.stun` | |
| | Leave empty if you are not behind NAT. | `settings.network.stun.help` | |
| | Local SIP port | `settings.network.port` | |
| | 0 picks a free port automatically. | `settings.network.port.help` | |
| | Keep-alive interval | `settings.network.keepAlive` | |
| | Keeps NAT bindings open between registrations. | `settings.network.keepAlive.help` | |
| | seconds | `settings.unit.seconds` | Unit label; plural rules apply. |
| | Use ICE | `settings.network.ice` | |
| | Finds a working media path through NAT. Uses the STUN server above. | `settings.network.ice.help` | |
| | Changing the port re-registers all accounts. Calls in progress are not interrupted. Transport and SRTP are set per account in the account editor. | `settings.network.footer` | |
| | Audio codecs, in order of preference | `settings.codecs.header` | |
| | Codec, Sample rate, Bitrate | `settings.codecs.column.codec`, `.sampleRate`, `.bitrate` | Table headers. |
| | PCMU (G.711 µ-law), PCMA (G.711 A-law) | `settings.codecs.pcmu`, `settings.codecs.pcma` | Codec names; G.711 variants. |
| | Move up, Move down | `settings.codecs.moveUp`, `settings.codecs.moveDown` | Tooltips. |
| | Restore Defaults | `settings.codecs.restoreDefaults` | |
| | Drag rows or use the arrows to reorder. Unchecked codecs are never offered. At least one codec must stay enabled. | `settings.codecs.footer` | |
| `[Full]` | Save recordings to | `settings.recording.folder` | |
| `[Full]` | MacroSIP Recordings | `settings.recording.folderName` | Default folder name. |
| `[Full]` | Record all calls automatically | `settings.recording.auto` | |
| `[Full]` | Recordings are saved as M4A (AAC). The temporary WAV is deleted after conversion. | `settings.recording.footer` | |
| `[Full]` | File name: %@ | `settings.recording.fileName` | %@ sample file name. |
| `[Full]` | Show Recordings Folder | `settings.recording.showFolder` | |
| `[Full]` | Open in Finder | `settings.recording.openFinder` | |
| `[Full]` | Answer incoming calls automatically | `settings.autoAnswer.mode` | |
| `[Full]` | Off, All calls, Contacts only | `settings.autoAnswer.off`, `.all`, `.contactsOnly` | Segments. |
| `[Full]` | Delay before answering | `settings.autoAnswer.delay` | |
| `[Full]` | Honour the server's answer-after request | `settings.autoAnswer.honourServer` | |
| `[Full]` | Answers when the PBX sends Call-Info: answer-after=N (intercom, paging), even if the mode is Off. | `settings.autoAnswer.honourServer.help` | |
| `[Full]` | Do Not Disturb wins over auto-answer. Auto-answer never answers a second call while you are already on one. | `settings.autoAnswer.footer` | |

### 9 Account editor

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Edit Account | `account.title.edit` | |
| | New Account | `account.title.new` | Proposed. |
| | Identity | `account.group.identity` | Group header. |
| | Account name | `account.field.name` | |
| | Display name | `account.field.displayName` | |
| | Shown to people you call. | `account.field.displayName.help` | |
| | Server | `account.group.server` | Group header. |
| | SIP server | `account.field.server` | |
| | Username | `account.field.username` | |
| | Auth username | `account.field.authUsername` | |
| | Only if different from the username. | `account.field.authUsername.help` | |
| | Optional | `account.field.optional` | Placeholder. |
| | Password | `account.field.password` | |
| | Stored in the Keychain. | `account.field.password.help` | |
| | Domain | `account.field.domain` | |
| | Empty uses the SIP server. | `account.field.domain.help` | |
| | Outgoing proxy | `account.field.proxy` | |
| | Optional, e.g. sip:proxy.example.com;lr | `account.field.proxy.placeholder` | Placeholder. |
| | Connection | `account.group.connection` | |
| | Transport | `account.field.transport` | |
| | UDP, TCP, TLS | `account.transport.udp`, `.tcp`, `.tls` | |
| | Media encryption (SRTP) | `account.field.srtp` | |
| | Disabled, Optional, Mandatory | `account.srtp.disabled`, `.optional`, `.mandatory` | Glossary modes. |
| | Registration expiry | `account.field.expiry` | |
| | Register with server | `account.field.register` | |
| | Off keeps the account for outgoing calls only. | `account.field.register.help` | |
| | Default for outgoing calls | `account.field.defaultOutgoing` | |
| `[Full]` | Publish my presence | `account.field.publishPresence` | |
| `[Full]` | Lets contacts who watch you see Available / Away / DND. | `account.field.publishPresence.help` | |
| | Delete Account… | `account.delete` | Destructive. |
| | Test | `account.test` | |
| | Registered | `account.status.registered` | Status beside buttons. |
| | Cancel | `common.cancel` | |
| | Save | `common.save` | |
| | Enter a host name like pbx.example.com, or an IP address. | `account.error.server` | Validation. |
| | Test failed: %@ | `account.test.failed` | %@ SIP error, e.g. "401 Unauthorized". |
| | The server rejected the username or password. Nothing was saved. | `account.test.failed.hint` | |
| | Test Again | `account.test.again` | |

### 10 First launch

| Ed. | English | Key | Notes |
|---|---|---|---|
| | No account | `main.accountPicker.none` | Popup, disabled. Repeated from Common. |
| | No accounts | `status.noAccounts` | Status bar. |
| | Add a SIP account to start calling | `firstrun.title` | |
| | You need the server address, username and password from your phone provider or PBX administrator. | `firstrun.body` | |
| | Add Account… | `firstrun.addAccount` | Button. |
| | Contacts and the call log work without an account. | `firstrun.footnote` | |
| | "MacroSIP needs the microphone so the other person can hear you during calls." | `NSMicrophoneUsageDescription` (Info.plist, not String Catalog) | Usage string. |
| | Don't Allow, Allow | system | Provided by macOS. |

### Proposed strings not in the mockups

These are needed by the spec and have no mockup text. Each is listed in Open items where a decision is required.

| English (proposed) | Key | Used on |
|---|---|---|
| Registering… | `accounts.status.registering` | 8.2, 9 |
| Not saved | `account.status.unsaved` | 9 |
| Testing… | `account.test.running` | 9 |
| Registered; expires in %lld s. | `account.test.success` | 9 |
| Calling… / Ringing… | `call.state.outgoing`, `call.state.early` | 4 |
| Ringing | `call.state.ringing` | 6 |
| Microphone access is off | `call.mic.denied` | 4 |
| Name, number or account are required | `contact.error.required` | 2 |
| Delete this account? (title) and buttons | `account.delete.confirm.*` | 8.2, 9 |

---

## Open items — resolved

Resolved by the orchestrator on 2026-10-10 as routine UI decisions (none changes scope). Numbers match the writer's list.

1. **Window height.** Fixed 340×520. "Resizable height" in screen 1 is a mockup slip; ignore it.
2. **Escape in the main window.** Dialpad: clears the dial field if non-empty, otherwise nothing. Contacts: clears the search if non-empty. Call Log: nothing. During an incoming call shown in the main window, Escape silences the ringtone (does not decline).
3. **Hold button.** Toggle: label "Hold" with pause icon when the call is active, "Resume" with play icon when it is held. With several calls, pressing Resume on a held call holds the currently active one first. When the only call is held, the panel header shows "On hold" and the timer keeps running.
4. **Registering state.** Orange dot, text "Registering…"; failed = red dot + short reason; registered = green; disabled account = grey, text "Off".
5. **Status bar overflow.** Up to three accounts shown as dot + name; from the fourth onward collapse to a single summary "3/4 registered" with a tooltip listing all; clicking opens Settings › Accounts.
6. **Fifth call.** Rejected silently with 486; a call log entry is written with direction `missed` and a note "Rejected: call limit" visible in the row subtitle.
7. **Clear log confirmation.** Standard alert sheet "Clear call history?" with Cancel / Clear (destructive). No inline confirm.
8. **Last-error group.** Follows the selected account in the list. If the selected account has no error the group is hidden.
9. **Link handler.** Popup "When a sip:/tel: link is opened": "Ask before calling" (default), "Call immediately", "Only fill the dial field".
10. **Transport default for new accounts.** UDP, SRTP disabled (ADR 0009: no global defaults). The mockup's TLS/mandatory on "Office" is sample data.
11. **Attended-transfer Cancel.** Hangs up the consultation call and resumes the original call (unhold). The banner disappears.
12. **Conference count.** `[Full]` Counts remote parties only: two rows = "2 participants". Fix the mockup text when Full work starts.
13. **Incoming call inside the main window.** The window switches to the Dialpad tab automatically; the call panel shows the "incoming" state (caller, account, Answer / Decline). If the user switches to another tab while ringing, the summary bar shows "Incoming: <name>" with Answer and Decline buttons. Escape silences the ringtone.
14. **Transfer popover.** Placeholder "Number or contact"; up to 5 suggestions; Return with a highlighted suggestion picks it and performs the default action ("Transfer Now"); Return with none highlighted uses the typed text.
15. **Quality chip.** Tooltip "Codec · loss X% · jitter Y ms · RTT Z ms". No MOS.
16. **Four-call layout.** Rows are 44 pt; four rows plus controls fit in 520 pt without scrolling. Never more than four calls (ADR 0009).
17. **Contacts search keys.** Escape clears the field (second Escape leaves focus). Up/Down move the list selection while the field keeps focus; Return calls the selected contact.
18. **Watch presence default.** `[Full]` Off for new contacts.
19. **Dial letters for Russian.** Keys show Latin letters only in both locales (as on a phone keypad); no Cyrillic letters.
20. **Copy.** Contacts empty: "No contacts yet" / "Add a contact to call it in one click." Call log empty: "No calls yet". Delete account: alert "Delete account “%@”?" body "Its password is removed from Keychain. Call history is kept." buttons Cancel / Delete. Account names need not be unique; the list disambiguates with the SIP address in the subtitle. Test success: "Registered successfully (%lld ms)".
21. **Validation.** Local port 0 or 1024–65535; keep-alive 0 (off) or 5–600 s; registration expiry 60–3600 s; invalid values show a red outline and the Save button is disabled.
22. **Recording folder missing.** `[Full]` Decide when Full work starts.
23. **Menu bar icon precedence.** While a call is active the timer wins; the missed badge returns after the call ends if there are still unseen missed calls. Opening the Call Log tab clears the badge.
24. **Quick dial in the menu bar menu.** No suggestions; the field only takes a number or URI and Return calls it with the default outgoing account. Suggestions exist only in the main window.
