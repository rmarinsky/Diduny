#!/usr/bin/env python3
"""Check native catalogs and directly declared static UI text. No user content is translated."""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";')
UI = re.compile(r'\b(?:Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|GroupBox|Menu|Link|ProgressView|ContentUnavailableView|help|accessibilityLabel|accessibilityHint|navigationTitle|alert|confirmationDialog)\(\s*"((?:\\.|[^"\\])*)"')

def unescape(text):
    text = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m[1], 16)), text)
    return json.loads('"' + text + '"')

def catalog(language):
    path = ROOT / f'Diduny/Resources/{language}.lproj/Localizable.strings'
    entries = [(unescape(k), unescape(v)) for k, v in ENTRY.findall(path.read_text())]
    assert len(dict(entries)) == len(entries), f'Duplicate {language} keys'
    return dict(entries)

en, uk = catalog('en'), catalog('uk')
errors = []
if en.keys() != uk.keys():
    errors.append('English and Ukrainian catalog keys differ')
for key in en.keys() & uk.keys():
    tokens = lambda text: sorted(re.findall(r'%(?:\d+\$)?(?:0?\d+)?(?:\.[0-9]+)?(?:lld|ld|d|f|@|%)', text))
    if tokens(key) != tokens(uk[key]):
        errors.append(f'Placeholder mismatch: {key}')
for source in (ROOT / 'Diduny').rglob('*.swift'):
    for match in UI.finditer(source.read_text()):
        if '\\(' in match[1]:
            continue  # Interpolated messages are checked in the extracted catalog/runtime.
        key = unescape(match[1])
        if re.search('[a-zA-Z]', key) and key not in uk:
            errors.append(f'{source.relative_to(ROOT)}: missing {key}')
# With compiler output, also validate typed interpolations and conditional SwiftUI keys.
if len(sys.argv) > 1:
    for path in pathlib.Path(sys.argv[1]).glob('*.stringsdata'):
        data = json.loads(path.read_text())
        for entry in data.get('tables', {}).get('Localizable', []):
            if entry['key'] not in uk:
                errors.append(f"{path.stem}: missing compiler key {entry['key']}")
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print(f'PASS: {len(uk)} matching UK/EN keys; static UI coverage; format placeholders')
