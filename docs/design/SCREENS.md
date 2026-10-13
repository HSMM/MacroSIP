# MacroSIP screens

Text specification of the user interface, derived from the approved mockups in `mockups.html` and the decisions in ADR 0009. This is the primary input for the SwiftUI implementation. Where this file and the mockup differ, the decision in ADR 0009 wins; where the mockup is silent, the item is listed under **Open items**.

Vocabulary follows `docs/GLOSSARY.md` (account, registration, call, active call, held call, remote party, DTMF, blind transfer, attended transfer, conference, presence, DND, auto-answer, recording).

## How to read this document

- **`[v2]`** marks anything the notes defer beyond Full or beyond v1. These are not to be built now.
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
| 2 | Account row: outgoing account pop-up button at the left, nothing else | 35 pt high (row padding 3 pt top, 10 pt sides, 6 pt bottom; button min height 26 pt) |
| 3 | Number row: number field | 46 pt high, 10 pt side padding |
| 4 | Tab control (segmented, three segments) | 36 pt high incl. padding |
| 5 | Tab body | fills the rest; 392 pt in call states |
| 6 | Status bar | 26 pt high, full width |

### Title

Title text: "MacroSIP" (`main.title`).

### Account row

The account picker is no longer in the number row. It sits in its own row above the number field.

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Outgoing account pop-up button | popup (compact pop-up button), at the left of the row, min height 26 pt | Registration dot at the left, short account name ("Office", 12.5 pt, medium, truncates with an ellipsis), chevron at the right. The dot shows that account's registration. Click opens the Account pop-up (below). Choosing an account sets the outgoing account for this call only. The initial value is the account marked "Default for outgoing calls" (see 9). Tooltip: `main.accountPicker.help`. | Disabled when there are no accounts: reads "No account" (`account.popup.none`), grey dot, dimmed (screen 10). |

### Account pop-up

Open state of the pop-up button. A menu anchored under the button, about 262 pt wide. Shown on every main-window screen.

| # | Element | Type | Behaviour |
|---|---|---|---|
| 0 | Search field (`account.popup.search`, "Search accounts"), 34 pt | search field, only with 8 or more accounts | First row, focused when the menu opens. Filters the rows while typing by name, user name, domain and registrar (case and accents ignored); "No matching accounts" when none match. |
| 1 | Header "Accounts" (`account.popup.header`) | menu header | Static. |
| 2 | Account row, one per account, in account order (see 8.2); with 8 or more accounts: enabled accounts first, then disabled ones, each group alphabetical | menu row | Disabled accounts stay in the list. 37 pt high; a long list scrolls like any menu. See the columns below. |
| 3 | Separator | | |
| 4 | "Account Settings…" (`account.popup.settings`), shortcut Command-, | menu item | Opens Settings at Accounts. |

Parts of an account row, left to right:

| Part | Content | Behaviour |
|---|---|---|
| Checkmark column | checkmark on the chosen outgoing account; empty space on the others | Read-only. |
| Registration dot | as in the dot mapping below | Read-only. |
| Name and address | name (13 pt, medium); beneath it the SIP address (11 pt, secondary), for example "andrei@pbx.example.com". A failing account shows the error in red in place of the plain address: "403 Forbidden · andrei@voip.example.org". | Clicking the name picks the outgoing account and closes the menu. |
| Switch | small switch (toggle) at the right | Turns the account on or off WITHOUT closing the menu. |

**Behaviour:**

- Off means no registration and no outgoing calls. The row stays in the list, dimmed, so the account can be turned back on, and the account leaves the status bar. A failing account is silenced in two clicks (open the menu, switch it off).
- The same on/off state is the "Enabled" switch in the account editor (screen 9) and the "Disabled" status in Settings › Accounts (screen 8.2). A disabled account keeps its settings and its Keychain item.
- The status bar items have no menu of their own; switches live only in this pop-up [decided Q1.3]. The status bar summary of many accounts (below) opens this pop-up.

### Number row

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Number field | text field, 17 pt, min height 30 pt | Accepts typed digits, letters, `+`, `*`, `#`, spaces, dashes, and pasted `sip:` or `tel:` URIs. Placeholder "Name or number". Keeps focus whenever the window is key. Return places the call (see screen 1). Letters open a suggestions dropdown (see screen 1). | Disabled when there are no accounts (dimmed). Stays enabled during a call. |

Status dot mapping for the account pop-up, status bar and Accounts table:

