#!/usr/bin/env python3
"""Verify a staged app and helper using an isolated Foundation-only probe.

Runs no importer, GUI application, helper registration, or mounted-volume access.
The probe links the actual L10n source and fails if it falls back to build resources.
"""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from check_localizations import LANGUAGES, RESOURCES, ROOT, SOURCES, strings

# Actual helper producers persist these English records, irrespective of their
# process language. Feed them into receivers with different app preferences.
AGENT_MESSAGES = [json.loads(value) for value in re.findall(
    r'message:\s*("(?:\\.|[^"\\])*")', (SOURCES / 'SDImportAgent/main.swift').read_text()
)]

EXPECTED = {
    'en': 'Settings', 'zh-Hans': '设置', 'zh-Hant': '設定', 'ja': '設定',
    'ko': '설정', 'de': 'Einstellungen', 'fr': 'Réglages', 'es': 'Ajustes',
    'pt-BR': 'Ajustes', 'it': 'Impostazioni', 'es-MX': 'Ajustes',
    'fr-CA': 'Réglages', 'zh-HK': '設定', 'nl-NL': 'Settings',
}
PROBE = r'''
import Foundation
extension Bundle {
    static var module: Bundle { fatalError("Packaged resource lookup failed") }
}
@main
struct LocalizationProbe {
    static func main() throws {
        let count = 1
        let path = "/synthetic/100% 写真 %@.jpg"
        let reason = "Sentinel 50%"
        let copyError: Error = SDImportError.copySizeMismatch(expected: 12, actual: 4)
        let setupError: Error = SDImportError.missingApplicationSupportDirectory
        guard let recordsIndex = CommandLine.arguments.firstIndex(of: "--helper-records"),
              recordsIndex + 1 < CommandLine.arguments.count else {
            fatalError("Missing helper records for localization probe")
        }
        let helperRecords = try JSONDecoder().decode(
            [String].self,
            from: Data(CommandLine.arguments[recordsIndex + 1].utf8)
        )
        let result: [String: Any] = [
            "settings": L10n.tr("Settings"),
            "files": L10n.tr("\(count) files"),
            "scanStatus": L10n.tr("Scan complete. \(count) files were imported on another Mac"),
            "error": L10n.tr("Could not access \(path): \(reason)"),
            "copyFailure": copyError.localizedDescription,
            "setupFailure": setupError.localizedDescription,
            "storedExcluded": L10n.storedMessage("excluded_by_import_selection"),
            "helperErrors": helperRecords.map { L10n.storedMessage($0) },
            "bundle": L10n.resourceBundle.bundleURL.path,
            "fallback": L10n.tr("A missing development message")
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
'''


def verify(app):
    app = app.resolve()
    helper = app / 'Contents/Library/LoginItems/SDImportAgent.app'
    with tempfile.TemporaryDirectory(prefix='sd-import-l10n-') as scratch:
        scratch = Path(scratch)
        source = scratch / 'Probe.swift'
        source.write_text(PROBE)
        binary = scratch / 'Probe'
        subprocess.run([
            'xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(scratch / 'module-cache'),
            str(ROOT / 'SDImport/Packages/SDImportCore/Sources/SDImportCore/Localization/L10n.swift'),
            str(ROOT / 'SDImport/Packages/SDImportCore/Sources/SDImportCore/Models/SDImportError.swift'),
            str(source), '-o', str(binary),
        ], check=True)
        for index, target in enumerate([app, helper]):
            assert target.is_dir(), f'Missing app/helper: {target}'
            info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
            assert set(info['CFBundleLocalizations']) == LANGUAGES, f'{target}: advertised languages'
            resource = target / 'Contents/Resources/SDImportCore_SDImportCore.bundle'
            assert resource.is_dir(), f'{target}: missing shared localization bundle'
            folders = {p.stem for p in resource.rglob('*.lproj')}
            assert folders == LANGUAGES, f'{target}: missing language resources: {LANGUAGES - folders}'
            for folder in resource.rglob('*.lproj'):
                assert (folder / 'Localizable.strings').is_file()
                assert (folder / 'Localizable.stringsdict').is_file()
                source_folder = RESOURCES / folder.name
                packaged_strings = json.loads(subprocess.check_output([
                    'plutil', '-convert', 'json', '-o', '-', str(folder / 'Localizable.strings'),
                ]))
                assert packaged_strings == strings(source_folder / 'Localizable.strings'), f'{target}: stale {folder.name} catalog'
                packaged_plurals = plistlib.loads((folder / 'Localizable.stringsdict').read_bytes())
                source_plurals = plistlib.loads((source_folder / 'Localizable.stringsdict').read_bytes())
                assert packaged_plurals == source_plurals, f'{target}: stale {folder.name} plural rules'
            probe = scratch / f'Probe{index}.app'
            contents = probe / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Resources').mkdir()
            shutil.copy2(binary, contents / 'MacOS/Probe')
            shutil.copytree(resource, contents / 'Resources' / resource.name)
            probe_info = {
                'CFBundleExecutable': 'Probe', 'CFBundleIdentifier': f'example.localization.probe{index}',
                'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': info['CFBundleDevelopmentRegion'],
                'CFBundleLocalizations': info['CFBundleLocalizations'],
            }
            (contents / 'Info.plist').write_bytes(plistlib.dumps(probe_info))
            for language, expected in EXPECTED.items():
                result = subprocess.run([
                    str(contents / 'MacOS/Probe'), '-AppleLanguages', f'("{language}")',
                    '-AppleLocale', language.replace('-', '_'),
                    '--helper-records', json.dumps(AGENT_MESSAGES),
                ], check=True, capture_output=True, text=True)
                value = json.loads(result.stdout)
                assert value['settings'] == expected, (target.name, language, value)
                assert value['bundle'].startswith(str(contents / 'Resources')), value
                assert value['fallback'] == 'A missing development message', value
                assert '/synthetic/100% 写真 %@.jpg' in value['error'], value
                assert 'Sentinel 50%' in value['error'], value
                assert '12' in value['copyFailure'] and '4' in value['copyFailure'], value
                assert 'copySizeMismatch' not in value['copyFailure'], value
                assert 'missingApplicationSupportDirectory' not in value['setupFailure'], value
                assert 'excluded_by_import_selection' not in value['storedExcluded'], value
                matched_language = {'es-MX': 'es', 'fr-CA': 'fr', 'zh-HK': 'zh-Hant', 'nl-NL': 'en'}.get(language, language)
                receiver_catalog = strings(RESOURCES / f'{matched_language}.lproj/Localizable.strings')
                assert AGENT_MESSAGES and value['helperErrors'] == [receiver_catalog[message] for message in AGENT_MESSAGES], value
                if language == 'de':
                    assert value['files'] == '1 Datei', value
                    assert value['scanStatus'] == 'Scan abgeschlossen. 1 Datei wurde auf einem anderen Mac importiert', value
                    assert value['storedExcluded'] == 'Ausgeschlossen', value
                    assert value['setupFailure'] == 'Der Anwendungssupportordner ist nicht verfügbar.', value
                if language == 'en':
                    assert value['files'] == '1 file', value
                    assert value['scanStatus'] == 'Scan complete. 1 file was imported on another Mac', value
            print(f'{target.name}: 10 languages + 4 regional/fallback preferences, packaged lookup and formatting OK')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: python3 script/check_localization_bundles.py /path/to/App.app')
    verify(Path(sys.argv[1]))
