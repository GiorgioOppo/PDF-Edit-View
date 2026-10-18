#!/usr/bin/env python3
"""Exercise the history checker against disposable synthetic Git repositories.

Uses only Python's standard library and Git. No credentials, user documents,
network requests or existing repository mutations are involved.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class PublicationHistoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cartapdf-history-check-")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name)
        (self.repository / "scripts").mkdir()
        for name in ("check-publication-history.py", "check-repository.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.repository / "scripts" / name)
        self.environment = {
            **os.environ,
            "GIT_AUTHOR_NAME": "Synthetic audit",
            "GIT_COMMITTER_NAME": "Synthetic audit",
            "GIT_AUTHOR_EMAIL": "synthetic@users.noreply.github.com",
            "GIT_COMMITTER_EMAIL": "synthetic@users.noreply.github.com",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
        }
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
            self.environment.pop(name, None)
        self.git("init", "-q", "-b", "main")

    def git(self, *arguments: str) -> bytes:
        return subprocess.run(
            ["git", *arguments], cwd=self.repository, env=self.environment,
            capture_output=True, check=True,
        ).stdout

    def commit(self, files: dict[str, bytes], message: str = "Synthetic fixture") -> None:
        for name, data in files.items():
            path = self.repository / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.git("add", "--", name)
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", message)

    def scan(self, *refs: str) -> tuple[int, dict[str, object], str]:
        arguments = [sys.executable, str(self.repository / "scripts/check-publication-history.py")]
        for ref in refs or ("refs/heads/main",):
            arguments += ["--ref=" + ref]
        result = subprocess.run(arguments, cwd=self.repository, env=self.environment, capture_output=True, text=True)
        output = result.stdout + result.stderr
        return result.returncode, json.loads(result.stdout or result.stderr), output

    def test_clean_text_empty_and_binary_blobs_and_no_mutations(self) -> None:
        self.commit({"readme.txt": "English · 日本語 · 中文\n".encode(), "empty.txt": b"", "binary.dat": b"\xff\xfe\x00"})
        before = (self.git("rev-parse", "HEAD"), self.git("status", "--porcelain=v1"), self.git("for-each-ref", "--format=%(refname) %(objectname)"))
        code, report, _ = self.scan()
        after = (self.git("rev-parse", "HEAD"), self.git("status", "--porcelain=v1"), self.git("for-each-ref", "--format=%(refname) %(objectname)"))
        self.assertEqual(code, 0)
        self.assertEqual(report["result"], "passed_selected_checks")
        self.assertFalse(report["complete_security_audit"])
        self.assertEqual(report["blob_checks"]["UTF8_blobs_checked"], 2)
        self.assertEqual(report["blob_checks"]["non_UTF8_blobs_not_signature_checked"], 1)
        self.assertEqual(before, after)

    def test_removed_historical_secret_and_personal_path_are_found_without_values(self) -> None:
        token = "gh" + "p_" + "a" * 40
        personal_path = "/" + "Users/SyntheticAudit/private/document.txt"
        self.commit({"old.txt": (token + "\n" + personal_path).encode()})
        self.git("rm", "-q", "old.txt")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Remove synthetic sensitive fixture")
        code, report, output = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual(report["metadata_checks"]["reachable_commits"], 2)
        self.assertEqual(report["blob_checks"]["signature_findings_by_category"], {"GitHub token": 1, "personal machine path": 1})
        self.assertNotIn(token, output)
        self.assertNotIn(personal_path, output)

    def test_commit_message_signatures_are_checked_without_values(self) -> None:
        token = "gh" + "p_" + "b" * 40
        self.commit({"clean.txt": b"Clean"}, message="Synthetic " + token)
        code, report, output = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual(report["metadata_checks"]["commit_message_signature_findings_by_category"], {"GitHub token": 1})
        self.assertNotIn(token, output)

    def test_historical_filename_is_checked_even_when_blob_was_reused(self) -> None:
        self.commit({"clean.txt": b"Same bytes"})
        self.git("mv", "clean.txt", ".env")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Synthetic renamed file")
        code, report, _ = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual(report["blob_checks"]["unique_blobs"], 1)
        self.assertEqual(sum(report["metadata_checks"]["historical_filename_findings_by_category"].values()), 1)

    def test_non_noreply_commit_identity_requires_review_without_address_output(self) -> None:
        address = "synthetic-private@example.invalid"
        self.environment["GIT_AUTHOR_EMAIL"] = address
        self.commit({"clean.txt": b"Clean"})
        code, report, output = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual(report["metadata_checks"]["non_GitHub_noreply_commit_email_identities_requiring_review"], 1)
        self.assertNotIn(address, output)

    def test_mailmap_cannot_hide_the_original_commit_address(self) -> None:
        address = "synthetic-private@example.invalid"
        self.environment["GIT_AUTHOR_EMAIL"] = address
        mapping = f"Synthetic audit <synthetic@users.noreply.github.com> <{address}>\n"
        self.commit({"clean.txt": b"Clean", ".mailmap": mapping.encode()})
        code, report, output = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual(report["metadata_checks"]["non_GitHub_noreply_commit_email_identities_requiring_review"], 1)
        self.assertNotIn(address, output)

    def test_official_GitHub_service_noreply_identity_is_accepted(self) -> None:
        self.environment["GIT_COMMITTER_EMAIL"] = "noreply@github.com"
        self.commit({"clean.txt": b"Clean"})
        code, report, _ = self.scan()
        self.assertEqual(code, 0)
        self.assertEqual(report["metadata_checks"]["unique_commit_email_identities_checked"], 2)
        self.assertEqual(report["metadata_checks"]["non_GitHub_noreply_commit_email_identities_requiring_review"], 0)

    def test_nested_annotated_tags_include_messages_and_tagger_addresses(self) -> None:
        token = "gh" + "p_" + "c" * 40
        address = "synthetic-tagger@example.invalid"
        self.commit({"clean.txt": b"Clean"})
        self.environment["GIT_COMMITTER_EMAIL"] = address
        self.git("-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "Synthetic " + token)
        self.git("-c", "tag.gpgsign=false", "tag", "-a", "nested", "release", "-m", "Synthetic nested annotation")
        code, report, output = self.scan("refs/tags/nested")
        self.assertEqual(code, 1)
        self.assertEqual(report["annotated_tag_checks"]["reachable_annotated_tag_objects"], 2)
        self.assertEqual(report["annotated_tag_checks"]["tag_signature_findings_by_category"], {"GitHub token": 1})
        self.assertEqual(report["annotated_tag_checks"]["non_GitHub_noreply_tagger_email_identities_requiring_review"], 1)
        self.assertNotIn(token, output)
        self.assertNotIn(address, output)

    def test_shallow_clone_is_incomplete(self) -> None:
        self.commit({"clean.txt": b"First"})
        self.commit({"clean.txt": b"Second"})
        clone = self.repository / "shallow"
        self.git("clone", "--quiet", "--depth", "1", self.repository.as_uri(), str(clone))
        shutil.copytree(self.repository / "scripts", clone / "scripts")
        self.repository = clone
        code, report, _ = self.scan()
        self.assertEqual(code, 2)
        self.assertEqual(report["result"], "incomplete")
        self.assertIn("shallow", report["reason"])

    def test_ref_scope_is_explicit_and_internal_or_revision_inputs_are_rejected(self) -> None:
        self.commit({"clean.txt": b"Clean"})
        self.git("checkout", "-qb", "extra")
        self.commit({"extra.key": b"Synthetic private filename only"})
        self.git("checkout", "-q", "main")
        self.assertEqual(self.scan("refs/heads/main")[0], 0)
        self.assertEqual(self.scan("refs/heads/main", "refs/heads/extra")[0], 1)
        for ref in ("HEAD", "refs/codex/snapshot", "refs/heads/codex/snapshot", "refs/heads/main~1", "--all"):
            with self.subTest(ref=ref):
                code, report, _ = self.scan(ref)
                self.assertEqual(code, 2)
                self.assertEqual(report["result"], "incomplete")

    def test_oversized_blob_is_reported_without_reading_its_content(self) -> None:
        script = self.repository / "scripts/check-publication-history.py"
        script.write_text(script.read_text().replace("MAX_BLOB_BYTES = 95 * 1024 * 1024", "MAX_BLOB_BYTES = 100"))
        self.commit({"large.txt": b"x" * 100})
        code, report, _ = self.scan()
        self.assertEqual(code, 1)
        self.assertEqual(report["blob_checks"]["blobs_at_or_above_size_limit_not_read"], 1)
        self.assertEqual(report["blob_checks"]["UTF8_blobs_checked"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
