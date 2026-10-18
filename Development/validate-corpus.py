#!/usr/bin/env python3
"""Run the native CLI against a separately acquired, pinned official corpus.

No Java engine is used. Corpus files are not bundled or downloaded by the app.
Historical filenames do not reliably identify current catalogue predicates.
Filename comparisons are diagnostic candidates, never a completeness score.
"""
import argparse
import concurrent.futures
import hashlib
import json
import re
import subprocess
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--corpus", type=Path, required=True)
parser.add_argument("--executable", type=Path, required=True)
parser.add_argument("--report", type=Path, required=True)
parser.add_argument("--workers", type=int, default=4)
parser.add_argument("--limit", type=int)
args = parser.parse_args()
inventory = json.loads((args.corpus / "inventory.json").read_text())
entries = inventory["files"][:args.limit]
started = time.monotonic()
binary_hash = hashlib.sha256(args.executable.read_bytes()).hexdigest()

def verify(entry):
    path = args.corpus / "files" / entry["path"]
    profile = re.match(r"PDF_A-([1234][abuef]?)", entry["path"]).group(1)
    case = re.search(r"(\d+(?:-\d+)+)-t(\d+)-(pass|fail)", path.name, re.I)
    data = path.read_bytes()
    record = {"file": entry["path"], "profile": profile, "sha256": hashlib.sha256(data).hexdigest()}
    actual_blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    record["git_blob_sha1"] = actual_blob
    if actual_blob != entry["sha"] or len(data) != entry["size"]:
        record.update(result="error", error="Corpus bytes do not match the pinned official Git blob")
        return record
    if case:
        record.update(clause=case[1].replace("-", "."), test_number=str(int(case[2])), expected=case[3].lower())
    else:
        record["expected"] = "unmapped"
    try:
        result = subprocess.run([str(args.executable), "--cli", "validate-pdfa", str(path), profile],
                                capture_output=True, text=True, timeout=30)
        report = json.loads(result.stdout)
        record.update(verdict=report["verdict"], exit_code=result.returncode,
                      unverified_count=sum(r["status"] == "notVerified" for r in report["rules"] + report.get("modelChecks", [])),
                      model_check_status_counts=dict(Counter(r["status"] for r in report.get("modelChecks", []))))
        selected = [r for r in report["rules"] if r["clause"] == record.get("clause") and r["testNumber"] == record.get("test_number")]
        record["mapping_basis"] = "unreviewed_historical_filename"
        record["target_statuses"] = [r["status"] for r in selected]
        if not selected:
            record["result"] = "unmapped"
        elif record["expected"] == "fail":
            record["result"] = "candidate_failure_detected" if any(r["status"] == "failed" for r in selected) else "candidate_failure_not_detected"
        else:
            record["result"] = "candidate_pass_failed" if any(r["status"] == "failed" for r in selected) else (
                "candidate_pass_unverified" if any(r["status"] == "notVerified" for r in selected) else "candidate_pass_without_failure")
        if record["result"] in ("candidate_pass_failed", "candidate_failure_not_detected", "candidate_pass_unverified"):
            record["target_details"] = [{k:r[k] for k in ("id","objectType","status","detail","locations")} for r in selected]
        record["model_failures"] = [r["detail"] for r in report.get("modelChecks",[]) if r["status"] == "failed"]
        record["model_failure_details"] = [{k:r[k] for k in ("id","objectType","detail","locations")} for r in report.get("modelChecks",[]) if r["status"] == "failed"]
        record["actual_failed_rules"] = [{"id":r["id"],"objectType":r["objectType"]} for r in report["rules"] if r["status"] == "failed"]
    except Exception as error:
        record.update(result="error", error=str(error))
    return record

records = []
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(args.workers, 8))) as pool:
    for i, record in enumerate(pool.map(verify, entries), 1):
        records.append(record)
        if i % 100 == 0:
            print(f"{i}/{len(entries)} file analizzati", flush=True)
summary = dict(Counter(record["result"] for record in records))
proof = {"repository": inventory["repository"], "commit": inventory["commit"], "data_license": "CC BY 4.0",
         "implementation": "CartaPDF native Swift; Apple frameworks only; no veraPDF engine",
         "binary_sha256": binary_hash, "finished_at": datetime.now(timezone.utc).isoformat(),
         "elapsed_seconds": round(time.monotonic() - started, 3),
         "comparison": "Historical filename clause/test numbers are provisional candidates; many differ from current catalogue predicates. Candidate results are not a validated accuracy or ISO coverage score. An unrelated failure never proves the named requirement.",
         "filename_rule_mapping_reviewed": False,
         "complete_ISO_validation_proven": False, "files": len(records), "summary": summary,
         "overall_verdicts": dict(Counter(record.get("verdict","error") for record in records)),
         "by_profile": {profile:dict(Counter(r["result"] for r in records if r["profile"] == profile))
                        for profile in sorted({r["profile"] for r in records})},
         "results": records}
args.report.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(summary, ensure_ascii=False), flush=True)
