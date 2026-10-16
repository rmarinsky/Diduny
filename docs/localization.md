# Interface languages

Diduny ships English (`en`, development fallback) and Ukrainian (`uk`). Without an
app-specific choice, macOS resolves the preferred language from the installed resources.
General → App language writes only the app's `AppleLanguages` preference. Selecting
system language removes that app override. Relaunch applies the change; this avoids
mixing existing AppKit windows and cached Bundle resources. Recording, translation
languages, provider codes, stored user content and accessibility identifiers are unchanged.

Use SwiftUI localized literals or `String(localized:)` for presentation text. Keep
user-entered names, transcripts, device names, enum raw values and protocol fields plain.
Dynamic UI helper labels need a localized key or an explicitly localized caller.
Use the app's resolved Bundle language for the policy URL and language display names.
Do not manufacture interpolation keys with `%@`: Swift emits `%lld` for Int values.

Checks:

```sh
python3 scripts/check-localization.py
# After a build/test with SWIFT_EMIT_LOC_STRINGS=YES:
python3 scripts/check-localization.py /path/to/DerivedData/Build/Intermediates.noindex/Diduny.build/Test/Diduny.build/Objects-normal/arm64
```

The compiler-output argument verifies typed interpolations and conditional SwiftUI keys
in addition to catalog parity, format placeholders and direct static UI coverage.
The existing SettingsStorageProviderTests contain the app preference and resource tests.
Run tests with configuration `Test`, not `Debug`, to use the separate test preferences domain.

For account/payment review, `python3 scripts/build-payment-demo.py` builds an isolated
native shell. Start the backend's `services/ears-proxy/scripts/payment-demo.ts` separately;
it listens only on loopback port19439 and simulates the payment provider. This shell is
not the full onboarding or a live WayForPay test. No card entry or money is involved.

At implementation handoff the Mac was locked: Ukrainian layout, native language changes
across relaunch, full onboarding and full-app accessibility traversal remain pending.
The compile/catalog checks establish string availability, not visual completeness.
External OS/provider diagnostics may retain the external system's language.
