#!/usr/bin/env python3
"""Insert a small set of realistic notes into a fresh FeatherNote demo DB."""
import sqlite3
import sys
import time

db_path = sys.argv[1]
con = sqlite3.connect(db_path)
con.execute("PRAGMA journal_mode=WAL")
con.execute("PRAGMA synchronous=FULL")

now = int(time.time())
H = 3600
D = 24 * H

notes = [
    ("Reading list", """Books to get through this winter

- The Soul of a New Machine — Tracy Kidder
- A Philosophy of Software Design — John Ousterhout
- The Peregrine — J. A. Baker
- Crafting Interpreters — Robert Nystrom (re-read the tree-walk chapters)

Half-finished: Seeing Like a State. Pick it back up at the chapter on
scientific forestry.""", 2 * D, True),
    ("Zig 0.17 async I/O notes", """Writing this down before I forget.

std.Io is the new interface. A writer is a *Writer with a buffer; the
old std.io getStdOut() pattern is gone.

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

Reading a request body means asking the reader for more, not allocating
the whole thing up front. The 320 KiB cap is enforced before parsing.

Question for later: does the connection accept loop need a cancellation
scope per request, or is one per connection enough?""", 4 * H, True),
    ("Sourdough schedule", """Starter is finally behaving. Current plan:

Day 1, 21:00  Feed 1:1:1, leave on the counter.
Day 2, 09:00  Mix dough: 500 g flour, 350 g water, 100 g starter, 10 g salt.
Day 2, 09:30  Four sets of stretch and folds, 30 min apart.
Day 2, 13:00  Shape, then cold retard in the fridge.
Day 3, 08:00  Bake at 250 C in the dutch oven, 20 min lid on, 20 min lid off.

Notes: the crumb was tighter when I bulk fermented in the cold kitchen.
Move the bowl to the top of the fridge next time.""", 1 * D + 3 * H, False),
    ("Server backup checklist", """Before any update or migration:

1. feathernote admin integrity --db .../feathernote.db
2. feathernote admin backup --db .../feathernote.db --out .../daily/pre-update.db
3. Confirm integrity_check: ok on the backup, not just the live file
4. Copy the backup off the host (encrypted) at least weekly
5. Restore drill once a quarter into a scratch directory

Do not copy a live WAL database with cp. Use the backup command.""", 26 * H, False),
    ("Trip to Lisbon", """Flights booked, 14-21 March.

Things to do:
- Day trip to Sintra, go early, buy the Pena Palace ticket online
- Tram 28 is a pickpocket festival, take the bus instead
- LX Factory on Sunday morning
- Time Out Market is fine but overpriced; the tascas in Alfama are better

Food: pasteis de Belem, the original shop, not the lookalikes near
Rossio. Ask the hotel about the seafood place by the ferry terminal.""", 3 * D, False),
    ("Notes on writing docs", """Docs are read by someone who is already frustrated.

- Lead with the thing that works, not the architecture.
- Every screenshot should show a real state, not a mockup.
- If a step can fail silently, say how to verify it.
- Put the long explanation after the short one, never instead of it.

The README is the front door. It should answer "what is this" in one
screen, then "how do I run it" in the next.""", 5 * D, False),
    ("Groceries", """- Coffee beans (the Ethiopian one, not the blend)
- Oat milk
- Eggs, a dozen
- Bread flour
- Lemons
- Dish soap
- Batteries, AA""", 2 * H, False),
    ("Home network", """Router: 192.168.1.1, admin password in the password manager.
Pi-hole at 192.168.1.10, DHCP hands it out as the only DNS.
The NAS is on a static lease, .20.

Todo: move the printer off the guest network, it keeps losing the queue.
Todo: document the switch ports. Port 4 is the one that flickers.""", 6 * D, False),
    ("Interview questions to ask", """Ask the engineer, not the recruiter:

- What did you ship last quarter, and what did it cost in maintenance?
- Where does the on-call rotation hurt most?
- What is the oldest thing in the repo that nobody wants to touch?
- How do decisions get reversed here?

Red flag: "we don't really have documentation" said cheerfully.""", 8 * D, False),
    ("Zig build system snippet", """Embedding a stylesheet at build time:

    const assets = b.createModule(.{
        .root_source_file = b.path("assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("assets", assets);

Then @embedFile in assets.zig. No runtime file reads, no path
assumptions in the binary. Cache invalidation is just a rebuild.""", 9 * D, False),
    ("Books I quit and why", """- Infinite Jest: twice. It is fine to stop.
- The Fountainhead: made it 200 pages, could not care less.
- Gödel, Escher, Bach: brilliant in pieces, exhausting as a whole.
  Keep it on the shelf, read an essay at a time.

No shame in quitting a book. The sunk cost is the book's problem.""", 11 * D, False),
    ("Bug: search misses hyphenated words", """Repro: note body contains "pre-update", search for "pre-update"
returns nothing, but "update" matches.

Cause: the search grammar splits on whitespace and quotes each term
with the double-quote phrase syntax, so the hyphen is treated as a
token separator inside FTS5, not part of the term. A phrase query for
"pre-update" does not match a document tokenized as pre + update.

Fix idea: normalize the query the same way the tokenizer does, or use
a prefix query. Needs a test either way.""", 13 * D, False),
    ("Weekly review template", """Wins:
- Shipped the backup timer
- Fixed the flaky integration test

Drags:
- Spent a day on a CSS bug that was one line

Next week, three things:
1. Finish the README
2. Restore drill
3. Read two chapters of the Ousterhout book

One thing to stop doing: refreshing the deploy logs every ten minutes.""", 15 * D, False),
    ("Packing list, cabin weekend", """- Boots, it will be muddy
- Headlamp + spare batteries
- The good knife and the small cutting board
- Coffee, grinder, filters (the cabin has a kettle only)
- Book, one is enough
- Board games: Codenames, maybe Hive
- Check the woodpile when we arrive""", 7 * H, False),
]

for title, body, age_seconds, pinned in notes:
    ts = now - age_seconds
    con.execute(
        "INSERT INTO notes(title,body,created_at,updated_at,version,is_pinned,deleted_at)"
        " VALUES(?,?,?,?,1,?,NULL)",
        (title, body, ts, ts, 1 if pinned else 0),
    )

# Two notes in Trash so the trash view is not empty.
for title, body, age in [
    ("Old router config", "WPA2 key was on the sticky note. Superseded by the new mesh setup.", 20 * D),
    ("Draft: standing desk build", "Bought the frame, never ordered the top. Revisit in spring.", 30 * D),
]:
    ts = now - age
    con.execute(
        "INSERT INTO notes(title,body,created_at,updated_at,version,is_pinned,deleted_at)"
        " VALUES(?,?,?,?,1,0,?)",
        (title, body, ts, ts, ts),
    )

con.commit()
active = con.execute("SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL").fetchone()[0]
trash = con.execute("SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL").fetchone()[0]
print(f"seeded {active} active notes, {trash} in trash")
con.close()
