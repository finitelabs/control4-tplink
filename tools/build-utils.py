#!/usr/bin/env python3
"""Small build helpers that replace external CLI tools with the Python we
already require. Each is a subcommand:

  build-utils.py readme <input.md> <output.md>
      Generate the repo README from the driver docs markdown: strip <style>
      blocks and prettier-ignore markers, then normalize with mdformat.
      (replaces: pandoc + tools/pandoc-remove-style.lua)

  build-utils.py xml-get-name <driver.xml>
      Print /devicedata/name. (replaces: xmlstarlet sel)

  build-utils.py xml-set <driver.xml> <version|modified> <value>
      Set /devicedata/<version|modified> text in place, preserving the rest of
      the file byte-for-byte. (replaces: xmlstarlet edit --inplace)

  build-utils.py zip <output.zip> <file>...
      Create a zip of the given files (stored flat, basenames).
      (replaces: the `zip` CLI)
"""

import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree


def _strip_doc_chrome(text: str) -> str:
    # Remove <style>...</style> blocks and prettier-ignore comment markers — the
    # same things tools/pandoc-remove-style.lua stripped from the README.
    text = re.sub(r"<style\b[^>]*>.*?</style>", "", text, flags=re.S | re.I)
    text = re.sub(r"<!--\s*prettier-ignore.*?-->", "", text, flags=re.S | re.I)
    return text


def readme(input_path: Path, output_path: Path) -> None:
    import mdformat

    text = _strip_doc_chrome(input_path.read_text(encoding="utf-8"))
    text = mdformat.text(text, options={"wrap": 80}, extensions={"gfm"})
    output_path.write_text(text, encoding="utf-8")


def xml_get_name(xml_path: Path) -> None:
    root = ElementTree.parse(xml_path).getroot()
    name = root.findtext("name")
    if name is None:
        raise SystemExit(f"no /devicedata/name in {xml_path}")
    sys.stdout.write(name)


def xml_set(xml_path: Path, tag: str, value: str) -> None:
    if tag not in ("version", "modified"):
        raise SystemExit(f"xml-set only supports version|modified, got {tag!r}")
    text = xml_path.read_text(encoding="utf-8")
    # Handle both the empty self-closing form (<version/>) and a populated form
    # (<version>...</version>); replace only the first, top-level occurrence.
    pattern = rf"<{tag}\s*/>|<{tag}>.*?</{tag}>"
    replacement = f"<{tag}>{value}</{tag}>"
    new_text, n = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if n == 0:
        raise SystemExit(f"no <{tag}> element in {xml_path}")
    xml_path.write_text(new_text, encoding="utf-8")


def make_zip(output_path: Path, files: list[Path]) -> None:
    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            zf.write(f, arcname=f.name)


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 1
    cmd, rest = args[0], args[1:]
    if cmd == "readme" and len(rest) == 2:
        readme(Path(rest[0]).resolve(), Path(rest[1]).resolve())
    elif cmd == "xml-get-name" and len(rest) == 1:
        xml_get_name(Path(rest[0]).resolve())
    elif cmd == "xml-set" and len(rest) == 3:
        xml_set(Path(rest[0]).resolve(), rest[1], rest[2])
    elif cmd == "zip" and len(rest) >= 2:
        make_zip(Path(rest[0]).resolve(), [Path(p).resolve() for p in rest[1:]])
    else:
        print(__doc__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
