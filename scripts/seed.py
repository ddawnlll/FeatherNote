#!/usr/bin/env python3
"""Seed FeatherNote with synthetic notes for benchmarking.

Usage: scripts/seed.py --db data/feathernote.db --count 10000 --body-size 1024
The schema must exist first (run: feathernote admin integrity --db PATH).
"""
import argparse
import sqlite3
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--body-size", type=int, default=1024)
    ap.add_argument("--clear", action="store_true")
    args = ap.parse_args()

    con = sqlite3.connect(args.db)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=FULL")
    if args.clear:
        con.execute("DELETE FROM notes")
    now = int(time.time())
    rows = []
    for i in range(args.count):
        title = f"Seed note {i:05d}"
        prefix = f"seed {i} lorem ipsum dolor sit amet needle-{i}\n"
        if len(prefix) >= args.body_size:
            body = prefix[: args.body_size]
        else:
            body = prefix + "x" * (args.body_size - len(prefix))
        pinned = 1 if i % 500 == 0 else 0
        rows.append((title, body, now - i, now - i, 1, pinned, None))
    con.executemany(
        "INSERT INTO notes(title,body,created_at,updated_at,version,is_pinned,deleted_at)"
        " VALUES(?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    total = con.execute("SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL").fetchone()[0]
    print(f"seeded {args.count} notes ({total} active), body_size={args.body_size} bytes, db={args.db}")
    con.close()


if __name__ == "__main__":
    main()
