# Naming

- English UI and documents: **Cadenza** (capital C only). Simplified Chinese: **随言**. Traditional Chinese: **隨言**.
- Never show both product names in one UI. Exceptions: copyright lines and repository URLs.
- English tagline: **Speak where you type.** Chinese tagline: **随口说，随处写。**
- English subtitle: **Open-source voice typing for macOS.** Chinese subtitle: **在光标所在的地方，开口就是输入。**
- English UI must contain no Chinese, including provider names, permission prompts, errors, tooltips, and accessibility announcements.
- Use provider names as text; never use provider logos or imply endorsement.
- User-visible product names in code must come from `Brand.name`; sentences use localized `%@` placeholders. Names belong in localization resources, not Swift literals.
- New technical identifiers must be brand-neutral. The Bundle ID (`local.cadenza.app`), executable (`Cadenza`), Keychain service (`Cadenza`) and support folder (`~/Library/Application Support/Cadenza`) were renamed from the historical name on 2026-10-06 at the maintainer's request; `LegacyMigration` carries existing data across. These, the signing identity, and the installed path are compatibility identities again from now on: freeze them. Do not rename them during localization or branding.
- Localized display names may change; technical identities must not change with the language.
- The tagline describes the intended experience, not verified compatibility with every application. Documentation must state actual limitations.
- Feature lists and release notes include only implemented behavior, clearly distinguishing integration tests from unit tests.

## Localization

The names and taglines above are approved editorial choices. `Brand.swift` reads the localized name and tagline from the language resources.

English and Simplified Chinese must each have complete `Localizable.strings` and `InfoPlist.strings`. There is no Traditional Chinese interface yet; do not claim one.

The build must explicitly copy `.lproj` directories into `Contents/Resources`; validate the packaged strings and test both app languages after building. Finder and Dock may cache display names.
