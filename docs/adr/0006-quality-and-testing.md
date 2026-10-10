# ADR 0006 — Tests, verification and the pjsua second phone

Date: 2026-10-10. Status: accepted.

## Context
No Docker on the machine and no Asterisk in Homebrew. The owner will enter their own SIP account in the app and does not share credentials in chat.

## Decision
XCTest covers models, JSON store, Keychain wrapper (with a test service name), dial-string parsing and auto-answer rules. Signalling and media are verified by calling the `pjsua` CLI directly by IP on localhost, no registrar. Registration, transfer and presence are verified by the owner on their own account. A milestone closes only after build, tests and a real call. Each milestone gets an independent review by a separate agent.

## Consequences
Automated tests cannot cover REGISTER against a real server; that stays a manual checklist item until a local server is available.
