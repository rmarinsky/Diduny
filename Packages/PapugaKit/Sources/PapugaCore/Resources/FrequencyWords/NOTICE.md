# FrequencyWords notice

`frequency_uk.txt` and `frequency_en.txt` derive from the 50,000-word lists in
[hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords), pinned at
commit `525f9b560de45753a5ea01069454e72e9aa541c6`.

The lists are licensed under
[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).

## Changes from the source lists

The shipped files are **filtered**, not verbatim. Regenerate with:

```bash
swift scripts/build-frequency-list.swift uk <raw_uk.txt> papuga/Resources/FrequencyWords/frequency_uk.txt
swift scripts/build-frequency-list.swift en <raw_en.txt> papuga/Resources/FrequencyWords/frequency_en.txt
```

The filter keeps only entries the macOS dictionary for that language accepts,
and drops single characters, digits and symbols.

| List | Source | Shipped | Dropped on shape | Dropped as Russian | Rejected by macOS |
|---|---|---|---|---|---|
| `uk` | 50,000 | 27,683 | 207 | 3,206 | 18,904 |
| `en` | 50,000 | 36,179 | 722 | — | 13,099 |

The source `uk` list is OpenSubtitles-derived and heavily Russian-contaminated:
`что` was its 8th most frequent "Ukrainian" word (49,617), alongside `это`,
`если`, `тебя`. Because the index promotes anything it contains, Russian was
being accepted as valid Ukrainian — a layout flip could land on a Russian word,
and a guess could rank one above the genuine Ukrainian form.

A blanket Russian-lexicon subtraction would be wrong (`так`, `він`, `тебе` are
legitimately shared), and a count threshold is worse than useless here because
the contaminating words are high-frequency by construction. Letting the macOS
dictionary arbitrate drops `что`/`это`/`если`/`тебя` while keeping
`так`/`він`/`тебе`/`привіт`/`дякую`.

Over-deletion is cheap, but only because the list was demoted first: it is a
ranking signal and a promotion overlay, not the spelling authority (see
`HybridSpellChecker.mappedSpellingStatus`). A valid word dropped here simply
loses its frequency boost and falls through to the system dictionary.

## Supplement

`frequency_uk_supplement.txt` is hand-maintained by this project and carries no
upstream licence obligation. It covers what the OpenSubtitles base structurally
misses: Ukrainian apostrophe forms — the raw list contains **zero**, of any
codepoint — and a tech-vocabulary seed. Counts are synthetic and sit near the
cleaned base list's median (16), so a supplement entry ranks like ordinary
vocabulary rather than dominating.
