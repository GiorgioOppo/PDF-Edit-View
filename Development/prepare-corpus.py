#!/usr/bin/env python3
"""Acquire pinned official PDF/A test DATA for development, never app runtime.

Only PDF_A-* directories are selected. Isartor is excluded. Original Git blob
hashes are verified; no validator engine or third-party code is downloaded.
"""
import argparse
import concurrent.futures
import hashlib
import json
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

COMMIT = "377728596647e40edf16003d68d620773ce96ec5"
REPOSITORY = "https://github.com/veraPDF/veraPDF-corpus"
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--workers", type=int, default=4)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
headers = {"User-Agent":"CartaPDF-development-corpus/3.2"}

def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        return response.read()

tree = json.loads(fetch("https://api.github.com/repos/veraPDF/veraPDF-corpus/git/trees/" + COMMIT + "?recursive=1"))
if tree.get("truncated"):
    raise RuntimeError("Official tree inventory was truncated")
entries = []
for item in tree["tree"]:
    relative = PurePosixPath(item["path"])
    if (item["type"] == "blob" and item["path"].startswith("PDF_A-") and
            relative.suffix.lower() == ".pdf" and not relative.is_absolute() and
            all(part not in (".","..") for part in relative.parts)):
        entries.append(item)
entries.sort(key=lambda item:item["path"])
if len(entries) != 2164:
    raise RuntimeError("Unexpected pinned corpus inventory")
inventory = {"repository":REPOSITORY,"commit":COMMIT,
             "license":"CC BY 4.0; PDF_A-* data only; Isartor excluded","files":entries}
(args.output / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")

def valid(data, entry):
    return (len(data) == entry["size"] and
            hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == entry["sha"])

def acquire(entry):
    destination = args.output / "files" / entry["path"]
    if destination.is_file() and valid(destination.read_bytes(),entry):
        return None
    try:
        data = fetch("https://raw.githubusercontent.com/veraPDF/veraPDF-corpus/" + COMMIT + "/" +
                     urllib.parse.quote(entry["path"],safe="/"))
        if not valid(data,entry):
            raise RuntimeError("Downloaded bytes do not match the pinned Git blob")
        destination.parent.mkdir(parents=True,exist_ok=True)
        temporary = destination.with_name(destination.name + ".partial")
        temporary.write_bytes(data)
        temporary.replace(destination)
        return None
    except Exception as error:
        return {"file":entry["path"],"error":str(error)}

errors = []
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1,min(args.workers,8))) as pool:
    for index,error in enumerate(pool.map(acquire,entries),1):
        if error:
            errors.append(error)
        if index % 100 == 0:
            print(f"{index}/{len(entries)} verified or attempted",flush=True)
proof = {"repository":REPOSITORY,"commit":COMMIT,"files":len(entries),
         "bytes":sum(entry["size"] for entry in entries),"errors":errors,
         "engine_downloaded":False,"application_runtime_network":False}
(args.output / "download.json").write_text(json.dumps(proof,indent=2) + "\n")
print(json.dumps({key:value for key,value in proof.items() if key!="errors"}))
if errors:
    raise SystemExit(1)
