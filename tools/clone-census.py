#!/usr/bin/env python3
"""Clone census over the two duplicate-code rules' lint output: findings, families,
occurrences, purely-renamed families, cross-file share, and the bare-run share.

usage: clone-census.py <label> <t2-report> <t1-report> <repo-root>
                       [--cache DIR] [--after <t2-report> <t1-report>] [--removed FILE]

<t2-report> / <t1-report> are `hxq lint --rule duplicate-code-renamed` and
`--rule duplicate-code` output, either `--flat` text or `--format json`, taken with
CWD = <repo-root> so the paths resolve. Each finding's statement run is resolved
through `hxq ast <file> --json` (cached under --cache, default a temp dir), so a run's
region and each statement's text are exact.

The bare-run share is a TEXT-REGEX reading independent of the engine: a run whose
every statement is `var|final name[:T] [= name|literal]` or `name[.name] = name|literal`.
The engine's own predicate is structural (`DuplicateCode.isBareStmt`), and the two are
meant to disagree at the edges (an interpolating string, a `cast`); the regex is the
cross-check, not the definition. With `--after`, the removed families are listed by
name (`--removed FILE`) and the agreement matrix between the two readings is printed.
"""
import argparse
import collections
import json
import os
import re
import subprocess

LINE = re.compile(r'^(\S+?):(\d+):(\d+): \[info\] (\d+) statements duplicated from (?:(\S+?):)?(?:line )?(\d+)')
MESSAGE = re.compile(r'^(\d+) statements duplicated from (?:(\S+?):)?(?:line )?(\d+)')
VALUE = r"(-?[A-Za-z_][\w.]*|-?\d[\w.]*|'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|\[\]|\{\})"
BARE_DECL = re.compile(r"^(var|final)\s+[A-Za-z_]\w*\s*(:\s*[^=]+?)?\s*(=\s*" + VALUE + r")?\s*;?\s*$", re.S)
BARE_ASSIGN = re.compile(r"^[A-Za-z_][\w.]*\s*=\s*" + VALUE + r"\s*;?\s*$", re.S)


def parse_report(path):
    """Findings from a `--flat` text or a `--format json` lint report."""
    text = open(path).read()
    out = []
    if text.lstrip().startswith('['):
        for rec in json.loads(text):
            m = MESSAGE.match(rec['message'])
            if not m:
                continue
            n, of, ol = m.groups()
            out.append(finding(rec['file'], rec['line'], rec['col'], n, of, ol))
        return out
    for l in text.split('\n'):
        m = LINE.match(l)
        if m:
            f, line, col, n, of, ol = m.groups()
            out.append(finding(f, line, col, n, of, ol))
    return out


def finding(f, line, col, n, of, ol):
    return {'file': f, 'line': int(line), 'col': int(col), 'n': int(n),
            'origFile': of or f, 'origLine': int(ol), 'cross': of is not None}


def key(f):
    return (f['file'], f['line'], f['n'], f['origFile'], f['origLine'])


def family(f):
    return (f['origFile'], f['origLine'])


class Runs:
    """Statement runs resolved through the AST of ONE tree (`root`): both reports of an `--after` pair are
    resolved against it, so run the tool on the tip tree whose files the base report still describes."""

    def __init__(self, label, root, cache):
        self.label, self.root, self.cache = label, root, cache
        self.index = {}
        self.lines = {}
        self.trees = {}
        if cache:
            os.makedirs(cache, exist_ok=True)

    def ast(self, file):
        """One `hxq ast --json` per file per process; the disk cache is opt-in because a directory reused on
        another tree resolves runs against stale spans."""
        if file in self.trees:
            return self.trees[file]
        p = os.path.join(self.cache, self.label + '__' + file.replace('/', '__') + '.json') if self.cache else None
        if p and os.path.exists(p):
            tree = json.load(open(p))
        else:
            r = subprocess.run(['hxq', 'ast', file, '--json'], cwd=self.root, capture_output=True, text=True)
            tree = json.loads(r.stdout)
            if p:
                open(p, 'w').write(r.stdout)
        self.trees[file] = tree
        return tree

    def nodes_at(self, file):
        """(startLine, startCol) -> [(node, siblings, index)], outermost first."""
        if file not in self.index:
            by = {}

            def walk(n):
                kids = n.get('children', [])
                for i, c in enumerate(kids):
                    s = c.get('span')
                    if s:
                        by.setdefault((s['start'][0], s['start'][1]), []).append((c, kids, i))
                    walk(c)
            walk(self.ast(file)['tree'])
            self.index[file] = by
        return self.index[file]

    def source_lines(self, file):
        if file not in self.lines:
            self.lines[file] = open(os.path.join(self.root, file)).read().split('\n')
        return self.lines[file]

    def text(self, file, span):
        ls = self.source_lines(file)
        (l1, c1), (l2, c2) = span['start'], span['end']
        if l1 == l2:
            return ls[l1 - 1][c1 - 1:c2 - 1]
        return '\n'.join([ls[l1 - 1][c1 - 1:]] + ls[l1:l2 - 1] + [ls[l2 - 1][:c2 - 1]])

    def run_of(self, f):
        """The n statement nodes of finding f, or None when the position resolves to no run."""
        cands = self.nodes_at(f['file']).get((f['line'], f['col']))
        if not cands:
            return None
        for node, sibs, i in cands:
            if i + f['n'] <= len(sibs):
                return sibs[i:i + f['n']]
        return None

    def classify(self, f):
        stmts = self.run_of(f)
        if stmts is None:
            return 'unresolved'
        texts = [self.text(f['file'], s['span']).strip() for s in stmts]
        if all(BARE_DECL.match(t) for t in texts):
            return 'bare-decl'
        if all(BARE_ASSIGN.match(t) for t in texts):
            return 'bare-assign'
        if all(BARE_DECL.match(t) or BARE_ASSIGN.match(t) for t in texts):
            return 'bare-mixed'
        return 'logic'


