#!/usr/bin/env python3
"""Fixture catalog check (spec/14-qa.md §4.3).

Verifies that each fixture root's CATALOG.txt agrees exactly with what is on disk, that entries are grouped
and sorted, and that each file is well formed for its type. Standard library only, no network, no Xcode, so
it runs on Linux in CI before the package tests: a mangled fixture is then reported once, as a catalog
failure, rather than as a pile of confusing decode failures.

Exit codes: 0 pass, 1 failures (each printed as "FAIL <check>: <detail>"), 2 usage error.

DEVIATION from the spec's §5.1 catalog: modules 02 and 03 inlined their fixtures instead of writing the
`gmail` and `mime` families to disk, so the catalogs describe the files that exist (vectors, html) rather
than the 65 the spec anticipated. The family lists and EXPECTED_SIZES below are kept as written, so the
checks activate by themselves if those fixtures ever land.
"""

import hashlib
import json
import sys
from pathlib import Path

ROOTS = [
    ("Packages/MailCore/Tests/MailCoreTests/Fixtures", ["gmail", "mime", "vectors"]),
    ("Packages/MailCore/Tests/MailHTMLTests/Fixtures", ["html"]),
]

# Byte sizes that pin fixtures whose exact bytes a test asserts against. Entries for files that are not in a
# catalog are never consulted.
EXPECTED_SIZES = {
    "mime/reply-all.eml": 2276,
    "mime/forward-pdf.eml": 2927,
    "mime/forward-pdf-gmailweb.eml": 2971,
    "mime/stub.pdf": 125,
}

UTF8_SUFFIXES = (".html", ".txt", ".json", ".eml", ".sha256")
RAW_ALPHABET = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

failures = []


def fail(check, detail):
    failures.append(check)
    print(f"FAIL {check}: {detail}")


def catalog_entries(path):
    """Non-comment, non-blank lines of a CATALOG.txt."""
    lines = path.read_text(encoding="utf-8").split("\n")
    out = []
    for raw in lines:
        line = raw.rstrip("\r").strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


def disk_entries(root):
    """Every regular file under root as a relative path, minus CATALOG.txt and dot-files."""
    out = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.name == "CATALOG.txt" or path.name.startswith("."):
            continue
        out.append(str(path.relative_to(root)))
    return sorted(out)


def check_order(root_name, entries, families):
    """C5: sorted ascending inside a family, families in the order given."""
    seen = []
    for entry in entries:
        family = entry.split("/", 1)[0]
        if not seen or seen[-1] != family:
            if family in seen:
                fail("order", f"{root_name}: family {family!r} appears in more than one block")
                return
            seen.append(family)
    if seen != [f for f in families if f in seen]:
        fail("order", f"{root_name}: families {seen} are not in the order {families}")
    for family in seen:
        block = [e for e in entries if e.split("/", 1)[0] == family]
        if block != sorted(block):
            fail("order", f"{root_name}: {family} entries are not sorted")


def check_contents(root, entry):
    path = root / entry
    data = path.read_bytes()

    if entry.endswith(UTF8_SUFFIXES):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            fail("utf8", f"{entry}: {error}")
            return
    else:
        text = None

    if entry.endswith(".json"):
        try:
            json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as error:
            fail("json", f"{entry}: {error}")

    if entry.endswith(".eml"):
        sidecar = path.with_suffix(".sha256")
        if sidecar.is_file():
            want = sidecar.read_text(encoding="utf-8").strip()
            got = hashlib.sha256(data).hexdigest()
            if got != want:
                fail("sha256", f"{entry}: catalog says {want}, file is {got}")
        if b"\r\n" not in data:
            fail("crlf", f"{entry}: no CRLF line endings")
        elif data.replace(b"\r\n", b"").find(b"\n") != -1:
            fail("crlf", f"{entry}: contains a bare LF")

    if entry.endswith(".raw.txt") and text is not None:
        if "\n" in text:
            fail("raw", f"{entry}: must be a single line")
        elif set(text.strip()) - RAW_ALPHABET:
            fail("raw", f"{entry}: not unpadded base64url")

    if entry.startswith("gmail/batch.") and entry.endswith(".txt"):
        if b"\r\n" in data:
            fail("lf", f"{entry}: committed with CRLF; tests convert, so it must be LF")
        elif b"\n" not in data:
            fail("lf", f"{entry}: no newlines")

    expected = EXPECTED_SIZES.get(entry)
    if expected is not None and len(data) != expected:
        fail("size", f"{entry}: expected {expected} bytes, file is {len(data)}")


def main(argv):
    wants_order = "--check-order" in argv
    unknown = [a for a in argv[1:] if a != "--check-order"]
    if unknown:
        print(f"usage: {argv[0]} [--check-order]", file=sys.stderr)
        return 2

    total = 0
    for root_name, families in ROOTS:
        root = Path(root_name)
        catalog_path = root / "CATALOG.txt"
        if not catalog_path.is_file():
            fail("catalog", f"{root_name}/CATALOG.txt is missing")
            continue

        catalog = catalog_entries(catalog_path)
        disk = disk_entries(root)

        missing = [e for e in catalog if e not in disk]
        extra = [e for e in disk if e not in catalog]
        if missing:
            fail("catalog", f"{root_name}: in CATALOG.txt but not on disk: {missing}")
        if extra:
            fail("catalog", f"{root_name}: on disk but not in CATALOG.txt: {extra}")

        for entry in catalog:
            family = entry.split("/", 1)[0] if "/" in entry else ""
            if family not in families:
                fail("family", f"{root_name}: {entry!r} is not in a known family {families}")

        if wants_order:
            check_order(root_name, catalog, families)

        for entry in catalog:
            if entry in disk:
                check_contents(root, entry)
        total += len(catalog)

    if failures:
        print(f"{len(failures)} failure(s)")
        return 1
    print(f"OK {total} fixtures in {len(ROOTS)} roots")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
