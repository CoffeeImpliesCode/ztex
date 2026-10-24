#!/usr/bin/env python3
"""KaTeX screenshotter corpus as a ztex differential battery.

Loads KaTeX's test/screenshotter/ss_data.yaml, renders each formula through the
ztex binary, and reports parse support or an error class with a summary.

Usage:
    python3 scripts/katex_corpus.py [--ztex PATH] [--out notes/katex-corpus.md]
"""
import argparse
import os
import subprocess
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(os.path.expanduser("~"), "projects", "katex",
                      "test", "screenshotter", "ss_data.yaml")


def corpus_entries():
    d = yaml.safe_load(open(CORPUS))
    for name, v in d.items():
        if isinstance(v, str):
            yield name, v, False
        else:
            yield name, v.get("tex", ""), bool(v.get("display"))


def probe(ztex, tex, size=20):
    r = subprocess.run([ztex, "-i", tex, "-o", "/tmp/kc_probe.svg",
                        "-s", str(size), "-b", "white"],
                       capture_output=True, text=True, cwd=REPO)
    if r.returncode == 0:
        return "SUPPORTED", ""
    err = (r.stdout + r.stderr)
    if "UnknownCommand" in err:
        return "FAILED", "UnknownCommand"
    if "Unsupported" in err:
        return "FAILED", "Unsupported"
    if "Mismatched" in err or "Unclosed" in err or "Unexpected" in err:
        return "FAILED", "env/structure error"
    if "MissingArgument" in err:
        return "FAILED", "MissingArgument"
    return "FAILED", "other"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ztex", default=os.path.join(REPO, "zig-out", "bin", "ztex"))
    ap.add_argument("--out", default=os.path.join(REPO, "notes", "katex-corpus.md"))
    args = ap.parse_args()

    entries = list(corpus_entries())
    rows, ok = [], 0
    for name, tex, display in entries:
        status, why = probe(args.ztex, tex)
        if status == "SUPPORTED":
            ok += 1
        rows.append((name, display, status, why, tex.replace("\n", " ")[:90]))
    rows.sort(key=lambda r: (r[2], r[0]))

    with open(args.out, "w") as f:
        f.write("# KaTeX screenshotter corpus vs ztex\n\n")
        f.write(f"{len(entries)} entries; **{ok} SUPPORTED / {len(entries)-ok} FAILED**.\n\n")
        f.write("| name | display | status | error | tex |\n|---|---|---|---|---|\n")
        for name, display, status, why, tex in rows:
            f.write(f"| {name} | {'D' if display else 'I'} | {status} | {why} | `{tex}` |\n")
    print(f"{ok}/{len(entries)} SUPPORTED, {len(entries)-ok} FAILED -> {args.out}")
    for name, display, status, why, tex in rows:
        if status == "FAILED":
            print(f"  FAIL {name}: {why} — {tex[:70]}")


if __name__ == "__main__":
    sys.exit(main())