def census(label, t2, t1, runs):
    families = collections.defaultdict(list)
    for f in t2:
        families[family(f)].append(f)
    t1_endpoints = set()
    for f in t1:
        t1_endpoints.add((f['file'], f['line']))
        t1_endpoints.add((f['origFile'], f['origLine']))
    pure = [f for f in t2 if (f['file'], f['line']) not in t1_endpoints and family(f) not in t1_endpoints]
    pure_fams = {k for k, v in families.items() if all(x in pure for x in v)}
    cross = [f for f in t2 if f['cross']]
    t1_fams = {family(f) for f in t1}
    print(f'[{label}] type-2 findings={len(t2)} families={len(families)} occurrences={len(t2) + len(families)} '
          f'purely-renamed findings={len(pure)} purely-renamed families={len(pure_fams)} '
          f'cross-file={len(cross)} same-file={len(t2) - len(cross)}')
    print(f'[{label}] type-1 findings={len(t1)} families={len(t1_fams)} occurrences={len(t1) + len(t1_fams)} '
          f'cross-file={sum(1 for f in t1 if f["cross"])}')
    contained = sum(1 for k in t1_fams if k in families)
    print(f'[{label}] containment: type-1 families whose anchor is also a type-2 anchor={contained} of {len(t1_fams)}')
    for rule, fs in (('type-2', t2), ('type-1', t1)):
        kinds = collections.Counter()
        fam_kinds = {}
        for f in fs:
            f['kind'] = runs.classify(f)
            kinds[f['kind']] += 1
        fams = collections.defaultdict(set)
        for f in fs:
            fams[family(f)].add(f['kind'])
        for k, ks in fams.items():
            fam_kinds[k] = 'mixed' if len(ks) > 1 else next(iter(ks))
        bare_f = sum(v for k, v in kinds.items() if k.startswith('bare'))
        bare_fam = sum(1 for v in fam_kinds.values() if v.startswith('bare'))
        print(f'[{label}] {rule} findings by run kind (regex): {dict(sorted(kinds.items()))} '
              f'bare share={bare_f}/{len(fs)} findings, {bare_fam}/{len(fams)} families')
    return families


def compare(label, base, after, runs, removed_path):
    """Removed / added findings between two reports, and the regex reading of each side."""
    for rule, b, a in (('type-2', base[0], after[0]), ('type-1', base[1], after[1])):
        bk = {key(f): f for f in b}
        ak = {key(f): f for f in a}
        removed = [bk[k] for k in bk if k not in ak]
        added = [ak[k] for k in ak if k not in bk]
        kept = [ak[k] for k in ak if k in bk]
        agree = collections.Counter()
        for f in removed:
            agree[('removed', runs.classify(f).startswith('bare'))] += 1
        for f in kept:
            agree[('kept', runs.classify(f).startswith('bare'))] += 1
        removed_fams = sorted({family(f) for f in removed})
        print(f'[{label}] {rule} removed={len(removed)} findings / {len(removed_fams)} families, added={len(added)}, kept={len(kept)}; '
              f'regex agrees: removed&bare={agree[("removed", True)]} removed&logic={agree[("removed", False)]} '
              f'kept&bare={agree[("kept", True)]} kept&logic={agree[("kept", False)]}')
        for f in added:
            print(f'[{label}] {rule} ADDED {f["file"]}:{f["line"]} n={f["n"]} from {f["origFile"]}:{f["origLine"]}')
        if removed_path:
            with open(removed_path, 'a') as out:
                for fam in removed_fams:
                    members = [f for f in removed if family(f) == fam]
                    out.write(f'{label} {rule} {fam[0]}:{fam[1]} x{len(members)} n={members[0]["n"]} '
                              f'{"regex-bare" if runs.classify(members[0]).startswith("bare") else "regex-logic"}\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('label')
    ap.add_argument('t2')
    ap.add_argument('t1')
    ap.add_argument('root')
    ap.add_argument('--cache', default=None, help='keep each `hxq ast --json` output here across runs (opt-in: keyed by label + path, so a directory reused on another tree resolves runs against stale spans)')
    ap.add_argument('--after', nargs=2, metavar=('T2_AFTER', 'T1_AFTER'))
    ap.add_argument('--removed', help='append the removed families, one per line, to this file')
    args = ap.parse_args()
    runs = Runs(args.label, args.root, args.cache)
    t2, t1 = parse_report(args.t2), parse_report(args.t1)
    census(args.label, t2, t1, runs)
    if args.after:
        t2a, t1a = parse_report(args.after[0]), parse_report(args.after[1])
        census(args.label + ' after', t2a, t1a, runs)
        compare(args.label, (t2, t1), (t2a, t1a), runs, args.removed)


if __name__ == '__main__':
    main()