| Registration (glossary) | Dot | Text in status bar |
|---|---|---|
| `registered` | green | account name |
| `registering` | orange (not drawn in mockup; see Open items) | account name |
| `failed(reason)` | red | account name + ": " + short reason, in red |
| Account switched off (Enabled off) | grey, hollow | not shown: a disabled account leaves the status bar |
| `unregistered` with Register off and the account enabled ("Outgoing only") | grey, hollow | account name, grey |

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
| Reconnecting account | label with orange dot | "Office · retry in 8 s", counting down to the engine's next attempt ("Office · retrying…" at 0). Shown while the engine retries after a temporary failure (timeout, 5xx, transport error); a permanent failure stays red as before. |
| No network | grey "no Wi-Fi" glyph and "No network" | Replaces all account items while the Mac has no network path (the engine's `.network(.offline)`). Accounts come back with their own states when the path returns. |
| Settings button | gear glyph, rightmost item | Opens Settings at the last used tab; same as MacroSIP › Settings… (⌘,). Tooltip "Settings…". |
| Voicemail badge | small envelope glyph (accent colour) with the count of new messages, at the right before the Quick keys button | Shown while any account's voicemail indicator (MWI, screen 9) says messages are waiting; the count is the sum of new messages over the accounts. Tooltip "Voicemail: 2 new". Click dials the voicemail number of the first account with waiting messages (disabled when no account has a number). Hidden when nothing waits. The menu bar icon and the Dock badge are unchanged. |

The status bar is one line; items truncate without wrapping. With one to three enabled accounts there is one item per account. From four enabled accounts on, the items are replaced by one summary "4 of 6 online" (`status.summary`), followed by " · 2 failed" (`status.summary.failed`, plural) when any account failed. The summary and its dot are red when any account failed, orange while some are still connecting, otherwise green; clicking it opens the account pop-up (upward). The count is over enabled accounts only.

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
| 1 | Common frame (title, account row, number row, tabs, status bar) | See above. |
| 2 | Keypad grid | 3 columns by 4 rows, 9 pt gap. Key height 50 pt, corner radius 12 pt. |
| 3 | Action row | Three equal columns: empty (left), Call button (centre), Delete button (right). |
| 4 | ~~Hint line~~ | Removed at the owner's request (2026-10-12); Return still calls and Call with an empty field still redials (Behaviour below). |

### Elements

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Keys 1 to 9, `*`, 0, `#` | button (12 keys) | Appends the key to the number field. Each key shows its letters beneath the digit (2 ABC, 3 DEF, 4 GHI, 5 JKL, 6 MNO, 7 PQRS, 8 TUV, 9 WXYZ, 0 `+`; 1, `*`, `#` have none). Long-press on 0 inserts `+` instead of 0. | Enabled. |
| Call button | circular button, 58 pt, green, handset glyph | Places a call to the number field, normalised (see Behaviour below). With an empty field, redials the last number. | Disabled when the field is empty and there is no last number. |
| Delete button | circular ghost button, 36 pt, backspace glyph; accessibility label "Delete last digit" | Deletes the last character in the number field. Single click per character. | Disabled when the field is empty. |
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
| No accounts | Number field and account pop-up button disabled (dimmed; the button reads "No account"). Keypad is still visible, but Call is disabled; the body is replaced by the first-launch empty state (screen 10). |

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
| Presence dot | dot, 11 pt, overlaid on avatar bottom-right | Green available, yellow away, red busy or DND, grey offline or unknown. | Read-only. |
| Presence text | label, 11 pt, right of the row | "Available" or "Away" (other values: see Strings). Shown only for contacts with presence watched. | Read-only. |
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
| Watch Presence | checkmark menu item | Toggles the contact's presence subscription. Checkmark when on. | none |
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
| Watch presence (subscribe) | checkbox with label | Subscribes to presence for the contact. Default state for new contacts: see Open items. | Enabled. |
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
| Row, with a note | list row | A third line in orange: "Rejected: call limit", "Connection lost" or, in single-call mode, "Rejected: on another call" (code `busy`; a second caller turned away with 486 while you were on a call). | Enabled. |
| Play button | 20 pt round button in the row, left of the time column | Shown only when the entry has a recording that still exists. Blue disc with a white play glyph (white disc with a blue glyph on a selected row). Click opens the inline player under the row and starts playing; while playing it shows pause. Does not call back. | Enabled. |
| Inline player | compact strip under the row, 5 pt side inset, 6 pt corners, fill background | Play/pause (22 pt), elapsed `mm:ss`, scrubber (mini slider), total `mm:ss`, close (xmark). AVAudioPlayer; one player at a time (opening another row's replaces it). Leaving the tab, Clear, deleting the entry and the file disappearing close it; a ringing call pauses it. When the file cannot be opened the strip says "The recording cannot be played." | Enabled. |

**Direction icons:** incoming (answered): arrow into a corner, secondary colour. Outgoing: arrow out, secondary. Missed: red arrow dipping down, red name.

**Row double-click or Return:** calls back using the account the original call came in on (not the current outgoing account).

**Row context menu:**

| Item | Behaviour |
|---|---|
| Call | Calls back through the same account as the entry. |
| Call from ▸ | Submenu of enabled accounts. |
| Play recording / Show in Finder | Only for an entry with a recording, after a divider. Play recording opens the inline player and plays; Show in Finder selects the M4A file in Finder. |
| Add to Contacts | Opens the Contact sheet prefilled with name and number. |
| Copy Number | Copies the number or URI. |
| Delete Entry | Removes this entry without confirmation. |

**Clear confirmation** (alert sheet, 300 pt wide, app icon at top; mockup labels it "inline confirm" but the notes call it an alert; see Open items):

| Element | Behaviour |
|---|---|
| Title "Clear the call log?" | Static. |
| Body "All %lld entries are removed. Recordings stay in their folder." | Count is the number of entries. |
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
| Entry with a recording | Play button in the row; right-click adds Play recording and Show in Finder. The file is the one stored in the entry (`recordingURL`, set when the recording is saved) or, only for entries written by an older build (their recordings were saved before entries remembered them), the M4A in the recordings folder whose name (`yyyy-MM-dd HH.mm <party> (in\|out)`) has the same direction, a minute within the call and the remote party's name or number; a file is given to one entry only, the closest pairs first. The folder is scanned in the background. |
| Recording file gone | No play button. |

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
- Recording playback from the call log is built (was Q3.2 `[v2]`): play button, inline player, Show in Finder.

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
| 5 | State label, 11 pt, green, medium | "Connected" (`call.state.connected`). While recording, the red REC pill follows it on the same line: "Connected · [REC 00:08]". |
| 6 | Chip row, centred, wrapping | See chips below. The chips below in this order (account, quality, SRTP) and the speaker icon; nothing else. With one account and no SRTP the row is the quality chip and the speaker icon only; the panel is built to fit the 392 pt body with one chip row. If a long account name makes the row wrap and the content would not fit, the avatar shrinks to 36 pt and the spacing tightens. |
| 7 | Control grid | Always 3 columns, 6 buttons (Mute, Hold, Transfer, Keypad, Record, Merge). Gap 10 pt (rows) and 4 pt (columns). Pushed to the bottom of the body (`margin-top: auto`). |
| 8 | End Call button | Full width, 30 pt high, red, corner radius 8 pt, white label with hang-up glyph. Pinned at the bottom. |

**Chips:**

| Chip | Content | Behaviour |
|---|---|---|
| Account | "via %@" with account short name | Read-only. Shown only when two or more accounts are enabled (with one account it says nothing). |
| Quality | codec name and sample rate ("Opus 48 kHz") plus 4 signal bars | Bars come from the engine's call quality, polled every 2 s while the call is connected (not on hold): good = 4 green bars, fair = 3 or 2 orange bars (3 when MOS is 3.6 or more), poor = 1 red bar; dim bars until the first sample. Hover shows "Loss 0.5 % · Jitter 12 ms · RTT 48 ms · MOS 4.3" (RTT "–" while unknown). |
| SRTP | lock glyph and "SRTP" | Shown only when SRTP is actually active on the call. Tooltip "Media encrypted with SRTP". Never a "no SRTP" chip: an unencrypted call shows nothing. |
| Volume | small speaker icon (no fill, same height as the chips), always the last item of the row | Opens the call volume popover (below). In screen 5 and the conference the button sits at the right end of the header line. Tooltip "Call volume". |
| REC | red pill, white text, white dot, "REC %@" with the elapsed recording time | Shown while recording, in the state line (item 5), not in the chip row. |

**Poor connection banner** (yellow strip with a warning glyph, 11.5 pt medium, below the chip row; the avatar is hidden while it shows so the panel keeps fitting; in screen 5 it replaces the "N calls" header line; not shown in a conference): appears when the call has been `poor` for 6 s in a row, text "Poor connection: 12 % packet loss" where the reason is the worst metric (loss against 5 %, jitter against 60 ms, RTT against 400 ms; when none is past its limit: "low audio quality (MOS 2.5)"). Hidden again by the first sample that is not poor.

**Call volume popover** (250 pt wide, anchored to the speaker button):

| Element | Type | Behaviour |
|---|---|---|
| Title | label, 13 pt bold | "Call volume". |
| Speaker | slider 0 to 200 %, value on the right | Gain of what you hear. Default 100 %. Applied live to every call. |
| Microphone | slider 0 to 200 %, value on the right | Gain of what the other side hears. Default 100 %. |
| Reset | small button | Both sliders to 100 %; disabled when both are 100 %. |

The values are stored (Settings file, `audio.callSpeakerVolume` / `callMicrophoneVolume`) and are the starting volume of every new call. Command-Up / Command-Down (Call menu, while a call exists) change the speaker volume by 10 % and show the banner "Speaker volume: 110 %" for two seconds.

**Control grid buttons** (icon in a 38 pt circle, label below, 10.5 pt):

| Button | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Mute | toggle | Toggles the microphone for the active call. When on: circle filled with the inverse label colour and a mic-off glyph; label stays "Mute". | Enabled. |
| Hold | button | Holds the active call. Hold state: see Open items. | Enabled. |
| Transfer | button | Opens the transfer popover (below). | Enabled when there is a call to transfer. |
| Keypad | button | Swaps the panel for the DTMF keypad (4.2). | Enabled. |
| Record | toggle | Starts or stops recording of the active call. Circle red when on. | Enabled. |
| Merge | button | Resumes every held call and joins all answered calls into a local conference (screen 5). | Disabled with one call; enabled when two or more calls are answered, held or not. |

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
| REC chip | small red pill, "REC" | Shown while recording. |
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
| Reconnecting (media stopped, `isReconnecting`) | The state label becomes "Reconnecting… 12 s" in orange (seconds since the media stopped); in screen 5 the row subtitle shows the same text. All controls stay enabled. When the media returns the label goes back to "Connected". If it does not return the engine ends the call with "connection lost" (60 s) and the call log row gets the note "Connection lost". |
| Held (only call) | Hold control shows held state (see Open items). Timer continues. |
| Keypad | 4.2. |
| Contacts tab | 4.3. |
| Microphone access denied | Call panel shows "Microphone access is off" and a button "Open System Settings" (from the first-launch notes; not drawn; see Strings). |

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
- No volume or mic level controls in the call panel (Q4.2). Superseded: the speaker button and the call volume popover (4.1) were added with the owner's approval.
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
| Active | "Active · %@" in blue (duration) | Codec chip with bars and a red mini end button | Blue tint |
| Held | "On hold · %@" in orange | "Resume" small button (play glyph) and red mini end button | none |
| Consulting (attended transfer) | "Consulting · %@" in blue | red mini end button | Blue tint |
| In conference | "In conference" | "Split" small button and red mini end button | blue tint |

Each row's mini end button (22 pt red circle, hang-up glyph) ends that call only.

**Limits:** a fifth call is rejected with SIP 486 Busy Here. The UI message for this case is not drawn; see Open items.

**Second call behaviour:** typing a number and pressing Return during a call places a second call and holds the first. The first call moves to the held state and its row appears. This behaviour was added during the mockup review; it is not drawn in the mockup beyond the two-row state.

### 5.2 Call Log tab with a call and held calls

Summary bar (as 4.3) with the active call's name and timer, and "+1 on hold" in orange in place of the bar's muted icon. The list and the tool row sit below, as on screen 3.

### 5.3 Attended transfer in progress

Shown inside the call panel (Dialpad tab) as a state. Panel width 320 pt in the mockup.

| Element | Behaviour |
|---|---|
| Row 1: the consulting call (active) | "Andrei Kavaliou", "Consulting · 00:21", red mini end. |
| Row 2: the held original call | "Alesia Kazlouskaya", "On hold · waiting for transfer". |
| Banner | Title "Transfer Alesia Kazlouskaya to Andrei Kavaliou?" (bold); body "Alesia and Andrei will be connected and you leave both calls." |
| Cancel (small) | Cancels the transfer. Returns to the two calls with the original call active again (proposed; see Open items). |
| Complete Transfer (small, default, accent) | Completes the attended transfer (REFER with Replaces). Both remote parties are connected; the local call leg ends. |

### 5.4 Conference

Panel 320 pt wide.

| Element | Behaviour |
|---|---|
| Header | "CONFERENCE · %lld PARTICIPANTS" on the left; conference timer (tabular) on the right. |
| Participant rows | Each with avatar, name, "In conference", "Split" small button, red mini end. |
| Split | Takes that participant out of the conference as a held call. |
| mini end on a participant | Ends that leg. |
| End Conference | Full-width red button. Ends every leg. |

Merge (in 4.1) mixes all answered calls on this Mac (PJSIP conference bridge; not a server-side conference). Held calls are included: Merge resumes every held call and joins it, so the result is one conference with nobody on hold.

### States (screen 5)

| State | Appearance |
|---|---|
| One call | Screen 4. |
| Two calls, one held | 5.1. |
| Four calls | Row list shows four rows; the panel has no room for more. Exact layout at four rows: see Open items. |
| Attended transfer | 5.3. |
| Conference | 5.4. |
| Merge disabled (one call) | Merge button dimmed. Merge is enabled whenever two or more calls are answered (connected or held), unless all of them are already in the conference or an attended transfer is in progress. |

### Keyboard (screen 5)

| Key | Action |
|---|---|
| Return (number field) | Places a second call and holds the active one. |
| Return on a selected row | Not specified; see Open items. |
| Command-D | Ends the active call. |

### Decided

- At most 4 simultaneous calls (Q5.1).
- Merge joins all answered calls, held ones included (was Q5.2 `[v2]`), into a local conference; Split and End Conference as in 5.4.

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
| 5 | Auto-answer strip | See 6.5. |
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

Specified during the mockup review. Shown on the Dialpad tab in place of the call panel content, in the same 392 pt body. Layout follows 6.1, minus the window chrome:

| Element | Behaviour |
|---|---|
| Avatar, name, number | As 6.1. |
| Eyebrow "Incoming call on %@" | As 6.1. |
| State label | "Ringing" in orange (proposed). |
| Answer / Decline row | Two equal columns, 34 pt high, as 6.1. Answer is the default action for Return; Decline for Command-Period. |
| No chip row, no control grid | Hidden while ringing. |

If another tab is selected, the window keeps that tab and shows the summary bar with the incoming call's name and "Incoming" state; clicking the bar returns to the Dialpad tab (proposed; see Open items).

### 6.5 Auto-answer strip

Shown only when auto-answer will fire (mode All, or Contacts only and the caller is a contact, or a server `answer-after` header).

| Element | Type | Behaviour |
|---|---|---|
| Countdown ring | 22 pt circular progress | Drains over the delay (Settings › Calls › Auto-answer). |
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

Auto-answer never answers a second call while already on one (Settings › Calls note).

What happens to a second call is set in Settings › Calls › During a call (8.7): **Call waiting** (this window and a short tone in the earpiece instead of the ringtone), **Window only** (this window and the normal ringtone) or **Busy** (single-call mode: the caller gets 486 Busy Here at once, nothing rings, and the call log gets the entry with the note "Rejected: on another call").

With "Bring the main window to the front on an incoming call" on, the main window is ordered to the front whenever a call rings (unless Do Not Disturb rejects it), without activating MacroSIP, so nothing the user is typing in another app goes into it. The floating window appears in addition, also when the main window is frontmost. Until the user clicks into the main window, the keys that act on calls are ignored there: keypad digits (DTMF), Return in the call log and Return to answer; the hold ends with a click or when the last call ends. If the main window is already the key window of the active app, nothing is held back.

### States (screen 6)

| State | Appearance |
|---|---|
| Ringing | 6.1. |
| Ringing, auto-answer countdown | 6.1 with strip. |
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
| No network | outline handset with a slash across it; tooltip "MacroSIP · No network" | The Mac has no network path; wins over Registered and On call for the glyph (the timer and badge still show). |

State precedence when several apply: on call shows the timer; missed badge is always shown when there are unseen missed calls; moon shows when DND is on. (Precedence is a proposal; see Open items.)

Clicking the icon during a call brings the main window forward.

### 7.2 Status item menu

Native NSMenu, width about 286 pt. Structure, top to bottom:

| # | Item | Type | Behaviour | Enabled |
|---|---|---|---|---|
| 1 | Account line, one per enabled account | informational line with status dot and account name, address in secondary text at right | Click opens Settings at Accounts, that account selected. Failed line in red with "Failed: %@" (reason text, e.g. "403 Forbidden"). | Enabled. |
| 1a | Voicemail line, one per enabled account with a voicemail number (screen 9) | menu item with an envelope glyph: "Voicemail: 2 new" ("Voicemail · Office: 2 new" when several accounts have a number) | Click calls the account's voicemail number through that account. Filled envelope while messages wait. | Disabled while the account's indicator says nothing waits ("Voicemail: 0 new"). |
| 2 | separator | | | |
| 3 | Quick-dial row | text field plus green call button | Typing shows matching contacts as menu items below the field (proposed; see Open items). Return calls through the default account. Placeholder "Call number or name…". | Call disabled when the field is empty and there is no last number. |
| 4 | separator | | | |
| 5 | Section header "Recent Calls" | header | | |
| 6 | Recent calls, last 5 | menu items | Icon (direction), name or number, time at right. Missed entries in red. Click calls back through the entry's account. | Enabled. |
| 7 | separator | | | |
| 8 | Do Not Disturb | submenu item (checkmark when on) | Submenu: Off, On, divider, For 30 minutes, For 1 hour, Until tomorrow 9:00 (the coming 9:00: today when chosen between 0:00 and 9:00); checkmark on Off or On. While a timed DND runs the item title shows the time left: "Do Not Disturb · 27 min" (rounded up; "1 h 5 min" from an hour). Rejects incoming calls with 486; the status published is Do Not Disturb. When the time is up DND ends by itself and the status from before comes back. Option-Command-D (Call menu) still toggles On/Off. Timed DND survives a restart (the end time is stored). | Enabled. |
| 9 | My Status ▸ | submenu item, with the current status at right ("Available ›") | See 7.4. | Enabled. |
| 10 | separator | | | |
| 11 | Show MacroSIP | menu item, shortcut Command-0 | Brings up the main window. | Enabled. |
| 12 | Settings… | menu item, Command-comma | Opens Settings. | Enabled. |
| 13 | separator | | | |
| 14 | Quit MacroSIP | menu item, Command-Q | Quits. The title is "Quit %@" with the app name ("Quit MacroSIP"). | Enabled. |

"Show %@" and "Quit %@" use the bundle display name ("MacroSIP").

### 7.3 Dock badge

| Element | Behaviour |
|---|---|
| Dock icon badge | Red pill, count of unseen missed calls. Hidden when zero. Clears when the Call Log tab is opened. |
| Dock icon visibility | Controlled by Settings › General "Show icon in the Dock". Hidden Dock icon: the menu bar icon and the window remain. |

### 7.4 My Status submenu

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

---

## 8. Settings

Screen 08. Standard macOS Settings window: toolbar tabs, grouped forms, changes apply immediately (no Save button), window title follows the selected tab, width 680 pt (fits the Quick keys and Directory tabs, Q11.9).

### Window

| Element | Behaviour |
|---|---|
| Title | Name of the selected tab (General, Accounts, Audio, Network, Codecs, Recording, Calls, Quick keys, Directory). |
| Toolbar | Tabs with icon above label (20 pt icon, 11 pt label). Selected tab filled. |
| Tabs | General, Accounts, Audio, Network, Codecs, Recording, Calls (icon `phone.badge.waveform`), Quick keys and Directory (nine tabs, panes specified in screens 11 and 13). |
| Pane body | Grouped rows on a grey background, fixed width 680 pt, min height 380 pt, 18 pt top and 22 pt side padding. Height follows the content up to 640 pt; a taller pane scrolls (vertical scroll bar, content keeps its width) and the window stays whole on a 13-inch screen. |
| Save button | None. Changes apply immediately. |

**Grouped-form pattern** (all panes): group header above a group box (rounded 9 pt, white); rows 40 pt min height, separated by hairlines inset 12 pt; label on the left (13 pt), control on the right; optional secondary label under the row label (11.5 pt); group footer text under the box (11.5 pt, secondary).

Settings is opened from the menu (Command-comma) or the "Settings…" link on the first-launch screen.

### 8.1 General

Layout: toggles, Do Not Disturb, Language, Updates, then a collapsed "Advanced" group. Everything about calls is in the Calls tab (8.7); "Sort contacts by" is in the Directory tab (screen 13). The pane fits a 13-inch screen with Advanced closed; opened, it scrolls.

**Group 1, toggles:**

| Row | Type | Behaviour |
|---|---|---|
| Launch at login | toggle | Registers the login item. No first-run prompt [decided Q10.2]. |
| Keep running in the menu bar when the window is closed | toggle | When off, closing the window quits the app. |
| Show icon in the Dock | toggle | Hides or shows the Dock icon (see 7.3). |

**Group Do Not Disturb (no header):**

| Row | Type | Behaviour |
|---|---|---|
| Do Not Disturb (secondary label: "Declines incoming calls with 486 Busy Here and publishes Do Not Disturb.", or "Until 14:30 · 27 min left" while timed) | popup | Off, On, For 30 minutes, For 1 hour, Until tomorrow 9:00; while a timer runs its first item is the running end ("Until 14:30 · 27 min left", "Until Tue 9:00 · …" on another day) and cannot be re-picked. Same as the menu bar submenu. "Until tomorrow 9:00" is the coming 9:00: 9:00 on the next calendar day, or 9:00 today when it is chosen between 0:00 and 9:00. |

**Group 2, language:**

| Row | Type | Behaviour |
|---|---|---|
| Language (secondary label "Takes effect after MacroSIP restarts.") | popup, current value "System (English)" | Choices: System, English, Русский. Changing prompts for restart. |

Group footer: "Choices: System, English, Русский."

**Group Updates:** see ADR 0013 (automatic checks, release candidates, Check Now).

**Advanced (disclosure group, closed by default, label "Advanced", ru «Дополнительно»; the state is kept for the session):** contains the two groups below, in this order.

**Group Links (header "Links"):**

| Row | Type | Behaviour | Enabled |
|---|---|---|---|
| Open sip: and tel: links with MacroSIP (secondary label with status line) | label and button "Make Default" | Registers MacroSIP for `sip:`, `sips:` and `tel:` through Launch Services. The status line (warning dot, orange) says which other app owns `tel:` when it is not MacroSIP: "Another app currently handles tel: links." | Enabled. |
| When a link is opened (secondary "Fills the number field so you can check it first.") | popup, current value "Ask before calling" | Ask before calling / Call immediately / Only fill the number. "Ask before calling" fills the number field; it does not place the call. | Enabled. |

**Group Troubleshooting (header "Troubleshooting"):** Open Log Folder (reveals the log in Finder), Copy Diagnostics (versions, macOS, accounts without passwords, settings).

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
| Status | "Registered", "403" (short reason, in red), "Disabled" (grey; the account is switched off), "Outgoing only" (grey; enabled, "Register with server" off) | 70 pt |

Rows: one per account, drag to reorder. Order is used in the account pop-up (up to 7 accounts; with 8 or more the pop-up sorts by state and name). With 8 or more accounts a filter field (`accounts.filter`, "Filter accounts") sits above the table and narrows the rows by name, user name, domain and registrar; dragging is off while a filter is typed. Selected row: blue, white text.

Table footer: "+" (add account), "−" (remove account, confirms), "Edit…" (opens the account editor sheet, 9). Group footer: "Double-click an account to edit it. Drag to reorder; the order is used in the account pop-up and the status bar."

**Last error group** (header "Backup · last error", i.e. the account name and the word "last error"):

| Row | Content | Element |
|---|---|---|
| Error label | "403 Forbidden" (monospaced), second line "REGISTER rejected at %@. Check the username and password." | label |
| Retry | button | Re-attempts registration for the account. |

**Behaviour:**

- Status updates live.
- Double-click an account: opens the editor (9).
- "−" with a row selected: confirmation before deleting; also removes the Keychain item (see Open items for the wording).
- Switching an account off (the switch in the account pop-up, or "Enabled" in the editor) shows it as Disabled here. Unchecking "Register with server" on an enabled account shows it as Outgoing only.
- Only one account is the default outgoing account; setting another as default clears the previous one (in the editor).

**States:**

| State | Appearance |
|---|---|
| No accounts | Table empty with message `accounts.empty` (proposed). "−" and "Edit…" disabled. Last error group hidden. |
| Registered | Green dot, "Registered". |
| Failed | Red dot, "403" (or short reason), last error group visible for that account. |
| Disabled | Grey hollow dot, "Disabled". The account is switched off (no registration, no outgoing calls). |
| Outgoing only | Grey hollow dot, "Outgoing only". Enabled, "Register with server" off. |
| Registering | Orange dot (proposed; not drawn); see Open items. |

**Keyboard:** Return edits the selected row (proposed; double-click is drawn). Delete key removes the selected row after confirmation (proposed).

**Decided:** Accounts pane lists accounts with live status; add, remove, edit; last error with Retry (ADR 0009).

### 8.3 Audio

Layout: six groups: Devices, Ringtone, Hold music, Sound events, Audio test, Processing.

**Devices:**

| Row | Type | Behaviour | Notes |
|---|---|---|---|
| Microphone | level meter (8 segments) and popup | Meter is live while this pane is open. Popup lists input devices plus "System default". | Meter: green segments, the top segment yellow when near clipping. |
| Speaker | popup | Lists output devices plus "System default". The test tone moved to the Audio test group. | |
| Ringtone device (secondary "Ring through the speakers even when a headset is used for calls.") | popup | Output for the ringtone only. Shows "MacBook Pro Speakers" in the mockup. | |
| Switch to a headset when it is connected (secondary "Uses a newly connected headset for calls until it is unplugged.") | toggle | On by default. A device that appears with both input and output becomes the microphone and the speaker (the chosen names above stay as they are) and a banner "Switched to AirPods Pro" shows for 4 s. When it is unplugged the chosen devices come back ("Back to MacBook Pro Speakers"; "Back to the system default" when none was chosen). Picking a microphone or speaker by hand, or switching this off, ends the following. The ringtone device is never changed. Devices already present at start are not followed. | on |
| Headset buttons (secondary "Connected: Jabra Evolve2 65" or "No headset with call controls") | toggle | On by default. Answer, hang up, hold, mute and redial from the HID telephony buttons of a USB headset; the headset's LEDs follow the call. Off releases the devices. The secondary text names the connected headset. | on |

Group footer: "System default" follows macOS Sound settings. If a chosen device is unplugged, MacroSIP falls back to the system default and switches back when it returns.

**Ringtone:**

| Row | Type | Behaviour |
|---|---|---|
| Sound | "Play" small button with a play glyph, and popup | Popup: Classic, Digital, Soft (built-in), a separator, and "Custom file…". The mockup shows "Custom: office-bell.m4a". "Play" previews the sound. |
| Volume | slider with speaker glyph (160 pt wide) and the value ("100 %") | Ringtone volume, 0 to 100 %, default 100 %. Applied live; "Play" previews at this volume. |

Group footer: "Built-in choices: Classic, Digital, Soft. "Custom file…" accepts WAV, AIFF, M4A, MP3."

**Hold music:**

| Row | Type | Behaviour |
|---|---|---|
| Source | popup | Built-in (a short looping melody, default), "Custom: office-hold.m4a" when a file was chosen, "Custom file…" (open panel: WAV, AIFF, M4A, MP3 and anything else AVFoundation reads; the engine converts it once), a separator, Off (silence). Applied at once, also to calls already on hold. |

Group footer: "The caller hears this while on hold." A file the engine cannot read keeps the previous source; the footer then shows "The file could not be used: <reason>" and a banner says the same.

**Sound events** (all off by default; short beeps on the speaker, never sent to the call or the recording):

| Row | Type | Behaviour |
|---|---|---|
| Call connected and ended | toggle | Two rising beeps when a call connects (not after a resume from hold), two falling beeps when a call the window showed ends. |
| Dial pad key presses | toggle | The DTMF tone of the key pressed on the dial pad while no call is active ("+" has no tone). During a call the key pad sends DTMF instead. |
| New voicemail | toggle | Three beeps when an account's indicator reports more new messages than before. |
| Registration error and lost network | toggle | Two low beeps when a registration fails or the network path goes away; at most once every 10 seconds. |

Group footer: "Short beeps on the speaker; the other side never hears them."

**Audio test:**

| Row | Type | Behaviour |
|---|---|---|
| Speaker and microphone (secondary "Test plays two notes on the speaker for 2 seconds; the meter shows the microphone.") | level meter (8 segments) and "Test" small button | Test plays two notes (660 and 880 Hz) for 2 seconds on the speaker chosen above (system default = the call output); a second press restarts it. The meter is the live microphone level, the same as in the Microphone row. |

**Processing:**

| Row | Type | Behaviour |
|---|---|---|
| Echo cancellation (secondary "Turn off only when using a headset with its own echo cancellation.") | toggle | On by default. |

**Keyboard:** none beyond standard.

**States:** device list updates live when devices are plugged or unplugged. Missing device shows the fallback (footer rule above). Hold music file refused: footer in the group names the reason, the popup keeps the previous choice.

**Decided:** echo cancellation lives in Audio (ADR 0009, Q8.1).

### 8.4 Network

Layout: three groups (Connection, RTP, DNS), then an info note; a restart banner appears above the groups when needed.

**Connection:**

| Row | Type | Behaviour | Default / example |
|---|---|---|---|
| STUN server (secondary "Leave empty if you are not behind NAT.") | text field, min width 220 pt | Host and optional port. Empty disables STUN. | "stun.example.org:3478" |
| Local SIP port (secondary "0 picks a free port automatically.") | number field, 70 pt, with stepper | Range 0 to 65535. 0 picks a free port. Changing it re-registers all accounts. | 5060 |
| Keep-alive interval (secondary "Keeps NAT bindings open between registrations.") | number field, 50 pt, stepper, unit "seconds" | Positive integer. | 15 |
| Use ICE (secondary "Finds a working media path through NAT. Uses the STUN server above.") | toggle | On by default. | on |

**RTP (header "RTP"):**

| Row | Type | Behaviour | Default |
|---|---|---|---|
| Port range (secondary "Audio uses this range. Each call needs two ports; 1024–65535.") | two number fields with steppers, 56 pt each, labelled "Start" and "Ports" | Start 1024 to 65535, at least 8 ports, the last port not past 65535. An invalid value outlines the field red while it has the focus and reverts on blur. Applies after an engine restart. | 4000, 1000 |
| Use rport (secondary "Asks the server to reply to the address and port it sees. Helps behind NAT.") | toggle | Applies at once. | on |

**DNS (header "DNS"):**

| Row | Type | Behaviour | Default |
|---|---|---|---|
| Use DNS SRV records (secondary "Finds the server and port of an account through SRV records, then falls back to the domain itself.") | toggle | Applies after an engine restart. | off |
| Nameserver (secondary "Address of a DNS server. Empty uses the system's servers.") | text field, 220 pt, placeholder "System" | Enabled only while SRV is on. Empty = system servers. Applies after an engine restart. | empty |

**Restart banner:** when `applyNetworkSettings` answers `needsRestart`, an orange-tinted box above the groups says "Network changes are waiting for a restart of the engine. Accounts register again." with a "Restart now" button. The button stops and starts the engine (accounts register again); it is disabled while a call is active, with the line "End your calls first.". The banner goes away after the restart.

**Info note (no box, secondary text with info glyph):** "Changing the port re-registers all accounts. Calls in progress are not interrupted. Transport and SRTP are set per account in the account editor." and, in a second line, "Changes to the port range and DNS apply after a restart of the engine."

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

These four codecs come first [decided Q8.3]. Seven more follow, all off until turned on (the stored order of older settings gets them appended):

| Codec | Checked | Sample rate | Bitrate |
|---|---|---|---|
| G.722.1 (Siren 7) | off | 16 kHz | 16–32 kbit/s |
| G.722.1C (Siren 14) | off | 32 kHz | 24–48 kbit/s |
| GSM | off | 8 kHz | 13 kbit/s |
| iLBC | off | 8 kHz | 13–15 kbit/s |
| Speex 8 kHz | off | 8 kHz | 2–25 kbit/s |
| Speex 16 kHz | off | 16 kHz | 4–42 kbit/s |
| Speex 32 kHz | off | 32 kHz | 4–44 kbit/s |

Restore Defaults puts the order back (classic four, then the new ones) and turns on Opus, G.722 and PCMU only. Second footer line: "Wideband codecs (Opus, G.722, G.722.1, Speex 16 and 32 kHz) work only if the PBX supports them."

A second group "Opus" (footer: "Packet-loss correction adds a little data so lost packets can be repaired; keep it on for Wi-Fi and mobile networks. Silence suppression sends nothing during pauses to save bandwidth, but can clip the start of a word; turn it on only when bandwidth is tight."):

| Row | Type | Behaviour | Default |
|---|---|---|---|
| Packet-loss correction (FEC) | toggle | Opus in-band forward error correction. | on |
| Silence suppression (DTX) | toggle | Opus discontinuous transmission. | off |

Both rows are disabled while Opus is unchecked. Changes apply to the running engine at once (new and re-negotiated streams); stored as `codecOptions`.

Footer: "Move up" and "Move down" icon buttons (chevron), "Restore Defaults" small button on the right.

Group header: "Audio codecs, in order of preference". Group footer: "Drag rows or use the arrows to reorder. Unchecked codecs are never offered. At least one codec must stay enabled."

**Behaviour:**

- Order sets SDP preference.
- Unchecking a codec removes it from offers. At least one must stay checked: unchecking the last one is refused (control disabled).
- Bitrate and sample rate are informational.
- Restore Defaults restores the four rows above, in that order, all checked except PCMA (proposed; see Open items).

**Keyboard:** Option-Up / Option-Down moves the selected row (proposed; not drawn).

### 8.6 Recording

Layout: three groups.

| Row | Type | Behaviour |
|---|---|---|
| Save recordings to | popup with folder icon, current "MacroSIP Recordings" | Choose folder; the picker remembers access with a security-scoped bookmark. |
| Record all calls automatically | toggle, off | When on, every call is recorded. |
| Channels | native segmented control "Mono" / "Stereo" (160 pt), default Mono; the row's secondary text describes the selected option ("Both sides mixed into one channel." / "You on the left channel, the caller on the right.") | Applies to recordings that start after the change. Stereo keeps you on the left channel and the caller (every conference participant) on the right; the temporary files are one WAV per side, converted into a single stereo M4A. If the conversion fails, every WAV is kept in the recordings folder (`<name>.wav` for mono, `<name>-local.wav` and `<name>-remote.wav` for stereo). |

Group footer: "Recordings are saved as M4A (AAC), mono or stereo with you on the left channel and the caller on the right. The temporary WAV files are deleted after conversion." then "File name: 2026-10-10 14.52 Alesia Kazlouskaya (in).m4a" (monospaced). Format: date and time to minutes, remote party name, direction in parentheses ("in" or "out").

**Notice tone** (second group):

| Row | Type | Behaviour |
|---|---|---|
| Play a notice tone while recording | toggle, off | A short 1400 Hz beep heard by both sides and written into the recording, one second after a recording starts and then every interval. Applies to recordings in progress too. |
| Every | number field (56 pt) with stepper, unit "seconds" | 5 to 60, steps of 5, default 15; dimmed while the switch is off. |

Group footer: "A short beep every 15 seconds tells both sides that the call is recorded." (the number follows the field).

Third group:

| Row | Type | Behaviour |
|---|---|---|
| Show Recordings Folder | button "Open in Finder" | Opens the folder in Finder. |

Notes: a Record button is always available in the call panel even when automatic recording is off.

**States:** folder missing: popup shows the folder name with a warning; choose again (proposed).

### 8.7 Calls

Tab "Calls" (ru «Звонки»; formerly "Auto-answer"; SF Symbol `phone.badge.waveform`). Three groups in this order, then the auto-answer footer.

**Group Incoming calls (header "Incoming calls"):**

| Row | Type | Behaviour |
|---|---|---|
| Reject calls from (secondary: "A rejected call never rings. The caller gets 603 Decline and the call log shows “Rejected: rule”.") | popup, 220 pt, default Nobody | Nobody / Everyone / Numbers not in Contacts / Anonymous callers. Applies at once (`CallOptions.denyIncoming`). "Numbers not in Contacts" compares the caller with every number of every contact (`CallOptions.knownNumbers`, kept in sync whenever contacts change). The engine answers 603 Decline (433 Anonymity Disallowed for anonymous callers) before anything rings, so the app only sees the call end; the call log gets a missed entry with the note "Rejected: rule". Calls placed by the user are not affected. |

**Group During a call (header "During a call", ru «Во время звонка»):**

| Row | Type | Behaviour |
|---|---|---|
| When a call comes in during a call | popup, default "Call waiting (tone and window)" | Call waiting (tone and window) / Window only / Busy (single-call mode). Applies at once, also during calls. Secondary label explains Busy (486 Busy Here, only the call log shows it). |
| DTMF method (secondary: "Automatic uses RFC 2833 and falls back to SIP INFO.") | popup, default Automatic | Automatic / RFC 2833 / SIP INFO / In-band. The next digits use the new method. |
| Bring the main window to the front on an incoming call (secondary: "The incoming-call window still appears as well.") | toggle, default off | When on, the main window is brought to the front (not activated) when a call rings, in addition to the floating window; call keys stay ignored in it until the user clicks into it (see 6.6). |

**Group Auto-answer (header "Auto-answer", ru «Автоответ»):**

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

Screen 09. Sheet on Settings › Accounts. 500 pt wide (460 in the mockup; widened so the Russian button labels fit). Opens from "+", "Edit…" and double-click. Title "Edit Account" for existing accounts (`account.title.edit`); "New Account" for new (proposed).

### Layout (top to bottom)

Only the basics are visible; everything else sits in a collapsible "Advanced" section.

| # | Section | Content |
|---|---|---|
| 1 | Title | "Edit Account", 13 pt bold. |
| 2 | Basics group | Account name, SIP server, Username, Password, Enabled. |
| 3 | Advanced (disclosure, label 13 pt semibold, collapsed by default) | Groups: Profile (Display name); Server (Auth username, Domain, Outgoing proxy); Connection (Transport, Media encryption (SRTP), Registration expiry, Verify server certificate with TLS); switches (Register with server, Default for outgoing calls, Publish my presence). |
| 4 | Button row | Delete Account…, Test, status text, Cancel, Save. |

**Advanced section:** closed for a new account and for an account whose advanced fields are all at their defaults (no display name, no auth username, domain equals the server, no proxy, UDP, SRTP disabled, expiry 300 s, Register on, not the default among several accounts, presence publishing off, certificate verification on). It opens by itself, so the user can see why an account behaves as it does, when any of them differs. The user's own open or close is remembered until the app quits and applies to the next editor. The sheet is 430 pt high while it is closed and 640 pt (470 pt in the main window) when open; the content scrolls. Validation and Test work whether it is open or not.

### Elements

Rows of the basics group are listed first; the others are inside Advanced.

| Element | Type | Behaviour | Required | Default |
|---|---|---|---|---|
| Account name (secondary: none) | text field | Short label used in the account pop-up, status bar, call panel and menu bar ("Office"). | Yes (proposed; mockup gives it no marker) | empty |
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
| Voicemail number (secondary "Dialled from the menu bar and the status bar.") | text field, placeholder "*97" | Number or SIP URI the app dials for the voicemail items (menu bar, status bar badge). Group "Voicemail" in Advanced. | No | empty |
| Voicemail indicator (MWI) (secondary "Shows the number of new messages the server reports.") | toggle | Subscribes to the server's message-summary; new messages show in the status bar badge and the menu bar item. A server that pushes the indicator without a subscription is shown too. | | on |
| Enabled (secondary "Off stops registration and outgoing calls; the account stays in the pop-up, dimmed, and leaves the status bar.") | toggle | First row of the switches group. The same state as the switch in the account pop-up on the main window. Off: no registration and no outgoing calls; shown as Disabled in Settings › Accounts. The account keeps its settings and its Keychain item. | | on |
| Register with server (secondary "Off keeps the account for outgoing calls only.") | toggle | Off: the account does not register, so it takes no incoming calls; it is still used for outgoing calls and shows as Outgoing only in Settings › Accounts. | | on |
| Default for outgoing calls | toggle | Only one account is default; turning on clears the previous one. | | on in mockup |
| Publish my presence (secondary "Lets contacts who watch you see Available / Away / DND.") | toggle | Per-account presence publish. | | on in mockup |
| Delete Account… | button, destructive | Asks for confirmation; removes the account and its Keychain item. | | |
| Test | button | Registers once with the values in the sheet, without saving; shows the result inline (9.2). | Enabled when Server, Username and Password are filled. | |
| Status text | label, with a dot | Live registration status of the saved account ("Registered"). For a new account: "Not saved". | | |
| Cancel | button | Closes without saving. Escape. | | |
| Save | button, default (accent) | Validates; stores password in Keychain; saves; re-registers; closes. | Enabled when valid. | |

**Behaviour:**

- Save validates the fields, stores the password in the Keychain and re-registers. The status beside the buttons updates live.
- Test does not save anything. It uses a temporary registration.
- Delete asks for confirmation and removes the Keychain item too.
- "Enabled" off keeps everything stored (settings, Keychain item); only registration and outgoing calls stop.
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
| 1 | Common frame | Account pop-up button reads "No account" (dimmed). Number field disabled. Tabs enabled. |
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

After Save in the editor, the empty state disappears and the Dialpad body (screen 1) becomes live. The account pop-up button and number field become enabled.

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

Every user-visible English string in the mockups and notes. Keys are the `.strings` keys (dot notation; `Sources/MacroSIPApp/Resources/{en,ru}.lproj`) (camelCase segments). Placeholders use `%@` (string) and `%lld` (integer); numbered `%1$@` form is required where a translation changes word order. Column **Ed.** marks strings.

Strings marked "(proposed)" are not in the mockups; they are needed by the spec and are in the Open items list where a decision is needed. Strings shown only as sample data (e.g. "Alesia Kazlouskaya", "+7 912 555-01-23", "pbx.example.com") are not strings and are not listed.

### Common and main window

| Ed. | English | Key | Notes |
|---|---|---|---|
| | MacroSIP | `main.title` | Window title. |
| | Dialpad | `tabs.dialpad` | |
| | Contacts | `tabs.contacts` | |
| | Call Log | `tabs.callLog` | |
| | Name or number | `main.numberField.placeholder` | |
| | Outgoing account | `main.accountPicker.help` | Tooltip. |
| | Accounts | `account.popup.header` | Account pop-up header. |
| | Account Settings… | `account.popup.settings` | Account pop-up item, ⌘,. |
| | No account | `account.popup.none` | Pop-up button label when there are no accounts; dimmed. |
| | No accounts | `status.noAccounts` | Status bar. |
| | %@: %@ | `status.account.failed` | Account name, short reason; red. |
| | Settings… | `menu.settings` | Shown in status bar in first launch as "Settings… ⌘,". |
| | Show %@ | `menu.showApp` | Menu bar item; %@ app name. |
| | Quit %@ | `menu.quitApp` | Menu bar item; %@ app name. |
| | %1$lld of %2$lld online | `status.summary` | Status bar summary (4+ enabled accounts). |
| | %lld failed | `status.summary.failed` | Plural; appended after " · " when any failed. |
| | Search accounts | `account.popup.search` | Pop-up search placeholder. |
| | No matching accounts | `account.popup.noMatches` | |
| | Filter accounts | `accounts.filter` | Settings › Accounts filter placeholder. |

### 1 Dialpad

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Call | `dialpad.call.help` | Accessibility label of the Call button. |
| | Delete last digit | `dialpad.delete.help` | Accessibility label. |
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
| | Watch Presence | `contacts.menu.watchPresence` | Checkmark item. |
| | Delete | `contacts.menu.delete` | |
| | Delete %@? | `contacts.delete.confirm` | %@ contact name. |
| | Delete | `common.delete` | Destructive button. |
| | Cancel | `common.cancel` | |
| | Available | `presence.available` | Presence text and menu. |
| | Away | `presence.away` | |
| | Do Not Disturb | `presence.dnd` | |
| | Edit Contact | `contact.edit.title` | Sheet title. |
| | New Contact | `contact.new.title` | Proposed. |
| | Name | `contact.field.name` | |
| | Number | `contact.field.number` | |
| | Account | `contact.field.account` | |
| | Any (use default) | `contact.account.any` | |
| | Watch presence (subscribe) | `contact.watchPresence` | Checkbox. |
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
| | Play recording | `calllog.recording.play` | Play button help and context menu. |
| | Pause | `calllog.recording.pause` | |
| | Close player | `calllog.recording.close` | |
| | Show in Finder | `calllog.recording.showInFinder` | Context menu. |
| | The recording cannot be played. | `calllog.recording.failed` | In the inline player. |
| | Playback position | `calllog.recording.position` | Accessibility label of the scrubber. |
| | Rejected: on another call | `calllog.note.busy` | Note of a call turned away in single-call mode. |
| | Clear the call log? | `calllog.clear.title` | Alert title. |
| | All %lld entries are removed. | `calllog.clear.body` | |
| | Recordings stay in their folder. | `calllog.clear.bodyRecordings` | Second sentence of the body. |
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
| | Loss %1$@ · Jitter %2$@ · RTT %3$@ · MOS %4$@ | `call.quality.details` | Quality tooltip. |
| | Good connection, Fair connection, Poor connection | `call.quality.level.good`, `.fair`, `.poor` | Tooltip / accessibility. |
| | Poor connection: %@ packet loss | `call.quality.poor.loss` | Banner. %@ e.g. "12 %". |
| | Poor connection: high jitter (%@) | `call.quality.poor.jitter` | Banner. |
| | Poor connection: high latency (%@) | `call.quality.poor.rtt` | Banner. |
| | Poor connection: low audio quality (MOS %@) | `call.quality.poor.mos` | Banner. |
| | %@ %, %@ ms | `unit.percent`, `unit.ms` | Units ("мс" in Russian). |
| | Call volume | `call.volume.title` | Button tooltip and popover title. |
| | Reset | `call.volume.reset` | |
| | Speaker volume: %@ | `banner.volume.speaker` | |
| | Speaker Volume Up, Speaker Volume Down | `menu.volumeUp`, `menu.volumeDown` | Call menu, Command-Up / Command-Down. |
| | SRTP | `call.srtp.label` | |
| | Media encrypted with SRTP | `call.srtp.help` | Tooltip. |
| | REC %@ | `call.rec.chip` | %@ elapsed time. |
| | Mute | `call.mute` | |
| | Hold | `call.hold` | |
| | Transfer | `call.transfer` | |
| | Keypad | `call.keypad` | |
| | Record | `call.record` | |
| | Merge | `call.merge` | |
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
| | Reconnecting… %lld s | `call.state.reconnecting` | Orange state label while the media is missing. |
| | No network | `status.noNetwork`, `menubar.state.noNetwork.help` | Status bar and menu bar tooltip. |
| | %1$@ · retry in %2$lld s | `status.account.retry` | Status bar item of a reconnecting account. |
| | %@ · retrying… | `status.account.retrying` | Same, at 0 s. |
| | Reconnecting… | `accounts.status.reconnecting` | Account status in lists and the editor. |
| | Connection lost | `calllog.note.connectionLost` | Call log note. |

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
| | In conference | `calls.row.inConference` | |
| | Split | `calls.split` | |
| | +1 on hold | `callbar.moreHeld` | See 4; plural form. |
| | Transfer %@ to %@? | `transfer.banner.title` | Alesia to Andrei. |
| | %@ and %@ will be connected and you leave both calls. | `transfer.banner.body` | |
| | Cancel | `common.cancel` | |
| | Complete Transfer | `transfer.complete` | Default button. |
| | CONFERENCE · %lld PARTICIPANTS | `conference.header` | Displayed uppercase. |
| | End Conference | `conference.end` | |

### 6 Incoming call

| Ed. | English | Key | Notes |
|---|---|---|---|
| | Incoming call on %@ | `incoming.eyebrow` | %@ account name. |
| | Answer | `incoming.answer` | |
| | Decline | `incoming.decline` | |
| | Incoming call · %@ | `incoming.notification.title` | %@ account name. |
| | Auto-answer in %lld s | `incoming.autoAnswer.countdown` | |
| | Cancel | `incoming.autoAnswer.cancel` | Link-style button. |
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
| | Do Not Disturb | `menu.dnd` | Submenu title (Option-Command-D in the Call menu). Also the label in Settings. |
| | Do Not Disturb · %@ | `menu.dnd.remaining` | Title while timed; %@ is "27 min", "1 h", "1 h 5 min". |
| | Off / On | `dnd.off`, `dnd.on` | Submenu and Settings popup. |
| | For 30 minutes / For 1 hour | `dnd.minutes30`, `dnd.hour1` | |
| | Until tomorrow 9:00 | `dnd.tomorrow` | |
| | %lld min / %lld h / %1$lld h %2$lld min | `duration.minutes`, `duration.hours`, `duration.hoursMinutes` | Short durations. |
| | My Status | `menu.myStatus` | Submenu title. |
| | Available › | `menu.myStatus.current` | Shows current value at right. |
| | Away | `menu.status.away` | Submenu item (Full). |
| | Available | `menu.status.available` | Submenu item (Full). |
| | Do Not Disturb | `menu.status.dnd` | Submenu item. |
| | Show %@ | `menu.showApp` | Repeated from Common; Command-0. |
| | Settings… | `menu.settings` | Command-comma. |
| | Quit %@ | `menu.quitApp` | Command-Q. |
| | Offline | `menubar.state.offline.help` | Accessibility; proposed. |
| | Voicemail | `menu.voicemail` | Menu item and status bar tooltip prefix; "Voicemail · Office" when several accounts have a number. |
| | %lld new | `voicemail.newCount` | Plural (stringsdict); after "Voicemail: ". |

### 8 Settings

| Ed. | English | Key | Notes |
|---|---|---|---|
| | General | `settings.tab.general` | Toolbar and title. |
| | Accounts | `settings.tab.accounts` | |
| | Audio | `settings.tab.audio` | |
| | Network | `settings.tab.network` | |
| | Codecs | `settings.tab.codecs` | |
| | Recording | `settings.tab.recording` | |
| | Calls | `settings.tab.calls` | Tab (formerly Auto-answer). |
| | Launch at login | `settings.general.launchAtLogin` | |
| | Keep running in the menu bar when the window is closed | `settings.general.keepRunning` | |
| | Show icon in the Dock | `settings.general.showInDock` | |
| | During a call | `settings.calls.duringCall.header` | Group header (Calls tab). |
| | Auto-answer | `settings.autoAnswer.header` | Group header (Calls tab). |
| | Advanced | `settings.general.advanced.header` | Disclosure group at the bottom of General. |
| | Until %1$@ · %2$@ left | `settings.general.dnd.until` | Settings DND row while timed (time, remaining). |
| | Declines incoming calls with 486 Busy Here and publishes Do Not Disturb. | `settings.general.dnd.help` | |
| | When a call comes in during a call | `settings.general.calls.incomingWhileOnCall` | |
| | Busy answers the second caller with 486 Busy Here; you see nothing of it except in the call log. | `settings.general.calls.incomingWhileOnCall.help` | |
| | Call waiting (tone and window) / Window only / Busy (single-call mode) | `settings.general.calls.waiting`, `.windowOnly`, `.busy` | Popup values. |
| | DTMF method | `settings.general.calls.dtmf` | |
| | Automatic uses RFC 2833 and falls back to SIP INFO. | `settings.general.calls.dtmf.help` | |
| | Automatic / In-band | `settings.general.calls.dtmf.automatic`, `.inBand` | "RFC 2833" and "SIP INFO" are not translated. |
| | Bring the main window to the front on an incoming call | `settings.general.calls.bringToFront` | |
| | The incoming-call window still appears as well. | `settings.general.calls.bringToFront.help` | |
| | Incoming calls | `settings.general.deny.header` | Group header. |
| | Reject calls from | `settings.general.deny.label` | |
| | A rejected call never rings. The caller gets 603 Decline and the call log shows “Rejected: rule”. | `settings.general.deny.help` | |
| | Nobody / Everyone / Numbers not in Contacts / Anonymous callers | `settings.general.deny.nobody`, `.everyone`, `.notInContacts`, `.anonymous` | Popup values. |
| | Rejected: rule | `calllog.note.denied` | Call log note of a call turned away by the rule. |
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
| | Accounts list header and footer: "Double-click an account to edit it. Drag to reorder; the order is used in the account pop-up and the status bar." | `accounts.list.footer` | |
| | Name, Address, Transport, Status | `accounts.column.name`, `accounts.column.address`, `accounts.column.transport`, `accounts.column.status` | Table headers. |
| | Default | `accounts.badge.default` | |
| | Registered | `accounts.status.registered` | |
| | Disabled | `accounts.status.disabled` | Account switched off. |
| | Outgoing only | `accounts.status.outgoingOnly` | Enabled, "Register with server" off. |
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
| | Switch to a headset when it is connected | `settings.audio.followNewDevices` | |
| | Uses a newly connected headset for calls until it is unplugged. | `settings.audio.followNewDevices.help` | |
| | Switched to %@ | `banner.audio.switched` | |
| | Back to %@ | `banner.audio.back` | |
| | Back to the system default | `banner.audio.backDefault` | |
| | Built-in choices: Classic, Digital, Soft. "Custom file…" accepts WAV, AIFF, M4A, MP3. | `settings.audio.ringtone.footer` | |
| | Processing | `settings.audio.processing.header` | |
| | Echo cancellation | `settings.audio.echoCancellation` | |
| | Turn off only when using a headset with its own echo cancellation. | `settings.audio.echoCancellation.help` | |
| | Headset buttons | `settings.audio.headsetButtons` | |
| | Connected: %@ | `settings.audio.headsetButtons.connected` | %@ device name. |
| | No headset with call controls | `settings.audio.headsetButtons.none` | |
| | Hold music | `settings.audio.holdMusic.header` | |
| | Source | `settings.audio.holdMusic.source` | |
| | Built-in, Off | `settings.audio.holdMusic.builtIn`, `.off` | Popup items; "Custom file…" and "Custom: %@" are reused from the ringtone. |
| | The caller hears this while on hold. | `settings.audio.holdMusic.footer` | |
| | The file could not be used: %@ | `settings.audio.holdMusic.error` | Footer and banner; %@ reason. |
| | Sound events | `settings.audio.soundEvents.header` | |
| | Call connected and ended | `settings.audio.soundEvents.callEvents` | |
| | Dial pad key presses | `settings.audio.soundEvents.keyPress` | |
| | New voicemail | `settings.audio.soundEvents.voicemail` | |
| | Registration error and lost network | `settings.audio.soundEvents.error` | |
| | Short beeps on the speaker; the other side never hears them. | `settings.audio.soundEvents.footer` | |
| | Audio test | `settings.audio.audioTest.header` | |
| | Speaker and microphone | `settings.audio.audioTest.row` | |
| | Test plays two notes on the speaker for 2 seconds; the meter shows the microphone. | `settings.audio.audioTest.help` | |
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
| | RTP | `settings.network.rtp.header` | |
| | Port range | `settings.network.rtp.portRange` | |
| | Audio uses this range. Each call needs two ports; 1024–65535. | `settings.network.rtp.portRange.help` | |
| | Start, Ports | `settings.network.rtp.start`, `.count` | Labels of the two number fields. |
| | Use rport | `settings.network.rport` | |
| | Asks the server to reply to the address and port it sees. Helps behind NAT. | `settings.network.rport.help` | |
| | DNS | `settings.network.dns.header` | |
| | Use DNS SRV records | `settings.network.dns.srv` | |
| | Finds the server and port of an account through SRV records, then falls back to the domain itself. | `settings.network.dns.srv.help` | |
| | Nameserver | `settings.network.dns.nameserver` | |
| | Address of a DNS server. Empty uses the system's servers. | `settings.network.dns.nameserver.help` | |
| | System | `settings.network.dns.nameserver.placeholder` | Placeholder. |
| | Changes to the port range and DNS apply after a restart of the engine. | `settings.network.restartFooter` | |
| | Network changes are waiting for a restart of the engine. Accounts register again. | `settings.network.restart.banner` | |
| | Restart now | `settings.network.restart.now` | |
| | End your calls first. | `settings.network.restart.busy` | |
| | Audio codecs, in order of preference | `settings.codecs.header` | |
| | Codec, Sample rate, Bitrate | `settings.codecs.column.codec`, `.sampleRate`, `.bitrate` | Table headers. |
| | PCMU (G.711 µ-law), PCMA (G.711 A-law) | `settings.codecs.pcmu`, `settings.codecs.pcma` | Codec names; G.711 variants. |
| | Move up, Move down | `settings.codecs.moveUp`, `settings.codecs.moveDown` | Tooltips. |
| | Restore Defaults | `settings.codecs.restoreDefaults` | |
| | Opus | `settings.codecs.opus.header` | |
| | Packet-loss correction (FEC) | `settings.codecs.opus.fec` | |
| | Silence suppression (DTX) | `settings.codecs.opus.dtx` | |
| | Packet-loss correction adds a little data ... only when bandwidth is tight. | `settings.codecs.opus.footer` | Full text in 8.5. |
| | Drag rows or use the arrows to reorder. Unchecked codecs are never offered. At least one codec must stay enabled. | `settings.codecs.footer` | |
| | Wideband codecs (Opus, G.722, G.722.1, Speex 16 and 32 kHz) work only if the PBX supports them. | `settings.codecs.footer.wideband` | Codec names (G.722.1, GSM, iLBC, Speex) are not translated. |
| | Save recordings to | `settings.recording.folder` | |
| | MacroSIP Recordings | `settings.recording.folderName` | Default folder name. |
| | Record all calls automatically | `settings.recording.auto` | |
| | Channels | `settings.recording.layout` | |
| | Mono | `settings.recording.layout.mono` | Segment. |
| | Stereo | `settings.recording.layout.stereo` | Segment. |
| | Both sides mixed into one channel. | `settings.recording.layout.mono.help` | Secondary text when Mono is selected. |
| | You on the left channel, the caller on the right. | `settings.recording.layout.stereo.help` | Secondary text when Stereo is selected. |
| | Recordings are saved as M4A (AAC), mono or stereo with you on the left channel and the caller on the right. The temporary WAV files are deleted after conversion. | `settings.recording.footer` | |
| | File name: %@ | `settings.recording.fileName` | %@ sample file name. |
| | Show Recordings Folder | `settings.recording.showFolder` | |
| | Open in Finder | `settings.recording.openFinder` | |
| | Notice tone | `settings.recording.notice.header` | |
| | Play a notice tone while recording | `settings.recording.notice.enable` | |
| | Every | `settings.recording.notice.interval` | Unit "seconds" reused. |
| | A short beep every %lld seconds tells both sides that the call is recorded. | `settings.recording.notice.footer` | %lld the interval. |
| | Answer incoming calls automatically | `settings.autoAnswer.mode` | |
| | Off, All calls, Contacts only | `settings.autoAnswer.off`, `.all`, `.contactsOnly` | Segments. |
| | Delay before answering | `settings.autoAnswer.delay` | |
| | Honour the server's answer-after request | `settings.autoAnswer.honourServer` | |
| | Answers when the PBX sends Call-Info: answer-after=N (intercom, paging), even if the mode is Off. | `settings.autoAnswer.honourServer.help` | |
| | Do Not Disturb wins over auto-answer. Auto-answer never answers a second call while you are already on one. | `settings.autoAnswer.footer` | |

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
| | Enabled | `account.field.enabled` | First switch in the editor. |
| | Off stops registration and outgoing calls; the account stays in the pop-up, dimmed, and leaves the status bar. | `account.field.enabled.help` | |
| | Default for outgoing calls | `account.field.defaultOutgoing` | |
| | Publish my presence | `account.field.publishPresence` | |
| | Lets contacts who watch you see Available / Away / DND. | `account.field.publishPresence.help` | |
| | Delete Account… | `account.delete` | Destructive. |
| | Test | `account.test` | |
| | Registered | `account.status.registered` | Status beside buttons. |
| | Cancel | `common.cancel` | |
| | Save | `common.save` | |
| | Enter a host name like pbx.example.com, or an IP address. | `account.error.server` | Validation. |
| | Test failed: %@ | `account.test.failed` | %@ SIP error, e.g. "401 Unauthorized". |
| | The server rejected the username or password. Nothing was saved. | `account.test.failed.hint` | |
| | Test Again | `account.test.again` | |
| | Advanced | `account.group.advanced` | Disclosure label of the editor. |
| | Voicemail | `account.group.voicemail` | Group header in Advanced. |
| | Voicemail number | `account.field.voicemailNumber` | |
| | Dialled from the menu bar and the status bar. | `account.field.voicemailNumber.help` | |
| | Voicemail indicator (MWI) | `account.field.mwi` | |
| | Shows the number of new messages the server reports. | `account.field.mwi.help` | |

### 10 First launch

| Ed. | English | Key | Notes |
|---|---|---|---|
| | No account | `account.popup.none` | Pop-up button, disabled. Repeated from Common. |
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

Resolved on 2026-10-10 as routine UI decisions (none changes scope).

1. **Window height.** Fixed 340×520. "Resizable height" in screen 1 is a mockup slip; ignore it.
2. **Escape in the main window.** Dialpad: clears the dial field if non-empty, otherwise nothing. Contacts: clears the search if non-empty. Call Log: nothing. During an incoming call shown in the main window, Escape silences the ringtone (does not decline).
3. **Hold button.** Toggle: label "Hold" with pause icon when the call is active, "Resume" with play icon when it is held. With several calls, pressing Resume on a held call holds the currently active one first. When the only call is held, the panel header shows "On hold" and the timer keeps running.
4. **Registering state.** Orange dot, text "Registering…"; failed = red dot + short reason; registered = green; disabled account = grey, text "Disabled" (see Q1.3 and 8.2).
5. **Status bar overflow.** Up to three accounts shown as dot + name; from the fourth onward collapse to a single summary "3/4 registered" with a tooltip listing all; clicking opens Settings › Accounts.
6. **Fifth call.** Rejected silently with 486; a call log entry is written with direction `missed` and a note "Rejected: call limit" visible in the row subtitle.
7. **Clear log confirmation.** Standard alert sheet "Clear call history?" with Cancel / Clear (destructive). No inline confirm.
8. **Last-error group.** Follows the selected account in the list. If the selected account has no error the group is hidden.
9. **Link handler.** Popup "When a sip:/tel: link is opened": "Ask before calling" (default), "Call immediately", "Only fill the dial field".
10. **Transport default for new accounts.** UDP, SRTP disabled (ADR 0009: no global defaults). The mockup's TLS/mandatory on "Office" is sample data.
11. **Attended-transfer Cancel.** Hangs up the consultation call and resumes the original call (unhold). The banner disappears.
12. **Conference count.** Counts remote parties only: two rows = "2 participants". Fix the mockup text with the next mockup revision.
13. **Incoming call inside the main window.** The window switches to the Dialpad tab automatically; the call panel shows the "incoming" state (caller, account, Answer / Decline). If the user switches to another tab while ringing, the summary bar shows "Incoming: <name>" with Answer and Decline buttons. Escape silences the ringtone.
14. **Transfer popover.** Placeholder "Number or contact"; up to 5 suggestions; Return with a highlighted suggestion picks it and performs the default action ("Transfer Now"); Return with none highlighted uses the typed text.
15. **Quality chip.** Superseded: tooltip "Loss 0.5 % · Jitter 12 ms · RTT 48 ms · MOS 4.3" and bars from the real call quality (4.1).
16. **Four-call layout.** Rows are 44 pt; four rows plus controls fit in 520 pt without scrolling. Never more than four calls (ADR 0009).
17. **Contacts search keys.** Escape clears the field (second Escape leaves focus). Up/Down move the list selection while the field keeps focus; Return calls the selected contact.
18. **Watch presence default.** Off for new contacts.
19. **Dial letters for Russian.** Keys show Latin letters only in both locales (as on a phone keypad); no Cyrillic letters.
20. **Copy.** Contacts empty: "No contacts yet" / "Add a contact to call it in one click." Call log empty: "No calls yet". Delete account: alert "Delete account “%@”?" body "Its password is removed from Keychain. Call history is kept." buttons Cancel / Delete. Account names need not be unique; the list disambiguates with the SIP address in the subtitle. Test success: "Registered successfully (%lld ms)".
21. **Validation.** Local port 0 or 1024–65535; keep-alive 0 (off) or 5–600 s; registration expiry 60–3600 s; invalid values show a red outline and the Save button is disabled.
22. **Recording folder missing.** Decide with the first user report.
23. **Menu bar icon precedence.** While a call is active the timer wins; the missed badge returns after the call ends if there are still unseen missed calls. Opening the Call Log tab clears the badge.
24. **Quick dial in the menu bar menu.** No suggestions; the field only takes a number or URI and Return calls it with the default outgoing account. Suggestions exist only in the main window.

## Decided — owner (2026-10-12)

- **Q1.3 = A.** Accounts are switched on and off with the switches in the account pop-up (screen 1); the status bar has no menu and shows enabled accounts only. The same state is "Enabled" in the account editor and "Disabled" in Settings › Accounts.

---

## 11. Quick keys

Screen 11. Speed-dial and BLF panel next to or under the main window. Off by default. Up to 12 keys on one page. Keys are configured in Settings › Quick keys (screen 8 pane, specified here).

### Layout

Variant A, panel at the right:

| # | Element | Notes |
|---|---|---|
| 1 | Main window | Unchanged 340 pt column on the left. |
| 2 | Quick keys panel | 220 pt wide column to the right of the main window; the window grows from 340 pt to 560 pt wide, height stays 520 pt. Header row "Quick keys" with a gear button (22 pt) at the right, then a list of key rows (12 slots). |
| 3 | Key row | 38 pt high: BLF dot (10 pt) at left, name (13 pt, medium), number (11.5 pt, secondary), type glyph at right. Empty slots show a dashed "Add key…" row. |

Variant B, panel at the bottom:

| # | Element | Notes |
|---|---|---|
| 1 | Main window | 340 pt wide; grows in height by about 110 pt. |
| 2 | Quick keys strip | Under the status bar. Header "Quick keys" with the gear. Grid of 3 columns; two rows (6 keys) are visible, the rest scrolls. Each cell shows only the dot and the name; the tooltip gives number and type. A dashed "Add…" cell follows the last key. |

When the panel is Off the main window is the fixed 340 by 520 pt of the common frame. Exception to "the window never grows": the width (Right) or height (Bottom) change applies only while the panel is shown, and only to the main window.

### Elements

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Panel header | label + icon button (gear) | The gear opens Settings › Quick keys. | Enabled. |
| Key | button (row or cell) | Performs the key's action (table below). Tooltip: name, number, BLF state, type, shortcut. | Dimmed when the type needs an active call and there is none (see Type behaviour). Also disabled when no account is enabled. |
| BLF dot | dot, 10 pt | Green available, red on the phone, orange blinking ringing, grey no presence information. A key with BLF off has no dot. | Read-only. |
| Ringing key | key state | Orange tint and the word "ringing" after the number. Click picks the call up (pickup rule below). | Enabled. |
| Empty slot | dashed button, "Add key…" | Opens Settings › Quick keys with a new row selected. | Enabled. |
| Key context menu | menu | Edit… (opens Settings › Quick keys with the row selected), Remove (clears the slot, no confirmation). | Enabled. |

**Type behaviour** (`QuickKeyType`):

| Type | Glyph | Idle | In a call |
|---|---|---|---|
| Call | handset | Dials the number from the default outgoing account. | Current call goes on hold, new call starts (screen 5). |
| DTMF | # | Dials the digits as a number (so "Pickup *8" works as a key). | Sends the digits as DTMF on the active call. |
| Blind transfer | arrows | Dimmed. | Transfers the active call to the number at once. |
| Attended transfer | arrows | Dimmed. | Holds the active call, calls the number; Complete Transfer appears in the call panel (screen 5.3). |
| Add to conference | people | Dimmed. | Calls the number and joins it to the active call when answered. |
| Call / Blind transfer | handset + arrows | Acts as Call. | Acts as Blind transfer. |
| Call / Attended transfer | handset + arrows | Acts as Call. | Acts as Attended transfer. |
| Call / Conference | handset + people | Acts as Call. | Acts as Add to conference. |

Blind and attended types share the arrows glyph; the tooltip names the type.

**BLF.** A key with BLF on watches the line state of its number. It uses the same presence subscription as a contact with "Watch presence": a key and a contact with the same number share one subscription, and removing one does not drop the other. Ringing (orange, blinking) is shown only when the PBX reports call state in the presence/dialog notifications; otherwise a BLF key shows green and red only. **Pickup:** a click on a ringing key dials the pickup code (Settings › Quick keys) followed by the key's number, for example `*8` + `101` gives `*8101`. If the number is empty on the key the code alone is dialled (group pickup).

### Settings › Quick keys (pane)

Added as the eighth toolbar tab (screen 8). Layout: key table, hint, then two groups.

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Key table | table, 12 fixed rows | Columns: Name, Number, Type, BLF, Key. Rows reorder by drag. Name and Number are edited in place (double-click a row or start typing). Empty rows show "Empty". | Enabled. |
| Type | popup in the Type column | Eight types in two sections: Call, DTMF, Blind transfer, Attended transfer, Add to conference; a separator and the caption "Smart: call when idle, act on the call when in one"; Call / Blind transfer, Call / Attended transfer, Call / Conference. | Disabled on an empty row. |
| BLF | checkbox in the BLF column | Watches the number's line state. | Disabled when the number is empty. |
| Key | label | Shortcut: ⌘1 to ⌘9 for rows 1 to 9 following the list order; rows 10 to 12 show "—". | Read-only. |
| Count | label | "%lld of 12 keys". | n/a |
| Show panel | segmented control: Off, Right, Bottom | Default Off. Right widens the window to 560 pt, Bottom adds the 3-column strip. | Enabled. |
| Pickup code | text field | Default `*8`. Used when a ringing key is clicked. | Enabled. |
| Shortcuts note | label | "⌘1 – ⌘9 press keys 1–9 while MacroSIP is the frontmost app, also when the panel is hidden. Keys 10–12 are clicked only. Shortcuts follow the order of the list." | n/a |

### States

| State | Appearance |
|---|---|
| Panel off | No panel; main window 340 by 520 pt. |
| No keys defined | Panel shows only the dashed "Add key…" slots. |
| Idle | Call, DTMF and smart keys enabled; plain transfer and conference keys dimmed (Sales queue and Conference room in the mockup). |
| In a call | All keys enabled. |
| No account enabled | All keys disabled. |
| Ringing | Key tinted orange, dot blinking, label "ringing". |
| No presence information | Grey dot. Key still works. |
| Network down / reconnecting | BLF dots turn grey; keys with a Call type stay clickable and fail as a normal call would. |

### Keyboard

| Key | Action |
|---|---|
| ⌘1 – ⌘9 | Presses key 1 to 9 (list order). Works while MacroSIP is frontmost, also with the panel hidden; does nothing for an empty or dimmed key. |
| Tab / Space | Moves between keys; Space presses the focused key (panel only). |

### Strings

| English | Key | Notes |
|---|---|---|
| Quick keys | `quickkeys.title` | Panel header and Settings tab and title. |
| Add key… | `quickkeys.add` | Empty slot (right panel). |
| Add… | `quickkeys.add.short` | Empty cell (bottom strip). |
| Edit… | `quickkeys.menu.edit` | Key context menu. |
| Remove | `quickkeys.menu.remove` | Key context menu. |
| ringing | `quickkeys.state.ringing` | After the number. |
| Available / On the phone / Ringing / No information | `quickkeys.blf.available`, `quickkeys.blf.busy`, `quickkeys.blf.ringing`, `quickkeys.blf.unknown` | Tooltip. |
| Name, Number, Type, BLF, Key | `quickkeys.column.name`, `.number`, `.type`, `.blf`, `.key` | Table header. |
| Empty | `quickkeys.row.empty` | Empty row. |
| %lld of 12 keys | `quickkeys.count` | |
| Drag rows to reorder. Name and Number are edited in place; double-click a row or start typing. The BLF box watches the number's line state. | `quickkeys.hint` | Under the table. |
| Call | `quickkeys.type.call` | Type pop-up. |
| DTMF | `quickkeys.type.dtmf` | |
| Blind transfer | `quickkeys.type.blindTransfer` | |
| Attended transfer | `quickkeys.type.attendedTransfer` | |
| Add to conference | `quickkeys.type.conference` | |
| Smart: call when idle, act on the call when in one | `quickkeys.type.smart.caption` | Pop-up section caption. |
| Call / Blind transfer | `quickkeys.type.callBlind` | |
| Call / Attended transfer | `quickkeys.type.callAttended` | |
| Call / Conference | `quickkeys.type.callConference` | |
| Panel | `quickkeys.panel.header` | Group header. |
| Show panel | `quickkeys.panel.show` | |
| Off / Right / Bottom | `quickkeys.panel.off`, `quickkeys.panel.right`, `quickkeys.panel.bottom` | |
| Show panel Right widens the window to 560 pt; Bottom adds a 3-column strip. | `quickkeys.panel.footer` | Row sublabel. |
| Pickup code | `quickkeys.pickup.label` | |
| Used when you click a ringing key. | `quickkeys.pickup.sub` | |
| ⌘1 – ⌘9 press keys 1–9 while MacroSIP is the frontmost app, also when the panel is hidden. Keys 10–12 are clicked only. Shortcuts follow the order of the list. | `quickkeys.shortcuts.note` | Group footer. |

### Decided

- **Q11.1.** 12 keys on one page, no banks or pages.
- **Q11.2.** The panel is Off by default; Right (window 560 pt) or Bottom (3 columns, scrolls), set in Settings › Quick keys.
- **Q11.3.** Eight types as in the Type pop-up; smart types call when idle and act on the active call when in one; plain transfer and conference keys are dimmed with no call.
- **Q11.4.** A DTMF key sends its digits in a call and dials them as a number when idle.
- **Q11.5.** BLF reuses the contacts' presence subscription. Ringing (orange) shows only when the PBX reports call state; otherwise keys show green and red only.
- **Q11.6.** A click on a ringing key dials the pickup code followed by the key's number (`*8` + 101 gives `*8101`). Alternative: the code alone (group pickup).
- **Q11.7.** ⌘1–⌘9 follow the list order and work with the panel hidden; keys 10–12 have no shortcut.
- **Q11.8.** Keys are edited only in Settings; the panel offers Edit… and Remove on right-click.
- **Q11.9.** The Settings window widens to 680 pt to fit the Quick keys and Directory tabs.

---

## 12. Contact card

Screen 12. Replaces the Edit Contact sheet of screen 2 (320 pt) with a 500 pt card; adds Favorites to the Contacts tab and a sort setting to Settings › Directory (first group, `ContactsSortGroup`).

### Layout (sheet)

| # | Element | Notes |
|---|---|---|
| 1 | Title row | "Edit Contact" / "New Contact" at the left, Favorite star toggle at the right. |
| 2 | Identity block | Photo well (64 pt circle) with "Choose…" below; to the right First name, Last name, Organization fields. |
| 3 | Phone numbers | Group with one row per number, "Add number" link, hint line. |
| 4 | Details | Email, Account, Watch presence. |
| 5 | Notes | Multi-line text field, 3 lines, grows to 6. |
| 6 | Buttons | Cancel and Save, right-aligned. |

The card is 500 pt wide, wider than the 340 pt main window, so it is a separate panel window, not an attached sheet (the mockup shows it as a sheet). It opens centred over the main window; only one card is open at a time (asking for another brings the open one forward), and the main window stays usable behind it.

### Elements

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Favorite | toggle (star) | Adds the contact to Favorites. | Enabled. |
| Photo | image well + button "Choose…" | "Choose…" opens a file picker (images), crops to a circle, stores a 256 pt copy. Without a photo the well shows initials on the colour used in the list. A "Remove" item appears in the well's context menu when a photo is set. | Enabled. |
| First name | text field | Free text. | Enabled. |
| Last name | text field | Free text. | Enabled. |
| Organization | text field | Free text. | Enabled. |
| Number row | text field + label popup + "Default" radio + remove (cross) | Number or SIP URI, normalised as on the dialpad. Label popup: Work, Mobile, Home, Other, SIP. Exactly one row is the default; the radio of the first added row is set automatically; removing the default makes the first remaining row the default. | The remove button is disabled when only one row remains. |
| Add number | link button | Appends an empty row (label Work, or the next unused label). No limit on rows. | Enabled. |
| Email | text field | Free text; stored, not validated beyond a single "@". | Enabled. |
| Account | popup | As screen 2. | Enabled. |
| Watch presence | checkbox | Subscribes to the default number. | Enabled. |
| Notes | text editor | Free text. | Enabled. |
| Cancel | button | Closes without saving. Escape. | Enabled. |
| Save | button, default | Saves and closes. | Disabled until a name (first, last or organization) or a number is filled. |

Display name (derived, not stored separately): "First Last"; whichever of the two is filled; the organization if both are empty; the default number if all three are empty.

### Contacts tab changes (screen 2)

| Element | Behaviour |
|---|---|
| Favorites section | First section, header "Favorites". Sorted like the rest. A favourite also stays in its letter section. Hidden when there are no favourites. |
| Contact row | Second line shows the default number and its label ("102 · Work"); a "+N" badge (N = number of further numbers) at the right of the line when N > 0. A number-only SIP URI shows without a label if the label is "SIP". |
| Context menu | One item "Call <label> <number>" per number, default first and with the Return shortcut; then Call from ▸, Copy Number (default number), Edit…, Add to Favorites / Remove from Favorites, Watch Presence, Delete. |
| Count label | "%lld contacts · %lld favorites"; the favorites part is omitted when 0. |
| Search | Also matches every number, first and last name, and organization. |
| Section letters | By the first letter of the sort key (see Settings › Directory). |
| Double-click, Return | Call the default number. |

### Settings › Directory (first group)

| Element | Type | Behaviour |
|---|---|---|
| Contacts group header | label | "Contacts". |
| Sort by | segmented control: First name, Last name | Default First name. Changes list order and the section letters; names are always shown as "First Last". |

### Other behaviour

- The call log and the incoming-call window match a remote party to a contact through any of its numbers, comparing digits without spaces, dashes and brackets. SIP addresses compare the user part and, when both sides have a host, the host too. A match on a contact's default number wins over a match on another number; when two contacts match equally well the call log stays unlinked, and a name shown for the caller comes from the first of them by display name.
- Search text with letters is matched as plain text; digits-only text is also matched against the numbers without spaces, dashes and brackets.
- Photos are not kept in contacts.json but as `photos/<contact id>.jpg` beside it; contacts.json also carries `name` and `number` so an older build can still read it, and an entry that cannot be read is skipped (the original file is kept as `contacts.damaged-<date>.json`).
- Save applies only what the card changed to the contact as stored at that moment; a contact deleted while its card was open is created again.
- Import from the macOS Contacts app (directory source, screen 13) fills first and last name, organization, labelled numbers, email, photo and notes.
- Older files with `name`/`number`: each existing contact's "Name" is split at the last space into First and Last name (a single word becomes First name); its number becomes an Other number and the default.

### States

| State | Appearance |
|---|---|
| New | Empty fields; one empty number row (Work, default). Save disabled. |
| Edit | Filled. |
| Photo set | Photo in the well; the button stays "Choose…". |
| No favourites | No Favorites section. |
| Sort by last name | Sections grouped by the last name's first letter. |

### Keyboard

| Key | Action |
|---|---|
| Return | Save, when enabled (not in Notes, where Return inserts a line). |
| Escape | Cancel. |
| Tab / Shift-Tab | Moves through fields in visual order. |
| Favorite | No key equivalent: Command-D belongs to Call › End Call. The star in the card and "Add to Favorites / Remove from Favorites" in the context menu toggle it. |

### Strings

| English | Key | Notes |
|---|---|---|
| Edit Contact / New Contact | `contact.edit.title`, `contact.new.title` | Existing keys from screen 2. |
| Favorite | `contact.favorite` | Star tooltip and accessibility label. |
| Choose… | `contact.photo.choose` | |
| Remove Photo | `contact.photo.remove` | |
| First name | `contact.firstName` | |
| Last name | `contact.lastName` | |
| Organization | `contact.organization` | |
| Phone numbers | `contact.numbers.header` | |
| Work, Mobile, Home, Other, SIP | `contact.label.work`, `.mobile`, `.home`, `.other`, `.sip` | Number labels. |
| Default | `contact.numbers.default` | Radio label. |
| Add number | `contact.numbers.add` | |
| Labels: Work, Mobile, Home, Other, SIP. The default number is used by double-click, Return and presence. | `contact.numbers.hint` | |
| Email | `contact.email` | |
| Account | `contact.account` | Existing label. |
| Preferred account for calls to %@. | `contact.account.sub` | |
| Watch presence | `contact.presence` | Existing label. |
| Subscribes to the default number. | `contact.presence.sub` | |
| Notes | `contact.notes` | |
| Favorites | `contacts.section.favorites` | List section header. |
| Call %1$@ %2$@ | `contacts.menu.callNumber` | Label, number. |
| Add to Favorites / Remove from Favorites | `contacts.menu.favoriteAdd`, `contacts.menu.favoriteRemove` | |
| %lld contacts · %lld favorites | `contacts.count`, `contacts.favorites.count` | Two plural entries in `Localizable.stringsdict`, joined with " · "; the second is omitted when 0. |
| Contacts | `settings.general.contacts.header` | |
| Sort by | `settings.general.sort` | |
| First name / Last name | `settings.general.sort.first`, `settings.general.sort.last` | |
| Names are always shown as "First Last". Sorting by last name also groups the sections by its first letter. | `settings.general.sort.footer` | |

### Decided

- **Q12.1.** The display name is "First Last", or whichever of the two is filled, or the organization if both are empty.
- **Q12.2.** Settings › Directory gets "Sort by: First name / Last name" (First name by default); the display order does not change.
- **Q12.3.** Number labels Work, Mobile, Home, Other, SIP; any number of rows; one default for calls and presence.
- **Q12.4.** The call log matches a call to a contact through any of its numbers, compared without spaces, dashes and brackets.
- **Q12.5.** Favorites first, sorted like the rest; a favourite also appears in its letter section.
- **Q12.6.** Import from the macOS Contacts app (screen 13) fills names, organization, labelled numbers, email, photo and notes.
- **Q12.7.** Existing contacts move over with "Name" split at the last space into First and Last name, and their number as Other, default.

---

## 13. Directory

Screen 13. Search of company and online directories from the number field, and the Settings › Directory pane with the source sheet.

### Layout

| # | Element | Notes |
|---|---|---|
| 1 | Number field suggestions | The dropdown under the number field (screen 1, Q1.1) gains a "Directory" section. Up to 5 results per source. |
| 2 | Settings › Directory | Ninth toolbar tab (screen 8). Source list, per-source detail group, Search group. |
| 3 | Add Directory Source sheet | Sheet on Settings, fields depend on the type. |

### Suggestions list

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Contacts section | list section | Local contacts matching the text, first. Default number and label shown; ↩ hint on the highlighted row. | Enabled. |
| Directory section | list section | Directory results in the source order of Settings. Each row: source badge (LDAP, Google, URL, Contacts), name with matched letters in bold, number and label. A number already present in Contacts is shown only once (as a local contact). | Enabled. |
| Searching row | label with spinner, last row | "Searching <source>…" while a source has not answered; its rows are added when they arrive. Several slow sources show one row each. | Read-only. |
| Result count | label | "%lld results from %lld sources" when all sources have answered. | n/a |
| Source with an error | | Skipped silently (status shown in Settings). | n/a |

Search starts after 2 characters and a 300 ms pause in typing; an in-flight search is cancelled when the text changes. Disabled sources and sources in the "Sign in required" or error state are not searched. Digit-only text of 2 or more characters is searched too (sources match on numbers).

**Context menu** on a directory result: Call, Copy Number, Add to Contacts (creates a card from the entry).

### Settings › Directory (pane)

| Element | Type | Behaviour | Enabled / disabled |
|---|---|---|---|
| Source list | table | Columns Source (name, address, mode "search only" or "import into Contacts"), Status, On (switch). Drag to reorder: this is the result order. | Enabled. |
| Status | label with dot | Connected, Sign in required, Synced N min ago, error text. | Read-only. |
| On | toggle | A switched-off source is not searched and not synced. | Enabled. |
| + / − / Edit… | icon buttons | Add opens the sheet; − removes the selected source after a confirmation alert (imported entries stay in Contacts); Edit opens the sheet for the selected source. Double-click edits. | − and Edit… disabled with no selection. |
| Sign-in group | group, shown when the selected source needs it | "Access has expired or was revoked" with sub-label "Search skips this source until you sign in again." and the Sign In… button (opens the browser). | Shown only for Google Contacts in the "Sign in required" state. |
| Search directories from the number field | toggle | On by default. Sub-label: "Starts after 2 characters and a 300 ms pause in typing." | Enabled. |
| Results per source | stepper with field | 1 to 10, default 5. | Enabled. |
| Look up names of incoming callers | toggle | On by default. Asks search-only sources for at most 1 second while the call rings; imported sources are looked up locally. | Enabled. |

### Add Directory Source sheet

Fields common to all types: Type popup (LDAP, URL (CSV or JSON), Google Contacts, macOS Contacts), Name (not for macOS Contacts, which is named "macOS Contacts"), buttons Cancel and Add (default, disabled until required fields are filled; "Save" when editing).

| Type | Fields | Notes |
|---|---|---|
| LDAP | Server (placeholder `ldap://ldap.example.com`; sub-label "ldaps:// or StartTLS when possible."), Base DN, Bind DN (sub-label "Empty for anonymous search."), Password (secure; "Stored in the Keychain."), Search filter (default `(\|(cn=*%s*)(telephoneNumber=*%s*))`; `%s` is the typed text), Results radio: Search only (results are not stored) / Import into Contacts (copied and refreshed daily), Test button with inline result "Connected · %lld entries". | ldaps:// and StartTLS are supported; plain ldap:// is allowed. Password in Keychain. |
| URL (CSV or JSON) | URL, Refresh every (popup: Hour, 6 hours, Day, Week; default Hour), Results radio. Footer: "CSV with a header row, or a JSON array of objects. Columns named name, first name, last name, number, mobile, email are recognised." | Fetched on the chosen schedule. |
| Google Contacts | "Sign in with Google" button; explanation "Opens Google in your browser once to allow read-only access to your contacts. MacroSIP keeps only the access token, in the Keychain; you can remove access in your Google Account at any time." Results radio. | Needs the OAuth client id from the owner's Google Cloud project (read-only contacts scope). |
| macOS Contacts | No fields except the Results radio (default Import into Contacts per the mockup row "This Mac · import into Contacts"). | The system Contacts-access prompt appears when Add is pressed, not at launch. If denied the source is added in the error state "Access denied" with a link to System Settings. |

Imported entries are refreshed daily (URL: on its own schedule) and are marked as imported in the contact card (read-only source badge, proposed).

### States

| State | Appearance |
|---|---|
| No sources | Number field shows local suggestions only. Settings list shows "No sources" with an Add button (proposed). |
| Searching | Spinner row "Searching <source>…". |
| All answered | Spinner row replaced by the result count. |
| Nothing found | Directory section hidden; local section as before. |
| Source error | Status shows the error; source is skipped. |
| Sign in required | Status "Sign in required" (orange dot); sign-in group shown. |
| Google sign-in running | Sign In… (pane) or "Sign in with Google" (sheet) disabled with a small spinner and "Waiting for Google…"; the browser shows the consent page. Closing the sheet abandons the sign-in. |
| Google signed in | The e-mail replaces "Google account" in the sheet row (with a green check) and appears under the source in the list; status "Connected". |
| Google sign-in failed | The reason under the Sign In… row (pane) or as a warning line in the sheet: "Google sign-in is not configured in this build", "Timed out", an HTTP code. A cancelled sign-in shows nothing. |
| Offline | Directory search is skipped; local contacts only. |

### Keyboard

| Key | Action |
|---|---|
| Up / Down | Moves the highlight through contacts and directory rows. |
| Return | Calls the highlighted entry; with nothing highlighted dials the text as typed. |
| Escape | Closes the list and keeps the text. |
| Command-C (on a highlighted result) | Copies the number. |

### Strings

| English | Key | Notes |
|---|---|---|
| Directory | `directory.title` | Settings tab, title, list section header. |
| Contacts | `directory.section.contacts` | Suggestions section header. |
| Searching %@… | `directory.searching` | Spinner row; source name. |
| %lld results from %lld sources | `directory.results` | |
| Call, Copy Number, Add to Contacts | `directory.menu.call`, `directory.menu.copy`, `directory.menu.add` | Result context menu. |
| Source, Status, On | `directory.column.source`, `.status`, `.on` | Table header. |
| search only | `directory.mode.search` | Source subtitle. |
| import into Contacts | `directory.mode.import` | Source subtitle. |
| Connected | `directory.status.connected` | |
| Sign in required | `directory.status.signin` | |
| Synced %@ ago | `directory.status.synced` | Relative time. |
| Access denied | `directory.status.denied` | |
| Results are listed in this order; drag to reorder. A source that is switched off is not searched and not synced. | `directory.sources.footer` | |
| Access has expired or was revoked | `directory.signin.title` | |
| Search skips this source until you sign in again. | `directory.signin.sub` | |
| Sign In… | `directory.signin.button` | |
| Search | `directory.search.header` | Group header. |
| Search directories from the number field | `directory.search.enable` | |
| Starts after 2 characters and a 300 ms pause in typing. | `directory.search.enable.sub` | |
| Results per source | `directory.search.limit` | |
| Look up names of incoming callers | `directory.lookup.enable` | |
| Asks search-only sources for at most 1 second while the call rings. | `directory.lookup.sub` | |
| Add Directory Source | `directory.add.title` | Sheet title (Edit Directory Source when editing: `directory.edit.title`). |
| Type, Name | `directory.add.type`, `directory.add.name` | |
| LDAP, URL (CSV or JSON), Google Contacts, macOS Contacts | `directory.type.ldap`, `.url`, `.google`, `.macos` | |
| Types: LDAP, URL (CSV or JSON), Google Contacts, macOS Contacts. | `directory.add.types.footer` | |
| Server, Base DN, Bind DN, Password, Search filter | `directory.ldap.server`, `.baseDN`, `.bindDN`, `.password`, `.filter` | |
| ldaps:// or StartTLS when possible. | `directory.ldap.server.sub` | |
| Empty for anonymous search. | `directory.ldap.bindDN.sub` | |
| Stored in the Keychain. | `directory.ldap.password.sub` | |
| %s is the typed text. | `directory.ldap.filter.sub` | |
| Results | `directory.results.header` | Radio group header. |
| Search only / results are not stored | `directory.results.search`, `directory.results.search.sub` | |
| Import into Contacts / copied and refreshed daily | `directory.results.import`, `directory.results.import.sub` | |
| Test | `directory.test` | |
| Connected · %lld entries | `directory.test.success` | |
| URL, Refresh every | `directory.url.url`, `directory.url.refresh` | |
| Hour, 6 hours, Day, Week | `directory.url.refresh.hour`, `.hours6`, `.day`, `.week` | |
| CSV with a header row, or a JSON array of objects. Columns named name, first name, last name, number, mobile, email are recognised. | `directory.url.footer` | |
| Sign in with Google | `directory.google.signin` | |
| Waiting for Google… | `directory.google.signingIn` | While the browser is open. |
| Google sign-in is not configured in this build | `directory.error.googleClientID` | A build without an OAuth client id. |
| Opens Google in your browser once to allow read-only access to your contacts. MacroSIP keeps only the access token, in the Keychain; you can remove access in your Google Account at any time. | `directory.google.footer` | |
| MacroSIP looks up names and numbers in Contacts when you search from the number field. | `NSContactsUsageDescription` | Info.plist; system prompt text. |
| Cancel, Add | `directory.add.cancel`, `directory.add.confirm` | Reuse the common Cancel; Add is new. |

### Decided

- **Q13.1.** Search starts after 2 characters and a 300 ms pause; up to 5 results per source.
- **Q13.2.** Local contacts first, then directory results in source order; a number already in Contacts is shown only once.
- **Q13.3.** Results are not stored unless the source is set to "Import into Contacts"; imported entries are refreshed daily (URL: on its own schedule).
- **Q13.4.** Google Contacts uses an OAuth client id from the owner's Google Cloud project, with read-only contacts access. Needed before this source can ship.
- **Q13.5.** macOS Contacts asks for the Contacts permission when the source is added, not at launch. Replaces Q2.1.
- **Q13.6.** LDAP passwords are kept in the Keychain; ldaps:// and StartTLS are supported, plain ldap:// is allowed.
- **Q13.7.** Incoming calls look up the caller's name in the sources for at most 1 second (switch in Settings › Directory, on).

### As built

Where the app differs from the tables above:

- **Search group**: besides the switch and "Results per source" it has "Minimum characters" (1 to 5, default 2; `directory.search.minLength`), which replaces the fixed "2 characters" in the sub-label. The switch has no sub-label.
- **Counts**: "%lld results from %lld sources" is two plural strings joined by a space (`directory.results.count`, `directory.results.sources`), because the string checker allows one plural variable per key. The count shows sources that returned results.
- **Status** "Synced %@" takes the formatter's relative text ("5 min. ago"), so there is no separate "ago".
- **Rows**: the number is shown without its label (the 340 pt column is too narrow for both); source badge at the right end of a result row, avatar (photo or initials) at the left; the ↩ hint is shown on the highlighted local contact. A click on a row puts the number into the field (as for local contacts) and does not search again; Return on the highlighted row calls it. With more than about 11 rows the list scrolls.
- **Escape** closes the list and keeps the text; a second Escape clears the field.
- **Source list**: the status column also holds "Import now" for sources set to import (with "Importing…" while it runs); the result ("Imported 120 contacts (14 updated)") is a banner under the list for 10 seconds. Imported sources are refreshed in the background daily (URL: on its own schedule), macOS Contacts only when access was already granted. A failed import shows its reason in the banner and does not disable the button or the schedule; only "Sign in required" does. Every failure reason is shown in the app's language (text straight from a library, such as an LDAP diagnostic, is shown as it is).
- **Import merge**: entries are matched to contacts by number, never duplicated. A card the same source created earlier (`Contact.importedFrom`) follows the directory on every import: name, organization, e-mail and photo are replaced, missing numbers added. A card the user made or edited by hand keeps its name, photo and the rest; it only receives what it lacks (an empty organization or e-mail, a missing photo, new numbers). Notes, favourite and the preferred account are never touched. New cards get the note "Imported from <source>". "Add to Contacts" from a search result makes a card of the user's own.
- **Test and passwords**: the LDAP password typed in the sheet is used by Test as typed and stored in the Keychain only by Save; Cancel leaves the stored password as it was. The macOS Contacts source has no name of its own: the list shows "macOS Contacts" in the app's language.
- **Sheet**: LDAP has a "Use StartTLS" switch; URL has a CSV / JSON switch (chosen from the URL's extension until touched). Google: "Sign in with Google" opens the consent page in the browser and waits for the redirect (two minutes at most); the e-mail is shown in the row and stored by Save. macOS Contacts: the "Allow access" button runs the Test (the system prompt), with an "Open System Settings…" row when access is denied.
- **Caller names**: a caller's name from the directory is used when the SIP display name is empty or just the number; the name is also stored in the call log entry.
