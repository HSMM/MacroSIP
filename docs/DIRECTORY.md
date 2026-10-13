# Directory of users (screen 13)

Search of company and online directories from the number field, caller-name lookup for ringing calls,
and import into Contacts. UI spec: `docs/design/SCREENS.md` § 13. Core code: `Sources/MacroSIPCore/Directory/`,
settings: `Sources/MacroSIPCore/Model/DirectorySettings.swift`, LDAP shim: `Sources/CLDAP/`.

## Architecture

```
AppSettings.directory (settings.json)          Keychain
  DirectorySettings                              com.hsmm.macrosip         LDAP bind password, account = source id
    sources: [DirectorySource]  ───────┐         com.hsmm.macrosip.google  Google OAuth token (JSON), account = source id
    lookupIncomingCallers, ...         │                 ▲
                                       ▼                 │ DirectoryCredentials
                          DirectoryService (actor) ──────┤
                            one DirectoryProvider per source (rebuilt when its connection settings change)
                            ├─ MacContactsProvider    Contacts framework, in-memory snapshot
                            ├─ LDAPDirectoryProvider  libldap through CLDAP, one connection per request, two at a time
                            ├─ URLDirectoryProvider   URLSession + DirectoryFeedParser, in-memory cache
                            └─ GoogleDirectoryProvider People API over URLSession, hourly index for lookup
                            GoogleOAuth ─────────────────┘  sign-in (PKCE + loopback redirect), token refresh
                            events: AsyncStream<DirectoryEvent>  (.sourceStatus(id:status:))
```

- **Search** (`search(_:)`, or `searchUpdates(_:)` source by source): runs only when "Search directories
  from the number field" is on and the text has `minimumQueryLength` (2) characters. Every enabled source
  is asked at once for `resultsPerSource` (5) entries; the call returns after all answered or after 3 s
  with what arrived, in source order. The 300 ms typing pause and cancelling a stale search (cancel the
  task, or stop iterating `searchUpdates`) are the caller's job; a cancelled search returns at once.
- **Lookup** (`lookup(number:)`): only when "Look up names of incoming callers" is on; asks the enabled
  *search-only* sources (imported ones are already in Contacts) for at most 1 s and returns the match of
  the earliest source in order, as soon as no earlier source can still answer.
- **Numbers** are compared by `DirectoryNumber.matches`: digits only (a SIP URI gives its user part); equal,
  or for numbers of 7+ digits the last up-to-10 digits agree, so `+7 (495) 123-45-67`, `8 495 1234567` and
  `1234567` are one line. Extensions must be equal.
- **Status**: `.connected`, `.signInRequired`, `.error(DirectoryError)` (macOS Contacts denied:
  `.error(.accessDenied)`, `isAccessDenied`), `.syncedAt(date)` (after an import, and for URL sources after
  each fetch). Published on `events` when it changes; `currentStatuses()` gives the current map. A source in
  "Sign in required" (a Google source without a token in the Keychain, or whose token Google refused) is not
  asked until `signInGoogle` succeeds; a failed source is skipped for 60 s, then retried; a source that only
  timed out keeps its status; a late answer of a removed source is dropped. `DirectoryError` is structured
  (`.timedOut`, `.cannotConnect(host:)`, `.invalidCredentials`, `.http(code)`, `.badFeed(…)`,
  `.notConfigured(…)`, …) so the app shows every reason in its own language (`DirectoryStyle.text(for:)`);
  only `.server(text)` carries library text as it is. `.cancelled` (the caller gave up) never changes a status.
- **Test** (`test(source:ldapPassword:)`): builds a provider for the given (possibly unsaved) source and
  connects; updates the status of a saved source with that id. The LDAP password typed in the sheet is passed
  in and used for this test only (`DirectoryCredentials.overriding(ldapPassword:for:)`); nothing reaches the
  Keychain before Save. macOS Contacts shows the permission prompt here.
- **Sign in** (`signInGoogle(sourceID:openURL:)`): runs `GoogleOAuth.signIn` for a Google source, saved or still
  a draft of the sheet; `openURL` receives the authorization URL to open in the browser. Returns the account
  e-mail (the caller stores it in `GoogleConfig.accountEmail`) and sets a saved source to "Connected". Changing
  `accountEmail` does not rebuild the provider: a Google source is identified by its id.
- **Import** (`importAll(source:)`): every entry as a `Contact` (name split at the last space, default
  number first, `importedFrom` = the source id); sets `.syncedAt(now)`. The app adds the note
  "Imported from <source>" to new cards and merges (`DirectoryMerge`): a card matched by number that the same
  source created follows the directory (name, organization, e-mail, photo replaced, numbers added); any other
  card is the user's and only receives what it lacks; notes, favourite and preferred account are never
  touched. A failed import does not lock the source: "Import now" stays enabled and the schedule
  (`DirectoryService.isImportDue(_:lastSync:)`, `importInterval(for:)`: URL sources on their refresh
  interval, the others daily) tries again, because the last import time is recorded only on success.

