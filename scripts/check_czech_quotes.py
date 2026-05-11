#!/usr/bin/env python3
"""Lint Swift source files for unsafe Czech-quote patterns.

Problem: Czech typography pairs „ (U+201E, low-9 double quote)
with " (U+201C, left double quote — i.e. the opening high mark
used at end of word). When a developer types „word" and the
closing mark is an ASCII U+0022 instead of the Unicode U+201C,
the ASCII " terminates the surrounding Swift string literal
mid-text, producing cryptic SyntaxError diagnostics.

This script scans .swift files for the unsafe combination and
reports each occurrence. Exit code is non-zero when issues are
found so it slots into pre-commit / CI.

Safe patterns:
  - „word"   (closing is Unicode U+201C → safe inside Swift string)
  - „word\\"  (closing is escaped ASCII → safe)
  - „word.   (no closing quote — typography incomplete but compiles)

Unsafe pattern:
  - „word"   (closing is unescaped ASCII U+0022 inside a literal)
"""
from __future__ import annotations

import pathlib
import sys

LOW_QUOTE = '„'          # U+201E
HIGH_QUOTE = '"'         # U+201C (Czech closing, safe)
ASCII_QUOTE = '"'        # U+0022 (Swift string delimiter — unsafe inside string)


def scan_line(line: str) -> str | None:
    """Return diagnostic message when line has an unsafe pattern, else None.

    Walks the line LTR. Whenever it sees a low-quote U+201E it
    looks ahead for the nearest closing mark. If that closing mark
    is an unescaped ASCII U+0022, the pattern is unsafe.
    """
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == LOW_QUOTE:
            # Find the nearest closing mark of any kind.
            j = i + 1
            while j < len(line):
                c = line[j]
                if c == HIGH_QUOTE:
                    break  # safe form
                if c == ASCII_QUOTE:
                    # Check if escaped (preceded by an odd number of backslashes).
                    backslashes = 0
                    k = j - 1
                    while k >= 0 and line[k] == '\\':
                        backslashes += 1
                        k -= 1
                    if backslashes % 2 == 1:
                        break  # escaped — safe form
                    return (
                        f"unescaped ASCII \" closes Czech low-quote pair "
                        f"(position {j}): {line.strip()[:140]}"
                    )
                j += 1
            i = j + 1
        else:
            i += 1
    return None


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent / "SpiceHarvester"
    if not root.is_dir():
        print(f"error: directory not found: {root}", file=sys.stderr)
        return 2
    issues: list[str] = []
    for path in root.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for ln, line in enumerate(text.splitlines(), start=1):
            # Skip pure-comment lines so we don't flag prose in
            # doc comments that may use less-strict typography.
            stripped = line.lstrip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            diag = scan_line(line)
            if diag is not None:
                issues.append(f"{path.relative_to(root.parent)}:{ln}: {diag}")
    if issues:
        print("Czech-quote lint failures:", file=sys.stderr)
        for issue in issues:
            print(f"  {issue}", file=sys.stderr)
        print(
            f"\n{len(issues)} unsafe pattern(s). "
            f"Replace ASCII \" with Unicode “ or backslash-escape it.",
            file=sys.stderr,
        )
        return 1
    print(f"OK — scanned {sum(1 for _ in root.rglob('*.swift'))} Swift files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
