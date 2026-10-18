#!/usr/bin/env python3
"""Export native localization snapshots with opt-in XCTest and validate evidence.

Pass a synthetic PDF created with Development/make-ui-audit-fixture.py. Eight
sequential child processes select their language through launch arguments.
This driver performs no desktop input and does not certify a complete GUI,
linguistic, accessibility, or PDF/A audit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import zlib


ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ('en', 'it', 'es', 'de', 'fr', 'zh-Hans', 'zh-Hant', 'ja')
TEST = 'CartaPDFTests.CartaUISnapshotTests/testExportNativeInterfaceSnapshotsWhenRequested'
SNAPSHOT_IDS = {
    'editor', 'editor-text-formatting', 'tools', 'preferences', 'forms-constrained', 'forms',
    'keyboard-annotations', 'workflow-merge', 'workflow-split', 'workflow-layout',
    'workflow-numbering', 'workflow-crop', 'ocr', 'ocr-minimum', 'export', 'export-minimum',
    'export-csv', 'structure-objects', 'structure-original', 'structure-preflight',
    'structure-certificates', 'pdfa', 'pdfa-minimum',
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def native_environment() -> dict[str, str]:
    # Preserve HOME rather than assigning a different meaning to that system
    # variable. Do not propagate credentials or unrelated development overrides.
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
    for key in ('HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_CTYPE'):
        if key in os.environ:
            environment[key] = os.environ[key]
    developer = os.environ.get('DEVELOPER_DIR')
    standard = Path('/Applications/Xcode.app/Contents/Developer')
    if developer and Path(developer).is_dir() and not developer.endswith('/CommandLineTools'):
        environment['DEVELOPER_DIR'] = developer
    elif standard.is_dir():
        environment['DEVELOPER_DIR'] = str(standard)
    else:
        raise ValueError('A full Xcode installation is required for the native XCTest runner')
    return environment


def run_logged(arguments: list[str], environment: dict[str, str], log: Path,
               timeout: int) -> dict:
    with log.open('wb') as stream:
        try:
            result = subprocess.run(arguments, cwd=ROOT, env=environment, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=timeout)
            return {'exit_code': result.returncode, 'timed_out': False}
        except subprocess.TimeoutExpired:
            return {'exit_code': None, 'timed_out': True}


def find_products() -> tuple[Path, Path]:
    scratch = Path(tempfile.gettempdir()) / f'CartaPDF-native-tests-{os.getuid()}' / 'build'
    bundles = [path for path in scratch.rglob('CartaPDFTests.xctest') if path.is_dir()]
    if not bundles:
        raise ValueError('No CartaPDFTests.xctest product exists; run without --skip-build first')
    valid = [(path, path.parent / 'CartaPDF_CartaPDF.bundle') for path in bundles
             if (path.parent / 'CartaPDF_CartaPDF.bundle').is_dir()]
    if len(valid) != 1:
        raise ValueError('Expected exactly one native XCTest product with its sibling resource bundle')
    return valid[0]


def paeth(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    distances = (abs(prediction - left), abs(prediction - above), abs(prediction - upper_left))
    if distances[0] <= distances[1] and distances[0] <= distances[2]:
        return left
    return above if distances[1] <= distances[2] else upper_left


def png_variation(path: Path) -> tuple[int, int, bool]:
    """Validate native PNG chunks and compare reconstructed pixel samples."""
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Snapshot is not a PNG')
    offset, compressed, header, palette = 8, bytearray(), None, None
    found_end = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError('Truncated PNG chunk')
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 8 + length
        if end + 4 > len(data):
            raise ValueError('Truncated PNG payload')
        payload = data[offset + 8:end]
        if (zlib.crc32(kind + payload) & 0xffffffff) != struct.unpack_from('>I', data, end)[0]:
            raise ValueError('PNG checksum mismatch')
        if kind == b'IHDR':
            if header is not None or length != 13:
                raise ValueError('Invalid PNG header')
            header = struct.unpack('>IIBBBBB', payload)
        elif kind == b'PLTE':
            palette = payload
        elif kind == b'IDAT':
            compressed.extend(payload)
        elif kind == b'IEND':
            found_end = True
            if end + 4 != len(data):
                raise ValueError('Unexpected bytes after the PNG end')
            break
        offset = end + 4
    if not found_end or header is None:
        raise ValueError('Incomplete PNG')
    width, height, depth, colour, compression, filtering, interlace = header
    if not (0 < width <= 10000 and 0 < height <= 10000):
        raise ValueError('Invalid snapshot dimensions')
    if compression or filtering or interlace or depth not in (8, 16) or colour not in (0, 2, 3, 4, 6):
        raise ValueError('Unsupported native PNG encoding')
    if colour == 3 and (depth != 8 or palette is None or len(palette) % 3):
        raise ValueError('Invalid native indexed PNG palette')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    bytes_per_pixel = channels * (depth // 8)
    row_size = width * bytes_per_pixel
    decoded = zlib.decompress(compressed)
    if len(decoded) != height * (row_size + 1):
        raise ValueError('PNG decoded dimensions differ from its header')
    if any(mode not in range(5) for mode in decoded[::row_size + 1]):
        raise ValueError('Invalid PNG scanline filter')
    previous = bytearray(row_size)
    first, variation = None, False
    for y in range(height):
        start = y * (row_size + 1)
        mode = decoded[start]
        row = bytearray(decoded[start + 1:start + row_size + 1])
        if mode:
            for x in range(row_size):
                left = row[x - bytes_per_pixel] if x >= bytes_per_pixel else 0
                above = previous[x]
                upper_left = previous[x - bytes_per_pixel] if x >= bytes_per_pixel else 0
                addition = (left if mode == 1 else above if mode == 2
                            else (left + above) // 2 if mode == 3 else paeth(left, above, upper_left))
                row[x] = (row[x] + addition) & 255
        if not variation:
            for x in range(0, row_size, bytes_per_pixel):
                pixel = bytes(row[x:x + bytes_per_pixel])
                if colour == 3:
                    index = pixel[0] * 3
                    if index + 3 > len(palette):
                        raise ValueError('PNG palette index is invalid')
                    pixel = palette[index:index + 3]
                if first is None:
                    first = pixel
                elif pixel != first:
                    variation = True
                    break
        if variation:
            # Chunk CRCs, decoded length and every scanline filter have already
            # been checked. One unequal native pixel proves nonuniformity; no
            # need to reconstruct the remaining image in Python.
            return width, height, True
        previous = row
    return width, height, variation


def verify_language(output: Path, language: str, fixture: Path, fixture_hash: str,
                    log: Path, execution: dict) -> dict:
    if execution['timed_out'] or execution['exit_code'] != 0:
        raise ValueError('Native XCTest timed out' if execution['timed_out'] else 'Native XCTest failed')
    text = log.read_text(encoding='utf-8', errors='replace')
    if not re.search(r'Executed 1 test(?:s)?, with 0 failures', text) or re.search(r'\bskipped\b', text, re.I):
        raise ValueError('The requested snapshot test did not run and pass exactly once')
    directory = output / language
    report_path = directory / 'manifest.json'
    report = json.loads(report_path.read_text(encoding='utf-8'))
    if report.get('formatVersion') != 1 or report.get('selectedLanguage') != language:
        raise ValueError('Snapshot manifest version or selected language differs')
    normalize = lambda value: value.replace('_', '-').lower()
    if [normalize(value) for value in report.get('preferredLanguages', [])] != [normalize(language)]:
        raise ValueError('Foundation preferred languages differ from the launch argument')
    if report.get('sourceFixtureSHA256') != fixture_hash or report.get('sourceFixtureName') != fixture.name:
        raise ValueError('Snapshot fixture identity differs')
    if report.get('windowsOrderedOnScreen') is not False:
        raise ValueError('The snapshot test did not confirm that windows stayed off screen')
    records = report.get('snapshots', [])
    if len(records) != len(SNAPSHOT_IDS) or {record.get('id') for record in records} != SNAPSHOT_IDS:
        raise ValueError('The manifest does not contain exactly the expected 23 native snapshots')
    files = {record.get('file') for record in records}
    if files != {identifier + '.png' for identifier in SNAPSHOT_IDS}:
        raise ValueError('Snapshot filenames differ from their stable surface IDs')
    if {path.name for path in directory.glob('*.png')} != files:
        raise ValueError('PNG files differ from the language manifest')
    verified = []
    for record in records:
        identifier = record['id']
        path = directory / record['file']
        if not path.is_file() or path.is_symlink():
            raise ValueError('Snapshot file is absent or is a symlink')
        actual_hash = digest(path)
        if actual_hash != record.get('sha256'):
            raise ValueError(f'{identifier}: PNG hash differs from its native manifest')
        width, height, variation = png_variation(path)
        if not variation or (width, height) != (record.get('pixelWidth'), record.get('pixelHeight')):
            raise ValueError(f'{identifier}: PNG pixels are uniform or dimensions differ')
        for field in ('requestedWidth', 'requestedHeight', 'renderedWidth', 'renderedHeight',
                      'fittingWidth', 'fittingHeight'):
            value = record.get(field)
            minimum_ok = isinstance(value, (int, float)) and (
                value >= 0 if field.startswith('fitting') else value > 0)
            if not minimum_ok or not math.isfinite(value):
                raise ValueError(f'{identifier}: invalid measured layout dimensions')
        if (record['requestedWidth'], record['requestedHeight']) != (record['renderedWidth'], record['renderedHeight']):
            raise ValueError(f'{identifier}: rendered viewport differs from the requested viewport')
        verified.append({'id': identifier, 'file': path.relative_to(output).as_posix(),
                         'sha256': actual_hash, 'pixel_width': width, 'pixel_height': height,
                         'native_pixel_variation': True})
    return {'language': language, 'status': 'passed', 'manifest': report_path.relative_to(output).as_posix(),
            'manifest_sha256': digest(report_path), 'method': report.get('method'),
            'test_log': log.relative_to(output).as_posix(), 'test_log_sha256': digest(log),
            'test_exit_code': execution['exit_code'], 'snapshots': verified}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', required=True, type=Path, help='Synthetic, immutable PDF fixture')
    parser.add_argument('--output', required=True, type=Path, help='New evidence directory; must not exist')
    parser.add_argument('--skip-build', action='store_true', help='Use the existing native XCTest build products')
    parser.add_argument('--languages', nargs='+', choices=LANGUAGES, default=list(LANGUAGES),
                        help='Subset for a probe; the default exports every localization variant')
    arguments = parser.parse_args()
    fixture = arguments.fixture.expanduser().resolve()
    if not fixture.is_file() or fixture.suffix.lower() != '.pdf':
        parser.error('--fixture must name an existing synthetic PDF')
    if len(arguments.languages) != len(set(arguments.languages)):
        parser.error('--languages must not contain duplicates')
    output = arguments.output.expanduser().resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error('--output must be a new directory')
    logs = output / 'Logs'
    logs.mkdir()
    fixture_hash = digest(fixture)
    aggregate = {
        'format_version': 1, 'languages': arguments.languages,
        'source_fixture_name': fixture.name, 'source_fixture_sha256': fixture_hash,
        'expected_snapshots_per_language': len(SNAPSHOT_IDS), 'build_skipped': arguments.skip_build,
        'system_language_preferences_modified': False, 'desktop_input_performed': False,
        'complete_gui_audit': False, 'complete_linguistic_audit': False,
        'complete_voiceover_audit': False, 'complete_pdfa_conformance_validation': False,
        'interpretation': 'Native offscreen snapshots support a human review of the listed surfaces. '
                          'Passing checks verify evidence integrity and nonuniform pixels, not text clipping, '
                          'linguistic completeness, every interaction, or on-screen window behavior.',
        'results': [], 'failures': [],
    }
    try:
        environment = native_environment()
        if not arguments.skip_build:
            log = logs / 'build.log'
            execution = run_logged(['/bin/bash', str(ROOT / 'scripts/test.sh'), '--filter', 'CartaUISnapshotTests'],
                                   environment, log, timeout=900)
            aggregate['build'] = {**execution, 'log': log.relative_to(output).as_posix(), 'sha256': digest(log)}
            if execution['timed_out'] or execution['exit_code'] != 0:
                raise ValueError('Native test build failed; inspect Logs/build.log')
        bundle, resources = find_products()
        test_binary = bundle / 'Contents/MacOS/CartaPDFTests'
        aggregate['test_product_name'] = bundle.name
        aggregate['test_binary_sha256'] = digest(test_binary)
        aggregate['resource_bundle_name'] = resources.name
        aggregate['resource_bundle_sha256'] = {
            path.relative_to(resources).as_posix(): digest(path)
            for path in sorted(resources.rglob('*.strings'))
        }
        if not aggregate['resource_bundle_sha256']:
            raise ValueError('The native test resource bundle has no localization tables')
        for language in arguments.languages:
            log = logs / f'{language}.log'
            child_environment = dict(environment)
            child_environment.update(PACKAGE_RESOURCE_BUNDLE_PATH=str(resources),
                                     CARTAPDF_UI_AUDIT_OUTPUT_DIRECTORY=str(output),
                                     CARTAPDF_UI_AUDIT_FIXTURE=str(fixture))
            preference = '(' + json.dumps(language) + ')'
            execution = run_logged(['/usr/bin/xcrun', 'xctest', '-AppleLanguages', preference,
                                    '-XCTest', TEST, str(bundle)], child_environment, log, timeout=180)
            try:
                result = verify_language(output, language, fixture, fixture_hash, log, execution)
                aggregate['results'].append(result)
            except (OSError, ValueError, KeyError, TypeError, zlib.error) as error:
                failure = {'language': language, 'reason': str(error), **execution,
                           'test_log': log.relative_to(output).as_posix(), 'test_log_sha256': digest(log)}
                aggregate['failures'].append(failure)
        if digest(fixture) != fixture_hash:
            raise ValueError('The source fixture changed during snapshot generation')
        aggregate['fixture_unchanged'] = True
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        aggregate['failures'].append({'stage': 'driver', 'reason': str(error)})
        aggregate['fixture_unchanged'] = fixture.is_file() and digest(fixture) == fixture_hash
    aggregate['status'] = 'passed' if not aggregate['failures'] else 'failed'
    aggregate['verified_snapshot_count'] = sum(len(result['snapshots']) for result in aggregate['results'])
    (output / 'manifest.json').write_text(json.dumps(aggregate, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status': aggregate['status'], 'output': str(output), 'manifest': 'manifest.json',
                      'languages': arguments.languages, 'verified_snapshots': aggregate['verified_snapshot_count'],
                      'failures': aggregate['failures'], 'complete_gui_audit': False}))
    return 0 if aggregate['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
