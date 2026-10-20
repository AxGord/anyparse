#!/usr/bin/env python3
"""Fails when text a downstream project must not see published is about to enter the repository.

usage: scrub-guard.py [--list PATH] [--range A..B] [--quiet]

The token list is NOT part of this repository, by design: a list of the names to keep out
would itself publish them. It is read from --list or from the ANYPARSE_SCRUB_LIST environment
variable, in git-filter-repo `--replace-text` form, so the file that rewrites history is the
same file that guards it - one entry per line, `old==>new`, `regex:<python re>==>new` or
`literal:old==>new`; only the left-hand side is read, the replacement is ignored.

Without --range the tracked files of the work tree are scanned (binary files skipped, as
filter-repo skips them). With --range A..B the lines that range ADDS (`git diff A B`) and its
commit messages are scanned instead - what a push would publish (tools/hooks/pre-push-scrub.sh).

Exit 0 = clean, or no list configured (reported on stderr, so a clone without the private list
is not blocked); 1 = a match, each printed as `<where>:<line>: rule <n>`; 2 = usage error.
"""
import argparse
import os
import re
import subprocess
import sys

BINARY_PROBE = 8192


def load_rules(path):
    """The left-hand sides of a filter-repo replace-text file, each as a compiled bytes regex."""
    rules = []
    with open(path, 'rb') as f:
        for raw in f:
            line = raw.rstrip(b'\r\n')
            if b'==>' in line:
                line = line.rsplit(b'==>', 1)[0]
            if line.startswith(b'regex:'):
                rules.append(re.compile(line[len(b'regex:'):]))
            else:
                if line.startswith(b'literal:'):
                    line = line[len(b'literal:'):]
                if line:
                    rules.append(re.compile(re.escape(line)))
    return rules


def scan(where, data, rules, quiet):
    """Prints one row per (line, rule) match in `data`; returns the number of rows."""
    hits = 0
    for n, rule in enumerate(rules, 1):
        for m in rule.finditer(data):
            hits += 1
            if not quiet:
                line = data.count(b'\n', 0, m.start()) + 1
                print(f'{where}:{line}: rule {n}')
    return hits


def git(*args):
    return subprocess.run(['git', *args], capture_output=True, check=True).stdout


def scan_tree(rules, quiet):
    hits = 0
    for name in git('ls-files', '-z').split(b'\0'):
        if not name or not os.path.isfile(name):
            continue
        with open(name, 'rb') as f:
            data = f.read()
        if b'\0' in data[:BINARY_PROBE]:
            continue
        hits += scan(name.decode('utf-8', 'replace'), data, rules, quiet)
    return hits


def scan_range(span, rules, quiet):
    if '..' not in span:
        raise SystemExit('scrub-guard: --range needs A..B')
    base, tip = span.split('..', 1)
    added = b'\n'.join(
        line[1:] for line in git('diff', '--no-color', '-U0', base, tip).split(b'\n')
        if line.startswith(b'+') and not line.startswith(b'+++')
    )
    messages = git('log', '--format=%H%n%B', f'{base}..{tip}')
    return scan(f'diff {span}', added, rules, quiet) + scan(f'messages {span}', messages, rules, quiet)


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('--list', default=os.environ.get('ANYPARSE_SCRUB_LIST'))
    parser.add_argument('--range')
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args()
    if not args.list:
        print('scrub-guard: no token list (--list / ANYPARSE_SCRUB_LIST), nothing checked', file=sys.stderr)
        return 0
    if not os.path.isfile(args.list):
        print(f'scrub-guard: token list {args.list} does not exist', file=sys.stderr)
        return 2
    rules = load_rules(args.list)
    hits = scan_range(args.range, rules, args.quiet) if args.range else scan_tree(rules, args.quiet)
    print(f'scrub-guard: {hits} match(es) of {len(rules)} rule(s)', file=sys.stderr)
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main())
