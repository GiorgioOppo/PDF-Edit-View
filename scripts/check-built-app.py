#!/usr/bin/env python3
"""Check a built macOS bundle and its packaged PDF/A CLI; no ISO certification."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

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
with tempfile.TemporaryDirectory(prefix='CartaPDF-built-app-') as directory:
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
assert len(matrix) == 11
print(json.dumps({'packaged_CLI_profiles': matrix, 'catalogue_entries': sum(e['rule_count'] for e in profiles['profiles']),
                  'font_resources': len(font['items']), 'signature': 'passed', 'architecture': 'arm64',
                  'input_unchanged': True, 'complete_ISO_validation_proven': False}))
