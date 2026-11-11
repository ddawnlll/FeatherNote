#!/usr/bin/env python3
"""Build the Goose escape spike and compare exact bytes with FeatherNote's Zig rule.

No network access, no server, no production database. Requires Goose on PATH.
The reference mirrors src/http_util.zig::escapeHtml (not Python html.escape).
"""
import os
import pathlib
import random
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SOURCE = HERE / "escape_html.goose"

def reference(data: bytes) -> bytes:
    return (data.replace(b"&", b"&amp;")
                .replace(b"<", b"&lt;")
                .replace(b">", b"&gt;")
                .replace(b'"', b"&quot;")
                .replace(b"'", b"&#39;"))

def main() -> int:
    goose = shutil.which("goose")
    if not goose:
        print("FAIL: Goose compiler not on PATH. Install from aardappel/goose releases.", file=sys.stderr)
        return 2

    # Pin the compiler version or commit in the eventual full benchmark report.
    print("Goose compiler:", subprocess.run([goose, "version"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.strip())
    with tempfile.TemporaryDirectory(prefix="feather-goose-") as tmp:
        exe = str(pathlib.Path(tmp) / "escape_html")
        for cmd in ([goose, "check", str(SOURCE)],
                    [goose, "build", "-o", exe, str(SOURCE)]):
            print("+", " ".join(cmd))
            subprocess.run(cmd, cwd=HERE, check=True)

        cases = [
            b"", b"hello", b"&<>\\\"'", b"&&&&", b"<script>alert(1)</script>",
            b"</textarea> \"x\" 'y' &amp;", b"newline\\nline2\\r\\n", b"zero\\x00byte",
            "Grüße aus Köln — 日本語 🪶".encode("utf-8"),
            (b"nothing-to-escape " * 8192),
            (b"<&'\"x>" * 32768),
        ]
        rng = random.Random(20261111)
        alphabet = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<>&\"' /\\n\\r\\t"
        for _ in range(64):
            size = rng.randrange(0, 8192)
            cases.append(bytes(alphabet[rng.randrange(len(alphabet))] for _ in range(size)))

        for i, data in enumerate(cases):
            actual = subprocess.run([exe], input=data, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=True).stdout
            expected = reference(data)
            if actual != expected:
                limit = min(len(actual), len(expected))
                first = next((n for n in range(limit) if actual[n] != expected[n]), limit)
                print(f"FAIL case {i}, first byte diff at {first}, "
                      f"actual={actual[max(0,first-12):first+40]!r}, "
                      f"expected={expected[max(0,first-12):first+40]!r}", file=sys.stderr)
                return 1
        print(f"PASS: {len(cases)} differential fixtures; identical bytes.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
