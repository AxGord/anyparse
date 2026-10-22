package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Pool;
import devkit.Result;
import haxe.Exception;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev clone-census <label> <t2-report> <t1-report> <repo-root> [--cache DIR] [--after <t2> <t1>] [--removed FILE]` —
 * the census of the two duplicate-code rules' lint output: findings, families, occurrences, purely-renamed families,
 * the cross-file share and the bare-run share.
 *
 * `<t2-report>` / `<t1-report>` are `hxq lint --rule duplicate-code-renamed` and `--rule duplicate-code` output, `--flat`
 * text or `--format json`, taken with the CWD at `<repo-root>` so the paths resolve. Each finding's statement run is
 * resolved through `hxq ast <file> --json`, so a run's region and each statement's text are exact; `--cache DIR` keeps
 * those outputs across runs, keyed by label and path (a directory reused on another tree resolves against stale spans).
 *
 * The bare-run share is a TEXT-REGEX reading independent of the engine: a run whose every statement is
 * `var|final name[:T] [= name|literal]` or `name[.name] = name|literal`. The engine's own predicate is structural
 * (`DuplicateCode.isBareStmt`), and the two are meant to disagree at the edges; the regex is the cross-check, not the
 * definition. With `--after`, the removed families are listed by name (`--removed FILE`) and the agreement matrix
 * between the two readings is printed. Both reports of an `--after` pair resolve against the one `<repo-root>`.
 */
@:nullSafety(Strict)
final class CloneCensus {

	public static inline final USAGE: String = 'usage: dev clone-census <label> <t2-report> <t1-report> <repo-root>'
		+ ' [--cache DIR] [--after <t2-report> <t1-report>] [--removed FILE]';

	/** The groups of a finding's message: its statement count, its partner's file (absent: the same file) and line. */
	private static inline final COUNT_GROUP: Int = 1;

	private static inline final PARTNER_GROUP: Int = 2;
	private static inline final PARTNER_LINE_GROUP: Int = 3;

	/** Every character Python's `str.isspace` answers true for. */
	private static inline final PY_WHITESPACE: String = '\t\n\x0B\x0C\r\x1C\x1D\x1E\x1F \u0085                 　';

	/** Whether a run kind is one of the bare ones (`bare-decl`, `bare-assign`, `bare-mixed`). */
	public static inline function isBare(kind: String): Bool {
		return kind.startsWith('bare');
	}

	/** Run the subcommand over `argv`; answers the exit status. */
	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final cache: Null<String> = args.option('--cache');
		final after: Null<Array<String>> = args.values('--after', 2);
		final removed: Null<String> = args.option('--removed');
		final given: Array<String> = args.positionals(['<label>', '<t2-report>', '<t1-report>', '<repo-root>']);
		final label: String = given[0];
		final runs: Runs = new Runs(label, given[3], cache);
		final base: Array<Array<Finding>> = [parseReport(given[1]), parseReport(given[2])];
		final later: Null<Array<Array<Finding>>> = after == null ? null : [parseReport(after[0]), parseReport(after[1])];
		final all: Array<Finding> = base[0].concat(base[1]).concat(later == null ? [] : later[0].concat(later[1]));
		runs.prefetch([for (f in all) f.file]);
		var lines: Array<String> = census(label, base[0], base[1], runs);
		if (later != null) {
			lines = lines.concat(census('$label after', later[0], later[1], runs));
			lines = lines.concat(compare(label, base, later, runs, removed));
		}
		if (lines.length > 0) Sys.println(lines.join('\n'));
		return 0;
	}

	/** The findings of a `--flat` text or a `--format json` lint report at `path`. */
	public static function parseReport(path: String): Array<Finding> {
		final text: String = Runs.universalNewlines(File.getContent(path));
		final out: Array<Finding> = [];
		final message: EReg = ~/^(\d+) statements duplicated from (?:(\S+?):)?(?:line )?(\d+)/;
		if (pyStrip(text, true, false).startsWith('[')) {
			final records: Array<ReportRecord> = Json.parse(text);
			for (rec in records) if (message.match(rec.message)) out.push(finding(rec.file, rec.line, rec.col, message));
			return out;
		}
		// a text line is `<file>:<line>:<col>: [info] ` and the message: no file holds a space, so the head ends at the first one
		final head: EReg = ~/^(\S+?:\d+:\d+): \[info\] (.*)/;
		for (l in text.split('\n')) if (head.match(l) && message.match(head.matched(2))) {
			final position: Array<String> = head.matched(1).split(':');
			final col: Int = number(position.pop() ?? '');
			final line: Int = number(position.pop() ?? '');
			out.push(finding(position.join(':'), line, col, message));
		}
		return out;
	}

	/**
	 * The census lines of one report pair: the counts of each rule, how far the type-1 families sit inside the type-2
	 * ones, and each rule's findings by the regex reading of their runs.
	 */
	public static function census(label: String, t2: Array<Finding>, t1: Array<Finding>, runs: Runs): Array<String> {
		final out: Array<String> = [];
		final families: Grouped = group(t2);
		final endpoints: Array<String> = [];
		for (f in t1) {
			endpoints.push(at(f.file, f.line));
			endpoints.push(familyOf(f));
		}
		final purelyRenamed: Finding -> Bool = f -> !endpoints.contains(at(f.file, f.line)) && !endpoints.contains(familyOf(f));
		final pure: Int = t2.filter(purelyRenamed).length;
		final pureFamilies: Int = families.keys.filter(key -> only(families.members[key]).foreach(purelyRenamed)).length;
		final cross: Int = t2.filter(f -> f.cross).length;
		final t1Families: Grouped = group(t1);
		final t1FamilyCount: Int = t1Families.keys.length;
		out.push(
			'[$label] type-2 findings=${t2.length} families=${families.keys.length} occurrences=${t2.length + families.keys.length} '
			+ 'purely-renamed findings=$pure purely-renamed families=$pureFamilies cross-file=$cross same-file=${t2.length - cross}'
		);
		out.push(
			'[$label] type-1 findings=${t1.length} families=$t1FamilyCount occurrences=${t1.length + t1FamilyCount} '
			+ 'cross-file=${t1.filter(f -> f.cross).length}'
		);
		final contained: Int = t1Families.keys.filter(k -> families.members.exists(k)).length;
		out.push('[$label] containment: type-1 families whose anchor is also a type-2 anchor=$contained of $t1FamilyCount');
		for (rule in [{ name: 'type-2', findings: t2 }, { name: 'type-1', findings: t1 }]) {
			final kinds: Map<String, Int> = [];
			final familyKinds: Map<String, Array<String>> = [];
			final order: Array<String> = [];
			for (f in rule.findings) {
				final kind: String = runs.classify(f);
				kinds[kind] = (kinds[kind] ?? 0) + 1;
				final key: String = familyOf(f);
				final seen: Null<Array<String>> = familyKinds[key];
				if (seen == null) {
					familyKinds[key] = [kind];
					order.push(key);
				} else if (!seen.contains(kind)) {
					seen.push(kind);
				}
			}
			var bareFindings: Int = 0;
			for (kind => count in kinds) if (isBare(kind)) bareFindings += count;
			final bareFamilies: Int = order.filter(k -> {
				final ks: Array<String> = familyKinds[k] ?? [];
				ks.length == 1 && isBare(ks[0]);
			}).length;
			out.push(
				'[$label] ${rule.name} findings by run kind (regex): ${pyDict(kinds)} '
				+ 'bare share=$bareFindings/${rule.findings.length} findings, $bareFamilies/${order.length} families'
			);
		}
		return out;
	}

	/**
	 * The lines comparing a `base` report pair with a `later` one: per rule the removed, added and kept findings and how
	 * the regex reading agrees with the removal, each added finding, and — appended to the file `removedPath` — each
	 * removed family.
	 */
	public static function compare(
		label: String, base: Array<Array<Finding>>, later: Array<Array<Finding>>, runs: Runs, removedPath: Null<String>
	): Array<String> {
		final out: Array<String> = [];
		for (k => rule in ['type-2', 'type-1']) {
			final before: Keyed = keyed(base[k]);
			final now: Keyed = keyed(later[k]);
			final removed: Array<Finding> = [for (key in before.keys) if (!now.byKey.exists(key)) only(before.byKey[key])];
			final added: Array<Finding> = [for (key in now.keys) if (!before.byKey.exists(key)) only(now.byKey[key])];
			final kept: Array<Finding> = [for (key in now.keys) if (before.byKey.exists(key)) only(now.byKey[key])];
			final bare: Finding -> Bool = f -> runs.classify(f).startsWith('bare');
			final removedBare: Int = removed.filter(bare).length;
			final keptBare: Int = kept.filter(bare).length;
			final removedFamilies: Array<Finding> = [];
			for (f in removed) if (!removedFamilies.exists(r -> familyOf(r) == familyOf(f))) removedFamilies.push(f);
			removedFamilies.sort((a, b) -> if (a.origFile == b.origFile)
				a.origLine - b.origLine
			else if (a.origFile < b.origFile)
				-1
			else
				1);
			out.push(
				'[$label] $rule removed=${removed.length} findings / ${removedFamilies.length} families, added=${added.length}, '
				+ 'kept=${kept.length}; regex agrees: removed&bare=$removedBare removed&logic=${removed.length - removedBare} '
				+ 'kept&bare=$keptBare kept&logic=${kept.length - keptBare}'
			);
			for (f in added) out.push('[$label] $rule ADDED ${f.file}:${f.line} n=${f.n} from ${f.origFile}:${f.origLine}');
			if (removedPath == null) continue;
			final rows: Array<String> = [
				for (fam in removedFamilies) {
					final members: Array<Finding> = removed.filter(f -> familyOf(f) == familyOf(fam));
					final reading: String = bare(members[0]) ? 'regex-bare' : 'regex-logic';
					'$label $rule ${fam.origFile}:${fam.origLine} x${members.length} n=${members[0].n} $reading\n';
				}
			];
			// `sys.io.File.append` on node writes at the offset it counts itself, not at the end: a second append overwrites
			js.node.Fs.appendFileSync(removedPath, rows.join(''));
		}
		return out;
	}

	/** Python's `str.strip` (or its `lstrip` / `rstrip` half): the whitespace `str.isspace` names, not only ASCII. */
	public static function pyStrip(s: String, left: Bool = true, right: Bool = true): String {
		var from: Int = 0;
		var to: Int = s.length;
		if (left) while (from < to && pySpace(s.charCodeAt(from))) from++;
		if (right) while (to > from && pySpace(s.charCodeAt(to - 1))) to--;
		return s.substring(from, to);
	}

	/** The family a finding belongs to: the anchor its copy duplicates. */
	private static inline function familyOf(f: Finding): String {
		return at(f.origFile, f.origLine);
	}

	private static inline function at(file: String, line: Int): String {
		return '$file\n$line';
	}

	/** `value`, which a key taken from the same map guarantees is there. */
	private static function only<T>(value: Null<T>): T {
		if (value == null) throw new Exception('clone-census: a key lost its entry');
		return value;
	}

	/** The finding a report line or record names, `re`'s groups from `first` on being its count, partner file and line. */
	private static function finding(file: String, line: Int, col: Int, message: EReg): Finding {
		final partner: Null<String> = (message.matched(PARTNER_GROUP): Null<String>);
		return {
			file: file,
			line: line,
			col: col,
			n: number(message.matched(COUNT_GROUP)),
			origFile: partner ?? file,
			origLine: number(message.matched(PARTNER_LINE_GROUP)),
			cross: partner != null
		};
	}

	private static function number(text: String): Int {
		final value: Null<Int> = Std.parseInt(text);
		if (value == null) throw new Exception('clone-census: "$text" is not a number');
		return value;
	}

	/** The findings of `findings` by family, families in first-seen order. */
	private static function group(findings: Array<Finding>): Grouped {
		final grouped: Grouped = { keys: [], members: [] };
		for (f in findings) {
			final key: String = familyOf(f);
			final members: Null<Array<Finding>> = grouped.members[key];
			if (members == null) {
				grouped.keys.push(key);
				grouped.members[key] = [f];
			} else {
				members.push(f);
			}
		}
		return grouped;
	}

	/** `findings` by their whole identity, keys in first-seen order, each key answering its LAST finding. */
	private static function keyed(findings: Array<Finding>): Keyed {
		final out: Keyed = { keys: [], byKey: [] };
		for (f in findings) {
			final key: String = [f.file, '${f.line}', '${f.n}', f.origFile, '${f.origLine}'].join('\n');
			if (!out.byKey.exists(key)) out.keys.push(key);
			out.byKey[key] = f;
		}
		return out;
	}

	/** `counts` as Python prints a dict built from its items sorted by key. */
	private static function pyDict(counts: Map<String, Int>): String {
		final keys: Array<String> = [for (k in counts.keys()) k];
		keys.sort(Reflect.compare);
		return '{' + [for (k in keys) '\'$k\': ${counts[k]}'].join(', ') + '}';
	}

	/** Whether the character `code` is whitespace to Python's `str.isspace`. */
	private static function pySpace(code: Null<Int>): Bool {
		return code != null && PY_WHITESPACE.indexOf(String.fromCharCode(code)) >= 0;
	}

}

/**
 * The statement runs of the findings, resolved through the AST of ONE tree (`root`) — both reports of an `--after` pair
 * are resolved against it. Everything it reads is kept for the length of this run only.
 */
@:nullSafety(Strict)
final class Runs {

	/** How many `hxq ast` processes run at once: the knee of the project's process fan-out. */
	private static inline final AST_PARALLEL: Int = 4;

	private final _trees: Map<String, AstFile> = [];
	private final _index: Map<String, Map<String, Array<Candidate>>> = [];
	private final _lines: Map<String, Array<String>> = [];
	private final _bareDecl: EReg = ~/^(var|final)\s+[A-Za-z_]\w*\s*(:\s*[^=]+?)?\s*(=\s*(-?[A-Za-z_][\w.]*|-?\d[\w.]*|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\[\]|\{\}))?\s*;?\s*$/s;
	private final _bareAssign: EReg = ~/^[A-Za-z_][\w.]*\s*=\s*(-?[A-Za-z_][\w.]*|-?\d[\w.]*|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\[\]|\{\})\s*;?\s*$/s;
	private final _label: String;
	private final _root: String;
	private final _cache: Null<String>;

	public function new(label: String, root: String, cache: Null<String>) {
		_label = label;
		_root = root;
		_cache = cache;
		if (cache != null) FileSystem.createDirectory(cache);
	}

	/**
	 * Read the AST of every file of `files` not read yet, in parallel. The first one runs alone, so a stale `hxq` engine
	 * is rebuilt once rather than by several processes at the same time.
	 */
	public function prefetch(files: Array<String>): Void {
		final missing: Array<String> = [];
		for (file in files) if (!_trees.exists(file) && !missing.contains(file)) {
			final cached: Null<String> = cachePath(file);
			if (cached != null && FileSystem.exists(cached))
				_trees[file] = Json.parse(File.getContent(cached));
			else
				missing.push(file);
		}
		if (missing.length == 0) return;
		store(missing[0], astCommand(missing[0]).run());
		final rest: Array<String> = missing.slice(1);
		for (i => result in Pool.of(AST_PARALLEL).map(rest, astCommand)) store(rest[i], result);
	}

	/** The kind of `f`'s statement run by the regex reading: `bare-decl`, `bare-assign`, `bare-mixed`, `logic` or `unresolved`. */
	public function classify(f: Finding): String {
		final statements: Null<Array<AstNode>> = runOf(f);
		if (statements == null) return 'unresolved';
		final texts: Array<String> = [for (s in statements) CloneCensus.pyStrip(text(f.file, s.span))];
		if (texts.foreach(t -> _bareDecl.match(t))) return 'bare-decl';
		if (texts.foreach(t -> _bareAssign.match(t))) return 'bare-assign';
		if (texts.foreach(t -> _bareDecl.match(t) || _bareAssign.match(t))) return 'bare-mixed';
		return 'logic';
	}

	/** The `n` statement nodes of finding `f`, or null when its position resolves to no run. */
	private function runOf(f: Finding): Null<Array<AstNode>> {
		final candidates: Null<Array<Candidate>> = nodesAt(f.file)['${f.line}:${f.col}'];
		if (candidates == null) return null;
		for (c in candidates) if (c.index + f.n <= c.siblings.length) return c.siblings.slice(c.index, c.index + f.n);
		return null;
	}

	/** Every node of `file` by its start `line:col`, outermost first. */
	private function nodesAt(file: String): Map<String, Array<Candidate>> {
		final known: Null<Map<String, Array<Candidate>>> = _index[file];
		if (known != null) return known;
		final by: Map<String, Array<Candidate>> = [];
		function walk(node: AstNode): Void {
			final kids: Array<AstNode> = node.children ?? [];
			for (i => child in kids) {
				final span: Null<AstSpan> = child.span;
				if (span != null) {
					final key: String = '${span.start[0]}:${span.start[1]}';
					final list: Array<Candidate> = by[key] ?? [];
					list.push({ siblings: kids, index: i });
					by[key] = list;
				}
				walk(child);
			}
		}
		walk(tree(file).tree);
		_index[file] = by;
		return by;
	}

	/** The source text `span` covers in `file`, its columns 1-based and its end exclusive; none for no span. */
	private function text(file: String, span: Null<AstSpan>): String {
		if (span == null) return '';
		final ls: Array<String> = sourceLines(file);
		final l1: Int = span.start[0];
		final c1: Int = span.start[1];
		final l2: Int = span.end[0];
		final c2: Int = span.end[1];
		return l1 == l2
			? slice(ls[l1 - 1], c1 - 1, c2 - 1)
			: [slice(ls[l1 - 1], c1 - 1, ls[l1 - 1].length)].concat(ls.slice(l1, l2 - 1)).concat([slice(ls[l2 - 1], 0, c2 - 1)]).join('\n');
	}

	private function sourceLines(file: String): Array<String> {
		final known: Null<Array<String>> = _lines[file];
		if (known != null) return known;
		final lines: Array<String> = universalNewlines(File.getContent(Path.join([_root, file]))).split('\n');
		_lines[file] = lines;
		return lines;
	}

	private function tree(file: String): AstFile {
		if (!_trees.exists(file)) prefetch([file]);
		final known: Null<AstFile> = _trees[file];
		if (known == null) throw new Exception('clone-census: no AST of $file');
		return known;
	}

	private function astCommand(file: String): Command {
		return cmd('hxq ast $file --json').at(_root);
	}

	/** Keep the `hxq ast --json` output `result` of `file`, and cache it when a cache is kept. */
	private function store(file: String, result: Result): Void {
		final parsed: Null<AstFile> = try Json.parse(result.out) catch (exception: Exception) null;
		if (parsed == null)
			throw new Exception(
				'clone-census: `${result.command}` printed no AST (${result.failure != '' ? result.failure : result.err.trim()})'
			);
		_trees[file] = parsed;
		final cached: Null<String> = cachePath(file);
		if (cached != null) File.saveContent(cached, result.out);
	}

	private function cachePath(file: String): Null<String> {
		final cache: Null<String> = _cache;
		return cache == null ? null : Path.join([cache, '${_label}__${file.split('/').join('__')}.json']);
	}

	/** `text` with every `\r\n` and lone `\r` read as `\n`, as Python's text mode reads a file. */
	public static function universalNewlines(text: String): String {
		return text.replace('\r\n', '\n').replace('\r', '\n');
	}

	/** Python's slice `s[from:to]`: both ends clamped, empty when they cross. */
	private static function slice(s: String, from: Int, to: Int): String {
		final a: Int = Std.int(Math.max(0, Math.min(from, s.length)));
		final b: Int = Std.int(Math.max(0, Math.min(to, s.length)));
		return b <= a ? '' : s.substring(a, b);
	}

}

/** One duplicate-code finding: its copy at `file:line:col`, `n` statements long, of the anchor `origFile:origLine`. */
typedef Finding = {
	var file: String;
	var line: Int;
	var col: Int;
	var n: Int;
	var origFile: String;
	var origLine: Int;
	var cross: Bool;
}

/** Findings by family, families in first-seen order. */
typedef Grouped = {
	var keys: Array<String>;
	var members: Map<String, Array<Finding>>;
}

/** Findings by whole identity, keys in first-seen order. */
typedef Keyed = {
	var keys: Array<String>;
	var byKey: Map<String, Finding>;
}

/** A node starting at some position: its siblings and its index among them. */
typedef Candidate = {
	var siblings: Array<AstNode>;
	var index: Int;
}

/** What `hxq ast --json` prints of one file. */
typedef AstFile = {
	var tree: AstNode;
}

/** One node of an `hxq ast --json` tree, as far as a census reads it. */
typedef AstNode = {
	var ?children: Array<AstNode>;
	var ?span: AstSpan;
}

/** A node's extent: `start` and `end`, each `[line, column]`, 1-based. */
typedef AstSpan = {
	var start: Array<Int>;
	var end: Array<Int>;
}

/** One record of a `--format json` lint report, as far as a census reads it. */
typedef ReportRecord = {
	var file: String;
	var line: Int;
	var col: Int;
	var message: String;
}
