"""Compare the new Windows V7 schema with the result of the actual Mac SQL.

Does not open user data. --write regenerates the blank database schema snapshot.
This is not a legacy-data migration implementation.
"""
import pathlib
import re
import sqlite3
import sys
import textwrap

root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "JotBloomCore/Persistence/DatabaseMigrator.swift").read_text()
operations = dict((operation, textwrap.dedent(sql).strip()) for sql, operation in
                  re.findall(r'"""(.*?)""",\s*operation: "([^"]+)"', source, re.S))
operations["migrate_v4_library_order"] = re.search(
    r'execute\("([^"]+)", operation: "migrate_v4_library_order"', source).group(1)
db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys=ON")
for name in ["create_inspirations", "create_inspirations_index", "create_drafts",
             "create_clipboard_items", "create_clipboard_items_time_index",
             "create_clipboard_items_image_index", "migrate_v3", "migrate_v4_library_order",
             "migrate_v5_chat", "migrate_v6_history", "migrate_v7_ai"]:
    db.executescript(operations[name])

def objects(connection):
    return connection.execute("SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL "
                              "AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()

target = root / "Windows/src/JotBloom.Windows.Storage/SchemaV7.sql"
if "--write" in sys.argv:
    # Tables must exist before their indexes/triggers. Cross-table FK definitions are allowed.
    rows = sorted(objects(db), key=lambda row: (row[0] != "table", row[0], row[1]))
    target.write_text("-- Blank V7 snapshot from Mac DatabaseMigrator.swift. See scripts/check-schema.py.\n"
                      + "\n\n".join(row[2] + ";" for row in rows) + "\nPRAGMA user_version=7;\n")
candidate = sqlite3.connect(":memory:")
candidate.executescript(target.read_text())
normalize = lambda rows: [(t, n, re.sub(r'\s+', ' ', sql).strip()) for t, n, sql in rows]
assert normalize(objects(db)) == normalize(objects(candidate)), "Windows V7 schema differs from Mac"
assert candidate.execute("PRAGMA user_version").fetchone()[0] == 7
print(f"PASS: {len(objects(db))} V7 tables/indexes/triggers match Mac migration SQL")
