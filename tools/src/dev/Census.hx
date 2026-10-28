package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev census [--write | --order-only] [--bin <test.js>] [--repo <tree>]` — the census lists of `unit.census` against the
 * generated registries `bin/test.js` prints (`--list-*`). The lists stay a SECOND declaration, so a name that vanished
 * from a registry fails a parity test by name; this tool only takes the typing out of keeping them. Without a mode it
 * reports and exits 1 on any difference; `--write` rewrites every list to its registry and prints each name it added or
 * removed, so a removal is a line its author reads; `--order-only` rewrites only lists whose names already agree as a
 * set — what a union merge leaves out of order — and refuses, writing nothing, otherwise.
 */
@:nullSafety(Strict)
final class Census {

	public static inline final USAGE: String = 'usage: dev census [--write | --order-only] [--bin <test.js>] [--repo <tree>]';

	/** Every census list, each with its parts in the order they concatenate. */
	public static final LISTS: Array<CensusList> = [
		{
			name: 'classes',
			listing: '--list-classes',
			constant: 'REGISTERED_CLASSES',
			parts: ['test/unit/census/RegisteredClasses.hx'],
			sorted: true,
			nameOnly: false
		},
		{
			name: 'pins',
			listing: '--list-pins',
			constant: 'PINS',
			parts: [
				'test/unit/census/PinsCheckAToO.hx',
				'test/unit/census/PinsCheckPToZ.hx',
				'test/unit/census/PinsGrammarAndCli.hx',
				'test/unit/census/PinsQueryAndRuntime.hx'
			],
			sorted: false,
			nameOnly: false
		},
		{
			name: 'arms',
			listing: '--list-arms',
			constant: 'ARMS',
			parts: [
				'test/unit/census/DeclaredArms1.hx',
				'test/unit/census/DeclaredArms2.hx',
				'test/unit/census/DeclaredArms3.hx'
			],
			sorted: false,
			nameOnly: true
		},
		{
			name: 'deferred arms',
			listing: '--list-deferred',
			constant: 'ARMS',
			parts: ['test/unit/census/DeferredArms.hx'],
			sorted: false,
			nameOnly: false
		}
	];

	/** The column a census line may not pass (`hxformat.json` `wrapping.maxLineLength`). */
	private static inline final MAX_WIDTH: Int = 140;

	/** The columns a tab takes (`hxformat.json` `indentation.tabWidth`). */
	private static inline final TAB_WIDTH: Int = 4;

	/** How many names one report line spells before it elides the rest. */
	private static inline final NAMES_SHOWN: Int = 8;

	/** The separator a pin or an arm line puts between its fields, and where a long entry is wrapped. */
	private static inline final FIELD_SEPARATOR: String = ' :: ';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final write: Bool = args.flag('--write');
		final orderOnly: Bool = args.flag('--order-only');
		final repo: String = Repo.resolve(args.option('--repo'));
		final bin: String = args.option('--bin') ?? Path.join([repo, 'bin/test.js']);
		args.done();
		if (write && orderOnly) throw new UsageError('pass --write or --order-only, not both');
		final mode: CensusMode = if (write)
			Write
		else if (orderOnly)
			OrderOnly
		else
			Check;
		return run(repo, bin, mode, Sys.println).ok ? 0 : 1;
	}

	/**
	 * Compare every list of the tree `repo` with the registry the runner `testJs` prints, report each through `print`, and
	 * rewrite what `mode` allows. `ok` is whether the tree's lists now agree with the registries.
	 */
	public static function run(repo: String, testJs: String, mode: CensusMode, print: String -> Void): CensusRun {
		final readings: Array<{
			list: CensusList,
			texts: Array<String>,
			delta: ListDelta,
			registry: Array<String>
		}> = [
			for (list in LISTS) {
				final registry: Array<String> = registryOf(list, repo, testJs);
				final texts: Array<String> = [for (part in list.parts) File.getContent(Path.join([repo, part]))];
				final declared: Array<String> = [
					for (i => text in texts) for (entry in entriesOrThrow(text, list.constant, list.parts[i])) entry.value
				];
				{
					list: list,
					texts: texts,
					delta: delta(declared, registry),
					registry: registry
				};
			}
		];
		final setMoved: Bool = readings.exists(r -> r.delta.added.length + r.delta.removed.length > 0);
		final writes: Bool = mode == Write || mode == OrderOnly && !setMoved;
		final written: Array<String> = [];
		for (reading in readings) {
			print('${reading.list.name}: ${describe(reading.delta, reading.registry.length)}');
			// rewritten even when in sync: a part whose last line lacks its comma gains it, so a union merge can append
			if (!writes) continue;
			final parts: Array<Array<CensusEntry>> = [
				for (i => text in reading.texts) entriesOrThrow(text, reading.list.constant, reading.list.parts[i])
			];
			final placed: Array<Array<CensusEntry>> = assign(parts, reading.registry);
			for (i => part in reading.list.parts) {
				final rewritten: String = rewrite(reading.texts[i], reading.list.constant, placed[i]);
				if (rewritten == reading.texts[i]) continue;
				File.saveContent(Path.join([repo, part]), rewritten);
				written.push(part);
			}
		}
		if (mode == OrderOnly && setMoved) print('census: the names differ as a set, so nothing was rewritten — a merge lost or added one');
		return { ok: writes || !readings.exists(r -> !inSync(r.delta)), written: written };
	}

	/** The registry `list` mirrors, as the runner `testJs` of the tree `repo` prints it. */
	public static function registryOf(list: CensusList, repo: String, testJs: String): Array<String> {
		final lines: Array<String> = cmd('node $testJs ${list.listing}').at(repo).lines();
		final names: Array<String> = list.nameOnly ? [for (line in lines) line.split(FIELD_SEPARATOR)[0]] : lines;
		if (list.sorted) names.sort(Reflect.compare);
		return names;
	}

	/** How `declared` differs from `registry`: the names only one of them holds, and whether the order is all that differs. */
	public static function delta(declared: Array<String>, registry: Array<String>): ListDelta {
		final left: Array<String> = declared.copy();
		final added: Array<String> = [for (name in registry) if (!left.remove(name)) name];
		return { added: added, removed: left, same: declared.join('\n') == registry.join('\n') };
	}

	/**
	 * The entries of `parts` placed into the registry's order: a declared entry stays in its part (its source text kept),
	 * a new one joins the part its registry predecessor sits in, and a part never takes an entry the order puts before a
	 * later part's — so the parts concatenate to the registry exactly.
	 */
	public static function assign(parts: Array<Array<CensusEntry>>, registry: Array<String>): Array<Array<CensusEntry>> {
		final placed: Array<Array<CensusEntry>> = [for (_ in parts) []];
		final pool: Array<{ part: Int, entry: CensusEntry }> = [for (i => part in parts) for (entry in part) { part: i, entry: entry }];
		var current: Int = 0;
		for (name in registry) {
			final found: Null<{ part: Int, entry: CensusEntry }> = pool.find(p -> p.entry.value == name);
			if (found == null) {
				placed[current].push({ value: name, lines: render(name) });
				continue;
			}
			pool.remove(found);
			if (found.part > current) current = found.part;
			placed[current].push(found.entry);
		}
		return placed;
	}

	/** The entries of the array literal `constant` in `text`, or null when `text` declares no such literal. */
	public static function entries(text: String, constant: String): Null<Array<CensusEntry>> {
		final lines: Array<String> = text.split('\n');
		final open: Int = openLine(lines, constant);
		if (open < 0) return null;
		final found: Array<CensusEntry> = [];
		for (i in open + 1...lines.length) {
			final line: String = lines[i];
			if (line == '\t];') return found;
			final item: String = line.trim();
			if (item == '') continue;
			final where: String = 'line ${i + 1}';
			if (item.startsWith('+ ') && found.length > 0) {
				final last: CensusEntry = found[found.length - 1];
				found[found.length - 1] = { value: last.value + literal(item.substr(2), where), lines: last.lines.concat([line]) };
			} else {
				found.push({ value: literal(item, where), lines: [line] });
			}
		}
		throw new Exception('the `$constant` literal has no closing `\t];` line');
	}

	/** `text` with the body of the array literal `constant` replaced by `items`, each line ending in a comma. */
	public static function rewrite(text: String, constant: String, items: Array<CensusEntry>): String {
		final lines: Array<String> = text.split('\n');
		final open: Int = openLine(lines, constant);
		final close: Int = lines.indexOf('\t];', open);
		if (open < 0 || close < 0) throw new Exception('no `$constant` literal to rewrite');
		final body: Array<String> = [
			for (item in items) for (i => line in item.lines) i == item.lines.length - 1 && !line.endsWith(',') ? '$line,' : line
		];
		return lines.slice(0, open + 1).concat(body).concat(lines.slice(close)).join('\n');
	}

	/**
	 * The lines of a new entry `value`: one literal, or — when that line would pass the width limit — the literal cut
	 * after its last field separator that fits, the rest on a `+` continuation line, the way the writer leaves a long one.
	 */
	public static function render(value: String): Array<String> {
		final whole: String = '\t\t${quote(value)},';
		if (width(whole) <= MAX_WIDTH) return [whole];
		var cut: Int = value.lastIndexOf(FIELD_SEPARATOR);
		while (cut > 0 && width('\t\t${quote(value.substr(0, cut + FIELD_SEPARATOR.length))}') > MAX_WIDTH)
			cut = value.lastIndexOf(FIELD_SEPARATOR, cut - 1);
		if (cut <= 0) return [whole];
		final head: Int = cut + FIELD_SEPARATOR.length;
		return ['\t\t${quote(value.substr(0, head))}', '\t\t\t+ ${quote(value.substr(head))},'];
	}

	/** Whether `delta` is no difference at all. */
	private static inline function inSync(delta: ListDelta): Bool {
		return delta.same;
	}

	/** One report clause for `delta` over a registry of `count` names. */
	private static function describe(delta: ListDelta, count: Int): String {
		if (inSync(delta)) return 'in sync ($count)';
		if (delta.added.length + delta.removed.length == 0) return 'order differs ($count)';
		final names: Array<String> = [for (name in delta.added) '+$name'].concat([for (name in delta.removed) '-$name']);
		final shown: String = names.slice(0, NAMES_SHOWN).join(', ') + (names.length > NAMES_SHOWN ? ', …' : '');
		return '+${delta.added.length} -${delta.removed.length}: $shown';
	}

	/** `entries`, refusing a part that declares no literal `constant`. */
	private static function entriesOrThrow(text: String, constant: String, part: String): Array<CensusEntry> {
		final found: Null<Array<CensusEntry>> =
			try entries(text, constant) catch (exception: Exception) throw new Exception('$part: ${exception.message}');
		if (found == null) throw new Exception('$part declares no `$constant` array literal');
		return found;
	}

	/** The index of the line opening the array literal `constant` (`static final <constant>: … = [`), or -1. */
	private static function openLine(lines: Array<String>, constant: String): Int {
		final open: EReg = new EReg('^\\t(?:public |private )?static final $constant\\b[^=]*= \\[$', '');
		for (i => line in lines) if (open.match(line)) return i;
		return -1;
	}

	/** The value of one single-quoted literal `item` (its trailing comma allowed); anything else is refused. */
	private static function literal(item: String, where: String): String {
		final quoted: String = item.endsWith(',') ? item.substr(0, item.length - 1) : item;
		if (quoted.length < 2 || !quoted.startsWith('\'') || !quoted.endsWith('\''))
			throw new Exception('$where: a census line holds one single-quoted literal, not `$item`');
		final body: String = quoted.substr(1, quoted.length - 2);
		final value: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < body.length) {
			final c: String = body.charAt(i);
			final next: String = body.charAt(i + 1);
			if (c == '\\' && (next == '\\' || next == '\'') || c == '$' && next == '$') {
				value.add(next);
				i += 2;
			} else if (c == '\\' || c == '$' || c == '\'') {
				throw new Exception('$where: a census literal escapes only `\\\\`, `\\\'` and `$$$$`: `$item`');
			} else {
				value.add(c);
				i++;
			}
		}
		return value.toString();
	}

	/** `value` as a single-quoted Haxe literal. */
	private static function quote(value: String): String {
		return '\'' + value.replace('\\', '\\\\').replace('\'', '\\\'').replace('$', '$$') + '\'';
	}

	/** The columns `line` takes, a tab counting `TAB_WIDTH`. */
	private static function width(line: String): Int {
		return line.length + (line.split('\t').length - 1) * (TAB_WIDTH - 1);
	}

}

/** One census list: the registry it mirrors and the parts that declare it. */
typedef CensusList = {
	var name: String;

	/** The `bin/test.js` flag that prints the registry. */
	var listing: String;

	/** The array literal each part declares. */
	var constant: String;

	var parts: Array<String>;

	/** Whether the registry is compared sorted (it prints in another order). */
	var sorted: Bool;

	/** Whether the census keeps only the first field of a registry line. */
	var nameOnly: Bool;
}

/** One entry of a census literal: its value and the source lines that spell it. */
typedef CensusEntry = {
	var value: String;
	var lines: Array<String>;
}

/** How a census list differs from its registry. */
typedef ListDelta = {
	var added: Array<String>;
	var removed: Array<String>;

	/** Whether the two are the same names in the same order. */
	var same: Bool;
}

/** What `Census.run` did. */
typedef CensusRun = {
	var ok: Bool;

	/** The parts it rewrote, relative to the tree. */
	var written: Array<String>;
}

/** What `Census.run` may rewrite. */
enum CensusMode {
	Check;
	Write;
	OrderOnly;
}
