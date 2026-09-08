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
 * Parsed options for `apq refs` — `lang`, `json`, the read / write / decl selection
 * (`wantDecls` / `wantReads` / `wantWrites`), output toggles, `flat`, `limit`, the symbol
 * `names` (a LIST — a bare `--` in argv separates several of them from the scope), and
 * `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller
 * returns immediately.
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
	var names: Array<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * One name's slice of a batched `apq refs` walk: the file groups its hits landed
 * in, the two unfiltered totals the member-access nudge reads, and the candidate
 * names a 0-hit nudge suggests from.
 *
 * It exists because a batch parses each file ONCE and then asks every name of the
 * same tree, so the per-name accumulators cannot live in the loop — one record per
 * name carries them across the file walk.
 *
 * `candidateNames` is the one place a batch is not identical to N separate runs:
 * a single-name walk parses only files whose text holds that name, while a batch
 * parses any file holding ANY of them, so a name's candidate set can be WIDER
 * here. That only ever improves the suggestion in a nudge; no hit set moves.
 */
@:nullSafety(Strict)
typedef RefsBatch = {
	var name: String;
	var entries: Array<{ file: String, source: String, hits: Array<RefHit> }>;
	var memberAccesses: Int;
	var bindings: Int;
	var candidateNames: Map<String, Bool>;
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

	private static final CMD: String = 'refs';

	public function new() {}

	public function name(): String {
		return CMD;
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
			names: [],
			inputSpecs: [],
			errExit: code
		};
	}

	private static function runRefs(args: Array<String>, ctx: CliContext): Int {
		final o: RefsOpts = parseRefsArgs(args);
		if (o.errExit != null) return o.errExit;
		if (o.names.length == 0) {
			CliIo.stderr('apq refs: missing <name> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq refs: missing <file-or-dir-or-glob> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		// `--json` renders ONE document, and two concatenated documents are not JSON.
		// A refusal is the honest answer; inventing a by-name envelope would give the
		// schema two shapes and every consumer a branch.
		if (o.json && o.names.length > 1) {
			CliIo.stderr('apq refs: --json emits ONE document, so it takes ONE name — drop --json, or run one call per name\n');
			return EXIT_USAGE;
		}
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
		if (expanded.unmatched.length > 0 && CliArgs.nameSeparatorIndex(args) < 0)
			CliIo.stderr('${CliWalk.unmatchedSpecNudge(CMD, expanded.unmatched)}\n');

		final skips: Array<QuerySkip> = [];
		final collected: Null<Array<RefsBatch>> = collectRefsEntries(o.names, paths, plugin, shape, expanded.singleFile, skips, {
			anyFilter: anyFilter,
			wantDecls: o.wantDecls,
			wantReads: o.wantReads,
			wantWrites: o.wantWrites
		});
		if (collected == null) return EXIT_RUNTIME;

		final batched: Bool = collected.length > 1;
		var anyHits: Bool = false;
		for (batch in collected) {
			final allEntries: Array<{ file: String, source: String, hits: Array<RefHit> }> = batch.entries;
			if (allEntries.length > 0) anyHits = true;
			if (batched) CliIo.sysPrint(CliWalk.batchSection(batch.name));

			// A parse failure is evidence for THIS name only if the file could have held it —
			// otherwise a batch hands every name the union of the others' failures, and the
			// "N parseable" count stops matching what the same name reports on its own.
			final own: Array<SkipEntry> = CliWalk.skipsFor(batch.name, !expanded.singleFile, skips);
			if (allEntries.length == 0)
				CliIo.stderr(
					'${CliWalk.emptyWalkerNudge(CMD, batch.name, paths.length, paths.length - own.length, own, batch.candidateNames)}\n'
				);
			if (batch.memberAccesses > 0)
				CliIo.stderr('${CliWalk.memberAccessNudge(CMD, batch.name, batch.memberAccesses, batch.bindings)}\n');

			// The cap is PER NAME: a run that asked for three names wants all three
			// represented, and a shared budget would let the first one eat it.
			final shown: Array<{ file: String, source: String, hits: Array<RefHit> }> =
				CliWalk.capAndReport(
					CMD, allEntries, o.limit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) },
					paths.length
				);
			if (o.json) {
				CliIo.sysPrint(Json.renderRefs(shown, o.wantDoc, o.wantSource, plugin.lexicalRegions));
			} else {
				for (entry in shown)
					CliIo.sysPrint(Text.renderRefs(
						entry.file, entry.source, entry.hits, o.wantDoc, o.wantSource, plugin.lexicalRegions(entry.source), o.flat
					));
			}
		}
		return ctx.emptyExit(!anyHits);
	}

	private static function printRefsUsage(): Void {
		CliIo.sysPrint('Usage: apq refs [options] <name> <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('       apq refs [options] <name>... -- <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --json              Emit JSON instead of text\n');
		CliIo.sysPrint('  --decls             Filter to declarations\n');
		CliIo.sysPrint('  --reads             Filter to read references\n');
		CliIo.sysPrint('  --writes            Filter to write references (Phase 3.3)\n');
		CliUsage.printDocSourceFlatLimitLangHelp();
		CliIo.sysPrint('Phase 3.1: name-only matching, no lexical scope. Filters combine\n');
		CliIo.sysPrint('inclusively — passing `--decls --reads` keeps both kinds.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A bare `--` splits SEVERAL names from the scope: every positional before\n');
		CliIo.sysPrint('it is a name, every one after it a scope spec, and the tree is parsed ONCE\n');
		CliIo.sysPrint('for all of them. Each name gets its own `=== <name> ===` section on stdout\n');
		CliIo.sysPrint('and its own --limit budget. Without the separator the grammar is unchanged\n');
		CliIo.sysPrint('(first positional = name, rest = scope). --json takes ONE name.\n');
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
		// A bare `--` in argv makes every positional BEFORE it a name and every one
		// after it a scope spec. Without one the grammar is untouched: the first
		// positional is the name, the rest are scope specs.
		final scan: WalkerScan = CliArgs.beginWalkerScan(args);

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--':
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
					scan.flat = true;
				case '--limit':
					try scan.limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
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
					CliArgs.routePositional(a, i, scan.separator, scan.names, scan.inputSpecs);
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
			flat: scan.flat,
			limit: scan.limit,
			names: scan.names,
			inputSpecs: scan.inputSpecs,
			errExit: null
		};
	}

	private static function collectRefsEntries(
		names: Array<String>, paths: Array<String>, plugin: GrammarPlugin, shape: RefShape, singleFile: Bool, skips: Array<QuerySkip>,
		filter: {
			anyFilter: Bool,
			wantDecls: Bool,
			wantReads: Bool,
			wantWrites: Bool
		}
	): Null<Array<RefsBatch>> {
		final batches: Array<RefsBatch> = [
			for (name in names)
				{
					name: name,
					entries: [],
					memberAccesses: 0,
					bindings: 0,
					candidateNames: []
				}
		];
		var scanned: Int = 0;
		for (path in paths) {
			// ONE parse per file for the whole batch. The pre-filter is the UNION of
			// the names, so a file holding any of them is parsed and every name is
			// then asked of the same tree.
			final parsedFile: Null<{ source: String, tree: QueryNode }> = CliWalk.parseWalkedFile(
				CMD, plugin.parseFile, path, singleFile, ++scanned, paths.length, names, skips
			);
			if (parsedFile == null) {
				// Single-file mode treats a parse failure as fatal — null tells the caller to
				// return EXIT_RUNTIME. Multi-file mode already recorded the file — WITH its
				// source, so `CliWalk.skipsFor` can hand each name only the failures that name
				// could have been found in — and walks on.
				if (singleFile) return null;
				continue;
			}
			final source: String = parsedFile.source;
			final parsed: QueryNode = parsedFile.tree;
			for (batch in batches) {
				final found: { hits: Array<RefHit>, skipped: Int } = Refs.findWithSkipped(batch.name, parsed, shape);
				final raw: Array<RefHit> = found.hits;
				// Both totals are UNFILTERED and cover every file, so what the walker could not
				// resolve is reported the same way whatever the caller asked to be shown.
				batch.memberAccesses += found.skipped;
				for (h in raw) if (h.kind != RefKind.Decl) batch.bindings++;
				final filtered: Array<RefHit> = filter.anyFilter
					? raw.filter(h -> kindAllowed(h.kind, filter.wantDecls, filter.wantReads, filter.wantWrites))
					: raw;
				if (filtered.length == 0) {
					collectNames(parsed, batch.candidateNames);
					continue;
				}
				batch.entries.push({ file: path, source: source, hits: filtered });
			}
		}
		return batches;
	}

}
