#!/usr/bin/env python3
"""Check native translations without building, networking, or modifying files."""
from collections import Counter
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'SDImport/Packages/SDImportCore/Sources'
RESOURCES = SOURCES / 'SDImportCore/Resources'
LANGUAGES = {'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es', 'pt-BR', 'it'}
FORMAT = re.compile(r'%(?:(\d+)\$)?(lld|llu|ld|lu|lf|[difu@%])')
PAIR = re.compile(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;')


def strings(path):
    text = path.read_text()
    pairs = [(json.loads(m[1]), json.loads(m[2])) for m in PAIR.finditer(text)]
    assert len(dict(pairs)) == len(pairs), f'{path}: duplicate keys'
    remainder = PAIR.sub('', re.sub(r'/\*.*?\*/', '', text, flags=re.S))
    assert not remainder.strip(), f'{path}: invalid strings syntax'
    return dict(pairs)


def arguments(value):
    result = Counter()
    index = 0
    for match in FORMAT.finditer(value):
        if match[2] == '%':
            continue
        index += 1
        result[(int(match[1] or index), match[2])] += 1
    # Catch stray format directives which could crash formatting or eat arguments.
    assert '%' not in FORMAT.sub('', value), f'Invalid format directive: {value}'
    return result


def normalized_key(value):
    return FORMAT.sub(lambda m: '%' if m[2] == '%' else '{argument}', value)


def end_string(source, start):
    if source[start:start + 3] == '"""':
        end = source.index('"""', start + 3)
        return end + 3
    index = start + 1
    while index < len(source):
        if source[index] == '"':
            return index + 1
        if source[index:index + 2] == '\\(':
            index = end_interpolation(source, index + 1)
        elif source[index] == '\\':
            index += 2
        else:
            index += 1
    raise AssertionError('Unterminated Swift string')


def end_interpolation(source, start):
    depth, index = 1, start + 1
    while depth:
        char = source[index]
        if char == '"':
            index = end_string(source, index)
        else:
            depth += (char == '(') - (char == ')')
            index += 1
    return index


def normalized_literal(literal):
    chunks, index = [], 1
    while index < len(literal) - 1:
        if literal[index:index + 2] == '\\(':
            chunks.append('{argument}')
            index = end_interpolation(literal, index + 1)
        elif literal[index:index + 3] == '\\u{':
            end = literal.index('}', index + 3)
            chunks.append(chr(int(literal[index + 3:end], 16)))
            index = end + 1
        elif literal[index] == '\\':
            chunks.append(json.loads('"' + literal[index:index + 2] + '"'))
            index += 2
        else:
            chunks.append(literal[index])
            index += 1
    return ''.join(chunks)


def check():
    assert {p.stem for p in RESOURCES.glob('*.lproj')} == LANGUAGES
    english = strings(RESOURCES / 'en.lproj/Localizable.strings')
    source_keys = {normalized_key(key) for key in english}
    occurrences = 0
    covered_targets = set()
    for path in SOURCES.rglob('*.swift'):
        source = path.read_text()
        for call in re.finditer(r'\b(?:L10n\.)?tr\(\s*"', source):
            start = call.end() - 1
            literal = source[start:end_string(source, start)]
            normalized = normalized_literal(literal)
            assert normalized in source_keys, f'{path.relative_to(ROOT)}: missing translation key for {literal}'
            occurrences += 1
            covered_targets.add(path.relative_to(SOURCES).parts[0])
    assert covered_targets == {'SDImportApp', 'SDImportCore', 'SDImportCommerce'}, 'Missing native presentation target coverage'
    # Helper errors cross a process boundary: persist recognized messages so the
    # containing app, whose preferred language may differ, translates them.
    agent = (SOURCES / 'SDImportAgent/main.swift').read_text()
    assert not re.search(r'message:\s*L10n\.tr', agent), 'Do not persist helper-language translations'
    agent_messages = re.findall(r'message:\s*("(?:\\.|[^"\\])*")', agent)
    assert agent_messages and all(json.loads(value) in english for value in agent_messages)

    for language in sorted(LANGUAGES):
        folder = RESOURCES / f'{language}.lproj'
        catalog = strings(folder / 'Localizable.strings')
        assert set(catalog) == set(english), f'{language}: missing or extra keys'
        for key, value in catalog.items():
            assert value.strip(), f'{language}: empty {key}'
            assert arguments(key) == arguments(value), f'{language}: argument mismatch for {key}'
            assert not re.search(r'\{\d+\}', value), f'{language}: unconverted placeholder in {key}'
        plural = plistlib.loads((folder / 'Localizable.stringsdict').read_bytes())
        assert set(plural) == set(plistlib.loads((RESOURCES / 'en.lproj/Localizable.stringsdict').read_bytes()))
        for key, rule in plural.items():
            assert key in catalog and arguments(key) == Counter({(1, 'lld'): 1})
            assert rule['NSStringLocalizedFormatKey'] == '%#@count@'
            count = rule['count']
            assert count['NSStringFormatSpecTypeKey'] == 'NSStringPluralRuleType'
            assert count['NSStringFormatValueTypeKey'] == 'lld'
            for category in ['one', 'other']:
                assert arguments(count[category]) == arguments(key), f'{language}: plural mismatch {key}'
        print(f'{language}: {len(catalog)} keys, {len(plural)} plural rules OK')

    for name in ['SDImport-Info.plist', 'SDImportAgent-Info.plist']:
        info = plistlib.loads((ROOT / 'SDImport/Packaging/MacAppStore' / name).read_bytes())
        assert set(info['CFBundleLocalizations']) == LANGUAGES, name
    helper = (SOURCES / 'SDImportCore/Localization/L10n.swift').read_text()
    declared = re.search(r'supportedLanguages = (\[.*?\])', helper)[1]
    assert set(json.loads(declared)) == LANGUAGES
    build = (ROOT / 'script/build_and_run.sh').read_text()
    assert '$APP_RESOURCES/SDImportCore_SDImportCore.bundle' in build
    assert '$AGENT_CONTENTS/Resources/SDImportCore_SDImportCore.bundle' in build
    print(f'{occurrences} localized source expressions covered; bundle declarations OK')


if __name__ == '__main__':
    check()
