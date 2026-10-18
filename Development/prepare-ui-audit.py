#!/usr/bin/env python3
"""Prepare isolated, language-specific macOS app copies for a manual UI audit.

Uses Python's standard library and Apple's native command-line tools. The app's
Swift sources are not rebuilt, and this script never opens a GUI or writes to
the user's language preferences. Open the generated copies with a UI tool.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


LANGUAGES = ('en', 'it', 'es', 'de', 'fr', 'zh-Hans', 'zh-Hant', 'ja')
TABLES = ('Localizable', 'AppShortcuts', 'InfoPlist')
LAUNCHER_SOURCE = r'''
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int isolated_directory(const char *executable_directory,
                              const char *relative, const char *key,
                              int trailing_slash) {
    char candidate[PATH_MAX], resolved[PATH_MAX], value[PATH_MAX];
    int size = snprintf(candidate, sizeof(candidate), "%s/%s",
                        executable_directory, relative);
    if (size < 0 || (size_t)size >= sizeof(candidate) ||
        realpath(candidate, resolved) == NULL) return -1;
    size = snprintf(value, sizeof(value), trailing_slash ? "%s/" : "%s", resolved);
    if (size < 0 || (size_t)size >= sizeof(value)) return -1;
    return setenv(key, value, 1);
}

int main(int argc, char **argv) {
    char executable[PATH_MAX], directory[PATH_MAX], core[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 ||
        realpath(executable, directory) == NULL) {
        fputs("Cannot locate the UI audit launcher.\n", stderr);
        return 125;
    }
    char *last_separator = strrchr(directory, '/');
    if (last_separator == NULL) return 125;
    *last_separator = '\0';
    int length = snprintf(core, sizeof(core), "%s/CartaPDF-core", directory);
    if (length < 0 || (size_t)length >= sizeof(core)) return 125;

    if (isolated_directory(directory, "../../../Sandboxes/@LANGUAGE@/Home", "CARTAPDF_UI_AUDIT_HOME", 0) ||
        isolated_directory(directory, "../../../Sandboxes/@LANGUAGE@/Home", "CFFIXED_USER_HOME", 0) ||
        isolated_directory(directory, "../../../Sandboxes/@LANGUAGE@/Temporary", "TMPDIR", 1)) {
        fputs("Cannot isolate the UI audit directories.\n", stderr);
        return 125;
    }
    unsetenv("PACKAGE_RESOURCE_BUNDLE_PATH");
    unsetenv("PACKAGE_RESOURCE_BUNDLE_URL");

    char **arguments = calloc((size_t)argc + 3, sizeof(char *));
    if (arguments == NULL) return 125;
    arguments[0] = core;
    arguments[1] = "-AppleLanguages";
    arguments[2] = "(\"@LANGUAGE@\")";
    for (int index = 1; index < argc; ++index) arguments[index + 2] = argv[index];
    arguments[argc + 2] = NULL;
    execv(core, arguments);
    fprintf(stderr, "Cannot execute the UI audit app: %s\n", strerror(errno));
    free(arguments);
    return 126;
}
'''


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def run(arguments: list[str], *, cwd: Path | None = None,
        environment: dict[str, str] | None = None, timeout: int = 120) -> str:
    result = subprocess.run(arguments, cwd=cwd, env=environment,
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Do not echo environment values or an unbounded native diagnostic.
        raise RuntimeError(f'{Path(arguments[0]).name} failed with exit code {result.returncode}')
    return result.stdout


def strings_table(path: Path) -> dict[str, str]:
    values = json.loads(run(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)]))
    if not isinstance(values, dict) or not values or not all(
            isinstance(key, str) and isinstance(value, str) and value
            for key, value in values.items()):
        raise ValueError('A packaged localization table is empty or invalid')
    return values


def copy_without_metadata(source: str, destination: str) -> str:
    result = shutil.copyfile(source, destination)
    shutil.copymode(source, destination)
    return result


def prepare(base: Path, output: Path) -> dict:
    info_path = base / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    original_name = info['CFBundleExecutable']
    if not isinstance(original_name, str) or Path(original_name).name != original_name:
        raise ValueError('The base app has an invalid executable name')
    if original_name == 'CartaPDF-core':
        raise ValueError('Use the original app, not an already wrapped audit app')
    binary = base / 'Contents/MacOS' / original_name
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError('The base app executable is missing or not executable')
    if set(info.get('CFBundleLocalizations', [])) != set(LANGUAGES):
        raise ValueError('The base app does not declare all eight localization variants')

    resources = base / 'Contents/Resources'
    tables = {language: {table: strings_table(resources / f'{language}.lproj' / f'{table}.strings')
                         for table in TABLES} for language in LANGUAGES}
    counts = {table: len(tables['en'][table]) for table in TABLES}
    for language in LANGUAGES:
        for table in TABLES:
            if set(tables[language][table]) != set(tables['en'][table]):
                raise ValueError(f'Packaged {table} keys differ for {language}')
    expected_counts = {language: counts['Localizable'] for language in LANGUAGES}
    architectures = run(['/usr/bin/xcrun', 'lipo', '-archs', str(binary)]).strip().split()
    if not architectures or any(value not in ('arm64', 'x86_64') for value in architectures):
        raise ValueError('Unsupported base app architecture')

    support = output / 'Support'
    support.mkdir()
    base_hashes = {
        'info_plist': digest(info_path),
        'executable': digest(binary),
        'localization_tables': {
            f'{language}.lproj/{table}.strings': digest(resources / f'{language}.lproj' / f'{table}.strings')
            for language in LANGUAGES for table in TABLES
        },
    }
    manifest = {
        'schema_version': 1,
        'purpose': 'Isolated app copies for a manual localization UI audit',
        'base_app_name': base.name,
        'base_bundle_identifier': info.get('CFBundleIdentifier'),
        'base_sha256': base_hashes,
        'architectures': architectures,
        'packaged_table_entries': counts,
        'system_preferences_modified': False,
        'gui_launched': False,
        'manual_ui_audit_completed': False,
        'apps': [],
    }

    for language in LANGUAGES:
        app = output / f'CartaPDF UI {language}.app'
        sandbox = output / 'Sandboxes' / language
        audit_home = sandbox / 'Home'
        temporary = sandbox / 'Temporary'
        audit_home.mkdir(parents=True)
        temporary.mkdir()
        shutil.copytree(base, app, symlinks=True, copy_function=copy_without_metadata)
        executable_directory = app / 'Contents/MacOS'
        core = executable_directory / 'CartaPDF-core'
        (executable_directory / original_name).rename(core)
        clone_info = dict(info)
        clone_info['CFBundleIdentifier'] = f'it.cartapdf.uiaudit.{language}'
        clone_info['CFBundleName'] = f'CartaPDF UI {language}'
        clone_info['CFBundleDisplayName'] = f'CartaPDF UI {language}'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(clone_info))

        source = support / f'launcher-{language}.c'
        source.write_text(LAUNCHER_SOURCE.replace('@LANGUAGE@', language), encoding='utf-8')
        launcher = executable_directory / original_name
        compile_arguments = ['/usr/bin/xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                             '-O2', '-mmacosx-version-min=14.0']
        for architecture in architectures:
            compile_arguments.extend(['-arch', architecture])
        compile_arguments.extend([str(source), '-o', str(launcher)])
        run(compile_arguments)
        launcher.chmod(0o755)
        run(['/usr/bin/xattr', '-cr', str(app)])
        run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app)])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])

        environment = os.environ.copy()
        for key in ('PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL'):
            environment.pop(key, None)
        # The launcher also sets these values itself for LaunchServices/CUA.
        environment.update(CARTAPDF_UI_AUDIT_HOME=str(audit_home), CFFIXED_USER_HOME=str(audit_home),
                           TMPDIR=str(temporary) + '/')
        report = json.loads(run([str(launcher), '--cli', 'language'], cwd=sandbox,
                                environment=environment, timeout=30))
        if report.get('selectedLanguage') != language:
            raise ValueError(f'The {language} audit launcher selected the wrong language')
        if report.get('supportedLanguages') != list(LANGUAGES) or report.get('catalogueCounts') != expected_counts:
            raise ValueError(f'The {language} audit launcher did not load the packaged catalogues')
        normalize = lambda value: value.replace('_', '-').lower()
        if [normalize(value) for value in report.get('preferredLanguages', [])] != [normalize(language)]:
            raise ValueError(f'The {language} process did not receive its isolated language preference')
        expected_labels = {label: tables[language]['Localizable'][key] for label, key in
                           {'open': 'Apri…', 'save': 'Salva', 'cancel': 'Annulla'}.items()}
        if report.get('labels') != expected_labels:
            raise ValueError(f'The {language} UI labels do not match the packaged translations')
        clone_resource_hashes = {
            relative: digest(app / 'Contents/Resources' / relative)
            for relative in base_hashes['localization_tables']
        }
        if clone_resource_hashes != base_hashes['localization_tables']:
            raise ValueError('Wrapping changed packaged localization resources')
        manifest['apps'].append({
            'language': language,
            'path': app.relative_to(output).as_posix(),
            'bundle_identifier': clone_info['CFBundleIdentifier'],
            'home': audit_home.relative_to(output).as_posix(),
            'temporary_directory': temporary.relative_to(output).as_posix(),
            'launcher_source': source.relative_to(output).as_posix(),
            'cli_language': report,
            'sha256': {'info_plist': digest(app / 'Contents/Info.plist'),
                       'core_executable': digest(core), 'launcher_executable': digest(launcher),
                       'launcher_source': digest(source)},
            'resource_hashes_match_base': True,
            'ad_hoc_signature': 'verified',
        })
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Existing macOS .app bundle to copy')
    parser.add_argument('--output', type=Path, help='New output directory; defaults to a temporary directory')
    arguments = parser.parse_args()
    base = arguments.app.expanduser().resolve()
    if base.suffix != '.app' or not base.is_dir():
        parser.error('app must be an existing .app directory')
    if arguments.output is None:
        output = Path(tempfile.mkdtemp(prefix='CartaPDF-UIAudit-')).resolve()
    else:
        output = arguments.output.expanduser().resolve()
        if output == base or base in output.parents:
            parser.error('output must be outside the base app')
        output.mkdir(parents=True, exist_ok=False)
    try:
        manifest = prepare(base, output)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'failed', 'output': str(output), 'error': str(error)}))
        return 1
    print(json.dumps({'status': 'prepared', 'output': str(output), 'manifest': 'manifest.json',
                      'languages': list(LANGUAGES), 'apps': len(manifest['apps']),
                      'catalogue_entries': manifest['packaged_table_entries']['Localizable'],
                      'system_preferences_modified': False, 'gui_launched': False}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
