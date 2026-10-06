# Security policy

Cadenza handles microphone audio and, optionally, cloud credentials and a local API, so security reports are taken seriously.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository. Only the maintainers can see it.

Include what you found, the app version, macOS version, and steps to reproduce. Do not include real recordings, transcripts
or credentials; redact anything private.

We aim to acknowledge a report within 7 days and to tell you what we plan to do within 30 days. These are goals for a
volunteer project, not guarantees. Please allow time for a fix before sharing details publicly, and we will credit you in the
release notes if you wish.

## In scope

- The loopback developer API: authentication, token handling, permission checks, origin and host validation, request limits.
- Credential storage and handling (Keychain items, logs, URLs, error messages).
- Anything that could send audio or text off the Mac without the user's consent.
- Typing text into other apps against the user's wishes (target checks, secure input fields).
- Model download and import: checksum bypass, path traversal, archive extraction.

## Out of scope

- Vulnerabilities in a cloud speech provider's own service.
- Problems that need an attacker who already has full control of the user's Mac or account.
- Builds that were modified or signed by someone else.

## Supported versions

Only the latest release receives fixes.
