# ADR 0004 — JSON files plus Keychain, no MicroSIP import in v1

Date: 2026-10-10. Status: accepted.

## Context
Data volume is small: a few accounts, hundreds of contacts, thousands of log entries at most.

## Decision
Accounts, contacts, call log and settings are JSON files in `~/Library/Application Support/MacroSIP/` (`accounts.json`, `contacts.json`, `calllog.json`, `settings.json`), written atomically. Passwords are stored in the login Keychain under the account id. Import of `MicroSIP.ini` and `Contacts.xml` is deferred to v2.

## Consequences
Human-readable and easy to back up. If the log grows past tens of thousands of entries, move it to SQLite with a new ADR.
