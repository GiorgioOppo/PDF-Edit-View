#!/usr/bin/env python3
"""Read-only, explicitly scoped publication-history checks (standard library only).

This checks selected signatures, paths and commit identities; it is not a complete
security audit. It never fetches, rewrites Git data, prints matching values or
changes repository visibility. Supply every branch/tag intended for publication.
Unselected refs, GitHub artifacts/logs and working-tree files are outside scope.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path, PurePosixPath
import re
import runpy
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
MAX_BLOB_BYTES = 95 * 1024 * 1024
REF_PREFIXES = ("refs/heads/", "refs/remotes/", "refs/tags/")
IDENTITY_NOREPLY = re.compile(r"^(?:[^\s@]+@(?:users\.)?noreply\.github\.com|noreply@github\.com)$", re.IGNORECASE)
GIT_ENVIRONMENT = {
    **os.environ,
    # A partial clone must fail on missing objects rather than fetching them.
    "GIT_NO_LAZY_FETCH": "1",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
}


class ScanError(Exception):
    """A diagnostic that contains no Git command output or matching values."""


def git(*arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "--no-replace-objects", *arguments], cwd=ROOT,
        env=GIT_ENVIRONMENT, capture_output=True, check=False,
    )
    if result.returncode:
        raise ScanError("Git could not complete the requested read-only operation.")
    return result.stdout


def resolve_refs(refs: list[str]) -> tuple[list[str], list[str]]:
    commits: list[str] = []
    objects: list[str] = []
    for index, ref in enumerate(refs, start=1):
        # Revision expressions, shorthand and internal agent/snapshot refs are
        # deliberately excluded. Git resolves tags to their commit targets.
        if (not ref.startswith(REF_PREFIXES)
                or any(part in {".codex", "codex", "snapshots"} for part in ref.split("/"))
                or subprocess.run(
                    ["git", "check-ref-format", ref], cwd=ROOT,
                    env=GIT_ENVIRONMENT,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                ).returncode):
            raise ScanError(f"Reference {index} must be a full branch, remote branch or tag ref outside internal snapshot namespaces.")
        try:
            commit = git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode("ascii").strip()
        except (ScanError, UnicodeError):
            raise ScanError(f"Reference {index} does not resolve to a local commit.") from None
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
            raise ScanError("Git returned an unexpected object identifier.")
        commits.append(commit)
        objects.append(git("rev-parse", "--verify", "--end-of-options", ref).decode("ascii").strip())
    return commits, objects


def object_inventory(tips: list[str]) -> tuple[list[tuple[str, int]], list[tuple[str, int]]]:
    identifiers = git("rev-list", "--objects", "--no-object-names", *tips)
    result = subprocess.run(
        ["git", "--no-replace-objects", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        cwd=ROOT, env=GIT_ENVIRONMENT, input=identifiers, capture_output=True, check=False,
    )
    if result.returncode:
        raise ScanError("Git could not inspect the reachable object inventory.")
    blobs: list[tuple[str, int]] = []
    tags: list[tuple[str, int]] = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 3 or not parts[2].isdigit():
            raise ScanError("Git returned an incomplete object inventory.")
        if parts[1] == b"blob":
            blobs.append((parts[0].decode("ascii"), int(parts[2])))
        elif parts[1] == b"tag":
            tags.append((parts[0].decode("ascii"), int(parts[2])))
    return blobs, tags


def read_exact(stream: object, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)  # type: ignore[attr-defined]
        if not chunk:
            raise ScanError("Git returned incomplete blob bytes.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def signatures(content: str, patterns: dict[str, re.Pattern[str]], host_paths: re.Pattern[str]) -> Counter[str]:
    found = Counter({category: 1 for category, pattern in patterns.items() if pattern.search(content)})
    if host_paths.search(content):
        found["personal machine path"] += 1
    return found


def scan_blobs(blobs: list[tuple[str, int]], patterns: dict[str, re.Pattern[str]], host_paths: re.Pattern[str]) -> dict[str, object]:
    findings: Counter[str] = Counter()
    text_count = binary_count = large_count = 0
    process = subprocess.Popen(
        ["git", "--no-replace-objects", "cat-file", "--batch"], cwd=ROOT,
        env=GIT_ENVIRONMENT,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    try:
        assert process.stdin is not None and process.stdout is not None
        for identifier, size in blobs:
            if size >= MAX_BLOB_BYTES:
                large_count += 1
                continue
            process.stdin.write((identifier + "\n").encode("ascii"))
            process.stdin.flush()
            expected_header = f"{identifier} blob {size}".encode("ascii")
            if process.stdout.readline().rstrip(b"\n") != expected_header:
                raise ScanError("Git returned an unexpected blob header.")
            data = read_exact(process.stdout, size)
            if process.stdout.read(1) != b"\n":
                raise ScanError("Git returned an invalid blob boundary.")
            try:
                content = data.decode("utf-8")
            except UnicodeDecodeError:
                binary_count += 1
                continue
            text_count += 1
            findings.update(signatures(content, patterns, host_paths))
        process.stdin.close()
        if process.wait() != 0:
            raise ScanError("Git could not finish reading blob bytes.")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
    return {
        "unique_blobs": len(blobs), "UTF8_blobs_checked": text_count,
        "non_UTF8_blobs_not_signature_checked": binary_count,
        "blobs_at_or_above_size_limit_not_read": large_count,
        "blob_size_limit_bytes": MAX_BLOB_BYTES,
        "signature_findings_by_category": dict(sorted(findings.items())),
    }


def scan_metadata(commits: list[str], patterns: dict[str, re.Pattern[str]], host_paths: re.Pattern[str], forbidden_parts: set[str], forbidden_suffixes: set[str]) -> dict[str, object]:
    message_findings: Counter[str] = Counter()
    path_findings: Counter[str] = Counter()
    identities: set[str] = set()
    reviewed_identities: set[str] = set()
    paths: set[str] = set()
    for commit in commits:
        # Lowercase %ae/%ce preserve the addresses actually published in Git;
        # mailmap aliases must not hide an original personal address.
        fields = git("show", "--no-show-signature", "--no-color", "-s", "--format=%ae%x00%ce%x00%B", commit).decode("utf-8", errors="replace").split("\0", 2)
        if len(fields) != 3:
            raise ScanError("Git returned incomplete commit metadata.")
        for email in fields[:2]:
            normalized = email.strip().lower()
            identities.add(normalized)
            if not IDENTITY_NOREPLY.fullmatch(normalized):
                reviewed_identities.add(normalized)
        message_findings.update(signatures(fields[2], patterns, host_paths))
        for raw_path in git("ls-tree", "-r", "--name-only", "-z", commit).split(b"\0"):
            if raw_path:
                paths.add(raw_path.decode("utf-8", errors="surrogateescape"))
    for name in paths:
        path = PurePosixPath(name)
        if (any(part in forbidden_parts or part.startswith(".build") for part in path.parts)
                or path.suffix.lower() in forbidden_suffixes | {".pdf", ".log"}
                or path.name == ".DS_Store" or path.name.startswith(".env")):
            path_findings["generated document, local configuration or credential filename"] += 1
        if host_paths.search(name):
            path_findings["personal machine path in filename"] += 1
    return {
        "reachable_commits": len(commits),
        "commit_message_signature_findings_by_category": dict(sorted(message_findings.items())),
        "unique_historical_file_paths_checked": len(paths),
        "historical_filename_findings_by_category": dict(sorted(path_findings.items())),
        "unique_commit_email_identities_checked": len(identities),
        "non_GitHub_noreply_commit_email_identities_requiring_review": len(reviewed_identities),
        "email_scope": "Commit author and committer addresses only; upstream attribution addresses in file content are not classified as private identities.",
    }


def scan_tags(tags: list[tuple[str, int]], patterns: dict[str, re.Pattern[str]], host_paths: re.Pattern[str]) -> dict[str, object]:
    findings: Counter[str] = Counter()
    identities: set[str] = set()
    reviewed_identities: set[str] = set()
    skipped = 0
    for identifier, size in tags:
        if size >= MAX_BLOB_BYTES:
            skipped += 1
            continue
        content = git("cat-file", "tag", identifier).decode("utf-8", errors="replace")
        findings.update(signatures(content, patterns, host_paths))
        header = content.split("\n\n", 1)[0]
        for line in header.splitlines():
            if line.startswith("tagger "):
                match = re.search(r"<([^<>]+)> [0-9]+ [+-][0-9]{4}$", line)
                address = match.group(1).lower() if match else ""
                identities.add(address)
                if not IDENTITY_NOREPLY.fullmatch(address):
                    reviewed_identities.add(address)
    return {
        "reachable_annotated_tag_objects": len(tags),
        "tag_signature_findings_by_category": dict(sorted(findings.items())),
        "tag_objects_at_or_above_size_limit_not_read": skipped,
        "unique_tagger_email_identities_checked": len(identities),
        "non_GitHub_noreply_tagger_email_identities_requiring_review": len(reviewed_identities),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", action="append", required=True, help="Full local branch, remote branch or tag ref; repeat for every publication ref.")
    options = parser.parse_args()
    try:
        policy = runpy.run_path(str(ROOT / "scripts/check-repository.py"))
        if git("rev-parse", "--is-shallow-repository").strip() != b"false":
            raise ScanError("A complete local history is required; shallow repositories are outside this scan's supported scope.")
        refs = list(dict.fromkeys(options.ref))
        tips, objects = resolve_refs(refs)
        commits = git("rev-list", *tips).decode("ascii").splitlines()
        blob_objects, tag_objects = object_inventory(objects)
        blobs = scan_blobs(blob_objects, policy["SECRET_PATTERNS"], policy["PERSONAL_PATH"])
        metadata = scan_metadata(commits, policy["SECRET_PATTERNS"], policy["PERSONAL_PATH"], policy["FORBIDDEN_PARTS"], policy["FORBIDDEN_SUFFIXES"])
        tags = scan_tags(tag_objects, policy["SECRET_PATTERNS"], policy["PERSONAL_PATH"])
        review_required = bool(
            blobs["signature_findings_by_category"]
            or blobs["blobs_at_or_above_size_limit_not_read"]
            or metadata["commit_message_signature_findings_by_category"]
            or metadata["historical_filename_findings_by_category"]
            or metadata["non_GitHub_noreply_commit_email_identities_requiring_review"]
            or tags["tag_signature_findings_by_category"]
            or tags["tag_objects_at_or_above_size_limit_not_read"]
            or tags["non_GitHub_noreply_tagger_email_identities_requiring_review"]
        )
        report = {
            "result": "review_required" if review_required else "passed_selected_checks",
            "scope": "Explicit publication refs and their reachable Git blobs, commit messages, annotated tags, filenames and commit/tagger email identities. No network or repository mutation.",
            "references": refs,
            "resolved_commit_targets": tips,
            "blob_checks": blobs,
            "metadata_checks": metadata,
            "annotated_tag_checks": tags,
            "complete_security_audit": False,
            "outside_scope": "Unselected refs, non-UTF8 content signatures, working-tree files, GitHub Actions logs/artifacts, issues, pull requests, external systems and arbitrary credential formats.",
        }
        print(json.dumps(report, indent=2, ensure_ascii=True))
        return 1 if review_required else 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, ScanError) as error:
        message = str(error) if isinstance(error, ScanError) else "The local history scan could not complete."
        print(json.dumps({"result": "incomplete", "reason": message, "complete_security_audit": False}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
