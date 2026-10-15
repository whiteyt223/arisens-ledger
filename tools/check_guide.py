#!/usr/bin/env python3
"""Validate reframework/data/arisens_guide.json (run by CI and before you open a pull request).

    python tools/check_guide.py
"""
import json
import sys
from pathlib import Path

PATH = Path(__file__).resolve().parent.parent / "reframework" / "data" / "arisens_guide.json"
REQUIRED = {
    "id": int, "name": str, "how": str, "decision": bool, "choices": list, "best": str,
    "rewards": str, "warnings": list, "follow_ups": str, "confidence": str, "sources": list,
}
OPTIONAL = {"item_hints": dict}
CONFIDENCE = {"high", "medium", "low"}
LIMITS = {"how": 90, "best": 45, "follow_ups": 40}  # words; generous versions of the style guide


def words(s):
    return len(s.split())


def main():
    errors = []
    try:
        raw = PATH.read_text(encoding="utf-8")
    except OSError as e:
        print(f"cannot read {PATH}: {e}")
        return 1
    bad = [i for i, ch in enumerate(raw) if ord(ch) > 127]
    if bad:
        line = raw.count("\n", 0, bad[0]) + 1
        errors.append(f"non-ASCII character on line {line} (use straight quotes and plain dashes; the in-game font has no fancy punctuation)")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"invalid JSON: {e}")
        return 1
    if not isinstance(data, list):
        print("top level must be a JSON array of quest entries")
        return 1

    seen = set()
    for n, q in enumerate(data):
        where = f"entry {n} ({q.get('name', '?') if isinstance(q, dict) else '?'})"
        if not isinstance(q, dict):
            errors.append(f"{where}: must be an object")
            continue
        for key, typ in REQUIRED.items():
            if key not in q:
                errors.append(f"{where}: missing '{key}'")
            elif not isinstance(q[key], typ) or (typ is int and isinstance(q[key], bool)):
                errors.append(f"{where}: '{key}' must be {typ.__name__}")
        for key in q:
            if key not in REQUIRED and key not in OPTIONAL:
                errors.append(f"{where}: unknown key '{key}'")
        if errors and errors[-1].startswith(where):
            continue
        if q["id"] in seen:
            errors.append(f"{where}: duplicate id {q['id']}")
        seen.add(q["id"])
        if q["confidence"] not in CONFIDENCE:
            errors.append(f"{where}: confidence must be one of {sorted(CONFIDENCE)}")
        for key, lim in LIMITS.items():
            if words(q[key]) > lim:
                errors.append(f"{where}: '{key}' is {words(q[key])} words (keep it under {lim}; it shows in a small overlay)")
        for c in q["choices"]:
            if not isinstance(c, dict) or not all(isinstance(c.get(k), str) for k in ("option", "outcome", "rewards")):
                errors.append(f"{where}: each choice needs string 'option', 'outcome' and 'rewards'")
        if q["decision"] and not q["choices"]:
            errors.append(f"{where}: decision is true but there are no choices")
        if not all(isinstance(w, str) for w in q["warnings"]):
            errors.append(f"{where}: warnings must be strings")
        if len(q["warnings"]) > 5:
            errors.append(f"{where}: more than 5 warnings; keep the most important ones")
        for s in q["sources"]:
            if not isinstance(s, str) or not s.startswith(("http://", "https://")):
                errors.append(f"{where}: sources must be http(s) URLs")
        for item, hint in (q.get("item_hints") or {}).items():
            if not isinstance(hint, str) or not hint.strip():
                errors.append(f"{where}: item_hints['{item}'] must be a non-empty string")

    ids = [q.get("id") for q in data if isinstance(q, dict)]
    if ids != sorted(ids):
        errors.append("entries must be sorted by id")

    if errors:
        print(f"{len(errors)} problem(s) in {PATH.name}:")
        for e in errors:
            print("  - " + e)
        return 1
    print(f"OK: {len(data)} quests, {sum(1 for q in data if q['decision'])} with choices, "
          f"{sum(1 for q in data if q.get('item_hints'))} with item hints")
    return 0


if __name__ == "__main__":
    sys.exit(main())
