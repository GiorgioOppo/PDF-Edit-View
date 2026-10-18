#!/usr/bin/env python3
"""Verify packaged Apple-only release resources and native PDF/A CLI reports.

Run on an extracted .app outside the project to exercise resource discovery.
This verifies packaging and fail-closed behavior, not complete ISO conformity.
"""
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--fixture", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
app = args.app.resolve()
resources = app / "Contents/Resources"
executable = app / "Contents/MacOS/CartaPDF"
sha = lambda data: hashlib.sha256(data).hexdigest()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True, capture_output=True)
profiles = json.loads((resources / "PDFAProfiles/MANIFEST.json").read_text())
font_bytes = (resources / "PDFFontData/MANIFEST.json").read_bytes()
assert sha(font_bytes) == "0f2ac1ecd208995e164298d3eca70d2db9b6cc3322363317b419161c435a7f31"
font_data = json.loads(font_bytes)
for entry in profiles["profiles"]:
    assert sha((resources / "PDFAProfiles" / entry["file"]).read_bytes()) == entry["sha256"]
for entry in font_data["items"]:
    assert sha((resources / "PDFFontData" / entry["file"]).read_bytes()) == entry["sha256"]
for relative in ["PDFAProfiles/LICENSE.txt", "PDFAProfiles/NOTICE.txt",
                 "PDFFontData/NOTICE.txt", "PDFFontData/CMaps/LICENSE.md", "PDFFontData/AGL/LICENSE.md"]:
    assert (resources / relative).is_file(), relative
input_hash = sha(args.fixture.read_bytes())
matrix = []
for entry in profiles["profiles"]:
    profile = entry["file"].removeprefix("PDFA-").removesuffix(".xml").lower()
    result = subprocess.run([str(executable), "--cli", "validate-pdfa", str(args.fixture.resolve()), profile],
                            cwd="/private/tmp", capture_output=True, text=True, timeout=30)
    report = json.loads(result.stdout)
    assert len(report["rules"]) == entry["rule_count"]
    assert report["coverageComplete"] is False and report["verdict"] != "conforming"
    assert report["sha256"] == input_hash and report["scopeGaps"]
    assert report["modelChecks"], "Physical syntax check missing"
    assert result.returncode == (2 if report["verdict"] == "nonconforming" else 3)
    matrix.append({"profile":profile,"rules":len(report["rules"]),"exit_code":result.returncode,
                   "verdict":report["verdict"],"passed":sum(r["status"]=="passed" for r in report["rules"]),
                   "failed":sum(r["status"]=="failed" for r in report["rules"]),
                   "not_verified":sum(r["status"]=="notVerified" for r in report["rules"]),
                   "model_checks":len(report["modelChecks"]),
                   "model_check_families":dict(Counter(row["objectType"] for row in report["modelChecks"]))})
assert sha(args.fixture.read_bytes()) == input_hash
assert sum(item["rules"] for item in matrix) == 1489
assert next(item for item in matrix if item["profile"] == "2b")["exit_code"] == 3
# Synthetic colour-schema witness exercises the packaged CLI independently of
# the Apple archive fixture. Passing this local condition never certifies ISO.
def colour_fixture(white):
    objects = {1:b"<< /Type /Catalog /Pages 2 0 R >>",
               2:b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
               3:("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /ColorSpace << /CS1 [/CalGray << /WhitePoint [" + white + "] >>] >> >> >>").encode()}
    data = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n"); offsets = {}
    for number, body in objects.items():
        offsets[number] = len(data); data += str(number).encode()+b" 0 obj\n"+body+b"\nendobj\n"
    start = len(data); data += b"xref\n0 4\n0000000000 65535 f \n"
    for number in range(1,4): data += f"{offsets[number]:010d} 00000 n \n".encode()
    data += f"trailer\n<< /Root 1 0 R /Size 4 /ID [<1234><5678>] >>\nstartxref\n{start}\n%%EOF\n".encode()
    return bytes(data)
colour_matrix = []
with tempfile.TemporaryDirectory(prefix="CartaPDF-release-colour-",dir="/private/tmp") as directory:
    for valid, white in [(True,"1 1 1"),(False,"0 1 1")]:
        fixture = Path(directory)/("valid.pdf" if valid else "invalid.pdf")
        fixture.write_bytes(colour_fixture(white)); digest = sha(fixture.read_bytes())
        for entry in profiles["profiles"]:
            profile = entry["file"].removeprefix("PDFA-").removesuffix(".xml").lower()
            result = subprocess.run([str(executable),"--cli","validate-pdfa",str(fixture),profile],cwd="/private/tmp",capture_output=True,text=True,timeout=30)
            report = json.loads(result.stdout)
            rows = [row for row in report["modelChecks"] if row["objectType"]=="ColorSpaceModel"]
            assert rows and any(row["status"] == ("passed" if valid else "failed") for row in rows)
            if valid: assert all(row["status"]!="failed" for row in rows)
            assert not report["coverageComplete"] and report["scopeGaps"] and report["verdict"]!="conforming"
            assert result.returncode == (2 if report["verdict"]=="nonconforming" else 3)
            assert sha(fixture.read_bytes())==digest==report["sha256"]
            colour_matrix.append({"profile":profile,"schema_fixture":"valid" if valid else "invalid","color_schema_status":[row["status"] for row in rows],"global_verdict":report["verdict"],"exit_code":result.returncode,"input_sha256":digest,"input_unchanged":True})
proof = {"app_version":info["CFBundleShortVersionString"],"build":info["CFBundleVersion"],
         "verified_app_path":str(app),"working_directory":"/private/tmp",
         "binary_sha256":sha(executable.read_bytes()),"codesign_strict":"passed",
         "native_release_CLI_profiles":matrix,"input_sha256":input_hash,"input_unchanged":True,
         "catalogued_rule_entries":1489,"catalogue_resources_verified":11,
         "font_reference_resources_verified":len(font_data["items"]),
         "resources_resolved_outside_workspace":True,"complete_ISO_validation":False,
         "native_colour_schema_CLI_profiles":colour_matrix,"colour_schema_scope":"22 packaged-CLI cases; local structural conditions only, not ISO completeness."}
args.output.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k:v for k,v in proof.items() if k not in {"native_release_CLI_profiles","native_colour_schema_CLI_profiles"}},ensure_ascii=False))
