#!/usr/bin/env python3
"""
Repair UTF-8 / XML-character issues in marketing SVG files.
Writes UTF-8 without BOM and Unix newlines only.
"""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


# XML 1.0 Char excludes most C0 controls; keep TAB, LF, CR only before cleaning text.
# str.maketrans: use None to delete (ZWSP, BOM, etc.).
_TRANSLATE_PUNCT = str.maketrans(
    {
        "\ufeff": None,
        "\u00a0": " ",
        "\u200b": None,
        "\u200c": None,
        "\u200d": None,
        "\u2060": None,
        "\u2028": "\n",
        "\u2029": "\n",
        "\u2022": "-",  # bullet
        "\u00b7": "-",  # middle dot (bytes repair also replaces lone 0xB7)
        "\u2013": "-",  # en dash
        "\u2014": "-",  # em dash
        "\u201c": '"',
        "\u201d": '"',
        "\u2018": "'",
        "\u2019": "'",
    }
)


def _repair_bytes(raw: bytes) -> bytes:
    """Fix common breakage: BOM, stray Latin-1 middle-dot bytes mangling UTF-8."""
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    # Prefer replacing well-formed middot sequences first so we don't leave orphan C2.
    raw = raw.replace("\u00b7".encode(), b"-")  # valid UTF-8 sequence for U+00B7
    raw = raw.replace(b"\xb7", b"-")
    return raw


def _substitute_xml_invalid_controls(s: str) -> str:
    """
    XML 1.0 disallows most C0 bytes in Char. Preserve TAB/LF/CR; map embedded
    control bytes commonly caused by corrupted punctuation to ASCII.
    """
    out: list[str] = []
    for ch in s:
        o = ord(ch)
        if o in (9, 10, 13):
            out.append(ch)
        elif o < 32:
            # 0x19 often appears where a right apostrophe was mangled ("We're").
            if o == 0x19:
                out.append("'")
            else:
                out.append("-")
        elif 55296 <= o <= 57343 or o in (65534, 65535):  # surrogates / non-chars
            continue
        else:
            out.append(ch)
    return "".join(out)


def sanitize_text_content(s: str) -> str:
    s = s.translate(_TRANSLATE_PUNCT)
    return _substitute_xml_invalid_controls(s)


def process_file(path: Path, dry_run: bool) -> tuple[bool, str | None]:
    raw_in = path.read_bytes()
    raw = _repair_bytes(raw_in)

    try:
        s = raw.decode("utf-8")
    except UnicodeDecodeError:
        # Last resort: drop undecodable bytes (should be rare after b7 repair)
        s = raw.decode("utf-8", errors="replace")

    s = sanitize_text_content(s)
    # Normalise Windows newlines -> LF (ASCII only)
    s = s.replace("\r\n", "\n").replace("\r", "\n")

    parse_error: str | None = None
    try:
        ET.fromstring(s)
    except ET.ParseError as exc:
        parse_error = str(exc)

    if dry_run:
        return (parse_error is None, parse_error)

    path.write_bytes(s.encode("utf-8"))
    return (parse_error is None, parse_error)


def main() -> int:
    parser = argparse.ArgumentParser(description="Sanitize SVG encoding and XML characters.")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="instagram_launch directory",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root: Path = args.root
    svgs = sorted(root.rglob("*.svg"))
    if not svgs:
        print("No SVG files found.", file=sys.stderr)
        return 1

    failed: list[tuple[Path, str]] = []
    for p in svgs:
        ok, err = process_file(p, args.dry_run)
        if not ok and err:
            failed.append((p, err))

    if args.dry_run:
        print(f"Checked {len(svgs)} SVG(s).")
    else:
        print(f"Sanitized {len(svgs)} SVG(s) under {root}.")

    if failed:
        print("\nParse failures after sanitize:", file=sys.stderr)
        for p, err in failed:
            print(f"  {p.relative_to(root)}: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
