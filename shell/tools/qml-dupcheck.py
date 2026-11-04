#!/usr/bin/env python3
"""A property or handler set twice in the same QML object.

    qml-dupcheck.py FILE.qml ...     prints each one; exit status 1 if any

QML refuses such a file outright ("Property value set multiple times"),
and with it every file that uses it: one of these in a service once kept
the whole shell from loading. qmllint doesn't report it.
"""
import re
import sys

found = 0
for path in sys.argv[1:]:
    src = open(path).read()
    # Strip comments and strings, keep braces/newlines.
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        if c in "\"'`":
            q = c; i += 1
            while i < n and src[i] != q:
                i += 2 if src[i] == "\\" else 1
            i += 1; out.append('""'); continue
        out.append(c); i += 1
    text = "".join(out)
    stack = [{}]
    kinds = []  # 'obj' or 'code' per brace
    line = 1; pos = 0
    tokens = re.finditer(r"\{|\}|\n|^[ \t]*((?:readonly\s+)?(?:property\s+\S+\s+)?[A-Za-z_][\w.]*)\s*:", text, re.M)
    for m in tokens:
        t = m.group(0)
        if t == "\n": line += 1; continue
        if t == "{":
            before = text[max(0, m.start() - 80):m.start()]
            is_obj = re.search(r"(^|[\s;])[A-Z][\w.]*\s*$", before) is not None
            kinds.append(is_obj); stack.append({} if is_obj else None); continue
        if t == "}":
            if kinds: kinds.pop(); stack.pop()
            continue
        name = m.group(1)
        if stack and stack[-1] is not None and name and not name.startswith("case") and name not in ("default",):
            key = re.sub(r"^(readonly\s+)?property\s+\S+\s+", "", name)
            if key in stack[-1]:
                print(f"{path}:{line}: '{key}' set again (first at {stack[-1][key]})")
                found += 1
            else:
                stack[-1][key] = line
        line += t.count("\n")

sys.exit(1 if found else 0)
