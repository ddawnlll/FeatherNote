#!/usr/bin/env python3
"""Measure explicit history purge on a synthetic database.

Builds one note with N full-snapshot revisions, then runs the real
`admin purge-history` dry run and apply, and the read-only doctor. Prints JSON;
no claim is made about percentile distributions because this is a single
administrative operation.

Usage: python3 scripts/bench-retention.py --revisions 100000 --keep-last 100
"""
import argparse
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = "retention benchmark password 123"


def seconds():
    return time.perf_counter()


def run(binary, args):
    started = seconds()
    result = subprocess.run([binary, "admin", *args], capture_output=True,
                            text=True, cwd=ROOT)
    return (seconds() - started) * 1000.0, result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=os.path.join(ROOT, "zig-out", "bin", "feathernote"))
    ap.add_argument("--revisions", type=int, default=100000)
    ap.add_argument("--keep-last", type=int, default=100)
    args = ap.parse_args()
    binary = os.path.abspath(args.binary)
    if args.revisions < 1 or args.keep_last < 1:
        print("revisions and keep-last must be positive", file=sys.stderr)
        return 2
    scratch = os.path.join(ROOT, ".jcode-test")
    if not os.path.isdir(scratch):
        scratch = None
    work = tempfile.mkdtemp(prefix="feathernote-retention-", dir=scratch)
    db_path = os.path.join(work, "retention.db")
    try:
        subprocess.run([binary, "admin", "set-password", "--db", db_path],
                       input=(PASSWORD + "\n").encode(), check=True, cwd=ROOT,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        title, body = "retention benchmark", "one body"
        digest = hashlib.sha256()
        digest.update(len(title).to_bytes(8, "little"))
        digest.update(title.encode())
        digest.update(len(body).to_bytes(8, "little"))
        digest.update(body.encode())
        checksum = digest.hexdigest()
        now = 1700000000
        conn = sqlite3.connect(db_path)
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute(
            "INSERT INTO notes(title,body,created_at,updated_at,version,is_pinned,deleted_at)"
            " VALUES(?,?,?,?,?,0,NULL)", (title, body, now, now, args.revisions))
        note_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        rows = ((note_id, i, i, title, body, 0, now + i, "web", "update", "", checksum)
                for i in range(1, args.revisions + 1))
        conn.executemany(
            "INSERT INTO note_revisions(note_id,revision_no,note_version,title,body,"
            "is_pinned,created_at,origin,action,summary,checksum)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?)", rows)
        conn.commit()
        conn.close()

        before = os.path.getsize(db_path)
        dry_ms, dry = run(binary, ["purge-history", "--db", db_path,
                                   "--keep-last", str(args.keep_last)])
        apply_ms, applied = run(binary, ["purge-history", "--db", db_path,
                                         "--keep-last", str(args.keep_last), "--apply"])
        after = os.path.getsize(db_path)
        doctor_ms, doctor = run(binary, ["doctor", "--db", db_path])
        result = {
            "revisions": args.revisions,
            "keep_last": args.keep_last,
            "database_bytes_before": before,
            "database_bytes_after": after,
            "dry_run_ms": round(dry_ms, 1),
            "apply_ms": round(apply_ms, 1),
            "doctor_ms": round(doctor_ms, 1),
            "dry_run_output": dry.stdout + dry.stderr,
            "apply_output": applied.stdout + applied.stderr,
            "dry_run_ok": dry.returncode == 0 and "verification: PASS" in (dry.stdout + dry.stderr),
            "apply_ok": applied.returncode == 0 and "verification: PASS" in (applied.stdout + applied.stderr),
            "doctor_ok": doctor.returncode == 0,
            "note": "single operation on one VM; database file does not shrink without VACUUM",
        }
        print(json.dumps(result, indent=2))
        return 0 if result["dry_run_ok"] and result["apply_ok"] and result["doctor_ok"] else 1
    finally:
        for name in os.listdir(work):
            os.unlink(os.path.join(work, name))
        os.rmdir(work)


if __name__ == "__main__":
    sys.exit(main())
