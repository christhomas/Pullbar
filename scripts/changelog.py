#!/usr/bin/env python3
"""Edit CHANGELOG.md and the changelog block in README.md.

Usage:
  scripts/changelog.py release <version> <repo> <summary-file>
      Move the Unreleased notes into a new version entry, add the pull
      request list from <summary-file>, then refresh the README.
  scripts/changelog.py readme
      Copy the two newest CHANGELOG entries into README.md, between the
      changelog:start and changelog:end markers.

Called by scripts/create-release.sh; run `readme` by hand after editing the
Unreleased notes.
"""
import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
README = ROOT / "README.md"
START = "<!-- changelog:start -->"
END = "<!-- changelog:end -->"
EMPTY = "_Nothing yet._"


def split_entries(text):
    """Return (preamble, [entry, ...]); each entry starts with a '## ' line."""
    parts = re.split(r"(?m)^(?=## )", text)
    return parts[0], [p.strip("\n") for p in parts[1:]]


def entry_body(entry):
    return entry.split("\n", 1)[1].strip() if "\n" in entry else ""


def is_empty_unreleased(entry):
    return entry.startswith("## Unreleased") and entry_body(entry) in ("", EMPTY)


def demote(markdown):
    """Add one '#' to every heading outside fenced code blocks."""
    out, fence = [], False
    for line in markdown.split("\n"):
        if line.startswith("```"):
            fence = not fence
        elif not fence and re.match(r"#+ ", line):
            line = "#" + line
        out.append(line)
    return "\n".join(out)


def release(version, repo, summary_file):
    preamble, entries = split_entries(CHANGELOG.read_text())
    if not entries or not entries[0].startswith("## Unreleased"):
        sys.exit("CHANGELOG.md must start its entries with '## Unreleased'.")
    notes = "" if is_empty_unreleased(entries[0]) else entry_body(entries[0])
    summary = pathlib.Path(summary_file).read_text().strip() or "_None._"
    today = datetime.date.today().isoformat()

    body = [f"## [{version}](https://github.com/{repo}/releases/tag/v{version}) - {today}"]
    if notes:
        body.append(notes)
    body.append("### Pull requests\n\n" + summary)
    entries[0:1] = [f"## Unreleased\n\n{EMPTY}", "\n\n".join(body)]

    CHANGELOG.write_text(preamble + "\n\n".join(entries) + "\n")
    readme()


def readme():
    _, entries = split_entries(CHANGELOG.read_text())
    newest = [e for e in entries if not is_empty_unreleased(e)][:2]
    block = "\n\n".join(demote(e) for e in newest) or EMPTY

    text = README.read_text()
    if START not in text or END not in text:
        sys.exit(f"README.md needs the {START} and {END} markers.")
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    README.write_text(f"{head}{START}\n\n{block}\n\n{END}{tail}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["release"] and len(sys.argv) == 5:
        release(*sys.argv[2:])
    elif sys.argv[1:] == ["readme"]:
        readme()
    else:
        sys.exit(__doc__)
