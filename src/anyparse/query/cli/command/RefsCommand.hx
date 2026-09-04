package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Parsed options for `apq refs` — `lang`, `json`, the read / write / decl selection (`wantDecls` / `wantReads` / `wantWrites`), output toggles, `flat`, `limit`, the symbol `name`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef RefsOpts = {
	var lang: String;
	var json: Bool;
	var wantDecls: Bool;
	var wantReads: Bool;
	var wantWrites: Bool;
	var wantDoc: Bool;
	var wantSource: Bool;
	var flat: Bool;
	var limit: Int;
	var name: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq refs` — symbol references (value bindings; scope-aware).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class RefsCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'refs';
	}

	public function summary(): String {
		return 'Symbol references (value bindings; scope-aware)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRefs(args, ctx);
	}

	public function usage(): Void {
		printRefsUsage();
	}

	private static inline function kindAllowed(k: RefKind, decls: Bool, reads: Bool, writes: Bool): Bool {
		return switch k {
			case Decl: decls;
			case Read: reads;
			case Write: writes;
		}
	}

	private static inline function refsParseExit(code: Int): RefsOpts {
		return {
			lang: '',
			json: false,
			wantDecls: false,
			wantReads: false,
			wantWrites: false,
			wantDoc: false,
			wantSource: false,
			flat: false,
			limit: -1,
			name: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function runRefs(args: Array<String>, ctx: CliContext): Int {
		final o: RefsOpts = parseRefsArgs(args);
		if (o.errExit != null) return o.errExit;
		final name: Null<String> = o.name;
		if (name == null) {
			CliIo.stderr('apq refs: missing <name> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq refs: missing <file-or-dir-or-glob> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		final nameStr: String = name;
		// No flag = no filter (emit every hit). Any flag flips on the
		// allow-set; sister CLIs (`git log --author --grep`) follow the
		// same any-flag-narrows convention.
		final anyFilter: Bool = o.wantDecls || o.wantReads || o.wantWrites;

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final shape: RefShape = plugin.refShape();

		final expanded: ExpandedInputs = CliArgs.expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq refs: no input files matched ${CliArgs.quotedSpecs(o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}

		final skipEntries: Array<SkipEntry> = [];
		final candidateNames: Map<String, Bool> = [];
		final collected: Null<{
			entries: Array<{ file: String, source: String, hits: Array<RefHit> }>,
			memberAccesses: Int,
			bindings: Int
		}> = collectRefsEntries(nameStr, paths, plugin, shape, expanded.singleFile, skipEntries, candidateNames, {
			anyFilter: anyFilter,
			wantDecls: o.wantDecls,
			wantReads: o.wantReads,
			wantWrites: o.wantWrites
		});
		if (collected == null) return EXIT_RUNTIME;
		final allEntries: Array<{ file: String, source: String, hits: Array<RefHit> }> = collected.entries;

		if (allEntries.length == 0)
			CliIo.stderr('${CliWalk.emptyWalkerNudge('refs', nameStr, paths.length, paths.length - skipEntries.length, skipEntries, candidateNames)}\n');
		if (collected.memberAccesses > 0)
			CliIo.stderr('${CliWalk.memberAccessNudge('refs', nameStr, collected.memberAccesses, collected.bindings)}\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('refs', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<RefHit> }> = CliWalk.limitEntries(
			allEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) }
		);
		if (o.json) {
			CliIo.sysPrint(Json.renderRefs(shown, o.wantDoc, o.wantSource, plugin.lexicalRegions));
		} else {
			for (entry in shown)
				CliIo.sysPrint(Text.renderRefs(
					entry.file, entry.source, entry.hits, o.wantDoc, o.wantSource, plugin.lexicalRegions(entry.source), o.flat
				));
		}
		return ctx.emptyExit(allEntries.length == 0);
	}

	private static function printRefsUsage(): Void {
		CliIo.sysPrint('Usage: apq refs [options] <name> <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --json              Emit JSON instead of text\n');
		CliIo.sysPrint('  --decls             Filter to declarations\n');
		CliIo.sysPrint('  --reads             Filter to read references\n');
		CliIo.sysPrint('  --writes            Filter to write references (Phase 3.3)\n');
		CliUsage.printDocSourceFlatLimitLangHelp();
		CliIo.sysPrint('Phase 3.1: name-only matching, no lexical scope. Filters combine\n');
		CliIo.sysPrint('inclusively — passing `--decls --reads` keeps both kinds.\n');
	}

	/**
	 * Collect every named leaf/inner-node into `out` for fuzzy
	 * "did you mean" suggestions. The full vocabulary covered by the
	 * walked tree — wider than just decls — keeps the suggestion list
	 * useful for either refs (value bindings) or uses (type positions)
	 * without needing a per-shape collector.
	 */
	public static function collectNames(root: QueryNode, out: Map<String, Bool>): Void {
		function walk(n: QueryNode): Void {
			final nm: Null<String> = n.name;
			if (nm != null && nm.length > 0) out[nm] = true;
			for (c in n.children) walk(c);
		}
		walk(root);
	}

	private static function parseRefsArgs(args: Array<String>): RefsOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var wantDecls: Bool = false;
		var wantReads: Bool = false;
		var wantWrites: Bool = false;
		var wantDoc: Bool = false;
		var wantSource: Bool = false;
		var flat: Bool = false;
		var limit: Int = -1;
		var name: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--decls':
					wantDecls = true;
				case '--reads':
					wantReads = true;
				case '--writes':
					wantWrites = true;
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--flat':
					flat = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return refsParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printRefsUsage();
					return refsParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq refs: unknown option "$a"\n');
						return refsParseExit(EXIT_USAGE);
					}
					if (name == null)
						name = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			json: json,
			wantDecls: wantDecls,
			wantReads: wantReads,
			wantWrites: wantWrites,
			wantDoc: wantDoc,
			wantSource: wantSource,
			flat: flat,
			limit: limit,
			name: name,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectRefsEntries(
		name: String, paths: Array<String>, plugin: GrammarPlugin, shape: RefShape, singleFile: Bool, skipEntries: Array<SkipEntry>,
		candidateNames: Map<String, Bool>, filter: {
			anyFilter: Bool,
			wantDecls: Bool,
			wantReads: Bool,
			wantWrites: Bool
		}
	): Null<{ entries: Array<{ file: String, source: String, hits: Array<RefHit> }>, memberAccesses: Int, bindings: Int }> {
		final allEntries: Array<{ file: String, source: String, hits: Array<RefHit> }> = [];
		var memberAccesses: Int = 0;
		var bindings: Int = 0;
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('refs', plugin.parseFile, path, source, singleFile, skipEntries, name);
			CliIo.streamProgress('refs', ++scanned, paths.length, singleFile);
			if (tree == null) {
				// Single-file mode treats a parse failure as fatal — null tells
				// the caller to return EXIT_RUNTIME. Multi-file mode records the
				// file in skipEntries and keeps walking.
				if (singleFile) return null;
				continue;
			}
			final found: { hits: Array<RefHit>, skipped: Int } = Refs.findWithSkipped(name, tree, shape);
			final raw: Array<RefHit> = found.hits;
			// Both totals are UNFILTERED and cover every file, so what the walker could not
			// resolve is reported the same way whatever the caller asked to be shown.
			memberAccesses += found.skipped;
			for (h in raw) if (h.kind != RefKind.Decl) bindings++;
			final filtered: Array<RefHit> = filter.anyFilter
				? raw.filter(h -> kindAllowed(h.kind, filter.wantDecls, filter.wantReads, filter.wantWrites))
				: raw;
			if (filtered.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({ file: path, source: source, hits: filtered });
		}
		return { entries: allEntries, memberAccesses: memberAccesses, bindings: bindings };
	}

}
