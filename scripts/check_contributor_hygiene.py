#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
FORBIDDEN = [
    "cl" + "aude",
    "co-" + "authored-by",
    "noreply@" + "anthropic.com",
]


def run_git(args: list[str]) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True)


def contains_forbidden(text: str) -> list[str]:
    lower = text.lower()
    return [pattern for pattern in FORBIDDEN if pattern in lower]


def check_history() -> list[str]:
    issues: list[str] = []
    log = run_git(["log", "--all", "--format=%H%n%an <%ae>%n%cn <%ce>%n%B%n---"])
    for block in log.split("\n---\n"):
        if not block.strip():
            continue
        hits = contains_forbidden(block)
        if hits:
            commit = block.splitlines()[0]
            issues.append(f"git history contains forbidden contributor metadata in {commit}: {', '.join(hits)}")
    return issues


def check_worktree() -> list[str]:
    issues: list[str] = []
    paths = [
        ROOT / "README.md",
        ROOT / ".gitignore",
        ROOT / ".github" / "workflows" / "build.yml",
    ]
    for path in paths:
        if not path.exists():
            continue
        hits = contains_forbidden(path.read_text(encoding="utf-8"))
        if hits:
            issues.append(f"{path.relative_to(ROOT)} contains forbidden contributor metadata: {', '.join(hits)}")

    local_settings_dir = ROOT / ("." + "cl" + "aude")
    if local_settings_dir.exists():
        issues.append(f"{local_settings_dir.relative_to(ROOT)} must not exist in the repository workspace")
    return issues


def check_shortlog() -> list[str]:
    shortlog = run_git(["shortlog", "-sne", "--all"])
    contributors = [line.strip() for line in shortlog.splitlines() if line.strip()]
    suffix = "davidmasinzprahy <david.masin@gmail.com>"
    if len(contributors) != 1 or not contributors[0].endswith(suffix):
        return ["expected exactly one contributor in git shortlog, got: " + "; ".join(contributors)]
    return []


def main() -> int:
    issues = check_history() + check_worktree() + check_shortlog()
    if issues:
        print("Contributor hygiene check failed:", file=sys.stderr)
        for issue in issues:
            print(f"  - {issue}", file=sys.stderr)
        return 1
    print("OK - contributor metadata is clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
