# Wrong-layout typing corpus

`corpus.json` is a reviewed, literal oracle shared by two different checks. It is not generated from Papuga's output during testing. `keys` describes physical keys on an ANSI US keyboard, not Unicode text to paste. Ukrainian-PC key 42 (US `\`) produces the apostrophe `ʼ` (U+02BC); key 50 produces `ґ`.

## Automated production-decision integration

```sh
xcodebuild test -project papuga.xcodeproj -scheme papuga -destination 'platform=macOS' -only-testing:papugaTests/AutoFixTypingCorpusTests CODE_SIGNING_ALLOWED=NO
```

Exercises `AutoFixWordEvaluator`, also called by `AutoFixController`: actual Carbon layouts, AppleNL, system spelling, shipped frequency dictionaries, source protection, target selection, punctuation interpretation, and immediate-delivery policy. No mapping result, language score, spelling verdict, or replacement decision is mocked. Each fixture is an individually named XCTest activity. Missing categories and layouts fail instead of silently testing nothing.

Positive cases assert the exact replacement and target layout. Negative cases assert that no automatic replacement is permitted; they do not forbid a non-mutating proposal. English spelling mistakes are separate negatives. The `continuous` cases are intentionally excluded at this layer: pretending a completed phrase is a single token would not test continuation or races.

## Interactive system check

```sh
swift scripts/papuga-autofix-corpus.swift papugaTests/Fixtures/typing/corpus.json /private/tmp/papuga-typing-report.json common.01
swift scripts/papuga-autofix-corpus.swift papugaTests/Fixtures/typing/corpus.json /private/tmp/papuga-continuation-report.json continuous.
# Omit the final prefix to run every case.
```

Requires the installed DEV app, macOS Accessibility/Input Monitoring permissions, US and Ukrainian-PC layouts, and exclusive keyboard focus. Do not use the keyboard or change focus while it runs. It sends physical key codes through System Events, observes TextEdit's actual content and the system's selected layout, and exits nonzero on any mismatch. No Enter-to-accept step is used. Continuous cases type the following word without waiting for a proposal or correction.

The driver restarts only DEV with process-local argument-domain overrides (TextEdit `autoMutate`, automatic layout switching, no custom replacement rules). On success or a caught error it closes only its UUID-named temporary document, restores the starting layout, and relaunches DEV without overrides. It does not rewrite preference files, touch clipboard contents, or close other documents. A forced process termination can bypass cleanup; relaunch DEV normally in that case. Partial completed results are retained on harness errors. Failed/interrupted test documents are retained for inspection (their paths are printed); only successful synthetic documents are deleted.

`observationDelayMS` is the post-input observation delay, not a precise measured latency guarantee. `scenarioElapsedMS` includes typing and automation overhead. The continuation cases are the primary race/lost-input check. This interactive runner is not a CI check and TextEdit results do not prove behavior in Teams, Telegram, browser editors, password fields, or other applications.

## Decision rules and limits

- A real source-language word, protected term, address, number, code token, or ambiguous target must not be silently replaced. A 2–4-character lowercase English token with no `aeiou` vowel may be a system-accepted abbreviation: prefer a cross-script target with at least 999 corpus occurrences only when neither bundled nor learned source vocabulary attests the abbreviation. Uppercase abbreviations and learned terms remain protected. One-character tokens remain unchanged.
- An exact, word-like cross-script dictionary match of at least two characters is evidence independent of AppleNL's language-identification score. Low AppleNL confidence alone must not suppress that match.
- Balanced punctuation stays outside the converted word. When a trailing physical key has two dictionary-valid interpretations, a fourfold corpus-frequency advantage can resolve it; otherwise offer a proposal. Leading physical-letter keys such as `];f` must not be discarded as punctuation.
- Approved single-word replacements bypass the phrase grace timer. Existing unresolved phrases still require whole-range handling so a suffix is not silently abandoned.
- New edge cases belong in this corpus with independently checked literal input/output. Do not change an expected result merely to match current behavior. Record whether the disagreement is a fixture error, a genuine ambiguity, or a product failure.
