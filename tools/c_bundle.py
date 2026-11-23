#!/usr/bin/env python3
"""Bundle a V-generated C file with the V-tree headers it includes.

V emits absolute `#include "C:/path/to/v/..."` lines for its own runtime
headers (atomic ops, OS shims, stb_truetype). A C file with those includes
only builds where that exact V checkout lives, so it is not a distributable.
This script rewrites those includes to vendored copies beside the C file:

    python3 tools/c_bundle.py <vroot> <in.c> <out.c> <thirdparty-dir> [--runtime-c a/b.c,...]

Positional args are as before; --runtime-c names extra V-tree *sources*
the link needs beyond headers (today: the OS thunk that defines symbols
the generated C declares but never defines, e.g. core_windows.c on
Windows). They are copied beside the headers and compiled alongside
<out.c>; the list is explicit per platform because it is part of the
build contract, not discovered. A companion's quoted *relative* includes
are closed over automatically: siblings that exist in the V tree are
vendored next to it (segfault_handler_nix.c brings its own header, which
the generated C never names), while system headers are left for the C
compiler.

Layout: <out.c> sits next to a `thirdparty/` directory, and each V-root
include `vroot/<rel>` is vendored to `thirdparty/<vendored>` with the
include rewritten to `"thirdparty/<vendored>"`, where `<vendored>` is
`<rel>` with one leading `thirdparty/` component stripped when present
(so V's own `thirdparty/foo.h` lands at `thirdparty/foo.h`, not
`thirdparty/thirdparty/foo.h`, while `vlib/...` lands at
`thirdparty/vlib/...`). Companion sources use the same mapping and are
compiled by path, so their sibling relative includes keep working.

Every absolute V-root include is copied to <thirdparty-dir>/<relpath> and
the include rewritten to "thirdparty/<relpath>". Anything left over fails
loud instead of writing a partial bundle: a missing header or source, an
unparseable include, or a surviving absolute V-root reference after the
rewrite.

Usage: run right after `v -shared -gc none -o <in.c>` for the module, then
build <out.c> (+ vendored companions) with a plain C compiler: no V include
paths are needed. Exit 0 after writing the bundle, 1 on any refusal.
"""

import os
import re
import shutil
import sys


def fail(msg):
    print(f'c_bundle REFUSED: {msg}')
    return 1


