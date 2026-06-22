package anyparse.query;

import anyparse.check.Check;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.Diff;
import anyparse.query.Diff.DiffHit;
import anyparse.query.Cases.CasesHit;
import anyparse.query.Lit.LitHit;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta.MetaHit;
import anyparse.query.Inline;
import anyparse.query.Inline.InlineResult;
import anyparse.query.InlineMethod;
import anyparse.query.ExtractVar;
import anyparse.query.ExtractVar.ExtractResult;
import anyparse.query.ExtractMethod;
import anyparse.query.AddParam;
import anyparse.query.AddParam.AddParamResult;
import anyparse.query.ChangeSig;
import anyparse.query.ChangeSig.ChangeSigResult;
import anyparse.query.RemoveParam;
import anyparse.query.RemoveParam.RemoveParamResult;
import anyparse.query.AddMember;
import anyparse.query.AddImport;
import anyparse.query.AddElement;
import anyparse.query.ReplaceNode;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.CrossRename;
import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.MoveSymbol;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.SymbolQuery;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.Rename;
import anyparse.query.Rename.RenameResult;
import anyparse.query.Uses.UsesHit;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;
import haxe.Exception;
import anyparse.query.NewFile.NewFileSpec;
import anyparse.query.NewFile.NewFileResult;
import anyparse.query.format.LintFormat;
import anyparse.check.LintConfig;
#if (sys || nodejs)
import sys.io.File;
import sys.FileSystem;
#end

/**
 * Skip-entry for a walker's 0-hit nudge: a path the walk could not parse
 * plus a human-readable failure locus (`LINE:COL <message>`). The locus
 * lets the reader judge whether the parse failure is upstream of the
 * searched-for content (warning critical) or far past it (can ignore)
 * without a follow-up `hxq ast <path>` probe.
 */
typedef SkipEntry = { path: String, locus: String };

/**
 * Discriminator on the first-failure locus utest emitted —
 * `Fail` covers `FAIL` / `FAILURE` rows; `Error` covers `ERROR` rows
 * (an unhandled exception inside the test body). Used by callers to
 * pick the user-facing label without string comparison.
 */
enum abstract TestSummaryFailureKind(Int) {

	final Fail = 0;

	final Error = 1;

}

/**
 * First-failure locus captured by `Cli.parseTestSummary` from a utest
 * stdout transcript. `className` is the unindented CamelCase test class
 * header utest emits above the test group; empty string when the
 * transcript doesn't carry one. `line` is the 1-indexed source line
 * decoded from the detail row's `line: N, …` prefix, or `-1` when only
 * a bare detail was emitted (utest's `Print.formatFailure` omits the
 * prefix for plain-string failures).
 */
typedef TestSummaryFailureLocus = {
	className: String,
	testName: String,
	line: Int,
	message: String,
	kind: TestSummaryFailureKind
};

/**
 * Structured result of parsing a utest stdout transcript. `firstFailure`
 * is null when the run had no failures or errors; otherwise it carries
 * the first encountered locus (subsequent failures only bump counters).
 */
typedef TestSummaryResult = {
	tests: Int,
	assertions: Int,
	failures: Int,
	errors: Int,
	firstFailure: Null<TestSummaryFailureLocus>
};

/**
 * Corpus harness sweep snapshot (`bin/.last-sweep.json` schema).
 * Mirrors `HxFormatterCorpusTest.printSweepDelta`'s write contract —
 * `apq sweep` reads the JSON and reports totals + delta without
 * re-running the corpus.
 */
typedef SweepTotals = {
	pass: Int,
	fail: Int,
	skipParse: Int,
	skipWrite: Int,
	skipConfig: Int,
	skipMalformed: Int
};

/**
 * Recon cluster bucket: how many fixtures fall under a normalised
 * forward-locus key, a couple of example file paths, and one raw
 * locus sample for display. The cluster KEY is shared via the map
 * that owns the bucket; only the per-bucket payload lives here.
 *
 * `paths` holds the full path list (every file in the cluster) for
 * `apq recon --cluster <substr>` drill — distinct from `examples`,
 * which is capped at `RECON_EXAMPLES_PER_CLUSTER` for the histogram
 * "e.g. … in: A, B" display.
 */
typedef ReconCluster = {
	var count: Int;
	var examples: Array<String>;
	var paths: Array<String>;
	var rawSample: String;
};

/**
 * Per-failure record captured during the recon sweep. Mode-dependent
 * output (histogram / cluster drill / predict-strip) reads these
 * after the walk instead of printing inline, so cluster filtering
 * and substitution prediction stay decoupled from the file-system
 * traversal loop.
 */
typedef ReconRecord = {
	var path: String;
	var clusterKey: String;
	var source: String;
	var skipLine: String;

	/**
	 * 1-indexed line of the parse-fail locus inside `source`. `0` when
	 * the record came from a non-`ParseError` exception (no span); the
	 * `--source` drill prints `<no locus>` for those.
	 */
	var line: Int;

	/** 1-indexed column at the parse-fail locus; `0` for non-`ParseError`. */
	var col: Int;
};

/**
 * Result of one corpus walk. `wired == false` means the plugin's recon
 * parser is missing — both `runReconSweep` and `strip --from-cluster`
 * surface that as a hard runtime error before consuming the records.
 */
typedef ReconWalkResult = {
	var wired: Bool;
	var records: Array<ReconRecord>;
	var clusters: Map<String, ReconCluster>;
};
typedef LintPassResult = {
	var nextActive: Array<{ file: String, source: String }>;
	var fixedDelta: Int;
};
typedef ReconCurrentParse = {
	var unwired: Bool;
	var ok: Bool;
	var line: Int;
	var col: Int;
	var msg: String;
};
typedef ReconRegressionResult = {
	var regressed: Int;
	var unblocked: Int;
	var scanned: Int;
	var unwired: Bool;
};

/**
 * One trail-opt gate annotation hit surfaced by `apq gates`. `line`/`col`
 * point at the decl host the `@:fmt` is attached to (1-indexed, derived
 * from the decl span via `Span.lineCol`). `gateKind` is the call name
 * (`trailOptParseGate` / `trailOptShapeGate`), `predicate` the quoted
 * inner symbol — the field name to look up on the schema instance.
 */
typedef GateHit = {
	var line: Int;
	var col: Int;
	var declKind: String;
	var declName: Null<String>;
	var gateKind: String;
	var predicate: String;
};

/**
 * Intermediate parse result of `extractGate` — `gateKind` is the call
 * name without parens, `predicate` the quoted inner symbol. `null` from
 * the extractor means the `@:fmt` argument is not a gate call.
 */
typedef GateExtract = { gateKind: String, predicate: String };

/**
 * Outcome of one predict-relax probe — what `tryPredictRelax` returns
 * and `reportPredictRelax` consumes.
 *
 *  - `Unblock` — patched source parses; the slice candidate is gate
 *    relaxation on the ctor at `origLine:origCol`.
 *  - `StillFail` — patched source still fails; `newLine:newCol`
 *    carries the new fail-locus (moved-locus hint applies).
 *  - `NoTarget` — original error had no usable `expected` hint
 *    (typically `//` or empty), so there was nothing to inject.
 */
enum PredictRelaxKind {

	Unblock;
	StillFail;
	NoTarget;

}

typedef PredictRelaxResult = {
	var kind: PredictRelaxKind;
	var original: String;
	var patched: String;
	var injected: String;
	var origLine: Int;
	var origCol: Int;
	var newLine: Int;
	var newCol: Int;
	var message: String;
};

/**
 * One Slice-40-relaxation candidate surfaced by `apq recon
 * --permissive-construct`. The same data `gates --mechanism
 * mandatory-ref-lead-trail` reports for a single mandatory `@:lead` +
 * `@:trail` Ref field, plus the extracted bracket-pair tokens the
 * predictor strips from each skip-parse fixture's source to model the
 * `@:optional` relaxation in advance of the grammar edit.
 *
 *  - `file:line:col` — locator on the grammar source (where the field
 *    is declared); same shape as `apq gates` output so the user can jump
 *    straight to the declaration.
 *  - `declKind` / `declName` — owning ctor / field identity (e.g.
 *    `VarField` + `cond`).
 *  - `lead` / `trail` — the bracket-pair tokens; the predictor's strip
 *    function deletes `<lead>BALANCED<trail>` (symmetric) or `<lead>…`
 *    (asymmetric) from each fixture and re-parses to predict an UNBLOCK
 *    upper bound.
 */
typedef PermissiveCandidate = {
	var file: String;
	var line: Int;
	var col: Int;
	var declKind: String;
	var declName: Null<String>;
	var lead: String;
	var trail: String;
};

/**
 * Result of one `stripBalancedPairs` pass — the patched source plus a
 * `count` of strip occurrences so the predictor can report NO MATCH
 * (count == 0, fixture doesn't contain the construct) distinctly from
 * STILL FAIL (count > 0 but post-strip parse still errors).
 */
typedef StripResult = {
	var out: String;
	var count: Int;
};

/**
 * `apq` CLI entry point. Parses argv, picks a grammar plugin via
 * `--lang`, dispatches on the subcommand.
 *
 * Phase 1 surface: `apq ast <file> [--lang L] [--json] [--depth N]
 * [--select PATH] [--at LINE:COL] [--min-children N] [--max-children N]`.
 * Other subcommands (`search`,
 * `refs`, `meta`) are reserved — calling them prints a "deferred"
 * notice with the phase that owns each.
 */
@:nullSafety(Strict)
final class Cli {

	private static final EXIT_OK: Int = 0;
	private static final EXIT_USAGE: Int = 2;
	private static final EXIT_RUNTIME: Int = 1;

	private static final SKIP_PATHS_SHOWN: Int = 5;
	private static final FUZZY_MAX_DIST: Int = 3;

	/** The maximum 32-bit signed integer — a null-span sort sentinel and the unbounded `--top` / `--all` count. */
	private static inline final MAX_INT: Int = 0x7FFFFFFF;

	/**
	 * `blast`'s heuristic field-access section (member-name SUPERSET) is
	 * the only walker section that routinely emits hundreds of lines on a
	 * common member name (`.name`, `.type`, `.value`). It is also the
	 * least precise — every hit needs human verification — so flooding
	 * the transcript with 1000+ lines wastes more than it gains. Smart-
	 * default cap of 20 + a header hint pointing at `--all` (no cap) /
	 * `--limit N` (explicit cap) gives the verify-each affordance without
	 * the flood. Precise `uses` / `refs` sections above stay uncapped.
	 */
	private static final HEUR_DEFAULT_CAP: Int = 20;

	/** Cap on the cluster-key suggestion preview (top keys by frequency) shown when `--cluster` / `--from-cluster` finds no exact match. */
	private static final CLUSTER_PREVIEW_LIMIT: Int = 10;

	private static final RECON_TOP_N_DEFAULT: Int = 30;
	private static final RECON_EXAMPLES_PER_CLUSTER: Int = 2;
	private static final RECON_HEAD_LEN: Int = 70;
	private static final RECON_LOCUS_LEN: Int = 20;

	/**
	 * `recon --cluster <key> --source` drill: lines printed either side
	 * of the fail-locus row. 3 is enough to see the construct's frame
	 * (decl line + open brace + the failing body line) without flooding
	 * the drill output when a cluster has dozens of paths.
	 */
	private static final RECON_SOURCE_WINDOW_RADIUS: Int = 3;

	private static final FUZZY_TOP_K: Int = 3;

	/**
	 * Substring "did you mean" — `query` ≥ this length OR the substring
	 * pre-filter is skipped (avoids `Hx` matching every grammar type).
	 */
	private static final FUZZY_SUBSTRING_MIN_QUERY: Int = 4;

	/**
	 * Substring "did you mean" — candidate's extra char count over
	 * `query.length` must not exceed this (avoids `Foo` matching a huge
	 * `FooSomeReallyLongName` and crowding out true neighbours).
	 */
	private static final FUZZY_SUBSTRING_MAX_EXTRA: Int = 8;

	public static function main(): Void {
		#if nodejs
		// Set the exit code and let Node exit naturally — do NOT call
		// `Sys.exit` -> `process.exit`. `process.exit` terminates before async
		// `process.stdout`/`stderr` writes to a pipe fd flush, truncating
		// captured output at the ~8 KB pipe buffer (file / TTY fds write
		// synchronously, which is why `apq … > file` was always complete). `run`
		// is fully synchronous, so the event loop empties immediately and Node
		// drains stdout/stderr before exiting with this code.
		js.Node.process.exitCode = run(Sys.args());
		#elseif sys
		Sys.exit(run(Sys.args()));
		#else
		throw 'apq: only sys targets supported';
		#end
	}

	/** Pure-argv entry. Returns process exit code. */
	public static function run(args: Array<String>): Int {
		if (args.length == 0 || args[0] == '-h' || args[0] == '--help') {
			printUsage();
			return EXIT_OK;
		}
		final cmd: String = args[0];
		_requireMatch = false;
		final rest: Array<String> = [];
		for (a in args.slice(1)) if (a == '--exit-on-empty' || a == '--require-match')
			_requireMatch = true;
		else
			rest.push(a);
		switch cmd {
			case 'ast':
				return runAst(rest);
			case 'search':
				return runSearch(rest);
			case 'refs':
				return runRefs(rest);
			case 'rename':
				return runRename(rest);
			case 'move':
				return runMove(rest);
			case 'symbols':
				return runSymbols(rest);
			case 'importers':
				return runImporters(rest);
			case 'declares':
				return runDeclares(rest);
			case 'lint':
				return runLint(rest);
			case 'inline':
				return runInline(rest);
			case 'inline-method':
				return runInlineMethod(rest);
			case 'extract-var':
				return runExtractVar(rest);
			case 'extract-method':
				return runExtractMethod(rest);
			case 'add-param':
				return runAddParam(rest);
			case 'change-sig':
				return runChangeSig(rest);
			case 'remove-param':
				return runRemoveParam(rest);
			case 'add-member':
				return runAddMember(rest);
			case 'add-import':
				return runAddImport(rest);
			case 'add-element':
				return runAddElement(rest);
			case 'replace-node':
				return runReplaceNode(rest);
			case 'remove-element':
				return runRemoveElement(rest);
			case 'remove-import':
				return runRemoveImport(rest);
			case 'remove-member':
				return runRemoveMember(rest);
			case 'fmt':
				return runFmt(rest);
			case 'new':
				return runNew(rest);
			case 'set-doc':
				return runSetDoc(rest);
			case 'set-comment':
				return runSetComment(rest);
			case 'rewrite':
				return runRewrite(rest);
			case 'comment-rewrite':
				return runCommentRewrite(rest);
			case 'set-modifier':
				return runSetModifier(rest);
			case 'uses':
				return runUses(rest);
			case 'meta':
				return runMeta(rest);
			case 'blast':
				return runBlast(rest);
			case 'lit':
				return runLit(rest);
			case 'mentions':
				return runMentions(rest);
			case 'cases':
				return runCases(rest);
			case 'gates':
				return runGates(rest);
			case 'diff':
				return runDiff(rest);
			case 'strip':
				return runStrip(rest);
			case 'writer-equals':
				return runWriterEquals(rest);
			case 'probe':
				return runProbe(rest);
			case 'writer-probe':
				return runWriterProbe(rest);
			case 'recon':
				#if (sys || nodejs)
				return runRecon(rest);
				#else
				stderr('apq recon: requires a sys target (filesystem walk)\n');
				return EXIT_USAGE;
				#end
			case 'sweep':
				#if (sys || nodejs)
				return runSweep(rest);
				#else
				stderr('apq sweep: requires a sys target (file read)\n');
				return EXIT_USAGE;
				#end
			case 'test-summary':
				#if (sys || nodejs)
				return runTestSummary(rest);
				#else
				stderr('apq test-summary: requires a sys target (file or stdin read)\n');
				return EXIT_USAGE;
				#end
			case 'self-status':
				#if (sys || nodejs)
				return runSelfStatus(rest);
				#else
				stderr('apq self-status: requires a sys target (filesystem walk)\n');
				return EXIT_USAGE;
				#end
			case 'source':
				#if (sys || nodejs)
				return runSource(rest);
				#else
				stderr('apq source: requires a sys target (file read)\n');
				return EXIT_USAGE;
				#end
			case _:
				stderr('apq: unknown subcommand "$cmd"\n');
				printUsage();
				return EXIT_USAGE;
		}
	}

	private static function runRefs(args: Array<String>): Int {
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
					lang = expectValue(args, ++i, '--lang');
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
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printRefsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq refs: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null)
						name = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq refs: missing <name> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq refs: missing <file-or-dir-or-glob> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		final nameStr: String = name;
		// No flag = no filter (emit every hit). Any flag flips on the
		// allow-set; sister CLIs (`git log --author --grep`) follow the
		// same any-flag-narrows convention.
		final anyFilter: Bool = wantDecls || wantReads || wantWrites;

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: RefShape = plugin.refShape();

		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq refs: no input files matched ${inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final singleFile: Bool = expanded.singleFile;
		final allEntries: Array<{ file: String, source: String, hits: Array<RefHit> }> = [];
		final skipEntries: Array<SkipEntry> = [];
		final candidateNames: Map<String, Bool> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('refs', plugin.parseFile, path, source, singleFile, skipEntries, nameStr);
			streamProgress('refs', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw: Array<RefHit> = Refs.find(nameStr, tree, shape);
			final filtered: Array<RefHit> = anyFilter ? raw.filter(h -> kindAllowed(h.kind, wantDecls, wantReads, wantWrites)) : raw;
			if (filtered.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({ file: path, source: source, hits: filtered });
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('refs', nameStr, paths.length, paths.length - skipEntries.length, skipEntries, candidateNames) + '\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = effectiveAutoLimit('refs', limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<RefHit> }> =
			limitEntries(
				allEntries, cappedLimit, e -> e.hits.length, (e, k) -> { file: e.file, source: e.source, hits: e.hits.slice(0, k) }
			);
		if (json) {
			sysPrint(Json.renderRefs(shown, wantDoc, wantSource));
		} else {
			for (entry in shown) sysPrint(Text.renderRefs(entry.file, entry.source, entry.hits, wantDoc, wantSource, flat));
		}
		return emptyExit(allEntries.length == 0);
	}

	/**
	 * `apq rename <file> <line>:<col> <newName> [--write]` — scope-correct,
	 * format-preserving rename of the binding identified by the symbol at
	 * `<line>:<col>`. Position-based so the EXACT binding is selected
	 * (`apq refs <name> --reads` shows distinct bindings for shadowed
	 * names). Reuses the `refs` resolver to collect the binding's full
	 * occurrence set, then span-rewrites only those identifier tokens.
	 *
	 * `<line>:<col>` uses the same column convention `apq refs` PRINTS, so
	 * a coordinate copied straight from `apq refs --decls` output selects
	 * the intended binding. Without `--write` the rewritten source is
	 * emitted to stdout; with `--write` it overwrites the file in place.
	 * A cursor that is not on a renameable identifier, or a rewrite that
	 * fails to re-parse, exits non-zero with the source untouched.
	 */
	private static function runRename(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var scope: Null<String> = null;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var newName: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--scope':
					scope = expectValue(args, ++i, '--scope');
				case '-h', '--help':
					printRenameUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq rename: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else if (newName == null)
						newName = a;
					else {
						stderr('apq rename: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null || newName == null) {
			stderr('apq rename: expected <file> <line>:<col> <newName>\n');
			printRenameUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq rename: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final newNameStr: String = newName;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq rename: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);

		if (scope != null) return runRenameScope(filePath, source, pos.line, pos.col, newNameStr, scope, write, plugin);

		final shape: RefShape = plugin.refShape();
		final result: RenameResult = Rename.rename(source, pos.line, pos.col, newNameStr, plugin, shape);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq rename: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq rename: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq rename <file> <l>:<c> <newName> --scope <dir>` — cross-file
	 * TYPE rename. The cursor's binding MUST be a type declaration; that
	 * type is renamed across every `.hx` file under `<dir>` (plus the
	 * cursor file if it sits outside the scope). Reads the scope files
	 * from disk, drives the pure `CrossRename.crossRenameType`, and on
	 * success either writes each changed file (`--write`) or prints a
	 * per-file occurrence summary. The whole rewrite is atomic — the
	 * pure op validates every rewritten file before returning, so a
	 * write either touches all changed files or none.
	 */
	private static function runRenameScope(
		filePath: String, source: String, line: Int, col: Int, newName: String, scope: String, write: Bool, plugin: GrammarPlugin
	): Int {
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs([scope], '.hx');
		final paths: Array<String> = expanded.paths;
		// The cursor file's declaration must be covered even if it sits
		// outside the scope directory — add it when expandInputs missed it.
		if (!paths.contains(filePath)) paths.push(filePath);
		if (paths.length == 0) {
			stderr('apq rename: --scope $scope matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final scopeFiles: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			if (path == filePath) {
				scopeFiles.push({ file: path, source: source });
				continue;
			}
			final fileSource: String = try readSourceForParse(path) catch (exception: Exception) {
				stderr('apq rename: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			scopeFiles.push({ file: path, source: fileSource });
		}

		final typeRefShape: TypeRefShape = plugin.typeRefShape();
		final refShape: RefShape = plugin.refShape();
		final result: CrossRenameResult = CrossRename.crossRenameType(
			filePath, source, line, col, newName, scopeFiles, plugin, typeRefShape, refShape
		);
		switch result {
			case Ok(changes, advisory):
				var totalOccurrences: Int = 0;
				for (c in changes) totalOccurrences += c.count;
				if (write) {
					for (c in changes) writeFile(c.file, c.newSource);
					stderr('apq rename: wrote ${changes.length} file(s), $totalOccurrences occurrence(s)\n');
				} else {
					for (c in changes) sysPrint('${c.file}: ${c.count} occurrence(s)\n');
					sysPrint('total: ${changes.length} file(s), $totalOccurrences occurrence(s)\n');
				}
				if (advisory != null) stderr('apq rename: $advisory\n');
				return EXIT_OK;
			case Err(message):
				stderr('apq rename: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq move <file> <line>:<col> <dest-file> --scope <dir> [--write]` —
	 * move the TYPE declaration at `<line>:<col>` (in `<file>`) into
	 * `<dest-file>` (same package), fixing imports across `<scope>`. Reads
	 * every scope file from disk (plus the cursor and destination files
	 * when they sit outside the scope directory), drives the pure
	 * `MoveSymbol.moveType`, and on success either writes each changed
	 * file (`--write`) or prints a per-file `moved` / `updated` summary.
	 * The whole rewrite is atomic — the pure op re-parses every rewritten
	 * file before returning, so a write either touches all changed files
	 * or none. `<line>:<col>` uses the same column convention `apq refs`
	 * prints.
	 */
	private static function runMove(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var scope: Null<String> = null;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var destFileArg: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--scope':
					scope = expectValue(args, ++i, '--scope');
				case '-h', '--help':
					printMoveUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq move: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else if (destFileArg == null)
						destFileArg = a;
					else {
						stderr('apq move: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null || destFileArg == null) {
			stderr('apq move: expected <file> <line>:<col> <dest-file>\n');
			printMoveUsage();
			return EXIT_USAGE;
		}
		if (scope == null) {
			stderr('apq move: --scope <dir> is required (imports are fixed across the scope)\n');
			printMoveUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq move: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final cursorFile: String = file;
		final destFile: String = destFileArg;
		final scopeDir: String = scope;
		final plugin: GrammarPlugin = pickPlugin(lang);

		// Gather scope files = expandInputs(scope) ∪ {cursorFile, destFile}.
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs([scopeDir], '.hx');
		final paths: Array<String> = expanded.paths;
		if (!paths.contains(cursorFile)) paths.push(cursorFile);
		if (!paths.contains(destFile)) paths.push(destFile);
		if (paths.length == 0) {
			stderr('apq move: --scope $scopeDir matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final scopeFiles: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			final fileSource: String = try readSourceForParse(path) catch (exception: Exception) {
				stderr('apq move: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			scopeFiles.push({ file: path, source: fileSource });
		}

		final typeRefShape: TypeRefShape = plugin.typeRefShape();
		final result: MoveResult = MoveSymbol.moveType(cursorFile, pos.line, pos.col, destFile, scopeFiles, plugin, typeRefShape);
		switch result {
			case Ok(changes, advisory):
				if (write) {
					for (c in changes) writeFile(c.file, c.newSource);
					stderr('apq move: wrote ${changes.length} file(s)\n');
				} else {
					for (c in changes) {
						final tag: String = c.file == cursorFile || c.file == destFile ? 'moved' : 'updated';
						sysPrint('${c.file}: $tag\n');
					}
					sysPrint('total: ${changes.length} file(s)\n');
				}
				if (advisory != null) stderr('apq move: $advisory\n');
				return EXIT_OK;
			case Err(message):
				stderr('apq move: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq symbols <scope> [--lang <name>] [--kind <Kind>]` — list every
	 * top-level type declaration across the `<scope>` (one or more
	 * file/dir/glob specs) as `<import-path>\t<Kind>\t<file>:<line>:<col>`,
	 * in input-file order then source order. `<import-path>` is what a
	 * consumer would `import` — the module path for the module's main
	 * type, else `module.SubType`. `--kind` filters to one decl kind
	 * (`ClassDecl` / `InterfaceDecl` / `EnumDecl` / `TypedefDecl` /
	 * `AbstractDecl`). Unparseable files are skipped silently. This is the
	 * CLI surface of the cross-file `SymbolIndex` type browser.
	 */
	private static function runSymbols(args: Array<String>): Int {
		var lang: String = 'haxe';
		var kindFilter: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--kind':
					kindFilter = expectValue(args, ++i, '--kind');
				case '-h', '--help':
					printSymbolsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq symbols: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					inputSpecs.push(a);
			}
			i++;
		}
		if (inputSpecs.length == 0) {
			stderr('apq symbols: expected <scope> (one or more file/dir/glob specs)\n');
			printSymbolsUsage();
			return EXIT_USAGE;
		}

		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq symbols: ${inputSpecs.join(', ')} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final files: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			final fileSource: String = try readSourceForParse(path) catch (exception: Exception) {
				stderr('apq symbols: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			files.push({ file: path, source: fileSource });
		}

		final rows: Array<SymbolQuery.SymbolRow> = SymbolQuery.symbols(files, plugin, kindFilter);
		for (row in rows) sysPrint('${SymbolQuery.formatSymbolRow(row)}\n');
		return EXIT_OK;
	}

	/**
	 * `apq importers <module> <scope> [--lang <name>]` — list the files in
	 * `<scope>` (one or more file/dir/glob specs after the module) that
	 * import `<module>` — a direct `import` / `using` of the module itself
	 * or of one of its sub-types. A wildcard `import pkg.*;` is NOT
	 * counted (see `SymbolIndex.filesImportingModule`). The reverse-
	 * dependency / impact-analysis surface of the cross-file `SymbolIndex`.
	 */
	private static function runImporters(args: Array<String>): Int {
		var lang: String = 'haxe';
		var module: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printImportersUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq importers: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (module == null)
						module = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (module == null || inputSpecs.length == 0) {
			stderr('apq importers: expected <module> <scope> (one or more file/dir/glob specs)\n');
			printImportersUsage();
			return EXIT_USAGE;
		}

		final modulePath: String = module;
		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq importers: ${inputSpecs.join(', ')} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final files: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			final fileSource: String = try readSourceForParse(path) catch (exception: Exception) {
				stderr('apq importers: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			files.push({ file: path, source: fileSource });
		}

		final hits: Array<String> = SymbolQuery.importers(files, plugin, modulePath);
		for (path in hits) sysPrint('$path\n');
		return EXIT_OK;
	}

	/**
	 * `apq declares <type> <scope> [--lang <name>]` — the declaration
	 * site(s) of the type named `<type>` across `<scope>` (one or more
	 * file/dir/glob specs), matching either the simple name or the fully
	 * qualified import path. Each site prints as
	 * `qualified<TAB>kind<TAB>file:line:col` on stdout. More than one is an
	 * ambiguity (two decls of the same name) and zero means the type is not
	 * declared in the scope — both are reported on stderr so stdout stays a
	 * clean row list. The focused, single-type counterpart of `symbols`.
	 */
	private static function runDeclares(args: Array<String>): Int {
		var lang: String = 'haxe';
		var typeName: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printDeclaresUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq declares: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (typeName == null)
						typeName = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (typeName == null || inputSpecs.length == 0) {
			stderr('apq declares: expected <type> <scope> (one or more file/dir/glob specs)\n');
			printDeclaresUsage();
			return EXIT_USAGE;
		}

		final name: String = typeName;
		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq declares: ${inputSpecs.join(', ')} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final files: Array<{ file: String, source: String }> = [];
		for (path in paths) {
			final fileSource: String = try readSourceForParse(path) catch (exception: Exception) {
				stderr('apq declares: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			files.push({ file: path, source: fileSource });
		}

		final rows: Array<SymbolQuery.SymbolRow> = SymbolQuery.declares(files, plugin, name);
		if (rows.length == 0)
			stderr('apq declares: no type named "$name" in ${inputSpecs.join(', ')}\n');
		else if (rows.length > 1) stderr('apq declares: ambiguous — ${rows.length} declarations of "$name"\n');
		for (row in rows) sysPrint('${SymbolQuery.formatSymbolRow(row)}\n');
		return EXIT_OK;
	}

	/**
	 * `apq lint <scope> [--rule <id>]... [--all] [--flat] [--lang <name>]`
	 * — run the analysis checks over `<scope>` (one or more file/dir/glob
	 * specs) and report violations grouped by file, reusing the walker
	 * reporter (`Text.renderViolations`). `--rule` selects a subset of the
	 * built-in checks by id (repeatable); the default runs all of them.
	 *
	 * Findings go to stdout grouped per file; a severity breakdown goes to
	 * stderr so stdout stays a clean list. `Info` advisories (e.g.
	 * unverifiable wildcard / `using` imports) are hidden unless `--all` is
	 * given, but always counted in the summary. The exit code is success
	 * regardless of findings — `lint` is a report, like `symbols`.
	 */
	private static function runLint(args: Array<String>): Int {
		final o: LintOpts = parseLintArgs(args);
		if (o.errExit != null) return o.errExit;
		if (o.inputSpecs.length == 0) {
			stderr('apq lint: expected <scope> (one or more file/dir/glob specs)\n');
			printLintUsage();
			return EXIT_USAGE;
		}

		final checks: Null<Array<Check>> = resolveLintChecks(o.ruleFilters);
		if (checks == null) return EXIT_USAGE;

		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq lint: ${o.inputSpecs.join(', ')} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final files: Array<{ file: String, source: String }> = [];
		final sourceOf: Map<String, String> = [];
		for (path in paths) {
			final fileSource: String = try readSourceForParse(path) catch (exception: Exception) {
				stderr('apq lint: $path: ${exception.message}\n');
				return EXIT_RUNTIME;
			};
			files.push({ file: path, source: fileSource });
			sourceOf[path] = fileSource;
		}

		final lintConfig: LintConfig = LintConfig.discover(paths[0] ?? '.');
		final activeChecks: Array<Check> = o.ruleFilters.length == 0
			? [
				for (c in checks) if (lintConfig.enabledFor(c.id())) c
			]
			: checks;
		final all: Array<Violation> = Linter.run(files, plugin, activeChecks, lintConfig);

		if (o.fix) return applyLintFixes(files, activeChecks, plugin, lintConfig);

		final shown: Array<Violation> = o.includeInfo ? all : all.filter(v -> v.severity != Severity.Info);
		renderLintReport(paths, shown, sourceOf, o.format, o.flat);
		lintSummary(all, paths, o.includeInfo);

		final failOn: Null<Severity> = o.failOn;
		if (failOn != null) {
			final threshold: Int = (cast failOn: Int);
			for (v in all) if ((cast v.severity: Int) <= threshold) return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	/** Source-offset sort key for a violation span; null spans sort last. */
	private static inline function spanStart(span: Null<Span>): Int {
		return span != null ? span.from : MAX_INT;
	}

	/**
	 * Apply each active check's autofix across the file set in `--fix` mode,
	 * iterating to a FIXED POINT. A fix can expose a new finding — deleting a
	 * dead-code run leaves a local unused; de-nesting a `redundant-else`
	 * `else if` chain surfaces the inner `else` — so a single pass is not
	 * enough. Each pass re-lints the in-memory (already-fixed) sources and
	 * re-applies; only files a prior pass changed are revisited (a fix exposes
	 * new findings only in a file it edited). Per file, a pass batches the
	 * fixable edits from every check into ONE `RefactorSupport.canonicalize`
	 * (so several deletions apply end-to-start without span-shift). Sources are
	 * mutated in memory and flushed to disk once at the end. A non-canonical
	 * first-pass file is refused by the canonical gate and skipped with a note;
	 * a later-pass refusal (a writer-idempotency wrinkle on our own output)
	 * just stops that file quietly. The pass count is capped as a runaway guard.
	 * Exit is always success — `--fix` is best-effort.
	 */
	private static function applyLintFixes(
		files: Array<{ file: String, source: String }>, checks: Array<Check>, plugin: GrammarPlugin, lintConfig: LintConfig
	): Int {
		final maxPasses: Int = 10;
		// Parse each file once and reuse the tree across the SymbolIndex build, every
		// check, and every fix — keyed by source content, so an unchanged file is
		// reused across passes and only a rewritten one re-parses on its new content.
		final cached: GrammarPlugin = new CachingGrammarPlugin(plugin);
		// hxformat.json is on disk and source-independent — discover once per file.
		final optsByFile: Map<String, Null<String>> = [];
		for (entry in files) optsByFile[entry.file] = discoverFormatConfig(entry.file);

		// Files eligible next pass: pass 1 = all; later passes = only the ones a
		// prior pass changed (a same-file fix exposes findings only where it edited; a cross-file fix would need a re-run).
		var active: Array<{ file: String, source: String }> = files.copy();
		final noted: Array<String> = [];
		final changedFiles: Array<String> = [];
		var fixedCount: Int = 0;
		var passes: Int = 0;
		var hitCap: Bool = false;
		// Per-file checks decide a file's findings from that file alone, so later passes
		// re-lint only the files a prior pass changed. A cross-file check (confinement)
		// must see every file or it mis-resolves on the active subset — run those over
		// the full set each pass.
		final fullScopeIds: Array<String> = ['unused-private', 'prefer-final-field', 'unused-parameter'];
		final activeScopeChecks: Array<Check> = [for (c in checks) if (!fullScopeIds.contains(c.id())) c];
		final fullScopeChecks: Array<Check> = [for (c in checks) if (fullScopeIds.contains(c.id())) c];

		while (active.length > 0) {
			if (passes >= maxPasses) {
				hitCap = true;
				break;
			}
			passes++;
			final pass: LintPassResult = applyLintPass(
				active, files, cached, activeScopeChecks, fullScopeChecks, checks, lintConfig, optsByFile, passes, noted, changedFiles
			);
			fixedCount += pass.fixedDelta;
			active = pass.nextActive;
		}

		for (entry in files) if (changedFiles.contains(entry.file)) writeFile(entry.file, entry.source);

		final skipTail: String = noted.length > 0 ? ', ${noted.length} file(s) skipped' : '';
		final capTail: String = hitCap ? ' (stopped at $maxPasses passes — re-run if more remain)' : '';
		stderr('apq lint --fix: fixed $fixedCount issue(s) in ${changedFiles.length} file(s) over $passes pass(es)$skipTail$capTail\n');
		return EXIT_OK;
	}

	/**
	 * `apq inline <file> <line>:<col> [--write]` — scope-correct,
	 * format-preserving inline of the local `var` / `final` binding
	 * identified by the symbol at `<line>:<col>`. Every read of the
	 * binding is replaced with the binding's initializer source text
	 * (parenthesised when the initializer is an operator expression), the
	 * declaration line is deleted, and the result is verified to re-parse.
	 * Reuses the `refs` resolver — the same scope-aware engine `rename`
	 * uses — so the EXACT binding under the cursor is targeted.
	 *
	 * The inline refuses unless the binding is single-assignment and its
	 * initializer is side-effect-free (no calls / field access / new /
	 * collections / lambdas / interpolation) and depends only on stable
	 * locals — a conservative whitelist that never trades correctness for
	 * reach. `<line>:<col>` uses the same column convention `apq refs`
	 * prints. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A cursor that is not
	 * on an inlinable local, an unsafe initializer, or a rewrite that
	 * fails to re-parse exits non-zero with the source untouched.
	 */
	private static function runInline(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '-h', '--help':
					printInlineUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq inline: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else {
						stderr('apq inline: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null) {
			stderr('apq inline: expected <file> <line>:<col>\n');
			printInlineUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq inline: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq inline: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: RefShape = plugin.refShape();
		final result: InlineResult = Inline.inlineVar(source, pos.line, pos.col, plugin, shape);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq inline: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq inline: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq inline-method <file> <line>:<col> [--write]` — inline the
	 * function whose declaration is at `<line>:<col>` into EVERY in-file
	 * call site and delete the now-dead declaration. The body must reduce
	 * to a single return expression; each call's positional arguments are
	 * substituted for the parameters (parenthesised to preserve
	 * precedence), and the call-site set is proven complete before any
	 * rewrite. Like `inline` it is format-preserving (raw span splices, not
	 * the writer). `<line>:<col>` uses the same column convention
	 * `apq refs` prints. Without `--write` the rewritten source is emitted
	 * to stdout; with `--write` it overwrites the file in place. A cursor
	 * not on a function, a non-single-return body, an unprovable call set,
	 * an impure dropped / duplicated argument, an arity mismatch, or an
	 * unparseable result exits non-zero with the file untouched. NOTE: a
	 * method may have callers in OTHER files that this in-file op cannot
	 * see or update — inlining deletes the declaration regardless.
	 */
	private static function runInlineMethod(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '-h', '--help':
					printInlineMethodUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq inline-method: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else {
						stderr('apq inline-method: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null) {
			stderr('apq inline-method: expected <file> <line>:<col>\n');
			printInlineMethodUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq inline-method: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq inline-method: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: RefShape = plugin.refShape();
		final result: EditResult = InlineMethod.inlineMethod(source, pos.line, pos.col, plugin, shape);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq inline-method: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq inline-method: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq extract-var <file> <line>:<col> <name> [--write]` — hoist the
	 * expression starting at `<line>:<col>` into a fresh local
	 * `final <name> = <expr>;` inserted on its own line immediately before
	 * the nearest enclosing block-level statement (at that statement's
	 * indentation), replacing the expression occurrence with `<name>`. The
	 * inverse of `inline`. The enclosing statement must be a direct child
	 * of a `{ }` block — an expression buried in a braceless branch is
	 * refused. `<line>:<col>` uses the same column convention `apq refs`
	 * prints. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A cursor not on an
	 * expression start, an enclosing statement outside a block, or an
	 * unparseable result exits non-zero with the file untouched.
	 */
	private static function runExtractVar(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var name: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '-h', '--help':
					printExtractVarUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq extract-var: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else if (name == null)
						name = a;
					else {
						stderr('apq extract-var: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null || name == null) {
			stderr('apq extract-var: expected <file> <line>:<col> <name>\n');
			printExtractVarUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq extract-var: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final nameStr: String = name;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq extract-var: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final result: ExtractResult = ExtractVar.extractVar(source, pos.line, pos.col, nameStr, plugin);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq extract-var: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq extract-var: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq extract-method <file> <startL>:<startC> <endL>:<endC> <name>
	 * [--write] [--reformat]` — extract the contiguous run of statements
	 * bounded by the two positions into a fresh local function `<name>`
	 * (a closure capturing the enclosing scope), replacing the run with a
	 * call. A local declared in the run and used after it becomes the
	 * call's return value (at most one). The run must be sibling statements
	 * of one `{ }` block with no return / break / continue. Because the op
	 * synthesises a new function, the result is WRITER-FORMATTED — the
	 * source must already be canonical unless `--reformat` is passed.
	 * `<line>:<col>` use the `apq refs` print convention. Without `--write`
	 * the rewritten source is emitted to stdout; with `--write` it
	 * overwrites in place.
	 */
	private static function runExtractMethod(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var startSpec: Null<String> = null;
		var endSpec: Null<String> = null;
		var name: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printExtractMethodUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq extract-method: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (startSpec == null)
						startSpec = a;
					else if (endSpec == null)
						endSpec = a;
					else if (name == null)
						name = a;
					else {
						stderr('apq extract-method: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || startSpec == null || endSpec == null || name == null) {
			stderr('apq extract-method: expected <file> <startLine>:<col> <endLine>:<col> <name>\n');
			printExtractMethodUsage();
			return EXIT_USAGE;
		}
		final startPos: Null<Position> = parseLineCol(startSpec);
		if (startPos == null) {
			stderr('apq extract-method: malformed start position "$startSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}
		final endPos: Null<Position> = parseLineCol(endSpec);
		if (endPos == null) {
			stderr('apq extract-method: malformed end position "$endSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final nameStr: String = name;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq extract-method: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: RefShape = plugin.refShape();
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		final result: EditResult = ExtractMethod.extractMethod(
			source, startPos.line, startPos.col, endPos.line, endPos.col, nameStr, reformat, plugin, shape, optsJson
		);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq extract-method: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq extract-method: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq add-param <file> <line>:<col> <paramText> [--write]` — add
	 * `<paramText>` as a new trailing parameter to the function whose
	 * declaration is at `<line>:<col>`. The parameter MUST be
	 * backward-compatible — optional (`?name:T`) or defaulted
	 * (`name:T = v`) — so existing call sites need no update; this is a
	 * decl-only operation that touches no call site. `<paramText>` is a
	 * single positional (the user quotes it when it contains spaces) and is
	 * taken verbatim. `<line>:<col>` uses the same column convention
	 * `apq refs` prints. Without `--write` the rewritten source is emitted
	 * to stdout; with `--write` it overwrites the file in place. A cursor
	 * not on a function, a required parameter, a name collision, or an
	 * unparseable result exits non-zero with the file untouched.
	 */
	private static function runAddParam(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var paramText: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '-h', '--help':
					printAddParamUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq add-param: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else if (paramText == null)
						paramText = a;
					else {
						stderr('apq add-param: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null || paramText == null) {
			stderr('apq add-param: expected <file> <line>:<col> <paramText>\n');
			printAddParamUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq add-param: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final paramStr: String = paramText;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq add-param: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final result: AddParamResult = AddParam.addParam(source, pos.line, pos.col, paramStr, plugin);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq add-param: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq add-param: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq add-member <file> --type <TypeName> <memberText> [--reformat] [--write]`
	 * — append `<memberText>` as a new member of the type named
	 * `<TypeName>`. The member is WRITER-FORMATTED: the raw text is placed
	 * before the body's closing `}` and the whole file is re-emitted through
	 * the writer (which also re-parse-validates). The file must already be
	 * writer-canonical, else it is refused unless `--reformat` is given.
	 * Without `--write` the rewritten source is emitted to stdout; with
	 * `--write` it overwrites the file in place. An unknown / ambiguous type
	 * name, a non-canonical file without `--reformat`, or an unparseable
	 * result, exits non-zero with the file untouched.
	 */
	private static function runAddMember(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var typeName: Null<String> = null;
		var file: Null<String> = null;
		var memberText: Null<String> = null;
		var fromFile: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--type':
					typeName = expectValue(args, ++i, '--type');
				case '--from-file':
					fromFile = expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddMemberUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq add-member: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (memberText == null)
						memberText = a;
					else {
						stderr('apq add-member: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fromFile != null || memberText == '-') {
			final resolved: Null<String> = resolveCodeArg('add-member', memberText, fromFile);
			if (resolved == null) return EXIT_RUNTIME;
			memberText = resolved;
		}
		if (file == null || typeName == null || memberText == null) {
			stderr('apq add-member: expected <file> --type <TypeName> (<memberText> | --from-file <path> | -)\n');
			printAddMemberUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final typeStr: String = typeName;
		final memberStr: String = memberText;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq add-member: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		final result: EditResult = AddMember.addMember(source, typeStr, memberStr, reformat, plugin, optsJson);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq add-member: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq add-member: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq add-import <file> <module.path> [--using] [--reformat] [--write]`
	 * — add an `import <module.path>;` (or `using` with `--using`) after the
	 * last existing import / using, else after the `package` declaration,
	 * else at the file start. The result is WRITER-FORMATTED (the whole file
	 * is re-emitted through the writer, which also re-parse-validates); the
	 * file must already be canonical, else it is refused unless `--reformat`
	 * is given. An already-present import of the same kind is refused.
	 * Without `--write` the rewritten source is emitted to stdout; with
	 * `--write` it overwrites the file in place. An empty path, a duplicate,
	 * a non-canonical file without `--reformat`, or an unparseable result
	 * exits non-zero with the file untouched.
	 */
	private static function runAddImport(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var isUsing: Bool = false;
		var file: Null<String> = null;
		var path: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--using':
					isUsing = true;
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddImportUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq add-import: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (path == null)
						path = a;
					else {
						stderr('apq add-import: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || path == null) {
			stderr('apq add-import: expected <file> <module.path> [--using]\n');
			printAddImportUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final pathStr: String = path;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq add-import: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		final result: EditResult = AddImport.addImport(source, pathStr, isUsing, reformat, plugin, optsJson);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq add-import: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq add-import: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq add-element <file> (--after <line>:<col> | --before <line>:<col>)
	 * <code> [--reformat] [--write]` — insert `<code>` as a new sibling
	 * element next to the existing element whose first token is at
	 * `<line>:<col>` (a statement in a block, a `case` in a `switch`, an
	 * array / object / call-argument element). The separator the slot needs
	 * (a `,` for comma lists, a newline for statement / case lists) is added
	 * automatically; the inserted element is WRITER-FORMATTED and the whole
	 * file is re-parse-validated (a malformed element is rejected). To
	 * append, point at the last sibling with `--after`; to prepend, the
	 * first with `--before`. `<line>:<col>` use the `apq refs` print
	 * convention. The source must already be canonical unless `--reformat`.
	 * Without `--write` the result goes to stdout; with `--write` it
	 * overwrites in place.
	 */
	private static function runAddElement(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var afterSpec: Null<String> = null;
		var beforeSpec: Null<String> = null;
		var appendSpec: Null<String> = null;
		var file: Null<String> = null;
		var code: Null<String> = null;
		var fromFile: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--after':
					afterSpec = expectValue(args, ++i, '--after');
				case '--before':
					beforeSpec = expectValue(args, ++i, '--before');
				case '--append':
					appendSpec = expectValue(args, ++i, '--append');
				case '--from-file':
					fromFile = expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printAddElementUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq add-element: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (code == null)
						code = a;
					else {
						stderr('apq add-element: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fromFile != null || code == '-') {
			final resolved: Null<String> = resolveCodeArg('add-element', code, fromFile, true);
			if (resolved == null) return EXIT_RUNTIME;
			code = resolved;
		}
		if (file == null || code == null) {
			stderr(
				'apq add-element: expected <file> (--after <line>:<col> | --before <line>:<col> | --append <line>:<col>) (<code> | --from-file <path> | -)\n'
			);
			printAddElementUsage();
			return EXIT_USAGE;
		}
		// Exactly one of --after / --before / --append must be given.
		final targetCount: Int = (afterSpec != null ? 1 : 0) + (beforeSpec != null ? 1 : 0) + (appendSpec != null ? 1 : 0);
		if (targetCount != 1) {
			stderr('apq add-element: provide exactly one of --after <line>:<col>, --before <line>:<col>, or --append <line>:<col>\n');
			return EXIT_USAGE;
		}

		final posSpec: String = if (afterSpec != null)
			afterSpec;
		else if (beforeSpec != null)
			beforeSpec;
		else
			(appendSpec: String);
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq add-element: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final codeStr: String = code;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq add-element: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		final result: EditResult = if (appendSpec != null)
			AddElement.appendElement(source, pos.line, pos.col, codeStr, reformat, plugin, optsJson);
		else
			AddElement.addElement(source, pos.line, pos.col, afterSpec != null ? After : Before, codeStr, reformat, plugin, optsJson);
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq add-element: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq add-element: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/** Shared Ok/Err + write/print tail for the single-result remove ops. */
	private static function finishEdit(opName: String, filePath: String, write: Bool, result: EditResult): Int {
		switch result {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq $opName: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				return EXIT_OK;
			case Err(message):
				stderr('apq $opName: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq remove-element <file> <line>:<col> [--reformat] [--write]` — remove
	 * the sibling element whose first token is at `line:col` (a statement /
	 * case / array / object / call-arg element / member), with its modifier /
	 * meta group, writer-formatted + re-parse-validated. The structural
	 * inverse of `add-element`; same column convention `apq refs` prints.
	 */
	private static function runRemoveElement(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var withDoc: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--with-doc':
					withDoc = true;
				case '-h', '--help':
					printRemoveElementUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq remove-element: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else {
						stderr('apq remove-element: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null) {
			stderr('apq remove-element: expected <file> <line>:<col>\n');
			printRemoveElementUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq remove-element: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq remove-element: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		return finishEdit(
			'remove-element', filePath, write, RemoveElement.removeElement(source, pos.line, pos.col, reformat, plugin, withDoc, optsJson)
		);
	}

	/**
	 * `apq remove-import <file> <module.path> [--reformat] [--write]` — remove
	 * the `import` / `using` whose exposed path equals `<module.path>` (the
	 * alias for an aliased import). The path must name exactly one statement.
	 * The by-name counterpart of `remove-element`; backend of `lint --fix`.
	 */
	private static function runRemoveImport(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var modulePath: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printRemoveImportUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq remove-import: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (modulePath == null)
						modulePath = a;
					else {
						stderr('apq remove-import: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || modulePath == null) {
			stderr('apq remove-import: expected <file> <module.path>\n');
			printRemoveImportUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final path: String = modulePath;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq remove-import: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		return finishEdit('remove-import', filePath, write, RemoveImport.removeImport(source, path, reformat, plugin, optsJson));
	}

	/**
	 * `apq remove-member <file> --type <T> <memberName> [--reformat] [--write]`
	 * — remove the member named `<memberName>` of type `<T>` (a field or
	 * method), with its modifier / meta group. Both `<T>` and `<memberName>`
	 * must resolve to exactly one node. The by-name counterpart of
	 * `add-member`.
	 */
	private static function runRemoveMember(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var withDoc: Bool = false;
		var typeName: Null<String> = null;
		var file: Null<String> = null;
		var memberName: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--type':
					typeName = expectValue(args, ++i, '--type');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--with-doc':
					withDoc = true;
				case '-h', '--help':
					printRemoveMemberUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq remove-member: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (memberName == null)
						memberName = a;
					else {
						stderr('apq remove-member: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || typeName == null || memberName == null) {
			stderr('apq remove-member: expected <file> --type <T> <memberName>\n');
			printRemoveMemberUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final type: String = typeName;
		final member: String = memberName;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq remove-member: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		return finishEdit(
			'remove-member', filePath, write, RemoveMember.removeMember(source, type, member, reformat, plugin, withDoc, optsJson)
		);
	}

	/**
	 * `apq replace-node <file> (--select <sel> | --at <line>:<col>) <newSource> [--reformat] [--write]`
	 * — replace the source span of a single node with `<newSource>`. The
	 * target is addressed by an `ast`-style `--select` selector (which must
	 * match exactly one node) OR by a cursor `--at <line>:<col>` in the same
	 * column convention `apq refs` prints. The result is WRITER-FORMATTED:
	 * the whole file is re-emitted through the writer (which also re-parse-
	 * validates), so the replacement is laid out by the grammar's rules. The
	 * file must already be canonical, else it is refused unless `--reformat`
	 * is given. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A target that resolves
	 * to no / multiple nodes, a non-canonical file without `--reformat`, or
	 * an unparseable result, exits non-zero with the file untouched.
	 */
	private static function runReplaceNode(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var selectExpr: Null<String> = null;
		var atSpec: Null<String> = null;
		var kind: Null<String> = null;
		var withDoc: Bool = false;
		var file: Null<String> = null;
		var newSource: Null<String> = null;
		var fromFile: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = expectValue(args, ++i, '--select');
				case '--at':
					atSpec = expectValue(args, ++i, '--at');
				case '--kind':
					kind = expectValue(args, ++i, '--kind');
				case '--with-doc':
					withDoc = true;
				case '--from-file':
					fromFile = expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '-h', '--help':
					printReplaceNodeUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq replace-node: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (newSource == null)
						newSource = a;
					else {
						stderr('apq replace-node: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fromFile != null || newSource == '-') {
			final resolved: Null<String> = resolveCodeArg('replace-node', newSource, fromFile, true);
			if (resolved == null) return EXIT_RUNTIME;
			newSource = resolved;
		}
		if (file == null || newSource == null) {
			stderr('apq replace-node: expected <file> (--select <sel> | --at <line>:<col>) (<newSource> | --from-file <path> | -)\n');
			printReplaceNodeUsage();
			return EXIT_USAGE;
		}
		// Exactly one of --select / --at must be given.
		if ((selectExpr == null) == (atSpec == null)) {
			stderr('apq replace-node: provide exactly one of --select <sel> or --at <line>:<col>\n');
			return EXIT_USAGE;
		}
		// --kind narrows --at to a node of that kind; it has no meaning with --select.
		if (kind != null && atSpec == null) {
			stderr('apq replace-node: --kind requires --at <line>:<col>\n');
			return EXIT_USAGE;
		}

		final target: ReplaceTarget = if (selectExpr != null)
			BySelector(selectExpr);
		else if (atSpec != null) {
			final pos: Null<Position> = parseLineCol(atSpec);
			if (pos == null) {
				stderr('apq replace-node: malformed position "$atSpec" — expected <line>:<col>\n');
				return EXIT_USAGE;
			}
			kind != null ? ByKindPosition(pos.line, pos.col, kind) : ByPosition(pos.line, pos.col);
		} else {
			// Unreachable given the exactly-one guard above; keeps the
			// if-expression exhaustive and null-safe.
			stderr('apq replace-node: provide exactly one of --select <sel> or --at <line>:<col>\n');
			return EXIT_USAGE;
		};

		final filePath: String = file;
		final newSrc: String = newSource;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq replace-node: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		return finishEdit(
			'replace-node', filePath, write, ReplaceNode.replaceNode(source, target, newSrc, reformat, plugin, withDoc, optsJson)
		);
	}

	/**
	 * `apq change-sig <file> <line>:<col> <perm> [--write]` — reorder the
	 * parameters of the function whose decl / binding is at `<line>:<col>`
	 * per `<perm>` (a comma-separated 0-based list of the OLD parameter
	 * indices in their NEW order, e.g. `2,0,1`), permuting the positional
	 * arguments at every resolvable in-file call site to match. The reorder
	 * is a SLOT SWAP — only the parameter / argument contents move, so the
	 * existing layout is preserved. `<line>:<col>` uses the same column
	 * convention `apq refs` prints. Without `--write` the rewritten source
	 * is emitted to stdout; with `--write` it overwrites the file in place.
	 * A reorder of a method also emits a cross-file advisory to stderr
	 * (callers in other files cannot be seen). A cursor not on a function,
	 * a malformed / non-permutation `<perm>`, an unresolvable / receiver-
	 * qualified call site, an arity mismatch, or an unparseable result,
	 * exits non-zero with the file untouched.
	 */
	private static function runChangeSig(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var permSpec: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '-h', '--help':
					printChangeSigUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq change-sig: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else if (permSpec == null)
						permSpec = a;
					else {
						stderr('apq change-sig: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null || permSpec == null) {
			stderr('apq change-sig: expected <file> <line>:<col> <perm>\n');
			printChangeSigUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq change-sig: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final permStr: String = permSpec;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq change-sig: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: RefShape = plugin.refShape();
		final result: ChangeSigResult = ChangeSig.changeSig(source, pos.line, pos.col, permStr, plugin, shape);
		switch result {
			case Ok(text, advisory):
				if (write) {
					writeFile(filePath, text);
					stderr('apq change-sig: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				if (advisory != null) stderr('apq change-sig: $advisory\n');
				return EXIT_OK;
			case Err(message):
				stderr('apq change-sig: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * `apq remove-param <file> <line>:<col> <index> [--write]` — remove the
	 * parameter at 0-based `<index>` from the function whose decl / binding
	 * is at `<line>:<col>`, deleting the corresponding positional argument
	 * at every resolvable in-file call site. The inverse of `add-param`,
	 * but — unlike `add-param` (decl-only, backward-compat-safe) — removing
	 * a parameter BREAKS calls, so it updates call sites with the SAME
	 * strict completeness proof `change-sig` uses (an unresolvable /
	 * receiver-qualified call, a value capture, or an arity mismatch is
	 * refused). The removed parameter must be unused in the body — a
	 * remaining use is refused (the result would reference an undefined
	 * identifier). `<line>:<col>` uses the same column convention `apq refs`
	 * prints. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A removal on a method
	 * also emits a cross-file advisory to stderr (callers in other files
	 * cannot be seen). A cursor not on a function, an out-of-range index, a
	 * used parameter, an unresolvable call, an arity mismatch, or an
	 * unparseable result, exits non-zero with the file untouched.
	 */
	private static function runRemoveParam(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var indexSpec: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write':
					write = true;
				case '-h', '--help':
					printRemoveParamUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq remove-param: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else if (indexSpec == null)
						indexSpec = a;
					else {
						stderr('apq remove-param: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || posSpec == null || indexSpec == null) {
			stderr('apq remove-param: expected <file> <line>:<col> <index>\n');
			printRemoveParamUsage();
			return EXIT_USAGE;
		}
		final pos: Null<Position> = parseLineCol(posSpec);
		if (pos == null) {
			stderr('apq remove-param: malformed position "$posSpec" — expected <line>:<col>\n');
			return EXIT_USAGE;
		}
		final index: Null<Int> = RefactorSupport.parseStrictInt(indexSpec);
		if (index == null) {
			stderr('apq remove-param: malformed index "$indexSpec" — expected a non-negative integer\n');
			return EXIT_USAGE;
		}
		final paramIndex: Int = index;

		final filePath: String = file;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq remove-param: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: RefShape = plugin.refShape();
		final result: RemoveParamResult = RemoveParam.removeParam(source, pos.line, pos.col, paramIndex, plugin, shape);
		switch result {
			case Ok(text, advisory):
				if (write) {
					writeFile(filePath, text);
					stderr('apq remove-param: wrote $filePath\n');
				} else {
					sysPrint(text);
				}
				if (advisory != null) stderr('apq remove-param: $advisory\n');
				return EXIT_OK;
			case Err(message):
				stderr('apq remove-param: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * Parse a `<line>:<col>` coordinate. Both components must be
	 * non-negative integers; returns null on any malformed shape so the
	 * caller emits a usage error rather than silently clamping.
	 */
	private static function parseLineCol(spec: String): Null<Position> {
		final colon: Int = spec.indexOf(':');
		if (colon <= 0 || colon >= spec.length - 1) return null;
		final line: Null<Int> = RefactorSupport.parseStrictInt(spec.substring(0, colon));
		final col: Null<Int> = RefactorSupport.parseStrictInt(spec.substring(colon + 1));
		return line == null || col == null ? null : { line: line, col: col };
	}

	private static function runUses(args: Array<String>): Int {
		var lang: String = 'haxe';
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
					lang = expectValue(args, ++i, '--lang');
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printUsesUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq uses: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null)
						name = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq uses: missing <type-name> argument\n');
			printUsesUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq uses: missing <file-or-dir-or-glob> argument\n');
			printUsesUsage();
			return EXIT_USAGE;
		}
		final nameStr: String = name;

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: TypeRefShape = plugin.typeRefShape();

		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq uses: no input files matched ${inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final singleFile: Bool = expanded.singleFile;
		final allEntries: Array<{ file: String, source: String, hits: Array<UsesHit> }> = [];
		final skipEntries: Array<SkipEntry> = [];
		final candidateNames: Map<String, Bool> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('uses', plugin.parseFileTypeRefs, path, source, singleFile, skipEntries, nameStr);
			streamProgress('uses', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final hits: Array<UsesHit> = Uses.find(nameStr, tree, shape);
			if (hits.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({ file: path, source: source, hits: hits });
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('uses', nameStr, paths.length, paths.length - skipEntries.length, skipEntries, candidateNames) + '\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = effectiveAutoLimit('uses', limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<UsesHit> }> =
			limitEntries(
				allEntries, cappedLimit, e -> e.hits.length, (e, k) -> { file: e.file, source: e.source, hits: e.hits.slice(0, k) }
			);
		for (entry in shown) sysPrint(Text.renderUses(entry.file, entry.source, entry.hits, wantDoc, wantSource, flat));
		return emptyExit(allEntries.length == 0);
	}

	private static function runMeta(args: Array<String>): Int {
		final o: MetaOpts = parseMetaArgs(args);
		if (o.errExit != null) return o.errExit;
		final argContains: Null<String> = o.argContains;
		final onKind: Null<String> = o.onKind;
		final positionals: Array<String> = o.positionals;

		// Positional grammar: [<annotation>[(<arg>)]] <file-or-dir-or-glob>...
		// The annotation, when present, is the leading positional and is
		// recognised by its `@` sigil (Haxe annotations always start with
		// `@`; file/dir/glob specs never do) — this disambiguates without
		// a positional-count cap, so multiple input specs are accepted.
		// With `--on` the annotation may be omitted entirely.
		//
		// The annotation may carry an inline arg filter `@:tag(arg)` — the
		// trailing `(...)` is split off the tag here. `argFilter` keeps only
		// hits whose meta has a TOP-LEVEL argument that is either the bare
		// ident `arg` OR a call `arg(...)` (callee match), the precise
		// counterpart to the `--arg-contains` substring scan. `@:fmt` is the
		// driving case (`@:fmt(propagateExprPosition)`), but the split is
		// tag-agnostic. `@:tag` with no `(...)` leaves the tag untouched and
		// `argFilter` null (the historical no-arg behaviour).
		final rawAnnotation: Null<String> = positionals.length > 0 && StringTools.startsWith(positionals[0], '@') ? positionals[0] : null;
		final annotation: Null<String> = rawAnnotation != null ? annotationTag(rawAnnotation) : null;
		final argFilter: Null<String> = rawAnnotation != null ? annotationArgFilter(rawAnnotation) : null;
		final inputSpecs: Array<String> = rawAnnotation != null ? positionals.slice(1) : positionals.copy();
		if (inputSpecs.length == 0) {
			stderr('apq meta: missing <file-or-dir-or-glob> argument\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		if (annotation == null && onKind == null) {
			// One bare positional with no `--on`: ambiguous — it is taken
			// as the <file-or-dir-or-glob>, leaving no annotation/kind to scope
			// the query. Spell out both halves the grammar needs.
			stderr('apq meta: need an <annotation> or --on <decl-kind>, plus a <file-or-dir-or-glob>\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final shape: MetaShape = plugin.metaShape();

		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq meta: no input files matched ${inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final skipEntries: Array<SkipEntry> = [];
		final allEntries: Null<Array<{ file: String, source: String, hits: Array<MetaHit> }>> =
			collectMetaEntries(paths, plugin, shape, expanded.singleFile, skipEntries, {
				annotation: annotation,
				argContains: argContains,
				argFilter: argFilter,
				onKind: onKind
			});
		if (allEntries == null) return EXIT_RUNTIME;

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('meta', null, paths.length, paths.length - skipEntries.length, skipEntries, null) + '\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = effectiveAutoLimit('meta', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<MetaHit> }> =
			limitEntries(
				allEntries, cappedLimit, e -> e.hits.length, (e, k) -> { file: e.file, source: e.source, hits: e.hits.slice(0, k) }
			);
		if (o.json) {
			sysPrint(Json.renderMeta(shown));
		} else {
			for (entry in shown) sysPrint(Text.renderMeta(entry.file, entry.source, entry.hits, o.flat));
		}
		return emptyExit(allEntries.length == 0);
	}

	/**
	 * `apq diff <a> <b>` — structural AST diff between two parseable
	 * source files. Output is `file:L:C ↔ file:L:C: <diff>` per hit.
	 * The pair walk is top-down without LCS realignment: it surfaces
	 * "single edit" / "end-of-list change" / "subtree swap" cleanly,
	 * but a mid-list insert into a long Star cascades every following
	 * sibling as `differs`. For those cases use byte diff or `--limit`.
	 */
	private static function runDiff(args: Array<String>): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var fileA: Null<String> = null;
		var fileB: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printDiffUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq diff: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (fileA == null)
						fileA = a;
					else if (fileB == null)
						fileB = a;
					else {
						stderr('apq diff: only two file arguments supported (got "$fileA", "$fileB", "$a")\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fileA == null || fileB == null) {
			stderr('apq diff: missing <a> <b> arguments\n');
			printDiffUsage();
			return EXIT_USAGE;
		}
		final a: String = fileA;
		final b: String = fileB;

		final plugin: GrammarPlugin = pickPlugin(lang);
		final sourceA: String = readSourceForParse(a);
		final sourceB: String = readSourceForParse(b);
		final treeA: QueryNode = try plugin.parseFile(sourceA) catch (e: ParseError) {
			stderr('apq diff: $a: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			stderr('apq diff: $a: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final treeB: QueryNode = try plugin.parseFile(sourceB) catch (e: ParseError) {
			stderr('apq diff: $b: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			stderr('apq diff: $b: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		var hits: Array<DiffHit> = Diff.diff(treeA, treeB);
		if (limit >= 0 && hits.length > limit) hits = hits.slice(0, limit);
		sysPrint(Diff.render(a, sourceA, b, sourceB, hits, flat));
		return EXIT_OK;
	}

	private static function printDiffUsage(): Void {
		sysPrint('Usage: apq diff [options] <a> <b>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` per-hit format (default: paired-header)\n');
		sysPrint('  --limit <n>         Stop after n hits (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Structural AST diff: walks both trees pairwise and reports nodes\n');
		sysPrint('where kind / name slot / child count diverges. No LCS realignment\n');
		sysPrint('— mid-list inserts cascade the tail as `differs`. Useful for strip-\n');
		sysPrint('test reconciliation when a byte diff is whitespace-noisy.\n');
	}

	/**
	 * `apq strip <file> --replace <pat> --with <repl> [...]` — machinised
	 * strip-test for the skip-parse campaign. Applies one or more
	 * literal string substitutions to a file's bytes in declaration
	 * order, then tries to parse the result via the grammar plugin.
	 * Emits a single `PARSE OK` / `PARSE FAIL: <err>` verdict to stdout;
	 * with `--show` also dumps the stripped source to stderr so a manual
	 * scratch-file dance (`cat > /tmp/probe.hx <<EOF … EOF; hxq ast …`)
	 * collapses to one command. Exits 0 on PARSE OK, non-zero on FAIL —
	 * scriptable for batch sole-blocker confirmation.
	 *
	 * Pairing rule: each `--with <repl>` consumes the immediately
	 * preceding `--replace <pat>`. Mismatch (more replaces than withs,
	 * or `--with` first) is a usage error. `--delete <pat>` is the
	 * shortcut for `--replace <pat> --with ''`. Repeat `--replace
	 * <pat>` / `--delete <pat>` for multi-substitution; subs apply in
	 * the order given. Substitutions are literal (no regex). Replaces
	 * EVERY occurrence (`StringTools.replace` semantics) — use a more
	 * specific pattern when only the first match should change.
	 *
	 * Lit-stripping context: `.hxtest` corpus fixtures carry a JSON
	 * config block above a `---` separator. Strip operates on raw bytes;
	 * pass an `.hx` scratch extract (the post-`---` body) or accept
	 * that the config bytes will pass through unchanged.
	 */
	private static function runStrip(args: Array<String>): Int {
		final o: StripOpts = parseStripArgs(args);
		if (o.errExit != null) return o.errExit;
		// Compile every pattern AHEAD of any FS I/O so a regex typo
		// surfaces as a single usage error instead of an N-file partial
		// apply. Indices stay aligned with `patterns` / `replacements`.
		// Plain (literal) mode leaves `compiledRegex` null and falls
		// through to the StringTools.replace path further down.
		final compiledRegex: Null<Array<EReg>> = o.regexMode ? compileStripRegexes('strip', o.patterns) : null;
		if (o.regexMode && compiledRegex == null) return EXIT_USAGE;
		// `--per-pattern` constraints: single-file only (the matrix
		// would be NxM otherwise), incompatible with `--dry-run` (the
		// dry-run path skips parse entirely so isolation diagnostics
		// have no PARSE OK/FAIL signal) and `--from-cluster` (the
		// cluster-mode discovers N files from a recon walk, never one).
		if (o.perPattern) {
			if (o.dryRun) {
				stderr('apq strip: --per-pattern is incompatible with --dry-run (dry-run skips the parse step)\n');
				return EXIT_USAGE;
			}
			if (o.fromCluster != null) {
				stderr('apq strip: --per-pattern is incompatible with --from-cluster (single-file isolation only)\n');
				return EXIT_USAGE;
			}
		}
		// `--from-cluster` mode: discover files via recon walk, then
		// fall through into the existing per-file substitution loop.
		// Conflict guards live here so a bad mix is surfaced before
		// any FS I/O or plugin call.
		final fromCluster: Null<String> = o.fromCluster;
		if (fromCluster != null) {
			if (o.files.length > 1) {
				stderr(
					'apq strip: --from-cluster takes at most one positional (corpus root); got ${o.files.length} (${o.files.join(', ')})\n'
				);
				return EXIT_USAGE;
			}
			final discovered: Null<Array<String>> = resolveStripFromCluster(o.lang, o.files.length == 1 ? o.files[0] : null, fromCluster);
			if (discovered == null) return EXIT_RUNTIME;
			// Replace the positional list with the cluster's path list so
			// the rest of runStrip is mode-agnostic. A non-null `discovered`
			// is non-empty by construction (any cluster keyed in the map
			// has at least one path; the no-match path returned null
			// above), so no zero-length branch needed here.
			o.files.resize(0);
			for (p in (discovered: Array<String>)) o.files.push(p);
		} else if (o.files.length == 0) {
			stderr('apq strip: missing <file> argument (one or more, applies same substitutions to each)\n');
			printStripUsage();
			return EXIT_USAGE;
		}
		final plugin: GrammarPlugin = pickPlugin(o.lang);
		if (o.perPattern) {
			if (o.files.length != 1) {
				stderr('apq strip: --per-pattern takes exactly one file (got ${o.files.length})\n');
				return EXIT_USAGE;
			}
			if (o.patterns.length < 2) {
				stderr(
					'apq strip: --per-pattern requires ≥2 patterns (got ${o.patterns.length}) — isolation diagnostic only useful when patterns can be tested independently\n'
				);
				return EXIT_USAGE;
			}
			return runStripPerPattern(plugin, o.files[0], o.patterns, o.replacements, compiledRegex);
		}
		return executeStrip(plugin, o, compiledRegex);
	}

	/**
	 * `--per-pattern` isolation diagnostic. Runs the parse on:
	 *  1. baseline (no patterns applied — the original source)
	 *  2. each pattern in isolation (only that one applied)
	 *  3. combined (all patterns applied, the regular strip behaviour)
	 *
	 * Output is one line per row, plus a final verdict that calls out
	 * the interlocking-blockers signature: every isolated row FAIL +
	 * combined OK means the slice needs N separate code mechanisms
	 * (one per pattern), not one. The verdict is informational — exit
	 * code follows the combined row, so a passing combination still
	 * exits 0 even when every isolated row failed.
	 *
	 * Single-file only (caller-enforced) — for multi-file matrices the
	 * `--dry-run` per-pattern totals + per-file PARSE OK/FAIL combination
	 * already covers the use-case.
	 */
	private static function runStripPerPattern(
		plugin: GrammarPlugin, filePath: String, patterns: Array<String>, replacements: Array<String>, compiledRegex: Null<Array<EReg>>
	): Int {
		final source: String = readSourceForParse(filePath);
		final regexMode: Bool = compiledRegex != null;
		final regexes: Array<EReg> = compiledRegex ?? [];
		final baseline: { ok: Bool, msg: String } = stripTryParse(plugin, source);
		sysPrint('baseline (no patterns): ${baseline.ok ? 'PARSE OK' : 'PARSE FAIL: ' + baseline.msg}\n');
		final isolatedResults: Array<{ ok: Bool, hits: Int }> = [];
		for (idx in 0...patterns.length) {
			final hits: Int = regexMode ? countRegexHits(regexes[idx], source) : countOccurrences(source, patterns[idx]);
			final isolated: String = regexMode
				? regexes[idx].replace(source, replacements[idx])
				: StringTools.replace(source, patterns[idx], replacements[idx]);
			final r: { ok: Bool, msg: String } = stripTryParse(plugin, isolated);
			isolatedResults.push({ ok: r.ok, hits: hits });
			final pat: String = patterns[idx];
			sysPrint('pattern[$idx] "$pat" ($hits match${hits == 1 ? '' : 'es'}): ${r.ok ? 'PARSE OK' : 'PARSE FAIL: ' + r.msg}\n');
		}
		var combinedStripped: String = source;
		for (idx in 0...patterns.length)
			combinedStripped = regexMode
				? regexes[idx].replace(combinedStripped, replacements[idx])
				: StringTools.replace(combinedStripped, patterns[idx], replacements[idx]);
		final combined: { ok: Bool, msg: String } = stripTryParse(plugin, combinedStripped);
		sysPrint('combined (all patterns): ${combined.ok ? 'PARSE OK' : 'PARSE FAIL: ' + combined.msg}\n');
		reportStripVerdict(baseline.ok, combined.ok, isolatedResults, patterns.length);
		return combined.ok ? EXIT_OK : EXIT_RUNTIME;
	}

	/**
	 * Resolve the `strip --from-cluster <key>` path list: run a recon
	 * walk over the corpus root, filter by cluster key, return absolute
	 * paths (so the file loop reads the actual files, not the
	 * stripped-relative names recon stores). On miss (unknown key) or
	 * setup error, prints to stderr and returns `null` — caller exits
	 * `EXIT_RUNTIME`.
	 *
	 * `rootArg` is the explicit positional (if any); fall back to
	 * `defaultReconRoot()` (env var) on null.
	 */
	private static function resolveStripFromCluster(lang: String, rootArg: Null<String>, key: String): Null<Array<String>> {
		#if (sys || nodejs)
		final root: String = rootArg ?? defaultReconRoot();
		if (root == '') {
			stderr("apq strip: --from-cluster requires a corpus root (positional <dir> or $ANYPARSE_HXFORMAT_FORK env var).\n");
			return null;
		}
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			stderr('apq strip: --from-cluster: "$root" is not a directory.\n');
			return null;
		}
		final plugin: GrammarPlugin = pickPlugin(lang);
		final walk: ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq strip: --from-cluster: no recon parser wired up for lang "$lang"\n');
			return null;
		}
		final cluster: Null<ReconCluster> = walk.clusters[key];
		if (cluster == null) {
			stderr('apq strip: --from-cluster "$key" matched no cluster key (exact match).\n');
			final keyEntries: Array<{ key: String, count: Int }> = [
				for (k => v in walk.clusters) { key: k, count: v.count }
			];
			keyEntries.sort((a, b) -> b.count - a.count);
			final preview: Int = keyEntries.length > CLUSTER_PREVIEW_LIMIT ? CLUSTER_PREVIEW_LIMIT : keyEntries.length;
			if (preview == 0) {
				stderr('  (no skip-parse failures in this sweep)\n');
			} else {
				stderr('  available keys (${keyEntries.length} total, showing top $preview by frequency):\n');
				for (idx in 0...preview) stderr('    "${keyEntries[idx].key}"  (${keyEntries[idx].count}×)\n');
				if (keyEntries.length > preview)
					stderr('    … (${keyEntries.length - preview} more — run `apq recon` on the same root to see the full histogram)\n');
			}
			return null;
		}
		// ReconCluster.paths are root-relative (e.g. `issue_582.hxtest`);
		// rejoin with the root so file IO uses absolute paths regardless
		// of CWD.
		final out: Array<String> = [for (p in cluster.paths) '$root/$p'];
		out.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
		return out;
		#else
		stderr('apq strip: --from-cluster requires a sys target (filesystem walk)\n');
		return null;
		#end
	}

	/**
	 * Count non-overlapping occurrences of `needle` in `haystack`.
	 * Matches `StringTools.replace`'s scan semantics — used by `apq
	 * strip --dry-run` so the per-pattern hit count exactly tracks
	 * how many substitutions the non-dry-run path would perform.
	 */
	private static function countOccurrences(haystack: String, needle: String): Int {
		if (needle.length == 0) return 0;
		var count: Int = 0;
		var from: Int = 0;
		while (true) {
			final idx: Int = haystack.indexOf(needle, from);
			if (idx < 0) break;
			count++;
			from = idx + needle.length;
		}
		return count;
	}

	/**
	 * Compile every `--replace` / `--delete` pattern as an `EReg` with
	 * the global flag `g` (needed so `replace` and `map` walk every
	 * occurrence, matching the literal-mode `StringTools.replace`
	 * semantics). On compile failure prints the offending pattern + EReg
	 * error to stderr and returns `null` — caller exits `EXIT_USAGE`
	 * before any FS I/O. Tool tag (`'strip'` / `'recon'`) is threaded for
	 * the error message prefix so the user sees which subcommand owned
	 * the typo.
	 */
	private static function compileStripRegexes(tool: String, patterns: Array<String>): Null<Array<EReg>> {
		final out: Array<EReg> = [];
		for (idx in 0...patterns.length) {
			final pat: String = patterns[idx];
			try {
				out.push(new EReg(pat, 'g'));
			} catch (e: Exception) {
				stderr('apq $tool: --regex: pattern[$idx] "$pat" is not a valid EReg: ${e.message}\n');
				return null;
			}
		}
		return out;
	}

	/**
	 * Count every match of `re` in `s`. Uses `EReg.map` for the side
	 * effect — the callback fires once per match (including zero-length
	 * matches, which `EReg` advances past internally) and returns the
	 * matched text unchanged so the produced string equals the input.
	 * Cheap enough for predict-strip / strip --dry-run sweeps.
	 */
	private static function countRegexHits(re: EReg, s: String): Int {
		var n: Int = 0;
		re.map(
			s, m -> {
				n++;
				m.matched(0);
			}
		);
		return n;
	}

	private static function printStripUsage(): Void {
		sysPrint('Usage: apq strip [options] <file> [<file2> ...] --replace <pat> --with <repl> [...]\n');
		sysPrint('       apq strip --from-cluster <key> [<dir>] --replace <pat> --with <repl> [...]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --replace <pat>     Literal substring to replace (paired with the next --with)\n');
		sysPrint('  --with <repl>       Replacement for the most recent --replace\n');
		sysPrint('  --delete <pat>      Shortcut for --replace <pat> --with \'\'\n');
		sysPrint('  --regex             Treat --replace / --delete patterns as EReg (global match)\n');
		sysPrint('                      instead of literal substrings. Backrefs in --with via $1.\n');
		sysPrint('  --show              Dump the stripped source to stderr (debug)\n');
		sysPrint('  --dry-run           Skip parse, only verify each pattern matched ≥1 occurrence somewhere (typo guard)\n');
		sysPrint('  --per-pattern       Isolation diagnostic for multi-pattern strip on a single file. Runs baseline,\n');
		sysPrint('                      each pattern alone, and combined. Surfaces interlocking blockers (combined OK +\n');
		sysPrint('                      every isolated row FAIL = slice needs N separate code mechanisms, not one).\n');
		sysPrint('                      Requires single file and ≥2 patterns; incompatible with --dry-run / --from-cluster.\n');
		sysPrint('  --from-cluster <key>\n');
		sysPrint('                      Discover file list via a recon walk and filter by EXACT cluster\n');
		sysPrint('                      key (same shape as `apq recon --cluster <key>`). Positional <dir>\n');
		sysPrint("                      becomes the corpus root (env fallback to $ANYPARSE_HXFORMAT_FORK\n");
		sysPrint('                      /test/testcases). Apply complement of `recon --predict-strip`.\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Apply literal substitutions in order, then parse the result via the\n');
		sysPrint('grammar plugin. Emits PARSE OK / PARSE FAIL: <err> and exits 0/2 —\n');
		sysPrint('scriptable sole-blocker confirmation for the skip-parse campaign.\n');
		sysPrint('StringTools.replace semantics: every occurrence is replaced.\n');
		sysPrint('\n');
		sysPrint('Pass multiple file paths to run the SAME substitutions against each\n');
		sysPrint('(batch mode); per-file output is prefixed with the path, and a final\n');
		sysPrint('summary line totals pass/fail counts. Exit 0 only when ALL files\n');
		sysPrint('PARSE OK; exit 2 when any file PARSE FAIL — useful for sole-blocker\n');
		sysPrint('sweeps across a list of candidate fixtures.\n');
	}

	/**
	 * `apq writer-equals <input> <expected> [--plain] [--lang haxe]` —
	 * byte-equality check on writer output. Parses `<input>`, writes via
	 * the plugin's trivia pipeline (default) or plain pipeline (`--plain`),
	 * compares the emitted bytes against the contents of `<expected>`.
	 *
	 * Exit 0 on match, 1 on byte-diff (or parse/write failure). On diff
	 * prints a single `apq writer-equals: byte-diff @ <offset>  exp=<…>
	 * act=<…>  (exp.len=…, act.len=…)` line — same shape as the corpus
	 * harness's `describeDiff`. Constructed for the writer-bug iteration
	 * loop where running a full Haxe probe + hxml + compile + node would
	 * be 4× slower.
	 *
	 * Default writer is TRIVIA (matches corpus + `--writer-output`).
	 * `--plain` selects the PLAIN writer that matches unit tests of the
	 * form `HxModuleWriter.write(HaxeModuleParser.parse(src))`. Always
	 * probe the pipeline that matches the test entry being constructed.
	 */
	private static function runWriterEquals(args: Array<String>): Int {
		var lang: String = 'haxe';
		var plain: Bool = false;
		var inputPath: Null<String> = null;
		var expectedPath: Null<String> = null;
		var configPath: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--plain':
					plain = true;
				case '--config':
					configPath = expectValue(args, ++i, '--config');
				case '-h', '--help':
					printWriterEqualsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq writer-equals: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (inputPath == null)
						inputPath = a;
					else if (expectedPath == null)
						expectedPath = a;
					else {
						stderr('apq writer-equals: expects exactly two paths (input, expected); got extra "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (inputPath == null || expectedPath == null) {
			stderr('apq writer-equals: missing <input> and/or <expected> argument\n');
			printWriterEqualsUsage();
			return EXIT_USAGE;
		}
		final inputPathFinal: String = inputPath;
		final expectedPathFinal: String = expectedPath;
		final plugin: GrammarPlugin = pickPlugin(lang);
		final source: String = readSourceForParse(inputPathFinal);
		final expected: String = readExpectedForCompare(expectedPathFinal);
		// Config precedence: section-1 from a `.hxtest` input wins (per-
		// fixture intent), fall back to `--config <path>` (project-wide
		// opt-in for plain `.hx` files — dogfood `.hxformat.json` etc.),
		// then plugin defaults.
		final sectionOpts: Null<String> = readWriteOptionsJsonOrNull(inputPathFinal);
		final optsJson: Null<String> = sectionOpts ?? (configPath != null ? readFile(configPath) : null);

		final emitted: Null<String> =
			try (plain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)) catch (e: ParseError) {
				stderr('apq writer-equals: $inputPathFinal: ${e.toString()}\n');
				return EXIT_RUNTIME;
			} catch (e: Exception) {
				stderr('apq writer-equals: $inputPathFinal: ${e.message}\n');
				return EXIT_RUNTIME;
			}
		if (emitted == null) {
			final flagName: String = plain ? '--plain' : '(trivia)';
			stderr('apq writer-equals: no writer wired up for lang "$lang" $flagName\n');
			return EXIT_USAGE;
		}
		if (emitted == expected) return EXIT_OK;
		sysPrint(describeByteDiff(emitted, expected) + '\n');
		return EXIT_RUNTIME;
	}

	/**
	 * Single-line byte-diff describing where `actual` first diverges from
	 * `expected`, with windowed snippets around the divergence point.
	 * Same shape as the corpus harness's `describeDiff` so writer-bug
	 * iteration via `apq writer-equals` reads identical to the corpus
	 * fail line.
	 */
	private static final BYTE_DIFF_WINDOW: Int = 40;

	private static final BYTE_DIFF_LEAD: Int = 4;

	private static function describeByteDiff(actual: String, expected: String): String {
		final maxLen: Int = expected.length < actual.length ? expected.length : actual.length;
		var diffAt: Int = -1;
		for (idx in 0...maxLen) if (StringTools.fastCodeAt(expected, idx) != StringTools.fastCodeAt(actual, idx)) {
			diffAt = idx;
			break;
		}
		if (diffAt == -1) diffAt = maxLen;
		final start: Int = diffAt - BYTE_DIFF_LEAD < 0 ? 0 : diffAt - BYTE_DIFF_LEAD;
		final expWin: String = escapeWindow(expected.substr(start, BYTE_DIFF_WINDOW));
		final actWin: String = escapeWindow(actual.substr(start, BYTE_DIFF_WINDOW));
		return 'apq writer-equals: byte-diff @ $diffAt'
			+ '  exp=<$expWin>' + '  act=<$actWin>' + '  (exp.len=${expected.length}, act.len=${actual.length})';
	}

	private static function escapeWindow(s: String): String {
		final buf: StringBuf = new StringBuf();
		for (idx in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, idx);
			switch c {
				case '\n'.code:
					buf.add('\\n');
				case '\t'.code:
					buf.add('\\t');
				case '\r'.code:
					buf.add('\\r');
				case _:
					buf.addChar(c);
			}
		}
		return buf.toString();
	}

	private static function printWriterEqualsUsage(): Void {
		sysPrint('Usage: apq writer-equals [options] <input> <expected>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --plain             Use the plain (non-trivia) writer (mirrors unit tests)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('  --config <path>     Load writer options from JSON file (hxformat.json-shaped).\n');
		sysPrint('                      Used for plain .hx inputs (dogfood opt-in); a .hxtest section-1\n');
		sysPrint('                      always wins over this flag.\n');
		sysPrint('\n');
		sysPrint('Parse <input>, write through the grammar plugin (trivia pipeline by\n');
		sysPrint('default, plain pipeline with --plain), compare against bytes of <expected>.\n');
		sysPrint('Exit 0 on match, 1 on byte-diff or parse/write failure.\n');
	}

	/**
	 * `apq lit <text> <file-or-dir-or-glob>...` — leaf-name probe over
	 * the parsed AST. Default kind filter `Literal` catches every
	 * string-literal occurrence (the leaf inside `SingleStringExpr`
	 * / `DoubleStringExpr` / `RawString`); pass `--kind <K1,K2>` to
	 * widen (e.g. `Literal,IdentExpr`) or override.
	 *
	 * The structural alternative to `# HXQ_OK:prose`-escaped grep for
	 * annotation-key / config-string lookups inside parseable `.hx`.
	 * Skips comments and string interpolations as a side effect of
	 * routing through the parser — no false positives from prose
	 * inside doc-comments or `'$ident'` interpolation segments.
	 */
	private static function runLit(args: Array<String>): Int {
		final o: LitOpts = parseLitArgs(args);
		if (o.errExit != null) return o.errExit;
		final target: Null<String> = o.target;
		if (target == null) {
			stderr('apq lit: missing <text> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			stderr('apq lit: missing <file-or-dir-or-glob> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		final targetStr: String = target;
		final kindFilter: Null<Array<String>> = o.kindFilter;
		// Resolve smart-default kind filter from <text> shape:
		// `trailOptShapeGate` / `MAX_LEN` / `endsWith_close_brace` look like
		// identifiers, the default `Literal`-only would silently miss the
		// `IdentExpr` / field-name leaves and force a re-run with
		// `--kind Literal,IdentExpr` or `--any-kind`. Promote the default
		// to `Literal,IdentExpr` for queries whose shape is unambiguously
		// an identifier (camelCase: mixed-case letters; snake_case:
		// contains `_` plus letters). Pure-lowercase / all-uppercase single
		// words stay `Literal`-only — they ambiguously match string content
		// and an `IdentExpr` widening would add noise (e.g. `hxq lit 'foo'`
		// inside a corpus of strings).
		final effectiveKindFilter: Array<String> = kindFilter ?? (looksLikeMixedIdentifier(targetStr)
			? ['Literal', 'IdentExpr']
			: ['Literal']);
		// Comment scan fires when the user explicitly opted in (`--include-comments`),
		// when the kind filter is the catch-all (`--any-kind` ⇒ empty array),
		// or when `Comment` appears in an explicit `--kind` list. The
		// default kind filter (smart-resolved Literal or Literal+IdentExpr)
		// deliberately stays comment-free — silent `--include-comments`-by-
		// default would flood doc-comment-heavy queries with noise.
		final scanComments: Bool = o.includeComments || (kindFilter != null && kindFilter.length == 0)
			|| effectiveKindFilter.contains('Comment');
		// `lit` matches DECODED literal values; the raw file holds the
		// ESCAPED form, so a raw-substring pre-filter can false-negative
		// when the searched key carries a backslash. Opt the pre-filter OUT
		// for backslash-bearing keys; for plain keys the decoded value and
		// the raw bytes coincide, so the pre-filter is safe.
		final litPrefilterKey: Null<String> = targetStr.indexOf('\\') < 0 ? targetStr : null;

		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq lit: no input files matched ${o.inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final skipEntries: Array<SkipEntry> = [];
		final collected: Null<{
			entries: Array<{ file: String, source: String, hits: Array<LitHit> }>,
			autoWidened: Bool
		}> = collectLitEntries(paths, plugin, expanded.singleFile, skipEntries, {
			target: targetStr,
			exact: o.exact,
			kinds: effectiveKindFilter,
			kindWasDefault: kindFilter == null,
			scanComments: scanComments,
			prefilterKey: litPrefilterKey
		});
		if (collected == null) return EXIT_RUNTIME;
		final allEntries: Array<{ file: String, source: String, hits: Array<LitHit> }> = collected.entries;

		if (allEntries.length == 0) {
			// DX v10: regex-like query → emit the regex-not-supported note
			// BEFORE the generic walker nudge. The generic nudge's dotted-
			// access heuristic mis-fires on patterns like `foo\|bar` and
			// sends the user toward `search '$x.field'`, which is wrong.
			final regexLabel: Null<String> = looksLikeRegex(targetStr);
			if (regexLabel != null)
				stderr(
					'apq lit: NOTE "$targetStr" looks like a regex (contains $regexLabel) — lit is substring-only. Run separate lit calls per alternative, or use apq refs / apq uses / apq search for shape-aware lookup.\n'
				);
			else
				stderr(emptyWalkerNudge('lit', targetStr, paths.length, paths.length - skipEntries.length, skipEntries, null) + '\n');
		} else if (collected.autoWidened) {
			final tried: String = effectiveKindFilter.join(',');
			stderr(
				'apq lit: NOTE auto-widened to --any-kind (default kind=$tried returned 0 hits). Pass `--any-kind` explicitly to silence this notice.\n'
			);
		}

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = effectiveAutoLimit('lit', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<LitHit> }> =
			limitEntries(
				allEntries, cappedLimit, e -> e.hits.length, (e, k) -> { file: e.file, source: e.source, hits: e.hits.slice(0, k) }
			);
		for (entry in shown) sysPrint(Lit.render(entry.file, entry.source, entry.hits, o.flat));
		return emptyExit(allEntries.length == 0);
	}

	/**
	 * Comment lexer — scans `source` for C-style line comments (`//…`) and
	 * block comments (slash-star and slash-star-star doc forms), filters
	 * by `target`, and appends each match as a `Comment`-kind `LitHit`
	 * to `out`. Captured text is the comment BODY, not including the
	 * delimiters: a `//foo` line yields a body of `foo` (with any leading
	 * space the source happened to carry); a slash-star block yields
	 * everything between the open and close. Substring match by default;
	 * `exact=true` requires `body == target`.
	 *
	 * The lexer is string-literal-aware — `"…"` / `'…'` regions are
	 * skipped so a `//` inside a string does not start a comment match,
	 * and backslash-escaped quotes inside strings stay quoted. The lexer
	 * is grammar-agnostic for C-style comment syntax (Haxe, C/C++, Java,
	 * JavaScript/TypeScript, Rust, Go, Swift, …). Languages with different
	 * comment delimiters (Python `#`, SQL `--`, Lisp `;`) need a plugin-
	 * supplied scanner — deferred until a non-C-style grammar lands.
	 *
	 * UTF-16 unit indexing matches `Span`'s `from`/`to` convention so the
	 * rendered `line:col` resolves via the standard `Span.lineCol(source)`
	 * call without any conversion.
	 */
	private static function appendCommentHits(target: String, source: String, exact: Bool, out: Array<LitHit>): Void {
		for (tok in RefactorSupport.collectCommentTokens(source)) {
			final bodySpan: Span = RefactorSupport.commentBody(source, tok);
			final body: String = source.substring(bodySpan.from, bodySpan.to);
			final match: Bool = exact ? body == target : body.indexOf(target) >= 0;
			if (match) out.push(new LitHit('Comment', body, new Span(tok.from, tok.to)));
		}
	}

	/**
	 * `apq cases <Ctor> <file-or-dir-or-glob>...` — precise case-pattern
	 * lookup. Finds every `case <Ctor>(_):` / `case <Ctor>:` / `case A |
	 * <Ctor>:` shape across the input tree. Solves the "search 'case
	 * Foo(_)' is not a valid pattern" pain — case-patterns are not
	 * parseable as top-level decl/stmt/expr, and `mentions` over-matches
	 * (imports, NewExpr, IdentExpr in non-pattern positions). Walks the
	 * QueryNode tree for `CaseBranch` nodes and emits one hit per
	 * matching pattern slot.
	 */
	private static function runCases(args: Array<String>): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var target: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printCasesUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq cases: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (target == null)
						target = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (target == null) {
			stderr('apq cases: missing <Ctor> argument\n');
			printCasesUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq cases: missing <file-or-dir-or-glob> argument\n');
			printCasesUsage();
			return EXIT_USAGE;
		}
		final targetStr: String = target;

		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq cases: no input files matched ${inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final singleFile: Bool = expanded.singleFile;
		final allEntries: Array<{ file: String, source: String, hits: Array<CasesHit> }> = [];
		final skipEntries: Array<SkipEntry> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('cases', plugin.parseFile, path, source, singleFile, skipEntries, targetStr);
			streamProgress('cases', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final hits: Array<CasesHit> = Cases.find(targetStr, tree);
			if (hits.length == 0) continue;
			allEntries.push({ file: path, source: source, hits: hits });
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('cases', targetStr, paths.length, paths.length - skipEntries.length, skipEntries, null) + '\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = effectiveAutoLimit('cases', limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<CasesHit> }> =
			limitEntries(
				allEntries, cappedLimit, e -> e.hits.length, (e, k) -> { file: e.file, source: e.source, hits: e.hits.slice(0, k) }
			);
		for (entry in shown) sysPrint(Cases.render(entry.file, entry.source, entry.hits, flat));
		return emptyExit(allEntries.length == 0);
	}

	/**
	 * `apq gates [<file-or-dir-or-glob>...]` — list every ctor decl
	 * carrying `@:fmt(trailOptParseGate('<predicate>'))` or
	 * `@:fmt(trailOptShapeGate('<predicate>'))`. THE structural answer
	 * to "which ctors gate their trailing terminator on a runtime
	 * predicate, and what predicate?" — the data you need before
	 * picking a gate-relaxation slice (Slice 30 / 39 pattern). Without
	 * this, the gate predicate is invisible until you grep the grammar
	 * by hand.
	 *
	 * Default scope: `src/anyparse/grammar/<lang>/` when run with no
	 * positional. Otherwise walks every file/dir/glob given.
	 *
	 * Output (per hit, grouped by file):
	 *   <file>:
	 *     <L>:<C>: <DeclKind> <name?> → <gate-call>
	 *
	 * Two recognised gate flavours:
	 *  - `trailOptParseGate('<predicate>')` — drives the runtime gate
	 *    on `@:trailOpt` (parser-side). Predicate lives on
	 *    `HxExprUtil.<predicate>` (or the schema plugin's instance).
	 *  - `trailOptShapeGate('<predicate>')` — drives the writer-side
	 *    decision for `var x = …` rhs and similar.
	 *
	 * Mutually intelligible with `apq meta @:fmt <dir>
	 * --arg-contains trailOptParseGate` — `gates` is the focused view
	 * that extracts just the predicate name and groups by gate flavour.
	 */
	private static function runGates(args: Array<String>): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		// `--mechanism <name>` extends `gates` from its original
		// `trail-opt`-only scope (`@:fmt(trailOptParseGate(...))` /
		// `trailOptShapeGate(...)`) to other Lowering mechanisms whose
		// `--predict-relax`-style relaxation potential we want to
		// inventory ahead of a slice:
		//   - `optional-ref` — fields with `@:optional` + `@:lead` /
		//     `@:kw` / `@:absentOn`. Already-relaxed precedent sites.
		//   - `optional-ref-trail` — Slice 40's new pattern (`@:optional`
		//     + `@:lead` + `@:trail` on a single Ref), used by
		//     `HxAbstractDecl.underlyingType`. THE list of bracket-pair
		//     fields you could optionalize via the Slice 40 mechanism.
		//   - `mandatory-ref-lead-trail` — Ref fields with `@:lead` +
		//     `@:trail` (bracket pair) WITHOUT `@:optional`. The
		//     pre-Slice-40 shape — candidates to relax via Slice 40's
		//     mechanism. THIS IS THE PREDICT-OPTIONAL FALLBACK list.
		//   - `kw-lead` — fields with `@:kw`. Slice precedent for word-
		//     keyword dispatch on a single field.
		// Default value `trail-opt` preserves the bare `gates` output
		// 1:1 (existing tests assume this).
		var mechanism: String = 'trail-opt';
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '--mechanism':
					mechanism = expectValue(args, ++i, '--mechanism');
				case '-h', '--help':
					printGatesUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq gates: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					inputSpecs.push(a);
			}
			i++;
		}
		final validMechanisms: Array<String> = [
			'trail-opt',
			'optional-ref',
			'optional-ref-trail',
			'mandatory-ref-lead-trail',
			'kw-lead'
		];
		if (!validMechanisms.contains(mechanism)) {
			stderr('apq gates: unknown --mechanism "$mechanism" (valid: ${validMechanisms.join(', ')})\n');
			return EXIT_USAGE;
		}
		// Default scope: the grammar tree for the selected lang.
		final effectiveSpecs: Array<String> = inputSpecs.length > 0 ? inputSpecs : ['src/anyparse/grammar/$lang/'];

		final plugin: GrammarPlugin = pickPlugin(lang);
		final shape: MetaShape = plugin.metaShape();
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(effectiveSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq gates: no input files matched ${effectiveSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final singleFile: Bool = expanded.singleFile;
		final skipEntries: Array<SkipEntry> = [];
		final allHits: Array<{ file: String, source: String, hits: Array<GateHit> }> = [];
		var totalHits: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('gates', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw: Array<MetaHit> = Meta.find(tree, shape, source);
			final fileHits: Array<GateHit> = mechanism == 'trail-opt'
				? collectTrailOptHits(raw, source, limit, totalHits)
				: collectMechanismHits(raw, source, mechanism, limit, totalHits);
			totalHits += fileHits.length;
			if (fileHits.length > 0) allHits.push({ file: path, source: source, hits: fileHits });
		}

		if (allHits.length == 0) {
			final what: String = switch mechanism {
				case 'trail-opt':
					'`@:fmt(trailOptParseGate(...))` / `@:fmt(trailOptShapeGate(...))` annotations';
				case 'optional-ref':
					'`@:optional` Ref fields with `@:lead` / `@:kw` / `@:absentOn`';
				case 'optional-ref-trail':
					'`@:optional @:lead @:trail` Ref fields (Slice 40 bracket-pair pattern)';
				case 'mandatory-ref-lead-trail':
					'mandatory Ref fields with `@:lead` + `@:trail` (relax candidates for Slice 40 mechanism)';
				case 'kw-lead':
					'fields with `@:kw`';
				case _: '<unknown mechanism>';
			};
			stderr('apq gates: no $what in ${paths.length} file(s) scanned\n');
			return EXIT_OK;
		}

		for (entry in allHits) {
			if (!flat) sysPrint('${entry.file}:\n');
			for (h in entry.hits) {
				final declLabel: String = h.declName == null ? h.declKind : '${h.declKind} ${h.declName}';
				final prefix: String = flat ? '${entry.file}:${h.line}:${h.col}: ' : '  ${h.line}:${h.col}: ';
				// trail-opt format preserved 1:1 for backwards-compat:
				// `<DeclKind> <name?> → trailOptParseGate('<pred>')`.
				// Other mechanisms render `<DeclKind> <name?> → <metas>`
				// where `<metas>` is the relevant subset of `@:` annotations
				// already-quoted in `predicate` (raw string from classifier).
				final tail: String = mechanism == 'trail-opt' ? '${h.gateKind}(\'${h.predicate}\')' : h.predicate;
				sysPrint('$prefix$declLabel → $tail\n');
			}
		}
		return EXIT_OK;
	}

	/**
	 * Original trail-opt walker — extracted from `runGates` body to
	 * peer with `collectMechanismHits` under the `--mechanism` switch.
	 * Iterates raw MetaHits one at a time and pushes one `GateHit` per
	 * matching `@:fmt(trailOpt*Gate(...))` argument; preserves the
	 * pre-`--mechanism` output and limit semantics.
	 */
	private static function collectTrailOptHits(raw: Array<MetaHit>, source: String, limit: Int, sharedTotal: Int): Array<GateHit> {
		final out: Array<GateHit> = [];
		for (h in raw) if (h.annotation == '@:fmt') for (arg in h.args) {
			final extracted: Null<GateExtract> = extractGate(arg);
			if (extracted == null) continue;
			if (limit >= 0 && sharedTotal + out.length >= limit) break;
			out.push({
				line: h.declSpan != null ? h.declSpan.lineCol(source).line : 0,
				col: h.declSpan != null ? h.declSpan.lineCol(source).col : 0,
				declKind: h.declKind,
				declName: h.declName,
				gateKind: extracted.gateKind,
				predicate: extracted.predicate,
			});
		}
		return out;
	}

	/**
	 * Bucket raw MetaHits by their `declSpan.from` — one bucket per
	 * field / branch / ctor that carries annotations. Returns the
	 * grouping map plus a parallel `order` array that preserves
	 * first-seen source order so downstream emitters render in file
	 * layout, not Map iteration order.
	 *
	 * Shared by `collectMechanismHits` (gates --mechanism) and
	 * `collectPermissiveCandidates` (recon --permissive-construct).
	 * Both consumers need the same grouping shape; factoring it out
	 * keeps the bucket-build logic single-sourced.
	 */
	private static function groupMetaHitsByDeclSpan(raw: Array<MetaHit>): { order: Array<Int>, groups: Map<Int, Array<MetaHit>> } {
		final order: Array<Int> = [];
		final groups: Map<Int, Array<MetaHit>> = [];
		for (h in raw) {
			final span: Null<Span> = h.declSpan;
			if (span == null) continue;
			final key: Int = span.from;
			var bucket: Null<Array<MetaHit>> = groups[key];
			if (bucket == null) {
				bucket = [];
				groups[key] = bucket;
				order.push(key);
			}
			bucket.push(h);
		}
		return { order: order, groups: groups };
	}

	/**
	 * `--mechanism <name>` walker. Groups raw MetaHits by their decl-host
	 * span (one group = all annotations on a single field / branch /
	 * ctor) and classifies each group by the requested mechanism's
	 * meta-set signature. Output's `predicate` field carries the
	 * rendered metas string (NOT a quoted symbol — the trail-opt
	 * formatter is bypassed via the `mechanism != 'trail-opt'` branch
	 * in the caller). Groups are emitted in source-order so the report
	 * matches the file layout.
	 */
	private static function collectMechanismHits(
		raw: Array<MetaHit>, source: String, mechanism: String, limit: Int, sharedTotal: Int
	): Array<GateHit> {
		final grouped: { order: Array<Int>, groups: Map<Int, Array<MetaHit>> } = groupMetaHitsByDeclSpan(raw);
		final out: Array<GateHit> = [];
		for (key in grouped.order) {
			if (limit >= 0 && sharedTotal + out.length >= limit) break;
			final metas: Null<Array<MetaHit>> = grouped.groups[key];
			if (metas == null) continue;
			final label: Null<String> = classifyMechanism(metas, mechanism);
			if (label == null) continue;
			final first: MetaHit = metas[0];
			final fspan: Null<Span> = first.declSpan;
			out.push({
				line: fspan != null ? fspan.lineCol(source).line : 0,
				col: fspan != null ? fspan.lineCol(source).col : 0,
				declKind: first.declKind,
				declName: first.declName,
				gateKind: '', // unused for non-trail-opt mechanisms
				predicate: (label: String),
			});
		}
		return out;
	}

	/**
	 * Mechanism classifier — returns the rendered metas label when the
	 * meta set on a single decl/field matches the requested mechanism's
	 * signature, `null` otherwise. The label is the small list of
	 * `@:annotation(...)` tokens that drive the mechanism, joined with
	 * single spaces — same shape a grammar author would see in the
	 * source. `@:fmt(...)` flags are NOT included (they're orthogonal
	 * to the mechanism dispatch); the label focuses on the parser-side
	 * structural metas.
	 */
	private static function classifyMechanism(metas: Array<MetaHit>, mechanism: String): Null<String> {
		var hasOptional: Bool = false;
		var lead: Null<String> = null;
		var trail: Null<String> = null;
		var kw: Null<String> = null;
		var absentOn: Null<String> = null;
		var sep: Null<String> = null;
		for (h in metas) switch h.annotation {
			case '@:optional':
				hasOptional = true;
			case '@:lead':
				lead = h.args.length > 0 ? h.args[0] : null;
			case '@:trail':
				trail = h.args.length > 0 ? h.args[0] : null;
			case '@:kw':
				kw = h.args.length > 0 ? h.args[0] : null;
			case '@:absentOn':
				absentOn = h.args.length > 0 ? h.args[0] : null;
			case '@:sep':
				sep = h.args.length > 0 ? h.args[0] : null;
			case _:
		}
		return switch mechanism {
			case 'optional-ref':
				if (!hasOptional)
					null
				else if (lead == null && kw == null && absentOn == null)
					null
				// Star fields with @:sep are excluded — they're the angle-
				// bracket array shape, not single Ref optional. Inspect
				// declName / declKind manually if you need both.
				else if (sep != null)
					null
				else
					renderMetaList(hasOptional, kw, lead, trail, absentOn);
			case 'optional-ref-trail':
				// Slice 40's exact signature: optional + lead + trail, no sep.
				if (hasOptional && lead != null && trail != null && sep == null)
					renderMetaList(hasOptional, kw, lead, trail, absentOn);
				else
					null;
			case 'mandatory-ref-lead-trail':
				// Pre-Slice-40 shape on a single Ref — the predict-optional
				// fallback candidates (turn `@:lead + @:trail` into
				// `@:optional @:lead + @:trail`). Exclude Star (`@:sep`)
				// — angle-bracket arrays are not the target.
				if (!hasOptional && lead != null && trail != null && sep == null)
					renderMetaList(hasOptional, kw, lead, trail, absentOn);
				else
					null;
			case 'kw-lead':
				if (kw != null)
					renderMetaList(hasOptional, kw, lead, trail, absentOn)
				else
					null;
			case _: null;
		};
	}

	private static function renderMetaList(
		hasOptional: Bool, kw: Null<String>, lead: Null<String>, trail: Null<String>, absentOn: Null<String>
	): String {
		final parts: Array<String> = [];
		if (hasOptional) parts.push('@:optional');
		if (kw != null) parts.push('@:kw($kw)');
		if (lead != null) parts.push('@:lead($lead)');
		if (trail != null) parts.push('@:trail($trail)');
		if (absentOn != null) parts.push('@:absentOn($absentOn)');
		return parts.join(' ');
	}

	/**
	 * Parse `trailOptParseGate('<pred>')` or `trailOptShapeGate('<pred>')`
	 * out of a single `@:fmt` argument string. Returns `null` if the
	 * arg isn't a gate call — `@:fmt(...)` carries many other flags
	 * (`tightLead`, `wrapRules(...)`, `bodyPolicy(...)`, …) which
	 * `gates` deliberately ignores. Hand-rolled parser to keep the
	 * walker independent of the format/wrap plugin types.
	 */
	private static function extractGate(arg: String): Null<GateExtract> {
		final trimmed: String = StringTools.trim(arg);
		final markers: Array<String> = ['trailOptParseGate', 'trailOptShapeGate'];
		for (m in markers) if (StringTools.startsWith(trimmed, m)) {
			final after: String = StringTools.trim(trimmed.substr(m.length));
			if (!StringTools.startsWith(after, '(')) continue;
			final inner: String = StringTools.trim(after.substring(1, after.lastIndexOf(')')));
			// `trailOptShapeGate` takes multiple args (`'endsWithCloseBrace', 'init'`);
			// extract just the FIRST quoted string — that's the predicate
			// method name on the schema instance. Subsequent args are
			// flag-bearing (typically a field-name selector) and not part
			// of the predicate identity.
			final firstArg: String = sliceFirstQuotedArg(inner);
			final stripped: String = stripQuotes(firstArg);
			if (stripped.length == 0) continue;
			return { gateKind: m, predicate: stripped };
		}
		return null;
	}

	/**
	 * Pick the first comma-separated argument from a paren-list body.
	 * Quote-aware: a comma INSIDE a `'…'` / `"…"` doesn't terminate the
	 * arg. Returns the trimmed first segment; the whole string when no
	 * top-level comma exists.
	 */
	private static function sliceFirstQuotedArg(inner: String): String {
		var inSingle: Bool = false;
		var inDouble: Bool = false;
		for (i in 0...inner.length) {
			final c: Int = StringTools.fastCodeAt(inner, i);
			if (!inDouble && c == "'".code)
				inSingle = !inSingle;
			else if (!inSingle && c == '"'.code)
				inDouble = !inDouble;
			else if (!inSingle && !inDouble && c == ','.code) return StringTools.trim(inner.substring(0, i));
		}
		return StringTools.trim(inner);
	}

	private static inline function stripQuotes(s: String): String {
		final t: String = StringTools.trim(s);
		if (t.length < 2) return t;
		final first: String = t.charAt(0);
		final last: String = t.charAt(t.length - 1);
		return (first == "'" && last == "'") || (first == '"' && last == '"') ? t.substring(1, t.length - 1) : t;
	}

	private static function printGatesUsage(): Void {
		sysPrint('Usage: apq gates [<file-or-dir-or-glob>...] [--flat] [--limit N] [--mechanism <name>]\n');
		sysPrint('\n');
		sysPrint('Default (--mechanism trail-opt): list ctor decls carrying\n');
		sysPrint('`@:fmt(trailOptParseGate(\'<pred>\'))` / `trailOptShapeGate(\'<pred>\')` and\n');
		sysPrint('the predicate name they dispatch. Pre-`--mechanism` output 1:1.\n');
		sysPrint('\n');
		sysPrint('Other --mechanism values inventory grammar surface by Lowering pattern:\n');
		sysPrint('  optional-ref          — `@:optional` Ref fields with @:lead/@:kw/@:absentOn\n');
		sysPrint('                          (already-relaxed precedent sites).\n');
		sysPrint('  optional-ref-trail    — `@:optional @:lead @:trail` Ref bracket-pair\n');
		sysPrint('                          (Slice 40 mechanism — current consumers).\n');
		sysPrint('  mandatory-ref-lead-trail\n');
		sysPrint('                        — mandatory Ref with @:lead+@:trail (no @:optional).\n');
		sysPrint('                          THE predict-optional fallback candidate list —\n');
		sysPrint('                          fields you could relax via Slice 40\'s mechanism.\n');
		sysPrint('  kw-lead               — fields with @:kw (keyword-dispatched).\n');
		sysPrint('\n');
		sysPrint('Default scope: src/anyparse/grammar/<lang>/ (haxe by default).\n');
	}

	private static function printCasesUsage(): Void {
		sysPrint('Usage: apq cases <Ctor> <file-or-dir-or-glob>... [--flat] [--limit N]\n');
		sysPrint('\n');
		sysPrint('Match every switch case-pattern whose top-level ctor is <Ctor>:\n');
		sysPrint('  case Ctor:           case Ctor(_):         case A | Ctor:\n');
		sysPrint('\n');
		sysPrint('Use when `search \'case Foo(_)\'` rejects the pattern and `mentions` over-\n');
		sysPrint('matches (imports / NewExpr / IdentExpr in non-pattern positions).\n');
	}

	/**
	 * `apq blast <type-name> <file-or-dir-or-glob>...` — typedef→enum (or
	 * any type-shape) change-impact checklist. Unions three signals the
	 * lone `uses`/`refs` queries each miss:
	 *
	 *  - `uses` — type-position references (field/param/type-param).
	 *  - `refs` — value-binding references (var/fn/param named the type).
	 *  - heuristic field-access — `expr.member` sites whose member name
	 *    matches a member of the type's own declaration. This is the
	 *    signal `uses`/`refs` are STRUCTURALLY blind to (a `.field`
	 *    access on a value of the type is neither a type position nor a
	 *    value binding) — exactly what was missed assessing a
	 *    typedef→enum blast. Name-based ⇒ a deliberate SUPERSET: it
	 *    over-matches any `.member` with the same identifier. It is a
	 *    verify-each checklist, not a precise result (precise would need
	 *    type inference, which `apq` deliberately does not do).
	 *
	 * The heuristic needs the type's declaration in the scanned set to
	 * learn its member names; if absent, that section is skipped with a
	 * note (the precise `uses`/`refs` sections still print).
	 */
	private static function runBlast(args: Array<String>): Int {
		final o: BlastOpts = parseBlastArgs(args);
		if (o.errExit != null) return o.errExit;
		final name: Null<String> = o.name;
		if (name == null) {
			stderr('apq blast: missing <type-name> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			stderr('apq blast: missing <file-or-dir-or-glob> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		final typeName: String = name;

		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final refShape: RefShape = plugin.refShape();
		final typeShape: TypeRefShape = plugin.typeRefShape();

		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq blast: no input files matched ${o.inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		// Pass 1: learn the type's member names + the spans of its own
		// declaration(s) (to exclude the decl's internals from the
		// heuristic). Walks the value-AST of every file once; cached for
		// the section passes below. NOT pre-filtered on `typeName`: the
		// heuristic field-access section matches MEMBER names, which can
		// occur in files that never name the type textually
		// (`obj.someField` with no mention of the type).
		final memberNames: Array<String> = [];
		final declSpans: Array<Span> = [];
		final valueTrees: Array<{ path: String, source: String, tree: QueryNode }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('blast', plugin.parseFile, path, source, expanded.singleFile);
			streamProgress('blast', ++scanned, paths.length, expanded.singleFile);
			if (tree == null) {
				if (expanded.singleFile) return EXIT_RUNTIME;
				continue;
			}
			valueTrees.push({ path: path, source: source, tree: tree });
			collectTypeDecl(tree, typeName, memberNames, declSpans);
		}

		var any: Bool = false;
		// Section 1 — type-position references (precise). Section 2 —
		// value-binding references (precise). Section 3 — heuristic
		// member-name field-access (superset). Order is fixed (precise
		// before heuristic); each section returns whether it printed a hit.
		if (blastUsesSection(valueTrees, typeName, typeShape, plugin, expanded.singleFile, o.flat)) any = true;
		if (blastRefsSection(valueTrees, typeName, refShape, o.flat)) any = true;

		if (memberNames.length == 0) {
			stderr(
				'apq blast: no declaration of "$typeName" in the scanned set — '
				+ 'heuristic field-access section skipped (uses/refs above are complete).\n'
			);
			if (!any) stderr('apq blast: no uses / refs of "$typeName" found\n');
			return emptyExit(!any);
		}
		if (blastHeuristicSection(valueTrees, memberNames, declSpans, typeName, o.showAll, o.limit)) any = true;

		if (!any) stderr('apq blast: no uses / refs / member-access of "$typeName" found\n');
		return emptyExit(!any);
	}

	/**
	 * `apq mentions <name> <file-or-dir-or-glob>...` — every named-leaf
	 * occurrence of an identifier. Unions three precise queries:
	 *
	 *  - `uses` — type-position references (field/param/return/extends).
	 *  - `refs` — value-binding references (var/fn/param of that name).
	 *  - `lit --any-kind --exact` — every other leaf carrying that name:
	 *    case-patterns (`case Foo(_):` → `IdentExpr 'Foo'`), import path
	 *    segments, `new Foo()` ctor calls, field-name slots.
	 *
	 * The "everything called X" question. Complementary to `blast`:
	 * `blast` answers "what could break when I change type T's shape"
	 * via a name-based field-access SUPERSET; `mentions` answers "where
	 * is the literal token X tokenised in the AST" precisely. No
	 * heuristic — every section is structural and exact-name. Use this
	 * when refs/uses/blast all return 0 but you know the name appears
	 * (case-patterns are the canonical example).
	 */
	private static function runMentions(args: Array<String>): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var name: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printMentionsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq mentions: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null)
						name = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq mentions: missing <name> argument\n');
			printMentionsUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq mentions: missing <file-or-dir-or-glob> argument\n');
			printMentionsUsage();
			return EXIT_USAGE;
		}
		final target: String = name;

		final plugin: GrammarPlugin = pickPlugin(lang);
		final refShape: RefShape = plugin.refShape();
		final typeShape: TypeRefShape = plugin.typeRefShape();

		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq mentions: no input files matched ${inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		// Single value-AST pass per file, shared across all three sections.
		// Mirrors `runBlast`'s caching discipline. All three sections
		// (uses / refs / lit-exact) search for `target` verbatim, so the
		// raw-substring pre-filter is a strict necessary condition.
		// Section 3 (`lit`) matches decoded literal values, so the key is
		// opted out of the pre-filter when it carries a backslash — same
		// escaped-literal caution as `runLit`.
		final mentionsPrefilterKey: Null<String> = target.indexOf('\\') < 0 ? target : null;
		final valueTrees: Array<{ path: String, source: String, tree: QueryNode }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked(
				'mentions', plugin.parseFile, path, source, expanded.singleFile, null, mentionsPrefilterKey
			);
			streamProgress('mentions', ++scanned, paths.length, expanded.singleFile);
			if (tree == null) {
				if (expanded.singleFile) return EXIT_RUNTIME;
				continue;
			}
			valueTrees.push({ path: path, source: source, tree: tree });
		}

		var any: Bool = false;

		// Section 1 — type-position references (precise). The type-refs
		// re-parse is pre-filtered on `target` (a type position always
		// names the type verbatim).
		var usesHeader: Bool = false;
		for (entry in valueTrees) {
			final typeTree: Null<QueryNode> = parseWalked(
				'mentions', plugin.parseFileTypeRefs, entry.path, entry.source, expanded.singleFile, null, target
			);
			if (typeTree == null) continue;
			final hits: Array<UsesHit> = Uses.find(target, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!usesHeader) {
				sysPrint('# uses (type positions)\n');
				usesHeader = true;
			}
			sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false, flat));
		}

		// Section 2 — value-binding references (precise).
		var refsHeader: Bool = false;
		for (entry in valueTrees) {
			final hits: Array<RefHit> = Refs.find(target, entry.tree, refShape);
			if (hits.length == 0) continue;
			any = true;
			if (!refsHeader) {
				sysPrint('# refs (value bindings)\n');
				refsHeader = true;
			}
			sysPrint(Text.renderRefs(entry.path, entry.source, hits, false, false, flat));
		}

		// Section 3 — every other leaf carrying this name (case-patterns,
		// imports, new exprs, field-name slots). `lit` with empty kind
		// filter + exact match. `--limit` caps this section only — the
		// precise refs/uses sections are typically small.
		final litEntries: Array<{ file: String, source: String, hits: Array<LitHit> }> = [];
		for (entry in valueTrees) {
			final hits: Array<LitHit> = Lit.find(target, entry.tree, true, null);
			if (hits.length == 0) continue;
			litEntries.push({ file: entry.path, source: entry.source, hits: hits });
		}
		if (litEntries.length > 0) {
			any = true;
			var totalHits: Int = 0;
			for (e in litEntries) totalHits += e.hits.length;
			final cappedLimit: Int = effectiveAutoLimit('mentions', limit, totalHits);
			final shown: Array<{ file: String, source: String, hits: Array<LitHit> }> =
				limitEntries(
					litEntries, cappedLimit, e -> e.hits.length, (e, k) -> { file: e.file, source: e.source, hits: e.hits.slice(0, k) }
				);
			sysPrint('# lit (every leaf — case-patterns / imports / new exprs / field-name slots)\n');
			for (entry in shown) sysPrint(Lit.render(entry.file, entry.source, entry.hits, flat));
		}

		if (!any) stderr('apq mentions: no uses / refs / lit-leaf of "$target" found\n');
		return emptyExit(!any);
	}

	/**
	 * Collect the member names + declaration spans of every top-level
	 * declaration named `typeName` (kind ends in `Decl` — the Haxe
	 * decl-kind convention). `@:meta` / `@:fmt(...)` argument subtrees
	 * are skipped so meta identifiers don't pollute the member set.
	 */
	private static function collectTypeDecl(node: QueryNode, typeName: String, names: Array<String>, declSpans: Array<Span>): Void {
		if (StringTools.endsWith(node.kind, 'Decl') && node.name == typeName) {
			if (node.span != null) declSpans.push(node.span);
			collectMemberNames(node, typeName, names);
			return;
		}
		for (c in node.children) collectTypeDecl(c, typeName, names, declSpans);
	}

	private static function collectMemberNames(node: QueryNode, typeName: String, names: Array<String>): Void {
		if (node.kind == 'Meta' || node.kind == 'MetaCall') return;
		final n: Null<String> = node.name;
		if (n != null && n != typeName && !names.contains(n)) names.push(n);
		for (c in node.children) collectMemberNames(c, typeName, names);
	}

	/**
	 * Walk for `FieldAccess` nodes whose accessed member name is one of
	 * `names`, excluding any inside a declaration-of-type span. Records
	 * a `file:line:col` line per hit.
	 */
	private static function collectMemberAccess(
		node: QueryNode, names: Array<String>, declSpans: Array<Span>, file: String, source: String,
		out: Array<{ loc: String, line: String }>
	): Void {
		if (node.kind == 'FieldAccess') {
			final n: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (n != null && span != null && names.contains(n) && !spanInsideAny(span, declSpans)) {
				final pos: Position = span.lineCol(source);
				final loc: String = '$file:${pos.line}:${pos.col}';
				out.push({ loc: loc, line: '$loc: .$n' });
			}
		}
		for (c in node.children) collectMemberAccess(c, names, declSpans, file, source, out);
	}

	private static function spanInsideAny(span: Span, outer: Array<Span>): Bool {
		for (o in outer) if (o.from <= span.from && span.to <= o.to) return true;
		return false;
	}

	private static function argMatches(args: Array<String>, sub: Null<String>): Bool {
		if (sub == null) return true;
		final needle: String = sub;
		for (a in args) if (a.indexOf(needle) >= 0) return true;
		return false;
	}

	/**
	 * Split the tag off an `@:tag(arg)` annotation positional. Returns the
	 * leading `@:tag` (trimmed, sans any `(...)` suffix); the historical
	 * bare `@:tag` form passes through unchanged.
	 */
	private static function annotationTag(annotation: String): String {
		final parenIdx: Int = annotation.indexOf('(');
		return StringTools.trim(parenIdx < 0 ? annotation : annotation.substring(0, parenIdx));
	}

	/**
	 * Extract the inline arg filter from an `@:tag(arg)` annotation
	 * positional — the text between the first `(` and the matching last
	 * `)`, trimmed. Returns `null` when the annotation has no `(...)`
	 * suffix (no arg filter) or when the parens are empty.
	 */
	private static function annotationArgFilter(annotation: String): Null<String> {
		final parenIdx: Int = annotation.indexOf('(');
		if (parenIdx < 0) return null;
		final closeIdx: Int = annotation.lastIndexOf(')');
		final raw: String = closeIdx > parenIdx ? annotation.substring(parenIdx + 1, closeIdx) : '';
		final trimmed: String = StringTools.trim(raw);
		return trimmed.length == 0 ? null : trimmed;
	}

	/**
	 * Precise inline arg filter (`@:tag(arg)`): keep a hit only when one of
	 * its TOP-LEVEL meta args is either the bare ident `arg` OR a call
	 * `arg(...)` (callee match). This is the structural counterpart to the
	 * `--arg-contains` substring scan — `propagateExprPosition` matches a
	 * `propagateExprPosition` arg but NOT a `myPropagateExprPositionExtra`
	 * one. `filter == null` is "no inline arg filter" (every hit passes).
	 */
	private static function argFilterMatches(args: Array<String>, filter: Null<String>): Bool {
		if (filter == null) return true;
		final needle: String = filter;
		for (a in args) {
			final arg: String = StringTools.trim(a);
			if (arg == needle) return true;
			if (StringTools.startsWith(arg, '$needle(')) return true;
		}
		return false;
	}

	private static inline function kindAllowed(k: RefKind, decls: Bool, reads: Bool, writes: Bool): Bool {
		return switch k {
			case Decl: decls;
			case Read: reads;
			case Write: writes;
		}
	}

	private static function runSearch(args: Array<String>): Int {
		final o: SearchOpts = parseSearchArgs(args);
		if (o.errExit != null) return o.errExit;
		final pattern: Null<String> = o.pattern;
		if (pattern == null) {
			stderr('apq search: missing <pattern> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			stderr('apq search: missing <file-or-dir-or-glob> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		final patternStr: String = pattern;

		// DX v10: macro reification (`$v{...}` / `$i{...}` / `$a{...}` /
		// `$b{...}` / `$p{...}` / `$e{...}` / `$es{...}`) is a Haxe macro-
		// time construct, not an AST shape — the pattern parser rejects it
		// with a generic "not valid as expression" message that sends the
		// user toward search debugging instead of `lit` (the right tool
		// for literal-string lookup, where the macro-time string slot lives).
		// Detect the sigil before parsing and point at the right tool.
		final reif: Null<String> = detectMacroReification(patternStr);
		if (reif != null) {
			stderr(
				'apq search: pattern "$patternStr" contains macro reification ($reif) which is a macro-time construct, not an AST shape pattern. For literal-string lookup use: apq lit \'<text>\' <files>. For identifier shape patterns use a metavar `$$x` (lowercase).\n'
			);
			return EXIT_USAGE;
		}

		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final parsed: Pattern = try plugin.parsePattern(patternStr) catch (e: Exception) {
			stderr('apq search: pattern: ${e.message}\n');
			return EXIT_RUNTIME;
		};

		// Non-fatal: a leaf pattern (bare name / lone metavar / bare
		// literal) has no code shape — search only hits it in
		// expression position, never a decl or type. Point at the
		// right tool (kind-aware) and proceed anyway.
		//
		// Kind branches:
		//  - Metavar           — lone `$x` matches every node; refs/uses
		//                        don't apply (no name to look up).
		//  - Literal / *Lit    — literal value; `apq lit '<value>'` is
		//                        the right tool (refs/uses don't apply).
		//  - IdentExpr / other — bare identifier; refs/uses/lit all
		//                        plausible depending on intent.
		if (parsed.isDegenerate()) stderr(degenerateNudge(patternStr, parsed.root.kind) + '\n');

		// `--explain`: emit the parsed pattern's S-expr to stderr at
		// scan start. When 0 matches across all scanned files the
		// closing diagnostic also prints the top input-kind histogram
		// — the most common reason a structurally-valid pattern misses
		// is a kind mismatch (e.g. searching `switch $x { … }` against
		// a tree whose actual kind is `SwitchExpr`, not `Switch`).
		if (o.explain) {
			stderr('apq search: pattern parses as:\n');
			stderr(Text.render(parsed.root));
		}

		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq search: no input files matched ${o.inputSpecs.join(' ')}\n');
			return EXIT_RUNTIME;
		}

		final collected: Null<{
			entries: Array<{ file: String, source: String, matches: Array<Match> }>,
			kindCounts: Map<String, Int>
		}> = collectSearchEntries(paths, plugin, expanded.singleFile, parsed, o.kind, o.explain);
		if (collected == null) return EXIT_RUNTIME;
		final allEntries: Array<{ file: String, source: String, matches: Array<Match> }> = collected.entries;

		// `--explain` closing diagnostic on 0 hits: print the kind
		// histogram so the user can see whether the pattern's root
		// kind even appears in the scanned input.
		if (o.explain && allEntries.length == 0) searchExplainHistogram(parsed.root.kind, collected.kindCounts);

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.matches.length;
		final cappedLimit: Int = effectiveAutoLimit('search', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, matches: Array<Match> }> =
			limitEntries(
				allEntries, cappedLimit, e -> e.matches.length,
				(e, k) -> { file: e.file, source: e.source, matches: e.matches.slice(0, k) }
			);
		renderSearchResults(shown, o.json, o.flat);
		return emptyExit(allEntries.length == 0);
	}

	private static function perMatchJson(file: String, source: String, m: Match): String {
		// Render a single match through the macro-generated writer by
		// wrapping it in a singleton envelope, then slicing the inner
		// JSON object out. Keeps every entry typed through the same path
		// as the multi-match render — no separate stringify code.
		final rendered: String = Json.renderSearchMatches(file, source, [m]);
		// Strip the `{"matches":[` prefix and `]}\n` suffix to get the
		// bare match object for inclusion in the multi-file array.
		final inner: String = StringTools.trim(rendered);
		final openIdx: Int = inner.indexOf('[');
		final closeIdx: Int = inner.lastIndexOf(']');
		return openIdx < 0 || closeIdx <= openIdx ? rendered : inner.substring(openIdx + 1, closeIdx);
	}

	private static function runAst(args: Array<String>): Int {
		final o: AstOpts = parseAstArgs(args);
		if (o.errExit != null) return o.errExit;

		// Source resolution: --code wins, then --stdin, then the file arg.
		// Exactly one of the three must be set.
		final sourceProvidersSet: Int = (o.codeArg != null ? 1 : 0) + (o.stdinFlag ? 1 : 0) + (o.file != null ? 1 : 0);
		if (sourceProvidersSet == 0) {
			stderr('apq ast: missing <file>, --code <s>, or --stdin\n');
			printAstUsage();
			return EXIT_USAGE;
		}
		if (sourceProvidersSet > 1) {
			stderr('apq ast: <file>, --code, and --stdin are mutually exclusive\n');
			return EXIT_USAGE;
		}
		final plugin: GrammarPlugin = pickPlugin(o.lang);
		// Capture nullable struct fields into locals so Strict narrows them;
		// the source/label resolution then branches once and narrows `file`
		// in its own arm. File label drives error / hit-location prefixes —
		// <probe> / <stdin> are distinct so a `probe` call still looks like a
		// probe in emitted diff headers and errors. The trailing throw is the
		// provably-unreachable arm (the mutex above proved exactly one set);
		// `var` is required because the value is assigned per-branch.
		final codeArg: Null<String> = o.codeArg;
		final file: Null<String> = o.file;
		var source: String;
		var fileLabel: String;
		if (codeArg != null) {
			source = codeArg;
			fileLabel = '<probe>';
		} else if (o.stdinFlag) {
			source = readStdin();
			fileLabel = '<stdin>';
		} else if (file != null) {
			source = readSourceForParse(file);
			fileLabel = file;
		} else
			throw new Exception('apq ast: no source provider after mutex check (unreachable)');

		// `--writer-output`: parse + format-write through the plugin's
		// round-trip pipeline. Independent of --select / --at / --json /
		// --depth / --doc / --source — emits the formatted source to stdout
		// and exits. Used for fast writer-bug iteration (a single command
		// vs full test runner round-trip).
		//
		// `--writer-output --diff`: instead of printing the emitted source,
		// parse it back and structurally AST-diff against the parsed input.
		// THE writer-bug iteration loop: see structurally what the writer
		// added / removed / reshaped in one shot, without a second `hxq diff`
		// call. Exit non-zero when the writer output fails to re-parse
		// (writer produced syntactically broken Haxe).
		if (o.writerOutput) return runAstWriterOutput(plugin, source, file, fileLabel, o.lang, o.writerOutputPlain, o.writerDiff);
		if (o.writerDiff) {
			stderr('apq ast: --diff requires --writer-output (it diffs input vs writer-emitted output)\n');
			return EXIT_USAGE;
		}

		final tree: QueryNode = try plugin.parseFile(source) catch (e: ParseError) {
			stderr('apq ast: $fileLabel: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			stderr('apq ast: $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		final atExpr: Null<String> = o.atExpr;
		if (atExpr != null) return runAstAt(o, atExpr, tree, source, fileLabel);

		final selectExpr: Null<String> = o.selectExpr;
		if (selectExpr != null) return runAstSelect(o, selectExpr, tree, source, fileLabel, plugin);

		if (o.countOnly) {
			sysPrint('${tree.children.length}\n');
			return EXIT_OK;
		}
		final shaped: QueryNode = shapeAstOutput(tree, o.depth, o.childrenLimit);
		sysPrint(o.json ? Json.renderTree(fileLabel, source, shaped) : Text.render(shaped, o.spans));
		return EXIT_OK;
	}

	/**
	 * Apply `--depth N` then `--children-limit N` shaping in one place.
	 * Depth truncate first (cheaper — drops sub-trees wholesale), then
	 * per-level child cap on what remains. Both clamps are optional;
	 * negative inputs are no-ops.
	 */
	private static function shapeAstOutput(node: QueryNode, depth: Int, childrenLimit: Int): QueryNode {
		var out: QueryNode = depth < 0 ? node : Engine.truncate(node, depth);
		if (childrenLimit >= 0) out = Engine.truncateChildren(out, childrenLimit);
		return out;
	}

	/**
	 * `apq probe '<code>' [ast-options]` — micro-AST probe with inline
	 * source. Replaces the Write→hxq scratch-file dance for 3-5 line
	 * code snippets: `hxq probe 'class C{function f(){…}}' --depth 5`
	 * is byte-equivalent to `hxq ast --code 'class C{…}' --depth 5`
	 * but reads as the call site of a probe, not as an ast inspection
	 * of a file that doesn't exist.
	 *
	 * Accepts every `apq ast` flag (`--depth`, `--select`, `--at`,
	 * `--json`, `--writer-output`, `--writer-output-plain`,
	 * `--writer-output --diff`, `--min-children`, `--max-children`).
	 * Pass `-` as the code argument to read source from stdin instead
	 * — useful when the snippet has shell-quoting trouble or comes
	 * from a heredoc / process substitution.
	 */
	private static function runProbe(args: Array<String>): Int {
		// Bare `apq probe` → usage. Doing the check up front (before the
		// argv walker) keeps the empty-args branch return 0, matching
		// the convention of `apq <cmd>` (no args) elsewhere.
		if (args.length == 0) {
			printProbeUsage();
			return EXIT_OK;
		}
		// The `hxq` shim auto-injects `--lang haxe` after the subcommand,
		// so the code arg is NOT always at args[0]. Walk the array and
		// pick the FIRST non-flag positional (skipping every `--flag`
		// AND its value-bearing successor). All flags are forwarded to
		// `runAst` verbatim; the positional becomes `--code <s>` (or
		// switches to `--stdin` when literal `-`).
		var codeArg: Null<String> = null;
		final forwarded: Array<String> = [];
		// `--writer-probe` is a probe-only flag that diverts the source to
		// `runWriterProbe`'s trivia+plain side-by-side emitter instead of
		// the default `runAst` path. Lives here (not in `runAst`'s flag
		// set) because writer-probe is a multi-pipeline aggregator with
		// no `--depth` / `--select` knobs to compose with. `--lang` IS
		// forwarded because `pickPlugin` needs it.
		var writerProbeMode: Bool = false;
		var lang: String = 'haxe';
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			if (a == '-h' || a == '--help') {
				printProbeUsage();
				return EXIT_OK;
			}
			if (a == '--writer-probe') {
				writerProbeMode = true;
				i++;
				continue;
			}
			if (a == '--lang') {
				lang = expectValue(args, ++i, '--lang');
				forwarded.push('--lang');
				forwarded.push(lang);
				i++;
				continue;
			}
			if (StringTools.startsWith(a, '--')) {
				forwarded.push(a);
				// Forward the option's value too. Boolean flags like
				// `--json` / `--stdin` / `--writer-output` consume no
				// value — track them by name so we don't eat the code
				// positional. Anything else is value-bearing per `runAst`.
				if (!isAstBoolFlag(a) && i + 1 < args.length) {
					forwarded.push(args[i + 1]);
					i++;
				}
				i++;
				continue;
			}
			if (codeArg != null) {
				stderr('apq probe: only one code argument supported (got "$codeArg" and "$a")\n');
				return EXIT_USAGE;
			}
			codeArg = a;
			i++;
		}
		if (codeArg == null) {
			stderr('apq probe: missing <code> argument\n');
			printProbeUsage();
			return EXIT_USAGE;
		}
		final codeFinal: String = codeArg;
		// ω-probe-staging: persist the probe source to a fixed scratch
		// path so a follow-up `strip` / `recon --probe` / `writer-equals`
		// can target the same bytes without re-heredoc-ing them. The
		// stdin path is also captured (we read once, write to /tmp, then
		// hand the bytes to runAst via --code instead of --stdin so the
		// downstream loader sees the same source we staged).
		final stagedSource: Null<String> = stageProbeSource(codeFinal);
		if (writerProbeMode) {
			final source: String = stagedSource ?? (codeFinal == '-' ? readStdin() : codeFinal);
			final plugin: GrammarPlugin = pickPlugin(lang);
			// `<probe>` is the synthetic file label — matches the byte
			// shape `apq writer-probe` uses on real files and keeps any
			// downstream error message format consistent.
			final triviaOk: Bool = emitOneWriterProbe(plugin, source, '<probe>', lang, false, null);
			final plainOk: Bool = emitOneWriterProbe(plugin, source, '<probe>', lang, true, null);
			return (triviaOk && plainOk) ? EXIT_OK : EXIT_RUNTIME;
		}
		// When stdin was staged, prefer --code over --stdin so runAst
		// loads the bytes we just persisted (avoids a double stdin read
		// on a now-empty stream). Falls through to the original --stdin
		// path when staging was skipped (#if !sys or codeFinal != '-').
		final injected: Array<String> = if (stagedSource != null)
			['--code', stagedSource];
		else if (codeFinal == '-')
			['--stdin'];
		else
			['--code', codeFinal];
		return runAst(injected.concat(forwarded));
	}

	/**
	 * Resolve the probe source bytes (from arg or stdin), persist them to
	 * `/tmp/anyparse-last-probe.hx`, and emit a stderr nudge naming the
	 * path. Returns the resolved bytes UNCONDITIONALLY on `sys` (whether
	 * or not the write succeeded) so the caller can re-use them via
	 * `--code` instead of attempting a second stdin read on an already-
	 * drained stream. Returns `null` only on `#if !sys` (no FileSystem
	 * access — the caller falls through to the original argv-passthrough
	 * path).
	 *
	 * Inline-arg and stdin-source both stage on `sys`: the user can
	 * re-run `strip /tmp/anyparse-last-probe.hx …` straight after any
	 * `probe` invocation. A write failure (read-only /tmp, disk full,
	 * permission) skips the nudge but still returns the resolved bytes —
	 * losing the stdin read AND failing the probe would be the worse
	 * outcome.
	 *
	 * `STAGE_PROBE_PATH` is a constant (not a flag) — the scratch path
	 * is single-slot by design (a chained `recon --probe` should target
	 * the LAST probe, not pick from a history).
	 */
	private static function stageProbeSource(codeArg: String): Null<String> {
		#if (sys || nodejs)
		final source: String = codeArg == '-' ? readStdin() : codeArg;
		try {
			sys.io.File.saveContent(STAGE_PROBE_PATH, source);
			stderr(
				'apq probe: staged source -> $STAGE_PROBE_PATH (use it with `apq strip $STAGE_PROBE_PATH …` or `apq recon --probe $STAGE_PROBE_PATH`).\n'
			);
		} catch (_: Exception) {
			// Write failed (read-only /tmp, disk full, permission). Skip
			// the nudge but STILL return the read bytes so the caller can
			// use `--code` instead of `--stdin` — a second stdin read on
			// an already-drained stream would silently parse empty input.
		}
		return source;
		#else
		return null;
		#end
	}

	private static inline final STAGE_PROBE_PATH: String = '/tmp/anyparse-last-probe.hx';

	/**
	 * Boolean (value-less) `--flag` set for `runAst`. Listed explicitly
	 * so `runProbe`'s argv walker can tell `--depth 5` (consumes 5)
	 * from `--json` (consumes nothing). Stay in sync with the cases
	 * in `runAst` that take no `expectValue` call.
	 */
	private static final AST_BOOL_FLAGS: Array<String> = [
		'--json',
		'--doc',
		'--source',
		'--writer-output',
		'--writer-output-plain',
		'--diff',
		'--stdin',
		'--spans',
	];

	private static inline function isAstBoolFlag(flag: String): Bool {
		return AST_BOOL_FLAGS.contains(flag);
	}

	/**
	 * `apq writer-probe <input> [--lang haxe]` — emit BOTH trivia and
	 * plain writer outputs in one call, separated by labelled fences.
	 * Replaces the `hxq ast … --writer-output` + `hxq ast …
	 * --writer-output-plain` two-command dance when constructing a
	 * unit-test `writerEquals` expected literal: side-by-side output
	 * makes the pipeline divergence (anon structs flatten, terminators
	 * change, comments drop in plain) immediately visible.
	 *
	 * Each pipeline runs independently; one failing does not abort the
	 * other. Exit 0 only when both succeed. Output format:
	 *   === trivia ===
	 *   <bytes>
	 *   === plain ===
	 *   <bytes>
	 *
	 * The `=== trivia ===` / `=== plain ===` fences are deliberately
	 * verbatim (no shell metacharacters) so a downstream `awk` /
	 * `split` can pull either section without ambiguity.
	 */
	private static function runWriterProbe(args: Array<String>): Int {
		var lang: String = 'haxe';
		var file: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printWriterProbeUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq writer-probe: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
						stderr('apq writer-probe: only one file argument supported (got "$file" and "$a")\n');
						return EXIT_USAGE;
					}
					file = a;
			}
			i++;
		}
		if (file == null) {
			stderr('apq writer-probe: missing <file> argument\n');
			printWriterProbeUsage();
			return EXIT_USAGE;
		}
		final fileFinal: String = file;
		final plugin: GrammarPlugin = pickPlugin(lang);
		final source: String = readSourceForParse(fileFinal);
		// `.hxtest` section-1 config drives BOTH labelled probes so the
		// trivia ↔ plain comparison reflects the corpus harness's actual
		// writer surface for this fixture.
		final optsJson: Null<String> = readWriteOptionsJsonOrNull(fileFinal);
		final triviaOk: Bool = emitOneWriterProbe(plugin, source, fileFinal, lang, false, optsJson);
		final plainOk: Bool = emitOneWriterProbe(plugin, source, fileFinal, lang, true, optsJson);
		return (triviaOk && plainOk) ? EXIT_OK : EXIT_RUNTIME;
	}

	private static function emitOneWriterProbe(
		plugin: GrammarPlugin, source: String, file: String, lang: String, plain: Bool, optsJson: Null<String>
	): Bool {
		final label: String = plain ? 'plain' : 'trivia';
		sysPrint('=== $label ===\n');
		final emitted: Null<String> =
			try (plain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)) catch (e: ParseError) {
				stderr('apq writer-probe: $label: $file: ${e.toString()}\n');
				return false;
			} catch (e: Exception) {
				stderr('apq writer-probe: $label: $file: ${e.message}\n');
				return false;
			}
		if (emitted == null) {
			final flag: String = plain ? '--writer-output-plain' : '--writer-output';
			stderr('apq writer-probe: $label: no writer wired up for lang "$lang" ($flag equivalent)\n');
			return false;
		}
		sysPrint(emitted);
		if (!StringTools.endsWith(emitted, '\n')) sysPrint('\n');
		// DX v10: source-preservation note. The trivia pipeline is meant
		// to round-trip source bytes verbatim (subject to the writer's
		// fidelity); a byte-diff signals an actual writer-fidelity gap
		// (e.g. `HxVarMore` `,` collapses the space, `static var` was
		// pre-Slice-37 producing `staticvar`). Plain pipeline is allowed
		// to canonicalise, so the check is trivia-only. The note is
		// stderr — stdout stays the labelled output, exit code unchanged.
		if (!plain) writerProbeSourcePreservationNote(source, emitted);
		return true;
	}

	private static function writerProbeSourcePreservationNote(source: String, emitted: String): Void {
		if (source == emitted) return;
		final minLen: Int = source.length < emitted.length ? source.length : emitted.length;
		var diffAt: Int = minLen;
		for (i in 0...minLen) if (StringTools.fastCodeAt(source, i) != StringTools.fastCodeAt(emitted, i)) {
			diffAt = i;
			break;
		}
		// Show a small window around the divergence on each side so the
		// reader can immediately see the missing/extra bytes without
		// re-running a diff tool.
		final wnd: Int = 8;
		final sFrom: Int = diffAt - wnd >= 0 ? diffAt - wnd : 0;
		final sExp: String = escapeProbeWindow(source.substring(sFrom, diffAt + wnd < source.length ? diffAt + wnd : source.length));
		final sAct: String = escapeProbeWindow(emitted.substring(sFrom, diffAt + wnd < emitted.length ? diffAt + wnd : emitted.length));
		stderr('apq writer-probe: NOTE trivia output differs from source at offset $diffAt (writer-fidelity gap)\n');
		stderr('  source : "$sExp"\n');
		stderr('  emitted: "$sAct"\n');
	}

	private static function escapeProbeWindow(s: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			switch c {
				case '\n'.code:
					buf.add('\\n');
				case '\t'.code:
					buf.add('\\t');
				case '\r'.code:
					buf.add('\\r');
				case '"'.code:
					buf.add('\\"');
				case _:
					buf.addChar(c);
			}
		}
		return buf.toString();
	}

	private static function pickPlugin(lang: String): GrammarPlugin {
		return switch lang {
			case 'haxe': new HaxeQueryPlugin();
			case _: throw 'apq: no grammar plugin for --lang "$lang"';
		};
	}

	/**
	 * `apq recon` — corpus skip-parse drill harness. Walks a directory
	 * looking for source files (`.hxtest` fixtures auto-extract section
	 * 2), tries each via the plugin's trivia parser, and clusters the
	 * failures by a normalised forward-locus key so the histogram shows
	 * the actual stuck CONSTRUCT, not the parser's terminator carousel
	 * (`expected="//"` is 90%+ of the raw signal and is dropped).
	 *
	 * Replaces the standalone `test/_ReconSkipParse.hx` + `/tmp/recon.js`
	 * dance — same clustering logic, but in-process with the rest of
	 * `hxq` so a single `haxe bin/apq-js.hxml` rebuild after a grammar
	 * edit picks up the new parser surface. No separate hxml.
	 *
	 * Modes:
	 *  - `apq recon <dir>` — sweep mode. Walks every `.hxtest` under
	 *    `<dir>` recursively, prints `SKIP path :: line:col <locus>` per
	 *    failure, then a histogram of the top clusters (--top default 30,
	 *    --all overrides).
	 *  - `apq recon --probe <file>` — single-file probe. Useful for
	 *    confirming a hypothesis about ONE fixture after a grammar edit.
	 */
	#if (sys || nodejs)
	private static function runRecon(args: Array<String>): Int {
		final o: ReconOpts = parseReconArgs(args);
		if (o.errExit != null) return o.errExit;
		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final probePath: Null<String> = o.probePath;
		if (o.predictRelax && probePath != null) return runReconProbeRelax(plugin, probePath, o.showSource);
		if (probePath != null)
			return runReconProbe(
				plugin, probePath, o.predictStrip, o.patterns, o.replacements, o.compiledRegex, o.showSource, o.writerEqualsAfter,
				o.writerEqualsPlain, o.expectedPath, o.lang
			);
		final rootFinal: String = o.rootDir ?? defaultReconRoot();
		if (rootFinal == '') {
			stderr(
				"apq recon: no <dir> given and $ANYPARSE_HXFORMAT_FORK env var is unset (no cached path at ~/.config/anyparse/fork_path either).\n"
			);
			stderr('  Either pass a directory:  apq recon /path/to/corpus\n');
			stderr('  or export the fork root:  ANYPARSE_HXFORMAT_FORK=/path/to/haxe-formatter\n');
			stderr('  (first env-supplied run caches the path under ~/.config/anyparse/; subsequent runs work without re-exporting)\n');
			return EXIT_USAGE;
		}
		if (!FileSystem.exists(rootFinal) || !FileSystem.isDirectory(rootFinal)) {
			stderr('apq recon: "$rootFinal" is not a directory.\n');
			return EXIT_RUNTIME;
		}
		final candidatesRegex: Null<String> = o.candidatesRegex;
		return o.regressionProbe
			? runReconRegressionProbe(plugin, rootFinal)
			: candidatesRegex != null
				? runReconCandidates(plugin, rootFinal, candidatesRegex)
				: o.permissiveConstruct
					? runReconPermissive(plugin, rootFinal, o.lang)
					: o.predictRelax
						? runReconSweepRelax(plugin, rootFinal, o.clusterFilter, o.noTargetClusterFilter, o.showSource)
						: runReconSweep(
							plugin, rootFinal, o.topN, o.clusterFilter, o.predictStrip, o.patterns, o.replacements, o.compiledRegex,
							o.showSource
						);
	}

	/**
	 * `apq recon --probe <file> --predict-relax` — single-file
	 * terminator-insertion predictor. Parses `<file>`, captures the
	 * `ParseError.expected` hint, INSERTS that token at the fail-locus,
	 * and retries. Three outcomes:
	 *  - `PREDICT RELAX UNBLOCK` — patched source parses; the slice
	 *    candidate is gate-relaxation on the ctor at the fail-locus
	 *    (make the terminator optional via `@:trailOpt` /
	 *    `@:fmt(trailOptParseGate(...))`).
	 *  - `PREDICT RELAX STILL FAIL` — patched source still fails; the
	 *    gap is deeper than just the missing terminator. NEW locus
	 *    printed (moved-locus hint same shape as predict-strip).
	 *  - `PREDICT RELAX NO TARGET` — original error has no `expected`
	 *    hint to inject. Rare; usually means the parser ran out of
	 *    grammar branches entirely rather than failing at a specific
	 *    terminator expectation.
	 *
	 * Doesn't take --replace/--with — the injected token comes from
	 * the parser's own error hint.
	 */
	private static function runReconProbeRelax(plugin: GrammarPlugin, path: String, showSource: Bool): Int {
		final original: String = readSourceForParse(path);
		final res: PredictRelaxResult = tryPredictRelax(plugin, original);
		return reportPredictRelax(path, original, res, showSource);
	}

	/**
	 * Sweep-mode predict-relax. Walks every skip-parse fixture under
	 * `root`, runs `tryPredictRelax`, prints per-file outcome plus a
	 * summary `--- relax: K unblock, M still fail, P no target ---`.
	 *
	 * Drill modes (mutually exclusive):
	 *  - `--cluster <key>` — filter to records whose normalised
	 *    forward-locus matches `key` exactly (same shape as predict-strip
	 *    cluster drill); ALL outcomes (Unblock / StillFail / NoTarget)
	 *    print per-file.
	 *  - `--no-target-cluster <expected-msg>` — filter to records whose
	 *    `tryPredictRelax` returns `NoTarget` with `res.message` equal to
	 *    `expected-msg`. THE bridge from the footer NO TARGET histogram
	 *    (the `70× expected hint is empty after quote-strip` aggregate) to
	 *    the file list — the only way to see every fixture in one bucket.
	 *    Unblock / StillFail records are filtered out by construction
	 *    (they don't belong to the NO TARGET footer).
	 *  - Neither set — full sweep with per-file Unblock / StillFail lines
	 *    plus a footer NO TARGET histogram by `res.message`.
	 */
	private static function runReconSweepRelax(
		plugin: GrammarPlugin, root: String, clusterFilter: Null<String>, noTargetClusterFilter: Null<String>, showSource: Bool
	): Int {
		final walk: ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		var records: Array<ReconRecord> = walk.records;
		if (clusterFilter != null) {
			final filter: String = clusterFilter;
			records = records.filter(r -> r.clusterKey == filter);
			if (records.length == 0) {
				stderr('apq recon: --cluster "$filter" matched no skip-parse records (predict-relax mode)\n');
				return EXIT_RUNTIME;
			}
		}
		if (noTargetClusterFilter != null) return runReconRelaxNoTargetCluster(plugin, records, noTargetClusterFilter, showSource);
		// Cluster scope (`--cluster <key>`) means the user already narrowed
		// to a handful of fixtures and likely wants per-file NO TARGET lines
		// for inspection. Full-sweep scope dumps tens of NO TARGET lines that
		// are mostly cond-comp `//` catch-all noise — collapse those by
		// `expected` message into a footer histogram, keep UNBLOCK / STILL
		// FAIL per-file (low count, actionable).
		return runReconRelaxFullSweep(plugin, records, clusterFilter != null, showSource);
	}

	/**
	 * Run a single predict-relax probe on `source`. Returns one of the
	 * three result kinds with the patched source / new locus / injected
	 * token packed inside for the reporter to render.
	 */
	private static function tryPredictRelax(plugin: GrammarPlugin, source: String): PredictRelaxResult {
		var origLine: Int = 0;
		var origCol: Int = 0;
		var injected: Null<String> = null;
		var insertAt: Int = -1;
		try {
			plugin.reconParse(source);
			// Already-parseable file given to predict-relax. Not an
			// error — could be a `--probe` call on a fixture that
			// landed after a recent slice. Surface as NoTarget with a
			// distinct message so the user knows.
			return {
				kind: NoTarget,
				original: source,
				patched: source,
				injected: '',
				origLine: 0,
				origCol: 0,
				newLine: 0,
				newCol: 0,
				message: 'source already parses (no relaxation needed)'
			};
		} catch (pe: ParseError) {
			final pos: Position = pe.span.lineCol(source);
			origLine = pos.line;
			origCol = pos.col;
			final expected: Null<String> = pe.expected;
			if (expected == null) {
				return {
					kind: NoTarget,
					original: source,
					patched: source,
					injected: '',
					origLine: origLine,
					origCol: origCol,
					newLine: 0,
					newCol: 0,
					message: pe.message
				};
			}
			injected = stripExpectedHint((expected: String));
			insertAt = pe.span.from;
		} catch (e: Exception) {
			return {
				kind: NoTarget,
				original: source,
				patched: source,
				injected: '',
				origLine: 0,
				origCol: 0,
				newLine: 0,
				newCol: 0,
				message: e.message
			};
		}
		if (injected == null || injected.length == 0 || insertAt < 0) {
			return {
				kind: NoTarget,
				original: source,
				patched: source,
				injected: '',
				origLine: origLine,
				origCol: origCol,
				newLine: 0,
				newCol: 0,
				message: 'expected hint is empty after quote-strip'
			};
		}
		final injectedFinal: String = injected;
		final patched: String = source.substr(0, insertAt) + injectedFinal + source.substr(insertAt);
		try {
			plugin.reconParse(patched);
			return {
				kind: Unblock,
				original: source,
				patched: patched,
				injected: injectedFinal,
				origLine: origLine,
				origCol: origCol,
				newLine: 0,
				newCol: 0,
				message: ''
			};
		} catch (pe2: ParseError) {
			final pos2: Position = pe2.span.lineCol(patched);
			return {
				kind: StillFail,
				original: source,
				patched: patched,
				injected: injectedFinal,
				origLine: origLine,
				origCol: origCol,
				newLine: pos2.line,
				newCol: pos2.col,
				message: pe2.message
			};
		} catch (e: Exception) {
			return {
				kind: StillFail,
				original: source,
				patched: patched,
				injected: injectedFinal,
				origLine: origLine,
				origCol: origCol,
				newLine: 0,
				newCol: 0,
				message: e.message
			};
		}
	}

	/**
	 * NO-TARGET diagnostic list cap — both `--no-target-cluster` 0-match
	 * stderr and the sweep footer breakdown surface at most this many
	 * keys before truncating.
	 */
	private static inline final NO_TARGET_TOP_N: Int = 10;

	/**
	 * Find-or-insert a `{key, count}` entry in `reasons` by exact key
	 * match. Shared by the predict-relax sweep footer (`runReconSweepRelax`
	 * NoTarget arm) and the `--no-target-cluster` drill 0-match
	 * diagnostic — both build the same expected-message histogram.
	 */
	private static function bumpReasonCount(reasons: Array<{ key: String, count: Int }>, key: String): Void {
		for (e in reasons) if (e.key == key) {
			e.count++;
			return;
		}
		reasons.push({ key: key, count: 1 });
	}

	private static function reportPredictRelax(path: String, original: String, res: PredictRelaxResult, showSource: Bool): Int {
		switch res.kind {
			case Unblock:
				sysPrint('PREDICT RELAX UNBLOCK   $path :: inserting "${res.injected}" at ${res.origLine}:${res.origCol} unblocks parse\n');
				return EXIT_OK;
			case StillFail:
				final movedHint: String = movedLocusHint(res.origLine, res.origCol, res.newLine, res.newCol);
				sysPrint(
					'PREDICT RELAX STILL FAIL $path :: ${res.newLine}:${res.newCol}${movedHint} after inserting "${res.injected}" — ${res.message}\n'
				);
				if (showSource && res.newLine > 0) printReconSourceWindow(res.patched, res.newLine);
				return EXIT_RUNTIME;
			case NoTarget:
				sysPrint('PREDICT RELAX NO TARGET $path :: at ${res.origLine}:${res.origCol} — ${res.message}\n');
				// NoTarget has no patched source (the parser found no
				// `expected` hint to inject), so the window is anchored on
				// the ORIGINAL fail-locus. `origLine == 0` is the
				// "already-parseable" / pre-error path (no usable locus);
				// skip the window for those.
				if (showSource && res.origLine > 0) printReconSourceWindow(res.original, res.origLine);
				return EXIT_RUNTIME;
		}
	}

	/**
	 * Strip the `expected="<X>"` hint down to a literal token. Hints
	 * arrive as raw strings from `ParseError.expected` — they may be
	 * `";"`, `;`, `'}'`, `// (comment-or-end marker)`, etc. Recognise
	 * the three common terminator shapes and return the bare char.
	 * Returns the trimmed input unchanged for anything else; the
	 * caller's parse retry will surface bogus-injection as STILL FAIL.
	 */
	private static function stripExpectedHint(hint: String): String {
		final t: String = StringTools.trim(hint);
		if (t.length == 0) return t;
		// `"<x>"` or `'<x>'` form.
		if (t.length >= 2) {
			final first: String = t.charAt(0);
			final last: String = t.charAt(t.length - 1);
			if ((first == '"' && last == '"') || (first == "'" && last == "'")) return t.substring(1, t.length - 1);
		}
		// `//` is the canonical "comment or end" marker the parser
		// emits when it ran out of brace-/Star-terminating options. No
		// token to inject — return empty so the caller routes to
		// NO TARGET.
		return t == '//' || t == '<no message>' ? '' : t;
	}

	/**
	 * `apq recon --candidates <regex>` — walk skip-parse fixtures and
	 * count regex matches in each fixture's source. Reports one line per
	 * file with ≥1 hit (`<path> :: N matches`) sorted by count desc, plus
	 * a summary `--- candidates: K files matched (M total hits across N
	 * skip-parse files) ---`.
	 *
	 * Use when the histogram's normalized forward-locus clusters can't
	 * surface every fixture containing a construct of interest — the
	 * regex sees the raw bytes, so multi-blocker fixtures whose locus
	 * lives at a different shape are still found. Reuses the recon
	 * walker (`collectReconSkipRecords`) so the file list matches every
	 * other recon mode's view of the corpus exactly.
	 *
	 * Exit non-zero when 0 files matched (typo guard, mirrors
	 * `strip --dry-run` / `recon --predict-strip` semantics).
	 */
	private static function runReconCandidates(plugin: GrammarPlugin, root: String, pattern: String): Int {
		final re: EReg = try new EReg(pattern, 'g') catch (e: Exception) {
			stderr('apq recon: --candidates: pattern "$pattern" is not a valid EReg: ${e.message}\n');
			return EXIT_USAGE;
		}
		final walk: ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: --candidates: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final hits: Array<{ path: String, count: Int }> = [];
		var totalHits: Int = 0;
		for (r in walk.records) {
			final n: Int = countRegexHits(re, r.source);
			if (n > 0) {
				hits.push({ path: r.path, count: n });
				totalHits += n;
			}
		}
		hits.sort((a, b) -> b.count - a.count);
		for (h in hits) sysPrint('${h.path} :: ${h.count} match${h.count == 1 ? '' : 'es'}\n');
		sysPrint(
			'--- candidates: ${hits.length} file${plural(hits.length)} matched ($totalHits total hit${plural(totalHits)} across ${walk.records.length} skip-parse file${plural(walk.records.length)}) ---\n'
		);
		return hits.length == 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * `apq recon --permissive-construct` — field-optionalization
	 * predictor for Slice 40's `@:optional + @:lead + @:trail` mechanism.
	 * Walks every `mandatory-ref-lead-trail` candidate surfaced by
	 * `gates --mechanism mandatory-ref-lead-trail`, simulates the
	 * relaxation by stripping the `<lead>...<trail>` bracket-pair from
	 * each skip-parse fixture, and re-parses. Aggregates UNBLOCK /
	 * STILL FAIL / NO MATCH counts per candidate field — gives the user
	 * a static upper-bound view of which field-optionalization would
	 * unblock which fixtures BEFORE editing the grammar.
	 *
	 * Strip semantics depend on the lead/trail shape:
	 *  - Symmetric pair (`(`, `{`, `[` as lead with matching closer):
	 *    delete the WHOLE `<lead>...<trail>` block, paren-depth balanced
	 *    (nested same-pair allowed, strings/comments skipped).
	 *  - Asymmetric (lead is `:` / `,` / `=` etc., trail is `)` / `}`):
	 *    delete from `<lead>` UP TO (exclusive of) `<trail>`. The trail
	 *    belongs to an enclosing construct and stays — models e.g.
	 *    `catch (e:Type)` -> `catch (e)`.
	 *
	 * Multi-char macro/string leads (`${`, `"`, `'`) are filtered out at
	 * candidate-collection time — they describe interpolation/string
	 * delimiters that don't relax via Slice 40's mechanism.
	 *
	 * Output: one block per candidate that has ≥1 UNBLOCK or STILL FAIL
	 * (NO-MATCH-only candidates are summarized in the footer to keep the
	 * useful signal visible).
	 */
	private static function runReconPermissive(plugin: GrammarPlugin, root: String, lang: String): Int {
		final walk: ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: --permissive-construct: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final records: Array<ReconRecord> = walk.records;
		final candidates: Array<PermissiveCandidate> = collectPermissiveCandidates(plugin, lang);
		if (candidates.length == 0) {
			stderr(
				'apq recon: --permissive-construct: no mandatory-ref-lead-trail candidates found in src/anyparse/grammar/$lang/ (cross-check with `apq gates --mechanism mandatory-ref-lead-trail`)\n'
			);
			return EXIT_RUNTIME;
		}
		sysPrint(
			'=== permissive-construct: ${candidates.length} candidate${plural(candidates.length)} from gates --mechanism mandatory-ref-lead-trail, ${records.length} skip-parse fixture${plural(records.length)} ===\n'
		);
		var totalUnblocks: Int = 0;
		var candidatesWithSignal: Int = 0;
		final noSignalLabels: Array<String> = [];
		for (cand in candidates) {
			final unblocks: Array<String> = [];
			final stillFails: Array<String> = [];
			var noMatchCount: Int = 0;
			for (r in records) {
				final stripped: StripResult = stripBalancedPairs(r.source, cand.lead, cand.trail);
				if (stripped.count == 0) {
					noMatchCount++;
					continue;
				}
				final ok: Bool = try plugin.reconParse(stripped.out) catch (exception: Exception) false;
				if (ok)
					unblocks.push(r.path);
				else
					stillFails.push(r.path);
			}
			final nameSuffix: String = cand.declName != null ? ' ${cand.declName}' : '';
			final label: String = '${cand.file}:${cand.line}: ${cand.declKind}$nameSuffix @:lead(\'${cand.lead}\') @:trail(\'${cand.trail}\')';
			if (unblocks.length == 0 && stillFails.length == 0) {
				noSignalLabels.push('$label ($noMatchCount NO MATCH)');
				continue;
			}
			candidatesWithSignal++;
			totalUnblocks += unblocks.length;
			sysPrint('\nCANDIDATE $label\n');
			sysPrint('  ${unblocks.length} UNBLOCK / ${stillFails.length} STILL FAIL / $noMatchCount NO MATCH\n');
			for (p in unblocks) sysPrint('    UNBLOCK: $p\n');
			for (p in stillFails) sysPrint('    STILL FAIL: $p\n');
		}
		sysPrint(
			'\n--- permissive-construct summary: $candidatesWithSignal of ${candidates.length} candidate${plural(candidates.length)} have ≥1 UNBLOCK or STILL FAIL ($totalUnblocks UNBLOCK${plural(totalUnblocks)} total) across ${records.length} skip-parse files ---\n'
		);
		if (noSignalLabels.length > 0) {
			sysPrint('--- NO MATCH only (${noSignalLabels.length} candidate${plural(noSignalLabels.length)} with no fixture match) ---\n');
			for (l in noSignalLabels) sysPrint('  $l\n');
		}
		return totalUnblocks == 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * Enumerate `mandatory-ref-lead-trail` candidates by walking the
	 * grammar tree (`src/anyparse/grammar/<lang>/`) the same way `apq
	 * gates --mechanism mandatory-ref-lead-trail` does. Returns the lead
	 * and trail tokens (not just the rendered metas string) so the
	 * predictor's strip function can target the bracket-pair directly.
	 *
	 * Filters out macro/string-lead candidates (`${`, `$`, `'`, `"`) —
	 * they describe interpolation/string delimiters whose `@:optional`
	 * relaxation isn't the Slice 40 mechanism. Single-char leads only —
	 * the strip function depth-tracker assumes one byte per lead/trail.
	 */
	private static function collectPermissiveCandidates(plugin: GrammarPlugin, lang: String): Array<PermissiveCandidate> {
		final out: Array<PermissiveCandidate> = [];
		final grammarDir: String = 'src/anyparse/grammar/$lang/';
		if (!FileSystem.exists(grammarDir) || !FileSystem.isDirectory(grammarDir)) return out;
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs([grammarDir], '.hx');
		final shape: MetaShape = plugin.metaShape();
		final skipEntries: Array<SkipEntry> = [];
		for (path in expanded.paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('recon', plugin.parseFile, path, source, false, skipEntries);
			if (tree == null) continue;
			final raw: Array<MetaHit> = Meta.find(tree, shape, source);
			final grouped: { order: Array<Int>, groups: Map<Int, Array<MetaHit>> } = groupMetaHitsByDeclSpan(raw);
			for (key in grouped.order) {
				final metas: Null<Array<MetaHit>> = grouped.groups[key];
				if (metas == null) continue;
				var hasOptional: Bool = false;
				var lead: Null<String> = null;
				var trail: Null<String> = null;
				var sep: Null<String> = null;
				for (h in metas) switch h.annotation {
					case '@:optional':
						hasOptional = true;
					case '@:lead':
						lead = h.args.length > 0 ? stripQuotes(h.args[0]) : null;
					case '@:trail':
						trail = h.args.length > 0 ? stripQuotes(h.args[0]) : null;
					case '@:sep':
						sep = h.args.length > 0 ? h.args[0] : null;
					case _:
				}
				if (hasOptional || lead == null || trail == null || sep != null) continue;
				final leadStr: String = (lead: String);
				final trailStr: String = (trail: String);
				// Skip macro/string delimiters — their @:optional
				// relaxation isn't the Slice 40 mechanism (interpolation,
				// string body, etc.).
				if (leadStr.length != 1 || trailStr.length != 1) continue;
				if (leadStr == '"' || leadStr == "'") continue;
				if (leadStr == '$') continue;
				final first: MetaHit = metas[0];
				final fspan: Null<Span> = first.declSpan;
				final pos: Null<Position> = fspan != null ? fspan.lineCol(source) : null;
				out.push({
					file: path,
					line: pos != null ? pos.line : 0,
					col: pos != null ? pos.col : 0,
					declKind: first.declKind,
					declName: first.declName,
					lead: leadStr,
					trail: trailStr,
				});
			}
		}
		return out;
	}

	/**
	 * Single-pass `<lead>...<trail>` strip on `source`. Symmetric leads
	 * (`(`, `{`, `[`) consume the whole balanced pair; asymmetric leads
	 * (`:`, `,`, `=` etc.) consume from lead UP TO the trail (the trail
	 * char itself remains in output — it belongs to the enclosing
	 * construct). String literals (single- or double-quoted) and
	 * comments (line- or block-style) are skipped verbatim so a `:`
	 * inside a string doesn't trigger a spurious strip.
	 *
	 * Returns the patched source plus a `count` of strip occurrences —
	 * `count == 0` lets the caller distinguish NO MATCH (fixture lacks
	 * the construct) from STILL FAIL (fixture has it but post-strip
	 * parse still errors).
	 */
	private static function stripBalancedPairs(source: String, lead: String, trail: String): StripResult {
		if (lead.length != 1 || trail.length != 1) return { out: source, count: 0 };
		final leadCode: Int = StringTools.fastCodeAt(lead, 0);
		final trailCode: Int = StringTools.fastCodeAt(trail, 0);
		final isSymmetric: Bool = isBracketOpener(leadCode);
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		var count: Int = 0;
		while (i < source.length) {
			final triviaEnd: Int = skipStringOrComment(source, i);
			if (triviaEnd > i) {
				buf.addSub(source, i, triviaEnd - i);
				i = triviaEnd;
				continue;
			}
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == leadCode) {
				final endIdx: Int = findPairEnd(source, i + 1, leadCode, trailCode, isSymmetric);
				if (endIdx >= 0) {
					count++;
					i = endIdx;
					continue;
				}
			}
			buf.addChar(c);
			i++;
		}
		return { out: buf.toString(), count: count };
	}

	/**
	 * Scan from `startIdx` looking for the matching trail. Returns the
	 * index PAST the strip region (caller does `i = endIdx` to skip it):
	 *  - Symmetric: returns index past the closing trail char (`<lead>...<trail>` consumed whole)
	 *  - Asymmetric: returns index AT the trail char (trail stays in output)
	 *
	 * `-1` when no match found (mismatched / unterminated). The caller
	 * keeps the lead char as-is in that case.
	 */
	private static function findPairEnd(source: String, startIdx: Int, leadCode: Int, trailCode: Int, isSymmetric: Bool): Int {
		var i: Int = startIdx;
		var depth: Int = isSymmetric ? 1 : 0;
		while (i < source.length) {
			final triviaEnd: Int = skipStringOrComment(source, i);
			if (triviaEnd > i) {
				i = triviaEnd;
				continue;
			}
			final c: Int = StringTools.fastCodeAt(source, i);
			if (isSymmetric) {
				if (c == leadCode) {
					depth++;
					i++;
					continue;
				}
				if (c == trailCode) {
					depth--;
					i++;
					if (depth == 0) return i;
					continue;
				}
			} else {
				if (depth == 0 && c == trailCode) return i;
				if (isBracketOpener(c)) {
					depth++;
					i++;
					continue;
				}
				if (isBracketCloser(c)) {
					if (depth == 0) return -1;
					depth--;
					i++;
					continue;
				}
			}
			i++;
		}
		return -1;
	}

	private static inline function isBracketOpener(c: Int): Bool {
		return c == '('.code || c == '{'.code || c == '['.code;
	}

	private static inline function isBracketCloser(c: Int): Bool {
		return c == ')'.code || c == '}'.code || c == ']'.code;
	}

	/**
	 * If `source[i]` starts a string literal (single- or double-quoted)
	 * or comment (line-style or block-style), return the index PAST it;
	 * otherwise return `i`. Handles backslash escapes inside strings,
	 * multi-line block comments. Used by the permissive-construct strip
	 * to skip trivia bytes so a `:` inside `"foo:bar"` doesn't trigger a
	 * spurious asymmetric pair-match.
	 */
	private static function skipStringOrComment(source: String, i: Int): Int {
		if (i >= source.length) return i;
		final c: Int = StringTools.fastCodeAt(source, i);
		if (c == '/'.code && i + 1 < source.length) {
			final c2: Int = StringTools.fastCodeAt(source, i + 1);
			if (c2 == '/'.code) {
				var j: Int = i + 2;
				while (j < source.length && StringTools.fastCodeAt(source, j) != '\n'.code) j++;
				return j;
			}
			if (c2 == '*'.code) {
				var j: Int = i + 2;
				while (j + 1 < source.length) {
					if (StringTools.fastCodeAt(source, j) == '*'.code && StringTools.fastCodeAt(source, j + 1) == '/'.code) return j + 2;
					j++;
				}
				return source.length;
			}
		}
		if (c == '"'.code || c == "'".code) {
			var j: Int = i + 1;
			while (j < source.length) {
				final cj: Int = StringTools.fastCodeAt(source, j);
				if (cj == '\\'.code) {
					j += 2;
					continue;
				}
				if (cj == c) return j + 1;
				j++;
			}
			return source.length;
		}
		return i;
	}

	/**
	 * `apq recon --regression-probe` — load the prior sweep snapshot's
	 * per-fixture status map (`bin/.last-sweep.json`'s `fixtures` array,
	 * written by `HxFormatterCorpusTest.printSweepDelta`) and diff
	 * against the current corpus's parse OK / SKIP_PARSE state.
	 *
	 * Surfaces every fixture whose parse status FLIPPED since the
	 * snapshot:
	 *   REGRESSED <path>: was PASS, now SKIP_PARSE :: line:col <locus>
	 *   UNBLOCKED <path>: was SKIP_PARSE, now parses OK
	 *
	 * The probe only runs the trivia parser, NOT the writer — skip-write
	 * / skip-config / malformed statuses are pre- or post-parse concerns
	 * and stay orthogonal to grammar edits. PASS / FAIL / SKIP_WRITE in
	 * the snapshot collapse to "parsed OK" for diff purposes (the writer
	 * failed but the parser accepted the input).
	 *
	 * Exits 0 when no regressions found (unblocks alone are still
	 * non-zero-friendly); non-zero exit when any REGRESSED line printed
	 * — so a CI hook can fail the build before the user runs the full
	 * sweep.
	 */
	private static function runReconRegressionProbe(plugin: GrammarPlugin, root: String): Int {
		// Load the prior snapshot. Missing / unreadable / malformed JSON
		// is a non-fatal "no baseline" — print a single info line and
		// exit OK so a fresh checkout doesn't fail the probe.
		final snapshotPath: String = 'bin/.last-sweep.json';
		if (!FileSystem.exists(snapshotPath)) {
			sysPrint(
				'apq recon: no prior sweep snapshot at $snapshotPath — run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK first to seed the baseline\n'
			);
			return EXIT_OK;
		}
		final prior: Map<String, String> = loadSweepFixtureStatus(snapshotPath);
		if (prior.iterator().hasNext() == false) {
			sysPrint(
				'apq recon: snapshot at $snapshotPath has no `fixtures` array — older format, re-run `node bin/test.js` to refresh the baseline\n'
			);
			return EXIT_OK;
		}
		final walk: ReconRegressionResult = walkReconRegression(plugin, root, prior);
		if (walk.unwired) {
			stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		sysPrint(
			'--- regression-probe: ${walk.regressed} regressed, ${walk.unblocked} unblocked, ${walk.scanned} scanned vs snapshot ---\n'
		);
		return walk.regressed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * Read `bin/.last-sweep.json`'s `fixtures` array (written by
	 * `HxFormatterCorpusTest.printSweepDelta`) into a `path → status`
	 * map. Returns an empty map on any parse / shape failure so the
	 * caller can fail-soft with a "no baseline" diagnostic instead of
	 * crashing on a malformed snapshot.
	 */
	private static function loadSweepFixtureStatus(path: String): Map<String, String> {
		final out: Map<String, String> = [];
		try {
			final raw: String = sys.io.File.getContent(path);
			final obj: Dynamic = haxe.Json.parse(raw);
			if (!Reflect.hasField(obj, 'fixtures')) return out;
			final fixtures: Dynamic = Reflect.field(obj, 'fixtures');
			if (!Std.isOfType(fixtures, Array)) return out;
			final arr: Array<Dynamic> = (fixtures: Array<Dynamic>);
			for (entry in arr) {
				final entryPath: Null<Dynamic> = Reflect.field(entry, 'path');
				final entryStatus: Null<Dynamic> = Reflect.field(entry, 'status');
				if (entryPath != null && entryStatus != null && Std.isOfType(entryPath, String) && Std.isOfType(entryStatus, String)) {
					// Normalise snapshot path to match what
					// `stripRootPrefix` emits for the recon walker. The
					// corpus harness records paths as
					// `test/testcases/<subdir>/<name>` (rooted at the fork);
					// recon walks from `<fork>/test/testcases` so its
					// stripped paths are `<subdir>/<name>`. Trim the leading
					// `test/testcases/` here so the diff lookup is keyed
					// the same way on both sides.
					final raw: String = (entryPath: String);
					final corpusPrefix: String = 'test/testcases/';
					final normalised: String = StringTools.startsWith(raw, corpusPrefix) ? raw.substr(corpusPrefix.length) : raw;
					out[normalised] = (entryStatus: String);
				}
			}
		} catch (_: Exception) {
			// best-effort: a scan failure leaves the partial status map
		}
		return out;
	}

	private static function runReconProbe(
		plugin: GrammarPlugin, path: String, predictStrip: Bool, patterns: Array<String>, replacements: Array<String>,
		compiledRegex: Null<Array<EReg>>, showSource: Bool, writerEqualsAfter: Bool = false, writerEqualsPlain: Bool = false,
		expectedPathOpt: Null<String> = null, lang: String = 'haxe'
	): Int {
		if (!FileSystem.exists(path)) {
			stderr('apq recon: --probe path "$path" does not exist\n');
			return EXIT_RUNTIME;
		}
		final original: String = readSourceForParse(path);
		// `--predict-strip --probe <file>` — apply substitutions to the
		// single probed file's source, then re-run the strict trivia parse
		// against the result. Mirrors the sweep-mode predict tag set
		// (`PREDICT UNBLOCK` / `PREDICT STILL FAIL` / `PREDICT NO MATCH`)
		// so a single-file dry-run stays semantically aligned with the
		// corpus walk. Per-pattern match totals are printed for the typo
		// guard (a `--replace` pattern matching 0 occurrences is the
		// canonical pre-edit signal of a typo or whitespace mismatch).
		// Without `--predict-strip`, the legacy PARSE OK / PARSE FAIL
		// output is byte-identical to before.
		if (predictStrip) return runReconProbePredict(plugin, path, original, patterns, replacements, compiledRegex, showSource);
		try {
			if (!plugin.reconParse(original)) {
				stderr('apq recon: no recon parser wired up for this grammar plugin\n');
				return EXIT_RUNTIME;
			}
			sysPrint('PARSE OK\n');
			return writerEqualsAfter ? runProbeWriterCheck(plugin, path, original, writerEqualsPlain, expectedPathOpt, lang) : EXIT_OK;
		} catch (exception: ParseError) {
			final pos: Position = exception.span.lineCol(original);
			final exp: String = reconNormalize(exception.expected);
			final snip: String = reconNormalize(reconSnippet(original, exception.span.from));
			sysPrint('PARSE FAIL :: ${pos.line}:${pos.col} expected="$exp" :: src="$snip"\n');
			return EXIT_RUNTIME;
		} catch (exception: Exception) {
			sysPrint('PARSE FAIL :: <non-ParseError> ${reconNormalize(exception.message)}\n');
			return EXIT_RUNTIME;
		}
	}

	/**
	 * ω-probe-writer-check: chain a writer round-trip + byte-equality check
	 * onto a probe-mode PARSE OK. Reuses `runWriterEquals`'s machinery so
	 * the byte-diff format stays identical to the corpus harness's fail
	 * line. Closes the "predicted +1 via predict-strip, got skip→fail
	 * because writer round-trip diverges" gap.
	 *
	 * Expected bytes resolution:
	 *  - explicit `--expected <path>` always wins.
	 *  - `.hxtest` input → section 3 (the fork's reference formatted output).
	 *  - plain `.hx` → byte-identity round-trip (compare against source).
	 *
	 * Last case turns the call into a writer-idempotency check: parse the
	 * source, write back, expect the same bytes. Useful for sanity-probing
	 * a grammar edit's writer round-trip on hand-rolled scratch inputs
	 * (`/tmp/probe.hx`) without typing the expected bytes twice.
	 */
	private static function runProbeWriterCheck(
		plugin: GrammarPlugin, inputPath: String, source: String, plain: Bool, expectedPathOpt: Null<String>, lang: String
	): Int {
		// `.hxtest` expected sections drop one trailing `\n` via
		// `stripPadNewlines` (the corpus harness adds `finalNewline=true`
		// and trims back one `\n` from `actualRaw` to keep the compare
		// symmetric). Mirror that here so a corpus-PASS fixture round-trips
		// to `WRITER PASS` via the probe, not a spurious off-by-newline
		// mismatch. Raw `.hx` inputs skip the strip — the user supplied
		// expected bytes verbatim.
		final hxtestMode: Bool = expectedPathOpt == null && StringTools.endsWith(inputPath, '.hxtest');
		final expectedSource: String = if (expectedPathOpt != null) {
			readExpectedForCompare((expectedPathOpt: String));
		} else if (hxtestMode) {
			readExpectedForCompare(inputPath);
		} else {
			source;
		};
		final optsJson: Null<String> = readWriteOptionsJsonOrNull(inputPath);
		final emittedRaw: Null<String> =
			try (plain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)) catch (e: ParseError) {
				sysPrint('WRITER FAIL :: ${e.toString()}\n');
				return EXIT_RUNTIME;
			} catch (e: Exception) {
				sysPrint('WRITER FAIL :: ${e.message}\n');
				return EXIT_RUNTIME;
			}
		if (emittedRaw == null) {
			final flagName: String = plain ? '--writer-equals-plain' : '--writer-equals';
			stderr('apq recon: no writer wired up for lang "$lang" ($flagName)\n');
			return EXIT_USAGE;
		}
		final emitted: String = (emittedRaw: String);
		final emittedNormalised: String = hxtestMode && emitted.length > 0
			&& StringTools.fastCodeAt(emitted, emitted.length - 1) == '\n'.code
			? emitted.substr(0, emitted.length - 1)
			: emitted;
		if (emittedNormalised == expectedSource) {
			sysPrint('WRITER PASS\n');
			return EXIT_OK;
		}
		sysPrint('WRITER FAIL :: ${describeByteDiff(emittedNormalised, expectedSource)}\n');
		return EXIT_RUNTIME;
	}

	private static function runReconProbePredict(
		plugin: GrammarPlugin, path: String, original: String, patterns: Array<String>, replacements: Array<String>,
		compiledRegex: Null<Array<EReg>>, showSource: Bool
	): Int {
		// Capture the original fail-locus first so STILL FAIL can report
		// the moved-locus hint (same signal as sweep-mode predict-strip).
		var origLine: Int = 0;
		var origCol: Int = 0;
		try {
			plugin.reconParse(original);
		} catch (pe: ParseError) {
			final pos: Position = pe.span.lineCol(original);
			origLine = pos.line;
			origCol = pos.col;
		} catch (_: Exception) {
			// best-effort: keep default origLine/origCol if the span lookup fails
		}
		final regexMode: Bool = compiledRegex != null;
		final regexes: Array<EReg> = compiledRegex ?? [];
		final patternHits: Array<Int> = [for (_ in 0...patterns.length) 0];
		var stripped: String = original;
		var fileHits: Int = 0;
		for (idx in 0...patterns.length) {
			final hits: Int = regexMode ? countRegexHits(regexes[idx], stripped) : countOccurrences(stripped, patterns[idx]);
			patternHits[idx] = hits;
			fileHits += hits;
			stripped = regexMode
				? regexes[idx].replace(stripped, replacements[idx])
				: StringTools.replace(stripped, patterns[idx], replacements[idx]);
		}
		var exitCode: Int = EXIT_OK;
		if (fileHits == 0) {
			sysPrint('PREDICT NO MATCH  $path\n');
		} else {
			try {
				if (!plugin.reconParse(stripped)) {
					stderr('apq recon: no recon parser wired up for this grammar plugin\n');
					return EXIT_RUNTIME;
				}
				sysPrint('PREDICT UNBLOCK   $path\n');
			} catch (pe: ParseError) {
				final pos: Position = pe.span.lineCol(stripped);
				final movedHint: String = movedLocusHint(origLine, origCol, pos.line, pos.col);
				sysPrint('PREDICT STILL FAIL $path :: ${pos.line}:${pos.col}${movedHint} ${pe.message}\n');
				if (showSource) printReconSourceWindow(stripped, pos.line);
				exitCode = EXIT_RUNTIME;
			} catch (e: Exception) {
				sysPrint('PREDICT STILL FAIL $path :: <no locus> ${e.message}\n');
				exitCode = EXIT_RUNTIME;
			}
		}
		// Per-pattern totals — same typo guard contract as sweep mode.
		for (idx in 0...patterns.length) {
			final pat: String = patterns[idx];
			final total: Int = patternHits[idx];
			sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		var anyZero: Bool = false;
		for (h in patternHits) if (h == 0) anyZero = true;
		if (anyZero) {
			stderr('apq recon: --predict-strip --probe: WARNING: one or more patterns matched 0 occurrences — see per-pattern totals\n');
			return EXIT_RUNTIME;
		}
		return exitCode;
	}

	private static function runReconSweep(
		plugin: GrammarPlugin, root: String, topN: Int, clusterFilter: Null<String>, predictStrip: Bool, patterns: Array<String>,
		replacements: Array<String>, compiledRegex: Null<Array<EReg>>, showSource: Bool
	): Int {
		final walk: ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final clusters: Map<String, ReconCluster> = walk.clusters;
		final records: Array<ReconRecord> = walk.records;
		// `--cluster <key>` filter: exact match against the normalised
		// cluster key (the histogram label, with `\n`/`\t` escaped).
		// Exact rather than substring because `}\n}` (canonical) would
		// substring-match every Haxe file's `…}\n}` tail. 0-match exits
		// non-zero; downstream output (SKIP / PREDICT / cluster drill)
		// walks the filtered records and the single-cluster map.
		var filteredRecords: Array<ReconRecord> = records;
		var filteredClusters: Map<String, ReconCluster> = clusters;
		if (clusterFilter != null) {
			final wanted: String = (clusterFilter: String);
			final hit: Null<ReconCluster> = clusters[wanted];
			if (hit == null) {
				stderr('apq recon: --cluster "$wanted" matched no cluster key (exact match).\n');
				final keyEntries: Array<{ key: String, count: Int }> = [
					for (k => v in clusters) { key: k, count: v.count }
				];
				keyEntries.sort((a, b) -> b.count - a.count);
				final preview: Int = keyEntries.length > CLUSTER_PREVIEW_LIMIT ? CLUSTER_PREVIEW_LIMIT : keyEntries.length;
				if (preview == 0) {
					stderr('  (no skip-parse failures in this sweep)\n');
				} else {
					stderr('  available keys (${keyEntries.length} total, showing top $preview by frequency):\n');
					for (idx in 0...preview) stderr('    "${keyEntries[idx].key}"  (${keyEntries[idx].count}×)\n');
					if (keyEntries.length > preview)
						stderr('    … (${keyEntries.length - preview} more — run without --cluster to see the full histogram)\n');
				}
				return EXIT_RUNTIME;
			}
			filteredClusters = [wanted => hit];
			filteredRecords = [for (r in records) if (r.clusterKey == wanted) r];
		}
		if (predictStrip)
			return runReconPredictStrip(
				filteredRecords, filteredClusters, plugin, patterns, replacements, compiledRegex, clusterFilter, showSource
			);
		for (r in filteredRecords) sysPrint('${r.skipLine}\n');
		return clusterFilter != null
			? printReconClusterDrill(filteredClusters, records.length, (clusterFilter: String), filteredRecords, showSource)
			: printReconHistogram(clusters, records.length, topN);
	}

	/**
	 * Corpus-walk extracted from `runReconSweep` so the same skip-parse
	 * record list drives both the recon sweep (histogram / cluster drill
	 * / predict-strip) and `strip --from-cluster` (apply substitutions
	 * to every file in a named cluster). Recurses into subdirs, parses
	 * each `.hxtest` via the plugin's trivia parser, and clusters
	 * failures by normalised forward-locus. `wired == false` when the
	 * plugin returns `false` from `reconParse` — surfaces the same
	 * "no recon parser for lang X" error in both callers.
	 */
	private static function collectReconSkipRecords(plugin: GrammarPlugin, root: String): ReconWalkResult {
		final clusters: Map<String, ReconCluster> = [];
		final records: Array<ReconRecord> = [];
		var wired: Bool = true;
		final stack: Array<String> = [root];
		while (stack.length > 0) {
			final dir: Null<String> = stack.pop();
			if (dir == null) break;
			final names: Array<String> = FileSystem.readDirectory(dir);
			names.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) {
				final path: String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!StringTools.endsWith(name, '.hxtest')) continue;
				final source: String = readSourceForParse(path);
				try {
					if (!plugin.reconParse(source)) {
						wired = false;
						break;
					}
				} catch (exception: ParseError) {
					final pos: Position = exception.span.lineCol(source);
					final relPath: String = stripRootPrefix(path, root);
					final exp: String = reconNormalize(exception.expected);
					final snip: String = reconNormalize(reconSnippet(source, exception.span.from));
					final rawLocus: String = reconRawLocus(source, exception.span.from);
					final key: String = reconNormalizeLocus(rawLocus);
					addReconCluster(clusters, key, relPath, rawLocus);
					records.push({
						path: relPath,
						clusterKey: key,
						source: source,
						skipLine: 'SKIP $relPath :: ${pos.line}:${pos.col} expected="$exp" :: src="$snip"',
						line: pos.line,
						col: pos.col,
					});
				} catch (exception: Exception) {
					final relPath: String = stripRootPrefix(path, root);
					final key: String = '<non-ParseError> ' + reconNormalize(exception.message);
					addReconCluster(clusters, key, relPath, '<exception>');
					records.push({
						path: relPath,
						clusterKey: key,
						source: source,
						skipLine: 'SKIP $relPath :: $key',
						line: 0,
						col: 0,
					});
				}
			}
			if (!wired) break;
		}
		return { wired: wired, records: records, clusters: clusters };
	}

	private static function printReconHistogram(clusters: Map<String, ReconCluster>, total: Int, topN: Int): Int {
		final entries: Array<{ key: String, cluster: ReconCluster }> = [
			for (k => v in clusters) { key: k, cluster: v }
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		final shown: Int = entries.length > topN ? topN : entries.length;
		sysPrint('\n');
		sysPrint('--- skip-parse construct-locus histogram (total $total, showing top $shown of ${entries.length}; --all overrides) ---\n');
		for (idx in 0...shown) {
			final entry = entries[idx];
			final c: ReconCluster = entry.cluster;
			final examplesStr: String = c.examples.length == 1 ? c.examples[0] : c.examples.join(', ');
			final raw: String = reconNormalize(c.rawSample);
			sysPrint('  ${c.count}× "${entry.key}"  e.g. "$raw"  in: $examplesStr\n');
		}
		if (entries.length > shown) sysPrint('  … (${entries.length - shown} more, use --top N or --all to see)\n');
		return EXIT_OK;
	}

	/**
	 * `--cluster <substr>` drill output: one block per matching
	 * cluster with the FULL path list (not the histogram's capped
	 * `examples` array). Sorted descending by cluster size; paths
	 * sorted ascending so output is stable. Replaces the global
	 * histogram in this mode.
	 *
	 * When `showSource` is true, each printed path is followed by a
	 * fenced window of source bytes around the fail-locus
	 * (`RECON_SOURCE_WINDOW_RADIUS` lines either side). Replaces the
	 * manual Read-per-path step after `--cluster` drill.
	 */
	private static function printReconClusterDrill(
		matches: Map<String, ReconCluster>, totalAcrossSweep: Int, needle: String, records: Array<ReconRecord>, showSource: Bool
	): Int {
		final entries: Array<{ key: String, cluster: ReconCluster }> = [
			for (k => v in matches) { key: k, cluster: v }
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		var matched: Int = 0;
		for (e in entries) matched += e.cluster.count;
		// Map path → record so the windowed source / locus lookup stays
		// O(1) per path even in clusters with hundreds of fixtures.
		// Built once for the drill block regardless of `showSource`
		// (cost is negligible vs the walk itself).
		final byPath: Map<String, ReconRecord> = [for (r in records) r.path => r];
		sysPrint('\n');
		sysPrint(
			'--- cluster drill for "$needle" (${entries.length} cluster${plural(entries.length)}, $matched of $totalAcrossSweep skip-parse paths) ---\n'
		);
		for (entry in entries) {
			final c: ReconCluster = entry.cluster;
			sysPrint('  cluster "${entry.key}" — ${c.count} path${plural(c.count)}:\n');
			final sorted: Array<String> = c.paths.copy();
			sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			for (p in sorted) {
				if (!showSource) {
					sysPrint('    $p\n');
					continue;
				}
				final rec: Null<ReconRecord> = byPath[p];
				if (rec == null) {
					sysPrint('    $p   <no record>\n');
					continue;
				}
				if (rec.line <= 0) {
					sysPrint('    $p   <no locus>\n');
					continue;
				}
				sysPrint('    $p at ${rec.line}:${rec.col}\n');
				printReconSourceWindow(rec.source, rec.line);
			}
		}
		return EXIT_OK;
	}

	/**
	 * Emit a windowed source slice centred on `failLine` (1-indexed) to
	 * stdout, with a `>>` marker on the fail row and right-aligned line
	 * numbers. Window radius is `RECON_SOURCE_WINDOW_RADIUS` either
	 * side; lines past EOF are silently clipped so a fail near the top
	 * or bottom prints as much context as is available.
	 */
	private static function printReconSourceWindow(source: String, failLine: Int): Void {
		final lines: Array<String> = source.split('\n');
		final radius: Int = RECON_SOURCE_WINDOW_RADIUS;
		final start: Int = failLine - radius < 1 ? 1 : failLine - radius;
		final end: Int = failLine + radius > lines.length ? lines.length : failLine + radius;
		sysPrint('      --- src window (L±$radius) ---\n');
		// Compute the gutter width from `end` so all rows line up; e.g.
		// a 3-digit end-line gives a 3-char gutter.
		final gutter: Int = ('$end').length;
		for (ln in start...end + 1) {
			final marker: String = ln == failLine ? '>>' : '  ';
			final num: String = padLeft('$ln', gutter);
			final body: String = lines[ln - 1];
			sysPrint('      $marker$num | $body\n');
		}
		sysPrint('      --- end ---\n');
	}

	private static inline function padLeft(s: String, width: Int): String {
		var out: String = s;
		while (out.length < width) out = ' ' + out;
		return out;
	}

	/**
	 * Render the predict-strip "moved locus" suffix. Three regimes:
	 *  - Same locus → empty (no hint needed).
	 *  - NEW > ORIG (line strictly greater, or same line + col strictly
	 *    greater) → ` (was L:C, advanced)` — strip uncovered a downstream
	 *    blocker; the substitution's effect was forward, so the residual
	 *    fail is a real second blocker.
	 *  - NEW < ORIG (line less, or same line + col less) → ` (was L:C,
	 *    moved BACKWARD — strip may have damaged earlier syntax, or your
	 *    substitution model doesn't match the actual blocker mechanism;
	 *    verify with `apq probe` on the unstripped fragment)` — the
	 *    common Slice 39-style failure mode where token substitution
	 *    can't model gate-relaxation.
	 *  - Same line, col differs → ` (was L:C)` — neutral; the strip
	 *    shifted things within one line, usually inconsequential.
	 *
	 * `origLine == 0` means the original error had no locus (rare —
	 * `<no locus>` already printed instead); guard returns empty.
	 */
	private static inline function movedLocusHint(origLine: Int, origCol: Int, newLine: Int, newCol: Int): String {
		if (origLine <= 0) return '';
		if (newLine == origLine && newCol == origCol) return '';
		final forward: Bool = newLine > origLine || (newLine == origLine && newCol > origCol);
		final backward: Bool = newLine < origLine || (newLine == origLine && newCol < origCol);
		return forward && newLine != origLine
			? ' (was $origLine:$origCol, advanced)'
			: backward
				? ' (was $origLine:$origCol, moved BACKWARD — strip may have damaged earlier syntax or modelled the wrong mechanism; verify with `apq probe`)'
				: ' (was $origLine:$origCol)';
	}

	/**
	 * `--predict-strip` output: for each skip-parse record, apply the
	 * supplied --replace / --with / --delete substitutions to the
	 * extracted source and re-run the plugin's trivia parser.
	 *
	 * Per-file tag:
	 *  - `PREDICT UNBLOCK` — substitution changed the source AND the
	 *    re-parse now succeeds; the grammar/strip-test change being
	 *    modelled would unblock this fixture.
	 *  - `PREDICT STILL FAIL` — substitution changed the source but
	 *    re-parse still fails (different blocker survives downstream).
	 *  - `PREDICT NO MATCH` — substitution patterns matched 0 times;
	 *    the fixture is unaffected by the proposed change. Typo
	 *    signal when this fires across the WHOLE sweep.
	 *
	 * Summary line at the end: total / unblock / still-fail / no-match
	 * counts. Exits non-zero only if ALL patterns matched 0 occurrences
	 * across the whole filtered set (mirror of `strip --dry-run`'s
	 * pattern-typo guard).
	 */
	private static function runReconPredictStrip(
		records: Array<ReconRecord>, clusters: Map<String, ReconCluster>, plugin: GrammarPlugin, patterns: Array<String>,
		replacements: Array<String>, compiledRegex: Null<Array<EReg>>, clusterFilter: Null<String>, showSource: Bool
	): Int {
		final regexMode: Bool = compiledRegex != null;
		final regexes: Array<EReg> = compiledRegex ?? [];
		var unblockCount: Int = 0;
		var stillFailCount: Int = 0;
		var noMatchCount: Int = 0;
		final patternHits: Array<Int> = [for (_ in 0...patterns.length) 0];
		for (r in records) {
			var stripped: String = r.source;
			var fileHits: Int = 0;
			for (idx in 0...patterns.length) {
				final hits: Int = regexMode ? countRegexHits(regexes[idx], stripped) : countOccurrences(stripped, patterns[idx]);
				patternHits[idx] += hits;
				fileHits += hits;
				stripped = regexMode
					? regexes[idx].replace(stripped, replacements[idx])
					: StringTools.replace(stripped, patterns[idx], replacements[idx]);
			}
			if (fileHits == 0) {
				sysPrint('PREDICT NO MATCH  ${r.path}\n');
				noMatchCount++;
				continue;
			}
			try {
				if (!plugin.reconParse(stripped)) {
					stderr('apq recon: no recon parser wired up for this grammar plugin\n');
					return EXIT_RUNTIME;
				}
				sysPrint('PREDICT UNBLOCK   ${r.path}\n');
				unblockCount++;
			} catch (pe: ParseError) {
				// New locus after substitution. When it differs from the
				// pre-strip locus the strip likely moved the problem (e.g.
				// pattern matched a decl AND a use position), which is the
				// common false-negative trap on slice candidates. Surface
				// the new line:col + message so the reader sees the move at
				// a glance instead of opening the stripped source to diff
				// the locus by hand. With `--source`, also emit a windowed
				// src slice around the new locus — replaces the manual
				// Read of the stripped source when the moved-locus hint
				// alone is ambiguous.
				final pos: Position = pe.span.lineCol(stripped);
				final movedHint: String = movedLocusHint(r.line, r.col, pos.line, pos.col);
				sysPrint('PREDICT STILL FAIL ${r.path} :: ${pos.line}:${pos.col}${movedHint} ${pe.message}\n');
				if (showSource) printReconSourceWindow(stripped, pos.line);
				stillFailCount++;
			} catch (e: Exception) {
				sysPrint('PREDICT STILL FAIL ${r.path} :: <no locus> ${e.message}\n');
				stillFailCount++;
			}
		}
		sysPrint('\n');
		final scope: String = clusterFilter == null ? 'whole sweep' : 'cluster "$clusterFilter"';
		sysPrint('--- predict-strip ($scope): ${records.length} skip-parse file${plural(records.length)}; ');
		sysPrint('$unblockCount would unblock, $stillFailCount still fail, $noMatchCount unchanged ---\n');
		for (idx in 0...patterns.length) {
			final pat: String = patterns[idx];
			final total: Int = patternHits[idx];
			sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		// Mirror `strip --dry-run`: every supplied pattern matching 0
		// across the whole filtered set is a typo signal worth surfacing
		// non-zero. A pattern matching SOMEWHERE but not everywhere is
		// expected behaviour for a targeted predicate; only the global
		// 0 case is the guard.
		var anyZero: Bool = false;
		for (h in patternHits) if (h == 0) anyZero = true;
		if (anyZero) {
			stderr(
				'apq recon: --predict-strip: WARNING: one or more patterns matched 0 occurrences anywhere in the filtered set — see per-pattern totals\n'
			);
			return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	private static function defaultReconRoot(): String {
		final fork: Null<String> = resolveForkPath();
		if (fork == null || fork.length == 0) return '';
		final candidate: String = '$fork/test/testcases';
		final resolved: String = FileSystem.exists(candidate) && FileSystem.isDirectory(candidate) ? candidate : fork;
		// Write-cache: persist the env-supplied path to
		// `~/.config/anyparse/fork_path` so the next `apq recon` works
		// WITHOUT re-exporting the env var. Env always wins; the cache
		// is consulted only by `resolveForkPath` when env is unset.
		// `tryWriteForkPathCache` short-circuits when the on-disk value
		// already matches, so steady-state writes are no-ops.
		#if (sys || nodejs)
		final envFork: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		if (envFork != null && envFork.length > 0) tryWriteForkPathCache(envFork);
		#end
		return resolved;
	}

	/**
	 * Resolve the haxe-formatter fork path with env > config-cache
	 * precedence. The env var IS the canonical source — the cache
	 * exists only to spare the user from re-exporting it on every
	 * session. A cached path that no longer points at a directory is
	 * dropped silently (a stale config should never block a `recon` run
	 * — the user gets the same `env var is unset` usage error as before).
	 */
	private static function resolveForkPath(): Null<String> {
		final env: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		if (env != null && env.length > 0) return env;
		#if (sys || nodejs)
		final cached: Null<String> = readForkPathCache();
		if (cached != null && cached.length > 0 && FileSystem.exists(cached) && FileSystem.isDirectory(cached)) return cached;
		#end
		return null;
	}

	/**
	 * Emit a stderr nudge when any `.hx` file under `src/` or `test/` is
	 * newer than `bin/test.js` — the next `node bin/test.js` will run
	 * STALE bytes and a 0-delta sweep / clean test-summary can lie. Drives
	 * the documented `[[feedback-rebuild-test-js-after-macro-edit]]`
	 * trap: `bin/apq.js` auto-rebuilds (the hxq shim handles it) but
	 * `bin/test.js` is a separate build artefact whose staleness has no
	 * gate elsewhere in the workflow.
	 *
	 * Silent on `#if !sys`, on missing `bin/test.js` (caller will hit a
	 * clean error from the missing binary), or when nothing under src/
	 * or test/ is newer. Best-effort: a FileSystem failure short-circuits
	 * without raising — the user always gets the requested totals.
	 */
	private static function warnIfTestJsStale(cmd: String): Void {
		#if (sys || nodejs)
		final binPath: String = 'bin/test.js';
		if (!FileSystem.exists(binPath)) return;
		try {
			final binTime: Float = FileSystem.stat(binPath).mtime.getTime();
			if (anyHxNewerThan('src', binTime) || anyHxNewerThan('test', binTime)) {
				stderr(
					'apq $cmd: WARNING: src/ or test/ is newer than bin/test.js — re-run `haxe test-js.hxml && node bin/test.js` before trusting these totals\n'
				);
			}
		} catch (_: Exception) {
			// best-effort: skip the staleness advisory on any FS error
		}
		#end
	}

	#if (sys || nodejs)
	private static function anyHxNewerThan(root: String, threshold: Float): Bool {
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) return false;
		final stack: Array<String> = [root];
		while (stack.length > 0) {
			final dir: Null<String> = stack.pop();
			if (dir == null) break;
			try {
				for (name in FileSystem.readDirectory(dir)) {
					final path: String = '$dir/$name';
					if (FileSystem.isDirectory(path)) {
						stack.push(path);
						continue;
					}
					if (!StringTools.endsWith(name, '.hx')) continue;
					if (FileSystem.stat(path).mtime.getTime() > threshold) return true;
				}
			} catch (_: Exception) {
				// best-effort: a stat failure falls through to return false
			}
		}
		return false;
	}

	private static function forkPathCacheFile(): Null<String> {
		final home: Null<String> = Sys.getEnv('HOME');
		return home == null || home.length == 0 ? null : '$home/.config/anyparse/fork_path';
	}

	private static function readForkPathCache(): Null<String> {
		final path: Null<String> = forkPathCacheFile();
		if (path == null || !FileSystem.exists(path)) return null;
		try {
			final raw: String = sys.io.File.getContent(path);
			final trimmed: String = StringTools.trim(raw);
			return trimmed.length > 0 ? trimmed : null;
		} catch (_: Exception) {
			return null;
		}
	}

	private static function tryWriteForkPathCache(value: String): Void {
		final path: Null<String> = forkPathCacheFile();
		if (path == null) return;
		// Skip write when the cache already matches — avoids a useless
		// disk hit on every recon invocation under the same env.
		try {
			if (FileSystem.exists(path)) {
				final existing: String = StringTools.trim(sys.io.File.getContent(path));
				if (existing == value) return;
			}
		} catch (_: Exception) {
			// best-effort: an unreadable existing file just proceeds to (over)write
		}
		try {
			final dir: String = haxe.io.Path.directory(path);
			if (dir.length > 0 && !FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			sys.io.File.saveContent(path, value);
		} catch (_: Exception) {
			// Best-effort cache write — never block recon on a write
			// failure (read-only HOME, disk full, permission). The env
			// path stays valid for the current run.
		}
	}
	#end

	private static function stripRootPrefix(path: String, root: String): String {
		return StringTools.startsWith(path, root + '/') ? path.substr(root.length + 1) : path == root ? '.' : path;
	}

	private static function addReconCluster(map: Map<String, ReconCluster>, key: String, file: String, rawLocus: String): Void {
		final prev: Null<ReconCluster> = map[key];
		if (prev == null) {
			map[key] = {
				count: 1,
				examples: [file],
				paths: [file],
				rawSample: rawLocus
			};
		} else {
			prev.count++;
			prev.paths.push(file);
			if (prev.examples.length < RECON_EXAMPLES_PER_CLUSTER) prev.examples.push(file);
		}
	}

	/**
	 * Raw forward locus — `RECON_LOCUS_LEN` chars starting AT the fail
	 * position. Used both as the cluster's raw sample (display) and as
	 * input to the normaliser (cluster key).
	 */
	private static function reconRawLocus(input: String, offset: Int): String {
		final start: Int = offset > input.length ? input.length : offset;
		final end: Int = start + RECON_LOCUS_LEN > input.length ? input.length : start + RECON_LOCUS_LEN;
		return input.substring(start, end);
	}

	/**
	 * Normalise the forward locus into a cluster key — identifier runs
	 * of length > 4 collapse to `_`, shorter runs (Haxe short keywords
	 * `var`, `is`, `as`, `in`, `for`, `try`, `new`, `if`, `else`,
	 * `case`, etc.) are kept verbatim so they remain visible in the
	 * histogram. Punctuation, operators and whitespace pass through.
	 * `reconNormalize` then escapes whitespace for one-line display.
	 */
	private static function reconNormalizeLocus(raw: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < raw.length) {
			final c: Int = StringTools.fastCodeAt(raw, i);
			final isIdStart: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
			if (isIdStart) {
				var j: Int = i + 1;
				while (j < raw.length) {
					final cj: Int = StringTools.fastCodeAt(raw, j);
					final isIdCont: Bool = (cj >= 'a'.code && cj <= 'z'.code) || (cj >= 'A'.code && cj <= 'Z'.code)
						|| (cj >= '0'.code && cj <= '9'.code) || cj == '_'.code;
					if (!isIdCont) break;
					j++;
				}
				final identLen: Int = j - i;
				if (identLen > 4)
					buf.add('_');
				else
					for (k in i...j) buf.addChar(StringTools.fastCodeAt(raw, k));
				i = j;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return reconNormalize(buf.toString());
	}

	/**
	 * Source window of `RECON_HEAD_LEN` characters centred on `offset`
	 * — the text around the farthest-failure locus, for the human-
	 * readable SKIP line. Whitespace is escaped by `reconNormalize`.
	 */
	private static function reconSnippet(input: String, offset: Int): String {
		final half: Int = Std.int(RECON_HEAD_LEN / 2);
		final centre: Int = offset > input.length ? input.length : offset;
		final start: Int = centre - half < 0 ? 0 : centre - half;
		final end: Int = centre + half > input.length ? input.length : centre + half;
		return input.substring(start, end);
	}

	private static function reconNormalize(message: Null<String>): String {
		return message == null || message == ''
			? '<no message>'
			: StringTools.replace(StringTools.replace(message, '\n', '\\n'), '\t', '\\t');
	}

	/**
	 * `apq sweep` — read-only view on the corpus harness's
	 * `bin/.last-sweep.json` snapshot. Prints totals (+ Δ vs a prior
	 * snapshot if `--prev <path>` is given) without re-running the
	 * corpus. THE no-corpus-rerun lookup for "what does the last sweep
	 * say" — closes the manual `cat bin/.last-sweep.json | grep` +
	 * `tail /tmp/sweep.log | grep ===== sweep totals` dance.
	 *
	 * Default path is `bin/.last-sweep.json` (matches the corpus
	 * harness's `SWEEP_JSON_PATH` constant). `--file <path>` overrides
	 * — useful for sanity-checking an alternate snapshot. Exit 0 when
	 * the file is read; exit 1 when it doesn't exist or is unparseable.
	 */
	private static function runSweep(args: Array<String>): Int {
		var filePath: String = 'bin/.last-sweep.json';
		var prevPath: Null<String> = null;
		var diffPath: Null<String> = null;
		// `--save <path>`: discoverable shorthand for "copy the current
		// snapshot to <path> so I can `--prev` / `--diff` against it
		// after the next sweep". Replaces the manual
		// `cp bin/.last-sweep.json /tmp/prev.json` step that's easy to
		// forget before a grammar slice. Performs the copy AFTER the
		// totals print so the user still sees the snapshot's contents.
		var savePath: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--file':
					filePath = expectValue(args, ++i, '--file');
				case '--prev':
					prevPath = expectValue(args, ++i, '--prev');
				case '--diff':
					// Allow bare `--diff` (no arg) → default to
					// `bin/.prev-sweep.json` (auto-rotated by the corpus
					// harness before every sweep write). The next-token
					// check follows expectValue's contract: a `--`-prefixed
					// token is a flag, not a value.
					if (i + 1 < args.length && !StringTools.startsWith(args[i + 1], '--')) {
						diffPath = expectValue(args, ++i, '--diff');
					} else {
						diffPath = 'bin/.prev-sweep.json';
					}
				case '--save':
					savePath = expectValue(args, ++i, '--save');
				case '--lang':
					// hxq shim auto-injects --lang haxe; harmless here (sweep
					// reads a JSON snapshot, no grammar plugin needed). Accept
					// + consume the value to keep shim invariance.
					expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printSweepUsage();
					return EXIT_OK;
				case _:
					stderr('apq sweep: unknown option "$a"\n');
					printSweepUsage();
					return EXIT_USAGE;
			}
			i++;
		}
		final cur: Null<SweepTotals> = loadSweepJson(filePath);
		if (cur == null) {
			stderr('apq sweep: cannot read $filePath (missing or unparseable)\n');
			return EXIT_RUNTIME;
		}
		warnIfTestJsStale('sweep');
		final total: Int = cur.pass + cur.fail + cur.skipParse + cur.skipWrite + cur.skipConfig + cur.skipMalformed;
		sysPrint(
			'${cur.pass} pass / ${cur.fail} fail / ${cur.skipParse} skip-parse / ${cur.skipWrite} skip-write / ${cur.skipConfig} skip-config / ${cur.skipMalformed} malformed (total $total)\n'
		);
		if (prevPath != null) {
			final prev: Null<SweepTotals> = loadSweepJson(prevPath);
			if (prev == null) {
				stderr('apq sweep: cannot read --prev $prevPath\n');
				return EXIT_RUNTIME;
			}
			sysPrint(
				'  Δpass ${sweepSigned(cur.pass - prev.pass)} / Δfail ${sweepSigned(cur.fail - prev.fail)} / Δskip-parse ${sweepSigned(cur.skipParse - prev.skipParse)}  vs $prevPath (${prev.pass} / ${prev.fail} / ${prev.skipParse})\n'
			);
		}
		if (savePath != null) {
			try {
				final raw: String = sys.io.File.getContent(filePath);
				sys.io.File.saveContent((savePath: String), raw);
				sysPrint('apq sweep: saved snapshot $filePath -> $savePath\n');
			} catch (e: Exception) {
				stderr('apq sweep: --save failed: ${e.message}\n');
				return EXIT_RUNTIME;
			}
		}
		return diffPath != null ? runSweepDiff(filePath, diffPath) : EXIT_OK;
	}

	/**
	 * Per-fixture status diff between two sweep snapshots. THE answer to
	 * "which fixtures flipped between these two runs" — replaces the
	 * ad-hoc python3 reads against `bin/.last-sweep.json`'s `fixtures`
	 * array. Composes with `--prev` (totals delta is printed first, then
	 * the per-fixture rows; the two are orthogonal).
	 *
	 * Output shape: one line per changed path, plus a transition-count
	 * breakdown summary. Sorted by path for deterministic output.
	 */
	private static function runSweepDiff(curPath: String, prevPath: String): Int {
		final cur: Map<String, String> = loadSweepFixtureStatus(curPath);
		final prev: Map<String, String> = loadSweepFixtureStatus(prevPath);
		if (!cur.iterator().hasNext()) {
			stderr(
				'apq sweep: --diff: $curPath has no `fixtures` array — re-run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK to seed it\n'
			);
			return EXIT_RUNTIME;
		}
		if (!prev.iterator().hasNext()) {
			stderr('apq sweep: --diff: $prevPath has no `fixtures` array\n');
			return EXIT_RUNTIME;
		}
		final allPaths: Map<String, Bool> = [];
		for (k in cur.keys()) allPaths.set(k, true);
		for (k in prev.keys()) allPaths.set(k, true);
		final sorted: Array<String> = [for (k in allPaths.keys()) k];
		sorted.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
		final transitions: Map<String, Int> = [];
		var changed: Int = 0;
		for (path in sorted) {
			final ps: Null<String> = prev.get(path);
			final cs: Null<String> = cur.get(path);
			if (ps == cs) continue;
			changed++;
			final key: String = if (ps == null)
				'ADDED($cs)'
			else if (cs == null)
				'REMOVED($ps)'
			else
				'$ps->$cs';
			transitions.set(key, (transitions.get(key) ?? 0) + 1);
			if (ps == null)
				sysPrint('ADDED $path (now $cs)\n');
			else if (cs == null)
				sysPrint('REMOVED $path (was $ps)\n');
			else
				sysPrint('$ps -> $cs: $path\n');
		}
		final breakdown: Array<String> = [for (k => v in transitions) '$k: $v'];
		breakdown.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
		if (changed == 0)
			sysPrint('--- sweep --diff: 0 fixtures changed (snapshots identical) ---\n');
		else
			sysPrint('--- sweep --diff: $changed fixtures changed (${breakdown.join(', ')}) ---\n');
		return EXIT_OK;
	}

	private static function loadSweepJson(path: String): Null<SweepTotals> {
		return !sys.FileSystem.exists(path)
			? null
			: try {
				final raw: String = sys.io.File.getContent(path);
				final obj: Dynamic = haxe.Json.parse(raw);
				final pass: Null<Int> = Reflect.hasField(obj, 'pass') ? Reflect.field(obj, 'pass') : null;
				final fail: Null<Int> = Reflect.hasField(obj, 'fail') ? Reflect.field(obj, 'fail') : null;
				final skipParse: Null<Int> = Reflect.hasField(obj, 'skipParse') ? Reflect.field(obj, 'skipParse') : null;
				final skipWrite: Null<Int> = Reflect.hasField(obj, 'skipWrite') ? Reflect.field(obj, 'skipWrite') : null;
				final skipConfig: Null<Int> = Reflect.hasField(obj, 'skipConfig') ? Reflect.field(obj, 'skipConfig') : null;
				final skipMalformed: Null<Int> = Reflect.hasField(obj, 'skipMalformed') ? Reflect.field(obj, 'skipMalformed') : null;
				if (pass == null || fail == null || skipParse == null) return null;
				{
					pass: pass,
					fail: fail,
					skipParse: skipParse,
					skipWrite: skipWrite ?? 0,
					skipConfig: skipConfig ?? 0,
					skipMalformed: skipMalformed ?? 0,
				};
			} catch (_: Exception) null;
	}

	private static inline function sweepSigned(n: Int): String return n > 0 ? '+$n' : '$n';

	private static function printSweepUsage(): Void {
		sysPrint('Usage: apq sweep [--file <path>] [--prev <path>] [--diff <path>] [--save <path>]\n');
		sysPrint('\n');
		sysPrint('Read the corpus harness sweep snapshot (`bin/.last-sweep.json` by\n');
		sysPrint('default) and print totals + optional delta vs a prior snapshot.\n');
		sysPrint('No corpus rerun — only reads JSON.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --file <path>   Snapshot file (default: bin/.last-sweep.json)\n');
		sysPrint('  --prev <path>   Compare against another snapshot, print Δ triple\n');
		sysPrint('  --diff <path>   Per-fixture status diff vs another snapshot (PASS->FAIL,\n');
		sysPrint('                  FAIL->PASS, ADDED/REMOVED entries). Composes with --prev.\n');
		sysPrint('                  Auto-default: `bin/.prev-sweep.json` (the corpus harness\n');
		sysPrint('                  auto-rotates this before each sweep write), no path needed.\n');
		sysPrint('  --save <path>   Copy the current snapshot to <path>. Use before a grammar\n');
		sysPrint('                  slice to capture a baseline for `--prev` / `--diff` later.\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	/**
	 * `apq test-summary [<file>]` — parse a utest stdout transcript and
	 * print `N tests / M assertions / F failures / E errors`. Replaces
	 * the manual `grep -cE ': OK' /tmp/test.out` + assertion-count
	 * one-liner I keep rebuilding after every test run.
	 *
	 * Source resolution: positional path (file), `-` (stdin), or default
	 * `/tmp/test.out` when run with no positional and the file exists.
	 * Always exits 0 on a successful parse, 1 on read failure — the test
	 * outcome is informational (the test runner's exit code is the
	 * authoritative pass/fail signal).
	 *
	 * Parse rules (utest 1.13.x format, what `node bin/test.js` emits):
	 *  - `  testName: OK <dots>` — one line per test; trailing dots are
	 *    one per assertion.
	 *  - `  testName: FAIL` / `  testName: ERROR` — failure / error
	 *    counters; case-insensitive substring match on the suffix.
	 */
	private static function runTestSummary(args: Array<String>): Int {
		var sourcePath: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '-h', '--help':
					printTestSummaryUsage();
					return EXIT_OK;
				case '--lang':
					// Shim invariance — apq test-summary doesn't use a plugin.
					expectValue(args, ++i, '--lang');
				case _:
					if (sourcePath != null) {
						stderr('apq test-summary: only one positional source supported (got "$sourcePath" and "$a")\n');
						return EXIT_USAGE;
					}
					sourcePath = a;
			}
			i++;
		}
		final raw: String = try {
			switch (sourcePath) {
				case null: {
					if (sys.FileSystem.exists('/tmp/test.out'))
						sys.io.File.getContent('/tmp/test.out');
					else {
						stderr('apq test-summary: no source given and /tmp/test.out missing — pass <path> or `-` for stdin\n');
						return EXIT_USAGE;
					}
				}
				case '-': {
					readStdin();
				}
				case _: {
					sys.io.File.getContent((sourcePath: String));
				}
			}
		} catch (e: Exception) {
			stderr('apq test-summary: read failed: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final result: TestSummaryResult = parseTestSummary(raw);
		final src: String = sourcePath ?? '/tmp/test.out';
		warnIfTestJsStale('test-summary');
		sysPrint(
			'${result.tests} tests / ${result.assertions} assertions / ${result.failures} failures / ${result.errors} errors  ($src)\n'
		);
		final ff: Null<TestSummaryFailureLocus> = result.firstFailure;
		if (ff != null) {
			final classQual: String = ff.className.length > 0 ? '${ff.className}.' : '';
			final lineFrag: String = ff.line >= 0 ? '  line:${ff.line}' : '';
			final msgFrag: String = ff.message.length > 0 ? '  ${ff.message}' : '';
			final label: String = ff.kind == TestSummaryFailureKind.Error ? 'error' : 'failure';
			sysPrint('first $label: $classQual${ff.testName}$lineFrag$msgFrag\n');
		}
		return EXIT_OK;
	}

	/**
	 * `apq self-status [<dir>]` — walk `<dir>` recursively (default `src/`),
	 * try every `.hx` file via the grammar plugin's trivia parser, print
	 * one `SKIP <path> :: LINE:COL <message>` line per failure plus a
	 * footer `--- self-status: M parseable, N skip-parse (total T) ---`.
	 *
	 * Solves the dogfooding gap where `hxq` walkers silently skip
	 * unparseable files: the user finds out a file is unparseable only by
	 * grepping warnings emitted by `lit` / `refs` / `uses` etc., one at a
	 * time. `self-status` surfaces the full skip-parse set in one call.
	 *
	 * Exit code is 0 even when files skip-parse — this is a status report,
	 * not a check. `--strict` flips to non-zero on any skip-parse so CI
	 * wiring can guard against regressions.
	 */
	private static function runSelfStatus(args: Array<String>): Int {
		var lang: String = 'haxe';
		var rootDir: Null<String> = null;
		var strict: Bool = false;
		var showSource: Bool = false;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '-h', '--help':
					printSelfStatusUsage();
					return EXIT_OK;
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--strict':
					strict = true;
				case '--source':
					showSource = true;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq self-status: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (rootDir != null) {
						stderr('apq self-status: only one positional <dir> supported (got "$rootDir" and "$a")\n');
						return EXIT_USAGE;
					}
					rootDir = a;
			}
			i++;
		}
		final root: String = rootDir ?? 'src';
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			stderr('apq self-status: "$root" is not a directory.\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = pickPlugin(lang);
		var parseable: Int = 0;
		var skipParse: Int = 0;
		final skipLines: Array<String> = [];
		final stack: Array<String> = [root];
		while (stack.length > 0) {
			final dir: Null<String> = stack.pop();
			if (dir == null) break;
			final names: Array<String> = FileSystem.readDirectory(dir);
			names.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) {
				final path: String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!StringTools.endsWith(name, '.hx')) continue;
				final source: String = try readSourceForParse(path) catch (_: Exception) continue;
				try {
					plugin.parseFile(source);
					parseable++;
				} catch (exception: ParseError) {
					skipParse++;
					final pos: Position = exception.span.lineCol(source);
					final exp: String = reconNormalize(exception.expected);
					final src: String = showSource ? ' :: src="' + reconNormalize(reconSnippet(source, exception.span.from)) + '"' : '';
					skipLines.push('SKIP $path :: ${pos.line}:${pos.col} expected="$exp"$src');
				} catch (exception: Exception) {
					skipParse++;
					skipLines.push('SKIP $path :: <non-ParseError> ${reconNormalize(exception.message)}');
				}
			}
		}
		skipLines.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		for (line in skipLines) sysPrint('$line\n');
		final total: Int = parseable + skipParse;
		sysPrint('--- self-status: $parseable parseable, $skipParse skip-parse (total $total) ---\n');
		return (strict && skipParse > 0) ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function printSelfStatusUsage(): Void {
		sysPrint('apq self-status [<dir>] [--strict] [--source]\n');
		sysPrint('\n');
		sysPrint('Walks <dir> recursively (default `src/`) and prints which `.hx` files\n');
		sysPrint('the grammar plugin cannot parse. Each failure shows as:\n');
		sysPrint('  SKIP <path> :: LINE:COL expected="<X>"\n');
		sysPrint('\n');
		sysPrint('With --source the SKIP line gains a `:: src="<window>"` tail showing\n');
		sysPrint('the bytes around the fail-locus (same format as `recon --probe`).\n');
		sysPrint('\n');
		sysPrint('Closes the dogfood gap: hxq walkers silently skip unparseable files;\n');
		sysPrint('self-status surfaces the full set in one call.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --strict       Exit non-zero when any file skip-parses (CI guard).\n');
		sysPrint('  --source       Append windowed source around each fail-locus.\n');
		sysPrint('  --lang <name>  Grammar plugin (default `haxe`).\n');
		sysPrint('  -h, --help     Show this help.\n');
	}

	#if (sys || nodejs)
	/**
	 * `apq source <file> [--range SPEC] [--number]` — emit a file's RAW
	 * verbatim lines with NO AST parse, so it works on ANY file (parseable
	 * or skip-parse). Default output is unprefixed lines — directly usable
	 * for anchoring an Edit — replacing the `git show … > /tmp/.txt` /
	 * `node readFileSync` dance (the Read tool fabricates `.hx` past the
	 * first lines; cat/sed/grep are gated; this hxq subcommand is allowed).
	 *
	 * `--range SPEC` is 1-based inclusive: `L` (single line), `L:L2`
	 * (range), `L:` (L to EOF), `:L2` (start to L2). Out-of-range bounds
	 * clamp to the file (friendly, no crash). `--number` / `-n` switches to
	 * `cat -n`-style `<lineno>\t<line>` output for navigation.
	 */
	private static function runSource(args: Array<String>): Int {
		var lang: String = 'haxe';
		var range: Null<String> = null;
		var selectExpr: Null<String> = null;
		var atSpec: Null<String> = null;
		var number: Bool = false;
		var raw: Bool = false;
		var file: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--range':
					range = expectValue(args, ++i, '--range');
				case '--select':
					selectExpr = expectValue(args, ++i, '--select');
				case '--at':
					atSpec = expectValue(args, ++i, '--at');
				case '--number', '-n':
					number = true;
				case '--raw':
					raw = true;
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printSourceUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq source: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
						stderr('apq source: only one file argument supported (got "$file" and "$a")\n');
						return EXIT_USAGE;
					}
					file = a;
			}
			i++;
		}

		if (file == null) {
			stderr('apq source: missing <file> argument\n');
			printSourceUsage();
			return EXIT_USAGE;
		}
		final modes: Int = (range != null ? 1 : 0) + (selectExpr != null ? 1 : 0) + (atSpec != null ? 1 : 0);
		if (modes > 1) {
			stderr('apq source: --range, --select and --at are mutually exclusive — pick one\n');
			return EXIT_USAGE;
		}
		final path: String = file;
		if (!FileSystem.exists(path)) {
			stderr('apq source: no such file "$path"\n');
			return EXIT_RUNTIME;
		}
		if (FileSystem.isDirectory(path)) {
			stderr('apq source: "$path" is a directory (source views one file)\n');
			return EXIT_RUNTIME;
		}

		final content: String = readFile(path);
		// Split on `\n` so a trailing newline does not synthesise a spurious
		// empty final line — the standard "lines = N+1 splits, last empty"
		// is dropped to keep line numbers aligned with an editor's view.
		final lines: Array<String> = content.split('\n');
		if (lines.length > 0 && lines[lines.length - 1] == '') lines.pop();

		// `--select` / `--at` resolve a NODE's span to its line range (these
		// parse the file — unlike the raw, parse-free `--range` / whole-file
		// path, which still works on a skip-parse file).
		final bounds: Null<{ from: Int, to: Int }> = if (selectExpr != null || atSpec != null)
			resolveNodeLineBounds(path, content, lang, selectExpr, atSpec);
		else
			parseRangeSpec(range, lines.length);
		if (bounds == null) {
			if (selectExpr != null || atSpec != null) return EXIT_RUNTIME;
			stderr('apq source: bad --range "$range" (use L, L:L2, L:, or :L2 — 1-based)\n');
			return EXIT_USAGE;
		}

		// Strip the common leading-whitespace prefix shared by every non-blank
		// line in the range (textwrap.dedent) so a deeply-nested slice reads
		// without its indentation tax. `--raw` keeps bytes verbatim — required
		// when the output anchors an Edit or feeds column coordinates, since
		// dedent shifts both.
		final strip: Int = raw ? 0 : commonIndentWidth(lines, bounds.from, bounds.to);

		final buf: StringBuf = new StringBuf();
		for (n in bounds.from...bounds.to + 1) {
			final line: String = lines[n - 1];
			if (number) buf.add('$n\t');
			buf.add(strip > 0 ? dedentLine(line, strip) : line);
			buf.add('\n');
		}
		sysPrint(buf.toString());
		return EXIT_OK;
	}

	/**
	 * Parse a `source --range` spec into a 1-based inclusive `{from, to}`
	 * line pair, clamped to `[1, lineCount]`. Forms: `null`/`""` → whole
	 * file; `L` → single line; `L:L2` → range; `L:` → L to EOF; `:L2` →
	 * start to L2. Returns `null` on a malformed spec (non-int part, or an
	 * inverted range after clamping). An empty file (`lineCount == 0`)
	 * yields an empty `{1, 0}` range so the caller prints nothing.
	 */
	private static function parseRangeSpec(spec: Null<String>, lineCount: Int): Null<{ from: Int, to: Int }> {
		if (lineCount == 0) return { from: 1, to: 0 };
		if (spec == null || spec.length == 0) return { from: 1, to: lineCount };
		final colon: Int = spec.indexOf(':');
		if (colon < 0) {
			final single: Null<Int> = Std.parseInt(spec);
			if (single == null) return null;
			final clamped: Int = clampLine(single, lineCount);
			return { from: clamped, to: clamped };
		}
		final loStr: String = spec.substring(0, colon);
		final hiStr: String = spec.substring(colon + 1);
		final lo: Null<Int> = loStr.length == 0 ? 1 : Std.parseInt(loStr);
		final hi: Null<Int> = hiStr.length == 0 ? lineCount : Std.parseInt(hiStr);
		if (lo == null || hi == null) return null;
		final from: Int = clampLine(lo, lineCount);
		final to: Int = clampLine(hi, lineCount);
		return from > to ? null : { from: from, to: to };
	}

	/** Clamp a 1-based line number into `[1, lineCount]`. */
	private static inline function clampLine(n: Int, lineCount: Int): Int {
		return n < 1 ? 1 : (n > lineCount ? lineCount : n);
	}

	private static function printSourceUsage(): Void {
		sysPrint('Usage: apq source [options] <file>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --range <spec>     1-based inclusive lines: L | L:L2 | L: | :L2 (default: whole file)\n');
		sysPrint('  --select <sel>     Source of the node matching <sel> (apq ast selector,\n');
		sysPrint("                     e.g. 'FnMember:foo' / 'ClassDecl:Bar') — must match exactly one\n");
		sysPrint('  --at <line>:<col>  Source of the innermost node at the 1-based position\n');
		sysPrint('  --number, -n       Prefix each line with `<lineno>\\t` (cat -n style)\n');
		sysPrint('  --raw              Keep bytes verbatim — no dedent (for Edit-anchoring / real columns)\n');
		sysPrint('  --lang <name>      Grammar plugin for --select / --at (default: haxe)\n');
		sysPrint('  -h, --help         Show this help\n');
		sysPrint('\n');
		sysPrint('Emits RAW lines of <file>. The default / `--range` path does NO parse and\n');
		sysPrint('works on any file (parseable or skip-parse). `--select` / `--at` parse the\n');
		sysPrint('file and print the full lines spanning the matched node — the clean way to\n');
		sysPrint("read ONE function by name (no line numbers, no S-expr): apq source f.hx --select 'FnMember:foo'.\n");
		sysPrint('\n');
		sysPrint('By default the common leading indentation shared by the shown lines is\n');
		sysPrint('stripped (dedent) so nested slices read cleanly; pass `--raw` to keep exact\n');
		sysPrint('bytes — needed when the output anchors an Edit or you need true column\n');
		sysPrint('positions. The gate-blessed replacement for `git show` / `readFileSync`.\n');
	}
	#end

	/**
	 * Pure parser over a utest stdout transcript. Exposed for unit tests so
	 * the structured result (counts + first-failure locus) can be asserted
	 * directly without the stdout-capture round-trip Cli.run would impose.
	 *
	 * Line shape recognition (utest 1.13.x):
	 *  - `  testName: OK <dots>` — pass; dot-count adds to assertions.
	 *  - `  testName: FAIL[URE] <…>` — failure counter.
	 *  - `  testName: ERR[OR] <…>` — error counter.
	 *  - `ClassName` (unindented CamelCase token, no colon) — class header;
	 *    tracked so first-failure carries its qualifier.
	 *  - `    <detail>` (4-space indent) following a fail/err — the
	 *    failure's detail line. `line: N, <msg>` and
	 *    `fileName: X, line: N, <msg>` shapes are decoded into structured
	 *    fields; bare detail falls into `message`.
	 *
	 * The detail capture only fires for the FIRST fail/err — once
	 * `firstFailure` is set, subsequent failures only bump counters.
	 */
	public static function parseTestSummary(raw: String): TestSummaryResult {
		final okRe: EReg = ~/^\s+(\w[\w.]*):\s+OK(\s+(\.+))?/;
		final failRe: EReg = ~/^\s+(\w[\w.]*):\s+FAIL/;
		final errRe: EReg = ~/^\s+(\w[\w.]*):\s+ERR/;
		final classRe: EReg = ~/^([A-Z]\w*)$/;
		final detailFullRe: EReg = ~/^\s*fileName:\s*([^,]+),\s*line:\s*(\d+),\s*(.*)$/;
		final detailLineRe: EReg = ~/^\s*line:\s*(\d+),\s*(.*)$/;
		// Bare-message detail: any non-zero indent + non-empty content.
		// Widened from `\s{4,}` because utest's indent isn't guaranteed
		// 4-space (tabs / 2-space variants exist in older transcripts).
		final detailBareRe: EReg = ~/^\s+(\S.*)$/;
		var tests: Int = 0;
		var assertions: Int = 0;
		var failures: Int = 0;
		var errors: Int = 0;
		var currentClass: String = '';
		var firstFailure: Null<TestSummaryFailureLocus> = null;
		var awaitingDetail: Bool = false;
		for (line in raw.split('\n')) {
			if (awaitingDetail) {
				awaitingDetail = false;
				final locus: Null<TestSummaryFailureLocus> = firstFailure;
				if (locus != null && tryCaptureDetail(locus, line, detailFullRe, detailLineRe, detailBareRe)) continue;
				// Fall through: the line was NOT a detail row (utest emitted
				// no detail for this failure, or the next test row arrived
				// immediately). Re-process via the normal regex chain so we
				// don't silently swallow it.
			}
			if (okRe.match(line)) {
				tests++;
				final dots: Null<String> = try okRe.matched(3) catch (_: Exception) null;
				if (dots != null) assertions += (dots: String).length;
			} else if (failRe.match(line)) {
				failures++;
				if (firstFailure == null) {
					firstFailure = {
						className: currentClass,
						testName: failRe.matched(1),
						line: -1,
						message: '',
						kind: TestSummaryFailureKind.Fail
					};
					awaitingDetail = true;
				}
			} else if (errRe.match(line)) {
				errors++;
				if (firstFailure == null) {
					firstFailure = {
						className: currentClass,
						testName: errRe.matched(1),
						line: -1,
						message: '',
						kind: TestSummaryFailureKind.Error
					};
					awaitingDetail = true;
				}
			} else if (classRe.match(line)) {
				currentClass = classRe.matched(1);
			}
		}
		return {
			tests: tests,
			assertions: assertions,
			failures: failures,
			errors: errors,
			firstFailure: firstFailure
		};
	}

	private static function tryCaptureDetail(locus: TestSummaryFailureLocus, line: String, full: EReg, lineOnly: EReg, bare: EReg): Bool {
		// Disambiguate bare detail from regular test rows: a fail/err line
		// fits `bare` too (`^\s+\S.*`). The fail/err regexes already
		// consumed those, so we additionally require the bare branch to
		// NOT look like an indented test row (contain `: OK|FAIL|ERR`).
		if (full.match(line)) {
			locus.line = parsePositiveInt(full.matched(2));
			locus.message = StringTools.trim(full.matched(3));
			return true;
		}
		if (lineOnly.match(line)) {
			locus.line = parsePositiveInt(lineOnly.matched(1));
			locus.message = StringTools.trim(lineOnly.matched(2));
			return true;
		}
		if (bare.match(line) && !~/:\s+(OK|FAIL|ERR)/.match(line)) {
			locus.message = StringTools.trim(bare.matched(1));
			return true;
		}
		return false;
	}

	private static inline function parsePositiveInt(s: String): Int {
		final v: Null<Int> = Std.parseInt(s);
		return v ?? -1;
	}

	private static function printTestSummaryUsage(): Void {
		sysPrint('Usage: apq test-summary [<file> | -]\n');
		sysPrint('\n');
		sysPrint('Parse a utest stdout transcript and report tests / assertions / failures /\n');
		sysPrint('errors. Source resolution:\n');
		sysPrint('  <file>     — read from the given path\n');
		sysPrint('  -          — read from stdin (heredoc / pipe / process subst.)\n');
		sysPrint('  (default)  — `/tmp/test.out` if it exists, else usage error\n');
		sysPrint('\n');
		sysPrint('Parses lines of shape `  testName: OK <dots>` / `: FAIL` / `: ERROR`.\n');
		sysPrint('Dot count after `OK` is the assertion count (one dot per assert).\n');
		sysPrint('When any FAIL / ERROR is present, appends a second line with the first\n');
		sysPrint('failure\'s locus: `first failure: ClassName.testName  line:N  <message>`\n');
		sysPrint('(class header / line / message included when utest emitted them).\n');
		sysPrint('Always exits 0 on a successful parse — the test runner\'s exit code is\n');
		sysPrint('the authoritative pass/fail signal.\n');
	}
	#end

	private static function printReconUsage(): Void {
		sysPrint('Usage: apq recon [<dir>] [--top N | --all] [--cluster <substr> [--source]]\n');
		sysPrint('                 [--predict-strip --replace <pat> --with <repl> ... [--source]]\n');
		sysPrint('                 [--probe <file>]\n');
		sysPrint('\n');
		sysPrint('Sweep mode: walks every .hxtest under <dir> (section-2 auto-extracted),\n');
		sysPrint('runs the trivia parser, clusters failures by normalised forward-locus,\n');
		sysPrint('and prints SKIP lines + histogram. Default <dir> is\n');
		sysPrint("$ANYPARSE_HXFORMAT_FORK/test/testcases when the env var is set.\n");
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --lang <name>           Grammar plugin (default: haxe)\n');
		sysPrint('  --top N                 Show top N clusters (default: 30)\n');
		sysPrint('  --all                   Show every cluster\n');
		sysPrint('  --cluster <key>         Drill into ONE cluster: full path list instead of\n');
		sysPrint('                          histogram. EXACT match against the cluster key\n');
		sysPrint('                          shown in the histogram (with \\n / \\t escapes).\n');
		sysPrint('                          0-match exits non-zero with top keys for ref.\n');
		sysPrint('  --no-target-cluster <expected-msg>\n');
		sysPrint('                          With --predict-relax: drill into ONE bucket of the\n');
		sysPrint('                          footer NO TARGET breakdown — print every fixture\n');
		sysPrint('                          whose predict-relax outcome is NoTarget with\n');
		sysPrint('                          message == <expected-msg>. EXACT match against the\n');
		sysPrint('                          key shown in the footer histogram. Bridges the\n');
		sysPrint('                          footer aggregate to the file list — --cluster uses\n');
		sysPrint('                          a different namespace (forward-locus on raw bytes).\n');
		sysPrint('                          0-match exits non-zero with top NO TARGET keys.\n');
		sysPrint('                          Mutex with --cluster / --probe.\n');
		sysPrint('  --source                With --cluster, append a windowed source slice\n');
		sysPrint('                          around the fail-locus for each path (L±3).\n');
		sysPrint('                          With --predict-strip, also emits the window for\n');
		sysPrint('                          each STILL FAIL entry around the NEW fail-locus\n');
		sysPrint('                          (the moved-locus payload). With --predict-relax,\n');
		sysPrint('                          emits the window for STILL FAIL (around NEW locus\n');
		sysPrint('                          in patched source) and for NO TARGET entries in\n');
		sysPrint('                          drill/probe modes (around the ORIGINAL fail-locus,\n');
		sysPrint('                          which has no patch). Sweep-mode NO TARGET stays\n');
		sysPrint('                          collapsed into the footer histogram. Usage error\n');
		sysPrint('                          outside these modes.\n');
		sysPrint('  --predict-strip         Apply substitutions to each skip-parse source\n');
		sysPrint('                          and retry; print PREDICT UNBLOCK / STILL FAIL /\n');
		sysPrint('                          NO MATCH per file. Requires --replace/--with or\n');
		sysPrint('                          --delete; combinable with --cluster.\n');
		sysPrint('  --replace <pat> --with <repl>\n');
		sysPrint('                          Substitution pair (with --predict-strip; repeatable).\n');
		sysPrint('  --delete <pat>          Shortcut for --replace <pat> --with "".\n');
		sysPrint('  --regex                 Treat --replace / --delete patterns as EReg patterns\n');
		sysPrint('                          (global, applies to every match) instead of literal\n');
		sysPrint('                          substrings. Requires --predict-strip. One regex\n');
		sysPrint('                          covers every site of a construct in the corpus.\n');
		sysPrint('  --candidates <regex>    Cross-cluster enumeration: walk skip-parse fixtures,\n');
		sysPrint('                          print `<path> :: N matches` for every file with ≥1\n');
		sysPrint('                          regex hit (sorted by count desc) + summary. Use when\n');
		sysPrint('                          the histogram clusters by exact forward-locus and a\n');
		sysPrint('                          construct lives in differently-shaped multi-blocker\n');
		sysPrint('                          fixtures. Mutually exclusive with --predict-strip /\n');
		sysPrint('                          --cluster / --probe / --regression-probe.\n');
		sysPrint('  --probe <file>          Single-file probe instead of sweep. Composes with\n');
		sysPrint('                          --predict-strip: applies substitutions to the file and\n');
		sysPrint('                          retries the parse, printing PREDICT UNBLOCK / STILL\n');
		sysPrint('                          FAIL / NO MATCH + per-pattern totals + typo guard\n');
		sysPrint('                          (same shape as sweep mode).\n');
		sysPrint('  --regression-probe      Diff current corpus parse OK / SKIP_PARSE state against\n');
		sysPrint('                          the prior sweep snapshot (`bin/.last-sweep.json`).\n');
		sysPrint('                          Reports every fixture whose parse status FLIPPED since\n');
		sysPrint('                          the snapshot — REGRESSED (was PASS / FAIL / SKIP_WRITE,\n');
		sysPrint('                          now skip-parse) and UNBLOCKED (was SKIP_PARSE, now\n');
		sysPrint('                          parses). Cheap pre-edit / post-edit sanity check —\n');
		sysPrint('                          only runs the trivia parse, no writer / no expected-\n');
		sysPrint('                          bytes diff. Non-zero exit when any regression found.\n');
		sysPrint('                          Mutually exclusive with --probe / --predict-strip /\n');
		sysPrint('                          --cluster.\n');
		sysPrint('  --permissive-construct  Field-optionalization predictor for Slice 40\'s\n');
		sysPrint('                          `@:optional + @:lead + @:trail` mechanism. Walks every\n');
		sysPrint('                          `mandatory-ref-lead-trail` candidate from `apq gates\n');
		sysPrint('                          --mechanism mandatory-ref-lead-trail`, strips the\n');
		sysPrint('                          `<lead>...<trail>` bracket-pair from each skip-parse\n');
		sysPrint('                          fixture, re-parses, and aggregates UNBLOCK / STILL FAIL\n');
		sysPrint('                          / NO MATCH per candidate. THE pre-edit upper-bound\n');
		sysPrint('                          view of which field-optionalization would unblock\n');
		sysPrint('                          which fixtures. Mutually exclusive with every other\n');
		sysPrint('                          recon mode.\n');
		sysPrint('  --writer-equals         After --probe PARSE OK, also run writer round-trip +\n');
		sysPrint('                          byte-equality check vs the fixture\'s expected section\n');
		sysPrint('                          (or `--expected <path>` for plain .hx). Prints WRITER\n');
		sysPrint('                          PASS / FAIL upfront so you see whether the slice would\n');
		sysPrint('                          yield +1 PASS or skip→fail without running the corpus\n');
		sysPrint('                          sweep. Incompatible with --predict-strip / --predict-\n');
		sysPrint('                          relax (their patched source diverges from expected by\n');
		sysPrint('                          construction). Requires --probe.\n');
		sysPrint('  --writer-equals-plain   Same as --writer-equals but routes through the PLAIN\n');
		sysPrint('                          (non-trivia) pipeline (HxModuleParser → HxModuleWriter).\n');
		sysPrint('  --expected <path>       Override the expected-bytes source (default: .hxtest\n');
		sysPrint('                          section 3, or the input itself for raw .hx). Requires\n');
		sysPrint('                          --writer-equals.\n');
		sysPrint('  -h, --help              Show this help.\n');
	}

	private static function readFile(path: String): String {
		#if (sys || nodejs)
		return File.getContent(path);
		#else
		throw 'apq: file IO requires a sys target';
		#end
	}

	private static function writeFile(path: String, content: String): Void {
		#if (sys || nodejs)
		File.saveContent(path, content);
		#else
		throw 'apq: file IO requires a sys target';
		#end
	}

	/**
	 * Read all bytes from stdin and decode as UTF-8 source. Used by
	 * `apq ast --stdin` (and `apq probe -`) to accept inline source
	 * via shell pipe / heredoc / process substitution instead of
	 * `--code <s>` or a file path.
	 *
	 * On Node, `Sys.stdin().readAll()` raises `haxe.io.Error.Blocked`
	 * when stdin is a pipe (hxnodejs's sync stdin doesn't survive a
	 * partial read). Fall back to Node's native `fs.readFileSync(0)`
	 * which reads the full pipe to EOF synchronously.
	 */
	private static function readStdin(): String {
		#if nodejs
		final fs: Dynamic = js.Lib.require('fs');
		final buf: Dynamic = fs.readFileSync(0);
		return (buf: Dynamic).toString('utf8');
		#elseif sys
		return Sys.stdin().readAll().toString();
		#else
		throw 'apq: stdin requires a sys target';
		#end
	}

	/**
	 * Resolve the new-code text for a writer-emit mutation op (`add-member`
	 * / `replace-node` / `add-element`) when it comes from somewhere other
	 * than the inline positional argument: a `--from-file <path>`, or stdin
	 * when the positional is the literal `-` (mirroring `apq probe -`). This
	 * is the quote-safe input path for code containing `$` or `'` that the
	 * shell would otherwise mangle as a positional argument. Called only
	 * when `fromFile != null` or `code == '-'`; returns the resolved text,
	 * or null after printing the reason to stderr (the caller then exits
	 * non-zero). `opName` names the op in those messages.
	 */
	private static function resolveCodeArg(
		opName: String, code: Null<String>, fromFile: Null<String>, stripTrailing: Bool = false
	): Null<String> {
		if (fromFile != null && code != null) {
			stderr('apq $opName: provide the code inline, via --from-file, or as - for stdin — not more than one\n');
			return null;
		}
		if (fromFile != null) {
			try {
				return stripTrailing ? withoutTrailingNewline(readFile(fromFile)) : readFile(fromFile);
			} catch (exception: Exception) {
				stderr('apq $opName: $fromFile: ${exception.message}\n');
				return null;
			}
		}
		// code == '-' → read the new code from stdin.
		try {
			return stripTrailing ? withoutTrailingNewline(readStdin()) : readStdin();
		} catch (exception: Exception) {
			stderr('apq $opName: reading stdin: ${exception.message}\n');
			return null;
		}
	}

	/**
	 * Drop a single trailing newline (`\r\n` or `\n`) from `s`. The span-splice ops
	 * (`replace-node` / `add-element`) pass `stripTrailing = true` so a heredoc's mandatory
	 * trailing newline does not land inside the replaced span as a stray blank line — the
	 * writer regenerates the trivia after the span. Append ops (`add-member` / `new --raw`)
	 * leave it: there the writer already normalises the trailing newline away.
	 */
	private static function withoutTrailingNewline(s: String): String {
		return StringTools.endsWith(s, '\r\n')
			? s.substring(0, s.length - 2)
			: StringTools.endsWith(s, '\n') ? s.substring(0, s.length - 1) : s;
	}

	/**
	 * Read a file as **source for parsing**. Same as `readFile` for plain
	 * `.hx` files; auto-extracts the input section (between the 1st and
	 * 2nd `\n---\n` separators) when the path ends with `.hxtest` AND the
	 * content has the canonical 3-section layout (`config / input /
	 * expected`, as defined by `unit.HxFormatterCorpusHelpers`). This
	 * collapses the recurring `.hxtest` strip-test dance — `awk` /
	 * scratch-file extract followed by parse — into a direct
	 * `hxq strip /path/case.hxtest --replace … --with …`.
	 *
	 * Non-3-section `.hxtest` files (malformed, or a fork variant) pass
	 * through unchanged so the parser sees the raw bytes and the user
	 * gets a normal parse-error trace, not a silent transformation.
	 */
	private static function readSourceForParse(path: String): String {
		return readHxtestSectionOrRaw(path, 1);
	}

	/**
	 * Read a file as **expected output bytes** for byte-comparison
	 * (`writer-equals <input> <expected>`). Symmetric to
	 * `readSourceForParse`: when the path ends with `.hxtest` and has the
	 * canonical 3-section layout, returns section 3 (the fork's reference
	 * formatted output); otherwise returns the raw bytes. Lets a fork
	 * fixture serve as its own expected-bytes file in one command instead
	 * of pre-extracting via `awk` / scratch file.
	 */
	private static function readExpectedForCompare(path: String): String {
		return readHxtestSectionOrRaw(path, 2);
	}

	/**
	 * Common backend for the two `.hxtest`-aware readers. `sectionIdx`
	 * is the 0-based section index into the `\n---\n` split — `1` for
	 * the input source, `2` for the expected output. Trims exactly one
	 * leading and one trailing `\n` to mirror
	 * `HxFormatterCorpusHelpers.stripPadNewlines`.
	 */
	private static function readHxtestSectionOrRaw(path: String, sectionIdx: Int): String {
		final content: String = readFile(path);
		if (!StringTools.endsWith(path, '.hxtest')) return content;
		final parts: Array<String> = content.split('\n---\n');
		if (parts.length != 3) return content;
		var section: String = parts[sectionIdx];
		if (section.length > 0 && section.charAt(0) == '\n') section = section.substr(1);
		if (section.length > 0 && section.charAt(section.length - 1) == '\n') section = section.substr(0, section.length - 1);
		return section;
	}

	/**
	 * Resolve the writer-config JSON for `path`. For a `.hxtest` input it
	 * auto-extracts section-1 (the harness's per-fixture config), returning
	 * `null` when the file lacks the canonical 3-section layout. For a
	 * normal `.hx` it falls back to project-config DISCOVERY — the first
	 * `hxformat.json` found walking up from the file's directory (see
	 * `discoverFormatConfig`), so `apq` formats a file by its project's own
	 * style. `null` (no `.hxtest` section, no discovered config) leaves the
	 * plugin on its compiled defaults. The result feeds
	 * `plugin.writeRoundTrip(source, optsJson)`.
	 */
	private static function readWriteOptionsJsonOrNull(path: String): Null<String> {
		if (!StringTools.endsWith(path, '.hxtest')) return discoverFormatConfig(path);
		final content: String = readFile(path);
		final parts: Array<String> = content.split('\n---\n');
		if (parts.length != 3) return null;
		var section: String = parts[0];
		if (section.length > 0 && section.charAt(section.length - 1) == '\n') section = section.substr(0, section.length - 1);
		return section;
	}

	/**
	 * Walk up from `filePath`'s directory to the filesystem root and return
	 * the content of the first `hxformat.json` found — the project's writer
	 * style config (haxe-formatter JSON schema), loaded by the plugin via
	 * `HaxeFormatConfigLoader`. Returns `null` when no config exists on the
	 * path, leaving the writer on its compiled defaults. Mirrors how
	 * haxe-formatter / `.editorconfig` discover a per-project config, so a
	 * file outside any configured project still formats with the defaults.
	 */
	private static function discoverFormatConfig(filePath: String): Null<String> {
		#if (sys || nodejs)
		var dir: String = haxe.io.Path.directory(FileSystem.absolutePath(filePath));
		while (dir != '') {
			final candidate: String = dir + '/hxformat.json';
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) return File.getContent(candidate);
			final parent: String = haxe.io.Path.directory(dir);
			if (parent == dir) break;
			dir = parent;
		}
		return null;
		#else
		return null;
		#end
	}

	private static function expectValue(args: Array<String>, idx: Int, flag: String): String {
		if (idx >= args.length) throw 'apq: $flag requires a value';
		return args[idx];
	}

	/**
	 * Expand one-or-more file/dir/glob specs into a deduped path list,
	 * order-preserving. `singleFile` (parse-fail becomes a hard error,
	 * mirroring `apq ast`) holds only when exactly one spec was given
	 * and it resolved to exactly that one concrete file — multi-spec or
	 * glob/dir scans skip unparseable files silently.
	 */
	private static function expandInputs(specs: Array<String>, ext: String): { paths: Array<String>, singleFile: Bool } {
		final paths: Array<String> = [];
		for (spec in specs) for (p in Glob.expand(spec, ext)) if (!paths.contains(p)) paths.push(p);
		final singleFile: Bool = specs.length == 1 && paths.length == 1 && paths[0] == specs[0];
		return { paths: paths, singleFile: singleFile };
	}

	/**
	 * Keep at most `limit` hits total across the per-file entries,
	 * truncating the entry that crosses the budget and dropping the
	 * rest. `limit < 0` is "no limit" (the no-flag default). Generic
	 * over the entry shape: `len` reads a hit count, `trim` rebuilds an
	 * entry capped to the first `k` hits.
	 */
	private static function limitEntries<T>(entries: Array<T>, limit: Int, len: T -> Int, trim: (T, Int) -> T): Array<T> {
		if (limit < 0) return entries;
		final out: Array<T> = [];
		var remaining: Int = limit;
		for (e in entries) {
			if (remaining <= 0) break;
			final n: Int = len(e);
			if (n <= remaining) {
				out.push(e);
				remaining -= n;
			} else {
				out.push(trim(e, remaining));
				remaining = 0;
			}
		}
		return out;
	}

	/**
	 * Parse `--limit <n>` at position `i` (the flag itself already
	 * matched). Returns the parsed non-negative count, or throws the
	 * same way `expectValue` does on a missing/!int value — callers
	 * surface it as a usage error.
	 */
	private static function parseLimit(args: Array<String>, idx: Int): Int {
		final v: String = expectValue(args, idx, '--limit');
		final n: Null<Int> = Std.parseInt(v);
		if (n == null || n < 0) throw 'apq: --limit expects a non-negative integer, got "$v"';
		return n;
	}

	/**
	 * Walker flood guard. When the caller did NOT pass `--limit` (`limit < 0`)
	 * and the total hit count exceeds `AUTO_LIMIT_THRESHOLD`, returns the
	 * threshold AND prints a stderr nudge so the user sees the truncation
	 * happened. Otherwise returns `limit` unchanged.
	 *
	 * Killer case: `apq lit '/*' src/ --any-kind` previously flooded ~165KB
	 * of leaf hits. Now it caps to `AUTO_LIMIT_THRESHOLD` automatically and
	 * surfaces the count so the user can re-run with an explicit `--limit N`
	 * for a precise budget.
	 *
	 * `--limit 0` (any explicit value) is honoured verbatim — the guard
	 * only fires on the implicit "no limit" default.
	 */
	private static function effectiveAutoLimit(cmdName: String, limit: Int, totalHits: Int): Int {
		if (limit >= 0 || totalHits <= AUTO_LIMIT_THRESHOLD) return limit;
		stderr('apq $cmdName: auto-capped to $AUTO_LIMIT_THRESHOLD of $totalHits hits — pass `--limit N` for an explicit cap.\n');
		return AUTO_LIMIT_THRESHOLD;
	}

	private static inline final AUTO_LIMIT_THRESHOLD: Int = 500;

	private static function printUsage(): Void {
		sysPrint('apq — anyparse query CLI\n');
		sysPrint('\n');
		sysPrint('Usage: apq <command> [options] <file>\n');
		sysPrint('\n');
		sysPrint('Commands:\n');
		sysPrint('  ast           Dump parsed AST (S-expr or JSON)\n');
		sysPrint('  probe         AST/writer probe with inline source (no file IO)\n');
		sysPrint('  search        Structural pattern search\n');
		sysPrint('  refs          Symbol references (value bindings; scope-aware)\n');
		sysPrint('  rename        Scope-correct, format-preserving symbol rename\n');
		sysPrint('  move          Move a type declaration to another file (same package)\n');
		sysPrint('  symbols       List top-level type declarations across a scope (cross-file)\n');
		sysPrint('  importers     List files importing a given module (cross-file)\n');
		sysPrint('  declares      Declaration site(s) of one named type (ambiguity check)\n');
		sysPrint('  lint          Run analysis checks and report violations (e.g. unused-import)\n');
		sysPrint('  inline        Inline a local variable into its uses\n');
		sysPrint('  inline-method Inline a single-return function into its call sites + delete it\n');
		sysPrint('  extract-var   Hoist an expression into a new local final\n');
		sysPrint('  extract-method Extract a statement run into a local function (closure)\n');
		sysPrint('  add-param     Add a backward-compatible parameter to a function\n');
		sysPrint('  change-sig    Reorder a function\'s parameters + call-site args\n');
		sysPrint('  remove-param  Remove a function parameter + call-site args\n');
		sysPrint('  add-member    Append a member to a type body (writer-formatted, canonical-gated)\n');
		sysPrint('  add-import    Add an import / using to a module (writer-formatted, canonical-gated)\n');
		sysPrint('  add-element   Insert a sibling element — statement/case/list elem (--after/--before)\n');
		sysPrint('  replace-node  Replace a node\'s source span (--select / --at; writer-formatted)\n');
		sysPrint('  remove-element Remove a sibling element by cursor (inverse of add-element)\n');
		sysPrint('  remove-import Remove an import / using by module path (backend of lint --fix)\n');
		sysPrint('  remove-member Remove a member by --type + name (inverse of add-member)\n');
		sysPrint('  uses          Type references (field/param/type-param positions)\n');
		sysPrint('  meta          Annotation-on-decl shortcut\n');
		sysPrint('  blast         Change-impact checklist (uses + refs + member-access)\n');
		sysPrint('  lit           Leaf-name probe (string literals, identifiers — prose-in-code)\n');
		sysPrint('  mentions      Every named-leaf occurrence (uses + refs + lit --any-kind --exact)\n');
		sysPrint('  cases         Precise case-pattern lookup (case Ctor: / case Ctor(_): / case A | Ctor:)\n');
		sysPrint('  gates         List @:fmt(trailOptParseGate/trailOptShapeGate) annotations + predicate names\n');
		sysPrint('  diff          Structural AST diff between two files\n');
		sysPrint('  strip         Sed-strip + parse-check (sole-blocker confirmation)\n');
		sysPrint('  writer-equals Byte-equality check on writer output (trivia + --plain)\n');
		sysPrint('  writer-probe  Emit trivia + plain writer outputs side-by-side\n');
		sysPrint('  recon         Skip-parse drill — corpus sweep + locus-cluster histogram\n');
		sysPrint('  sweep         Read corpus sweep snapshot totals + Δ vs prior\n');
		sysPrint('  set-modifier  Flip visibility / add-remove modifiers at a cursor (no retype)\n');
		sysPrint('  test-summary  Parse utest stdout transcript into tests/assertions/failures\n');
		sysPrint('  rewrite       Structural search-and-replace (search-pattern metavars)\n');
		sysPrint('  set-doc       Add/replace a declaration\'s doc-comment at a cursor\n');
		sysPrint('  set-comment   Replace the comment at a cursor (line run or block)\n');
		sysPrint('  comment-rewrite  Text find/replace inside comments (write-twin of lit; --regex)\n');
		sysPrint('  self-status   List .hx files the grammar plugin cannot parse (dogfood gap)\n');
		sysPrint('  new           Create a new module — final class / implements <iface> (canonical)\n');
		sysPrint('  source        Emit RAW verbatim file lines (no parse; --range L:L2)\n');
		sysPrint('  fmt           Canonicalise Haxe source (writer round-trip; --write / --list)\n');
		sysPrint('\n');
		sysPrint('Global options:\n');
		sysPrint('  --lang <name>   Pick grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show help\n');
	}

	private static function printSymbolsUsage(): Void {
		sysPrint('Usage: apq symbols <scope...> [options]\n');
		sysPrint('\n');
		sysPrint('List every top-level type declaration across the scope (one or more\n');
		sysPrint('file/dir/glob specs) as <import-path>\\t<Kind>\\t<file>:<line>:<col>.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --kind <Kind>   Only list this decl kind (ClassDecl/InterfaceDecl/\n');
		sysPrint('                  EnumDecl/TypedefDecl/AbstractDecl)\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printImportersUsage(): Void {
		sysPrint('Usage: apq importers <module> <scope...> [options]\n');
		sysPrint('\n');
		sysPrint('List the files in the scope (file/dir/glob specs after the module) that\n');
		sysPrint('import <module> — the module itself or one of its sub-types. A wildcard\n');
		sysPrint('import pkg.*; is not counted.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printDeclaresUsage(): Void {
		sysPrint('Usage: apq declares <type> <scope...> [options]\n');
		sysPrint('\n');
		sysPrint('Print the declaration site(s) of the type named <type> across the scope\n');
		sysPrint('(file/dir/glob specs after the type), matching the simple name or the fully\n');
		sysPrint('qualified import path. Each row is qualified<TAB>kind<TAB>file:line:col. More\n');
		sysPrint('than one row is an ambiguity; zero means the type is not declared in the\n');
		sysPrint('scope. The focused, single-type counterpart of symbols.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printLintUsage(): Void {
		sysPrint('Usage: apq lint <scope...> [options]\n');
		sysPrint('\n');
		sysPrint('Run the analysis checks over the scope (one or more file/dir/glob specs) and\n');
		sysPrint('report violations grouped by file as <line>:<col>: [severity] message (rule).\n');
		sysPrint('Info advisories are hidden unless --all. The exit code is success unless\n');
		sysPrint('--fail-on selects a severity present in the findings. Built-in checks:\n');
		sysPrint('unused-import, unused-local, duplicate-import, naming, unused-private,\n');
		sysPrint('complexity, fold-adjacent-string-literals.\n');
		sysPrint('\n');
		sysPrint('Inline suppression: a trailing "// noqa" (or "// noqa: <rule>,<rule>") clears\n');
		sysPrint('findings on its line; "// CHECKSTYLE:OFF" ... "// CHECKSTYLE:ON" clears a region.\n');
		sysPrint('\n');
		sysPrint('Project config: an "apqlint.json" discovered by walking up from a linted file\n');
		sysPrint('enables/disables rules and overrides their severity or options, e.g.\n');
		sysPrint('{ "rules": { "naming": { "severity": "error" }, "complexity": { "max": 15 },\n');
		sysPrint('"fold-adjacent-string-literals": { "enabled": false } } }.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --rule <id>       Run only this check (repeatable; default: all)\n');
		sysPrint('  --fix            Apply autofixes in place (e.g. delete unused imports)\n');
		sysPrint('  --fail-on <sev>   Exit non-zero if a finding at-or-above <sev> exists\n');
		sysPrint('                    (error|warning|info)\n');
		sysPrint('  --format <fmt>    Output format: text (default), json, checkstyle\n');
		sysPrint('  --all, -a        Include Info-severity advisories in the report\n');
		sysPrint('  --flat           One <file>:<line>:<col> per line (text format only)\n');
		sysPrint('  --lang <name>    Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help       Show this help\n');
	}

	private static function printExtractMethodUsage(): Void {
		sysPrint('Usage: apq extract-method <file> <startLine>:<col> <endLine>:<col> <name> [options]\n');
		sysPrint('\n');
		sysPrint('Extract the contiguous run of statements bounded by the two positions into\n');
		sysPrint('a fresh local function <name> (a closure), replacing the run with a call.\n');
		sysPrint('A local defined in the run and used after it becomes the return value.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		sysPrint('  --reformat      Canonicalise the whole file if it is not already canonical\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printAddElementUsage(): Void {
		sysPrint(
			'Usage: apq add-element <file> (--after <l>:<c> | --before <l>:<c> | --append <l>:<c>) (<code> | --from-file <path> | -) [options]\n'
		);
		sysPrint('\n');
		sysPrint('Insert <code> as a new element into a list-shaped slot. With --after / --before,\n');
		sysPrint('<l>:<c> points at an existing SIBLING element (a statement in a block, a case in\n');
		sysPrint('a switch, an array / object / call-argument element). With --append, it points at\n');
		sysPrint('the CONTAINER itself (block / array / object / call / new / class / switch); the\n');
		sysPrint('element is added as the last child — which also works on an empty container that\n');
		sysPrint('has no sibling to point at. The slot separator (comma or newline) is added\n');
		sysPrint('automatically; the element is writer-formatted + re-parse-validated. The element\n');
		sysPrint('text may be inline, from --from-file, or stdin when it is the literal `-`.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --after <l>:<c>   Insert after the sibling element at this position\n');
		sysPrint('  --before <l>:<c>  Insert before the sibling element at this position\n');
		sysPrint('  --append <l>:<c>  Append as the last child of the container at this position\n');
		sysPrint('  --from-file <path> Read the element text from a file instead of the argument\n');
		sysPrint('  --write           Overwrite the file in place (default: print to stdout)\n');
		sysPrint('  --reformat        Canonicalise the whole file if it is not already canonical\n');
		sysPrint('  --lang <name>     Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help        Show this help\n');
	}

	private static function printRemoveElementUsage(): Void {
		sysPrint('Usage: apq remove-element <file> <line>:<col> [options]\n');
		sysPrint('\n');
		sysPrint('Remove the sibling element whose first token is at <line>:<col> — a statement\n');
		sysPrint('in a block, a case in a switch, an array / object / call-argument element, or a\n');
		sysPrint('class member (with its modifier / meta group). The structural inverse of\n');
		sysPrint('add-element; one separating comma is removed for comma lists. The result is\n');
		sysPrint('writer-formatted + re-parse-validated.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --with-doc      Also remove the element\'s leading doc comment\n');
		sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		sysPrint('  --reformat      Canonicalise the whole file if it is not already canonical\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printRemoveImportUsage(): Void {
		sysPrint('Usage: apq remove-import <file> <module.path> [options]\n');
		sysPrint('\n');
		sysPrint('Remove the import / using statement whose exposed path equals <module.path>\n');
		sysPrint('(the alias for an aliased import). The path must name exactly one statement.\n');
		sysPrint('The by-name counterpart of remove-element; backend of lint --fix.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		sysPrint('  --reformat      Canonicalise the whole file if it is not already canonical\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printRemoveMemberUsage(): Void {
		sysPrint('Usage: apq remove-member <file> --type <T> <memberName> [options]\n');
		sysPrint('\n');
		sysPrint('Remove the member named <memberName> of type <T> (a field or method), with\n');
		sysPrint('its modifier / meta group. Both <T> and <memberName> must resolve to exactly\n');
		sysPrint('one node. The by-name counterpart of add-member.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --type <T>      The enclosing type (required)\n');
		sysPrint('  --with-doc      Also remove the member\'s leading doc comment\n');
		sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		sysPrint('  --reformat      Canonicalise the whole file if it is not already canonical\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printInlineMethodUsage(): Void {
		sysPrint('Usage: apq inline-method <file> <line>:<col> [options]\n');
		sysPrint('\n');
		sysPrint('Inline the single-return function declared at <line>:<col> into every\n');
		sysPrint('in-file call site (arguments substituted for parameters) and delete the\n');
		sysPrint('declaration. The call-site set is proven complete before any rewrite.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show this help\n');
	}

	private static function printSearchUsage(): Void {
		sysPrint('Usage: apq search [options] <pattern> <file-or-dir-or-glob>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of text\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('  --kind <Kind>       Only match nodes of this AST kind\n');
		sysPrint('  --explain           Print parsed pattern AST; on 0 hits show input-kind histogram\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('\n');
		sysPrint("Pattern syntax: language source with `$X` / `$_` metavars.\n");
		sysPrint("  $X      — bind a subtree; reuses must match structurally.\n");
		sysPrint("  $_      — wildcard, no binding.\n");
		sysPrint('\n');
		sysPrint('Use `--` before a pattern that starts with `--` (e.g. the\n');
		sysPrint("prefix-decrement pattern `--$x`): apq search -- '--\\$x' <file>\n");
	}

	private static function printLitUsage(): Void {
		sysPrint('Usage: apq lit [options] <text> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --exact              Require exact string equality (default: substring)\n');
		sysPrint('  --kind <K1,K2,...>   Restrict to leaves of these kinds (default: shape-based, see below)\n');
		sysPrint('                       The synthetic kind `Comment` triggers a comment-only\n');
		sysPrint('                       scan (no AST walk) — `--kind Comment` searches `//…`\n');
		sysPrint('                       and `/* … */` bodies only.\n');
		sysPrint('  --any-kind           Match every named leaf regardless of kind (also\n');
		sysPrint('                       scans comments).\n');
		sysPrint('  --include-comments   Scan source comments ALONGSIDE the AST walk. Sugar\n');
		sysPrint('                       for "default kinds AS-IS, plus Comment" — keeps the\n');
		sysPrint('                       smart-default `--kind` resolution and adds comment\n');
		sysPrint('                       bodies. Use when the same text may live in either a\n');
		sysPrint('                       string literal or a `//`/`/**` comment (TODO/FIXME\n');
		sysPrint('                       hunts, doc-keyword cross-checks). Comments are\n');
		sysPrint('                       string-literal-aware: `//` inside `"…"`/`\'…\'` is\n');
		sysPrint('                       not a comment.\n');
		sysPrint('  --flat               Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>          Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>        Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Walks parsed AST for leaf nodes whose `name` slot matches <text>.\n');
		sysPrint('Smart-default --kind: when <text> is camelCase / snake_case the\n');
		sysPrint('default widens to `Literal,IdentExpr` (clearly an identifier query —\n');
		sysPrint('`hxq lit trailOptShapeGate src/` finds both literals and identifier\n');
		sysPrint('references without a re-run). Pure-lowercase / all-uppercase single\n');
		sysPrint('words stay `Literal`-only — they ambiguously match string content and\n');
		sysPrint('identifier widening would flood prose hits. Override with --kind /\n');
		sysPrint('--any-kind. AST kinds skip comments and string interpolation by routing\n');
		sysPrint('through the parser; `--include-comments` / `--kind Comment` re-enables\n');
		sysPrint('them via a separate string-literal-aware scan over the raw source.\n');
	}

	private static function printBlastUsage(): Void {
		sysPrint('Usage: apq blast [options] <type-name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Explicit cap on the heuristic section (overrides smart default)\n');
		sysPrint('  --all               Disable the smart-default cap on the heuristic section\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Heuristic field-access (`.member` superset) is capped at ${HEUR_DEFAULT_CAP} by default.\n');
		sysPrint('Pass --all for the full list, or --limit N for an explicit cap.\n');
		sysPrint('Precise uses / refs sections are uncapped.\n');
		sysPrint('\n');
		sysPrint('Change-impact checklist for a type. Unions three sections:\n');
		sysPrint('  uses  — type-position references (precise)\n');
		sysPrint('  refs  — value-binding references (precise)\n');
		sysPrint('  heuristic field-access — `expr.member` whose member name is\n');
		sysPrint('          a member of the type\'s decl. SUPERSET / name-based —\n');
		sysPrint('          over-matches, VERIFY each. This is the signal plain\n');
		sysPrint('          `uses`/`refs` are blind to (the typedef->enum gap).\n');
		sysPrint('Needs the type\'s declaration in the scanned set for the\n');
		sysPrint('heuristic; absent ⇒ that section is skipped (uses/refs stand).\n');
	}

	private static function printMentionsUsage(): Void {
		sysPrint('Usage: apq mentions [options] <name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Cap the lit section at n hits\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Every named-leaf occurrence of an identifier. Unions:\n');
		sysPrint('  uses  — type-position references (precise)\n');
		sysPrint('  refs  — value-binding references (precise)\n');
		sysPrint('  lit   — every other leaf with that exact name:\n');
		sysPrint('          case-patterns (`case Foo(_):` → IdentExpr),\n');
		sysPrint('          imports, `new Foo()`, field-name slots.\n');
		sysPrint('\n');
		sysPrint('Use this when refs/uses/blast return 0 but you know the\n');
		sysPrint('name appears (case-patterns are the canonical example —\n');
		sysPrint('blind to refs/uses/blast). All three sections are exact-\n');
		sysPrint('name and structural; no heuristic / no over-match.\n');
	}

	private static function printRefsUsage(): Void {
		sysPrint('Usage: apq refs [options] <name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of text\n');
		sysPrint('  --decls             Filter to declarations\n');
		sysPrint('  --reads             Filter to read references\n');
		sysPrint('  --writes            Filter to write references (Phase 3.3)\n');
		sysPrint('  --doc               Also emit each hit\'s leading doc-comment\n');
		sysPrint('  --source            Also emit each hit\'s verbatim source slice\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Phase 3.1: name-only matching, no lexical scope. Filters combine\n');
		sysPrint('inclusively — passing `--decls --reads` keeps both kinds.\n');
	}

	private static function printRenameUsage(): Void {
		sysPrint('Usage: apq rename <file> <line>:<col> <newName> [--write] [--scope <dir>]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --scope <dir>       Cross-file TYPE rename across every .hx under <dir>\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Scope-correct, format-preserving rename of the binding identified by\n');
		sysPrint('the symbol at <line>:<col>. The position selects the EXACT binding —\n');
		sysPrint('a shadowing param / loop var / field with the same name is left\n');
		sysPrint('untouched. <line>:<col> uses the same column convention `apq refs`\n');
		sysPrint('prints, so a coordinate copied from `apq refs --decls` selects the\n');
		sysPrint('intended binding. The rewrite is verified to re-parse; a cursor not on\n');
		sysPrint('a renameable identifier, or an unparseable result, exits non-zero with\n');
		sysPrint('the file untouched.\n');
		sysPrint('\n');
		sysPrint('With --scope <dir> the cursor MUST be on a TYPE declaration (class /\n');
		sysPrint('interface / enum / typedef / abstract); that type is renamed across\n');
		sysPrint('every .hx file under <dir> — type positions, new T, cast, extends /\n');
		sysPrint('implements, type params, the decl name, import / using segments, and\n');
		sysPrint('static-receiver accesses (T.staticMethod() / T.CONST whose receiver is\n');
		sysPrint('not a value binding). Type-namespace only: bare Class<T> value uses\n');
		sysPrint('(var c = T;) and aliased imports are NOT rewritten (a missed form\n');
		sysPrint('dangles into a compile error, never a silent change). The rename refuses\n');
		sysPrint('if the type is declared in more than one file under scope, if any scope\n');
		sysPrint('file does not parse, or if any rewritten file fails to re-parse — the\n');
		sysPrint('write is atomic. Without --write a per-file occurrence summary is printed.\n');
	}

	private static function printMoveUsage(): Void {
		sysPrint('Usage: apq move <file> <line>:<col> <dest-file> --scope <dir> [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --scope <dir>       Directory whose .hx imports are fixed (required)\n');
		sysPrint('  --write             Write each changed file in place (default: print summary)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Move the TYPE declaration (class / interface / enum / typedef /\n');
		sysPrint('abstract) at <line>:<col> in <file> into <dest-file>, which must be in\n');
		sysPrint('the SAME PACKAGE. The decl is relocated verbatim — its leading\n');
		sysPrint('doc-comment and @:meta lines move with it. Every file under --scope that\n');
		sysPrint('imported the type through its old module path is repointed at the new\n');
		sysPrint('path, and the type-position imports the moved body depends on are carried\n');
		sysPrint('into the destination (best-effort: a dependency reached via a static\n');
		sysPrint('receiver T.x() or a value position is not auto-detected and may need a\n');
		sysPrint('manual import — surfaced in the advisory). <line>:<col> uses the same\n');
		sysPrint('column convention `apq refs` prints.\n');
		sysPrint('\n');
		sysPrint('Refuses a cross-package move, an ambiguous / missing type, a decl that\n');
		sysPrint('shares a source line with other code, any scope file that does not parse,\n');
		sysPrint('or any rewritten file that fails to re-parse — the write is atomic\n');
		sysPrint('(all changed files or none). Same-package moves only in this increment.\n');
	}

	private static function printInlineUsage(): Void {
		sysPrint('Usage: apq inline <file> <line>:<col> [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Scope-correct, format-preserving inline of the local var / final\n');
		sysPrint('binding identified by the symbol at <line>:<col>. Every read of the\n');
		sysPrint('binding is replaced with its initializer source (parenthesised when\n');
		sysPrint('the initializer is an operator expression) and the declaration line is\n');
		sysPrint('removed. The inline refuses unless the binding is single-assignment and\n');
		sysPrint('its initializer is side-effect-free (no calls / field access / new /\n');
		sysPrint('collections / lambdas / interpolation) and reads only stable locals.\n');
		sysPrint('<line>:<col> uses the same column convention `apq refs` prints. The\n');
		sysPrint('rewrite is verified to re-parse; a cursor not on an inlinable local, an\n');
		sysPrint('unsafe initializer, or an unparseable result, exits non-zero with the\n');
		sysPrint('file untouched.\n');
	}

	private static function printExtractVarUsage(): Void {
		sysPrint('Usage: apq extract-var <file> <line>:<col> <name> [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Scope-correct, format-preserving extract-variable — the inverse of\n');
		sysPrint('inline. The expression starting at <line>:<col> is hoisted into a fresh\n');
		sysPrint('local `final <name> = <expr>;` inserted on its own line immediately\n');
		sysPrint('before the nearest enclosing block-level statement (at that statement\'s\n');
		sysPrint('indentation), and the expression occurrence is replaced with <name>.\n');
		sysPrint('The cursor must point at the FIRST token of an expression; the\n');
		sysPrint('outermost expression starting there is selected. The enclosing\n');
		sysPrint('statement must be a direct child of a { } block — an expression buried\n');
		sysPrint('in a braceless branch is refused. <line>:<col> uses the same column\n');
		sysPrint('convention `apq refs` prints. The rewrite is verified to re-parse; a\n');
		sysPrint('cursor not on an expression start, an enclosing statement outside a\n');
		sysPrint('block, or an unparseable result exits non-zero with the file untouched.\n');
	}

	private static function printAddParamUsage(): Void {
		sysPrint('Usage: apq add-param <file> <line>:<col> <paramText> [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Add a backward-compatible parameter to a function declaration. The\n');
		sysPrint('function whose declaration is at <line>:<col> gains <paramText> as a new\n');
		sysPrint('trailing parameter (e.g. `?flag:Bool`, `count:Int = 0`, `?cb:Void->Void`).\n');
		sysPrint('The parameter MUST be optional (`?name:T`) or defaulted (`name:T = v`),\n');
		sysPrint('so existing call sites need no update — a required parameter would break\n');
		sysPrint('them and is refused. This is a DECL-ONLY operation: no call site is\n');
		sysPrint('touched, which makes it safe for methods AND local functions alike.\n');
		sysPrint('Quote <paramText> if it contains spaces. <line>:<col> uses the same\n');
		sysPrint('column convention `apq refs` prints. The rewrite is verified to\n');
		sysPrint('re-parse; a cursor not on a function, a required parameter, a name\n');
		sysPrint('collision, or an unparseable result exits non-zero with the file\n');
		sysPrint('untouched.\n');
	}

	private static function printAddMemberUsage(): Void {
		sysPrint('Usage: apq add-member <file> --type <TypeName> (<memberText> | --from-file <path> | -) [--reformat] [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --type <TypeName>   Type whose body gains the member (required)\n');
		sysPrint('  --from-file <path>  Read <memberText> from a file instead of the argument\n');
		sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('The member text may be given inline, read from a file with --from-file, or\n');
		sysPrint('read from stdin when it is the literal `-` (heredoc-friendly for code with\n');
		sysPrint('`$` or quotes the shell would mangle). Append <memberText> as a new member\n');
		sysPrint('of <TypeName>. The member is\n');
		sysPrint('WRITER-FORMATTED — indented and laid out by the grammar\'s rules, not\n');
		sysPrint('inserted as-is — by re-emitting the whole file through the writer (this\n');
		sysPrint('also re-parse-validates). Works for class / interface / abstract / enum /\n');
		sysPrint('typedef bodies; positioning is append-only (ordering is the formatting\n');
		sysPrint('layer\'s job). The file must already be in canonical form (its own writer\n');
		sysPrint('output); otherwise it is refused unless --reformat is given (which\n');
		sysPrint('canonicalises the whole file). Quote <memberText> if it contains spaces.\n');
		sysPrint('An unknown / ambiguous type name, a non-canonical file without --reformat,\n');
		sysPrint('or an unparseable result, exits non-zero with the file untouched.\n');
	}

	private static function printAddImportUsage(): Void {
		sysPrint('Usage: apq add-import <file> <module.path> [--using] [--reformat] [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --using             Add a `using` instead of an `import`\n');
		sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Add `import <module.path>;` (or `using` with --using) after the last\n');
		sysPrint('existing import / using, else after the `package` declaration, else at the\n');
		sysPrint('start of the file. The result is WRITER-FORMATTED (the whole file is\n');
		sysPrint('re-emitted through the writer, which also re-parse-validates). The file\n');
		sysPrint('must already be canonical; otherwise it is refused unless --reformat is\n');
		sysPrint('given. An import of the same kind already present is refused (a no-op). An\n');
		sysPrint('empty path, a duplicate, a non-canonical file without --reformat, or an\n');
		sysPrint('unparseable result exits non-zero with the file untouched.\n');
	}

	private static function printReplaceNodeUsage(): Void {
		sysPrint(
			'Usage: apq replace-node <file> (--select <sel> | --at <line>:<col>) (<newSource> | --from-file <path> | -) [--reformat] [--write]\n'
		);
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --select <sel>      Address the node by an ast-style selector\n');
		sysPrint('                      (Kind / Kind:name / A > B); must match exactly one\n');
		sysPrint('  --at <line>:<col>   Address the innermost node at the cursor\n');
		sysPrint('  --kind <Kind>      With --at: the innermost node of <Kind> at the cursor\n');
		sysPrint('                      (reaches a co-starting operator / wrapper node)\n');
		sysPrint('  --with-doc          Also replace the leading doc comment (rewrite its docs)\n');
		sysPrint('  --from-file <path>  Read <newSource> from a file instead of the argument\n');
		sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('The new source may be inline, read from a file with --from-file, or read\n');
		sysPrint('from stdin when it is the literal `-` (heredoc-friendly for code with `$`\n');
		sysPrint('or quotes the shell would mangle). Replace the source span of a single\n');
		sysPrint('node with <newSource>. Provide\n');
		sysPrint('exactly one of --select or --at. --at uses the same column convention\n');
		sysPrint('`apq refs` prints (NOT the raw 1-indexed `ast --at`). The result is\n');
		sysPrint('WRITER-FORMATTED — the whole file is re-emitted through the writer (which\n');
		sysPrint('also re-parse-validates), so the replacement is laid out by the grammar\'s\n');
		sysPrint('rules. The file must already be canonical; otherwise it is refused unless\n');
		sysPrint('--reformat is given. Quote <newSource> if it contains spaces. A target\n');
		sysPrint('that resolves to no / multiple nodes, a non-canonical file without\n');
		sysPrint('--reformat, or an unparseable result, exits non-zero with the file\n');
		sysPrint('untouched.\n');
	}

	private static function printChangeSigUsage(): Void {
		sysPrint('Usage: apq change-sig <file> <line>:<col> <perm>  (perm = comma-separated 0-based new order, e.g. 2,0,1)\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Scope-correct, format-preserving change-signature (parameter reorder).\n');
		sysPrint('The function whose declaration / binding is at <line>:<col> has its\n');
		sysPrint('parameters reordered per <perm> — a comma-separated 0-based list giving\n');
		sysPrint('the NEW order of OLD parameter indices (for g(a,b,c), `2,0,1` reorders\n');
		sysPrint('to c,a,b). The positional arguments at every resolvable in-file call\n');
		sysPrint('site are permuted to match. The reorder is a slot swap — only the\n');
		sysPrint('parameter / argument contents move, so the existing layout is preserved.\n');
		sysPrint('Methods (called via bare `name(...)` / `this.name(...)`) and named local\n');
		sysPrint('functions are supported; a receiver-qualified `obj.name(...)` call, an\n');
		sysPrint('unresolvable call, or a call with omitted optional arguments is refused\n');
		sysPrint('(change-sig never leaves a call site with stale argument order). A method\n');
		sysPrint('reorder also emits a cross-file advisory (callers in other files are out\n');
		sysPrint('of scope). <line>:<col> uses the same column convention `apq refs`\n');
		sysPrint('prints. The rewrite is verified to re-parse; a cursor not on a function,\n');
		sysPrint('a non-permutation <perm>, or an unparseable result, exits non-zero with\n');
		sysPrint('the file untouched.\n');
	}

	private static function printRemoveParamUsage(): Void {
		sysPrint('Usage: apq remove-param <file> <line>:<col> <index> [--write]  (index = 0-based parameter to remove)\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Scope-correct, format-preserving remove-parameter — the inverse of\n');
		sysPrint('add-param. The function whose declaration / binding is at <line>:<col>\n');
		sysPrint('loses the parameter at 0-based <index>, and the corresponding positional\n');
		sysPrint('argument is deleted at every resolvable in-file call site (the separating\n');
		sysPrint('comma goes too, so the surviving list stays well-formed). Unlike\n');
		sysPrint('add-param (decl-only, always backward-compatible), removing a parameter\n');
		sysPrint('BREAKS calls, so remove-param updates call sites with the SAME strict\n');
		sysPrint('completeness proof change-sig uses: a receiver-qualified `obj.name(...)`\n');
		sysPrint('call, an unresolvable call, a value capture, or a call with omitted\n');
		sysPrint('optional arguments is refused (the removal never leaves a call with a\n');
		sysPrint('stale argument). The removed parameter must be unused in the body — a\n');
		sysPrint('remaining use is refused (the result would reference an undefined\n');
		sysPrint('identifier). Methods (called via bare `name(...)` / `this.name(...)`) and\n');
		sysPrint('named local functions are supported; a method removal also emits a\n');
		sysPrint('cross-file advisory (callers in other files are out of scope).\n');
		sysPrint('<line>:<col> uses the same column convention `apq refs` prints. The\n');
		sysPrint('rewrite is verified to re-parse; a cursor not on a function, an\n');
		sysPrint('out-of-range index, a used parameter, or an unparseable result, exits\n');
		sysPrint('non-zero with the file untouched.\n');
	}

	private static function printUsesUsage(): Void {
		sysPrint('Usage: apq uses [options] <type-name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --doc               Also emit each hit\'s leading doc-comment\n');
		sysPrint('  --source            Also emit each hit\'s verbatim source slice\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Finds type-position references — a field/var type annotation,\n');
		sysPrint('an enum-constructor parameter type, a type parameter. Sister of\n');
		sysPrint('`refs` (value bindings). `Array<T>` reports both `Array` and\n');
		sysPrint('`T`. For "where is X declared" use `refs --decls` / `ast --select`.\n');
	}

	private static function printMetaUsage(): Void {
		sysPrint('Usage: apq meta [<annotation>[(<arg>)]] [options] <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --arg-contains <s>  Keep hits whose argument list contains <s> (substring)\n');
		sysPrint('  --on <decl-kind>    Keep hits attached to the given decl kind\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('<annotation> is the target language source syntax (e.g. `@:foo`),\n');
		sysPrint('recognised by its leading `@`. Omit it with `--on` to list every\n');
		sysPrint('annotation on a decl kind.\n');
		sysPrint('\n');
		sysPrint('Inline arg filter `@:tag(arg)` keeps only hits whose meta has a\n');
		sysPrint('top-level argument that is the bare ident `arg` OR a call `arg(...)`\n');
		sysPrint('(callee match) — e.g. `apq meta \'@:fmt(propagateExprPosition)\' src/`.\n');
		sysPrint('Unlike --arg-contains (substring), the inline form is exact per arg.\n');
	}

	private static function printAstUsage(): Void {
		sysPrint('Usage: apq ast [options] <file> | --code <s> | --stdin\n');
		sysPrint('\n');
		sysPrint('Source (exactly one):\n');
		sysPrint('  <file>              Path to a parseable source file (or .hxtest — section 2 auto-extracted)\n');
		sysPrint('  --code <s>          Inline source string (typically via the `probe` subcommand)\n');
		sysPrint('  --stdin             Read all of stdin as source\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of S-expr\n');
		sysPrint('  --depth <n>         Truncate beyond depth n. Counted from the displayed root:\n');
		sysPrint('                      module (default), the matched node when paired with --select / --at.\n');
		sysPrint('                      --depth 0 prints just the root with no children.\n');
		sysPrint('  --select <path>     Subtree(s) matching a selector (e.g. "ClassDecl > FnDecl:foo")\n');
		sysPrint('  --at <line>:<col>   Innermost node enclosing the 1-indexed position\n');
		sysPrint('  --doc               With --select/--at: emit the match\'s leading doc-comment\n');
		sysPrint('  --source            With --select/--at: emit the match\'s verbatim source slice\n');
		sysPrint('  --min-children <n>  With --select: keep only matches with >= n direct children (e.g. multi-arg ParamCtor)\n');
		sysPrint('  --max-children <n>  With --select: keep only matches with <= n direct children\n');
		sysPrint(
			'  --spans             Append `@from-to` byte-range annotation to every rendered node — same-span duplicates (parser bug emitting two nodes at the same position) become a trivial visual signal.\n'
		);
		sysPrint(
			'  --count             Print just the integer direct-child count at the displayed root (one line per match with --select). Sanity-check for member counts before writing a corpus-driver test assertion.\n'
		);
		sysPrint('  --writer-output     Parse + format-write through the plugin trivia pipeline and print the emitted source\n');
		sysPrint(
			'  --writer-output-plain  Like --writer-output but uses the plain (non-trivia) writer — mirrors the unit-test entry HxModuleWriter.write(HaxeModuleParser.parse(src)); flattens source layout, drops comments\n'
		);
		sysPrint('  --diff              With --writer-output: AST-diff the input against the emitted output (writer-bug loop)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
	}

	private static function printProbeUsage(): Void {
		sysPrint('Usage: apq probe <code> [ast-options]\n');
		sysPrint('       apq probe - [ast-options]   (read code from stdin)\n');
		sysPrint('       apq probe <code> --writer-probe   (trivia + plain side-by-side)\n');
		sysPrint('\n');
		sysPrint('Inline-source variant of `apq ast`. Accepts every ast option\n');
		sysPrint('(--depth/--select/--at/--json/--writer-output/--writer-output-plain/\n');
		sysPrint('--writer-output --diff/--min-children/--max-children/--lang).\n');
		sysPrint('\n');
		sysPrint('--writer-probe diverts to the `writer-probe` aggregator: emits BOTH\n');
		sysPrint('the trivia and plain writer outputs separated by `=== trivia ===` /\n');
		sysPrint('`=== plain ===` fences. Mirrors `apq writer-probe <file>` for inline\n');
		sysPrint('source — no scratch file needed.\n');
		sysPrint('\n');
		sysPrint('Example:\n');
		sysPrint("  apq probe 'class C { function f() { @:m return switch x { case _: 0; } } }' --depth 6\n");
		sysPrint("  apq probe 'class C {}' --writer-probe\n");
	}

	private static function printWriterProbeUsage(): Void {
		sysPrint('Usage: apq writer-probe [options] <file>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Parse <file>, run BOTH the trivia and plain writer pipelines, and\n');
		sysPrint('emit each output between labelled fences:\n');
		sysPrint('  === trivia ===\n');
		sysPrint('  <bytes>\n');
		sysPrint('  === plain ===\n');
		sysPrint('  <bytes>\n');
		sysPrint('\n');
		sysPrint('Replaces the two-command dance (`hxq ast … --writer-output` then\n');
		sysPrint('`hxq ast … --writer-output-plain`) when constructing a unit-test\n');
		sysPrint('`writerEquals` expected literal: side-by-side output makes the\n');
		sysPrint('pipeline divergence (anon flatten, terminators, comments) visible.\n');
		sysPrint('Exit 0 only when both pipelines succeed.\n');
	}

	private static function stderr(s: String): Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

	/**
	 * Heartbeat interval for the multi-file walk progress line — emit a
	 * stderr `scanned K/N` every this many files so a corpus-wide walk
	 * never goes silent (a watchdog reading a redirected stream sees
	 * steady byte growth). Tuned so a several-hundred-file `src/` walk
	 * yields ~10–20 lines rather than one-per-file flooding.
	 */
	private static inline final PROGRESS_INTERVAL: Int = 25;

	/**
	 * Per-file walk progress heartbeat (multi-file scans only). Writes a
	 * `scanned <done>/<total>` line to **stderr** — never stdout — so the
	 * walker's machine-readable hit output stays byte-identical while a
	 * long run still produces incremental output. Fires every
	 * `PROGRESS_INTERVAL` files plus once at completion, and is a no-op
	 * for single-file queries (`singleFile`), tiny scans (`total <=
	 * PROGRESS_INTERVAL`), or when `HXQ_NO_PROGRESS` is set (so a caller
	 * merging streams via `2>&1` can suppress it).
	 *
	 * `done` is 1-based (the count of files processed so far, inclusive
	 * of the current one).
	 */
	private static function streamProgress(cmd: String, done: Int, total: Int, singleFile: Bool): Void {
		if (singleFile || total <= PROGRESS_INTERVAL) return;
		#if (sys || nodejs)
		if (Sys.getEnv('HXQ_NO_PROGRESS') != null) return;
		#end
		if (done % PROGRESS_INTERVAL == 0 || done == total) stderr('apq $cmd: scanned $done/$total files…\n');
	}

	/**
	 * Parse one walked file for the scan subcommands
	 * (`refs`/`uses`/`meta`/`search`). The behaviour on a parse failure
	 * depends on how the input was given. When the user named exactly
	 * one file (`singleFile`), the failure IS the query's answer: it is
	 * reported and the caller turns it into a hard error, mirroring
	 * `apq ast`. In directory / glob / multi-file scan mode an
	 * unparseable file is out of scope by nature, so it is skipped
	 * silently — no per-file error noise on every walk. Returns the
	 * parsed tree, or `null` to skip (scan) / fail (single file).
	 *
	 * Substring pre-filter: a name-walker only ever emits hits whose
	 * leaf text equals `searchKey`. An identifier / annotation key is
	 * carried verbatim into the AST (never escaped, case-sensitive), so
	 * `source.indexOf(searchKey) >= 0` is a strict necessary condition
	 * for ANY hit — if the raw bytes do not contain the key, no parse
	 * can produce a match. When `searchKey` is non-null and absent from
	 * `source`, the file is skipped WITHOUT parsing (the dominant cost
	 * on a corpus-wide walk) and WITHOUT a skip-entry: the file parses
	 * fine, it is a confirmed no-match, not a parse failure. The raw
	 * read is shared with the parse — the caller already read `source`
	 * once and passes the same buffer here, so the pre-filter adds no
	 * extra IO.
	 *
	 * `lit` searches the DECODED literal value while the raw file holds
	 * the ESCAPED form, so a raw `indexOf` can false-negative on a key
	 * containing escape sequences. Callers that cannot guarantee the key
	 * appears verbatim in source (e.g. `lit` on a backslash-bearing key)
	 * pass `searchKey == null` to opt out — correctness over speed.
	 *
	 * The pre-filter is suppressed in `singleFile` mode: there a `null`
	 * tree means "parse failed" and the caller turns it into a hard
	 * error. A pre-filter skip is a confirmed no-match, NOT a parse
	 * failure, so suppressing it preserves the single-file contract
	 * (parse the named file, emit 0 hits + nudge, exit 0). The win is a
	 * corpus-wide-scan win anyway — skipping one named file is moot.
	 */
	private static function parseWalked(
		cmd: String, parse: String -> QueryNode, path: String, source: String, singleFile: Bool, ?skipOut: Array<SkipEntry>,
		?searchKey: String
	): Null<QueryNode> {
		return !singleFile && searchKey != null && source.indexOf(searchKey) < 0
			? null
			: try parse(source) catch (exception: ParseError) {
				if (singleFile) stderr('apq $cmd: $path: ${exception.toString()}\n');
				if (skipOut != null) skipOut.push({ path: path, locus: formatParseErrorLocus(exception, source) });
				null;
			}
			catch (exception: Exception) {
				if (singleFile) stderr('apq $cmd: $path: ${exception.message}\n');
				if (skipOut != null) skipOut.push({ path: path, locus: exception.message });
				null;
			};
	}

	/**
	 * Render a `ParseError` as the skip-entry locus suffix shown in the
	 * 0-hit walker nudge: `LINE:COL <message>[ (expected <X>)]`.
	 *
	 * The locus tells the reader whether the parse failure is at the
	 * top of the file (so the file is effectively invisible to the walk)
	 * or far past where the searched name would plausibly live (warning
	 * can be ignored). Saves a follow-up `hxq ast <path>` probe to read
	 * the same information.
	 */
	private static function formatParseErrorLocus(exception: ParseError, source: String): String {
		final pos: Position = exception.span.lineCol(source);
		final base: String = '${pos.line}:${pos.col} ${exception.message}';
		return exception.expected == null ? base : '$base (expected ${exception.expected})';
	}

	/**
	 * Increment `counts[node.kind]` for every node in the tree. Used
	 * by `apq search --explain` to build the kind histogram that
	 * surfaces "pattern's root kind is not present in input" mismatches.
	 */
	private static function tallyKinds(root: QueryNode, counts: Map<String, Int>): Void {
		function walk(n: QueryNode): Void {
			final prev: Null<Int> = counts.get(n.kind);
			counts.set(n.kind, prev == null ? 1 : prev + 1);
			for (c in n.children) walk(c);
		}
		walk(root);
	}

	/**
	 * Heuristic: does the string look like a Haxe TypeName? First letter
	 * uppercase ASCII, no `/`, no `.` (eliminates relative paths like
	 * `./Foo.hx` and dotted accesses like `Foo.bar`). Used by `ast` to
	 * detect `apq ast <TypeName> <dir>` (refs/uses surface mistakenly
	 * fed to ast).
	 */
	private static function looksLikeTypeName(s: String): Bool {
		if (s.length == 0) return false;
		final c: Int = StringTools.fastCodeAt(s, 0);
		return c >= 'A'.code && c <= 'Z'.code && s.indexOf('/') < 0 && s.indexOf('.') < 0;
	}

	/**
	 * Heuristic: is the string clearly an identifier rather than a string
	 * fragment? Drives `lit`'s smart-default kind filter — when the query
	 * is camelCase (`trailOptShapeGate`) or snake_case (`MAX_LEN`,
	 * `endsWith_close_brace`) the user almost always wants the identifier
	 * tier promoted alongside `Literal`. Pure-lowercase single words
	 * (`foo`) and all-uppercase single words (`API`) stay ambiguous and
	 * keep the conservative `Literal`-only default — widening them would
	 * flood the result with prose hits.
	 *
	 * Rule: every char is alpha / digit / `_`, AND the string contains
	 * either a lower-then-upper transition (camelCase) or a `_` between
	 * letters (snake_case). Single letters / pure digits / strings with
	 * spaces / punctuation never qualify.
	 */
	private static function looksLikeMixedIdentifier(s: String): Bool {
		if (s.length < 2) return false;
		var hasLower: Bool = false;
		var hasUpper: Bool = false;
		var hasUnderscore: Bool = false;
		var hasLetter: Bool = false;
		var mixedTransition: Bool = false;
		var prevLower: Bool = false;
		for (idx in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, idx);
			final isLower: Bool = c >= 'a'.code && c <= 'z'.code;
			final isUpper: Bool = c >= 'A'.code && c <= 'Z'.code;
			final isDigit: Bool = c >= '0'.code && c <= '9'.code;
			final isUnderscore: Bool = c == '_'.code;
			if (!(isLower || isUpper || isDigit || isUnderscore)) return false;
			if (isLower) {
				hasLower = true;
				hasLetter = true;
			}
			if (isUpper) {
				hasUpper = true;
				hasLetter = true;
				if (prevLower) mixedTransition = true;
			}
			if (isUnderscore) hasUnderscore = true;
			prevLower = isLower;
		}
		return hasLetter && (mixedTransition || (hasUnderscore && (hasLower || hasUpper)));
	}

	/**
	 * Heuristic: does the query look like a leading-dot field-name slot
	 * (`.expr`, `.body`)? A single `.` prefix followed by an identifier-
	 * shaped tail. Used by the 0-hit nudge on `lit` / `refs` / `uses`:
	 * a leading-dot literal is never a captured leaf (lit) / value
	 * binding (refs) / type position (uses) — the user is looking for
	 * a `$x.<rest>` field-access shape, the structural answer is
	 * `apq search`.
	 *
	 * Returns the dot-stripped tail (`.expr` → `expr`) when the query
	 * qualifies, null otherwise. Composes with `looksLikeDottedAccess`
	 * (which rejects empty leading segments) — that heuristic is for
	 * `Type.method` / `obj.field` SOURCE notation; this one is for the
	 * field-name-only `.x` lookup intent.
	 */
	private static function looksLikeLeadingDotField(s: String): Null<String> {
		if (s.length < 2) return null;
		if (StringTools.fastCodeAt(s, 0) != '.'.code) return null;
		final tail: String = s.substr(1);
		// Tail must be a single identifier — multi-segment chains like
		// `.obj.field` are not the intended shape (they would also
		// produce false positives on the `obj.field` SOURCE form).
		if (tail.indexOf('.') >= 0) return null;
		final first: Int = StringTools.fastCodeAt(tail, 0);
		final firstOk: Bool = (first >= 'a'.code && first <= 'z'.code) || (first >= 'A'.code && first <= 'Z'.code) || first == '_'.code;
		if (!firstOk) return null;
		for (idx in 1...tail.length) {
			final c: Int = StringTools.fastCodeAt(tail, idx);
			final ok: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
				|| c == '_'.code;
			if (!ok) return null;
		}
		return tail;
	}

	/**
	 * Heuristic: does the query look like a dotted member access
	 * (`TypeName.method`, `obj.field`, `pkg.Module.entry`)? A single `.`
	 * or `..` separator between identifier-shaped segments. Used by the
	 * 0-hit nudge on `lit` / `refs` / `uses`: a dotted name is never a
	 * leaf-name, value-binding, or type-position match — it's a Call /
	 * FieldAccess shape, the structural answer is `apq search`.
	 *
	 * Returns the split segments when the query qualifies, null otherwise.
	 * Each segment must be a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`)
	 * and total segment count must be ≥ 2.
	 */
	/**
	 * DX v10: detect regex-like queries handed to `lit`. `lit` is
	 * substring-only; users who reach for `\|` (regex alternation),
	 * `[^...]` (character class negation), or `(?:...)` (non-capturing
	 * group) typically have a regex mental model and end up confused
	 * when the default 0-hit nudge talks about dotted access. Returns
	 * a short label describing what was detected, or null when the
	 * query carries no regex-specific syntax. Plain `?`, `*`, `[`, `]`
	 * are common in identifiers/globs and do NOT trip the heuristic
	 * alone — only the genuinely regex-only forms.
	 */
	private static function looksLikeRegex(s: String): Null<String> {
		return s.indexOf('\\|') >= 0
			? '`\\|` (regex alternation)'
			: s.indexOf('[^') >= 0
				? '`[^...]` (negated character class)'
				: s.indexOf('(?:') >= 0
					? '`(?:...)` (non-capturing group)'
					: s.indexOf('(?=') >= 0 ? '`(?=...)` (lookahead)' : s.indexOf('(?!') >= 0 ? '`(?!...)` (negative lookahead)' : null;
	}

	/**
	 * DX v10: detect Haxe macro reification sigils in a search pattern.
	 * `$v{}` / `$i{}` / `$a{}` / `$b{}` / `$p{}` / `$e{}` / `$es{}` are
	 * macro-time constructs; the pattern parser rejects them with a
	 * generic message that misdirects the user. Returns the matched
	 * sigil (e.g. "`$v{}`") for the error message, or null when the
	 * pattern carries none. Plain metavars `$x` (followed by letter, not
	 * `{` + reif tag) pass through.
	 */
	private static function detectMacroReification(s: String): Null<String> {
		final tags: Array<String> = ['v', 'i', 'a', 'b', 'p', 'e', 'es'];
		for (tag in tags) {
			final probe: String = "$" + tag + '{';
			if (s.indexOf(probe) >= 0) return "`$" + tag + '{...}`';
		}
		return null;
	}

	private static function looksLikeDottedAccess(s: String): Null<Array<String>> {
		if (s.indexOf('.') < 0) return null;
		final parts: Array<String> = s.split('.');
		if (parts.length < 2) return null;
		for (p in parts) {
			if (p.length == 0) return null;
			final first: Int = StringTools.fastCodeAt(p, 0);
			final firstOk: Bool = (first >= 'a'.code && first <= 'z'.code) || (
				first >= 'A'.code && first <= 'Z'.code
			) || first == '_'.code;
			if (!firstOk) return null;
			for (idx in 1...p.length) {
				final c: Int = StringTools.fastCodeAt(p, idx);
				final ok: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
					|| c == '_'.code;
				if (!ok) return null;
			}
		}
		return parts;
	}

	/**
	 * Heuristic: does the string look like a file/dir path? Contains `/`
	 * or `.hx` suffix, OR is an existing filesystem entry. Pairs with
	 * `looksLikeTypeName` to detect the `ast <TypeName> <dir>` shape.
	 */
	private static function looksLikePath(s: String): Bool {
		if (s.indexOf('/') >= 0) return true;
		if (StringTools.endsWith(s, '.hx')) return true;
		#if (sys || nodejs)
		return sys.FileSystem.exists(s);
		#else
		return false;
		#end
	}

	/**
	 * Build the per-kind nudge for `search` on a degenerate (single-leaf)
	 * pattern. Kind-aware: a lone metavar has no name to refs/uses; a
	 * literal value goes through `lit`; a bare identifier supports all
	 * three (refs/uses/lit). Sister of `emptyWalkerNudge` — both emit
	 * tool-suggestion messages on a structurally-valid-but-misaimed query.
	 */
	private static function degenerateNudge(patternStr: String, rootKind: String): String {
		final prefix: String = 'apq search: pattern "$patternStr" ';
		return switch rootKind {
			case 'Metavar':
				prefix + 'is a lone metavar — matches every node. Narrow with structural '
					+ "context (e.g. \"$x.field\", \"func($x)\"), or look up by name: apq refs <name> --decls / apq uses <Type>. Searching anyway.";
			case 'Literal' | 'StringLit' | 'BoolLit' | 'IntLit' | 'FloatLit' | 'SingleStringExpr' | 'DoubleStringExpr' | 'RawString':
				prefix + 'is a bare literal — for literal-content lookup use: apq lit \'$patternStr\' <files>. Searching anyway.';
			case _:
				// Bare identifier (IdentExpr) and anything else that
				// parses to a single leaf.
				prefix + 'has no code structure — search matches shape, not bare names. '
					+ 'Try one of: apq refs $patternStr --decls (value binding), ' + 'apq uses $patternStr (type position), '
					+ 'apq lit \'$patternStr\' (string-literal content), ' + 'apq ast --select. Searching anyway.';
		}
	}

	/**
	 * Stderr nudge emitted by walker subcommands (refs/uses/meta/lit) when
	 * they return zero hits. Composes up to three diagnostic layers:
	 *
	 *  - SUMMARY: counts of files scanned vs parseable — turns a silent
	 *    miss into an observable signal.
	 *  - KIND HINT: when `name` is non-null, a kind-aware tool suggestion
	 *    (`refs <X>` on UpperCase → try `uses`/`blast`; `uses <x>` on
	 *    lowercase → try `refs`/`lit`; etc.). `meta` has no `<name>` and
	 *    skips this layer.
	 *  - SKIP-PARSE WARNING: when `skipEntries` lists files that failed to
	 *    parse, surface count + first few paths AND their failure locus
	 *    (`LINE:COL <message>`). The locus lets the reader judge whether
	 *    the parse failure is upstream of the searched-for content (the
	 *    file is effectively invisible — warning critical) or far past it
	 *    (warning can be ignored) without a follow-up `hxq ast` probe.
	 *  - FUZZY DID-YOU-MEAN: for refs/uses with a non-null `candidates`
	 *    name pool, suggest top-K candidates within Levenshtein distance.
	 *    Silent when nothing close enough qualifies.
	 */
	private static function emptyWalkerNudge(
		cmd: String, name: Null<String>, scanned: Int, parseable: Int, ?skipEntries: Array<SkipEntry>, ?candidates: Map<String, Bool>
	): String {
		final summary: String = 'apq $cmd: 0 hits ($scanned file(s) scanned, $parseable parseable)';
		final tail: StringBuf = new StringBuf();
		if (name != null) {
			final n: String = name;
			final first: Int = n.length > 0 ? StringTools.fastCodeAt(n, 0) : 0;
			final isUpper: Bool = first >= 'A'.code && first <= 'Z'.code;
			final isLower: Bool = first >= 'a'.code && first <= 'z'.code;
			final leadingDot: Null<String> = looksLikeLeadingDotField(n);
			final dotted: Null<Array<String>> = looksLikeDottedAccess(n);
			final hint: String = if (leadingDot != null && (cmd == 'lit' || cmd == 'refs' || cmd == 'uses')) {
				// Leading-dot query (`.expr`, `.body`) — user is hunting a
				// field-access shape but typed the SLOT name only. lit
				// won't capture the leading `.` (FieldAccess leaves are
				// the identifier after `.`, the `.` is a postfix
				// operator); refs/uses don't know about field positions.
				// The structural answer is `apq search '$x.<tail>'`.
				final t: String = leadingDot;
				' — "$n" is a leading-dot field-name slot. $cmd matches leaf names / single bindings / type positions, never `expr.field` shape. Try: apq search \'$$x.$t\' <dir> (field-access shape), apq lit \'$t\' <dir> --any-kind (every leaf — field-name slots included), or apq refs $t <dir> --decls (where the field is declared).';
			} else if (dotted != null && (cmd == 'lit' || cmd == 'refs' || cmd == 'uses')) {
				// Dotted query (`TypeName.method`, `obj.field`) — never a
				// leaf-name / value-binding / type-position match. The
				// structural answer is `apq search` with the access shape.
				final lhs: String = dotted[0];
				final rhs: String = dotted[dotted.length - 1];
				final lhsFirst: Int = StringTools.fastCodeAt(lhs, 0);
				final lhsIsUpper: Bool = lhsFirst >= 'A'.code && lhsFirst <= 'Z'.code;
				// LHS uppercase ⇒ static call shape; otherwise instance access.
				if (lhsIsUpper)
					' — "$n" is a dotted access (Type.method / pkg.Module). $cmd matches leaf names / single bindings / type positions, never `Type.method` shape. Try: apq search \'$n($$_)\' <dir> (call shape), apq search \'$lhs.$rhs\' <dir> (field-access shape), or apq refs $rhs <dir> --decls (where the method is declared).';
				else
					' — "$n" is a dotted access (obj.field). $cmd matches leaf names / single bindings, never `obj.field` shape. Try: apq search \'$$x.$rhs\' <dir> (field-access shape), apq search \'$n\' <dir> (literal access), or apq refs $rhs <dir> --decls (where the field is declared).';
			} else
				switch cmd {
					case 'refs':
						if (isUpper)
							' — "$n" starts uppercase, looks like a TypeName. Try: apq uses $n <dir> (type positions), apq blast $n <dir> (full change-impact incl. field-access), or apq lit \'$n\' <dir> --any-kind (every leaf — case-patterns / imports / new exprs).';
						else
							' — "$n" has no value-binding here. Locals/params are NOT indexed. Try: apq lit \'$n\' <dir> --any-kind (every leaf — strings/idents/field-names) or apq search \'$$x.$n\' <dir> (field-access shape).${macroEmitHint(n)}';
					case 'uses':
						if (isLower)
							' — "$n" starts lowercase, not a TypeName. Try: apq refs $n <dir> (value bindings) or apq lit \'$n\' <dir> --any-kind (every leaf).${macroEmitHint(n)}';
						else
							' — no type-position references. For full change-impact incl. `.field` access try: apq blast $n <dir>, or apq lit \'$n\' <dir> --any-kind (every leaf — incl. case-patterns).';
					case 'blast':
						' — no declaration of "$n" in the scanned set (the heuristic section needs it). Either widen the scan, or use apq uses $n <dir> + apq refs $n <dir> directly.';
					case 'lit':
						if (looksLikeMixedIdentifier(n))
							' — no Literal/IdentExpr leaf matches "$n" (camelCase/snake_case query → default kind widened to Literal+IdentExpr; --exact for full equality). Try --any-kind (every leaf — incl. field-name slots), apq refs $n <dir> --decls, or apq search \'$$x.$n\' <dir> (field-access shape).';
						else
							' — no string-literal content matches "$n" (default: substring on Literal leaves; --exact for full equality). Widen the kind set with --kind Literal,IdentExpr or --any-kind (catches every leaf — incl. field-name slots), or try: apq refs $n <dir> --decls.';
					case 'meta':
						''; // meta has no <name> arg (annotation is its own thing) — leave silent.
					case _:
						'';
				};
			tail.add(hint);
		}

		// Skip-parse warning: parseable < scanned means the answer may
		// be hiding in unparsed files. Surface this loudly so a 0-hit
		// query on a broken corpus is not silently trusted.
		if (skipEntries != null && skipEntries.length > 0) {
			final n: Int = skipEntries.length;
			tail.add(
				'\napq $cmd: WARNING: $n file(s) skip-parse — answer may be hiding in unparsed files. Locus shows the parse-failure position; if it is far past the construct you searched for, the warning can be ignored.'
			);
			final shown: Int = n < SKIP_PATHS_SHOWN ? n : SKIP_PATHS_SHOWN;
			for (i in 0...shown) {
				final entry: SkipEntry = skipEntries[i];
				tail.add('\n  skip: ${entry.path} :: ${entry.locus}');
			}
			if (n > shown) tail.add('\n  ... and ${n - shown} more');
		}

		// Fuzzy "did you mean": for refs/uses on 0 hits, propose the
		// top-K decl/type names within Levenshtein distance. Stays
		// silent when no candidate qualifies — don't fabricate hints.
		if (name != null && candidates != null && (cmd == 'refs' || cmd == 'uses')) {
			final suggestions: Array<String> = findFuzzy(name, candidates);
			if (suggestions.length > 0) tail.add('\napq $cmd: Did you mean: ${suggestions.join(', ')}?');
		}

		return summary + tail.toString();
	}

	/**
	 * Append a hint when `name` appears to be macro-generated — scan
	 * `src/anyparse/macro/*.hx` for a `<name>Field` Field-builder function
	 * declaration (the canonical `Codegen.<name>Field()` shape that emits
	 * runtime helpers like `peekKw` / `matchLit` / `expectLit`). When found,
	 * point the user at the macro source where the literal name appears,
	 * since the runtime caller search (refs/uses) cannot reach the FFun
	 * `name: '<name>'` string-literal slot inside the builder body.
	 *
	 * Returns empty string when:
	 *  - `sys` target not available (no FileSystem access);
	 *  - `src/anyparse/macro` doesn't exist (running outside the project);
	 *  - no `<name>Field` function found in any macro source.
	 *
	 * Sniff is conservative (substring match for the exact FFun signature
	 * prefix `function <name>Field(`) — false positives require an
	 * unrelated function with that exact suffix, which the project does
	 * not produce.
	 */
	private static function macroEmitHint(name: String): String {
		#if (sys || nodejs)
		final macroDir: String = 'src/anyparse/macro';
		if (!FileSystem.exists(macroDir) || !FileSystem.isDirectory(macroDir)) return '';
		final marker: String = 'function ${name}Field(';
		try {
			for (entry in FileSystem.readDirectory(macroDir)) {
				if (!StringTools.endsWith(entry, '.hx')) continue;
				final src: String = sys.io.File.getContent('$macroDir/$entry');
				if (src.indexOf(marker) < 0) continue;
				return
					' If "$name" is a macro-emitted parser runtime helper, the emit site lives in src/anyparse/macro/$entry — try apq lit \'$name\' src/anyparse/macro/ --any-kind to see the FFun name slot.';
			}
		} catch (_: Exception) {
			// best-effort: return '' if building the hint text fails
		}
		return '';
		#else
		return '';
		#end
	}

	/**
	 * Collect every named leaf/inner-node into `out` for fuzzy
	 * "did you mean" suggestions. The full vocabulary covered by the
	 * walked tree — wider than just decls — keeps the suggestion list
	 * useful for either refs (value bindings) or uses (type positions)
	 * without needing a per-shape collector.
	 */
	private static function collectNames(root: QueryNode, out: Map<String, Bool>): Void {
		function walk(n: QueryNode): Void {
			final nm: Null<String> = n.name;
			if (nm != null && nm.length > 0) out.set(nm, true);
			for (c in n.children) walk(c);
		}
		walk(root);
	}

	/**
	 * Top-`FUZZY_TOP_K` "did you mean" candidates ranked in two tiers:
	 *
	 *  - Tier 0 — substring match: `query` is a contiguous substring of
	 *    `cand` (prefix/suffix/inner). Score = extra char count
	 *    `cand.length - query.length`. Catches the common grammar miss
	 *    `HxTypeParam` → `HxTypeParamDecl` (Levenshtein distance 4 from
	 *    appending "Decl" — beyond `FUZZY_MAX_DIST`, but `HxTypeParam` IS
	 *    a substring of `HxTypeParamDecl`). Guarded by
	 *    `FUZZY_SUBSTRING_MIN_QUERY` (avoids `Hx` matching everything)
	 *    and `FUZZY_SUBSTRING_MAX_EXTRA` (avoids `Foo` crowding out true
	 *    neighbours with a long-name match).
	 *
	 *  - Tier 1 — Levenshtein within `FUZZY_MAX_DIST`. Catches typos and
	 *    transpositions a substring scan can't.
	 *
	 * A candidate that qualifies under Tier 0 is NOT also evaluated under
	 * Tier 1 — the substring tier always wins, and we don't double-add.
	 * Returns empty when nothing qualifies; the caller emits the "did you
	 * mean" line only on a non-empty result (never fabricates hints).
	 */
	private static function findFuzzy(query: String, pool: Map<String, Bool>): Array<String> {
		final scored: Array<{ name: String, tier: Int, score: Int }> = [];
		final qLen: Int = query.length;
		final substringEnabled: Bool = qLen >= FUZZY_SUBSTRING_MIN_QUERY;
		for (cand in pool.keys()) {
			if (cand == query) continue;
			if (substringEnabled && cand.length > qLen && cand.length - qLen <= FUZZY_SUBSTRING_MAX_EXTRA && cand.indexOf(query) >= 0) {
				scored.push({ name: cand, tier: 0, score: cand.length - qLen });
				continue;
			}
			final d: Int = levenshtein(query, cand);
			if (d <= FUZZY_MAX_DIST) scored.push({ name: cand, tier: 1, score: d });
		}
		scored.sort((a, b) -> a.tier != b.tier ? a.tier - b.tier : (a.score != b.score ? a.score - b.score : (a.name < b.name ? -1 : 1)));
		final take: Int = scored.length < FUZZY_TOP_K ? scored.length : FUZZY_TOP_K;
		return [for (i in 0...take) scored[i].name];
	}

	/** Levenshtein edit distance (insert/delete/substitute = 1). */
	private static function levenshtein(a: String, b: String): Int {
		final la: Int = a.length;
		final lb: Int = b.length;
		if (la == 0) return lb;
		if (lb == 0) return la;
		var prev: Array<Int> = [for (j in 0...lb + 1) j];
		var cur: Array<Int> = [for (j in 0...lb + 1) 0];
		for (i in 1...la + 1) {
			cur[0] = i;
			final ai: Int = StringTools.fastCodeAt(a, i - 1);
			for (j in 1...lb + 1) {
				final cost: Int = ai == StringTools.fastCodeAt(b, j - 1) ? 0 : 1;
				final del: Int = prev[j] + 1;
				final ins: Int = cur[j - 1] + 1;
				final sub: Int = prev[j - 1] + cost;
				var m: Int = del < ins ? del : ins;
				if (sub < m) m = sub;
				cur[j] = m;
			}
			final tmp: Array<Int> = prev;
			prev = cur;
			cur = tmp;
		}
		return prev[lb];
	}

	/**
	 * Extract the leading kind token from a `--select` expression for
	 * fuzzy "did you mean" lookup. Splits on `>` (chain step), `:`
	 * (Kind:name binding), `[` (future syntax), and whitespace, returns
	 * the first non-empty segment. Empty result → no suggestion line.
	 */
	private static function extractFirstKindToken(selectExpr: String): String {
		final trimmed: String = StringTools.trim(selectExpr);
		if (trimmed.length == 0) return '';
		var end: Int = trimmed.length;
		for (i in 0...trimmed.length) {
			final c: Int = StringTools.fastCodeAt(trimmed, i);
			if (c == '>'.code || c == ':'.code || c == '['.code || c == ' '.code || c == '\t'.code) {
				end = i;
				break;
			}
		}
		return StringTools.trim(trimmed.substr(0, end));
	}

	/** Distinct node-constructor kinds present in a tree, sorted — the
	* self-discovery list shown when `--select` matches nothing. */
	private static function collectKinds(root: QueryNode): Array<String> {
		final seen: Array<String> = [];
		function walk(n: QueryNode): Void {
			if (!seen.contains(n.kind)) seen.push(n.kind);
			for (c in n.children) walk(c);
		}
		walk(root);
		seen.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return seen;
	}

	private static inline function sysPrint(s: String): Void {
		#if (sys || nodejs)
		Sys.print(s);
		#end
	}

	/**
	 * Common leading-whitespace prefix length (chars) shared by every
	 * non-blank line of `lines` in the 1-based inclusive `[from, to]` range
	 * (textwrap.dedent semantics). Blank / whitespace-only lines are ignored.
	 * Returns 0 when the lines share no leading whitespace or the range holds
	 * only blanks.
	 */
	private static function commonIndentWidth(lines: Array<String>, from: Int, to: Int): Int {
		var common: Null<String> = null;
		for (n in from...to + 1) {
			final line: String = lines[n - 1];
			if (StringTools.trim(line).length != 0) {
				final lead: String = leadingWhitespace(line);
				common = common == null ? lead : sharedPrefix(common, lead);
				if (common.length == 0) return 0;
			}
		}
		return common == null ? 0 : common.length;
	}

	/** The leading run of spaces / tabs at the start of `s`. */
	private static function leadingWhitespace(s: String): String {
		var i: Int = 0;
		while (i < s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c != ' '.code && c != '\t'.code) break;
			i++;
		}
		return s.substr(0, i);
	}

	/** The longest common prefix of `a` and `b`. */
	private static function sharedPrefix(a: String, b: String): String {
		final limit: Int = a.length < b.length ? a.length : b.length;
		var i: Int = 0;
		while (i < limit && StringTools.fastCodeAt(a, i) == StringTools.fastCodeAt(b, i)) i++;
		return a.substr(0, i);
	}

	/**
	 * Drop the first `strip` chars (the verified common indent) of `line`; a
	 * blank / whitespace-only line collapses to empty instead of keeping stray
	 * trailing indent.
	 */
	private static function dedentLine(line: String, strip: Int): String {
		return StringTools.trim(line).length == 0 ? '' : line.substr(strip);
	}

	/**
	 * `apq fmt <file/dir/glob>... [--write] [--list]` — canonicalise Haxe
	 * source by re-emitting it through the writer (the same whole-file pipeline
	 * the writer-emit ops use), formatted by the project `hxformat.json`
	 * discovered from each file's directory. This is the deterministic
	 * file-level counterpart of the node-level writer-emit ops: it is what
	 * makes a freshly written file byte-canonical (the create recipe's
	 * finisher) and is the measuring stick for the canonical gate
	 * (`writeRoundTrip(s) == s`). With no flags on a single concrete file the
	 * formatted source goes to stdout; on multiple files / a directory `--list`
	 * mode is implied (gofmt `-l`: print the paths whose output differs). A
	 * file that fails to parse is reported and skipped; the exit code is
	 * non-zero if any file failed.
	 */
	private static function runFmt(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var list: Bool = false;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write', '-w':
					write = true;
				case '--list', '-l':
					list = true;
				case '-h', '--help':
					printFmtUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq fmt: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					inputSpecs.push(a);
			}
			i++;
		}
		if (inputSpecs.length == 0) {
			stderr('apq fmt: expected <file/dir/glob>...\n');
			printFmtUsage();
			return EXIT_USAGE;
		}

		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq fmt: ${inputSpecs.join(', ')} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		// No --write and no -l on a single concrete file → emit the formatted
		// source to stdout (gofmt's one-file default). Multiple files / a dir
		// without --write → list mode (names of files that would change).
		final listMode: Bool = list || (!write && !expanded.singleFile);

		var changed: Int = 0;
		var failed: Int = 0;
		for (path in paths) {
			final source: String = try readFile(path) catch (exception: Exception) {
				stderr('apq fmt: $path: ${exception.message}\n');
				failed++;
				continue;
			};
			final optsJson: Null<String> = discoverFormatConfig(path);
			final formatted: Null<String> = try plugin.writeRoundTrip(source, optsJson) catch (exception: Exception) {
				stderr('apq fmt: $path: ${exception.message}\n');
				failed++;
				continue;
			};
			if (formatted == null) {
				stderr('apq fmt: no writer for lang "$lang"\n');
				return EXIT_RUNTIME;
			}
			final isCanonical: Bool = formatted == source;
			if (write) {
				if (!isCanonical) {
					writeFile(path, formatted);
					changed++;
				}
			} else if (listMode) {
				if (!isCanonical) {
					sysPrint('$path\n');
					changed++;
				}
			} else
				sysPrint(formatted);
		}

		if (write)
			stderr('apq fmt: formatted $changed file(s)' + (failed > 0 ? ', $failed failed' : '') + '\n');
		else if (listMode && failed > 0) stderr('apq fmt: $failed file(s) failed to parse\n');
		return failed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function printFmtUsage(): Void {
		sysPrint('Usage: apq fmt <file/dir/glob>... [--write] [--list]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --write, -w     Rewrite each file in place with its canonical form\n');
		sysPrint('  --list, -l      Print paths whose output differs (gofmt -l); no rewrite\n');
		sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Canonicalise Haxe source by re-emitting it through the writer, formatted\n');
		sysPrint('by the project hxformat.json discovered from each file\'s directory. With\n');
		sysPrint('no flags on a single file the formatted source goes to stdout; on multiple\n');
		sysPrint('files or a directory, --list mode is implied. A file that fails to parse is\n');
		sysPrint('reported and skipped; the exit code is non-zero if any file failed.\n');
	}

	/**
	 * `apq new <path> (--class | --implements <iface>) [--field <m>]...
	 * [--bodies -] [--write]` — create a new module deterministically: derive
	 * the package + class name from <path>, assemble the scaffold (interface
	 * method stubs with sliced signatures, or verbatim `--field` members), and
	 * run it through the writer so the result is canonical-or-rejected and the
	 * file is never written on a parse failure. Create-only: an existing path
	 * is refused. `--bodies -` reads `@@ <method>` sections from stdin (see
	 * `NewFile`); a method without a section is left as a NotImplementedException
	 * stub (reported on stderr). Without `--write` the source goes to stdout.
	 */
	/** The class name for a new file: its basename without the `.hx` extension. */
	private static function newFileClassName(path: String): String {
		final base: String = haxe.io.Path.withoutDirectory(path);
		return StringTools.endsWith(base, '.hx') ? base.substr(0, base.length - 3) : base;
	}

	/**
	 * Derive the Haxe package for `path` from its location under a `src/` or
	 * `test/` source root: the directory segments below that root, dot-joined
	 * (`.../src/anyparse/check/Foo.hx` → `anyparse.check`). A file directly in
	 * a root, or outside any root, is package-less (`''`).
	 */
	private static function derivePackage(path: String): String {
		final dir: String = haxe.io.Path.directory(FileSystem.absolutePath(path)) + '/';
		for (root in ['/src/', '/test/']) {
			final at: Int = dir.lastIndexOf(root);
			if (at >= 0) {
				var tail: String = dir.substr(at + root.length);
				if (StringTools.endsWith(tail, '/')) tail = tail.substr(0, tail.length - 1);
				return tail == '' ? '' : tail.split('/').join('.');
			}
		}
		return '';
	}

	/**
	 * Resolve an `--implements` argument to the interface's source plus the
	 * import the new file needs. A qualified `pkg.Name` maps to
	 * `<srcRoot>/pkg/Name.hx` (import emitted only when its package differs from
	 * the new file's); a simple `Name` is taken as a sibling in the new file's
	 * own directory (same package, no import). Returns null when the file does
	 * not exist.
	 */
	/**
	 * Resolve an `--implements` argument to the interface's source, its
	 * fully-qualified module path, and its simple name. A qualified `pkg.Name`
	 * maps to `<srcRoot>/pkg/Name.hx`; a simple `Name` is taken as a sibling in
	 * the new file's own directory (its module path is then the new file's
	 * package + `.Name`). Returns null when the file does not exist. The module
	 * path lets the caller carry the interface's sibling sub-types and decide the
	 * interface import.
	 */
	private static function resolveInterface(iface: String, newPath: String): Null<{ source: String, ifaceModule: String, simple: String }> {
		final dot: Int = iface.lastIndexOf('.');
		if (dot >= 0) {
			final simple: String = iface.substr(dot + 1);
			final dir: String = haxe.io.Path.directory(FileSystem.absolutePath(newPath)) + '/';
			var srcRoot: Null<String> = null;
			for (root in ['/src/', '/test/']) {
				final at: Int = dir.lastIndexOf(root);
				if (at >= 0) {
					srcRoot = dir.substr(0, at + root.length);
					break;
				}
			}
			if (srcRoot == null) return null;
			final file: String = srcRoot + iface.split('.').join('/') + '.hx';
			return !FileSystem.exists(file) ? null : { source: readFile(file), ifaceModule: iface, simple: simple };
		}
		final file: String = haxe.io.Path.directory(FileSystem.absolutePath(newPath)) + '/' + iface + '.hx';
		if (!FileSystem.exists(file)) return null;
		final newPkg: String = derivePackage(newPath);
		return { source: readFile(file), ifaceModule: newPkg == '' ? iface : '$newPkg.$iface', simple: iface };
	}

	/**
	 * `apq new <path> (--class | --implements <iface>) [--field <m>]...
	 * [--bodies -] [--write]` — create a new module deterministically: derive
	 * the package + class name from <path>, assemble the scaffold (interface
	 * method stubs with sliced signatures + carried imports, or verbatim
	 * `--field` members), and run it through the writer so the result is
	 * canonical-or-rejected and the file is never written on a parse failure.
	 * Create-only: an existing path is refused. `--bodies -` reads `@@ <method>`
	 * sections from stdin (see `NewFile`); a method without a section is left as
	 * a NotImplementedException stub (reported on stderr). Without `--write` the
	 * source goes to stdout.
	 */
	/**
	 * `apq new <path> (--class | --implements <iface> | --kind <k>) [--extends <T>]...
	 * [--open] [--field <m>]... [--bodies -] [--write]` — create a new module
	 * deterministically: derive the package + class name from <path>, assemble the
	 * scaffold (interface method stubs with sliced signatures + carried imports, or
	 * verbatim `--field` members), and run it through the writer so the result is
	 * canonical-or-rejected and the file is never written on a parse failure.
	 * `--kind` (default class) picks class / interface / enum / typedef; `--extends`
	 * adds a superclass (class) or super-interfaces (interface); `--open` drops the
	 * `final` on a class. Create-only: an existing path is refused. `--bodies -`
	 * reads `@@ <method>` sections from stdin (see `NewFile`); a method without a
	 * section is left as a NotImplementedException stub (reported on stderr).
	 * Without `--write` the source goes to stdout.
	 */
	/**
	 * `apq new <path> (--class | --implements <iface> | --kind <k>) [--extends <T>]...
	 * [--open] [--underlying <T>] [--from <T>]... [--to <T>]... [--field <m>]...
	 * [--bodies -] [--write]` — create a new module deterministically: derive the
	 * package + class name from <path>, assemble the scaffold (interface method
	 * stubs with sliced signatures + carried imports, or verbatim `--field`
	 * members), and run it through the writer so the result is canonical-or-
	 * rejected and the file is never written on a parse failure. `--kind` (default
	 * class) picks class / interface / enum / typedef / abstract; `--extends` adds
	 * a superclass (class) / super-interfaces (interface) / struct extension
	 * (typedef); `--underlying`/`--from`/`--to` shape an abstract; `--open` drops
	 * the `final` on a class. Create-only: an existing path is refused. `--bodies -`
	 * reads `@@ <method>` sections from stdin (see `NewFile`); a method without a
	 * section is left as a NotImplementedException stub (reported on stderr).
	 * Without `--write` the source goes to stdout.
	 */
	/**
	 * `apq set-doc <file> <line>:<col> (<text> | --from-file | -) [--reformat]
	 * [--write]` — add or replace the doc-comment of the declaration at the
	 * cursor (see `SetDoc`). The text (inline / file / stdin via `resolveCodeArg`)
	 * is formatted into a doc-comment block and spliced before the decl, leaving
	 * the declaration itself untouched; the result is writer-formatted and
	 * re-parse-validated (canonical-gated unless `--reformat`).
	 */
	private static function runSetDoc(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var fromFile: Null<String> = null;
		var file: Null<String> = null;
		var pos: Null<String> = null;
		var docText: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--from-file':
					fromFile = expectValue(args, ++i, '--from-file');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printSetDocUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq set-doc: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (pos == null)
						pos = a;
					else if (docText == null)
						docText = a;
					else {
						stderr('apq set-doc: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fromFile != null || docText == '-') {
			final resolved: Null<String> = resolveCodeArg('set-doc', docText == '-' ? '-' : null, fromFile);
			if (resolved == null) return EXIT_RUNTIME;
			docText = resolved;
		}
		if (file == null || pos == null || docText == null) {
			stderr('apq set-doc: expected <file> <line>:<col> (<text> | --from-file <path> | -)\n');
			printSetDocUsage();
			return EXIT_USAGE;
		}
		final loc: Null<Position> = parseLineCol(pos);
		if (loc == null) {
			stderr('apq set-doc: bad position "$pos" (expected <line>:<col>)\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final docStr: String = docText;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq set-doc: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		switch SetDoc.setDoc(source, loc.line, loc.col, docStr, reformat, plugin, optsJson) {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq set-doc: wrote $filePath\n');
				} else
					sysPrint(text);
				return EXIT_OK;
			case Err(message):
				stderr('apq set-doc: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printSetDocUsage(): Void {
		sysPrint('Usage: apq set-doc <file> <line>:<col> (<text> | --from-file <path> | -) [--reformat] [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --from-file <path>  Read the doc text from a file instead of the argument\n');
		sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Add or replace the doc-comment of the declaration at <line>:<col> (the apq\n');
		sysPrint('refs column convention). The text is formatted into a doc-comment block and\n');
		sysPrint('spliced before the declaration; an existing leading doc comment is replaced,\n');
		sysPrint('the declaration itself is left untouched. The text may be inline, --from-file,\n');
		sysPrint('or - for stdin (heredoc-friendly, multi-line). Writer-formatted + validated.\n');
	}

	/**
	 * `apq set-modifier <file> <line>:<col> <change>... [--reformat] [--write]` —
	 * flip the visibility / add or remove boolean modifiers of the declaration at
	 * the cursor without retyping it (see `SetModifier`). Each change is
	 * `public` / `private` or `+<mod>` / `-<mod>`. Change tokens may begin with a
	 * single `-` (e.g. `-inline`); only a leading `--` is treated as an option.
	 * Writer-formatted + re-parse-validated (canonical-gated unless `--reformat`).
	 */
	private static function runSetModifier(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var pos: Null<String> = null;
		final changes: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printSetModifierUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq set-modifier: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (pos == null)
						pos = a;
					else
						changes.push(a);
			}
			i++;
		}
		if (file == null || pos == null || changes.length == 0) {
			stderr('apq set-modifier: expected <file> <line>:<col> <change>... (e.g. public, +static, -inline)\n');
			printSetModifierUsage();
			return EXIT_USAGE;
		}
		final loc: Null<Position> = parseLineCol(pos);
		if (loc == null) {
			stderr('apq set-modifier: bad position "$pos" (expected <line>:<col>)\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq set-modifier: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		switch SetModifier.setModifier(source, loc.line, loc.col, changes, reformat, plugin, optsJson) {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq set-modifier: wrote $filePath\n');
				} else
					sysPrint(text);
				return EXIT_OK;
			case Err(message):
				stderr('apq set-modifier: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printSetModifierUsage(): Void {
		sysPrint('Usage: apq set-modifier <file> <line>:<col> <change>... [--reformat] [--write]\n');
		sysPrint('\n');
		sysPrint('Changes:\n');
		sysPrint('  public | private    Set the visibility\n');
		sysPrint('  +<mod> | -<mod>     Add / remove a boolean modifier\n');
		sysPrint('                      (static, inline, override, macro, extern, dynamic)\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Flip the visibility / add or remove modifiers of the declaration at the\n');
		sysPrint('cursor without retyping it — the safe replacement for replace-node on a\n');
		sysPrint('modifier. `final` is not handled (it wraps the declaration; use replace-node).\n');
		sysPrint('The result is WRITER-FORMATTED + re-parse-validated.\n');
	}

	/**
	 * `apq new <path> (--class | --implements <iface> | --kind <k> | --raw -)
	 * [--extends <T>]... [--open] [--underlying <T>] [--from <T>]... [--to <T>]...
	 * [--field <m>]... [--bodies -] [--write]` — create a new module
	 * deterministically. The structured path derives the package + class name from
	 * <path> and assembles the scaffold (interface stubs / `--field` / `@@`
	 * sections incl. `@@ members`); `--raw -` instead takes the COMPLETE file from
	 * stdin (the validated atomic equivalent of a raw write, for shapes no spec
	 * covers). Either way the writer round-trip canonicalises + re-parse-validates,
	 * and the file is never written on a parse failure. Create-only: an existing
	 * path is refused. Without `--write` the source goes to stdout.
	 */
	private static function runNew(args: Array<String>): Int {
		final o: NewOpts = parseNewArgs(args);
		if (o.errExit != null) return o.errExit;
		final path: Null<String> = o.path;
		if (path == null) {
			stderr('apq new: expected <path>\n');
			printNewUsage();
			return EXIT_USAGE;
		}
		if (!o.raw && ['class', 'interface', 'enum', 'typedef', 'abstract'].indexOf(o.kind) < 0) {
			stderr('apq new: --kind must be class|interface|enum|typedef|abstract (got "${o.kind}")\n');
			return EXIT_USAGE;
		}
		final hasIntent: Bool = o.raw || o.asClass || o.iface != null || o.kind != 'class' || o.extendsList.length > 0 || o.fields.length
			> 0;
		if (!hasIntent) {
			stderr('apq new: specify --class / --implements <iface> / --kind <k> / --raw -\n');
			return EXIT_USAGE;
		}
		final filePath: String = path;
		if (FileSystem.exists(filePath)) {
			stderr('apq new: $filePath already exists (create-only; use the ops / fmt to modify)\n');
			return EXIT_RUNTIME;
		}

		final plugin: GrammarPlugin = pickPlugin(o.lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		return executeNew(o, filePath, plugin, optsJson);
	}

	/** Shared tail for `apq new`: report stub warnings, then write the file or emit to stdout. */
	private static function emitNew(filePath: String, result: EditResult, stubbed: Array<String>, write: Bool): Int {
		switch result {
			case Ok(text):
				for (m in stubbed) stderr('apq new: $m() left as a NotImplementedException stub\n');
				if (write) {
					writeFile(filePath, text);
					stderr('apq new: wrote $filePath\n');
				} else
					sysPrint(text);
				return EXIT_OK;
			case Err(message):
				stderr('apq new: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printNewUsage(): Void {
		sysPrint(
			'Usage: apq new <path> (--class | --implements <iface> | --kind <k> | --raw -) [--extends <T>]... [--open] [--underlying <T>] [--from <T>]... [--to <T>]... [--field <m>]... [--bodies -] [--write]\n'
		);
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --kind <k>          class (default) | interface | enum | typedef | abstract\n');
		sysPrint('  --class             Shorthand for --kind class\n');
		sysPrint('  --raw -            Read the COMPLETE file from stdin (validated atomic\n');
		sysPrint('                      write; for shapes no spec covers, e.g. multi-type files)\n');
		sysPrint('  --implements <i>    (class) implement interface <i> — stub every method\n');
		sysPrint('                      with its real signature (simple name = same package,\n');
		sysPrint('                      or a qualified pkg.Name)\n');
		sysPrint('  --extends <T>       (class) superclass / (interface, typedef) extension;\n');
		sysPrint('                      repeatable for interface/typedef; a qualified pkg.T is imported\n');
		sysPrint('  --underlying <T>    (abstract) the underlying type — required for --kind abstract\n');
		sysPrint('  --from <T> / --to <T>  (abstract) implicit-cast clauses (repeatable)\n');
		sysPrint('  --open              Emit a non-final class (default: final)\n');
		sysPrint('  --field <member>    Add a verbatim member (repeatable)\n');
		sysPrint('  --bodies -          Read @@ sections from stdin: @@ <method> bodies,\n');
		sysPrint('                      @@ members (a free-form member block), @@ imports, @@ doc;\n');
		sysPrint('                      an unfilled interface method gets a NotImplementedException stub\n');
		sysPrint('  --write             Write the new file (default: emit to stdout)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Assemble a NEW module and canonicalise it through the writer (parses-or-\n');
		sysPrint('fails, byte-canonical, atomic). The path must not already exist — modify\n');
		sysPrint('an existing file with the structural ops / apq fmt. An unparseable result\n');
		sysPrint('(e.g. a malformed @@ body) exits non-zero with nothing written.\n');
	}

	/**
	 * `apq set-comment <file> <line>:<col> (<text> | --from-file | -) [--reformat]
	 * [--write]` — replace the comment at the cursor (see `SetComment`). Line
	 * comments are trivia no other op reaches; a block comment is replaced whole, a
	 * full-line line-comment run as one unit. The replacement must itself be a
	 * comment; the result is writer-formatted and re-parse-validated (canonical-
	 * gated unless `--reformat`).
	 */
	private static function runSetComment(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var fromFile: Null<String> = null;
		var file: Null<String> = null;
		var pos: Null<String> = null;
		var commentText: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--from-file':
					fromFile = expectValue(args, ++i, '--from-file');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printSetCommentUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq set-comment: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (pos == null)
						pos = a;
					else if (commentText == null)
						commentText = a;
					else {
						stderr('apq set-comment: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fromFile != null || commentText == '-') {
			final resolved: Null<String> = resolveCodeArg('set-comment', commentText == '-' ? '-' : null, fromFile);
			if (resolved == null) return EXIT_RUNTIME;
			commentText = resolved;
		}
		if (file == null || pos == null || commentText == null) {
			stderr('apq set-comment: expected <file> <line>:<col> (<text> | --from-file <path> | -)\n');
			printSetCommentUsage();
			return EXIT_USAGE;
		}
		final loc: Null<Position> = parseLineCol(pos);
		if (loc == null) {
			stderr('apq set-comment: bad position "$pos" (expected <line>:<col>)\n');
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final commentStr: String = commentText;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq set-comment: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		switch SetComment.setComment(source, loc.line, loc.col, commentStr, reformat, plugin, optsJson) {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq set-comment: wrote $filePath\n');
				} else
					sysPrint(text);
				return EXIT_OK;
			case Err(message):
				stderr('apq set-comment: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printSetCommentUsage(): Void {
		sysPrint('Usage: apq set-comment <file> <line>:<col> (<text> | --from-file <path> | -) [--reformat] [--write]\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --from-file <path>  Read the comment text from a file instead of the argument\n');
		sysPrint('  --reformat          Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
	}

	/**
	 * `apq rewrite <file> <pattern> <replacement> [--reformat] [--write]` —
	 * structural search-and-replace (see `Rewrite`). Every node matching the
	 * `apq search`-syntax `<pattern>` is rewritten from `<replacement>`, where
	 * `$x` / `${x}` expand to the captured metavar's source and `${x+N}` /
	 * `${x-N}` shift an integer-literal metavar. All matches in one pass,
	 * writer-formatted + re-parse-validated (canonical-gated unless `--reformat`).
	 */
	private static function runRewrite(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var pattern: Null<String> = null;
		var replacement: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printRewriteUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq rewrite: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (pattern == null)
						pattern = a;
					else if (replacement == null)
						replacement = a;
					else {
						stderr('apq rewrite: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || pattern == null || replacement == null) {
			stderr('apq rewrite: expected <file> <pattern> <replacement>\n');
			printRewriteUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final pat: String = pattern;
		final repl: String = replacement;
		final source: String = try readFile(filePath) catch (exception: Exception) {
			stderr('apq rewrite: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = pickPlugin(lang);
		final optsJson: Null<String> = discoverFormatConfig(filePath);
		switch Rewrite.rewrite(source, pat, repl, reformat, plugin, optsJson) {
			case Ok(text):
				if (write) {
					writeFile(filePath, text);
					stderr('apq rewrite: wrote $filePath\n');
				} else
					sysPrint(text);
				return EXIT_OK;
			case Err(message):
				stderr('apq rewrite: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printRewriteUsage(): Void {
		sysPrint('Usage: apq rewrite <file> <pattern> <replacement> [--reformat] [--write]\n');
		sysPrint('\n');
		sysPrint("Structural search-and-replace. <pattern> uses apq search syntax with $x\n");
		sysPrint("metavariables; <replacement> is a template where $x / ${x} expand to the\n");
		sysPrint("captured source and ${x+N} / ${x-N} shift an integer-literal metavar by N.\n");
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --reformat  Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --write     Overwrite <file> in place (default: emit to stdout)\n');
	}

	private static function runCommentRewrite(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var list: Bool = false;
		var reformat: Bool = false;
		var regex: Bool = false;
		var find: Null<String> = null;
		var replace: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--write', '-w':
					write = true;
				case '--list', '-l':
					list = true;
				case '--reformat':
					reformat = true;
				case '--regex':
					regex = true;
				case '-h', '--help':
					printCommentRewriteUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq comment-rewrite: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (find == null)
						find = a;
					else if (replace == null)
						replace = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (find == null || replace == null || inputSpecs.length == 0) {
			stderr('apq comment-rewrite: expected <find> <replace> <file/dir/glob>...\n');
			printCommentRewriteUsage();
			return EXIT_USAGE;
		}

		final findStr: String = find;
		final replaceStr: String = replace;
		final plugin: GrammarPlugin = pickPlugin(lang);
		final expanded: { paths: Array<String>, singleFile: Bool } = expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq comment-rewrite: ${inputSpecs.join(', ')} matched no .hx files\n');
			return EXIT_RUNTIME;
		}

		final listMode: Bool = list || (!write && !expanded.singleFile);

		var changed: Int = 0;
		var failed: Int = 0;
		for (path in paths) {
			final source: String = try readFile(path) catch (exception: Exception) {
				stderr('apq comment-rewrite: $path: ${exception.message}\n');
				failed++;
				continue;
			};
			final optsJson: Null<String> = discoverFormatConfig(path);
			switch CommentRewrite.rewrite(source, findStr, replaceStr, regex, reformat, plugin, optsJson) {
				case Ok(text):
					final isChanged: Bool = text != source;
					if (write) {
						if (isChanged) {
							writeFile(path, text);
							changed++;
						}
					} else if (listMode) {
						if (isChanged) {
							sysPrint('$path\n');
							changed++;
						}
					} else
						sysPrint(text);
				case Err(message):
					stderr('apq comment-rewrite: $path: $message\n');
					failed++;
			}
		}

		if (write)
			stderr('apq comment-rewrite: rewrote $changed file(s)' + (failed > 0 ? ', $failed failed' : '') + '\n');
		else if (listMode && failed > 0) stderr('apq comment-rewrite: $failed file(s) failed\n');
		return failed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function printCommentRewriteUsage(): Void {
		sysPrint('Usage: apq comment-rewrite <find> <replace> <file/dir/glob>... [--regex] [--write] [--list]\n');
		sysPrint('\n');
		sysPrint('Text search-and-replace scoped to COMMENT bodies (the write-twin of\n');
		sysPrint('apq lit). Code and comment delimiters are never touched; strings are\n');
		sysPrint('skipped. The result is canonical + re-parse-validated.\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint("  --regex        <find> is a regex; <replace> a template where ${0}/${N}\n");
		sysPrint("                 expand to group N and ${N+K}/${N-K} shift group N by K\n");
		sysPrint('  --write, -w    Rewrite each file in place (default: stdout for one file,\n');
		sysPrint('                 list of changed paths for a dir / multiple files)\n');
		sysPrint('  --list, -l     Print paths whose comments would change; no rewrite\n');
		sysPrint('  --reformat     Canonicalise the whole file (allow a non-canonical input)\n');
		sysPrint('  --lang <name>  Grammar plugin (default: haxe)\n');
	}

	/**
	 * Resolve a `source --select <sel>` / `--at <line>:<col>` address to the
	 * 1-based inclusive line range spanning the matched node. Parses `content`
	 * with the `lang` plugin (so it works only on a parseable file, unlike the
	 * raw `--range` reader). Returns `null` after printing a specific
	 * `apq source: …` diagnostic (no match / ambiguous selector / position not on
	 * a node / parse failure).
	 */
	private static function resolveNodeLineBounds(
		path: String, content: String, lang: String, selectExpr: Null<String>, atSpec: Null<String>
	): Null<{ from: Int, to: Int }> {
		final plugin: GrammarPlugin = pickPlugin(lang);
		final tree: QueryNode = try plugin.parseFile(content) catch (exception: Exception) {
			stderr('apq source: $path does not parse: ${exception.message}\n');
			return null;
		};

		var node: Null<QueryNode> = null;
		if (selectExpr != null) {
			final selector: Selector = try Selector.parse(selectExpr) catch (exception: Exception) {
				stderr('apq source: malformed selector "$selectExpr": ${exception.message}\n');
				return null;
			};
			final matches: Array<QueryNode> = Engine.select(tree, selector, plugin.selectKindEquivalence());
			if (matches.length == 0) {
				stderr('apq source: no node matched --select "$selectExpr"\n');
				return null;
			}
			if (matches.length > 1) {
				stderr('apq source: --select "$selectExpr" matched ${matches.length} nodes — narrow it (e.g. Kind:name)\n');
				return null;
			}
			node = matches[0];
		} else if (atSpec != null) {
			final pos: Null<Position> = parseLineCol(atSpec);
			if (pos == null) {
				stderr('apq source: malformed position "$atSpec" — expected <line>:<col>\n');
				return null;
			}
			node = Engine.at(tree, Span.offsetOf(content, pos.line, pos.col));
			if (node == null) {
				stderr('apq source: no node at $atSpec\n');
				return null;
			}
		} else {
			stderr('apq source: provide --select <sel> or --at <line>:<col>\n');
			return null;
		}

		final resolved: Null<QueryNode> = node;
		if (resolved == null) {
			stderr('apq source: could not resolve a node from the address\n');
			return null;
		}
		final span: Null<Span> = resolved.span;
		if (span == null) {
			stderr('apq source: the matched node has no source span\n');
			return null;
		}
		final endOffset: Int = span.to > span.from ? span.to - 1 : span.from;
		return { from: span.lineCol(content).line, to: new Span(endOffset, endOffset).lineCol(content).line };
	}

	/** Map a `--fail-on` level name to its `Severity`, or null if unknown. */
	/**
	 * `--exit-on-empty` / `--require-match`, stripped from the argv in `run` and
	 * reset there on every invocation (single CLI call chain, never concurrent).
	 * When set, a find-walker that produced no hits exits non-zero instead of 0, so
	 * a script can reliably detect "no match" (e.g. confirm a symbol was removed).
	 */
	private static var _requireMatch: Bool = false;

	/**
	 * Walker exit code honouring `--exit-on-empty`: `EXIT_RUNTIME` when the walk
	 * found nothing and the flag was set, else `EXIT_OK`. Default (flag unset)
	 * keeps every walk exiting 0 — backward compatible.
	 */
	private static inline function emptyExit(empty: Bool): Int {
		return empty && _requireMatch ? EXIT_RUNTIME : EXIT_OK;
	}

	/** The plural suffix for a count: `''` for 1, `'s'` otherwise. */
	private static inline function plural(n: Int): String return n == 1 ? '' : 's';

	/** Terminal-case StripOpts: a flag/usage path that the caller returns immediately, ignoring every other field. */
	private static inline function stripParseExit(code: Int): StripOpts {
		return {
			lang: '',
			showSource: false,
			dryRun: false,
			perPattern: false,
			fromCluster: null,
			regexMode: false,
			files: [],
			patterns: [],
			replacements: [],
			errExit: code
		};
	}

	/**
	 * Parse `strip` argv into a StripOpts. A terminal case (`-h`/`--help`
	 * or any usage error) prints its message and returns with `errExit`
	 * set; the caller returns that code immediately. The natural end
	 * returns the full struct with `errExit: null`.
	 */
	private static function parseStripArgs(args: Array<String>): StripOpts {
		var lang: String = 'haxe';
		var showSource: Bool = false;
		// --dry-run: skip the parse step, only verify that every supplied
		// --replace/--delete pattern actually matched at least once in
		// at least one file. Typo guard for batch strip-sweeps — when
		// the pattern silently doesn't match, the corpus delta misleads;
		// a single dry-run pass surfaces the typo before any apply.
		var dryRun: Bool = false;
		// --per-pattern: isolation diagnostic for multi-pattern strip on a
		// single file. Runs the parse N+2 times — baseline (no patterns),
		// each pattern in isolation, and the combined apply — surfacing
		// whether each pattern is a sole-blocker, a partial contributor,
		// or a no-op. Catches the interlocking-blockers trap where a
		// combined-strip PARSE OK can mask that NO individual pattern
		// unblocks alone (i.e. the slice requires N separate code
		// mechanisms, not one). Single-file only — for multi-file sweeps
		// the matrix would be NxM and the signal is in --dry-run +
		// per-file PARSE OK/FAIL combinations.
		var perPattern: Bool = false;
		// `--from-cluster <key>` switches positional mode: the (single)
		// positional becomes the corpus root (recon-style, env fallback
		// to ANYPARSE_HXFORMAT_FORK/test/testcases); the file list is
		// derived from a recon walk of that root, filtered to the named
		// cluster. Direct complement to `recon --predict-strip`'s
		// upper-bound prediction — this is the actual sweep apply.
		var fromCluster: Null<String> = null;
		// --regex: treat every --replace / --delete pattern as an EReg
		// pattern (PCRE-ish, Haxe EReg dialect) instead of a literal
		// substring. Application path switches to EReg.replace (global)
		// for substitution and EReg.map for hit counting. The replacement
		// string keeps its literal semantics — to use a backref, write
		// e.g. `$1` per EReg.replace docs. Malformed regex is reported at
		// arg-validation time with EXIT_USAGE before any FS I/O.
		var regexMode: Bool = false;
		final files: Array<String> = [];
		final patterns: Array<String> = [];
		final replacements: Array<String> = [];
		var pendingReplace: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--replace':
					if (pendingReplace != null) {
						stderr('apq strip: --replace "$pendingReplace" needs a --with before the next --replace\n');
						return stripParseExit(EXIT_USAGE);
					}
					pendingReplace = expectValue(args, ++i, '--replace');
				case '--with':
					if (pendingReplace == null) {
						stderr('apq strip: --with requires a preceding --replace\n');
						return stripParseExit(EXIT_USAGE);
					}
					patterns.push(pendingReplace);
					replacements.push(expectValue(args, ++i, '--with'));
					pendingReplace = null;
				case '--delete':
					if (pendingReplace != null) {
						stderr('apq strip: --replace "$pendingReplace" needs a --with before --delete\n');
						return stripParseExit(EXIT_USAGE);
					}
					patterns.push(expectValue(args, ++i, '--delete'));
					replacements.push('');
				case '--regex':
					regexMode = true;
				case '--show':
					showSource = true;
				case '--dry-run':
					dryRun = true;
				case '--per-pattern':
					perPattern = true;
				case '--from-cluster':
					fromCluster = expectValue(args, ++i, '--from-cluster');
				case '-h', '--help':
					printStripUsage();
					return stripParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq strip: unknown option "$a"\n');
						return stripParseExit(EXIT_USAGE);
					}
					files.push(a);
			}
			i++;
		}
		if (pendingReplace != null) {
			stderr('apq strip: --replace "$pendingReplace" needs a --with\n');
			return stripParseExit(EXIT_USAGE);
		}
		if (patterns.length == 0) {
			stderr('apq strip: missing at least one --replace/--with or --delete\n');
			printStripUsage();
			return stripParseExit(EXIT_USAGE);
		}
		return {
			lang: lang,
			showSource: showSource,
			dryRun: dryRun,
			perPattern: perPattern,
			fromCluster: fromCluster,
			regexMode: regexMode,
			files: files,
			patterns: patterns,
			replacements: replacements,
			errExit: null
		};
	}

	/**
	 * --dry-run summary: print each pattern's total match count, then
	 * warn (and return EXIT_RUNTIME) when nothing changed anywhere or
	 * when any single pattern matched 0 occurrences. EXIT_OK otherwise.
	 */
	private static function reportStripDryRun(patterns: Array<String>, patternHits: Array<Int>, anyChanged: Bool): Int {
		// Per-pattern summary first so a sweep over N files exposes
		// each pattern's match count individually. Exit non-zero
		// when ANY supplied pattern matched 0 occurrences — the
		// guard's whole purpose is to catch a typo even when a
		// sibling pattern in the same call did match. Use the
		// global zero case for a stronger error message.
		var anyZero: Bool = false;
		for (idx in 0...patterns.length) {
			final pat: String = patterns[idx];
			final total: Int = patternHits[idx];
			if (total == 0) anyZero = true;
			sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		if (!anyChanged) {
			stderr('apq strip: --dry-run: WARNING: no pattern matched in any file (typo? pattern bytes vs. file bytes mismatch?)\n');
			return EXIT_RUNTIME;
		}
		if (anyZero) {
			stderr('apq strip: --dry-run: WARNING: one or more patterns matched 0 occurrences — see per-pattern totals above\n');
			return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	/**
	 * Apply the strip substitutions to every file in `o.files` via
	 * stripOneFile: dry-run defers to reportStripDryRun; otherwise each
	 * stripped file is re-parsed and PARSE OK/FAIL reported, with a
	 * no-change warning and a multi-file summary. EXIT_RUNTIME if any
	 * file failed to parse, EXIT_OK otherwise.
	 */
	private static function executeStrip(plugin: GrammarPlugin, o: StripOpts, compiledRegex: Null<Array<EReg>>): Int {
		final multi: Bool = o.files.length > 1;
		var anyFailed: Bool = false;
		var anyChanged: Bool = false;
		var passCount: Int = 0;
		var failCount: Int = 0;
		// --dry-run: track per-pattern match totals across all files so a
		// pattern that matched 0 occurrences ANYWHERE surfaces as a typo,
		// even when other patterns in the same call did match.
		final patternHits: Array<Int> = o.dryRun ? [for (_ in 0...o.patterns.length) 0] : [];
		// Narrow `Null<Array<EReg>>` to `Array<EReg>` in one place — the
		// inline `(compiledRegex : Array<EReg>)` cast does not satisfy
		// strict null safety. Empty fallback keeps the regex-mode-off
		// branch from indexing it.
		final regexes: Array<EReg> = compiledRegex ?? [];
		for (filePath in o.files) {
			final result: { changed: Bool, status: Int } = stripOneFile(plugin, o, regexes, filePath, multi, patternHits);
			if (result.changed) anyChanged = true;
			switch result.status {
				case 0:
					passCount++;
				case 1:
					failCount++;
					anyFailed = true;
				case _:
			}
		}
		if (o.dryRun) return reportStripDryRun(o.patterns, patternHits, anyChanged);
		if (!anyChanged) {
			final scope: String = multi ? 'across all ${o.files.length} files' : '';
			stderr(
				'apq strip: WARNING: no substitution changed the source (patterns matched 0 occurrences${scope == '' ? '' : ' $scope'})\n'
			);
		}
		if (multi) {
			sysPrint('--- $passCount PARSE OK, $failCount PARSE FAIL (total ${o.files.length}) ---\n');
		}
		return anyFailed ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * Apply every substitution to one file and report it: in dry-run,
	 * accumulate per-pattern hits into `patternHits` and print the
	 * WOULD CHANGE / NO MATCH line; otherwise re-parse the stripped
	 * source and print PARSE OK / PARSE FAIL. Returns whether the file
	 * changed and a status (-1 dry-run, 0 parse ok, 1 parse fail).
	 */
	private static function stripOneFile(
		plugin: GrammarPlugin, o: StripOpts, regexes: Array<EReg>, filePath: String, multi: Bool, patternHits: Array<Int>
	): { changed: Bool, status: Int } {
		final source: String = readSourceForParse(filePath);
		var stripped: String = source;
		var fileHits: Int = 0;
		for (idx in 0...o.patterns.length) {
			if (o.dryRun) {
				final hits: Int = o.regexMode ? countRegexHits(regexes[idx], stripped) : countOccurrences(stripped, o.patterns[idx]);
				patternHits[idx] += hits;
				fileHits += hits;
			}
			stripped = o.regexMode
				? regexes[idx].replace(stripped, o.replacements[idx])
				: StringTools.replace(stripped, o.patterns[idx], o.replacements[idx]);
		}
		final changed: Bool = stripped != source;
		if (o.showSource) {
			stderr('--- stripped source (${filePath}) ---\n$stripped\n--- end ---\n');
		}
		final prefix: String = multi ? '$filePath: ' : '';
		if (o.dryRun) {
			final tag: String = fileHits > 0 ? 'WOULD CHANGE' : 'NO MATCH';
			sysPrint('${prefix}$tag ($fileHits substitution${plural(fileHits)})\n');
			return { changed: changed, status: -1 };
		}
		try {
			plugin.parseFile(stripped);
			sysPrint('${prefix}PARSE OK\n');
			return { changed: changed, status: 0 };
		} catch (e: ParseError) {
			sysPrint('${prefix}PARSE FAIL: ${e.toString()}\n');
			return { changed: changed, status: 1 };
		} catch (e: Exception) {
			sysPrint('${prefix}PARSE FAIL: ${e.message}\n');
			return { changed: changed, status: 1 };
		}
	}

	/** Terminal-case ReconOpts: a flag/usage path the caller returns immediately, ignoring every other field. */
	private static inline function reconParseExit(code: Int): ReconOpts {
		return {
			lang: '',
			topN: 0,
			probePath: null,
			rootDir: null,
			clusterFilter: null,
			predictStrip: false,
			regressionProbe: false,
			candidatesRegex: null,
			predictRelax: false,
			permissiveConstruct: false,
			showSource: false,
			noTargetClusterFilter: null,
			patterns: [],
			replacements: [],
			regexMode: false,
			compiledRegex: null,
			writerEqualsAfter: false,
			writerEqualsPlain: false,
			expectedPath: null,
			errExit: code
		};
	}

	/**
	 * First validation group: `--source` drill-mode requirement, the
	 * `--regression-probe` mutex set, and the `--candidates` mutex set.
	 * Returns a non-null exit code (EXIT_USAGE) on the first violation,
	 * after printing the diagnostic; null when this group passes.
	 */
	private static function validateReconModesA(o: ReconOpts): Null<Int> {
		// `--source` is meaningful only in modes where the per-path window
		// adds signal — `--cluster <key>` drill, `--no-target-cluster
		// <key>` drill, `--predict-strip` STILL FAIL entries, or
		// `--predict-relax` (STILL FAIL in sweep mode, both STILL FAIL +
		// NO TARGET in probe / drill modes). In plain sweep mode without
		// any of those it would flood every SKIP line with a per-fixture
		// window, so make the misuse a hard usage error rather than a
		// silent no-op.
		if (o.showSource && o.clusterFilter == null && o.noTargetClusterFilter == null && !o.predictStrip && !o.predictRelax) {
			stderr(
				'apq recon: --source requires --cluster <key> / --no-target-cluster <key> / --predict-strip / --predict-relax (drill / STILL-FAIL modes only; would flood the sweep otherwise)\n'
			);
			return EXIT_USAGE;
		}
		// `--regression-probe` is its own mode — separate from probe /
		// predict / cluster / source. Reject the combinations with a clear
		// usage error instead of silently picking one path.
		if (o.regressionProbe) {
			if (o.probePath != null) {
				stderr('apq recon: --regression-probe and --probe are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (o.predictStrip) {
				stderr('apq recon: --regression-probe and --predict-strip are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (o.clusterFilter != null) {
				stderr('apq recon: --regression-probe and --cluster are mutually exclusive\n');
				return EXIT_USAGE;
			}
		}
		if (o.candidatesRegex != null && (
			o.probePath != null || o.predictStrip || o.clusterFilter != null || o.regressionProbe || o.predictRelax
		)) {
			stderr(
				'apq recon: --candidates is mutually exclusive with --probe / --predict-strip / --cluster / --regression-probe / --predict-relax\n'
			);
			return EXIT_USAGE;
		}
		return null;
	}

	/**
	 * Second validation group: the `--predict-relax` mutex set, the
	 * `--no-target-cluster` requirement/mutex set, and the
	 * `--permissive-construct` mutex check. Returns a non-null exit code
	 * (EXIT_USAGE) on the first violation; null when this group passes.
	 */
	private static function validateReconModesB(o: ReconOpts): Null<Int> {
		if (o.predictRelax) {
			if (o.predictStrip) {
				stderr(
					'apq recon: --predict-relax and --predict-strip are mutually exclusive (opposite models — strip removes tokens, relax inserts the expected one)\n'
				);
				return EXIT_USAGE;
			}
			if (o.regressionProbe) {
				stderr('apq recon: --predict-relax and --regression-probe are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (o.patterns.length > 0) {
				stderr(
					'apq recon: --predict-relax does not take --replace/--with/--delete (the injected token comes from the parser`s `expected` hint)\n'
				);
				return EXIT_USAGE;
			}
		}
		if (o.noTargetClusterFilter != null) {
			if (!o.predictRelax) {
				stderr(
					'apq recon: --no-target-cluster requires --predict-relax (the footer NO TARGET breakdown is only produced in predict-relax sweep mode)\n'
				);
				return EXIT_USAGE;
			}
			if (o.clusterFilter != null) {
				stderr(
					'apq recon: --cluster and --no-target-cluster are mutually exclusive (one drill at a time — --cluster drills by forward-locus, --no-target-cluster drills by expected-message)\n'
				);
				return EXIT_USAGE;
			}
			if (o.probePath != null) {
				stderr(
					'apq recon: --no-target-cluster requires sweep mode (no NO TARGET aggregation in --probe mode — pass a corpus directory instead)\n'
				);
				return EXIT_USAGE;
			}
		}
		if (o.permissiveConstruct && (o.probePath != null || o.predictStrip || o.predictRelax || o.regressionProbe
		|| o.clusterFilter != null || o.candidatesRegex != null || o.patterns.length > 0)) {
			stderr(
				'apq recon: --permissive-construct is its own mode — mutually exclusive with --probe / --predict-strip / --predict-relax / --regression-probe / --cluster / --candidates / --replace/--with/--delete\n'
			);
			return EXIT_USAGE;
		}
		return null;
	}

	/**
	 * Third validation group: `--writer-equals` requires `--probe` and is
	 * incompatible with `--predict-strip` / `--predict-relax`, and
	 * `--expected` requires `--writer-equals`. Returns a non-null exit
	 * code (EXIT_USAGE) on the first violation; null when it passes.
	 */
	private static function validateReconWriterEquals(o: ReconOpts): Null<Int> {
		if (o.writerEqualsAfter) {
			if (o.probePath == null) {
				stderr(
					'apq recon: --writer-equals requires --probe <file> (single-file mode; sweep mode already does byte-comparison via the corpus harness)\n'
				);
				return EXIT_USAGE;
			}
			if (o.predictStrip) {
				stderr(
					'apq recon: --writer-equals is incompatible with --predict-strip (the stripped source diverges from expected by construction — apply the slice first, then probe + writer-equals on the unstripped source)\n'
				);
				return EXIT_USAGE;
			}
			if (o.predictRelax) {
				stderr(
					'apq recon: --writer-equals is incompatible with --predict-relax (relax synthesises a missing token; expected bytes won`t match the patched source)\n'
				);
				return EXIT_USAGE;
			}
		}
		if (o.expectedPath != null && !o.writerEqualsAfter) {
			stderr('apq recon: --expected requires --writer-equals\n');
			return EXIT_USAGE;
		}
		return null;
	}

	/**
	 * Parse `recon` argv into a ReconOpts. A terminal case (`-h`/`--help`
	 * or any usage error) prints its message and returns with `errExit`
	 * set; the caller returns that code immediately. The natural end runs
	 * the post-loop validations and returns the full struct with
	 * `errExit: null`.
	 */
	private static function parseReconArgs(args: Array<String>): ReconOpts {
		var lang: String = 'haxe';
		var topN: Int = RECON_TOP_N_DEFAULT;
		var probePath: Null<String> = null;
		var rootDir: Null<String> = null;
		var clusterFilter: Null<String> = null;
		var predictStrip: Bool = false;
		// `--regression-probe`: read the prior sweep snapshot's per-fixture
		// status map (`bin/.last-sweep.json` `fixtures` array) and diff
		// against the current corpus's parse-OK/FAIL state. Surfaces every
		// fixture whose parse status FLIPPED since the snapshot was
		// written. Catches "I edited the grammar, am I breaking anything
		// that was working?" pre-sweep — cheaper than a full corpus rerun
		// because it only does the trivia parse step (no writer / no
		// expected-bytes comparison). Mutually exclusive with --probe /
		// --predict-strip / --cluster (separate diagnostic mode).
		var regressionProbe: Bool = false;
		// `--candidates <regex>`: cross-cluster construct enumeration.
		// Walks the same skip-parse record set as the sweep, applies
		// the EReg against each fixture's source, and prints
		// `<path> :: N matches` for every file with ≥1 hit (sorted by
		// count desc). Closes the gap where the histogram clusters by
		// exact forward-locus, so a construct that lives in different
		// multi-blocker fixtures (Slice 38's `new T<...>(` → 5 surfaced,
		// 6 actually present) is undercounted. Mutually exclusive with
		// --predict-strip / --cluster / --probe / --regression-probe.
		var candidatesRegex: Null<String> = null;
		// `--predict-relax`: terminator-insertion predictor. For each
		// skip-parse fixture, take the ParseError's `expected` hint as
		// the missing token and INSERT it at the fail-locus. If the
		// patched source parses, the slice candidate is gate-relaxation
		// (make the terminator optional via `@:trailOpt` / `@:fmt(trailOptParseGate(…))`).
		// If STILL FAIL, the gap is deeper than the immediate terminator.
		// Complement to `--predict-strip` (which models the OPPOSITE —
		// remove tokens to advance past a syntax mismatch): predict-relax
		// models "the parser would accept missing X at this position".
		// Mutex with --predict-strip / --regression-probe / --candidates.
		var predictRelax: Bool = false;
		// `--permissive-construct`: field-optionalization predictor.
		// Walks every `mandatory-ref-lead-trail` candidate from
		// `gates --mechanism mandatory-ref-lead-trail` (Slice 40's relax-
		// candidate inventory), strips the bracket-pair `<lead>...<trail>`
		// from each skip-parse fixture, and re-parses. Aggregates
		// UNBLOCK / STILL FAIL / NO MATCH per candidate so the user sees
		// which field-optionalization would unblock which fixtures
		// BEFORE committing to a Slice 40-style edit. Mutex with every
		// other recon mode — it's its own pipeline.
		var permissiveConstruct: Bool = false;
		// `--source`: drill-mode-only flag. When set in combination with
		// `--cluster <key>`, the per-path output gains a windowed source
		// snippet centred on the fail-locus. Outside drill it would
		// flood every SKIP line; usage error guards that.
		var showSource: Bool = false;
		// `--no-target-cluster <expected-msg>`: drill into ONE bucket of the
		// `--predict-relax` footer NO TARGET breakdown — the histogram that
		// aggregates per-file `NoTarget` outcomes by `res.message`
		// (`70× expected hint is empty after quote-strip` / `12× expected
		// HxDecl` / …). Footer keys live in a different namespace than
		// `--cluster <key>` (which drills by normalised forward-locus on
		// `r.clusterKey`); there was previously no path from the footer
		// aggregate to the file list. Active only in sweep predict-relax
		// mode; mutex with `--cluster` (one drill at a time) and `--probe`
		// (single-file, no aggregation).
		var noTargetClusterFilter: Null<String> = null;
		// Twin of `runStrip`'s arg-parsing: --replace X --with Y pairs
		// plus --delete X shortcut. Patterns and replacements arrays
		// stay aligned by construction. Active only with --predict-strip.
		final patterns: Array<String> = [];
		final replacements: Array<String> = [];
		var pendingReplace: Null<String> = null;
		// --regex: same semantics as `apq strip --regex` — treat every
		// --replace / --delete pattern as an EReg pattern. Lets one
		// predict-strip call cover every site of a construct in the
		// corpus (e.g. `new [A-Z]\w*<[^>]+>\(` matches every templated
		// constructor call, not just one literal pair) — closes the
		// pain where Slice 38's recon under-counted because the
		// histogram clusters by exact forward-locus shape.
		var regexMode: Bool = false;
		// `--writer-equals [--writer-equals-plain] [--expected <path>]`:
		// chain a writer round-trip + byte-equality check onto a probe-mode
		// PARSE OK. Closes the "predicted +1 via predict-strip, got skip→fail
		// because the writer round-trip diverges" gap that bit Slice 50 —
		// running predict-strip alone tells you ONLY about parse, not byte-
		// PASS. The combo flag is probe-only (single-file) because the
		// expected comparison needs a paired source/expected (sections 2/3
		// of an `.hxtest`, or `--expected <path>` for plain `.hx`). Sweep
		// mode already has the corpus harness doing this comparison.
		var writerEqualsAfter: Bool = false;
		var writerEqualsPlain: Bool = false;
		var expectedPath: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--top':
					final v: Null<Int> = Std.parseInt(expectValue(args, ++i, '--top'));
					if (v == null || v <= 0) {
						stderr('apq recon: --top requires a positive integer\n');
						return reconParseExit(EXIT_USAGE);
					}
					topN = v;
				case '--all':
					topN = MAX_INT;
				case '--probe':
					probePath = expectValue(args, ++i, '--probe');
				case '--cluster':
					clusterFilter = expectValue(args, ++i, '--cluster');
				case '--no-target-cluster':
					noTargetClusterFilter = expectValue(args, ++i, '--no-target-cluster');
				case '--source':
					showSource = true;
				case '--predict-strip':
					predictStrip = true;
				case '--predict-relax':
					predictRelax = true;
				case '--regression-probe':
					regressionProbe = true;
				case '--permissive-construct':
					permissiveConstruct = true;
				case '--candidates':
					candidatesRegex = expectValue(args, ++i, '--candidates');
				case '--replace':
					if (pendingReplace != null) {
						stderr('apq recon: --replace "$pendingReplace" needs a --with before the next --replace\n');
						return reconParseExit(EXIT_USAGE);
					}
					pendingReplace = expectValue(args, ++i, '--replace');
				case '--with':
					if (pendingReplace == null) {
						stderr('apq recon: --with requires a preceding --replace\n');
						return reconParseExit(EXIT_USAGE);
					}
					patterns.push(pendingReplace);
					replacements.push(expectValue(args, ++i, '--with'));
					pendingReplace = null;
				case '--delete':
					if (pendingReplace != null) {
						stderr('apq recon: --replace "$pendingReplace" needs a --with before --delete\n');
						return reconParseExit(EXIT_USAGE);
					}
					patterns.push(expectValue(args, ++i, '--delete'));
					replacements.push('');
				case '--regex':
					regexMode = true;
				case '--writer-equals':
					writerEqualsAfter = true;
				case '--writer-equals-plain':
					writerEqualsAfter = true;
					writerEqualsPlain = true;
				case '--expected':
					expectedPath = expectValue(args, ++i, '--expected');
				case '-h', '--help':
					printReconUsage();
					return reconParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq recon: unknown option "$a"\n');
						return reconParseExit(EXIT_USAGE);
					}
					if (rootDir != null) {
						stderr('apq recon: only one positional <dir> argument supported (got "$rootDir" and "$a")\n');
						return reconParseExit(EXIT_USAGE);
					}
					rootDir = a;
			}
			i++;
		}
		final o: ReconOpts = {
			lang: lang,
			topN: topN,
			probePath: probePath,
			rootDir: rootDir,
			clusterFilter: clusterFilter,
			predictStrip: predictStrip,
			regressionProbe: regressionProbe,
			candidatesRegex: candidatesRegex,
			predictRelax: predictRelax,
			permissiveConstruct: permissiveConstruct,
			showSource: showSource,
			noTargetClusterFilter: noTargetClusterFilter,
			patterns: patterns,
			replacements: replacements,
			regexMode: regexMode,
			compiledRegex: null,
			writerEqualsAfter: writerEqualsAfter,
			writerEqualsPlain: writerEqualsPlain,
			expectedPath: expectedPath,
			errExit: null
		};
		final sa: Null<Int> = validateReconStripArgs(o, pendingReplace);
		if (sa != null) return reconParseExit(sa);
		final mA: Null<Int> = validateReconModesA(o);
		if (mA != null) return reconParseExit(mA);
		final mB: Null<Int> = validateReconModesB(o);
		if (mB != null) return reconParseExit(mB);
		final we: Null<Int> = validateReconWriterEquals(o);
		return we != null ? reconParseExit(we) : o;
	}

	/**
	 * Post-loop validation of the `--replace`/`--with`/`--delete`/`--regex`
	 * predict-strip argument group, plus regex compilation. Mutates `o`
	 * with the compiled regex array on success. Returns a non-null exit
	 * code (EXIT_USAGE) on the first violation; null when the group passes.
	 */
	private static function validateReconStripArgs(o: ReconOpts, pendingReplace: Null<String>): Null<Int> {
		if (pendingReplace != null) {
			stderr('apq recon: --replace "$pendingReplace" needs a --with\n');
			return EXIT_USAGE;
		}
		if (o.predictStrip && o.patterns.length == 0) {
			stderr('apq recon: --predict-strip requires at least one --replace/--with or --delete\n');
			return EXIT_USAGE;
		}
		if (!o.predictStrip && o.patterns.length > 0) {
			stderr('apq recon: --replace/--with/--delete require --predict-strip\n');
			return EXIT_USAGE;
		}
		if (o.regexMode && !o.predictStrip) {
			stderr('apq recon: --regex requires --predict-strip (regex applies to --replace patterns)\n');
			return EXIT_USAGE;
		}
		final compiled: Null<Array<EReg>> = o.regexMode ? compileStripRegexes('recon', o.patterns) : null;
		if (o.regexMode && compiled == null) return EXIT_USAGE;
		o.compiledRegex = compiled;
		return null;
	}

	/** Terminal-case AstOpts: a flag/usage path that the caller returns immediately, ignoring every other field. */
	private static inline function astParseExit(code: Int): AstOpts {
		return {
			lang: '',
			json: false,
			depth: -1,
			selectExpr: null,
			atExpr: null,
			wantDoc: false,
			wantSource: false,
			writerOutput: false,
			writerOutputPlain: false,
			writerDiff: false,
			minChildren: -1,
			maxChildren: -1,
			childrenLimit: -1,
			spans: false,
			countOnly: false,
			file: null,
			codeArg: null,
			stdinFlag: false,
			errExit: code
		};
	}

	/**
	 * Report the `apq ast` "two positional arguments" usage error. Detects
	 * the `apq ast <TypeName> <dir>` miss — `ast` is single-file, while
	 * `<TypeName> <dir>` is the refs/uses/meta surface — and routes the user
	 * to the right multi-file walker; otherwise prints the plain message.
	 */
	private static function reportAstTwoFilesError(file: String, a: String): Void {
		// `apq ast <TypeName> <dir>` is a common miss — `ast` is single-
		// file, while `<TypeName> <dir>` is the refs/uses/meta surface.
		// Detect the shape (first arg looks like a TypeName, second arg
		// is an existing directory or .hx file) and route the user.
		final maybeTypeArg: String = file;
		final maybeDirArg: String = a;
		if (looksLikeTypeName(maybeTypeArg) && looksLikePath(maybeDirArg))
			stderr(
				'apq ast: only one file argument supported (got "$maybeTypeArg" and "$maybeDirArg").\n'
				+ '         "$maybeTypeArg" looks like a TypeName and "$maybeDirArg" like a path — `ast` is single-file.\n'
				+ '         For type lookup across a directory:\n'
				+ '           apq refs $maybeTypeArg $maybeDirArg --decls    # value bindings + decl site\n'
				+ '           apq uses $maybeTypeArg $maybeDirArg            # type-position consumers\n'
				+ '           apq blast $maybeTypeArg $maybeDirArg           # full change-impact (uses + refs + field-access)\n'
				+ '           apq meta @:peg $maybeDirArg                    # all PEG decls in scope\n'
				+ '         For a subtree of one file:\n' + '           apq ast <path-to-file.hx> --select Kind:$maybeTypeArg\n'
			);
		else
			stderr('apq ast: only one file argument supported (got "$file" and "$a")\n');
	}

	/**
	 * Parse `ast` argv into an AstOpts. A terminal case (`-h`/`--help` or any
	 * usage error) prints its message and returns with `errExit` set; the
	 * caller returns that code immediately. The natural end returns the full
	 * struct with `errExit: null`. The source-provider mutex and source
	 * resolution stay in the caller (they depend on FS/stdin I/O).
	 */
	private static function parseAstArgs(args: Array<String>): AstOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var depth: Int = -1;
		var selectExpr: Null<String> = null;
		var atExpr: Null<String> = null;
		var wantDoc: Bool = false;
		var wantSource: Bool = false;
		var writerOutput: Bool = false;
		var writerOutputPlain: Bool = false;
		var writerDiff: Bool = false;
		var minChildren: Int = -1;
		var maxChildren: Int = -1;
		var childrenLimit: Int = -1;
		var spans: Bool = false;
		var countOnly: Bool = false;
		var file: Null<String> = null;
		// Inline source (`apq probe '<code>'` -> `--code <s>`) or stdin
		// (`apq ast --stdin`) bypass the file read for micro-probes
		// without a /tmp scratch file. Mutually exclusive with each
		// other and with a file argument; checked after arg parsing.
		var codeArg: Null<String> = null;
		var stdinFlag: Bool = false;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--depth':
					// Depth is counted from the DISPLAYED ROOT, not from the
					// module: with `--select` / `--at`, the root is the
					// matched node (or each matched node, when --select
					// returns several); without either, the root is the
					// full module. So `--depth 0` always means "print just
					// the root, no children" regardless of mode. The three
					// `Engine.truncate` callsites below pass the right
					// subtree-root in each branch.
					final v: String = expectValue(args, ++i, '--depth');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null) {
						stderr('apq ast: --depth expects an integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					depth = parsed;
				case '--select':
					selectExpr = expectValue(args, ++i, '--select');
				case '--at':
					atExpr = expectValue(args, ++i, '--at');
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--writer-output':
					writerOutput = true;
				case '--writer-output-plain':
					writerOutput = true;
					writerOutputPlain = true;
				case '--diff':
					writerDiff = true;
				case '--min-children':
					final v: String = expectValue(args, ++i, '--min-children');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --min-children expects a non-negative integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					minChildren = parsed;
				case '--max-children':
					final v: String = expectValue(args, ++i, '--max-children');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --max-children expects a non-negative integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					maxChildren = parsed;
				case '--children-limit':
					// Cap direct-child count per node in the rendered output
					// (different beast from --max-children: that one FILTERS
					// matches by arity, this one TRUNCATES the printed tree
					// horizontally with an `(... N more)` sentinel). Composes
					// with --depth N for "first N children up to depth M".
					final v: String = expectValue(args, ++i, '--children-limit');
					final parsed: Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --children-limit expects a non-negative integer, got "$v"\n');
						return astParseExit(EXIT_USAGE);
					}
					childrenLimit = parsed;
				case '--code':
					codeArg = expectValue(args, ++i, '--code');
				case '--stdin':
					stdinFlag = true;
				case '--spans':
					// Append `@from-to` byte-range annotation to every
					// rendered node — same-span duplicates (e.g. parser bug
					// emitting two nodes at the same source position) become
					// a trivial visual signal in the S-expr output. Slice 36's
					// `^A|B` regex bug produced `(Ternary (FloatLit 1. @4-6)
					// (FloatLit 1. @4-6) (FloatLit 2. @11-13))` — two
					// FloatLits at the same span ⇒ mid-buffer match
					// overwrote an earlier ident. Plain `(no-spans)` form
					// stays default to keep transcripts compact.
					spans = true;
				case '--count':
					// ω-ast-count: print just the integer direct-child count
					// at the displayed root (the module by default; each
					// matched node when paired with `--select`). Composes
					// with `--select` — one line per match. Skips writer-
					// output / json / spans / doc / source rendering; only
					// the count is emitted. Replaces hand-counting members
					// when sanity-checking a corpus-driver test assertion.
					countOnly = true;
				case '-h', '--help':
					printAstUsage();
					return astParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq ast: unknown option "$a"\n');
						return astParseExit(EXIT_USAGE);
					}
					if (file != null) {
						reportAstTwoFilesError(file, a);
						return astParseExit(EXIT_USAGE);
					}
					file = a;
			}
			i++;
		}

		return {
			lang: lang,
			json: json,
			depth: depth,
			selectExpr: selectExpr,
			atExpr: atExpr,
			wantDoc: wantDoc,
			wantSource: wantSource,
			writerOutput: writerOutput,
			writerOutputPlain: writerOutputPlain,
			writerDiff: writerDiff,
			minChildren: minChildren,
			maxChildren: maxChildren,
			childrenLimit: childrenLimit,
			spans: spans,
			countOnly: countOnly,
			file: file,
			codeArg: codeArg,
			stdinFlag: stdinFlag,
			errExit: null
		};
	}

	/**
	 * `--writer-output`: parse + format-write through the plugin's round-trip
	 * pipeline, then either print the emitted source or (with `--diff`)
	 * structurally AST-diff the parsed input against the re-parsed output.
	 * Independent of --select / --at / --json / --depth / --doc / --source.
	 * Returns the process exit code.
	 */
	private static function runAstWriterOutput(
		plugin: GrammarPlugin, source: String, file: Null<String>, fileLabel: String, lang: String, writerOutputPlain: Bool,
		writerDiff: Bool
	): Int {
		// `.hxtest` section-1 (writer config JSON) auto-applies for
		// the file-path mode — drives `HxModuleWriteOptions` via
		// `HaxeFormatConfigLoader` so a fixture reproduces the corpus
		// harness's writer settings in a single command. `--code` /
		// `--stdin` modes have no path → defaults stay.
		final optsJson: Null<String> = file != null ? readWriteOptionsJsonOrNull((file: String)) : null;
		final emitted: Null<String> = try (writerOutputPlain
			? plugin.writeRoundTripPlain(source, optsJson)
			: plugin.writeRoundTrip(source, optsJson)) catch (e: ParseError) {
			stderr('apq ast: $fileLabel: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			stderr('apq ast: $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		if (emitted == null) {
			final flagName: String = writerOutputPlain ? '--writer-output-plain' : '--writer-output';
			stderr('apq ast: $flagName: no writer wired up for lang "$lang"\n');
			return EXIT_USAGE;
		}
		if (!writerDiff) {
			sysPrint(emitted);
			return EXIT_OK;
		}
		final emittedSrc: String = emitted;
		final treeIn: QueryNode = try plugin.parseFile(source) catch (e: ParseError) {
			stderr('apq ast: --writer-output --diff: input $fileLabel: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			stderr('apq ast: --writer-output --diff: input $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final treeOut: QueryNode = try plugin.parseFile(emittedSrc) catch (e: ParseError) {
			stderr('apq ast: --writer-output --diff: writer output failed to re-parse: ${e.toString()}\n');
			stderr('--- writer output ---\n$emittedSrc\n--- end ---\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			stderr('apq ast: --writer-output --diff: writer output failed to re-parse: ${e.message}\n');
			stderr('--- writer output ---\n$emittedSrc\n--- end ---\n');
			return EXIT_RUNTIME;
		}
		final hits: Array<DiffHit> = Diff.diff(treeIn, treeOut);
		sysPrint(Diff.render(fileLabel, source, '<writer-output>', emittedSrc, hits, false));
		return EXIT_OK;
	}

	/**
	 * `--at LINE:COL`: locate the innermost spanned node at the cursor and
	 * render it (or, with `--count`, print its direct-child count). Returns
	 * the process exit code.
	 */
	private static function runAstAt(o: AstOpts, atExpr: String, tree: QueryNode, source: String, fileLabel: String): Int {
		final colonIdx: Int = atExpr.indexOf(':');
		if (colonIdx < 0) {
			stderr('apq ast: --at expects LINE:COL, got "$atExpr"\n');
			return EXIT_USAGE;
		}
		final atLine: Null<Int> = Std.parseInt(atExpr.substring(0, colonIdx));
		final atCol: Null<Int> = Std.parseInt(atExpr.substring(colonIdx + 1));
		if (atLine == null || atCol == null) {
			stderr('apq ast: --at expects integer LINE:COL, got "$atExpr"\n');
			return EXIT_USAGE;
		}
		// Capture into non-null locals immediately after the null
		// check — Strict narrows locals, not the Null<Int> bindings,
		// and `Span.offsetOf` takes plain Int.
		final atLineN: Int = atLine;
		final atColN: Int = atCol;
		if (atLineN < 1 || atColN < 1) {
			stderr('apq ast: --at expects 1-indexed LINE:COL, got "$atExpr"\n');
			return EXIT_USAGE;
		}
		final offset: Int = Span.offsetOf(source, atLineN, atColN);
		final node: Null<QueryNode> = Engine.at(tree, offset);
		if (o.countOnly) {
			if (node != null) sysPrint('${node.children.length}\n');
			return EXIT_OK;
		}
		final matches: Array<QueryNode> = node == null ? [] : [shapeAstOutput(node, o.depth, o.childrenLimit)];
		sysPrint(
			o.json
				? Json.renderMatches(fileLabel, source, matches, o.wantDoc, o.wantSource)
				: Text.renderMatches(matches, source, o.wantDoc, o.wantSource, o.spans)
		);
		return EXIT_OK;
	}

	/**
	 * `--select` matched nothing: emit a self-correcting hint listing the
	 * kinds actually present, a fuzzy "did you mean", and (for a TypeName-
	 * shaped first kind) a cross-project pointer to the multi-file walkers.
	 */
	private static function reportAstSelectEmpty(
		tree: QueryNode, selectExpr: String, fileLabel: String, minChildren: Int, maxChildren: Int, preFilterLen: Int
	): Void {
		// Empty `--select` is indistinguishable from "wrong kind
		// name". Kinds are the exact node-constructor names and the
		// engine never enumerates them — so list the kinds actually
		// present in this file, turning a silent miss into a
		// self-correcting hint (no global kind table needed).
		final present: Array<String> = collectKinds(tree);
		final filterParts: Array<String> = [];
		if (minChildren >= 0) filterParts.push('--min-children=$minChildren');
		if (maxChildren >= 0) filterParts.push('--max-children=$maxChildren');
		if (preFilterLen > 0) filterParts.push('$preFilterLen pre-filter match(es) dropped by child-count');
		final filterNote: String = filterParts.length == 0 ? '' : ' (with ${filterParts.join(', ')})';
		// Kind-fuzzy "did you mean" — surface the closest match in
		// `present` for the first kind segment of `selectExpr`
		// (split on `>`, `:`, whitespace). Same `findFuzzy`
		// substring+Levenshtein two-tier shape as refs/uses on a
		// 0-hit name, so a typo like `--select ParamCtorr` →
		// `Did you mean: ParamCtor?` without re-reading the long
		// `Kinds present here:` list. Silent when nothing close.
		final firstKind: String = extractFirstKindToken(selectExpr);
		final presentMap: Map<String, Bool> = [for (k in present) k => true];
		final suggestions: Array<String> = firstKind.length > 0 ? findFuzzy(firstKind, presentMap) : [];
		final fuzzyLine: String = suggestions.length > 0 ? ' Did you mean: ${suggestions.join(', ')}?' : '';
		// Cross-project hint: when the first kind token starts uppercase
		// (TypeName-shaped — e.g. `HxCatchClause`, `HxModule`), the user
		// is likely hunting a decl that lives in OTHER files. `ast` is
		// single-file by design; point them at the multi-file walkers
		// (`refs --decls` / `uses` / `blast`) that DO recurse a dir.
		// Silent when the token is lowercase (field-shaped) or empty.
		final crossProjectHint: String = firstKind.length > 0 && StringTools.fastCodeAt(firstKind, 0) >= 'A'.code
			&& StringTools.fastCodeAt(firstKind, 0) <= 'Z'.code
			? ' If "$firstKind" is a TypeName declared elsewhere, ast is single-file; try apq refs $firstKind src/ --decls (declaration sites), apq uses $firstKind src/ (type positions), or apq blast $firstKind src/ (full change-impact).'
			: '';
		stderr(
			'apq ast: --select "$selectExpr"$filterNote matched no nodes in $fileLabel. '
			+ 'Kinds present here: ${present.join(', ')}.$fuzzyLine$crossProjectHint '
			+ 'Kinds are exact node-constructor names — run `apq ast $fileLabel` to see the tree.\n'
		);
	}

	/**
	 * `--select <sel>`: resolve the selector against the tree (kind-equivalence
	 * aware), apply the optional child-count arity filter, then render the
	 * matches (or print each match's child count with `--count`). Returns the
	 * process exit code.
	 */
	private static function runAstSelect(
		o: AstOpts, selectExpr: String, tree: QueryNode, source: String, fileLabel: String, plugin: GrammarPlugin
	): Int {
		final selector: Selector = Selector.parse(selectExpr);
		// Pass the grammar's kind-equivalence so `--select ClassDecl` /
		// `--select FnMember` also match `final class` / `final function`
		// (the `final`-wrapper shapes ClassForm / FinalModifiedMember).
		final preFilter: Array<QueryNode> = Engine.select(tree, selector, plugin.selectKindEquivalence());
		// ω-ast-child-count-filter: post-filter on direct-child count so
		// "find all multi-arg ParamCtor ctors" is one query. The selector
		// grammar (`Kind` / `Kind:name` / `Kind > Child`) is deliberately
		// minimal and stays that way — arity is a numeric predicate, not
		// a structural one, and lives on the CLI instead of the path.
		final raw: Array<QueryNode> = (o.minChildren < 0 && o.maxChildren < 0)
			? preFilter
			: [
				for (m in preFilter)
					if ((o.minChildren < 0 || m.children.length >= o.minChildren)
						&& (o.maxChildren < 0 || m.children.length <= o.maxChildren)) m
			];
		if (raw.length == 0) reportAstSelectEmpty(tree, selectExpr, fileLabel, o.minChildren, o.maxChildren, preFilter.length);
		if (o.countOnly) {
			for (m in raw) sysPrint('${m.children.length}\n');
			return EXIT_OK;
		}
		final matches: Array<QueryNode> = [for (m in raw) shapeAstOutput(m, o.depth, o.childrenLimit)];
		sysPrint(
			o.json
				? Json.renderMatches(fileLabel, source, matches, o.wantDoc, o.wantSource)
				: Text.renderMatches(matches, source, o.wantDoc, o.wantSource, o.spans)
		);
		return EXIT_OK;
	}

	private static inline function metaParseExit(code: Int): MetaOpts {
		return {
			lang: '',
			json: false,
			argContains: null,
			onKind: null,
			flat: false,
			limit: -1,
			positionals: [],
			errExit: code
		};
	}

	private static function parseMetaArgs(args: Array<String>): MetaOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var argContains: Null<String> = null;
		var onKind: Null<String> = null;
		var flat: Bool = false;
		var limit: Int = -1;
		final positionals: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--arg-contains':
					argContains = expectValue(args, ++i, '--arg-contains');
				case '--on':
					onKind = expectValue(args, ++i, '--on');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return metaParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printMetaUsage();
					return metaParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq meta: unknown option "$a"\n');
						return metaParseExit(EXIT_USAGE);
					}
					positionals.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			json: json,
			argContains: argContains,
			onKind: onKind,
			flat: flat,
			limit: limit,
			positionals: positionals,
			errExit: null
		};
	}

	private static function collectMetaEntries(
		paths: Array<String>, plugin: GrammarPlugin, shape: MetaShape, singleFile: Bool, skipEntries: Array<SkipEntry>, filter: {
			annotation: Null<String>,
			argContains: Null<String>,
			argFilter: Null<String>,
			onKind: Null<String>
		}
	): Null<Array<{ file: String, source: String, hits: Array<MetaHit> }>> {
		final allEntries: Array<{ file: String, source: String, hits: Array<MetaHit> }> = [];
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('meta', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				// In single-file mode a parse failure is fatal; signal the
				// caller (null) to return EXIT_RUNTIME. In multi-file mode the
				// file is recorded in skipEntries and the walk continues.
				if (singleFile) return null;
				continue;
			}
			final raw: Array<MetaHit> = Meta.find(tree, shape, source);
			final filtered: Array<MetaHit> = raw.filter(
				h -> (filter.annotation == null || h.annotation == filter.annotation) && argMatches(h.args, filter.argContains)
				&& argFilterMatches(h.args, filter.argFilter) && (filter.onKind == null || h.declKind == filter.onKind)
			);
			if (filtered.length == 0) continue;
			allEntries.push({ file: path, source: source, hits: filtered });
		}
		return allEntries;
	}

	private static inline function blastParseExit(code: Int): BlastOpts {
		return {
			lang: '',
			flat: false,
			limit: -1,
			showAll: false,
			name: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function parseBlastArgs(args: Array<String>): BlastOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var showAll: Bool = false;
		var name: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return blastParseExit(EXIT_USAGE);
					}
				case '--all':
					showAll = true;
				case '-h', '--help':
					printBlastUsage();
					return blastParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq blast: unknown option "$a"\n');
						return blastParseExit(EXIT_USAGE);
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
			flat: flat,
			limit: limit,
			showAll: showAll,
			name: name,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function blastUsesSection(
		valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, typeName: String, typeShape: TypeRefShape,
		plugin: GrammarPlugin, singleFile: Bool, flat: Bool
	): Bool {
		var any: Bool = false;
		var usesHeader: Bool = false;
		for (entry in valueTrees) {
			final typeTree: Null<QueryNode> = parseWalked(
				'blast', plugin.parseFileTypeRefs, entry.path, entry.source, singleFile, null, typeName
			);
			if (typeTree == null) continue;
			final hits: Array<UsesHit> = Uses.find(typeName, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!usesHeader) {
				sysPrint('# uses (type positions)\n');
				usesHeader = true;
			}
			sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false, flat));
		}
		return any;
	}

	private static function blastRefsSection(
		valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, typeName: String, refShape: RefShape, flat: Bool
	): Bool {
		var any: Bool = false;
		var refsHeader: Bool = false;
		for (entry in valueTrees) {
			final hits: Array<RefHit> = Refs.find(typeName, entry.tree, refShape);
			if (hits.length == 0) continue;
			any = true;
			if (!refsHeader) {
				sysPrint('# refs (value bindings)\n');
				refsHeader = true;
			}
			sysPrint(Text.renderRefs(entry.path, entry.source, hits, false, false, flat));
		}
		return any;
	}

	private static function blastHeuristicSection(
		valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, memberNames: Array<String>, declSpans: Array<Span>,
		typeName: String, showAll: Bool, limit: Int
	): Bool {
		final heur: Array<{ loc: String, line: String }> = [];
		for (entry in valueTrees) collectMemberAccess(entry.tree, memberNames, declSpans, entry.path, entry.source, heur);
		if (heur.length == 0) return false;
		// Smart-default cap on the heuristic section — the typical
		// transcript pain is `blast` flooding hundreds of `.member`
		// lines when the type's member names are common identifiers
		// (`.name`, `.type`, `.value`). Without `--limit` the
		// heuristic caps at HEUR_DEFAULT_CAP and prints a hint
		// pointing at `--all` (no cap) or `--limit N` (explicit).
		// Precise `uses` / `refs` sections stay uncapped — they
		// are name-bound and rarely flood.
		final defaultCap: Int = showAll ? -1 : HEUR_DEFAULT_CAP;
		final effectiveLimit: Int = limit >= 0 ? limit : defaultCap;
		final capped: Array<{ loc: String, line: String }> = (effectiveLimit >= 0 && heur.length > effectiveLimit)
			? heur.slice(0, effectiveLimit)
			: heur;
		final hint: String = (
			capped.length < heur.length
		) ? (limit >= 0 ? '' : ' — pass --all to show all, --limit N for explicit cap') : '';
		sysPrint(
			'# heuristic field-access (member-name superset of "$typeName" — VERIFY each; '
			+ 'name-based, over-matches; ${capped.length}/${heur.length} shown$hint)\n'
		);
		for (h in capped) sysPrint('${h.line}\n');
		return true;
	}

	private static inline function litParseExit(code: Int): LitOpts {
		return {
			lang: '',
			exact: false,
			flat: false,
			limit: -1,
			kindFilter: null,
			includeComments: false,
			target: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function parseLitArgs(args: Array<String>): LitOpts {
		var lang: String = 'haxe';
		var exact: Bool = false;
		var flat: Bool = false;
		var limit: Int = -1;
		var kindFilter: Null<Array<String>> = null;
		var includeComments: Bool = false;
		var target: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--exact':
					exact = true;
				case '--kind':
					kindFilter = expectValue(args, ++i, '--kind').split(',');
				case '--any-kind':
					kindFilter = [];
				case '--include-comments':
					includeComments = true;
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e: Exception) {
						stderr('${e.message}\n');
						return litParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printLitUsage();
					return litParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq lit: unknown option "$a"\n');
						return litParseExit(EXIT_USAGE);
					}
					if (target == null)
						target = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			exact: exact,
			flat: flat,
			limit: limit,
			kindFilter: kindFilter,
			includeComments: includeComments,
			target: target,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectLitEntries(
		paths: Array<String>, plugin: GrammarPlugin, singleFile: Bool, skipEntries: Array<SkipEntry>, query: {
			target: String,
			exact: Bool,
			kinds: Array<String>,
			kindWasDefault: Bool,
			scanComments: Bool,
			prefilterKey: Null<String>
		}
	): Null<{ entries: Array<{ file: String, source: String, hits: Array<LitHit> }>, autoWidened: Bool }> {
		final allEntries: Array<{ file: String, source: String, hits: Array<LitHit> }> = [];
		// Cache parsed trees so the auto-widen retry path doesn't reparse.
		final trees: Array<{ path: String, source: String, tree: QueryNode }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('lit', plugin.parseFile, path, source, singleFile, skipEntries, query.prefilterKey);
			streamProgress('lit', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return null;
				continue;
			}
			trees.push({ path: path, source: source, tree: tree });
			final hits: Array<LitHit> = Lit.find(query.target, tree, query.exact, query.kinds);
			if (query.scanComments) appendCommentHits(query.target, source, query.exact, hits);
			if (hits.length == 0) continue;
			// AST walk emits in depth-first source order; comment hits are
			// appended after. Sort by span.from so the rendered file group
			// stays in source order regardless of which pass produced the hit.
			if (query.scanComments) hits.sort((a, b) -> a.span.from - b.span.from);
			allEntries.push({ file: path, source: source, hits: hits });
		}

		// Auto-widen on 0-hit when kind was the smart-default (user didn't
		// pass --kind / --any-kind). Retry with --any-kind; if THAT finds
		// hits, flag autoWidened so the caller emits a note. Common case:
		// CamelCase TypeName queries that live as `ImportDecl` / `NewExpr`
		// only — default kind set misses both. Silent on real 0-hits.
		var autoWidened: Bool = false;
		if (allEntries.length == 0 && query.kindWasDefault) {
			for (entry in trees) {
				final hits: Array<LitHit> = Lit.find(query.target, entry.tree, query.exact, []);
				if (hits.length == 0) continue;
				allEntries.push({ file: entry.path, source: entry.source, hits: hits });
			}
			if (allEntries.length > 0) autoWidened = true;
		}
		return { entries: allEntries, autoWidened: autoWidened };
	}

	private static inline function newParseExit(code: Int): NewOpts {
		return {
			lang: '',
			write: false,
			asClass: false,
			open: false,
			raw: false,
			kind: 'class',
			iface: null,
			underlying: null,
			bodiesArg: null,
			bodiesFromFile: null,
			extendsList: [],
			fromList: [],
			toList: [],
			fields: [],
			path: null,
			errExit: code
		};
	}

	private static function parseNewArgs(args: Array<String>): NewOpts {
		var lang: String = 'haxe';
		var write: Bool = false;
		var asClass: Bool = false;
		var open: Bool = false;
		var raw: Bool = false;
		var kind: String = 'class';
		var iface: Null<String> = null;
		var underlying: Null<String> = null;
		var bodiesArg: Null<String> = null;
		var bodiesFromFile: Null<String> = null;
		final extendsList: Array<String> = [];
		final fromList: Array<String> = [];
		final toList: Array<String> = [];
		final fields: Array<String> = [];
		var path: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--class':
					asClass = true;
				case '--kind':
					kind = expectValue(args, ++i, '--kind');
				case '--extends':
					extendsList.push(expectValue(args, ++i, '--extends'));
				case '--underlying':
					underlying = expectValue(args, ++i, '--underlying');
				case '--from':
					fromList.push(expectValue(args, ++i, '--from'));
				case '--to':
					toList.push(expectValue(args, ++i, '--to'));
				case '--open':
					open = true;
				case '--raw':
					raw = true;
					if (i + 1 < args.length && args[i + 1] == '-')
						i++;

				case '--implements':
					iface = expectValue(args, ++i, '--implements');
				case '--field':
					fields.push(expectValue(args, ++i, '--field'));
				case '--bodies':
					bodiesArg = expectValue(args, ++i, '--bodies');
				case '--from-file':
					bodiesFromFile = expectValue(args, ++i, '--from-file');
				case '--write':
					write = true;
				case '-h', '--help':
					printNewUsage();
					return newParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq new: unknown option "$a"\n');
						return newParseExit(EXIT_USAGE);
					}
					if (path == null)
						path = a;
					else {
						stderr('apq new: unexpected extra argument "$a"\n');
						return newParseExit(EXIT_USAGE);
					}
			}
			i++;
		}
		return {
			lang: lang,
			write: write,
			asClass: asClass,
			open: open,
			raw: raw,
			kind: kind,
			iface: iface,
			underlying: underlying,
			bodiesArg: bodiesArg,
			bodiesFromFile: bodiesFromFile,
			extendsList: extendsList,
			fromList: fromList,
			toList: toList,
			fields: fields,
			path: path,
			errExit: null
		};
	}

	private static function executeNew(o: NewOpts, filePath: String, plugin: GrammarPlugin, optsJson: Null<String>): Int {
		if (o.raw) {
			final content: Null<String> = resolveCodeArg('new', '-', null);
			return content == null ? EXIT_RUNTIME : emitNew(filePath, NewFile.createRaw(content, plugin, optsJson), [], o.write);
		}

		var bodiesRaw: Null<String> = null;
		if (o.bodiesArg == '-' || o.bodiesFromFile != null) {
			final resolved: Null<String> = resolveCodeArg('new', o.bodiesArg == '-' ? '-' : null, o.bodiesFromFile);
			if (resolved == null) return EXIT_RUNTIME;
			bodiesRaw = resolved;
		} else if (o.bodiesArg != null) bodiesRaw = o.bodiesArg;

		final className: String = newFileClassName(filePath);
		final pkg: String = derivePackage(filePath);

		var ifaceSimple: Null<String> = null;
		var ifaceModule: Null<String> = null;
		var ifaceSource: Null<String> = null;
		final iface: Null<String> = o.iface;
		if (iface != null) {
			final resolved: Null<{ source: String, ifaceModule: String, simple: String }> = resolveInterface(iface, filePath);
			if (resolved == null) {
				stderr('apq new: could not locate interface "$iface" (expected a .hx beside the new file or at its package path)\n');
				return EXIT_RUNTIME;
			}
			ifaceSimple = resolved.simple;
			ifaceModule = resolved.ifaceModule;
			ifaceSource = resolved.source;
		}

		final spec: NewFileSpec = {
			className: className,
			pkg: pkg,
			fields: o.fields,
			kind: o.kind,
			isFinal: !o.open,
			extendsList: o.extendsList,
			underlying: o.underlying,
			fromList: o.fromList,
			toList: o.toList,
			ifaceSimple: ifaceSimple,
			ifaceModule: ifaceModule,
			ifaceSource: ifaceSource,
			bodiesRaw: bodiesRaw,
		};
		final res: NewFileResult = NewFile.create(spec, plugin, optsJson);
		return emitNew(filePath, res.result, res.stubbed, o.write);
	}

	private static inline function searchParseExit(code: Int): SearchOpts {
		return {
			lang: '',
			json: false,
			kind: null,
			limit: -1,
			explain: false,
			flat: false,
			pattern: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function parseSearchArgs(args: Array<String>): SearchOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var kind: Null<String> = null;
		var limit: Int = -1;
		var explain: Bool = false;
		var flat: Bool = false;
		var pattern: Null<String> = null;
		final inputSpecs: Array<String> = [];

		// `--` is the standard end-of-options sentinel: every token after
		// it is positional, never an option. A search pattern can legally
		// start with `--` (`--$x` = prefix-decrement), which would
		// otherwise be rejected as an unknown option — the sentinel is the
		// only way to reach those patterns.
		var optsEnded: Bool = false;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			var isOption: Bool = false;
			if (!optsEnded) {
				isOption = true;
				switch a {
					case '--lang':
						lang = expectValue(args, ++i, '--lang');
					case '--json':
						json = true;
					case '--kind':
						kind = expectValue(args, ++i, '--kind');
					case '--explain':
						explain = true;
					case '--flat':
						flat = true;
					case '--limit':
						try limit = parseLimit(args, ++i) catch (e: Exception) {
							stderr('${e.message}\n');
							return searchParseExit(EXIT_USAGE);
						}
					case '-h', '--help':
						printSearchUsage();
						return searchParseExit(EXIT_OK);
					case '--':
						optsEnded = true;
					case _:
						if (StringTools.startsWith(a, '--')) {
							stderr('apq search: unknown option "$a"\n');
							return searchParseExit(EXIT_USAGE);
						}
						isOption = false;
				}
			}
			if (!isOption) {
				if (pattern == null)
					pattern = a;
				else
					inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			json: json,
			kind: kind,
			limit: limit,
			explain: explain,
			flat: flat,
			pattern: pattern,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectSearchEntries(
		paths: Array<String>, plugin: GrammarPlugin, singleFile: Bool, parsed: Pattern, kind: Null<String>, explain: Bool
	): Null<{ entries: Array<{ file: String, source: String, matches: Array<Match> }>, kindCounts: Map<String, Int> }> {
		final allEntries: Array<{ file: String, source: String, matches: Array<Match> }> = [];
		final kindCounts: Map<String, Int> = [];
		for (path in paths) {
			final source: String = readSourceForParse(path);
			final tree: Null<QueryNode> = parseWalked('search', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return null;
				continue;
			}
			if (explain) tallyKinds(tree, kindCounts);
			final matches: Array<Match> = Matcher.search(parsed, tree, kind);
			if (matches.length == 0) continue;
			allEntries.push({ file: path, source: source, matches: matches });
		}
		return { entries: allEntries, kindCounts: kindCounts };
	}

	private static function searchExplainHistogram(patternKind: String, kindCounts: Map<String, Int>): Void {
		final entries: Array<{ k: String, n: Int }> = [for (k => n in kindCounts) { k: k, n: n }];
		entries.sort((a, b) -> a.n == b.n ? (a.k < b.k ? -1 : 1) : b.n - a.n);
		final topN: Int = entries.length < 12 ? entries.length : 12;
		stderr('apq search: 0 matches; pattern root kind is "$patternKind". Top kinds seen in input (${entries.length} distinct):\n');
		for (k in 0...topN) {
			final e = entries[k];
			final marker: String = e.k == patternKind ? ' ← matches pattern root' : '';
			stderr('  ${e.k} (${e.n})$marker\n');
		}
		if (!Lambda.exists(entries, e -> e.k == patternKind))
			stderr(
				'  (pattern root kind "$patternKind" NOT present in any scanned file — likely the wrong kind for this construct; check `apq ast <file>` to see the actual node shape)\n'
			);
	}

	private static function renderSearchResults(
		shown: Array<{ file: String, source: String, matches: Array<Match> }>, json: Bool, flat: Bool
	): Void {
		if (json) {
			final combined: StringBuf = new StringBuf();
			combined.add('{"matches":[');
			var first: Bool = true;
			for (entry in shown) {
				for (m in entry.matches) {
					if (!first) combined.add(',');
					first = false;
					combined.add(perMatchJson(entry.file, entry.source, m));
				}
			}
			combined.add(']}\n');
			sysPrint(combined.toString());
		} else {
			for (entry in shown) sysPrint(Text.renderSearchMatches(entry.file, entry.source, entry.matches, flat));
		}
	}

	private static inline function lintParseExit(code: Int): LintOpts {
		return {
			lang: '',
			flat: false,
			includeInfo: false,
			fix: false,
			failOn: null,
			format: 'text',
			ruleFilters: [],
			inputSpecs: [],
			errExit: code
		};
	}

	private static function parseLintArgs(args: Array<String>): LintOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var includeInfo: Bool = false;
		var fix: Bool = false;
		var failOn: Null<Severity> = null;
		var format: String = 'text';
		final ruleFilters: Array<String> = [];
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--rule':
					ruleFilters.push(expectValue(args, ++i, '--rule'));
				case '--all', '-a':
					includeInfo = true;
				case '--flat':
					flat = true;
				case '--fix':
					fix = true;
				case '--fail-on':
					final level: String = expectValue(args, ++i, '--fail-on');
					failOn = Severity.fromName(level);
					if (failOn == null) {
						stderr('apq lint: unknown --fail-on value "$level" (expected error|warning|info)\n');
						return lintParseExit(EXIT_USAGE);
					}
				case '--format':
					format = expectValue(args, ++i, '--format');
					if (format != 'text' && format != 'json' && format != 'checkstyle') {
						stderr('apq lint: unknown --format value "$format" (expected text|json|checkstyle)\n');
						return lintParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printLintUsage();
					return lintParseExit(EXIT_OK);
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq lint: unknown option "$a"\n');
						return lintParseExit(EXIT_USAGE);
					}
					inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			flat: flat,
			includeInfo: includeInfo,
			fix: fix,
			failOn: failOn,
			format: format,
			ruleFilters: ruleFilters,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function resolveLintChecks(ruleFilters: Array<String>): Null<Array<Check>> {
		final checks: Array<Check> = [];
		if (ruleFilters.length == 0) {
			for (check in Linter.builtins()) checks.push(check);
		} else {
			for (id in ruleFilters) {
				final check: Null<Check> = Linter.byId(id);
				if (check == null) {
					stderr('apq lint: unknown rule "$id"\n');
					return null;
				}
				checks.push(check);
			}
		}
		return checks;
	}

	private static function renderLintReport(
		paths: Array<String>, shown: Array<Violation>, sourceOf: Map<String, String>, format: String, flat: Bool
	): Void {
		// Order findings by input-file order, each file sorted by source
		// position so the report reads top-to-bottom; shared by every format.
		final ordered: Array<Violation> = [];
		for (path in paths) {
			final group: Array<Violation> = shown.filter(v -> v.file == path);
			group.sort((a, b) -> spanStart(a.span) - spanStart(b.span));
			for (v in group) ordered.push(v);
		}

		switch format {
			case 'json':
				sysPrint(LintFormat.json(ordered, sourceOf));
			case 'checkstyle':
				sysPrint(LintFormat.checkstyle(ordered, sourceOf));
			case _:
				for (path in paths) {
					final group: Array<Violation> = ordered.filter(v -> v.file == path);
					if (group.length == 0) continue;
					sysPrint(Text.renderViolations(path, sourceOf[path] ?? '', group, flat));
				}
		}
	}

	private static function lintSummary(all: Array<Violation>, paths: Array<String>, includeInfo: Bool): Void {
		var errors: Int = 0;
		var warnings: Int = 0;
		var infos: Int = 0;
		for (v in all) switch v.severity {
			case Severity.Error:
				errors++;
			case Severity.Warning:
				warnings++;
			case Severity.Info:
				infos++;
		}
		if (all.length == 0) {
			stderr('apq lint: no issues in ${paths.length} file(s)\n');
		} else {
			stderr('apq lint: $errors error(s), $warnings warning(s), $infos info(s) in ${paths.length} file(s)\n');
			if (!includeInfo && infos > 0) stderr('apq lint: $infos info advisory(ies) hidden — pass --all to show\n');
		}
	}

	/**
	 * `--no-target-cluster`: drill into one bucket of the footer NO TARGET
	 * breakdown. We must classify every record through `tryPredictRelax`
	 * first (the bucket key lives on the result, not on the raw record),
	 * so the filter runs after classification. Top-N reasons collected
	 * alongside for the 0-match diagnostic.
	 */
	private static function runReconRelaxNoTargetCluster(
		plugin: GrammarPlugin, records: Array<ReconRecord>, filter: String, showSource: Bool
	): Int {
		final matched: Array<{ record: ReconRecord, result: PredictRelaxResult }> = [];
		final noTargetReasonsTop: Array<{ key: String, count: Int }> = [];
		for (r in records) {
			final res: PredictRelaxResult = tryPredictRelax(plugin, r.source);
			if (res.kind != NoTarget) continue;
			bumpReasonCount(noTargetReasonsTop, res.message);
			if (res.message == filter) matched.push({ record: r, result: res });
		}
		if (matched.length == 0) {
			stderr('apq recon: --no-target-cluster "$filter" matched no NO TARGET records (predict-relax mode)\n');
			if (noTargetReasonsTop.length > 0) {
				noTargetReasonsTop.sort((a, b) -> b.count - a.count);
				final maxKeys: Int = noTargetReasonsTop.length < NO_TARGET_TOP_N ? noTargetReasonsTop.length : NO_TARGET_TOP_N;
				stderr('  available NO TARGET keys (top $maxKeys):\n');
				for (entry in noTargetReasonsTop.slice(0, NO_TARGET_TOP_N)) stderr('    ${entry.count}× ${entry.key}\n');
			}
			return EXIT_RUNTIME;
		}
		for (m in matched) reportPredictRelax(m.record.path, m.record.source, m.result, showSource);
		sysPrint('--- relax (no-target-cluster "$filter"): ${matched.length} files ---\n');
		return EXIT_OK;
	}

	/**
	 * Full predict-relax sweep over the records: classify each via
	 * `tryPredictRelax`, report UNBLOCK / STILL FAIL per file, and either
	 * keep NO TARGET per-file (cluster scope) or collapse it into a footer
	 * histogram by `expected` message (full-sweep scope).
	 */
	private static function runReconRelaxFullSweep(
		plugin: GrammarPlugin, records: Array<ReconRecord>, keepNoTargetPerFile: Bool, showSource: Bool
	): Int {
		var unblockCount: Int = 0;
		var stillFailCount: Int = 0;
		var noTargetCount: Int = 0;
		final noTargetReasons: Array<{ key: String, count: Int }> = [];
		for (r in records) {
			final res: PredictRelaxResult = tryPredictRelax(plugin, r.source);
			switch res.kind {
				case Unblock:
					reportPredictRelax(r.path, r.source, res, showSource);
					unblockCount++;
				case StillFail:
					reportPredictRelax(r.path, r.source, res, showSource);
					stillFailCount++;
				case NoTarget:
					if (keepNoTargetPerFile)
						reportPredictRelax(r.path, r.source, res, showSource);
					else
						bumpReasonCount(noTargetReasons, res.message);
					noTargetCount++;
			}
		}
		sysPrint(
			'--- relax: $unblockCount unblock, $stillFailCount still fail, $noTargetCount no target (of ${records.length} skip-parse files) ---\n'
		);
		if (!keepNoTargetPerFile && noTargetReasons.length > 0) {
			noTargetReasons.sort((a, b) -> b.count - a.count);
			sysPrint(
				'   no target breakdown (use --no-target-cluster <key> to drill into a specific shape, or --cluster <locus-key> for forward-locus drill):\n'
			);
			for (entry in noTargetReasons) sysPrint('     ${entry.count}× ${entry.key}\n');
		}
		return EXIT_OK;
	}

	/**
	 * Walk the current corpus and diff each fixture's parse status against
	 * the prior snapshot, printing REGRESSED / UNBLOCKED flips. Reuses the
	 * recursive-stack walk of `collectReconSkipRecords` but keeps the OK
	 * list too (which that helper drops). `unwired` aborts the caller.
	 */
	private static function walkReconRegression(plugin: GrammarPlugin, root: String, prior: Map<String, String>): ReconRegressionResult {
		var regressed: Int = 0;
		var unblocked: Int = 0;
		var scanned: Int = 0;
		final stack: Array<String> = [root];
		while (stack.length > 0) {
			final dir: Null<String> = stack.pop();
			if (dir == null) break;
			final names: Array<String> = FileSystem.readDirectory(dir);
			names.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) {
				final path: String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!StringTools.endsWith(name, '.hxtest')) continue;
				final relPath: String = stripRootPrefix(path, root);
				final priorStatus: Null<String> = prior[relPath];
				if (priorStatus == null) continue; // present locally but absent from snapshot — silent
				scanned++;
				final source: String = readSourceForParse(path);
				final current: ReconCurrentParse = reconRegressionParse(plugin, source);
				if (current.unwired) return {
					regressed: regressed,
					unblocked: unblocked,
					scanned: scanned,
					unwired: true
				};
				final priorParsed: Bool = priorStatus == 'PASS' || priorStatus == 'FAIL' || priorStatus == 'SKIP_WRITE';
				final priorSkipParse: Bool = priorStatus == 'SKIP_PARSE';
				if (priorParsed && !current.ok) {
					regressed++;
					final locus: String = current.line > 0
						? ' :: ${current.line}:${current.col} expected="${current.msg}"'
						: ' :: ${current.msg}';
					sysPrint('REGRESSED $relPath: was $priorStatus, now SKIP_PARSE$locus\n');
				} else if (priorSkipParse && current.ok) {
					unblocked++;
					sysPrint('UNBLOCKED $relPath: was SKIP_PARSE, now parses OK\n');
				}
				// SKIP_CONFIG / MALFORMED in prior: orthogonal to grammar; silent.
				// No flip: silent.
			}
		}
		return {
			regressed: regressed,
			unblocked: unblocked,
			scanned: scanned,
			unwired: false
		};
	}

	/**
	 * Parse one fixture's source under the recon parser. `unwired` flags a
	 * grammar plugin with no recon parser; otherwise `ok` plus the failure
	 * locus (line/col/msg) when the parse threw.
	 */
	private static function reconRegressionParse(plugin: GrammarPlugin, source: String): ReconCurrentParse {
		try {
			if (!plugin.reconParse(source)) return {
				unwired: true,
				ok: false,
				line: 0,
				col: 0,
				msg: ''
			};
			return {
				unwired: false,
				ok: true,
				line: 0,
				col: 0,
				msg: ''
			};
		} catch (exception: ParseError) {
			final pos: Position = exception.span.lineCol(source);
			return {
				unwired: false,
				ok: false,
				line: pos.line,
				col: pos.col,
				msg: reconNormalize(exception.expected)
			};
		} catch (exception: Exception) {
			return {
				unwired: false,
				ok: false,
				line: 0,
				col: 0,
				msg: reconNormalize(exception.message)
			};
		}
	}

	/**
	 * Parse a candidate source under the plugin's file parser, returning a
	 * PARSE OK / PARSE FAIL flag plus the failure message.
	 */
	private static function stripTryParse(plugin: GrammarPlugin, s: String): { ok: Bool, msg: String } {
		return try {
			plugin.parseFile(s);
			{ ok: true, msg: '' };
		} catch (e: ParseError) {
			{ ok: false, msg: e.toString() };
		} catch (e: Exception) {
			{ ok: false, msg: e.message };
		}
	}

	/**
	 * Print the per-pattern strip verdict. Interlocking-blockers signature:
	 * combined OK + every isolated row FAIL — the slice needs N code
	 * mechanisms, not one. Otherwise report how many patterns unblock alone,
	 * or flag the no-op case where the baseline already parses.
	 */
	private static function reportStripVerdict(
		baselineOk: Bool, combinedOk: Bool, isolatedResults: Array<{ ok: Bool, hits: Int }>, patternCount: Int
	): Void {
		if (combinedOk && !baselineOk) {
			var anyIsolatedOk: Bool = false;
			for (r in isolatedResults) if (r.ok) anyIsolatedOk = true;
			if (!anyIsolatedOk) {
				sysPrint(
					'VERDICT interlocking blockers — every pattern alone still fails; the combination is required. Slice scope likely needs $patternCount separate code mechanisms.\n'
				);
			} else {
				var soleCount: Int = 0;
				for (r in isolatedResults) if (r.ok) soleCount++;
				sysPrint(
					'VERDICT $soleCount of $patternCount pattern${plural(patternCount)} unblock alone — the rest are redundant (or compose into a tighter slice).\n'
				);
			}
		} else if (!combinedOk && baselineOk) {
			sysPrint('VERDICT no-op — baseline already parses; the strip diagnostic does not apply.\n');
		}
	}

	/**
	 * Run one --fix pass: rebuild the SymbolIndex over the current (mutated)
	 * sources, lint the active subset (active-scope checks) plus the full
	 * set (cross-file checks), then per active file collect + canonicalize
	 * its fixes. Returns the files changed this pass (eligible next pass)
	 * and the count of edits applied. Mutates `changedFiles` / `noted`.
	 */
	private static function applyLintPass(
		active: Array<{ file: String, source: String }>, files: Array<{ file: String, source: String }>, cached: GrammarPlugin,
		activeScopeChecks: Array<Check>, fullScopeChecks: Array<Check>, checks: Array<Check>, lintConfig: LintConfig,
		optsByFile: Map<String, Null<String>>, passes: Int, noted: Array<String>, changedFiles: Array<String>
	): LintPassResult {
		// Rebuild over the CURRENT (mutated) sources — naming's cross-file
		// rename consults the index, so it must reflect this pass's input.
		final index: SymbolIndex = SymbolIndex.build(files, cached);
		final violations: Array<Violation> = Linter.run(active, cached, activeScopeChecks, lintConfig);
		for (v in Linter.run(files, cached, fullScopeChecks, lintConfig)) violations.push(v);
		final nextActive: Array<{ file: String, source: String }> = [];
		var fixedDelta: Int = 0;
		for (entry in active) {
			final fileViolations: Array<Violation> = violations.filter(v -> v.file == entry.file);
			if (fileViolations.length == 0) continue;
			final disjoint: Array<{ span: Span, text: String }> = computeFileLintEdits(entry.source, fileViolations, checks, cached, index);
			if (disjoint.length == 0) continue;
			switch RefactorSupport.canonicalize(entry.source, disjoint, false, cached, optsByFile[entry.file]) {
				case Ok(text):
					if (text != entry.source) {
						entry.source = text;
						if (!changedFiles.contains(entry.file)) changedFiles.push(entry.file);
						fixedDelta += disjoint.length;
						nextActive.push(entry);
					}
				case Err(message):
					if (passes == 1 && !noted.contains(entry.file)) {
						stderr('apq lint --fix: ${entry.file}: $message\n');
						noted.push(entry.file);
					}
			}
		}
		return { nextActive: nextActive, fixedDelta: fixedDelta };
	}

	/**
	 * Collect every check's fix edits for one file's violations and drop the
	 * contained (overlapping) ones, returning a disjoint edit set ready for
	 * canonicalization.
	 */
	private static function computeFileLintEdits(
		source: String, fileViolations: Array<Violation>, checks: Array<Check>, cached: GrammarPlugin, index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (check in checks) {
			final own: Array<Violation> = fileViolations.filter(v -> v.rule == check.id());
			if (own.length == 0) continue;
			for (edit in check.fix(source, own, cached, index)) edits.push(edit);
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

}

@:nullSafety(Strict)
typedef StripOpts = {
	var lang: String;
	var showSource: Bool;
	var dryRun: Bool;
	var perPattern: Bool;
	var fromCluster: Null<String>;
	var regexMode: Bool;
	var files: Array<String>;
	var patterns: Array<String>;
	var replacements: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef ReconOpts = {
	var lang: String;
	var topN: Int;
	var probePath: Null<String>;
	var rootDir: Null<String>;
	var clusterFilter: Null<String>;
	var predictStrip: Bool;
	var regressionProbe: Bool;
	var candidatesRegex: Null<String>;
	var predictRelax: Bool;
	var permissiveConstruct: Bool;
	var showSource: Bool;
	var noTargetClusterFilter: Null<String>;
	var patterns: Array<String>;
	var replacements: Array<String>;
	var regexMode: Bool;
	var compiledRegex: Null<Array<EReg>>;
	var writerEqualsAfter: Bool;
	var writerEqualsPlain: Bool;
	var expectedPath: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag / validation
	// failure -> EXIT_USAGE); the caller returns this immediately and ignores the rest.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef AstOpts = {
	var lang: String;
	var json: Bool;
	var depth: Int;
	var selectExpr: Null<String>;
	var atExpr: Null<String>;
	var wantDoc: Bool;
	var wantSource: Bool;
	var writerOutput: Bool;
	var writerOutputPlain: Bool;
	var writerDiff: Bool;
	var minChildren: Int;
	var maxChildren: Int;
	var childrenLimit: Int;
	var spans: Bool;
	var countOnly: Bool;
	var file: Null<String>;
	// Inline source (`apq probe '<code>'` -> `--code <s>`) or stdin
	// (`apq ast --stdin`) bypass the file read for micro-probes
	// without a /tmp scratch file. Mutually exclusive with each
	// other and with a file argument; checked after arg parsing.
	var codeArg: Null<String>;
	var stdinFlag: Bool;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag / validation
	// failure -> EXIT_USAGE); the caller returns this immediately and ignores the rest.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef MetaOpts = {
	var lang: String;
	var json: Bool;
	var argContains: Null<String>;
	var onKind: Null<String>;
	var flat: Bool;
	var limit: Int;
	var positionals: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef BlastOpts = {
	var lang: String;
	var flat: Bool;
	var limit: Int;
	var showAll: Bool;
	var name: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef LitOpts = {
	var lang: String;
	var exact: Bool;
	var flat: Bool;
	var limit: Int;
	var kindFilter: Null<Array<String>>;
	var includeComments: Bool;
	var target: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef NewOpts = {
	var lang: String;
	var write: Bool;
	var asClass: Bool;
	var open: Bool;
	var raw: Bool;
	var kind: String;
	var iface: Null<String>;
	var underlying: Null<String>;
	var bodiesArg: Null<String>;
	var bodiesFromFile: Null<String>;
	var extendsList: Array<String>;
	var fromList: Array<String>;
	var toList: Array<String>;
	var fields: Array<String>;
	var path: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef SearchOpts = {
	var lang: String;
	var json: Bool;
	var kind: Null<String>;
	var limit: Int;
	var explain: Bool;
	var flat: Bool;
	var pattern: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
@:nullSafety(Strict)
typedef LintOpts = {
	var lang: String;
	var flat: Bool;
	var includeInfo: Bool;
	var fix: Bool;
	var failOn: Null<Severity>;
	var format: String;
	var ruleFilters: Array<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag/value -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};