## Sources

| Kind | Provider | Notes |
|---|---|---|
| `macContacts` | `MacContactsProvider` | `CNContactStore`. Asks for access only in `test()` (Q13.5); search and lookup fail with "Access denied" or "not requested" instead of prompting. The whole address book is read once and kept until `CNContactStoreDidChange`; thumbnails are read for the results (all of them on import). **The app's Info.plist needs `NSContactsUsageDescription`**, or macOS ends the process at the prompt. |
| `ldap` | `LDAPDirectoryProvider` | `ldap://`, `ldaps://`, StartTLS (`startTLS`, ignored for ldaps). Simple bind with `bindDN` and the Keychain password; anonymous when `bindDN` is empty. Subtree search under `baseDN` with `searchFilter` (`%s` = typed text, RFC 4515-escaped). Lookup asks `(|(phone=*<last 4 digits>*)(mobile=…))` and compares locally (servers ignore spaces and dashes in telephone numbers but not brackets or prefixes). `test()` binds, reads the base DN (`(objectClass=*)`, scope base) and counts entries with a number (up to 1000). 3 s per request (connect, bind, search); import 30 s, no paging (the server's size limit applies; size-limit results are kept). Attributes: `LDAPAttributeMap` (cn, telephoneNumber, mobile, mail, o; Active Directory: organization = `company`). |
| `url` | `URLDirectoryProvider` | http(s) or file URL. CSV with a header row (comma, semicolon or tab; RFC 4180 quotes; UTF-8 or Windows-1251) or JSON (array of objects at the root, at `jsonItemsPath`, or the first array of objects in a root object). Fields by `csvColumns` / `jsonPaths` (`URLFieldMap`; JSON key paths are dotted, `phones.0.value`), else by recognised names: name, first name, last name, number/phone/telephone/extension, mobile/cell, email/mail, organization/company (case, spaces, `_` and `-` ignored). Rows without a number are skipped. Kept in memory for `refreshMinutes`; revalidated with `If-None-Match` / `If-Modified-Since`; a failed refresh keeps the old copy. |
| `google` | `GoogleDirectoryProvider` | People API, read-only, with the tokens `GoogleOAuth.signIn` stored. Search: `people:searchContacts` (server-side matching of names, e-mails and numbers; `pageSize` ≤ 30; a warm-up request with an empty query starts a search session after 10 min without one, as Google asks). Import: `people/me/connections`, 1000 per page; the primary number first; phone types `mobile`/`workMobile`/`googleVoice` → mobile, `work`/`main`/`workFax`/`workPager` → work, `home`/`homeFax` → home, the rest (custom labels too) → other; people without a number are skipped; photos the user set are fetched (four at a time, Google's default silhouettes skipped). Lookup: from an in-memory index of the connections (searchContacts does not match reformatted numbers) refreshed hourly in the background while the stale copy answers (a failed refresh is retried after a minute). `test()` asks `people/me/connections?pageSize=1` and reports `totalPeople`. Tokens are renewed 60 s before `expiresAt` and once on a 401; `invalid_grant` deletes the token and puts the source in "Sign in required". 15 s per request; the HTTP client is an injectable `fetch` closure (tests run against a stub). Google's error message, when there is one, is shown as it is (`.server`), e.g. when the People API is not enabled. See below. |

### LDAP: why the system libldap

macOS ships OpenLDAP 2.4 as `libldap` (`/System/Library/Frameworks/LDAP.framework`, headers and `libldap.tbd`
in the Command Line Tools SDK, arm64 and x86_64). It gives StartTLS, ldaps with the system trust store,
RFC 4515 filter parsing and BER for free; a hand-written client over `Network` could not do StartTLS
(an `NWConnection` cannot be upgraded to TLS mid-stream). The SDK marks the API deprecated (since 10.11,
"use OpenDirectory"), which only matters for compiling: `Sources/CLDAP/cldap.c` silences the warning and
exposes a few undeprecated functions with an opaque handle, so Swift never imports `<ldap.h>`. It is a
system library, so the app still has no dylib dependency outside the system. If Apple ever removes it,
replace `LDAPClient` with an LDAPv3 client (bind, search, StartTLS through CFStream or a TLS framer); the
provider and the tests (`DirectoryLDAPTests` runs against an in-process `NWListener` server) stay.

Calls are blocking; `LDAPClient.run` runs them on an `OperationQueue` with two slots and resumes the caller.
A request's timeout (3 s; 30 s for an import) is one deadline for connect, StartTLS, bind and search
together (`cldap_set_timeout` before each step), so a slow server costs at most that. Cancelling the task
fails a request that still waits for a slot at once (`.cancelled`, nothing is sent); a request in flight
finishes its current libldap call and stops at the next step. `cldap_open` asks for certificate
verification (`LDAP_OPT_X_TLS_REQUIRE_CERT` = demand); if the library refuses the option, the first request
logs a warning and the library default applies.

## Adding a source kind

1. Add the case to `DirectorySourceKind` and, if it has settings, a `Codable` config struct with a
   tolerant `init(from:)` (every key optional) and a field on `DirectorySource` (decode with `try?`, so a
   damaged config does not drop the settings file). Unknown kinds in settings.json are dropped on read.
2. Implement `DirectoryProvider` (an `actor` when it keeps a cache, a `struct` otherwise): `search` returns
   at most `limit` entries, `lookup` uses `DirectoryNumber.matches`, `test` returns `.connected(entries:)`,
   `allEntries` everything for import. Throw `DirectoryError` (`.signInRequired` puts the source in
   "Sign in required"). For a local list, build a `DirectoryIndex` and use its `search` / `lookup`.
3. Return it from `DirectoryService.defaultProvider`. Secrets go through `DirectoryCredentials`
   (`DirectoryCredentials.inMemory()` keeps them in the process for tests and demos).
4. Tests: a `Directory*Tests.swift` file; `StubDirectoryProvider` in `DirectoryServiceTests.swift` covers
   the service side.
5. UI: type popup, fields, strings (SCREENS.md § 13).

## Google Contacts

Code: `GoogleOAuth.swift` (sign-in, token exchange and refresh, the loopback listener) and
`GoogleDirectoryProvider.swift` (People API requests, JSON, the lookup index). Tests: `DirectoryGoogleTests`.

**Before release the owner fills in `GoogleOAuth.Configuration.clientID`** (and `clientSecret` if Google issued
one) in `Sources/MacroSIPCore/Directory/GoogleOAuth.swift` with an OAuth client of type **Desktop app** from
Google Cloud › APIs & Services › Credentials, in a project with the **People API** enabled (and the OAuth consent
screen published, or every tester listed on it). A desktop client secret is not confidential (RFC 8252 § 8.5);
PKCE protects the exchange. While the id is empty, `signIn` throws `.notConfigured(.googleClientID)` and the
sheet's button reports it.

1. **Sign in** (`GoogleOAuth.signIn(sourceID:openURL:)`, run by `DirectoryService.signInGoogle`): authorization
   code flow with PKCE (RFC 7636, S256) and a loopback redirect (RFC 8252 § 7.3). `LoopbackRedirectServer`
   listens with `NWListener` on `http://127.0.0.1:<ephemeral port>/`; the authorization URL
   (`https://accounts.google.com/o/oauth2/v2/auth` with `client_id`, `redirect_uri`, `response_type=code`,
   `scope=https://www.googleapis.com/auth/contacts.readonly email`, `code_challenge`, `code_challenge_method=S256`,
   `state`, `access_type=offline`, `prompt=consent`) goes to the caller's `openURL`, which opens the browser.
   The redirect must carry the expected `state`, or it is refused with 400 and the listener keeps waiting; a
   request with `error` fails the sign-in (`access_denied` → `.accessDenied`); anything else gets 404. The
   browser is shown a plain "You can close this window" page. The flow waits 2 minutes at most (`.timedOut`)
   and stops at once when the task is cancelled (`.cancelled`). The code is exchanged at
   `https://oauth2.googleapis.com/token` with the `code_verifier`; `GoogleToken` (access token, refresh token,
   expiry, scope) is stored with `DirectoryCredentials.setGoogleToken` (Keychain service
   `com.hsmm.macrosip.google`, account = source id). The account e-mail comes from the `email` claim of the
   `id_token` (read without signature verification: it arrives straight from Google over TLS and is used for
   display only), else from `people/me`; it is returned for `GoogleConfig.accountEmail`.
2. **Requests** (`GoogleDirectoryProvider`): `GET https://people.googleapis.com/v1/…` with `Authorization: Bearer`.
   Search: `people:searchContacts?query=<text>&pageSize=<limit ≤ 30>&readMask=names,phoneNumbers,organizations,emailAddresses,photos`,
   preceded by a warm-up request with an empty query when no search ran for 10 minutes. Import and the lookup
   index: `people/me/connections?personFields=…&pageSize=1000` following `nextPageToken`. Test:
   `people/me/connections?personFields=names&pageSize=1` → `totalPeople`.
3. **Tokens**: renewed with the refresh token 60 s before `expiresAt` and once after a 401 (one refresh at a
   time; a refresh answer without a refresh token keeps the old one). `invalid_grant`, a token without a
   refresh token, or a 401 that survives a refresh delete the token and throw `.signInRequired`, so the source
   shows "Sign in required" with the sign-in group until the user signs in again.
4. **Service**: a Google source is in "Sign in required" exactly when no token is stored for its id
   (`DirectoryService.init` / `install`); `signInGoogle` sets it to "Connected" on success. The app's part:
   call `signInGoogle(sourceID:openURL:)` from the sheet and the sign-in group, open the URL with
   `NSWorkspace.shared.open`, store the returned e-mail in `GoogleConfig.accountEmail` and save the settings,
   and show `.notConfigured(.googleClientID)` in its own words (`DirectoryStyle.text(for:)`).
