#!/usr/bin/env python3
"""Check a built macOS bundle, localization, and PDF/A CLI; no ISO certification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


LANGUAGES = ('en', 'it', 'es', 'de', 'fr', 'zh-Hans', 'zh-Hant', 'ja')
LOCALIZATION_TABLES = ('Localizable', 'AppShortcuts', 'InfoPlist')


def packaged_environment():
    environment = os.environ.copy()
    # Resource lookup must succeed using the app alone, even from a SwiftPM
    # test shell with development resource bundle overrides.
    for key in ('PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL'):
        environment.pop(key, None)
    return environment


def rule_statuses(report):
    """Compare stable IDs/statuses, independently of localized descriptions."""
    result = {}
    for section in ('rules', 'modelChecks'):
        statuses = {rule['id']: rule['status'] for rule in report[section]}
        assert len(statuses) == len(report[section]), (report['profile'], section, 'duplicate IDs')
        result[section] = statuses
    return result


def packaged_strings(path):
    """Have Apple's parser read the actual packaged OpenStep strings table."""
    run = subprocess.run(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)],
                         check=True, capture_output=True, text=True, timeout=30)
    table = json.loads(run.stdout)
    assert isinstance(table, dict) and table, str(path)
    assert all(isinstance(key, str) and isinstance(value, str) and value
               for key, value in table.items()), str(path)
    return table


def check_packaged_localization(app, binary, directory):
    resources = app / 'Contents/Resources'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleDevelopmentRegion'] == 'en'
    assert set(info['CFBundleLocalizations']) == set(LANGUAGES)
    assert len(info['CFBundleLocalizations']) == len(LANGUAGES)
    assert {path.name for path in resources.glob('*.lproj') if path.is_dir()} == {
        language + '.lproj' for language in LANGUAGES
    }
    tables = {language: {
        name: packaged_strings(resources / (language + '.lproj') / (name + '.strings'))
        for name in LOCALIZATION_TABLES
    } for language in LANGUAGES}
    counts = {name: len(tables['en'][name]) for name in LOCALIZATION_TABLES}
    for language in LANGUAGES:
        for name in LOCALIZATION_TABLES:
            assert set(tables[language][name]) == set(tables['en'][name]), (language, name)
            assert len(tables[language][name]) == counts[name], (language, name)
        phrase = 'Unisci documenti con ${applicationName}'
        assert '${applicationName}' in tables[language]['AppShortcuts'][phrase], language
        assert tables[language]['InfoPlist']['PDF Document'], language

    # AppleLanguages is supplied only in this child process's argument domain.
    # No defaults command, preference file, or global language setting is changed.
    cases = [([language], language) for language in LANGUAGES]
    cases += [([preference], language) for preference, language in (
        ('it-IT', 'it'), ('es-MX', 'es'), ('de-AT', 'de'), ('fr-CA', 'fr'),
        ('en-GB', 'en'), ('ja-JP', 'ja'), ('zh-CN', 'zh-Hans'), ('zh-TW', 'zh-Hant'),
        ('zh-Hans-TW', 'zh-Hans'), ('zh-Hant-CN', 'zh-Hant'),
    )]
    cases += [(['pt-BR', 'fr-CA'], 'fr'), (['pt-BR', 'ru-RU', 'ar-SA'], 'en')]
    expected_counts = {language: counts['Localizable'] for language in LANGUAGES}
    label_keys = {'open': 'Apri…', 'save': 'Salva', 'cancel': 'Annulla'}
    environment = packaged_environment()
    results = []
    for preferences, selected in cases:
        argument = '(' + ', '.join(json.dumps(code) for code in preferences) + ')'
        run = subprocess.run([str(binary), '-AppleLanguages', argument, '--cli', 'language'],
                             cwd=directory, env=environment, capture_output=True,
                             text=True, timeout=30, check=True)
        report = json.loads(run.stdout)
        assert report['selectedLanguage'] == selected, (preferences, report)
        assert report['supportedLanguages'] == list(LANGUAGES), preferences
        assert report['catalogueCounts'] == expected_counts, preferences
        # Prove the ordered process preferences reached Foundation rather than
        # silently testing the language already selected on the build machine.
        normalize = lambda code: code.replace('_', '-').lower()
        assert list(map(normalize, report['preferredLanguages'])) == list(map(normalize, preferences)), preferences
        expected_labels = {label: tables[selected]['Localizable'][key]
                           for label, key in label_keys.items()}
        assert report['labels'] == expected_labels, (preferences, report['labels'], expected_labels)
        results.append({'preferences': preferences, 'selected': selected})
    return {'packaged_localizations': list(LANGUAGES), 'localization_table_entries': counts,
            'language_selection_cases': results, 'system_preferences_modified': False}

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
args = parser.parse_args()
app = args.app.resolve()
resources = app / 'Contents/Resources'
binary = app / 'Contents/MacOS/CartaPDF'
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)
# Apple lipo requires input files before -verify_arch. Select the Xcode tool,
# rather than a potentially different executable provided by the runner PATH.
subprocess.run(['/usr/bin/xcrun', 'lipo', str(binary), '-verify_arch', 'arm64'], check=True)
profiles = json.loads((resources / 'PDFAProfiles/MANIFEST.json').read_text())
font = json.loads((resources / 'PDFFontData/MANIFEST.json').read_text())
for root, entries in [(resources / 'PDFAProfiles', profiles['profiles']), (resources / 'PDFFontData', font['items'])]:
    for entry in entries:
        assert hashlib.sha256((root / entry['file']).read_bytes()).hexdigest() == entry['sha256']

