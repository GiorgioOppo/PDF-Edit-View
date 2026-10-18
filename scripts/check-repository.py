#!/usr/bin/env python3
"""Local repository checks using only the Python standard library.

Inspects tracked working-tree files. An empty index uses non-ignored files to
support the initial commit. The check reports locations and categories, never
matching secret values. It is a preventive check, not a complete security audit.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
APPLE_MODULES = {
    "AVFoundation", "AppIntents", "AppKit", "Combine", "Compression",
    "CoreGraphics", "CoreImage", "CoreText", "CryptoKit", "Darwin",
    "Foundation", "ImageCaptureCore", "ImageIO", "PDFKit", "Quartz", "QuartzCore",
    "ScreenCaptureKit", "Security", "SwiftUI", "UniformTypeIdentifiers",
    "Vision", "WebKit", "XCTest", "CartaPDF", "PackageDescription",
}
IMPORT = re.compile(
    r"^\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|internal|private|fileprivate|package)\s+)?"
    r"import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][\w]*)",
    re.MULTILINE,
)
SECRET_PATTERNS = {
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{50,255})\b"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "private key": re.compile("-----BEGIN " + r"(?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "Slack token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "Google API key": re.compile(r"\bAIza[A-Za-z0-9_-]{35}\b"),
    "credential in URL": re.compile(r"https?://[^\s/:@]+:[^\s/@]+@"),
}
PERSONAL_PATH = re.compile(
    "/" + r"Users/(?!Shared(?:/|\b))[^/\s<>\"'\[\]]+/|"
    "/" + r"home/[^/\s<>\"'\[\]]+/|"
    "/" + r"(?:private/)?var/folders/[A-Za-z0-9_/.-]+"
)
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+)\)")
FORBIDDEN_PARTS = {".git", ".swiftpm", ".agents", ".codex", ".aws", ".ui-audit", "dist", "__pycache__"}
FORBIDDEN_SUFFIXES = {".pyc", ".p12", ".pfx", ".key", ".pem", ".mobileprovision"}
ERRORS: list[str] = []


def error(path: Path | str, message: str, line: int | None = None) -> None:
    location = str(path)
    if line is not None:
        location += f":{line}"
    ERRORS.append(f"{location}: {message}")


def repository_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True,
    )
    source = result.stdout
    if not source:
        source = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            cwd=ROOT, check=True, capture_output=True,
        ).stdout
    return [Path(name.decode("utf-8")) for name in source.split(b"\0") if name]


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate object key")
        value[key] = item
    return value


def read_json(path: Path) -> object:
    return json.loads(
        (ROOT / path).read_text(encoding="utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite number")),
    )


def check_file(path: Path) -> str | None:
    full = ROOT / path
    if full.is_symlink():
        error(path, "symbolic links must not enter the published source tree")
        return None
    if not full.is_file():
        error(path, "tracked file is missing from the working tree")
        return None
    if (any(part in FORBIDDEN_PARTS or part.startswith(".build") for part in path.parts)
            or path.suffix.lower() in FORBIDDEN_SUFFIXES
            or path.name == ".DS_Store" or path.name.startswith(".env")):
        error(path, "generated, local configuration or credential file is tracked")
    if path.suffix.lower() == ".log":
        error(path, "raw machine logs belong outside the published source tree")
    if full.stat().st_size >= 95 * 1024 * 1024:
        error(path, "file is too large for the source repository")
        return None
    data = full.read_bytes()
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    for category, pattern in SECRET_PATTERNS.items():
        match = pattern.search(content)
        if match:
            error(path, f"possible {category}; inspect locally", content.count("\n", 0, match.start()) + 1)
    match = PERSONAL_PATH.search(content)
    if match:
        error(path, "personal machine path; replace with a portable reference", content.count("\n", 0, match.start()) + 1)
    if path.suffix == ".swift":
        for match in IMPORT.finditer(content):
            if match.group(1) not in APPLE_MODULES:
                error(path, "import outside the reviewed Apple/project module list", content.count("\n", 0, match.start()) + 1)
    if path.suffix == ".json":
        try:
            read_json(path)
        except (ValueError, UnicodeError) as exc:
            error(path, "invalid JSON: " + type(exc).__name__)
    return content


def check_markdown(path: Path, content: str, files: set[Path]) -> None:
    # Upstream data documentation may reference files in its original repository.
    if "PDFFontData" in path.parts or "PDFAProfiles" in path.parts:
        return
    for match in MARKDOWN_LINK.finditer(content):
        target = match.group(1).strip()
        if target.startswith("<") and ">" in target:
            target = target[1:target.index(">")]
        else:
            target = target.split(' "', 1)[0].split(" '", 1)[0]
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        decoded = unquote(parsed.path)
        if decoded.startswith("/"):
            error(path, "Markdown file link must be relative to the repository", content.count("\n", 0, match.start()) + 1)
            continue
        destination = (ROOT / path.parent / decoded).resolve()
        try:
            relative = destination.relative_to(ROOT)
        except ValueError:
            error(path, "Markdown link escapes the repository")
            continue
        if relative not in files and not any(relative in file.parents for file in files):
            error(path, "Markdown link target is missing or untracked: " + relative.as_posix())


def check_resources(files: set[Path]) -> None:
    for name, key, expected in (("PDFAProfiles", "profiles", 11), ("PDFFontData", "items", 215)):
        base = Path("Resources") / name
        mirror = Path("Sources/CartaPDF/Resources") / name
        canonical_files = {p.relative_to(base) for p in files if base in p.parents}
        mirrored_files = {p.relative_to(mirror) for p in files if mirror in p.parents}
        if canonical_files != mirrored_files:
            error(base, "resource copy does not match the SwiftPM resource file list")
        for relative in canonical_files & mirrored_files:
            if (ROOT / base / relative).read_bytes() != (ROOT / mirror / relative).read_bytes():
                error(base / relative, "resource copy differs from SwiftPM resource")
        try:
            manifest = read_json(base / "MANIFEST.json")
            entries = manifest[key]
            if len(entries) != expected:
                error(base, "unexpected resource manifest entry count")
            listed: set[str] = set()
            for item in entries:
                relative = PurePosixPath(item["file"])
                if relative.is_absolute() or ".." in relative.parts or str(relative) in listed:
                    error(base, "invalid or duplicate manifest file entry")
                    continue
                listed.add(str(relative))
                path = base / str(relative)
                if path not in files:
                    error(path, "manifest references an untracked resource")
                elif hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != item["sha256"]:
                    error(path, "manifest SHA-256 does not match resource bytes")
                if key == "profiles":
                    tree = ET.parse(ROOT / path)
                    count = sum(1 for node in tree.iter() if node.tag.rsplit("}", 1)[-1] == "rule")
                    if count != item["rule_count"]:
                        error(path, "catalogue rule count differs from manifest")
            if key == "profiles":
                if sum(item["rule_count"] for item in entries) != 1489:
                    error(base, "unexpected total PDF/A catalogue count")
                for filename, hash_key in (("LICENSE.txt", "license_text_sha256"), ("UPSTREAM-README.md", "upstream_readme_sha256")):
                    if hashlib.sha256((ROOT / base / filename).read_bytes()).hexdigest() != manifest[hash_key]:
                        error(base / filename, "upstream attribution hash does not match")
            for required in ("NOTICE.txt", "MANIFEST.json"):
                if base / required not in files:
                    error(base / required, "required third-party data attribution is missing")
        except (OSError, ValueError, KeyError, TypeError, ET.ParseError):
            error(base, "resource manifest or licensed data could not be verified")


def check_workflows(files: set[Path]) -> None:
    for path in sorted(files):
        if path.parent != Path(".github/workflows") or path.suffix not in {".yml", ".yaml"}:
            continue
        content = (ROOT / path).read_text(encoding="utf-8")
        for action in re.findall(r"^\s*(?:-\s*)?uses:\s*(\S+)", content, re.MULTILINE):
            if action.startswith("./"):
                continue
            if not re.fullmatch(r"actions/[A-Za-z0-9_-]+@[0-9a-f]{40}", action):
                error(path, "remote actions must be official GitHub actions pinned to a full commit SHA")
        if "pull_request_target" in content:
            error(path, "privileged pull request workflows are outside this repository's CI policy")
        if re.search(r"\b(?:write-all|contents:\s*write|id-token:\s*write)\b", content):
            error(path, "CI must not request write or identity-token permissions")


def main() -> int:
    try:
        paths = repository_files()
    except (OSError, subprocess.CalledProcessError, UnicodeError):
        print("Repository check failed: Git could not enumerate source files.", file=sys.stderr)
        return 1
    files = set(paths)
    if not files:
        print("Repository check failed: no source files found.", file=sys.stderr)
        return 1
    for path in sorted(files):
        content = check_file(path)
        if content is not None and path.suffix == ".md":
            check_markdown(path, content, files)
    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if re.search(r"\.(?:package|binaryTarget)\s*\(", package):
        error("Package.swift", "external package or binary dependencies are outside the project policy")
    check_resources(files)
    check_workflows(files)
    if ERRORS:
        for item in ERRORS:
            print(item, file=sys.stderr)
        print(f"Repository check failed: {len(ERRORS)} issue(s).", file=sys.stderr)
        return 1
    print(f"Repository check passed: {len(files)} source files; 11 PDF/A catalogues, 1489 entries and 215 font data resources verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