def main():
    args = sys.argv[1:]
    runtime_cs = []
    if '--runtime-c' in args:
        k = args.index('--runtime-c')
        if k + 1 >= len(args):
            print('usage: python3 tools/c_bundle.py <vroot> <in.c> <out.c> <thirdparty-dir> [--runtime-c a/b.c,...]')
            return 1
        runtime_cs = [c.strip().replace('\\', '/').lstrip('/') for c in args[k + 1].split(',') if c.strip()]
        args = args[:k]
    if len(args) != 4:
        print('usage: python3 tools/c_bundle.py <vroot> <in.c> <out.c> <thirdparty-dir> [--runtime-c a/b.c,...]')
        return 1
    vroot, in_path, out_path, third_dir = args
    vroot = vroot.replace('\\', '/').rstrip('/')
    # V normalizes most emitted paths to forward slashes (seen on Windows),
    # but a linux-target translation on a Windows host emits mixed
    # spellings (backslash root, forward rest), so every separator in the
    # root matches either slash. Without this a variant slips through the
    # rewrite and survives as an absolute include.
    vroots = [vroot]
    if '/' in vroot:
        vroots.append(vroot.replace('/', '\\'))
    def root_pat(v):
        # Map each separator to a both-slashes class *before* escaping, so
        # the backslash re.escape puts in front of '-', '.' etc. is never
        # mistaken for a path separator.
        return ''.join(r'[/\\]' if ch in ('/', '\\') else re.escape(ch) for ch in v)
    include_res = [re.compile(r'^(\s*#\s*include\s*")' + root_pat(v) + r'[/\\]([^"]+)(".*)$') for v in vroots]
    try:
        with open(in_path, 'r', encoding='utf-8') as f:
            lines = f.read().split('\n')
    except OSError as e:
        return fail(f'cannot read {in_path}: {e}')

    class Refuse(Exception):
        pass

    def vendor_rel(rel, kind):
        if not rel or rel.startswith('/') or '..' in rel.split('/'):
            raise Refuse(f'refusing unsafe {kind} path {rel!r}')
        vendored = rel[len('thirdparty/'):] if rel.startswith('thirdparty/') else rel
        src = vroot + '/' + rel
        if not os.path.isfile(src):
            raise Refuse(f'{kind} missing in V tree: {src}')
        dst = os.path.join(third_dir, *vendored.split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if not os.path.isfile(dst):
            shutil.copyfile(src, dst)
            copied.append(vendored)
        else:
            with open(src, 'rb') as a, open(dst, 'rb') as b:
                if a.read() != b.read():
                    raise Refuse(f'vendored {vendored} differs from V tree copy')
        return vendored

    copied = []
    try:
        out_lines = []
        for i, line in enumerate(lines, 1):
            m = None
            for rx in include_res:
                m = rx.match(line)
                if m:
                    break
            if not m:
                out_lines.append(line)
                continue
            rel = m.group(2).replace('\\', '/')
            vendored = vendor_rel(rel, f'header (gen.c line {i})')
            out_lines.append(f'{m.group(1)}thirdparty/{vendored}{m.group(3)}')
    except Refuse as e:
        return fail(str(e))
    text = '\n'.join(out_lines)
    # Includes are the build gate: an absolute V-root include only builds
    # where that exact checkout lives. Anything else absolute is string
    # data (today: V's zoneinfo zip path, built at init but read only by
    # timezone-name resolution, which no library path calls — the only
    # time use in the tree is monotonic ticks), so those are reported,
    # not refused.
    for i, line in enumerate(out_lines, 1):
        s = line.strip()
        flat = s.replace('\\', '/')
        if s.startswith('#include') and vroot in flat:
            return fail(f'surviving absolute V-root include at line {i}: {s}')
        if s.startswith('#include') and re.search(r'[A-Za-z]:[\\/]', s):
            return fail(f'line {i}: absolute include left in output: {s}')
    notes = []
    for i, line in enumerate(out_lines, 1):
        if vroot in line.replace('\\', '/') and not line.strip().startswith('#include'):
            notes.append(i)
    if notes:
        print(f'c_bundle: note: {len(notes)} non-include line(s) name the V root (inert string data): {notes[:5]}')
    # Companion sources: copy, then close over their quoted *relative*
    # includes. A companion names siblings in the V tree that the generated
    # C never names (segfault_handler_nix.c including its own header), so
    # the header pass above never sees them: resolve each against the
    # companion's own directory and vendor whatever exists there. Anything
    # else (system headers, bundle-local names) is left for the C compiler
    # to resolve or reject. Absolute V-root includes inside companions are
    # refused, because no checkout exists to resolve them against downstream.
    quoted_re = re.compile(r'^(\s*#\s*include\s*")([^"]+)(".*)$')
    try:
        rt_copied = []
        pairs = []
        for rel in runtime_cs:
            if not rel.endswith('.c'):
                raise Refuse(f'runtime-c must be .c files, got {rel!r}')
            rt_copied.append(vendor_rel(rel, 'runtime-c'))
            pairs.append((rel, rt_copied[-1]))
        seen = set()
        while pairs:
            rel, vendored = pairs.pop()
            if vendored in seen:
                continue
            seen.add(vendored)
            with open(os.path.join(third_dir, *vendored.split('/')), 'r',
                      encoding='utf-8', errors='replace') as f:
                body = f.read()
            base = os.path.dirname(rel)
            for n, sline in enumerate(body.split('\n'), 1):
                s = sline.strip()
                if not s.startswith('#include'):
                    continue
                if vroot in s.replace('\\', '/') or re.search(r'[A-Za-z]:[\\/]', s):
                    raise Refuse(f'companion {vendored} line {n} has V-root/absolute include: {s}')
                qm = quoted_re.match(sline)
                if not qm:
                    continue
                target = qm.group(2).replace('\\', '/')
                if not target or target.startswith('/') or '..' in target.split('/'):
                    continue
                sibling = (base + '/' + target).lstrip('/') if base else target
                if not os.path.isfile(vroot + '/' + sibling):
                    continue
                sv = vendor_rel(sibling, f'sibling header (from {vendored} line {n})')
                pairs.append((sibling, sv))
    except Refuse as e:
        return fail(str(e))
    except OSError as e:
        return fail(f'cannot read vendored companion: {e}')
    try:
        parent = os.path.dirname(os.path.abspath(out_path))
        os.makedirs(parent, exist_ok=True)
        with open(out_path, 'w', encoding='utf-8', newline='') as f:
            f.write(text)
    except OSError as e:
        return fail(f'cannot write {out_path}: {e}')
    print(f'c_bundle: vendored {len(copied)} file(s): {", ".join(copied) if copied else "(none new)"}')
    if runtime_cs:
        print(f'c_bundle: runtime-c {len(rt_copied)} new: {", ".join(rt_copied) if rt_copied else "(all already vendored)"}')
    print(f'c_bundle: wrote {out_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