# A synthetic page with no XMP is deliberately nonconforming. Resource absence
# must never masquerade as its expected violation or as an empty catalogue.
objects = {
    1: b'<< /Type /Catalog /Pages 2 0 R >>',
    2: b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
    3: b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>',
}
data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
offsets = {}
for number, body in objects.items():
    offsets[number] = len(data)
    data += str(number).encode() + b' 0 obj\n' + body + b'\nendobj\n'
start = len(data)
data += b'xref\n0 4\n0000000000 65535 f \n'
for number in range(1, 4):
    data += f'{offsets[number]:010d} 00000 n \n'.encode()
data += f'trailer\n<< /Root 1 0 R /Size 4 /ID [<1234><5678>] >>\nstartxref\n{start}\n%%EOF\n'.encode()
digest = hashlib.sha256(data).hexdigest()
matrix = []
locale_profile_checks = 0
with tempfile.TemporaryDirectory(prefix='CartaPDF-built-app-') as directory:
    localization = check_packaged_localization(app, binary, directory)
    source = Path(directory) / 'synthetic.pdf'
    source.write_bytes(data)
    for entry in profiles['profiles']:
        profile = entry['file'].removeprefix('PDFA-').removesuffix('.xml').lower()
        run = subprocess.run([str(binary), '--cli', 'validate-pdfa', str(source), profile],
                             cwd=directory, capture_output=True, text=True, timeout=30)
        report = json.loads(run.stdout)
        assert len(report['rules']) == entry['rule_count'], profile
        assert report['modelChecks'] and report['scopeGaps'], profile
        assert report['coverageComplete'] is False and report['verdict'] == 'nonconforming', profile
        assert run.returncode == 2 and report['sha256'] == digest, profile
        assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
        matrix.append(profile)
        baseline_statuses = rule_statuses(report)
        for language in LANGUAGES:
            # Localized diagnostic text must not alter a rule's classification,
            # overall verdict, coverage decision, exit status, or source bytes.
            argument = '(' + json.dumps(language) + ')'
            localized_run = subprocess.run(
                [str(binary), '-AppleLanguages', argument, '--cli',
                 'validate-pdfa', str(source), profile],
                cwd=directory, env=packaged_environment(), capture_output=True,
                text=True, timeout=30)
            localized_report = json.loads(localized_run.stdout)
            for key in ('profile', 'verdict', 'coverageComplete', 'sha256'):
                assert localized_report[key] == report[key], (language, profile, key)
            assert rule_statuses(localized_report) == baseline_statuses, (language, profile, 'rule statuses')
            assert localized_run.returncode == run.returncode, (language, profile, 'exit status')
            assert hashlib.sha256(source.read_bytes()).hexdigest() == digest, (language, profile, 'input changed')
            locale_profile_checks += 1
assert len(matrix) == 11
assert locale_profile_checks == 88
print(json.dumps({'packaged_CLI_profiles': matrix, 'catalogue_entries': sum(e['rule_count'] for e in profiles['profiles']),
                  'font_resources': len(font['items']), 'signature': 'passed', 'architecture': 'arm64',
                  'input_unchanged': True, 'complete_ISO_validation_proven': False,
                  'locale_profile_checks': locale_profile_checks, 'locale_model_statuses_unchanged': True,
                  **localization}))
