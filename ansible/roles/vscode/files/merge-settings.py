#!/usr/bin/env python3
"""Add missing VS Code defaults, preserving existing values and an original backup."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile

# Match quoted strings first so comments and trailing commas inside strings survive.
JSONC = re.compile(r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/')
TRAILING_COMMAS = re.compile(r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])')

def read_settings(text):
    def clean(match):
        token = match.group()
        if token.startswith('"'):
            return token
        return "".join("\n" if char == "\n" else " " for char in token)
    value = json.loads(TRAILING_COMMAS.sub(clean, JSONC.sub(clean, text)))
    if not isinstance(value, dict):
        raise ValueError("VS Code settings must be an object")
    return value

def merge_missing(current, defaults):
    changed = False
    for key, value in defaults.items():
        if key not in current:
            current[key] = value
            changed = True
        elif isinstance(current[key], dict) and isinstance(value, dict):
            changed = merge_missing(current[key], value) or changed
    return changed

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=Path)
    parser.add_argument("defaults", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = args.settings
    if path.is_symlink():
        raise ValueError("Refusing a symlinked settings file")
    original = path.read_text(encoding="utf-8-sig") if path.exists() else None
    current = read_settings(original) if original is not None else {}
    defaults = read_settings(args.defaults.read_text(encoding="utf-8-sig"))
    if not merge_missing(current, defaults):
        print("unchanged")
        return
    if not args.check:
        latest = path.read_text(encoding="utf-8-sig") if path.exists() else None
        if path.is_symlink() or latest != original:
            raise RuntimeError("VS Code settings changed during setup; rerun to review them")
        path.parent.mkdir(parents=True, exist_ok=True)
        if original is not None:
            backup = path.with_name(path.name + ".workstation.bak")
            try:
                with backup.open("x", encoding="utf-8") as output:
                    os.chmod(backup, 0o600)
                    output.write(original)
            except FileExistsError:
                pass
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                             prefix=".workstation-", delete=False) as output:
                temporary = output.name
                json.dump(current, output, indent=4, ensure_ascii=False)
                output.write("\n")
            latest = path.read_text(encoding="utf-8-sig") if path.exists() else None
            if path.is_symlink() or latest != original:
                raise RuntimeError("VS Code settings changed during setup; rerun to review them")
            os.replace(temporary, path)
            temporary = None
        finally:
            if temporary is not None:
                Path(temporary).unlink(missing_ok=True)
    print("changed")

if __name__ == "__main__":
    main()
