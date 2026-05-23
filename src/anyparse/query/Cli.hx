package anyparse.query;

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
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.Uses.UsesHit;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;
import haxe.Exception;

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
typedef SkipEntry = {path:String, locus:String};

/**
 * Corpus harness sweep snapshot (`bin/.last-sweep.json` schema).
 * Mirrors `HxFormatterCorpusTest.printSweepDelta`'s write contract —
 * `apq sweep` reads the JSON and reports totals + delta without
 * re-running the corpus.
 */
typedef SweepTotals = {pass:Int, fail:Int, skipParse:Int, skipWrite:Int, skipConfig:Int, skipMalformed:Int};

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
	var count:Int;
	var examples:Array<String>;
	var paths:Array<String>;
	var rawSample:String;
};

/**
 * Per-failure record captured during the recon sweep. Mode-dependent
 * output (histogram / cluster drill / predict-strip) reads these
 * after the walk instead of printing inline, so cluster filtering
 * and substitution prediction stay decoupled from the file-system
 * traversal loop.
 */
typedef ReconRecord = {
	var path:String;
	var clusterKey:String;
	var source:String;
	var skipLine:String;
	/**
	 * 1-indexed line of the parse-fail locus inside `source`. `0` when
	 * the record came from a non-`ParseError` exception (no span); the
	 * `--source` drill prints `<no locus>` for those.
	 */
	var line:Int;
	/** 1-indexed column at the parse-fail locus; `0` for non-`ParseError`. */
	var col:Int;
};

/**
 * Result of one corpus walk. `wired == false` means the plugin's recon
 * parser is missing — both `runReconSweep` and `strip --from-cluster`
 * surface that as a hard runtime error before consuming the records.
 */
typedef ReconWalkResult = {
	var wired:Bool;
	var records:Array<ReconRecord>;
	var clusters:Map<String, ReconCluster>;
};

/**
 * One trail-opt gate annotation hit surfaced by `apq gates`. `line`/`col`
 * point at the decl host the `@:fmt` is attached to (1-indexed, derived
 * from the decl span via `Span.lineCol`). `gateKind` is the call name
 * (`trailOptParseGate` / `trailOptShapeGate`), `predicate` the quoted
 * inner symbol — the field name to look up on the schema instance.
 */
typedef GateHit = {
	var line:Int;
	var col:Int;
	var declKind:String;
	var declName:Null<String>;
	var gateKind:String;
	var predicate:String;
};

/**
 * Intermediate parse result of `extractGate` — `gateKind` is the call
 * name without parens, `predicate` the quoted inner symbol. `null` from
 * the extractor means the `@:fmt` argument is not a gate call.
 */
typedef GateExtract = {gateKind:String, predicate:String};

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
	var kind:PredictRelaxKind;
	var original:String;
	var patched:String;
	var injected:String;
	var origLine:Int;
	var origCol:Int;
	var newLine:Int;
	var newCol:Int;
	var message:String;
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
	var file:String;
	var line:Int;
	var col:Int;
	var declKind:String;
	var declName:Null<String>;
	var lead:String;
	var trail:String;
};

/**
 * Result of one `stripBalancedPairs` pass — the patched source plus a
 * `count` of strip occurrences so the predictor can report NO MATCH
 * (count == 0, fixture doesn't contain the construct) distinctly from
 * STILL FAIL (count > 0 but post-strip parse still errors).
 */
typedef StripResult = {
	var out:String;
	var count:Int;
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

	private static final EXIT_OK:Int = 0;
	private static final EXIT_USAGE:Int = 2;
	private static final EXIT_RUNTIME:Int = 1;

	private static final SKIP_PATHS_SHOWN:Int = 5;
	private static final FUZZY_MAX_DIST:Int = 3;

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
	private static final HEUR_DEFAULT_CAP:Int = 20;

	private static final RECON_TOP_N_DEFAULT:Int = 30;
	private static final RECON_EXAMPLES_PER_CLUSTER:Int = 2;
	private static final RECON_HEAD_LEN:Int = 70;
	private static final RECON_LOCUS_LEN:Int = 20;
	/**
	 * `recon --cluster <key> --source` drill: lines printed either side
	 * of the fail-locus row. 3 is enough to see the construct's frame
	 * (decl line + open brace + the failing body line) without flooding
	 * the drill output when a cluster has dozens of paths.
	 */
	private static final RECON_SOURCE_WINDOW_RADIUS:Int = 3;
	private static final FUZZY_TOP_K:Int = 3;
	/**
	 * Substring "did you mean" — `query` ≥ this length OR the substring
	 * pre-filter is skipped (avoids `Hx` matching every grammar type).
	 */
	private static final FUZZY_SUBSTRING_MIN_QUERY:Int = 4;
	/**
	 * Substring "did you mean" — candidate's extra char count over
	 * `query.length` must not exceed this (avoids `Foo` matching a huge
	 * `FooSomeReallyLongName` and crowding out true neighbours).
	 */
	private static final FUZZY_SUBSTRING_MAX_EXTRA:Int = 8;

	public static function main():Void {
		#if (sys || nodejs)
		Sys.exit(run(Sys.args()));
		#else
		throw 'apq: only sys targets supported';
		#end
	}

	/** Pure-argv entry. Returns process exit code. */
	public static function run(args:Array<String>):Int {
		if (args.length == 0 || args[0] == '-h' || args[0] == '--help') {
			printUsage();
			return EXIT_OK;
		}
		final cmd:String = args[0];
		final rest:Array<String> = args.slice(1);
		switch cmd {
			case 'ast': return runAst(rest);
			case 'search': return runSearch(rest);
			case 'refs': return runRefs(rest);
			case 'uses': return runUses(rest);
			case 'meta': return runMeta(rest);
			case 'blast': return runBlast(rest);
			case 'lit': return runLit(rest);
			case 'mentions': return runMentions(rest);
			case 'cases': return runCases(rest);
			case 'gates': return runGates(rest);
			case 'diff': return runDiff(rest);
			case 'strip': return runStrip(rest);
			case 'writer-equals': return runWriterEquals(rest);
			case 'probe': return runProbe(rest);
			case 'writer-probe': return runWriterProbe(rest);
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
			case _:
				stderr('apq: unknown subcommand "$cmd"\n');
				printUsage();
				return EXIT_USAGE;
		}
	}

	private static function runRefs(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var wantDecls:Bool = false;
		var wantReads:Bool = false;
		var wantWrites:Bool = false;
		var wantDoc:Bool = false;
		var wantSource:Bool = false;
		var flat:Bool = false;
		var limit:Int = -1;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
					try limit = parseLimit(args, ++i) catch (e:Exception) {
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
					if (name == null) name = a;
					else inputSpecs.push(a);
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
		final nameStr:String = name;
		// No flag = no filter (emit every hit). Any flag flips on the
		// allow-set; sister CLIs (`git log --author --grep`) follow the
		// same any-flag-narrows convention.
		final anyFilter:Bool = wantDecls || wantReads || wantWrites;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:RefShape = plugin.refShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq refs: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<RefHit>}> = [];
		final skipEntries:Array<SkipEntry> = [];
		final candidateNames:Map<String, Bool> = new Map();
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('refs', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw:Array<RefHit> = Refs.find(nameStr, tree, shape);
			final filtered:Array<RefHit> = anyFilter
				? raw.filter(h -> kindAllowed(h.kind, wantDecls, wantReads, wantWrites))
				: raw;
			if (filtered.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({file: path, source: source, hits: filtered});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('refs', nameStr, paths.length, paths.length - skipEntries.length, skipEntries, candidateNames) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<RefHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		if (json) {
			sysPrint(Json.renderRefs(shown, wantDoc, wantSource));
		} else {
			for (entry in shown) sysPrint(Text.renderRefs(entry.file, entry.source, entry.hits, wantDoc, wantSource, flat));
		}
		return EXIT_OK;
	}

	private static function runUses(args:Array<String>):Int {
		var lang:String = 'haxe';
		var wantDoc:Bool = false;
		var wantSource:Bool = false;
		var flat:Bool = false;
		var limit:Int = -1;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
					try limit = parseLimit(args, ++i) catch (e:Exception) {
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
					if (name == null) name = a;
					else inputSpecs.push(a);
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
		final nameStr:String = name;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:TypeRefShape = plugin.typeRefShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq uses: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<UsesHit>}> = [];
		final skipEntries:Array<SkipEntry> = [];
		final candidateNames:Map<String, Bool> = new Map();
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('uses', plugin.parseFileTypeRefs, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final hits:Array<UsesHit> = Uses.find(nameStr, tree, shape);
			if (hits.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({file: path, source: source, hits: hits});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('uses', nameStr, paths.length, paths.length - skipEntries.length, skipEntries, candidateNames) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<UsesHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		for (entry in shown) sysPrint(Text.renderUses(entry.file, entry.source, entry.hits, wantDoc, wantSource, flat));
		return EXIT_OK;
	}

	private static function runMeta(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var argContains:Null<String> = null;
		var onKind:Null<String> = null;
		var flat:Bool = false;
		var limit:Int = -1;
		final positionals:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printMetaUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq meta: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					positionals.push(a);
			}
			i++;
		}

		// Positional grammar: [<annotation>] <file-or-dir-or-glob>...
		// The annotation, when present, is the leading positional and is
		// recognised by its `@` sigil (Haxe annotations always start with
		// `@`; file/dir/glob specs never do) — this disambiguates without
		// a positional-count cap, so multiple input specs are accepted.
		// With `--on` the annotation may be omitted entirely.
		final annotation:Null<String> = positionals.length > 0 && StringTools.startsWith(positionals[0], '@')
			? positionals[0] : null;
		final inputSpecs:Array<String> = annotation != null ? positionals.slice(1) : positionals.copy();
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
		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:MetaShape = plugin.metaShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq meta: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<MetaHit>}> = [];
		final skipEntries:Array<SkipEntry> = [];
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('meta', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw:Array<MetaHit> = Meta.find(tree, shape, source);
			final filtered:Array<MetaHit> = raw.filter(h ->
				(annotation == null || h.annotation == annotation)
				&& argMatches(h.args, argContains)
				&& (onKind == null || h.declKind == onKind));
			if (filtered.length == 0) continue;
			allEntries.push({file: path, source: source, hits: filtered});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('meta', null, paths.length, paths.length - skipEntries.length, skipEntries, null) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<MetaHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		if (json) {
			sysPrint(Json.renderMeta(shown));
		} else {
			for (entry in shown) sysPrint(Text.renderMeta(entry.file, entry.source, entry.hits, flat));
		}
		return EXIT_OK;
	}

	/**
	 * `apq diff <a> <b>` — structural AST diff between two parseable
	 * source files. Output is `file:L:C ↔ file:L:C: <diff>` per hit.
	 * The pair walk is top-down without LCS realignment: it surfaces
	 * "single edit" / "end-of-list change" / "subtree swap" cleanly,
	 * but a mid-list insert into a long Star cascades every following
	 * sibling as `differs`. For those cases use byte diff or `--limit`.
	 */
	private static function runDiff(args:Array<String>):Int {
		var lang:String = 'haxe';
		var flat:Bool = false;
		var limit:Int = -1;
		var fileA:Null<String> = null;
		var fileB:Null<String> = null;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
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
					if (fileA == null) fileA = a;
					else if (fileB == null) fileB = a;
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
		final a:String = fileA;
		final b:String = fileB;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final sourceA:String = readSourceForParse(a);
		final sourceB:String = readSourceForParse(b);
		final treeA:QueryNode = try plugin.parseFile(sourceA) catch (e:ParseError) {
			stderr('apq diff: $a: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq diff: $a: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final treeB:QueryNode = try plugin.parseFile(sourceB) catch (e:ParseError) {
			stderr('apq diff: $b: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq diff: $b: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		var hits:Array<DiffHit> = Diff.diff(treeA, treeB);
		if (limit >= 0 && hits.length > limit) hits = hits.slice(0, limit);
		sysPrint(Diff.render(a, sourceA, b, sourceB, hits, flat));
		return EXIT_OK;
	}

	private static function printDiffUsage():Void {
		sysPrint('Usage: apq diff [options] <a> <b>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` per-hit format (default: paired-header)\n');
		sysPrint('  --limit <n>         Stop after n hits (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint("Structural AST diff: walks both trees pairwise and reports nodes\n");
		sysPrint("where kind / name slot / child count diverges. No LCS realignment\n");
		sysPrint("— mid-list inserts cascade the tail as `differs`. Useful for strip-\n");
		sysPrint("test reconciliation when a byte diff is whitespace-noisy.\n");
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
	private static function runStrip(args:Array<String>):Int {
		var lang:String = 'haxe';
		var showSource:Bool = false;
		// --dry-run: skip the parse step, only verify that every supplied
		// --replace/--delete pattern actually matched at least once in
		// at least one file. Typo guard for batch strip-sweeps — when
		// the pattern silently doesn't match, the corpus delta misleads;
		// a single dry-run pass surfaces the typo before any apply.
		var dryRun:Bool = false;
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
		var perPattern:Bool = false;
		// `--from-cluster <key>` switches positional mode: the (single)
		// positional becomes the corpus root (recon-style, env fallback
		// to ANYPARSE_HXFORMAT_FORK/test/testcases); the file list is
		// derived from a recon walk of that root, filtered to the named
		// cluster. Direct complement to `recon --predict-strip`'s
		// upper-bound prediction — this is the actual sweep apply.
		var fromCluster:Null<String> = null;
		// --regex: treat every --replace / --delete pattern as an EReg
		// pattern (PCRE-ish, Haxe EReg dialect) instead of a literal
		// substring. Application path switches to EReg.replace (global)
		// for substitution and EReg.map for hit counting. The replacement
		// string keeps its literal semantics — to use a backref, write
		// e.g. `$1` per EReg.replace docs. Malformed regex is reported at
		// arg-validation time with EXIT_USAGE before any FS I/O.
		var regexMode:Bool = false;
		final files:Array<String> = [];
		final patterns:Array<String> = [];
		final replacements:Array<String> = [];
		var pendingReplace:Null<String> = null;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--replace':
					if (pendingReplace != null) {
						stderr('apq strip: --replace "$pendingReplace" needs a --with before the next --replace\n');
						return EXIT_USAGE;
					}
					pendingReplace = expectValue(args, ++i, '--replace');
				case '--with':
					if (pendingReplace == null) {
						stderr('apq strip: --with requires a preceding --replace\n');
						return EXIT_USAGE;
					}
					patterns.push(pendingReplace);
					replacements.push(expectValue(args, ++i, '--with'));
					pendingReplace = null;
				case '--delete':
					if (pendingReplace != null) {
						stderr('apq strip: --replace "$pendingReplace" needs a --with before --delete\n');
						return EXIT_USAGE;
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
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq strip: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					files.push(a);
			}
			i++;
		}
		if (pendingReplace != null) {
			stderr('apq strip: --replace "$pendingReplace" needs a --with\n');
			return EXIT_USAGE;
		}
		if (patterns.length == 0) {
			stderr('apq strip: missing at least one --replace/--with or --delete\n');
			printStripUsage();
			return EXIT_USAGE;
		}
		// Compile every pattern AHEAD of any FS I/O so a regex typo
		// surfaces as a single usage error instead of an N-file partial
		// apply. Indices stay aligned with `patterns` / `replacements`.
		// Plain (literal) mode leaves `compiledRegex` null and falls
		// through to the StringTools.replace path further down.
		final compiledRegex:Null<Array<EReg>> = regexMode ? compileStripRegexes('strip', patterns) : null;
		if (regexMode && compiledRegex == null) return EXIT_USAGE;
		// `--per-pattern` constraints: single-file only (the matrix
		// would be NxM otherwise), incompatible with `--dry-run` (the
		// dry-run path skips parse entirely so isolation diagnostics
		// have no PARSE OK/FAIL signal) and `--from-cluster` (the
		// cluster-mode discovers N files from a recon walk, never one).
		if (perPattern) {
			if (dryRun) {
				stderr('apq strip: --per-pattern is incompatible with --dry-run (dry-run skips the parse step)\n');
				return EXIT_USAGE;
			}
			if (fromCluster != null) {
				stderr('apq strip: --per-pattern is incompatible with --from-cluster (single-file isolation only)\n');
				return EXIT_USAGE;
			}
		}
		// `--from-cluster` mode: discover files via recon walk, then
		// fall through into the existing per-file substitution loop.
		// Conflict guards live here so a bad mix is surfaced before
		// any FS I/O or plugin call.
		if (fromCluster != null) {
			if (files.length > 1) {
				stderr('apq strip: --from-cluster takes at most one positional (corpus root); got ${files.length} (${files.join(", ")})\n');
				return EXIT_USAGE;
			}
			final discovered:Null<Array<String>> = resolveStripFromCluster(lang, files.length == 1 ? files[0] : null, (fromCluster : String));
			if (discovered == null) return EXIT_RUNTIME;
			// Replace the positional list with the cluster's path list so
			// the rest of runStrip is mode-agnostic. A non-null `discovered`
			// is non-empty by construction (any cluster keyed in the map
			// has at least one path; the no-match path returned null
			// above), so no zero-length branch needed here.
			files.resize(0);
			for (p in (discovered : Array<String>)) files.push(p);
		} else if (files.length == 0) {
			stderr('apq strip: missing <file> argument (one or more, applies same substitutions to each)\n');
			printStripUsage();
			return EXIT_USAGE;
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		if (perPattern) {
			if (files.length != 1) {
				stderr('apq strip: --per-pattern takes exactly one file (got ${files.length})\n');
				return EXIT_USAGE;
			}
			if (patterns.length < 2) {
				stderr('apq strip: --per-pattern requires ≥2 patterns (got ${patterns.length}) — isolation diagnostic only useful when patterns can be tested independently\n');
				return EXIT_USAGE;
			}
			return runStripPerPattern(plugin, files[0], patterns, replacements, compiledRegex);
		}
		final multi:Bool = files.length > 1;
		var anyFailed:Bool = false;
		var anyChanged:Bool = false;
		var passCount:Int = 0;
		var failCount:Int = 0;
		// --dry-run: track per-pattern match totals across all files so a
		// pattern that matched 0 occurrences ANYWHERE surfaces as a typo,
		// even when other patterns in the same call did match.
		final patternHits:Array<Int> = dryRun ? [for (_ in 0...patterns.length) 0] : [];
		// Narrow `Null<Array<EReg>>` to `Array<EReg>` in one place — the
		// inline `(compiledRegex : Array<EReg>)` cast does not satisfy
		// strict null safety. Empty fallback keeps the regex-mode-off
		// branch from indexing it.
		final regexes:Array<EReg> = compiledRegex ?? [];
		for (filePath in files) {
			final source:String = readSourceForParse(filePath);
			var stripped:String = source;
			var fileHits:Int = 0;
			for (idx in 0...patterns.length) {
				if (dryRun) {
					final hits:Int = regexMode
						? countRegexHits(regexes[idx], stripped)
						: countOccurrences(stripped, patterns[idx]);
					patternHits[idx] += hits;
					fileHits += hits;
				}
				stripped = regexMode
					? regexes[idx].replace(stripped, replacements[idx])
					: StringTools.replace(stripped, patterns[idx], replacements[idx]);
			}
			if (stripped != source) anyChanged = true;
			if (showSource) {
				stderr('--- stripped source (${filePath}) ---\n$stripped\n--- end ---\n');
			}
			final prefix:String = multi ? '$filePath: ' : '';
			if (dryRun) {
				final tag:String = fileHits > 0 ? 'WOULD CHANGE' : 'NO MATCH';
				sysPrint('${prefix}$tag ($fileHits substitution${fileHits == 1 ? '' : 's'})\n');
				continue;
			}
			try {
				plugin.parseFile(stripped);
				sysPrint('${prefix}PARSE OK\n');
				passCount++;
			} catch (e:ParseError) {
				sysPrint('${prefix}PARSE FAIL: ${e.toString()}\n');
				failCount++;
				anyFailed = true;
			} catch (e:Exception) {
				sysPrint('${prefix}PARSE FAIL: ${e.message}\n');
				failCount++;
				anyFailed = true;
			}
		}
		if (dryRun) {
			// Per-pattern summary first so a sweep over N files exposes
			// each pattern's match count individually. Exit non-zero
			// when ANY supplied pattern matched 0 occurrences — the
			// guard's whole purpose is to catch a typo even when a
			// sibling pattern in the same call did match. Use the
			// global zero case for a stronger error message.
			var anyZero:Bool = false;
			for (idx in 0...patterns.length) {
				final pat:String = patterns[idx];
				final total:Int = patternHits[idx];
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
		if (!anyChanged) {
			final scope:String = multi ? 'across all ${files.length} files' : '';
			stderr('apq strip: WARNING: no substitution changed the source (patterns matched 0 occurrences${scope == '' ? '' : ' $scope'})\n');
		}
		if (multi) {
			sysPrint('--- $passCount PARSE OK, $failCount PARSE FAIL (total ${files.length}) ---\n');
		}
		return anyFailed ? EXIT_RUNTIME : EXIT_OK;
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
		plugin:GrammarPlugin, filePath:String,
		patterns:Array<String>, replacements:Array<String>, compiledRegex:Null<Array<EReg>>
	):Int {
		final source:String = readSourceForParse(filePath);
		final regexMode:Bool = compiledRegex != null;
		final regexes:Array<EReg> = compiledRegex ?? [];
		inline function tryParse(s:String):{ok:Bool, msg:String} {
			return try {
				plugin.parseFile(s);
				{ok: true, msg: ''};
			} catch (e:ParseError) {
				{ok: false, msg: e.toString()};
			} catch (e:Exception) {
				{ok: false, msg: e.message};
			}
		}
		final baseline:{ok:Bool, msg:String} = tryParse(source);
		sysPrint('baseline (no patterns): ${baseline.ok ? "PARSE OK" : "PARSE FAIL: " + baseline.msg}\n');
		final isolatedResults:Array<{ok:Bool, hits:Int}> = [];
		for (idx in 0...patterns.length) {
			final hits:Int = regexMode
				? countRegexHits(regexes[idx], source)
				: countOccurrences(source, patterns[idx]);
			final isolated:String = regexMode
				? regexes[idx].replace(source, replacements[idx])
				: StringTools.replace(source, patterns[idx], replacements[idx]);
			final r:{ok:Bool, msg:String} = tryParse(isolated);
			isolatedResults.push({ok: r.ok, hits: hits});
			final pat:String = patterns[idx];
			sysPrint('pattern[$idx] "$pat" ($hits match${hits == 1 ? '' : 'es'}): ${r.ok ? "PARSE OK" : "PARSE FAIL: " + r.msg}\n');
		}
		var combinedStripped:String = source;
		for (idx in 0...patterns.length)
			combinedStripped = regexMode
				? regexes[idx].replace(combinedStripped, replacements[idx])
				: StringTools.replace(combinedStripped, patterns[idx], replacements[idx]);
		final combined:{ok:Bool, msg:String} = tryParse(combinedStripped);
		sysPrint('combined (all patterns): ${combined.ok ? "PARSE OK" : "PARSE FAIL: " + combined.msg}\n');
		// Verdict — interlocking-blockers signature: combined OK + every
		// isolated row FAIL. This is the slice-scope warning: each
		// pattern targets a separate parse blocker, so the slice needs
		// N code mechanisms, not one.
		if (combined.ok && !baseline.ok) {
			var anyIsolatedOk:Bool = false;
			for (r in isolatedResults) if (r.ok) anyIsolatedOk = true;
			if (!anyIsolatedOk) {
				sysPrint('VERDICT interlocking blockers — every pattern alone still fails; the combination is required. Slice scope likely needs ${patterns.length} separate code mechanisms.\n');
			} else {
				var soleCount:Int = 0;
				for (r in isolatedResults) if (r.ok) soleCount++;
				sysPrint('VERDICT $soleCount of ${patterns.length} pattern${patterns.length == 1 ? '' : 's'} unblock alone — the rest are redundant (or compose into a tighter slice).\n');
			}
		} else if (!combined.ok && baseline.ok) {
			sysPrint('VERDICT no-op — baseline already parses; the strip diagnostic does not apply.\n');
		}
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
	private static function resolveStripFromCluster(lang:String, rootArg:Null<String>, key:String):Null<Array<String>> {
		#if (sys || nodejs)
		final root:String = rootArg ?? defaultReconRoot();
		if (root == '') {
			stderr("apq strip: --from-cluster requires a corpus root (positional <dir> or $ANYPARSE_HXFORMAT_FORK env var).\n");
			return null;
		}
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			stderr('apq strip: --from-cluster: "$root" is not a directory.\n');
			return null;
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		final walk:ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq strip: --from-cluster: no recon parser wired up for lang "$lang"\n');
			return null;
		}
		final cluster:Null<ReconCluster> = walk.clusters[key];
		if (cluster == null) {
			stderr('apq strip: --from-cluster "$key" matched no cluster key (exact match).\n');
			final keyEntries:Array<{key:String, count:Int}> = [
				for (k => v in walk.clusters) {key: k, count: v.count}
			];
			keyEntries.sort((a, b) -> b.count - a.count);
			final preview:Int = keyEntries.length > 10 ? 10 : keyEntries.length;
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
		final out:Array<String> = [for (p in cluster.paths) '$root/$p'];
		out.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
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
	private static function countOccurrences(haystack:String, needle:String):Int {
		if (needle.length == 0) return 0;
		var count:Int = 0;
		var from:Int = 0;
		while (true) {
			final idx:Int = haystack.indexOf(needle, from);
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
	private static function compileStripRegexes(tool:String, patterns:Array<String>):Null<Array<EReg>> {
		final out:Array<EReg> = [];
		for (idx in 0...patterns.length) {
			final pat:String = patterns[idx];
			try {
				out.push(new EReg(pat, 'g'));
			} catch (e:Exception) {
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
	private static function countRegexHits(re:EReg, s:String):Int {
		var n:Int = 0;
		re.map(s, m -> {
			n++;
			m.matched(0);
		});
		return n;
	}

	private static function printStripUsage():Void {
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
		sysPrint("Apply literal substitutions in order, then parse the result via the\n");
		sysPrint("grammar plugin. Emits PARSE OK / PARSE FAIL: <err> and exits 0/2 —\n");
		sysPrint("scriptable sole-blocker confirmation for the skip-parse campaign.\n");
		sysPrint("StringTools.replace semantics: every occurrence is replaced.\n");
		sysPrint('\n');
		sysPrint("Pass multiple file paths to run the SAME substitutions against each\n");
		sysPrint("(batch mode); per-file output is prefixed with the path, and a final\n");
		sysPrint("summary line totals pass/fail counts. Exit 0 only when ALL files\n");
		sysPrint("PARSE OK; exit 2 when any file PARSE FAIL — useful for sole-blocker\n");
		sysPrint("sweeps across a list of candidate fixtures.\n");
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
	private static function runWriterEquals(args:Array<String>):Int {
		var lang:String = 'haxe';
		var plain:Bool = false;
		var inputPath:Null<String> = null;
		var expectedPath:Null<String> = null;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--plain':
					plain = true;
				case '-h', '--help':
					printWriterEqualsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq writer-equals: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (inputPath == null) inputPath = a;
					else if (expectedPath == null) expectedPath = a;
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
		final inputPathFinal:String = inputPath;
		final expectedPathFinal:String = expectedPath;
		final plugin:GrammarPlugin = pickPlugin(lang);
		final source:String = readSourceForParse(inputPathFinal);
		final expected:String = readExpectedForCompare(expectedPathFinal);
		// `.hxtest` input → section-1 config drives writer options so a
		// fork fixture reproduces the corpus harness's writer surface in
		// one command. Plain inputs stay on plugin defaults.
		final optsJson:Null<String> = readWriteOptionsJsonOrNull(inputPathFinal);

		final emitted:Null<String> = try (plain
			? plugin.writeRoundTripPlain(source, optsJson)
			: plugin.writeRoundTrip(source, optsJson))
		catch (e:ParseError) {
			stderr('apq writer-equals: $inputPathFinal: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq writer-equals: $inputPathFinal: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		if (emitted == null) {
			final flagName:String = plain ? '--plain' : '(trivia)';
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
	private static final BYTE_DIFF_WINDOW:Int = 40;
	private static final BYTE_DIFF_LEAD:Int = 4;

	private static function describeByteDiff(actual:String, expected:String):String {
		final maxLen:Int = expected.length < actual.length ? expected.length : actual.length;
		var diffAt:Int = -1;
		for (idx in 0...maxLen)
			if (StringTools.fastCodeAt(expected, idx) != StringTools.fastCodeAt(actual, idx)) {
				diffAt = idx;
				break;
			}
		if (diffAt == -1) diffAt = maxLen;
		final start:Int = diffAt - BYTE_DIFF_LEAD < 0 ? 0 : diffAt - BYTE_DIFF_LEAD;
		final expWin:String = escapeWindow(expected.substr(start, BYTE_DIFF_WINDOW));
		final actWin:String = escapeWindow(actual.substr(start, BYTE_DIFF_WINDOW));
		return 'apq writer-equals: byte-diff @ $diffAt'
			+ '  exp=<$expWin>'
			+ '  act=<$actWin>'
			+ '  (exp.len=${expected.length}, act.len=${actual.length})';
	}

	private static function escapeWindow(s:String):String {
		final buf:StringBuf = new StringBuf();
		for (idx in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, idx);
			switch c {
				case '\n'.code: buf.add('\\n');
				case '\t'.code: buf.add('\\t');
				case '\r'.code: buf.add('\\r');
				case _: buf.addChar(c);
			}
		}
		return buf.toString();
	}

	private static function printWriterEqualsUsage():Void {
		sysPrint('Usage: apq writer-equals [options] <input> <expected>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --plain             Use the plain (non-trivia) writer (mirrors unit tests)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
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
	private static function runLit(args:Array<String>):Int {
		var lang:String = 'haxe';
		var exact:Bool = false;
		var flat:Bool = false;
		var limit:Int = -1;
		// `null` = use smart default (resolved from <text> shape AFTER parsing
		// — camelCase / snake_case → Literal+IdentExpr, otherwise Literal).
		// Empty array = explicit `--any-kind`. Non-empty = explicit `--kind`.
		var kindFilter:Null<Array<String>> = null;
		var target:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--exact':
					exact = true;
				case '--kind':
					kindFilter = expectValue(args, ++i, '--kind').split(',');
				case '--any-kind':
					kindFilter = [];
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printLitUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq lit: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (target == null) target = a;
					else inputSpecs.push(a);
			}
			i++;
		}
		if (target == null) {
			stderr('apq lit: missing <text> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq lit: missing <file-or-dir-or-glob> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		final targetStr:String = target;
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
		final effectiveKindFilter:Array<String> = kindFilter != null
			? kindFilter
			: (looksLikeMixedIdentifier(targetStr) ? ['Literal', 'IdentExpr'] : ['Literal']);

		final plugin:GrammarPlugin = pickPlugin(lang);
		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq lit: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<LitHit>}> = [];
		final skipEntries:Array<SkipEntry> = [];
		// Cache parsed trees so the auto-widen retry path doesn't reparse.
		final trees:Array<{path:String, source:String, tree:QueryNode}> = [];
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('lit', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			trees.push({path: path, source: source, tree: tree});
			final hits:Array<LitHit> = Lit.find(targetStr, tree, exact, effectiveKindFilter);
			if (hits.length == 0) continue;
			allEntries.push({file: path, source: source, hits: hits});
		}

		// Auto-widen on 0-hit when kind was the smart-default (user didn't
		// pass --kind / --any-kind). Retry with --any-kind; if THAT finds
		// hits, show them with a stderr note so the next reflex is to add
		// `--any-kind` explicitly. Common case: CamelCase TypeName queries
		// that live as `ImportDecl` / `NewExpr` only (e.g. test-runner
		// imports) — default kind set (Literal,IdentExpr or Literal alone)
		// misses both. Silent on real 0-hits — the wider walk also empty.
		var autoWidened:Bool = false;
		if (allEntries.length == 0 && kindFilter == null) {
			for (entry in trees) {
				final hits:Array<LitHit> = Lit.find(targetStr, entry.tree, exact, []);
				if (hits.length == 0) continue;
				allEntries.push({file: entry.path, source: entry.source, hits: hits});
			}
			if (allEntries.length > 0) autoWidened = true;
		}

		if (allEntries.length == 0) {
			// DX v10: regex-like query → emit the regex-not-supported note
			// BEFORE the generic walker nudge. The generic nudge's dotted-
			// access heuristic mis-fires on patterns like `foo\|bar` and
			// sends the user toward `search '$x.field'`, which is wrong.
			final regexLabel:Null<String> = looksLikeRegex(targetStr);
			if (regexLabel != null)
				stderr('apq lit: NOTE "$targetStr" looks like a regex (contains $regexLabel) — lit is substring-only. Run separate lit calls per alternative, or use apq refs / apq uses / apq search for shape-aware lookup.\n');
			else
				stderr(emptyWalkerNudge('lit', targetStr, paths.length, paths.length - skipEntries.length, skipEntries, null) + '\n');
		} else if (autoWidened) {
			final tried:String = effectiveKindFilter.join(',');
			stderr('apq lit: NOTE auto-widened to --any-kind (default kind=$tried returned 0 hits). Pass `--any-kind` explicitly to silence this notice.\n');
		}

		final shown:Array<{file:String, source:String, hits:Array<LitHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		for (entry in shown) sysPrint(Lit.render(entry.file, entry.source, entry.hits, flat));
		return EXIT_OK;
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
	private static function runCases(args:Array<String>):Int {
		var lang:String = 'haxe';
		var flat:Bool = false;
		var limit:Int = -1;
		var target:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
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
					if (target == null) target = a;
					else inputSpecs.push(a);
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
		final targetStr:String = target;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq cases: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<CasesHit>}> = [];
		final skipEntries:Array<SkipEntry> = [];
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('cases', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final hits:Array<CasesHit> = Cases.find(targetStr, tree);
			if (hits.length == 0) continue;
			allEntries.push({file: path, source: source, hits: hits});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('cases', targetStr, paths.length, paths.length - skipEntries.length, skipEntries, null) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<CasesHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		for (entry in shown) sysPrint(Cases.render(entry.file, entry.source, entry.hits, flat));
		return EXIT_OK;
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
	private static function runGates(args:Array<String>):Int {
		var lang:String = 'haxe';
		var flat:Bool = false;
		var limit:Int = -1;
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
		var mechanism:String = 'trail-opt';
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
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
		final validMechanisms:Array<String> = [
			'trail-opt', 'optional-ref', 'optional-ref-trail', 'mandatory-ref-lead-trail', 'kw-lead'
		];
		if (!validMechanisms.contains(mechanism)) {
			stderr('apq gates: unknown --mechanism "$mechanism" (valid: ${validMechanisms.join(", ")})\n');
			return EXIT_USAGE;
		}
		// Default scope: the grammar tree for the selected lang.
		final effectiveSpecs:Array<String> = inputSpecs.length > 0
			? inputSpecs
			: ['src/anyparse/grammar/$lang/'];

		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:MetaShape = plugin.metaShape();
		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(effectiveSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq gates: no input files matched ${effectiveSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final skipEntries:Array<SkipEntry> = [];
		final allHits:Array<{file:String, source:String, hits:Array<GateHit>}> = [];
		var totalHits:Int = 0;
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('gates', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw:Array<MetaHit> = Meta.find(tree, shape, source);
			final fileHits:Array<GateHit> = mechanism == 'trail-opt'
				? collectTrailOptHits(raw, source, limit, totalHits)
				: collectMechanismHits(raw, source, mechanism, limit, totalHits);
			totalHits += fileHits.length;
			if (fileHits.length > 0) allHits.push({file: path, source: source, hits: fileHits});
		}

		if (allHits.length == 0) {
			final what:String = switch mechanism {
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
				final declLabel:String = h.declName == null ? h.declKind : '${h.declKind} ${h.declName}';
				final prefix:String = flat ? '${entry.file}:${h.line}:${h.col}: ' : '  ${h.line}:${h.col}: ';
				// trail-opt format preserved 1:1 for backwards-compat:
				// `<DeclKind> <name?> → trailOptParseGate('<pred>')`.
				// Other mechanisms render `<DeclKind> <name?> → <metas>`
				// where `<metas>` is the relevant subset of `@:` annotations
				// already-quoted in `predicate` (raw string from classifier).
				final tail:String = mechanism == 'trail-opt'
					? '${h.gateKind}(\'${h.predicate}\')'
					: h.predicate;
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
	private static function collectTrailOptHits(
		raw:Array<MetaHit>, source:String, limit:Int, sharedTotal:Int
	):Array<GateHit> {
		final out:Array<GateHit> = [];
		for (h in raw) if (h.annotation == '@:fmt') for (arg in h.args) {
			final extracted:Null<GateExtract> = extractGate(arg);
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
	private static function groupMetaHitsByDeclSpan(raw:Array<MetaHit>):{order:Array<Int>, groups:Map<Int, Array<MetaHit>>} {
		final order:Array<Int> = [];
		final groups:Map<Int, Array<MetaHit>> = [];
		for (h in raw) {
			final span:Null<Span> = h.declSpan;
			if (span == null) continue;
			final key:Int = span.from;
			var bucket:Null<Array<MetaHit>> = groups[key];
			if (bucket == null) {
				bucket = [];
				groups[key] = bucket;
				order.push(key);
			}
			bucket.push(h);
		}
		return {order: order, groups: groups};
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
		raw:Array<MetaHit>, source:String, mechanism:String, limit:Int, sharedTotal:Int
	):Array<GateHit> {
		final grouped:{order:Array<Int>, groups:Map<Int, Array<MetaHit>>} = groupMetaHitsByDeclSpan(raw);
		final out:Array<GateHit> = [];
		for (key in grouped.order) {
			if (limit >= 0 && sharedTotal + out.length >= limit) break;
			final metas:Null<Array<MetaHit>> = grouped.groups[key];
			if (metas == null) continue;
			final label:Null<String> = classifyMechanism(metas, mechanism);
			if (label == null) continue;
			final first:MetaHit = metas[0];
			final fspan:Null<Span> = first.declSpan;
			out.push({
				line: fspan != null ? fspan.lineCol(source).line : 0,
				col: fspan != null ? fspan.lineCol(source).col : 0,
				declKind: first.declKind,
				declName: first.declName,
				gateKind: '', // unused for non-trail-opt mechanisms
				predicate: (label : String),
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
	private static function classifyMechanism(metas:Array<MetaHit>, mechanism:String):Null<String> {
		var hasOptional:Bool = false;
		var lead:Null<String> = null;
		var trail:Null<String> = null;
		var kw:Null<String> = null;
		var absentOn:Null<String> = null;
		var sep:Null<String> = null;
		for (h in metas) switch h.annotation {
			case '@:optional': hasOptional = true;
			case '@:lead': lead = h.args.length > 0 ? h.args[0] : null;
			case '@:trail': trail = h.args.length > 0 ? h.args[0] : null;
			case '@:kw': kw = h.args.length > 0 ? h.args[0] : null;
			case '@:absentOn': absentOn = h.args.length > 0 ? h.args[0] : null;
			case '@:sep': sep = h.args.length > 0 ? h.args[0] : null;
			case _:
		}
		return switch mechanism {
			case 'optional-ref':
				if (!hasOptional) null
				else if (lead == null && kw == null && absentOn == null) null
				// Star fields with @:sep are excluded — they're the angle-
				// bracket array shape, not single Ref optional. Inspect
				// declName / declKind manually if you need both.
				else if (sep != null) null
				else renderMetaList(hasOptional, kw, lead, trail, absentOn);
			case 'optional-ref-trail':
				// Slice 40's exact signature: optional + lead + trail, no sep.
				if (hasOptional && lead != null && trail != null && sep == null)
					renderMetaList(hasOptional, kw, lead, trail, absentOn);
				else null;
			case 'mandatory-ref-lead-trail':
				// Pre-Slice-40 shape on a single Ref — the predict-optional
				// fallback candidates (turn `@:lead + @:trail` into
				// `@:optional @:lead + @:trail`). Exclude Star (`@:sep`)
				// — angle-bracket arrays are not the target.
				if (!hasOptional && lead != null && trail != null && sep == null)
					renderMetaList(hasOptional, kw, lead, trail, absentOn);
				else null;
			case 'kw-lead':
				if (kw != null) renderMetaList(hasOptional, kw, lead, trail, absentOn) else null;
			case _: null;
		};
	}

	private static function renderMetaList(
		hasOptional:Bool, kw:Null<String>, lead:Null<String>, trail:Null<String>, absentOn:Null<String>
	):String {
		final parts:Array<String> = [];
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
	private static function extractGate(arg:String):Null<GateExtract> {
		final trimmed:String = StringTools.trim(arg);
		final markers:Array<String> = ['trailOptParseGate', 'trailOptShapeGate'];
		for (m in markers) if (StringTools.startsWith(trimmed, m)) {
			final after:String = StringTools.trim(trimmed.substr(m.length));
			if (!StringTools.startsWith(after, '(')) continue;
			final inner:String = StringTools.trim(after.substring(1, after.lastIndexOf(')')));
			// `trailOptShapeGate` takes multiple args (`'endsWithCloseBrace', 'init'`);
			// extract just the FIRST quoted string — that's the predicate
			// method name on the schema instance. Subsequent args are
			// flag-bearing (typically a field-name selector) and not part
			// of the predicate identity.
			final firstArg:String = sliceFirstQuotedArg(inner);
			final stripped:String = stripQuotes(firstArg);
			if (stripped.length == 0) continue;
			return {gateKind: m, predicate: stripped};
		}
		return null;
	}

	/**
	 * Pick the first comma-separated argument from a paren-list body.
	 * Quote-aware: a comma INSIDE a `'…'` / `"…"` doesn't terminate the
	 * arg. Returns the trimmed first segment; the whole string when no
	 * top-level comma exists.
	 */
	private static function sliceFirstQuotedArg(inner:String):String {
		var inSingle:Bool = false;
		var inDouble:Bool = false;
		for (i in 0...inner.length) {
			final c:Int = StringTools.fastCodeAt(inner, i);
			if (!inDouble && c == "'".code) inSingle = !inSingle;
			else if (!inSingle && c == '"'.code) inDouble = !inDouble;
			else if (!inSingle && !inDouble && c == ','.code)
				return StringTools.trim(inner.substring(0, i));
		}
		return StringTools.trim(inner);
	}

	private static inline function stripQuotes(s:String):String {
		final t:String = StringTools.trim(s);
		if (t.length < 2) return t;
		final first:String = t.charAt(0);
		final last:String = t.charAt(t.length - 1);
		if ((first == "'" && last == "'") || (first == '"' && last == '"'))
			return t.substring(1, t.length - 1);
		return t;
	}

	private static function printGatesUsage():Void {
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

	private static function printCasesUsage():Void {
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
	private static function runBlast(args:Array<String>):Int {
		var lang:String = 'haxe';
		var flat:Bool = false;
		var limit:Int = -1;
		var showAll:Bool = false;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '--all':
					showAll = true;
				case '-h', '--help':
					printBlastUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq blast: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null) name = a;
					else inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq blast: missing <type-name> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq blast: missing <file-or-dir-or-glob> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		final typeName:String = name;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final refShape:RefShape = plugin.refShape();
		final typeShape:TypeRefShape = plugin.typeRefShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq blast: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		// Pass 1: learn the type's member names + the spans of its own
		// declaration(s) (to exclude the decl's internals from the
		// heuristic). Walks the value-AST of every file once; cached for
		// pass 2.
		final memberNames:Array<String> = [];
		final declSpans:Array<Span> = [];
		final valueTrees:Array<{path:String, source:String, tree:QueryNode}> = [];
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('blast', plugin.parseFile, path, source, expanded.singleFile);
			if (tree == null) {
				if (expanded.singleFile) return EXIT_RUNTIME;
				continue;
			}
			valueTrees.push({path: path, source: source, tree: tree});
			collectTypeDecl(tree, typeName, memberNames, declSpans);
		}

		var any:Bool = false;

		// Section 1 — type-position references (precise). The header is
		// emitted once, before the first file with a hit.
		var usesHeader:Bool = false;
		for (entry in valueTrees) {
			final typeTree:Null<QueryNode> = parseWalked('blast', plugin.parseFileTypeRefs, entry.path, entry.source, expanded.singleFile);
			if (typeTree == null) continue;
			final hits:Array<UsesHit> = Uses.find(typeName, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!usesHeader) {
				sysPrint('# uses (type positions)\n');
				usesHeader = true;
			}
			sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false, flat));
		}

		// Section 2 — value-binding references (precise).
		var refsHeader:Bool = false;
		for (entry in valueTrees) {
			final hits:Array<RefHit> = Refs.find(typeName, entry.tree, refShape);
			if (hits.length == 0) continue;
			any = true;
			if (!refsHeader) {
				sysPrint('# refs (value bindings)\n');
				refsHeader = true;
			}
			sysPrint(Text.renderRefs(entry.path, entry.source, hits, false, false, flat));
		}

		// Section 3 — heuristic member-name field-access (superset).
		if (memberNames.length == 0) {
			stderr('apq blast: no declaration of "$typeName" in the scanned set — '
				+ 'heuristic field-access section skipped (uses/refs above are complete).\n');
			if (!any) stderr('apq blast: no uses / refs of "$typeName" found\n');
			return EXIT_OK;
		}
		final heur:Array<{loc:String, line:String}> = [];
		for (entry in valueTrees)
			collectMemberAccess(entry.tree, memberNames, declSpans, entry.path, entry.source, heur);
		if (heur.length > 0) {
			// Smart-default cap on the heuristic section — the typical
			// transcript pain is `blast` flooding hundreds of `.member`
			// lines when the type's member names are common identifiers
			// (`.name`, `.type`, `.value`). Without `--limit` the
			// heuristic now caps at HEUR_DEFAULT_CAP and prints a hint
			// pointing at `--all` (no cap) or `--limit N` (explicit).
			// Precise `uses` / `refs` sections above stay uncapped — they
			// are name-bound and rarely flood.
			final defaultCap:Int = showAll ? -1 : HEUR_DEFAULT_CAP;
			final effectiveLimit:Int = limit >= 0 ? limit : defaultCap;
			final capped:Array<{loc:String, line:String}> = (effectiveLimit >= 0 && heur.length > effectiveLimit)
				? heur.slice(0, effectiveLimit) : heur;
			final hint:String = (capped.length < heur.length)
				? (limit >= 0
					? ''
					: ' — pass --all to show all, --limit N for explicit cap')
				: '';
			sysPrint('# heuristic field-access (member-name superset of "$typeName" — VERIFY each; '
				+ 'name-based, over-matches; ${capped.length}/${heur.length} shown$hint)\n');
			for (h in capped) sysPrint('${h.line}\n');
			any = true;
		}

		if (!any) stderr('apq blast: no uses / refs / member-access of "$typeName" found\n');
		return EXIT_OK;
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
	private static function runMentions(args:Array<String>):Int {
		var lang:String = 'haxe';
		var flat:Bool = false;
		var limit:Int = -1;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
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
					if (name == null) name = a;
					else inputSpecs.push(a);
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
		final target:String = name;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final refShape:RefShape = plugin.refShape();
		final typeShape:TypeRefShape = plugin.typeRefShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq mentions: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		// Single value-AST pass per file, shared across all three sections.
		// Mirrors `runBlast`'s caching discipline.
		final valueTrees:Array<{path:String, source:String, tree:QueryNode}> = [];
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('mentions', plugin.parseFile, path, source, expanded.singleFile);
			if (tree == null) {
				if (expanded.singleFile) return EXIT_RUNTIME;
				continue;
			}
			valueTrees.push({path: path, source: source, tree: tree});
		}

		var any:Bool = false;

		// Section 1 — type-position references (precise).
		var usesHeader:Bool = false;
		for (entry in valueTrees) {
			final typeTree:Null<QueryNode> = parseWalked('mentions', plugin.parseFileTypeRefs, entry.path, entry.source, expanded.singleFile);
			if (typeTree == null) continue;
			final hits:Array<UsesHit> = Uses.find(target, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!usesHeader) {
				sysPrint('# uses (type positions)\n');
				usesHeader = true;
			}
			sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false, flat));
		}

		// Section 2 — value-binding references (precise).
		var refsHeader:Bool = false;
		for (entry in valueTrees) {
			final hits:Array<RefHit> = Refs.find(target, entry.tree, refShape);
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
		final litEntries:Array<{file:String, source:String, hits:Array<LitHit>}> = [];
		for (entry in valueTrees) {
			final hits:Array<LitHit> = Lit.find(target, entry.tree, true, null);
			if (hits.length == 0) continue;
			litEntries.push({file: entry.path, source: entry.source, hits: hits});
		}
		if (litEntries.length > 0) {
			any = true;
			final shown:Array<{file:String, source:String, hits:Array<LitHit>}> = limitEntries(litEntries, limit,
				e -> e.hits.length,
				(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
			sysPrint('# lit (every leaf — case-patterns / imports / new exprs / field-name slots)\n');
			for (entry in shown) sysPrint(Lit.render(entry.file, entry.source, entry.hits, flat));
		}

		if (!any) stderr('apq mentions: no uses / refs / lit-leaf of "$target" found\n');
		return EXIT_OK;
	}

	/**
	 * Collect the member names + declaration spans of every top-level
	 * declaration named `typeName` (kind ends in `Decl` — the Haxe
	 * decl-kind convention). `@:meta` / `@:fmt(...)` argument subtrees
	 * are skipped so meta identifiers don't pollute the member set.
	 */
	private static function collectTypeDecl(node:QueryNode, typeName:String, names:Array<String>, declSpans:Array<Span>):Void {
		if (StringTools.endsWith(node.kind, 'Decl') && node.name == typeName) {
			if (node.span != null) declSpans.push(node.span);
			collectMemberNames(node, typeName, names);
			return;
		}
		for (c in node.children) collectTypeDecl(c, typeName, names, declSpans);
	}

	private static function collectMemberNames(node:QueryNode, typeName:String, names:Array<String>):Void {
		if (node.kind == 'Meta' || node.kind == 'MetaCall') return;
		final n:Null<String> = node.name;
		if (n != null && n != typeName && !names.contains(n)) names.push(n);
		for (c in node.children) collectMemberNames(c, typeName, names);
	}

	/**
	 * Walk for `FieldAccess` nodes whose accessed member name is one of
	 * `names`, excluding any inside a declaration-of-type span. Records
	 * a `file:line:col` line per hit.
	 */
	private static function collectMemberAccess(node:QueryNode, names:Array<String>, declSpans:Array<Span>, file:String, source:String, out:Array<{loc:String, line:String}>):Void {
		if (node.kind == 'FieldAccess') {
			final n:Null<String> = node.name;
			final span:Null<Span> = node.span;
			if (n != null && span != null && names.contains(n) && !spanInsideAny(span, declSpans)) {
				final pos:Position = span.lineCol(source);
				final loc:String = '$file:${pos.line}:${pos.col}';
				out.push({loc: loc, line: '$loc: .$n'});
			}
		}
		for (c in node.children) collectMemberAccess(c, names, declSpans, file, source, out);
	}

	private static function spanInsideAny(span:Span, outer:Array<Span>):Bool {
		for (o in outer) if (o.from <= span.from && span.to <= o.to) return true;
		return false;
	}

	private static function argMatches(args:Array<String>, sub:Null<String>):Bool {
		if (sub == null) return true;
		final needle:String = sub;
		for (a in args) if (a.indexOf(needle) >= 0) return true;
		return false;
	}

	private static inline function kindAllowed(k:RefKind, decls:Bool, reads:Bool, writes:Bool):Bool {
		return switch k {
			case Decl: decls;
			case Read: reads;
			case Write: writes;
		}
	}

	private static function runSearch(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var kind:Null<String> = null;
		var limit:Int = -1;
		var explain:Bool = false;
		var flat:Bool = false;
		var pattern:Null<String> = null;
		final inputSpecs:Array<String> = [];

		// `--` is the standard end-of-options sentinel: every token after
		// it is positional, never an option. A search pattern can legally
		// start with `--` (`--$x` = prefix-decrement), which would
		// otherwise be rejected as an unknown option — the sentinel is the
		// only way to reach those patterns.
		var optsEnded:Bool = false;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			var isOption:Bool = false;
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
						try limit = parseLimit(args, ++i) catch (e:Exception) {
							stderr('${e.message}\n');
							return EXIT_USAGE;
						}
					case '-h', '--help':
						printSearchUsage();
						return EXIT_OK;
					case '--':
						optsEnded = true;
					case _:
						if (StringTools.startsWith(a, '--')) {
							stderr('apq search: unknown option "$a"\n');
							return EXIT_USAGE;
						}
						isOption = false;
				}
			}
			if (!isOption) {
				if (pattern == null) pattern = a;
				else inputSpecs.push(a);
			}
			i++;
		}
		if (pattern == null) {
			stderr('apq search: missing <pattern> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq search: missing <file-or-dir-or-glob> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		final patternStr:String = pattern;

		// DX v10: macro reification (`$v{...}` / `$i{...}` / `$a{...}` /
		// `$b{...}` / `$p{...}` / `$e{...}` / `$es{...}`) is a Haxe macro-
		// time construct, not an AST shape — the pattern parser rejects it
		// with a generic "not valid as expression" message that sends the
		// user toward search debugging instead of `lit` (the right tool
		// for literal-string lookup, where the macro-time string slot lives).
		// Detect the sigil before parsing and point at the right tool.
		final reif:Null<String> = detectMacroReification(patternStr);
		if (reif != null) {
			stderr('apq search: pattern "$patternStr" contains macro reification ($reif) which is a macro-time construct, not an AST shape pattern. For literal-string lookup use: apq lit \'<text>\' <files>. For identifier shape patterns use a metavar `$$x` (lowercase).\n');
			return EXIT_USAGE;
		}

		final plugin:GrammarPlugin = pickPlugin(lang);
		final parsed:Pattern = try plugin.parsePattern(patternStr)
			catch (e:Exception) {
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
		if (parsed.isDegenerate())
			stderr(degenerateNudge(patternStr, parsed.root.kind) + '\n');

		// `--explain`: emit the parsed pattern's S-expr to stderr at
		// scan start. When 0 matches across all scanned files the
		// closing diagnostic also prints the top input-kind histogram
		// — the most common reason a structurally-valid pattern misses
		// is a kind mismatch (e.g. searching `switch $x { … }` against
		// a tree whose actual kind is `SwitchExpr`, not `Switch`).
		if (explain) {
			stderr('apq search: pattern parses as:\n');
			stderr(Text.render(parsed.root));
		}

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq search: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, matches:Array<Match>}> = [];
		final kindCounts:Map<String, Int> = new Map();
		for (path in paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('search', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			if (explain) tallyKinds(tree, kindCounts);
			final matches:Array<Match> = Matcher.search(parsed, tree, kind);
			if (matches.length == 0) continue;
			allEntries.push({file: path, source: source, matches: matches});
		}

		// `--explain` closing diagnostic on 0 hits: print the kind
		// histogram so the user can see whether the pattern's root
		// kind even appears in the scanned input. The most common
		// mismatch is "pattern parses as Kind X but inputs only
		// expose Kind Y for the same construct" — visible at a
		// glance once both lists are on screen.
		if (explain && allEntries.length == 0) {
			final patternKind:String = parsed.root.kind;
			final entries:Array<{k:String, n:Int}> = [for (k => n in kindCounts) {k: k, n: n}];
			entries.sort((a, b) -> a.n == b.n ? (a.k < b.k ? -1 : 1) : b.n - a.n);
			final topN:Int = entries.length < 12 ? entries.length : 12;
			stderr('apq search: 0 matches; pattern root kind is "$patternKind". Top kinds seen in input (${entries.length} distinct):\n');
			for (k in 0...topN) {
				final e = entries[k];
				final marker:String = e.k == patternKind ? ' ← matches pattern root' : '';
				stderr('  ${e.k} (${e.n})$marker\n');
			}
			if (!Lambda.exists(entries, e -> e.k == patternKind))
				stderr('  (pattern root kind "$patternKind" NOT present in any scanned file — likely the wrong kind for this construct; check `apq ast <file>` to see the actual node shape)\n');
		}

		final shown:Array<{file:String, source:String, matches:Array<Match>}> = limitEntries(allEntries, limit,
			e -> e.matches.length,
			(e, k) -> {file: e.file, source: e.source, matches: e.matches.slice(0, k)});
		if (json) {
			final combined:StringBuf = new StringBuf();
			combined.add('{"matches":[');
			var first:Bool = true;
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
		return EXIT_OK;
	}

	private static function perMatchJson(file:String, source:String, m:Match):String {
		// Render a single match through the macro-generated writer by
		// wrapping it in a singleton envelope, then slicing the inner
		// JSON object out. Keeps every entry typed through the same path
		// as the multi-match render — no separate stringify code.
		final rendered:String = Json.renderSearchMatches(file, source, [m]);
		// Strip the `{"matches":[` prefix and `]}\n` suffix to get the
		// bare match object for inclusion in the multi-file array.
		final inner:String = StringTools.trim(rendered);
		final openIdx:Int = inner.indexOf('[');
		final closeIdx:Int = inner.lastIndexOf(']');
		if (openIdx < 0 || closeIdx <= openIdx) return rendered;
		return inner.substring(openIdx + 1, closeIdx);
	}

	private static function runAst(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var depth:Int = -1;
		var selectExpr:Null<String> = null;
		var atExpr:Null<String> = null;
		var wantDoc:Bool = false;
		var wantSource:Bool = false;
		var writerOutput:Bool = false;
		var writerOutputPlain:Bool = false;
		var writerDiff:Bool = false;
		var minChildren:Int = -1;
		var maxChildren:Int = -1;
		var childrenLimit:Int = -1;
		var spans:Bool = false;
		var countOnly:Bool = false;
		var file:Null<String> = null;
		// Inline source (`apq probe '<code>'` → `--code <s>`) or stdin
		// (`apq ast --stdin`) bypass the file read for micro-probes
		// without a /tmp scratch file. Mutually exclusive with each
		// other and with a file argument; checked after arg parsing.
		var codeArg:Null<String> = null;
		var stdinFlag:Bool = false;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
					final v:String = expectValue(args, ++i, '--depth');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null) {
						stderr('apq ast: --depth expects an integer, got "$v"\n');
						return EXIT_USAGE;
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
					final v:String = expectValue(args, ++i, '--min-children');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --min-children expects a non-negative integer, got "$v"\n');
						return EXIT_USAGE;
					}
					minChildren = parsed;
				case '--max-children':
					final v:String = expectValue(args, ++i, '--max-children');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --max-children expects a non-negative integer, got "$v"\n');
						return EXIT_USAGE;
					}
					maxChildren = parsed;
				case '--children-limit':
					// Cap direct-child count per node in the rendered output
					// (different beast from --max-children: that one FILTERS
					// matches by arity, this one TRUNCATES the printed tree
					// horizontally with an `(... N more)` sentinel). Composes
					// with --depth N for "first N children up to depth M".
					final v:String = expectValue(args, ++i, '--children-limit');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --children-limit expects a non-negative integer, got "$v"\n');
						return EXIT_USAGE;
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
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq ast: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
						// `apq ast <TypeName> <dir>` is a common miss — `ast` is single-
						// file, while `<TypeName> <dir>` is the refs/uses/meta surface.
						// Detect the shape (first arg looks like a TypeName, second arg
						// is an existing directory or .hx file) and route the user.
						final maybeTypeArg:String = file;
						final maybeDirArg:String = a;
						if (looksLikeTypeName(maybeTypeArg) && looksLikePath(maybeDirArg))
							stderr('apq ast: only one file argument supported (got "$maybeTypeArg" and "$maybeDirArg").\n'
								+ '         "$maybeTypeArg" looks like a TypeName and "$maybeDirArg" like a path — `ast` is single-file.\n'
								+ '         For type lookup across a directory:\n'
								+ '           apq refs $maybeTypeArg $maybeDirArg --decls    # value bindings + decl site\n'
								+ '           apq uses $maybeTypeArg $maybeDirArg            # type-position consumers\n'
								+ '           apq blast $maybeTypeArg $maybeDirArg           # full change-impact (uses + refs + field-access)\n'
								+ '           apq meta @:peg $maybeDirArg                    # all PEG decls in scope\n'
								+ '         For a subtree of one file:\n'
								+ '           apq ast <path-to-file.hx> --select Kind:$maybeTypeArg\n');
						else
							stderr('apq ast: only one file argument supported (got "$file" and "$a")\n');
						return EXIT_USAGE;
					}
					file = a;
			}
			i++;
		}

		// Source resolution: --code wins, then --stdin, then the file arg.
		// Exactly one of the three must be set.
		final sourceProvidersSet:Int = (codeArg != null ? 1 : 0) + (stdinFlag ? 1 : 0) + (file != null ? 1 : 0);
		if (sourceProvidersSet == 0) {
			stderr('apq ast: missing <file>, --code <s>, or --stdin\n');
			printAstUsage();
			return EXIT_USAGE;
		}
		if (sourceProvidersSet > 1) {
			stderr('apq ast: <file>, --code, and --stdin are mutually exclusive\n');
			return EXIT_USAGE;
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		final source:String = codeArg != null ? (codeArg : String)
			: stdinFlag ? readStdin()
			: readSourceForParse((file : String));
		// File label drives error / hit-location prefixes — keep it
		// non-null for downstream renderers; <probe> / <stdin> are
		// distinct so a `probe` call still looks like a probe in
		// emitted diff headers and errors.
		final fileLabel:String = codeArg != null ? '<probe>'
			: stdinFlag ? '<stdin>'
			: (file : String);

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
		if (writerOutput) {
			// `.hxtest` section-1 (writer config JSON) auto-applies for
			// the file-path mode — drives `HxModuleWriteOptions` via
			// `HaxeFormatConfigLoader` so a fixture reproduces the corpus
			// harness's writer settings in a single command. `--code` /
			// `--stdin` modes have no path → defaults stay.
			final optsJson:Null<String> = file != null ? readWriteOptionsJsonOrNull((file : String)) : null;
			final emitted:Null<String> = try (writerOutputPlain
				? plugin.writeRoundTripPlain(source, optsJson)
				: plugin.writeRoundTrip(source, optsJson))
			catch (e:ParseError) {
				stderr('apq ast: $fileLabel: ${e.toString()}\n');
				return EXIT_RUNTIME;
			} catch (e:Exception) {
				stderr('apq ast: $fileLabel: ${e.message}\n');
				return EXIT_RUNTIME;
			}
			if (emitted == null) {
				final flagName:String = writerOutputPlain ? '--writer-output-plain' : '--writer-output';
				stderr('apq ast: $flagName: no writer wired up for lang "$lang"\n');
				return EXIT_USAGE;
			}
			if (!writerDiff) {
				sysPrint(emitted);
				return EXIT_OK;
			}
			final emittedSrc:String = emitted;
			final treeIn:QueryNode = try plugin.parseFile(source) catch (e:ParseError) {
				stderr('apq ast: --writer-output --diff: input $fileLabel: ${e.toString()}\n');
				return EXIT_RUNTIME;
			} catch (e:Exception) {
				stderr('apq ast: --writer-output --diff: input $fileLabel: ${e.message}\n');
				return EXIT_RUNTIME;
			}
			final treeOut:QueryNode = try plugin.parseFile(emittedSrc) catch (e:ParseError) {
				stderr('apq ast: --writer-output --diff: writer output failed to re-parse: ${e.toString()}\n');
				stderr('--- writer output ---\n$emittedSrc\n--- end ---\n');
				return EXIT_RUNTIME;
			} catch (e:Exception) {
				stderr('apq ast: --writer-output --diff: writer output failed to re-parse: ${e.message}\n');
				stderr('--- writer output ---\n$emittedSrc\n--- end ---\n');
				return EXIT_RUNTIME;
			}
			final hits:Array<DiffHit> = Diff.diff(treeIn, treeOut);
			sysPrint(Diff.render(fileLabel, source, '<writer-output>', emittedSrc, hits, false));
			return EXIT_OK;
		}
		if (writerDiff) {
			stderr('apq ast: --diff requires --writer-output (it diffs input vs writer-emitted output)\n');
			return EXIT_USAGE;
		}

		final tree:QueryNode = try plugin.parseFile(source) catch (e:ParseError) {
			stderr('apq ast: $fileLabel: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq ast: $fileLabel: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		if (atExpr != null) {
			final colonIdx:Int = atExpr.indexOf(':');
			if (colonIdx < 0) {
				stderr('apq ast: --at expects LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			final atLine:Null<Int> = Std.parseInt(atExpr.substring(0, colonIdx));
			final atCol:Null<Int> = Std.parseInt(atExpr.substring(colonIdx + 1));
			if (atLine == null || atCol == null) {
				stderr('apq ast: --at expects integer LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			// Capture into non-null locals immediately after the null
			// check — Strict narrows locals, not the Null<Int> bindings,
			// and `Span.offsetOf` takes plain Int.
			final atLineN:Int = atLine;
			final atColN:Int = atCol;
			if (atLineN < 1 || atColN < 1) {
				stderr('apq ast: --at expects 1-indexed LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			final offset:Int = Span.offsetOf(source, atLineN, atColN);
			final node:Null<QueryNode> = Engine.at(tree, offset);
			if (countOnly) {
				if (node != null) sysPrint('${node.children.length}\n');
				return EXIT_OK;
			}
			final matches:Array<QueryNode> = node == null ? [] : [shapeAstOutput(node, depth, childrenLimit)];
			sysPrint(json ? Json.renderMatches(fileLabel, source, matches, wantDoc, wantSource) : Text.renderMatches(matches, source, wantDoc, wantSource, spans));
			return EXIT_OK;
		}

		if (selectExpr != null) {
			final selector:Selector = Selector.parse(selectExpr);
			final preFilter:Array<QueryNode> = Engine.select(tree, selector);
			// ω-ast-child-count-filter: post-filter on direct-child count so
			// "find all multi-arg ParamCtor ctors" is one query. The selector
			// grammar (`Kind` / `Kind:name` / `Kind > Child`) is deliberately
			// minimal and stays that way — arity is a numeric predicate, not
			// a structural one, and lives on the CLI instead of the path.
			final raw:Array<QueryNode> = (minChildren < 0 && maxChildren < 0)
				? preFilter
				: [
					for (m in preFilter)
						if ((minChildren < 0 || m.children.length >= minChildren)
							&& (maxChildren < 0 || m.children.length <= maxChildren)) m
				];
			if (raw.length == 0) {
				// Empty `--select` is indistinguishable from "wrong kind
				// name". Kinds are the exact node-constructor names and the
				// engine never enumerates them — so list the kinds actually
				// present in this file, turning a silent miss into a
				// self-correcting hint (no global kind table needed).
				final present:Array<String> = collectKinds(tree);
				final filterParts:Array<String> = [];
				if (minChildren >= 0) filterParts.push('--min-children=$minChildren');
				if (maxChildren >= 0) filterParts.push('--max-children=$maxChildren');
				if (preFilter.length > 0) filterParts.push('${preFilter.length} pre-filter match(es) dropped by child-count');
				final filterNote:String = filterParts.length == 0 ? '' : ' (with ${filterParts.join(", ")})';
				// Kind-fuzzy "did you mean" — surface the closest match in
				// `present` for the first kind segment of `selectExpr`
				// (split on `>`, `:`, whitespace). Same `findFuzzy`
				// substring+Levenshtein two-tier shape as refs/uses on a
				// 0-hit name, so a typo like `--select ParamCtorr` →
				// `Did you mean: ParamCtor?` without re-reading the long
				// `Kinds present here:` list. Silent when nothing close.
				final firstKind:String = extractFirstKindToken(selectExpr);
				final presentMap:Map<String, Bool> = [for (k in present) k => true];
				final suggestions:Array<String> = firstKind.length > 0
					? findFuzzy(firstKind, presentMap)
					: [];
				final fuzzyLine:String = suggestions.length > 0
					? ' Did you mean: ${suggestions.join(", ")}?'
					: '';
				stderr('apq ast: --select "$selectExpr"$filterNote matched no nodes in $fileLabel. '
					+ 'Kinds present here: ${present.join(", ")}.$fuzzyLine '
					+ 'Kinds are exact node-constructor names — run `apq ast $fileLabel` to see the tree.\n');
			}
			if (countOnly) {
				for (m in raw) sysPrint('${m.children.length}\n');
				return EXIT_OK;
			}
			final matches:Array<QueryNode> = [for (m in raw) shapeAstOutput(m, depth, childrenLimit)];
			sysPrint(json ? Json.renderMatches(fileLabel, source, matches, wantDoc, wantSource) : Text.renderMatches(matches, source, wantDoc, wantSource, spans));
			return EXIT_OK;
		}

		if (countOnly) {
			sysPrint('${tree.children.length}\n');
			return EXIT_OK;
		}
		final shaped:QueryNode = shapeAstOutput(tree, depth, childrenLimit);
		sysPrint(json ? Json.renderTree(fileLabel, source, shaped) : Text.render(shaped, spans));
		return EXIT_OK;
	}

	/**
	 * Apply `--depth N` then `--children-limit N` shaping in one place.
	 * Depth truncate first (cheaper — drops sub-trees wholesale), then
	 * per-level child cap on what remains. Both clamps are optional;
	 * negative inputs are no-ops.
	 */
	private static function shapeAstOutput(node:QueryNode, depth:Int, childrenLimit:Int):QueryNode {
		var out:QueryNode = depth < 0 ? node : Engine.truncate(node, depth);
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
	private static function runProbe(args:Array<String>):Int {
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
		var codeArg:Null<String> = null;
		final forwarded:Array<String> = [];
		// `--writer-probe` is a probe-only flag that diverts the source to
		// `runWriterProbe`'s trivia+plain side-by-side emitter instead of
		// the default `runAst` path. Lives here (not in `runAst`'s flag
		// set) because writer-probe is a multi-pipeline aggregator with
		// no `--depth` / `--select` knobs to compose with. `--lang` IS
		// forwarded because `pickPlugin` needs it.
		var writerProbeMode:Bool = false;
		var lang:String = 'haxe';
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
		final codeFinal:String = codeArg;
		if (writerProbeMode) {
			final source:String = codeFinal == '-' ? readStdin() : codeFinal;
			final plugin:GrammarPlugin = pickPlugin(lang);
			// `<probe>` is the synthetic file label — matches the byte
			// shape `apq writer-probe` uses on real files and keeps any
			// downstream error message format consistent.
			final triviaOk:Bool = emitOneWriterProbe(plugin, source, '<probe>', lang, false, null);
			final plainOk:Bool = emitOneWriterProbe(plugin, source, '<probe>', lang, true, null);
			return (triviaOk && plainOk) ? EXIT_OK : EXIT_RUNTIME;
		}
		// `-` is the conventional Unix marker for stdin — route to the
		// shared --stdin path on runAst so probe shares one source loader.
		final injected:Array<String> = codeFinal == '-' ? ['--stdin'] : ['--code', codeFinal];
		return runAst(injected.concat(forwarded));
	}

	/**
	 * Boolean (value-less) `--flag` set for `runAst`. Listed explicitly
	 * so `runProbe`'s argv walker can tell `--depth 5` (consumes 5)
	 * from `--json` (consumes nothing). Stay in sync with the cases
	 * in `runAst` that take no `expectValue` call.
	 */
	private static final AST_BOOL_FLAGS:Array<String> = [
		'--json', '--doc', '--source',
		'--writer-output', '--writer-output-plain',
		'--diff', '--stdin', '--spans',
	];

	private static inline function isAstBoolFlag(flag:String):Bool {
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
	private static function runWriterProbe(args:Array<String>):Int {
		var lang:String = 'haxe';
		var file:Null<String> = null;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
		final fileFinal:String = file;
		final plugin:GrammarPlugin = pickPlugin(lang);
		final source:String = readSourceForParse(fileFinal);
		// `.hxtest` section-1 config drives BOTH labelled probes so the
		// trivia ↔ plain comparison reflects the corpus harness's actual
		// writer surface for this fixture.
		final optsJson:Null<String> = readWriteOptionsJsonOrNull(fileFinal);
		final triviaOk:Bool = emitOneWriterProbe(plugin, source, fileFinal, lang, false, optsJson);
		final plainOk:Bool = emitOneWriterProbe(plugin, source, fileFinal, lang, true, optsJson);
		return (triviaOk && plainOk) ? EXIT_OK : EXIT_RUNTIME;
	}

	private static function emitOneWriterProbe(plugin:GrammarPlugin, source:String, file:String, lang:String, plain:Bool, optsJson:Null<String>):Bool {
		final label:String = plain ? 'plain' : 'trivia';
		sysPrint('=== $label ===\n');
		final emitted:Null<String> = try (plain
			? plugin.writeRoundTripPlain(source, optsJson)
			: plugin.writeRoundTrip(source, optsJson))
		catch (e:ParseError) {
			stderr('apq writer-probe: $label: $file: ${e.toString()}\n');
			return false;
		} catch (e:Exception) {
			stderr('apq writer-probe: $label: $file: ${e.message}\n');
			return false;
		}
		if (emitted == null) {
			final flag:String = plain ? '--writer-output-plain' : '--writer-output';
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

	private static function writerProbeSourcePreservationNote(source:String, emitted:String):Void {
		if (source == emitted) return;
		final minLen:Int = source.length < emitted.length ? source.length : emitted.length;
		var diffAt:Int = minLen;
		for (i in 0...minLen) if (StringTools.fastCodeAt(source, i) != StringTools.fastCodeAt(emitted, i)) {
			diffAt = i;
			break;
		}
		// Show a small window around the divergence on each side so the
		// reader can immediately see the missing/extra bytes without
		// re-running a diff tool.
		final wnd:Int = 8;
		final sFrom:Int = diffAt - wnd >= 0 ? diffAt - wnd : 0;
		final sExp:String = escapeProbeWindow(source.substring(sFrom, diffAt + wnd < source.length ? diffAt + wnd : source.length));
		final sAct:String = escapeProbeWindow(emitted.substring(sFrom, diffAt + wnd < emitted.length ? diffAt + wnd : emitted.length));
		stderr('apq writer-probe: NOTE trivia output differs from source at offset $diffAt (writer-fidelity gap)\n');
		stderr('  source : "$sExp"\n');
		stderr('  emitted: "$sAct"\n');
	}

	private static function escapeProbeWindow(s:String):String {
		final buf:StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, i);
			switch c {
				case '\n'.code: buf.add('\\n');
				case '\t'.code: buf.add('\\t');
				case '\r'.code: buf.add('\\r');
				case '"'.code: buf.add('\\"');
				case _: buf.addChar(c);
			}
		}
		return buf.toString();
	}

	private static function pickPlugin(lang:String):GrammarPlugin {
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
	private static function runRecon(args:Array<String>):Int {
		var lang:String = 'haxe';
		var topN:Int = RECON_TOP_N_DEFAULT;
		var probePath:Null<String> = null;
		var rootDir:Null<String> = null;
		var clusterFilter:Null<String> = null;
		var predictStrip:Bool = false;
		// `--regression-probe`: read the prior sweep snapshot's per-fixture
		// status map (`bin/.last-sweep.json` `fixtures` array) and diff
		// against the current corpus's parse-OK/FAIL state. Surfaces every
		// fixture whose parse status FLIPPED since the snapshot was
		// written. Catches "I edited the grammar, am I breaking anything
		// that was working?" pre-sweep — cheaper than a full corpus rerun
		// because it only does the trivia parse step (no writer / no
		// expected-bytes comparison). Mutually exclusive with --probe /
		// --predict-strip / --cluster (separate diagnostic mode).
		var regressionProbe:Bool = false;
		// `--candidates <regex>`: cross-cluster construct enumeration.
		// Walks the same skip-parse record set as the sweep, applies
		// the EReg against each fixture's source, and prints
		// `<path> :: N matches` for every file with ≥1 hit (sorted by
		// count desc). Closes the gap where the histogram clusters by
		// exact forward-locus, so a construct that lives in different
		// multi-blocker fixtures (Slice 38's `new T<...>(` → 5 surfaced,
		// 6 actually present) is undercounted. Mutually exclusive with
		// --predict-strip / --cluster / --probe / --regression-probe.
		var candidatesRegex:Null<String> = null;
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
		var predictRelax:Bool = false;
		// `--permissive-construct`: field-optionalization predictor.
		// Walks every `mandatory-ref-lead-trail` candidate from
		// `gates --mechanism mandatory-ref-lead-trail` (Slice 40's relax-
		// candidate inventory), strips the bracket-pair `<lead>...<trail>`
		// from each skip-parse fixture, and re-parses. Aggregates
		// UNBLOCK / STILL FAIL / NO MATCH per candidate so the user sees
		// which field-optionalization would unblock which fixtures
		// BEFORE committing to a Slice 40-style edit. Mutex with every
		// other recon mode — it's its own pipeline.
		var permissiveConstruct:Bool = false;
		// `--source`: drill-mode-only flag. When set in combination with
		// `--cluster <key>`, the per-path output gains a windowed source
		// snippet centred on the fail-locus. Outside drill it would
		// flood every SKIP line; usage error guards that.
		var showSource:Bool = false;
		// Twin of `runStrip`'s arg-parsing: --replace X --with Y pairs
		// plus --delete X shortcut. Patterns and replacements arrays
		// stay aligned by construction. Active only with --predict-strip.
		final patterns:Array<String> = [];
		final replacements:Array<String> = [];
		var pendingReplace:Null<String> = null;
		// --regex: same semantics as `apq strip --regex` — treat every
		// --replace / --delete pattern as an EReg pattern. Lets one
		// predict-strip call cover every site of a construct in the
		// corpus (e.g. `new [A-Z]\w*<[^>]+>\(` matches every templated
		// constructor call, not just one literal pair) — closes the
		// pain where Slice 38's recon under-counted because the
		// histogram clusters by exact forward-locus shape.
		var regexMode:Bool = false;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--top':
					final v:Null<Int> = Std.parseInt(expectValue(args, ++i, '--top'));
					if (v == null || v <= 0) {
						stderr('apq recon: --top requires a positive integer\n');
						return EXIT_USAGE;
					}
					topN = v;
				case '--all':
					topN = 0x7fffffff;
				case '--probe':
					probePath = expectValue(args, ++i, '--probe');
				case '--cluster':
					clusterFilter = expectValue(args, ++i, '--cluster');
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
						return EXIT_USAGE;
					}
					pendingReplace = expectValue(args, ++i, '--replace');
				case '--with':
					if (pendingReplace == null) {
						stderr('apq recon: --with requires a preceding --replace\n');
						return EXIT_USAGE;
					}
					patterns.push(pendingReplace);
					replacements.push(expectValue(args, ++i, '--with'));
					pendingReplace = null;
				case '--delete':
					if (pendingReplace != null) {
						stderr('apq recon: --replace "$pendingReplace" needs a --with before --delete\n');
						return EXIT_USAGE;
					}
					patterns.push(expectValue(args, ++i, '--delete'));
					replacements.push('');
				case '--regex':
					regexMode = true;
				case '-h', '--help':
					printReconUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq recon: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (rootDir != null) {
						stderr('apq recon: only one positional <dir> argument supported (got "$rootDir" and "$a")\n');
						return EXIT_USAGE;
					}
					rootDir = a;
			}
			i++;
		}
		if (pendingReplace != null) {
			stderr('apq recon: --replace "$pendingReplace" needs a --with\n');
			return EXIT_USAGE;
		}
		if (predictStrip && patterns.length == 0) {
			stderr('apq recon: --predict-strip requires at least one --replace/--with or --delete\n');
			return EXIT_USAGE;
		}
		if (!predictStrip && patterns.length > 0) {
			stderr('apq recon: --replace/--with/--delete require --predict-strip\n');
			return EXIT_USAGE;
		}
		if (regexMode && !predictStrip) {
			stderr('apq recon: --regex requires --predict-strip (regex applies to --replace patterns)\n');
			return EXIT_USAGE;
		}
		final compiledRegex:Null<Array<EReg>> = regexMode ? compileStripRegexes('recon', patterns) : null;
		if (regexMode && compiledRegex == null) return EXIT_USAGE;
		// `--source` is meaningful only in modes where the per-path window
		// adds signal — `--cluster <key>` drill OR `--predict-strip`
		// STILL FAIL entries (where the new locus is the actionable
		// payload). In plain sweep mode it would flood every SKIP line
		// with a per-fixture window, so make the misuse a hard usage
		// error rather than a silent no-op.
		if (showSource && clusterFilter == null && !predictStrip) {
			stderr('apq recon: --source requires --cluster <key> or --predict-strip (drill / STILL-FAIL modes only; would flood the sweep otherwise)\n');
			return EXIT_USAGE;
		}
		// `--regression-probe` is its own mode — separate from probe /
		// predict / cluster / source. Reject the combinations with a clear
		// usage error instead of silently picking one path.
		if (regressionProbe) {
			if (probePath != null) {
				stderr('apq recon: --regression-probe and --probe are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (predictStrip) {
				stderr('apq recon: --regression-probe and --predict-strip are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (clusterFilter != null) {
				stderr('apq recon: --regression-probe and --cluster are mutually exclusive\n');
				return EXIT_USAGE;
			}
		}
		if (candidatesRegex != null) {
			if (probePath != null || predictStrip || clusterFilter != null || regressionProbe || predictRelax) {
				stderr('apq recon: --candidates is mutually exclusive with --probe / --predict-strip / --cluster / --regression-probe / --predict-relax\n');
				return EXIT_USAGE;
			}
		}
		if (predictRelax) {
			if (predictStrip) {
				stderr('apq recon: --predict-relax and --predict-strip are mutually exclusive (opposite models — strip removes tokens, relax inserts the expected one)\n');
				return EXIT_USAGE;
			}
			if (regressionProbe) {
				stderr('apq recon: --predict-relax and --regression-probe are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (patterns.length > 0) {
				stderr('apq recon: --predict-relax does not take --replace/--with/--delete (the injected token comes from the parser`s `expected` hint)\n');
				return EXIT_USAGE;
			}
		}
		if (permissiveConstruct) {
			if (probePath != null || predictStrip || predictRelax || regressionProbe || clusterFilter != null
				|| candidatesRegex != null || patterns.length > 0) {
				stderr('apq recon: --permissive-construct is its own mode — mutually exclusive with --probe / --predict-strip / --predict-relax / --regression-probe / --cluster / --candidates / --replace/--with/--delete\n');
				return EXIT_USAGE;
			}
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		if (predictRelax && probePath != null) return runReconProbeRelax(plugin, (probePath : String), showSource);
		if (probePath != null) return runReconProbe(plugin, (probePath : String), predictStrip, patterns, replacements, compiledRegex, showSource);
		final rootFinal:String = rootDir ?? defaultReconRoot();
		if (rootFinal == '') {
			stderr("apq recon: no <dir> given and $ANYPARSE_HXFORMAT_FORK env var is unset.\n");
			stderr('  Either pass a directory:  apq recon /path/to/corpus\n');
			stderr('  or export the fork root:  ANYPARSE_HXFORMAT_FORK=/path/to/haxe-formatter\n');
			return EXIT_USAGE;
		}
		if (!FileSystem.exists(rootFinal) || !FileSystem.isDirectory(rootFinal)) {
			stderr('apq recon: "$rootFinal" is not a directory.\n');
			return EXIT_RUNTIME;
		}
		if (regressionProbe) return runReconRegressionProbe(plugin, rootFinal);
		if (candidatesRegex != null) return runReconCandidates(plugin, rootFinal, (candidatesRegex : String));
		if (permissiveConstruct) return runReconPermissive(plugin, rootFinal, lang);
		if (predictRelax) return runReconSweepRelax(plugin, rootFinal, clusterFilter, showSource);
		return runReconSweep(plugin, rootFinal, topN, clusterFilter, predictStrip, patterns, replacements, compiledRegex, showSource);
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
	private static function runReconProbeRelax(plugin:GrammarPlugin, path:String, showSource:Bool):Int {
		final original:String = readSourceForParse(path);
		final res:PredictRelaxResult = tryPredictRelax(plugin, original);
		return reportPredictRelax(path, original, res, showSource);
	}

	/**
	 * Sweep-mode predict-relax. Walks every skip-parse fixture under
	 * `root`, runs `tryPredictRelax`, prints per-file outcome plus a
	 * summary `--- relax: K unblock, M still fail, P no target ---`.
	 * Filtered by `--cluster <key>` when set (same exact-match key
	 * semantics as predict-strip).
	 */
	private static function runReconSweepRelax(plugin:GrammarPlugin, root:String, clusterFilter:Null<String>, showSource:Bool):Int {
		final walk:ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		var records:Array<ReconRecord> = walk.records;
		if (clusterFilter != null) {
			final filter:String = clusterFilter;
			records = records.filter(r -> r.clusterKey == filter);
			if (records.length == 0) {
				stderr('apq recon: --cluster "$filter" matched no skip-parse records (predict-relax mode)\n');
				return EXIT_RUNTIME;
			}
		}
		var unblockCount:Int = 0;
		var stillFailCount:Int = 0;
		var noTargetCount:Int = 0;
		// Cluster scope (`--cluster <key>`) means the user already narrowed
		// to a handful of fixtures and likely wants per-file NO TARGET lines
		// for inspection. Full-sweep scope dumps tens of NO TARGET lines that
		// are mostly cond-comp `//` catch-all noise — collapse those by
		// `expected` message into a footer histogram, keep UNBLOCK / STILL
		// FAIL per-file (low count, actionable).
		final keepNoTargetPerFile:Bool = clusterFilter != null;
		final noTargetReasons:Array<{key:String, count:Int}> = [];
		for (r in records) {
			final res:PredictRelaxResult = tryPredictRelax(plugin, r.source);
			switch res.kind {
				case Unblock:
					reportPredictRelax(r.path, r.source, res, showSource);
					unblockCount++;
				case StillFail:
					reportPredictRelax(r.path, r.source, res, showSource);
					stillFailCount++;
				case NoTarget:
					if (keepNoTargetPerFile) {
						reportPredictRelax(r.path, r.source, res, showSource);
					} else {
						final reason:String = res.message;
						var hit:Null<{key:String, count:Int}> = null;
						for (e in noTargetReasons) if (e.key == reason) { hit = e; break; }
						if (hit == null)
							noTargetReasons.push({key: reason, count: 1});
						else
							hit.count++;
					}
					noTargetCount++;
			}
		}
		sysPrint('--- relax: $unblockCount unblock, $stillFailCount still fail, $noTargetCount no target (of ${records.length} skip-parse files) ---\n');
		if (!keepNoTargetPerFile && noTargetReasons.length > 0) {
			noTargetReasons.sort((a, b) -> b.count - a.count);
			sysPrint('   no target breakdown (use --cluster <key> to drill into a specific shape):\n');
			for (entry in noTargetReasons)
				sysPrint('     ${entry.count}× ${entry.key}\n');
		}
		return EXIT_OK;
	}

	/**
	 * Run a single predict-relax probe on `source`. Returns one of the
	 * three result kinds with the patched source / new locus / injected
	 * token packed inside for the reporter to render.
	 */
	private static function tryPredictRelax(plugin:GrammarPlugin, source:String):PredictRelaxResult {
		var origLine:Int = 0;
		var origCol:Int = 0;
		var injected:Null<String> = null;
		var insertAt:Int = -1;
		try {
			plugin.reconParse(source);
			// Already-parseable file given to predict-relax. Not an
			// error — could be a `--probe` call on a fixture that
			// landed after a recent slice. Surface as NoTarget with a
			// distinct message so the user knows.
			return {kind: NoTarget, original: source, patched: source, injected: '', origLine: 0, origCol: 0, newLine: 0, newCol: 0, message: 'source already parses (no relaxation needed)'};
		} catch (pe:ParseError) {
			final pos:Position = pe.span.lineCol(source);
			origLine = pos.line;
			origCol = pos.col;
			final expected:Null<String> = pe.expected;
			if (expected == null) {
				return {kind: NoTarget, original: source, patched: source, injected: '', origLine: origLine, origCol: origCol, newLine: 0, newCol: 0, message: pe.message};
			}
			injected = stripExpectedHint((expected : String));
			insertAt = pe.span.from;
		} catch (e:Exception) {
			return {kind: NoTarget, original: source, patched: source, injected: '', origLine: 0, origCol: 0, newLine: 0, newCol: 0, message: e.message};
		}
		if (injected == null || injected.length == 0 || insertAt < 0) {
			return {kind: NoTarget, original: source, patched: source, injected: '', origLine: origLine, origCol: origCol, newLine: 0, newCol: 0, message: 'expected hint is empty after quote-strip'};
		}
		final injectedFinal:String = injected;
		final patched:String = source.substr(0, insertAt) + injectedFinal + source.substr(insertAt);
		try {
			plugin.reconParse(patched);
			return {kind: Unblock, original: source, patched: patched, injected: injectedFinal, origLine: origLine, origCol: origCol, newLine: 0, newCol: 0, message: ''};
		} catch (pe2:ParseError) {
			final pos2:Position = pe2.span.lineCol(patched);
			return {kind: StillFail, original: source, patched: patched, injected: injectedFinal, origLine: origLine, origCol: origCol, newLine: pos2.line, newCol: pos2.col, message: pe2.message};
		} catch (e:Exception) {
			return {kind: StillFail, original: source, patched: patched, injected: injectedFinal, origLine: origLine, origCol: origCol, newLine: 0, newCol: 0, message: e.message};
		}
	}

	private static function reportPredictRelax(path:String, original:String, res:PredictRelaxResult, showSource:Bool):Int {
		switch res.kind {
			case Unblock:
				sysPrint('PREDICT RELAX UNBLOCK   $path :: inserting "${res.injected}" at ${res.origLine}:${res.origCol} unblocks parse\n');
				return EXIT_OK;
			case StillFail:
				final movedHint:String = movedLocusHint(res.origLine, res.origCol, res.newLine, res.newCol);
				sysPrint('PREDICT RELAX STILL FAIL $path :: ${res.newLine}:${res.newCol}${movedHint} after inserting "${res.injected}" — ${res.message}\n');
				if (showSource && res.newLine > 0) printReconSourceWindow(res.patched, res.newLine);
				return EXIT_RUNTIME;
			case NoTarget:
				sysPrint('PREDICT RELAX NO TARGET $path :: at ${res.origLine}:${res.origCol} — ${res.message}\n');
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
	private static function stripExpectedHint(hint:String):String {
		final t:String = StringTools.trim(hint);
		if (t.length == 0) return t;
		// `"<x>"` or `'<x>'` form.
		if (t.length >= 2) {
			final first:String = t.charAt(0);
			final last:String = t.charAt(t.length - 1);
			if ((first == '"' && last == '"') || (first == "'" && last == "'"))
				return t.substring(1, t.length - 1);
		}
		// `//` is the canonical "comment or end" marker the parser
		// emits when it ran out of brace-/Star-terminating options. No
		// token to inject — return empty so the caller routes to
		// NO TARGET.
		if (t == '//' || t == '<no message>') return '';
		return t;
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
	private static function runReconCandidates(plugin:GrammarPlugin, root:String, pattern:String):Int {
		final re:EReg = try new EReg(pattern, 'g') catch (e:Exception) {
			stderr('apq recon: --candidates: pattern "$pattern" is not a valid EReg: ${e.message}\n');
			return EXIT_USAGE;
		}
		final walk:ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: --candidates: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final hits:Array<{path:String, count:Int}> = [];
		var totalHits:Int = 0;
		for (r in walk.records) {
			final n:Int = countRegexHits(re, r.source);
			if (n > 0) {
				hits.push({path: r.path, count: n});
				totalHits += n;
			}
		}
		hits.sort((a, b) -> b.count - a.count);
		for (h in hits) sysPrint('${h.path} :: ${h.count} match${h.count == 1 ? '' : 'es'}\n');
		sysPrint('--- candidates: ${hits.length} file${hits.length == 1 ? '' : 's'} matched ($totalHits total hit${totalHits == 1 ? '' : 's'} across ${walk.records.length} skip-parse file${walk.records.length == 1 ? '' : 's'}) ---\n');
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
	private static function runReconPermissive(plugin:GrammarPlugin, root:String, lang:String):Int {
		final walk:ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: --permissive-construct: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final records:Array<ReconRecord> = walk.records;
		final candidates:Array<PermissiveCandidate> = collectPermissiveCandidates(plugin, lang);
		if (candidates.length == 0) {
			stderr('apq recon: --permissive-construct: no mandatory-ref-lead-trail candidates found in src/anyparse/grammar/$lang/ (cross-check with `apq gates --mechanism mandatory-ref-lead-trail`)\n');
			return EXIT_RUNTIME;
		}
		sysPrint('=== permissive-construct: ${candidates.length} candidate${candidates.length == 1 ? '' : 's'} from gates --mechanism mandatory-ref-lead-trail, ${records.length} skip-parse fixture${records.length == 1 ? '' : 's'} ===\n');
		var totalUnblocks:Int = 0;
		var candidatesWithSignal:Int = 0;
		final noSignalLabels:Array<String> = [];
		for (cand in candidates) {
			final unblocks:Array<String> = [];
			final stillFails:Array<String> = [];
			var noMatchCount:Int = 0;
			for (r in records) {
				final stripped:StripResult = stripBalancedPairs(r.source, cand.lead, cand.trail);
				if (stripped.count == 0) {
					noMatchCount++;
					continue;
				}
				final ok:Bool = try plugin.reconParse(stripped.out) catch (exception:Exception) false;
				if (ok) unblocks.push(r.path);
				else stillFails.push(r.path);
			}
			final nameSuffix:String = cand.declName != null ? ' ${cand.declName}' : '';
			final label:String = '${cand.file}:${cand.line}: ${cand.declKind}$nameSuffix @:lead(\'${cand.lead}\') @:trail(\'${cand.trail}\')';
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
		sysPrint('\n--- permissive-construct summary: $candidatesWithSignal of ${candidates.length} candidate${candidates.length == 1 ? '' : 's'} have ≥1 UNBLOCK or STILL FAIL ($totalUnblocks UNBLOCK${totalUnblocks == 1 ? '' : 's'} total) across ${records.length} skip-parse files ---\n');
		if (noSignalLabels.length > 0) {
			sysPrint('--- NO MATCH only (${noSignalLabels.length} candidate${noSignalLabels.length == 1 ? '' : 's'} with no fixture match) ---\n');
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
	private static function collectPermissiveCandidates(plugin:GrammarPlugin, lang:String):Array<PermissiveCandidate> {
		final out:Array<PermissiveCandidate> = [];
		final grammarDir:String = 'src/anyparse/grammar/$lang/';
		if (!FileSystem.exists(grammarDir) || !FileSystem.isDirectory(grammarDir)) return out;
		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs([grammarDir], '.hx');
		final shape:MetaShape = plugin.metaShape();
		final skipEntries:Array<SkipEntry> = [];
		for (path in expanded.paths) {
			final source:String = readSourceForParse(path);
			final tree:Null<QueryNode> = parseWalked('recon', plugin.parseFile, path, source, false, skipEntries);
			if (tree == null) continue;
			final raw:Array<MetaHit> = Meta.find(tree, shape, source);
			final grouped:{order:Array<Int>, groups:Map<Int, Array<MetaHit>>} = groupMetaHitsByDeclSpan(raw);
			for (key in grouped.order) {
				final metas:Null<Array<MetaHit>> = grouped.groups[key];
				if (metas == null) continue;
				var hasOptional:Bool = false;
				var lead:Null<String> = null;
				var trail:Null<String> = null;
				var sep:Null<String> = null;
				for (h in metas) switch h.annotation {
					case '@:optional': hasOptional = true;
					case '@:lead': lead = h.args.length > 0 ? stripQuotes(h.args[0]) : null;
					case '@:trail': trail = h.args.length > 0 ? stripQuotes(h.args[0]) : null;
					case '@:sep': sep = h.args.length > 0 ? h.args[0] : null;
					case _:
				}
				if (hasOptional || lead == null || trail == null || sep != null) continue;
				final leadStr:String = (lead : String);
				final trailStr:String = (trail : String);
				// Skip macro/string delimiters — their @:optional
				// relaxation isn't the Slice 40 mechanism (interpolation,
				// string body, etc.).
				if (leadStr.length != 1 || trailStr.length != 1) continue;
				if (leadStr == '"' || leadStr == "'") continue;
				if (leadStr == '$') continue;
				final first:MetaHit = metas[0];
				final fspan:Null<Span> = first.declSpan;
				final pos:Null<Position> = fspan != null ? fspan.lineCol(source) : null;
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
	private static function stripBalancedPairs(source:String, lead:String, trail:String):StripResult {
		if (lead.length != 1 || trail.length != 1) return {out: source, count: 0};
		final leadCode:Int = StringTools.fastCodeAt(lead, 0);
		final trailCode:Int = StringTools.fastCodeAt(trail, 0);
		final isSymmetric:Bool = isBracketOpener(leadCode);
		final buf:StringBuf = new StringBuf();
		var i:Int = 0;
		var count:Int = 0;
		while (i < source.length) {
			final triviaEnd:Int = skipStringOrComment(source, i);
			if (triviaEnd > i) {
				buf.addSub(source, i, triviaEnd - i);
				i = triviaEnd;
				continue;
			}
			final c:Int = StringTools.fastCodeAt(source, i);
			if (c == leadCode) {
				final endIdx:Int = findPairEnd(source, i + 1, leadCode, trailCode, isSymmetric);
				if (endIdx >= 0) {
					count++;
					i = endIdx;
					continue;
				}
			}
			buf.addChar(c);
			i++;
		}
		return {out: buf.toString(), count: count};
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
	private static function findPairEnd(source:String, startIdx:Int, leadCode:Int, trailCode:Int, isSymmetric:Bool):Int {
		var i:Int = startIdx;
		var depth:Int = isSymmetric ? 1 : 0;
		while (i < source.length) {
			final triviaEnd:Int = skipStringOrComment(source, i);
			if (triviaEnd > i) {
				i = triviaEnd;
				continue;
			}
			final c:Int = StringTools.fastCodeAt(source, i);
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

	private static inline function isBracketOpener(c:Int):Bool {
		return c == '('.code || c == '{'.code || c == '['.code;
	}

	private static inline function isBracketCloser(c:Int):Bool {
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
	private static function skipStringOrComment(source:String, i:Int):Int {
		if (i >= source.length) return i;
		final c:Int = StringTools.fastCodeAt(source, i);
		if (c == '/'.code && i + 1 < source.length) {
			final c2:Int = StringTools.fastCodeAt(source, i + 1);
			if (c2 == '/'.code) {
				var j:Int = i + 2;
				while (j < source.length && StringTools.fastCodeAt(source, j) != '\n'.code) j++;
				return j;
			}
			if (c2 == '*'.code) {
				var j:Int = i + 2;
				while (j + 1 < source.length) {
					if (StringTools.fastCodeAt(source, j) == '*'.code
						&& StringTools.fastCodeAt(source, j + 1) == '/'.code)
						return j + 2;
					j++;
				}
				return source.length;
			}
		}
		if (c == '"'.code || c == "'".code) {
			var j:Int = i + 1;
			while (j < source.length) {
				final cj:Int = StringTools.fastCodeAt(source, j);
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
	private static function runReconRegressionProbe(plugin:GrammarPlugin, root:String):Int {
		// Load the prior snapshot. Missing / unreadable / malformed JSON
		// is a non-fatal "no baseline" — print a single info line and
		// exit OK so a fresh checkout doesn't fail the probe.
		final snapshotPath:String = 'bin/.last-sweep.json';
		if (!FileSystem.exists(snapshotPath)) {
			sysPrint('apq recon: no prior sweep snapshot at $snapshotPath — run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK first to seed the baseline\n');
			return EXIT_OK;
		}
		final prior:Map<String, String> = loadSweepFixtureStatus(snapshotPath);
		if (prior.iterator().hasNext() == false) {
			sysPrint('apq recon: snapshot at $snapshotPath has no `fixtures` array — older format, re-run `node bin/test.js` to refresh the baseline\n');
			return EXIT_OK;
		}
		// Walk the current corpus and bucket each fixture as
		// PARSE_OK or SKIP_PARSE. Reused machinery from `collectReconSkipRecords`
		// — but we also need the OK list (which `collectReconSkipRecords`
		// drops), so walk again with a simpler shape.
		var regressed:Int = 0;
		var unblocked:Int = 0;
		var scanned:Int = 0;
		final stack:Array<String> = [root];
		while (stack.length > 0) {
			final dir:Null<String> = stack.pop();
			if (dir == null) break;
			final names:Array<String> = FileSystem.readDirectory(dir);
			names.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) {
				final path:String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!StringTools.endsWith(name, '.hxtest')) continue;
				final relPath:String = stripRootPrefix(path, root);
				final priorStatus:Null<String> = prior[relPath];
				if (priorStatus == null) continue; // present locally but absent from snapshot — silent
				scanned++;
				final source:String = readSourceForParse(path);
				var currentParseOk:Bool = false;
				var currentLine:Int = 0;
				var currentCol:Int = 0;
				var currentMsg:String = '';
				try {
					if (!plugin.reconParse(source)) {
						stderr('apq recon: no recon parser wired up for this grammar plugin\n');
						return EXIT_RUNTIME;
					}
					currentParseOk = true;
				} catch (exception:ParseError) {
					final pos:Position = exception.span.lineCol(source);
					currentLine = pos.line;
					currentCol = pos.col;
					currentMsg = reconNormalize(exception.expected);
				} catch (exception:Exception) {
					currentMsg = reconNormalize(exception.message);
				}
				final priorParsed:Bool = priorStatus == 'PASS' || priorStatus == 'FAIL' || priorStatus == 'SKIP_WRITE';
				final priorSkipParse:Bool = priorStatus == 'SKIP_PARSE';
				if (priorParsed && !currentParseOk) {
					regressed++;
					final locus:String = currentLine > 0 ? ' :: $currentLine:$currentCol expected="$currentMsg"' : ' :: $currentMsg';
					sysPrint('REGRESSED $relPath: was $priorStatus, now SKIP_PARSE$locus\n');
				} else if (priorSkipParse && currentParseOk) {
					unblocked++;
					sysPrint('UNBLOCKED $relPath: was SKIP_PARSE, now parses OK\n');
				}
				// SKIP_CONFIG / MALFORMED in prior: orthogonal to grammar; silent.
				// No flip: silent.
			}
		}
		sysPrint('--- regression-probe: $regressed regressed, $unblocked unblocked, $scanned scanned vs snapshot ---\n');
		return regressed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * Read `bin/.last-sweep.json`'s `fixtures` array (written by
	 * `HxFormatterCorpusTest.printSweepDelta`) into a `path → status`
	 * map. Returns an empty map on any parse / shape failure so the
	 * caller can fail-soft with a "no baseline" diagnostic instead of
	 * crashing on a malformed snapshot.
	 */
	private static function loadSweepFixtureStatus(path:String):Map<String, String> {
		final out:Map<String, String> = [];
		try {
			final raw:String = sys.io.File.getContent(path);
			final obj:Dynamic = haxe.Json.parse(raw);
			if (!Reflect.hasField(obj, 'fixtures')) return out;
			final fixtures:Dynamic = Reflect.field(obj, 'fixtures');
			if (!Std.isOfType(fixtures, Array)) return out;
			final arr:Array<Dynamic> = (fixtures : Array<Dynamic>);
			for (entry in arr) {
				final entryPath:Null<Dynamic> = Reflect.field(entry, 'path');
				final entryStatus:Null<Dynamic> = Reflect.field(entry, 'status');
				if (entryPath != null && entryStatus != null
					&& Std.isOfType(entryPath, String) && Std.isOfType(entryStatus, String)) {
					// Normalise snapshot path to match what
					// `stripRootPrefix` emits for the recon walker. The
					// corpus harness records paths as
					// `test/testcases/<subdir>/<name>` (rooted at the fork);
					// recon walks from `<fork>/test/testcases` so its
					// stripped paths are `<subdir>/<name>`. Trim the leading
					// `test/testcases/` here so the diff lookup is keyed
					// the same way on both sides.
					final raw:String = (entryPath : String);
					final corpusPrefix:String = 'test/testcases/';
					final normalised:String = StringTools.startsWith(raw, corpusPrefix)
						? raw.substr(corpusPrefix.length)
						: raw;
					out[normalised] = (entryStatus : String);
				}
			}
		} catch (_:Exception) {}
		return out;
	}

	private static function runReconProbe(
		plugin:GrammarPlugin, path:String,
		predictStrip:Bool, patterns:Array<String>, replacements:Array<String>,
		compiledRegex:Null<Array<EReg>>, showSource:Bool
	):Int {
		if (!FileSystem.exists(path)) {
			stderr('apq recon: --probe path "$path" does not exist\n');
			return EXIT_RUNTIME;
		}
		final original:String = readSourceForParse(path);
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
			return EXIT_OK;
		} catch (exception:ParseError) {
			final pos:Position = exception.span.lineCol(original);
			final exp:String = reconNormalize(exception.expected);
			final snip:String = reconNormalize(reconSnippet(original, exception.span.from));
			sysPrint('PARSE FAIL :: ${pos.line}:${pos.col} expected="$exp" :: src="$snip"\n');
			return EXIT_RUNTIME;
		} catch (exception:Exception) {
			sysPrint('PARSE FAIL :: <non-ParseError> ${reconNormalize(exception.message)}\n');
			return EXIT_RUNTIME;
		}
	}

	private static function runReconProbePredict(
		plugin:GrammarPlugin, path:String, original:String,
		patterns:Array<String>, replacements:Array<String>,
		compiledRegex:Null<Array<EReg>>, showSource:Bool
	):Int {
		// Capture the original fail-locus first so STILL FAIL can report
		// the moved-locus hint (same signal as sweep-mode predict-strip).
		var origLine:Int = 0;
		var origCol:Int = 0;
		try {
			plugin.reconParse(original);
		} catch (pe:ParseError) {
			final pos:Position = pe.span.lineCol(original);
			origLine = pos.line;
			origCol = pos.col;
		} catch (_:Exception) {}
		final regexMode:Bool = compiledRegex != null;
		final regexes:Array<EReg> = compiledRegex ?? [];
		final patternHits:Array<Int> = [for (_ in 0...patterns.length) 0];
		var stripped:String = original;
		var fileHits:Int = 0;
		for (idx in 0...patterns.length) {
			final hits:Int = regexMode
				? countRegexHits(regexes[idx], stripped)
				: countOccurrences(stripped, patterns[idx]);
			patternHits[idx] = hits;
			fileHits += hits;
			stripped = regexMode
				? regexes[idx].replace(stripped, replacements[idx])
				: StringTools.replace(stripped, patterns[idx], replacements[idx]);
		}
		var exitCode:Int = EXIT_OK;
		if (fileHits == 0) {
			sysPrint('PREDICT NO MATCH  $path\n');
		} else {
			try {
				if (!plugin.reconParse(stripped)) {
					stderr('apq recon: no recon parser wired up for this grammar plugin\n');
					return EXIT_RUNTIME;
				}
				sysPrint('PREDICT UNBLOCK   $path\n');
			} catch (pe:ParseError) {
				final pos:Position = pe.span.lineCol(stripped);
				final movedHint:String = movedLocusHint(origLine, origCol, pos.line, pos.col);
				sysPrint('PREDICT STILL FAIL $path :: ${pos.line}:${pos.col}${movedHint} ${pe.message}\n');
				if (showSource) printReconSourceWindow(stripped, pos.line);
				exitCode = EXIT_RUNTIME;
			} catch (e:Exception) {
				sysPrint('PREDICT STILL FAIL $path :: <no locus> ${e.message}\n');
				exitCode = EXIT_RUNTIME;
			}
		}
		// Per-pattern totals — same typo guard contract as sweep mode.
		for (idx in 0...patterns.length) {
			final pat:String = patterns[idx];
			final total:Int = patternHits[idx];
			sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		var anyZero:Bool = false;
		for (h in patternHits) if (h == 0) anyZero = true;
		if (anyZero) {
			stderr('apq recon: --predict-strip --probe: WARNING: one or more patterns matched 0 occurrences — see per-pattern totals\n');
			return EXIT_RUNTIME;
		}
		return exitCode;
	}

	private static function runReconSweep(
		plugin:GrammarPlugin, root:String, topN:Int,
		clusterFilter:Null<String>, predictStrip:Bool,
		patterns:Array<String>, replacements:Array<String>,
		compiledRegex:Null<Array<EReg>>, showSource:Bool
	):Int {
		final walk:ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final clusters:Map<String, ReconCluster> = walk.clusters;
		final records:Array<ReconRecord> = walk.records;
		// `--cluster <key>` filter: exact match against the normalised
		// cluster key (the histogram label, with `\n`/`\t` escaped).
		// Exact rather than substring because `}\n}` (canonical) would
		// substring-match every Haxe file's `…}\n}` tail. 0-match exits
		// non-zero; downstream output (SKIP / PREDICT / cluster drill)
		// walks the filtered records and the single-cluster map.
		var filteredRecords:Array<ReconRecord> = records;
		var filteredClusters:Map<String, ReconCluster> = clusters;
		if (clusterFilter != null) {
			final wanted:String = (clusterFilter : String);
			final hit:Null<ReconCluster> = clusters[wanted];
			if (hit == null) {
				stderr('apq recon: --cluster "$wanted" matched no cluster key (exact match).\n');
				final keyEntries:Array<{key:String, count:Int}> = [
					for (k => v in clusters) {key: k, count: v.count}
				];
				keyEntries.sort((a, b) -> b.count - a.count);
				final preview:Int = keyEntries.length > 10 ? 10 : keyEntries.length;
				if (preview == 0) {
					stderr('  (no skip-parse failures in this sweep)\n');
				} else {
					stderr('  available keys (${keyEntries.length} total, showing top $preview by frequency):\n');
					for (idx in 0...preview) stderr('    "${keyEntries[idx].key}"  (${keyEntries[idx].count}×)\n');
					if (keyEntries.length > preview) stderr('    … (${keyEntries.length - preview} more — run without --cluster to see the full histogram)\n');
				}
				return EXIT_RUNTIME;
			}
			filteredClusters = [wanted => hit];
			filteredRecords = [for (r in records) if (r.clusterKey == wanted) r];
		}
		if (predictStrip) return runReconPredictStrip(filteredRecords, filteredClusters, plugin, patterns, replacements, compiledRegex, clusterFilter, showSource);
		for (r in filteredRecords) sysPrint('${r.skipLine}\n');
		if (clusterFilter != null) return printReconClusterDrill(filteredClusters, records.length, (clusterFilter : String), filteredRecords, showSource);
		return printReconHistogram(clusters, records.length, topN);
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
	private static function collectReconSkipRecords(plugin:GrammarPlugin, root:String):ReconWalkResult {
		final clusters:Map<String, ReconCluster> = [];
		final records:Array<ReconRecord> = [];
		var wired:Bool = true;
		final stack:Array<String> = [root];
		while (stack.length > 0) {
			final dir:Null<String> = stack.pop();
			if (dir == null) break;
			final names:Array<String> = FileSystem.readDirectory(dir);
			names.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) {
				final path:String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!StringTools.endsWith(name, '.hxtest')) continue;
				final source:String = readSourceForParse(path);
				try {
					if (!plugin.reconParse(source)) {
						wired = false;
						break;
					}
				} catch (exception:ParseError) {
					final pos:Position = exception.span.lineCol(source);
					final relPath:String = stripRootPrefix(path, root);
					final exp:String = reconNormalize(exception.expected);
					final snip:String = reconNormalize(reconSnippet(source, exception.span.from));
					final rawLocus:String = reconRawLocus(source, exception.span.from);
					final key:String = reconNormalizeLocus(rawLocus);
					addReconCluster(clusters, key, relPath, rawLocus);
					records.push({
						path: relPath,
						clusterKey: key,
						source: source,
						skipLine: 'SKIP $relPath :: ${pos.line}:${pos.col} expected="$exp" :: src="$snip"',
						line: pos.line,
						col: pos.col,
					});
				} catch (exception:Exception) {
					final relPath:String = stripRootPrefix(path, root);
					final key:String = '<non-ParseError> ' + reconNormalize(exception.message);
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
		return {wired: wired, records: records, clusters: clusters};
	}

	private static function printReconHistogram(clusters:Map<String, ReconCluster>, total:Int, topN:Int):Int {
		final entries:Array<{key:String, cluster:ReconCluster}> = [
			for (k => v in clusters) {key: k, cluster: v}
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		final shown:Int = entries.length > topN ? topN : entries.length;
		sysPrint('\n');
		sysPrint('--- skip-parse construct-locus histogram (total $total, showing top $shown of ${entries.length}; --all overrides) ---\n');
		for (idx in 0...shown) {
			final entry = entries[idx];
			final c:ReconCluster = entry.cluster;
			final examplesStr:String = c.examples.length == 1
				? c.examples[0]
				: c.examples.join(', ');
			final raw:String = reconNormalize(c.rawSample);
			sysPrint('  ${c.count}× "${entry.key}"  e.g. "$raw"  in: $examplesStr\n');
		}
		if (entries.length > shown)
			sysPrint('  … (${entries.length - shown} more, use --top N or --all to see)\n');
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
		matches:Map<String, ReconCluster>, totalAcrossSweep:Int, needle:String,
		records:Array<ReconRecord>, showSource:Bool
	):Int {
		final entries:Array<{key:String, cluster:ReconCluster}> = [
			for (k => v in matches) {key: k, cluster: v}
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		var matched:Int = 0;
		for (e in entries) matched += e.cluster.count;
		// Map path → record so the windowed source / locus lookup stays
		// O(1) per path even in clusters with hundreds of fixtures.
		// Built once for the drill block regardless of `showSource`
		// (cost is negligible vs the walk itself).
		final byPath:Map<String, ReconRecord> = [for (r in records) r.path => r];
		sysPrint('\n');
		sysPrint('--- cluster drill for "$needle" (${entries.length} cluster${entries.length == 1 ? '' : 's'}, $matched of $totalAcrossSweep skip-parse paths) ---\n');
		for (entry in entries) {
			final c:ReconCluster = entry.cluster;
			sysPrint('  cluster "${entry.key}" — ${c.count} path${c.count == 1 ? '' : 's'}:\n');
			final sorted:Array<String> = c.paths.copy();
			sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			for (p in sorted) {
				if (!showSource) {
					sysPrint('    $p\n');
					continue;
				}
				final rec:Null<ReconRecord> = byPath[p];
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
	private static function printReconSourceWindow(source:String, failLine:Int):Void {
		final lines:Array<String> = source.split('\n');
		final radius:Int = RECON_SOURCE_WINDOW_RADIUS;
		final start:Int = failLine - radius < 1 ? 1 : failLine - radius;
		final end:Int = failLine + radius > lines.length ? lines.length : failLine + radius;
		sysPrint('      --- src window (L±$radius) ---\n');
		// Compute the gutter width from `end` so all rows line up; e.g.
		// a 3-digit end-line gives a 3-char gutter.
		final gutter:Int = ('$end').length;
		for (ln in start...end + 1) {
			final marker:String = ln == failLine ? '>>' : '  ';
			final num:String = padLeft('$ln', gutter);
			final body:String = lines[ln - 1];
			sysPrint('      $marker$num | $body\n');
		}
		sysPrint('      --- end ---\n');
	}

	private static inline function padLeft(s:String, width:Int):String {
		var out:String = s;
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
	private static inline function movedLocusHint(origLine:Int, origCol:Int, newLine:Int, newCol:Int):String {
		if (origLine <= 0) return '';
		if (newLine == origLine && newCol == origCol) return '';
		final forward:Bool = newLine > origLine || (newLine == origLine && newCol > origCol);
		final backward:Bool = newLine < origLine || (newLine == origLine && newCol < origCol);
		if (forward && newLine != origLine) return ' (was $origLine:$origCol, advanced)';
		if (backward) return ' (was $origLine:$origCol, moved BACKWARD — strip may have damaged earlier syntax or modelled the wrong mechanism; verify with `apq probe`)';
		return ' (was $origLine:$origCol)';
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
		records:Array<ReconRecord>, clusters:Map<String, ReconCluster>,
		plugin:GrammarPlugin, patterns:Array<String>, replacements:Array<String>,
		compiledRegex:Null<Array<EReg>>, clusterFilter:Null<String>, showSource:Bool
	):Int {
		final regexMode:Bool = compiledRegex != null;
		final regexes:Array<EReg> = compiledRegex ?? [];
		var unblockCount:Int = 0;
		var stillFailCount:Int = 0;
		var noMatchCount:Int = 0;
		final patternHits:Array<Int> = [for (_ in 0...patterns.length) 0];
		for (r in records) {
			var stripped:String = r.source;
			var fileHits:Int = 0;
			for (idx in 0...patterns.length) {
				final hits:Int = regexMode
					? countRegexHits(regexes[idx], stripped)
					: countOccurrences(stripped, patterns[idx]);
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
			} catch (pe:ParseError) {
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
				final pos:Position = pe.span.lineCol(stripped);
				final movedHint:String = movedLocusHint(r.line, r.col, pos.line, pos.col);
				sysPrint('PREDICT STILL FAIL ${r.path} :: ${pos.line}:${pos.col}${movedHint} ${pe.message}\n');
				if (showSource) printReconSourceWindow(stripped, pos.line);
				stillFailCount++;
			} catch (e:Exception) {
				sysPrint('PREDICT STILL FAIL ${r.path} :: <no locus> ${e.message}\n');
				stillFailCount++;
			}
		}
		sysPrint('\n');
		final scope:String = clusterFilter == null ? 'whole sweep' : 'cluster "$clusterFilter"';
		sysPrint('--- predict-strip ($scope): ${records.length} skip-parse file${records.length == 1 ? '' : 's'}; ');
		sysPrint('$unblockCount would unblock, $stillFailCount still fail, $noMatchCount unchanged ---\n');
		for (idx in 0...patterns.length) {
			final pat:String = patterns[idx];
			final total:Int = patternHits[idx];
			sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		// Mirror `strip --dry-run`: every supplied pattern matching 0
		// across the whole filtered set is a typo signal worth surfacing
		// non-zero. A pattern matching SOMEWHERE but not everywhere is
		// expected behaviour for a targeted predicate; only the global
		// 0 case is the guard.
		var anyZero:Bool = false;
		for (h in patternHits) if (h == 0) anyZero = true;
		if (anyZero) {
			stderr('apq recon: --predict-strip: WARNING: one or more patterns matched 0 occurrences anywhere in the filtered set — see per-pattern totals\n');
			return EXIT_RUNTIME;
		}
		return EXIT_OK;
	}

	private static function defaultReconRoot():String {
		final fork:Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		if (fork == null || fork.length == 0) return '';
		final candidate:String = '$fork/test/testcases';
		return FileSystem.exists(candidate) && FileSystem.isDirectory(candidate) ? candidate : fork;
	}

	private static function stripRootPrefix(path:String, root:String):String {
		if (StringTools.startsWith(path, root + '/')) return path.substr(root.length + 1);
		if (path == root) return '.';
		return path;
	}

	private static function addReconCluster(map:Map<String, ReconCluster>, key:String, file:String, rawLocus:String):Void {
		final prev:Null<ReconCluster> = map[key];
		if (prev == null) {
			map[key] = {count: 1, examples: [file], paths: [file], rawSample: rawLocus};
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
	private static function reconRawLocus(input:String, offset:Int):String {
		final start:Int = offset > input.length ? input.length : offset;
		final end:Int = start + RECON_LOCUS_LEN > input.length ? input.length : start + RECON_LOCUS_LEN;
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
	private static function reconNormalizeLocus(raw:String):String {
		final buf:StringBuf = new StringBuf();
		var i:Int = 0;
		while (i < raw.length) {
			final c:Int = StringTools.fastCodeAt(raw, i);
			final isIdStart:Bool = (c >= 'a'.code && c <= 'z'.code)
				|| (c >= 'A'.code && c <= 'Z'.code)
				|| c == '_'.code;
			if (isIdStart) {
				var j:Int = i + 1;
				while (j < raw.length) {
					final cj:Int = StringTools.fastCodeAt(raw, j);
					final isIdCont:Bool = (cj >= 'a'.code && cj <= 'z'.code)
						|| (cj >= 'A'.code && cj <= 'Z'.code)
						|| (cj >= '0'.code && cj <= '9'.code)
						|| cj == '_'.code;
					if (!isIdCont) break;
					j++;
				}
				final identLen:Int = j - i;
				if (identLen > 4) buf.add('_');
				else for (k in i...j) buf.addChar(StringTools.fastCodeAt(raw, k));
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
	private static function reconSnippet(input:String, offset:Int):String {
		final half:Int = Std.int(RECON_HEAD_LEN / 2);
		final centre:Int = offset > input.length ? input.length : offset;
		final start:Int = centre - half < 0 ? 0 : centre - half;
		final end:Int = centre + half > input.length ? input.length : centre + half;
		return input.substring(start, end);
	}

	private static function reconNormalize(message:Null<String>):String {
		if (message == null || message == '') return '<no message>';
		return StringTools.replace(StringTools.replace(message, '\n', '\\n'), '\t', '\\t');
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
	private static function runSweep(args:Array<String>):Int {
		var filePath:String = 'bin/.last-sweep.json';
		var prevPath:Null<String> = null;
		var diffPath:Null<String> = null;
		// `--save <path>`: discoverable shorthand for "copy the current
		// snapshot to <path> so I can `--prev` / `--diff` against it
		// after the next sweep". Replaces the manual
		// `cp bin/.last-sweep.json /tmp/prev.json` step that's easy to
		// forget before a grammar slice. Performs the copy AFTER the
		// totals print so the user still sees the snapshot's contents.
		var savePath:Null<String> = null;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
		final cur:Null<SweepTotals> = loadSweepJson(filePath);
		if (cur == null) {
			stderr('apq sweep: cannot read $filePath (missing or unparseable)\n');
			return EXIT_RUNTIME;
		}
		final total:Int = cur.pass + cur.fail + cur.skipParse + cur.skipWrite + cur.skipConfig + cur.skipMalformed;
		sysPrint('${cur.pass} pass / ${cur.fail} fail / ${cur.skipParse} skip-parse / ${cur.skipWrite} skip-write / ${cur.skipConfig} skip-config / ${cur.skipMalformed} malformed (total $total)\n');
		if (prevPath != null) {
			final prev:Null<SweepTotals> = loadSweepJson(prevPath);
			if (prev == null) {
				stderr('apq sweep: cannot read --prev $prevPath\n');
				return EXIT_RUNTIME;
			}
			sysPrint('  Δpass ${sweepSigned(cur.pass - prev.pass)} / Δfail ${sweepSigned(cur.fail - prev.fail)} / Δskip-parse ${sweepSigned(cur.skipParse - prev.skipParse)}  vs $prevPath (${prev.pass} / ${prev.fail} / ${prev.skipParse})\n');
		}
		if (savePath != null) {
			try {
				final raw:String = sys.io.File.getContent(filePath);
				sys.io.File.saveContent((savePath : String), raw);
				sysPrint('apq sweep: saved snapshot $filePath -> $savePath\n');
			} catch (e:Exception) {
				stderr('apq sweep: --save failed: ${e.message}\n');
				return EXIT_RUNTIME;
			}
		}
		if (diffPath != null) return runSweepDiff(filePath, diffPath);
		return EXIT_OK;
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
	private static function runSweepDiff(curPath:String, prevPath:String):Int {
		final cur:Map<String, String> = loadSweepFixtureStatus(curPath);
		final prev:Map<String, String> = loadSweepFixtureStatus(prevPath);
		if (!cur.iterator().hasNext()) {
			stderr('apq sweep: --diff: $curPath has no `fixtures` array — re-run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK to seed it\n');
			return EXIT_RUNTIME;
		}
		if (!prev.iterator().hasNext()) {
			stderr('apq sweep: --diff: $prevPath has no `fixtures` array\n');
			return EXIT_RUNTIME;
		}
		final allPaths:Map<String, Bool> = [];
		for (k in cur.keys()) allPaths.set(k, true);
		for (k in prev.keys()) allPaths.set(k, true);
		final sorted:Array<String> = [for (k in allPaths.keys()) k];
		sorted.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
		final transitions:Map<String, Int> = [];
		var changed:Int = 0;
		for (path in sorted) {
			final ps:Null<String> = prev.get(path);
			final cs:Null<String> = cur.get(path);
			if (ps == cs) continue;
			changed++;
			final key:String = if (ps == null) 'ADDED($cs)'
				else if (cs == null) 'REMOVED($ps)'
				else '$ps->$cs';
			transitions.set(key, (transitions.get(key) ?? 0) + 1);
			if (ps == null) sysPrint('ADDED $path (now $cs)\n');
			else if (cs == null) sysPrint('REMOVED $path (was $ps)\n');
			else sysPrint('$ps -> $cs: $path\n');
		}
		final breakdown:Array<String> = [for (k => v in transitions) '$k: $v'];
		breakdown.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
		if (changed == 0)
			sysPrint('--- sweep --diff: 0 fixtures changed (snapshots identical) ---\n');
		else
			sysPrint('--- sweep --diff: $changed fixtures changed (${breakdown.join(", ")}) ---\n');
		return EXIT_OK;
	}

	private static function loadSweepJson(path:String):Null<SweepTotals> {
		if (!sys.FileSystem.exists(path)) return null;
		return try {
			final raw:String = sys.io.File.getContent(path);
			final obj:Dynamic = haxe.Json.parse(raw);
			final pass:Null<Int> = Reflect.hasField(obj, 'pass') ? Reflect.field(obj, 'pass') : null;
			final fail:Null<Int> = Reflect.hasField(obj, 'fail') ? Reflect.field(obj, 'fail') : null;
			final skipParse:Null<Int> = Reflect.hasField(obj, 'skipParse') ? Reflect.field(obj, 'skipParse') : null;
			final skipWrite:Null<Int> = Reflect.hasField(obj, 'skipWrite') ? Reflect.field(obj, 'skipWrite') : null;
			final skipConfig:Null<Int> = Reflect.hasField(obj, 'skipConfig') ? Reflect.field(obj, 'skipConfig') : null;
			final skipMalformed:Null<Int> = Reflect.hasField(obj, 'skipMalformed') ? Reflect.field(obj, 'skipMalformed') : null;
			if (pass == null || fail == null || skipParse == null) return null;
			{
				pass: pass,
				fail: fail,
				skipParse: skipParse,
				skipWrite: skipWrite ?? 0,
				skipConfig: skipConfig ?? 0,
				skipMalformed: skipMalformed ?? 0,
			};
		} catch (_:Exception) null;
	}

	private static inline function sweepSigned(n:Int):String return n > 0 ? '+$n' : '$n';

	private static function printSweepUsage():Void {
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
	private static function runTestSummary(args:Array<String>):Int {
		var sourcePath:Null<String> = null;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
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
		final raw:String = try {
			if (sourcePath == null) {
				if (sys.FileSystem.exists('/tmp/test.out')) sys.io.File.getContent('/tmp/test.out');
				else {
					stderr('apq test-summary: no source given and /tmp/test.out missing — pass <path> or `-` for stdin\n');
					return EXIT_USAGE;
				}
			} else if (sourcePath == '-') {
				readStdin();
			} else {
				sys.io.File.getContent((sourcePath : String));
			}
		} catch (e:Exception) {
			stderr('apq test-summary: read failed: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final okRe:EReg = ~/^\s+\w[\w.]*:\s+OK(\s+(\.+))?/;
		var tests:Int = 0;
		var assertions:Int = 0;
		var failures:Int = 0;
		var errors:Int = 0;
		final lines:Array<String> = raw.split('\n');
		for (line in lines) {
			if (okRe.match(line)) {
				tests++;
				final dots:Null<String> = try okRe.matched(2) catch (_:Exception) null;
				if (dots != null) assertions += (dots : String).length;
				continue;
			}
			// FAIL / ERROR / FAILURE substrings — utest variants. Case-
			// insensitive contains-check on a test-method-shaped prefix
			// (leading whitespace + non-empty token + colon).
			if (~/^\s+\w[\w.]*:\s+FAIL/.match(line)) failures++;
			else if (~/^\s+\w[\w.]*:\s+ERR/.match(line)) errors++;
		}
		final src:String = sourcePath ?? '/tmp/test.out';
		sysPrint('$tests tests / $assertions assertions / $failures failures / $errors errors  ($src)\n');
		return EXIT_OK;
	}

	private static function printTestSummaryUsage():Void {
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
		sysPrint('Always exits 0 on a successful parse — the test runner\'s exit code is\n');
		sysPrint('the authoritative pass/fail signal.\n');
	}
	#end

	private static function printReconUsage():Void {
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
		sysPrint('  --source                With --cluster, append a windowed source slice\n');
		sysPrint('                          around the fail-locus for each path (L±3).\n');
		sysPrint('                          With --predict-strip, also emits the window for\n');
		sysPrint('                          each STILL FAIL entry around the NEW fail-locus\n');
		sysPrint('                          (the moved-locus payload). Usage error otherwise.\n');
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
		sysPrint('  -h, --help              Show this help.\n');
	}

	private static function readFile(path:String):String {
		#if (sys || nodejs)
		return File.getContent(path);
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
	private static function readStdin():String {
		#if nodejs
		final fs:Dynamic = js.Lib.require('fs');
		final buf:Dynamic = fs.readFileSync(0);
		return (buf : Dynamic).toString('utf8');
		#elseif sys
		return Sys.stdin().readAll().toString();
		#else
		throw 'apq: stdin requires a sys target';
		#end
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
	private static function readSourceForParse(path:String):String {
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
	private static function readExpectedForCompare(path:String):String {
		return readHxtestSectionOrRaw(path, 2);
	}

	/**
	 * Common backend for the two `.hxtest`-aware readers. `sectionIdx`
	 * is the 0-based section index into the `\n---\n` split — `1` for
	 * the input source, `2` for the expected output. Trims exactly one
	 * leading and one trailing `\n` to mirror
	 * `HxFormatterCorpusHelpers.stripPadNewlines`.
	 */
	private static function readHxtestSectionOrRaw(path:String, sectionIdx:Int):String {
		final content:String = readFile(path);
		if (!StringTools.endsWith(path, '.hxtest')) return content;
		final parts:Array<String> = content.split('\n---\n');
		if (parts.length != 3) return content;
		var section:String = parts[sectionIdx];
		if (section.length > 0 && section.charAt(0) == '\n') section = section.substr(1);
		if (section.length > 0 && section.charAt(section.length - 1) == '\n')
			section = section.substr(0, section.length - 1);
		return section;
	}

	/**
	 * Section-1 (writer config JSON) auto-extract for `.hxtest` inputs.
	 * Returns `null` for non-`.hxtest` paths and for `.hxtest` files
	 * that don't have the canonical 3-section layout, so writer entry
	 * points fall back to plugin defaults. When the 3-section layout is
	 * present, returns the trimmed JSON bytes (matching the corpus
	 * harness's reader convention) ready to feed into
	 * `plugin.writeRoundTrip(source, optsJson)`. Twin of
	 * `readSourceForParse` (section 2) and `readExpectedForCompare`
	 * (section 3).
	 */
	private static function readWriteOptionsJsonOrNull(path:String):Null<String> {
		if (!StringTools.endsWith(path, '.hxtest')) return null;
		final content:String = readFile(path);
		final parts:Array<String> = content.split('\n---\n');
		if (parts.length != 3) return null;
		var section:String = parts[0];
		if (section.length > 0 && section.charAt(section.length - 1) == '\n')
			section = section.substr(0, section.length - 1);
		return section;
	}

	private static function expectValue(args:Array<String>, idx:Int, flag:String):String {
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
	private static function expandInputs(specs:Array<String>, ext:String):{paths:Array<String>, singleFile:Bool} {
		final paths:Array<String> = [];
		for (spec in specs)
			for (p in Glob.expand(spec, ext))
				if (!paths.contains(p)) paths.push(p);
		final singleFile:Bool = specs.length == 1 && paths.length == 1 && paths[0] == specs[0];
		return {paths: paths, singleFile: singleFile};
	}

	/**
	 * Keep at most `limit` hits total across the per-file entries,
	 * truncating the entry that crosses the budget and dropping the
	 * rest. `limit < 0` is "no limit" (the no-flag default). Generic
	 * over the entry shape: `len` reads a hit count, `trim` rebuilds an
	 * entry capped to the first `k` hits.
	 */
	private static function limitEntries<T>(entries:Array<T>, limit:Int, len:T -> Int, trim:(T, Int) -> T):Array<T> {
		if (limit < 0) return entries;
		final out:Array<T> = [];
		var remaining:Int = limit;
		for (e in entries) {
			if (remaining <= 0) break;
			final n:Int = len(e);
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
	private static function parseLimit(args:Array<String>, idx:Int):Int {
		final v:String = expectValue(args, idx, '--limit');
		final n:Null<Int> = Std.parseInt(v);
		if (n == null || n < 0) throw 'apq: --limit expects a non-negative integer, got "$v"';
		return n;
	}

	private static function printUsage():Void {
		sysPrint('apq — anyparse query CLI\n');
		sysPrint('\n');
		sysPrint('Usage: apq <command> [options] <file>\n');
		sysPrint('\n');
		sysPrint('Commands:\n');
		sysPrint('  ast           Dump parsed AST (S-expr or JSON)\n');
		sysPrint('  probe         AST/writer probe with inline source (no file IO)\n');
		sysPrint('  search        Structural pattern search\n');
		sysPrint('  refs          Symbol references (value bindings; scope-aware)\n');
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
		sysPrint('  test-summary  Parse utest stdout transcript into tests/assertions/failures\n');
		sysPrint('\n');
		sysPrint('Global options:\n');
		sysPrint('  --lang <name>   Pick grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show help\n');
	}

	private static function printSearchUsage():Void {
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
		sysPrint("\n");
		sysPrint("Use `--` before a pattern that starts with `--` (e.g. the\n");
		sysPrint("prefix-decrement pattern `--$x`): apq search -- '--\\$x' <file>\n");
	}

	private static function printLitUsage():Void {
		sysPrint('Usage: apq lit [options] <text> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --exact             Require exact string equality (default: substring)\n');
		sysPrint('  --kind <K1,K2,...>  Restrict to leaves of these kinds (default: shape-based, see below)\n');
		sysPrint('  --any-kind          Match every named leaf regardless of kind\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint("Walks parsed AST for leaf nodes whose `name` slot matches <text>.\n");
		sysPrint("Smart-default --kind: when <text> is camelCase / snake_case the\n");
		sysPrint("default widens to `Literal,IdentExpr` (clearly an identifier query —\n");
		sysPrint("`hxq lit trailOptShapeGate src/` finds both literals and identifier\n");
		sysPrint("references without a re-run). Pure-lowercase / all-uppercase single\n");
		sysPrint("words stay `Literal`-only — they ambiguously match string content and\n");
		sysPrint("identifier widening would flood prose hits. Override with --kind /\n");
		sysPrint("--any-kind. Skips comments and string interpolation as a side effect\n");
		sysPrint("of routing through the parser — no false positives from doc-comments.\n");
	}

	private static function printBlastUsage():Void {
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

	private static function printMentionsUsage():Void {
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

	private static function printRefsUsage():Void {
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

	private static function printUsesUsage():Void {
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

	private static function printMetaUsage():Void {
		sysPrint('Usage: apq meta [<annotation>] [options] <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --arg-contains <s>  Keep hits whose argument list contains <s>\n');
		sysPrint('  --on <decl-kind>    Keep hits attached to the given decl kind\n');
		sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('<annotation> is the target language source syntax (e.g. `@:foo`),\n');
		sysPrint('recognised by its leading `@`. Omit it with `--on` to list every\n');
		sysPrint('annotation on a decl kind.\n');
	}

	private static function printAstUsage():Void {
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
		sysPrint('  --spans             Append `@from-to` byte-range annotation to every rendered node — same-span duplicates (parser bug emitting two nodes at the same position) become a trivial visual signal.\n');
		sysPrint('  --count             Print just the integer direct-child count at the displayed root (one line per match with --select). Sanity-check for member counts before writing a corpus-driver test assertion.\n');
		sysPrint('  --writer-output     Parse + format-write through the plugin trivia pipeline and print the emitted source\n');
		sysPrint('  --writer-output-plain  Like --writer-output but uses the plain (non-trivia) writer — mirrors the unit-test entry HxModuleWriter.write(HaxeModuleParser.parse(src)); flattens source layout, drops comments\n');
		sysPrint('  --diff              With --writer-output: AST-diff the input against the emitted output (writer-bug loop)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
	}

	private static function printProbeUsage():Void {
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

	private static function printWriterProbeUsage():Void {
		sysPrint('Usage: apq writer-probe [options] <file>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint("Parse <file>, run BOTH the trivia and plain writer pipelines, and\n");
		sysPrint("emit each output between labelled fences:\n");
		sysPrint('  === trivia ===\n');
		sysPrint('  <bytes>\n');
		sysPrint('  === plain ===\n');
		sysPrint('  <bytes>\n');
		sysPrint('\n');
		sysPrint("Replaces the two-command dance (`hxq ast … --writer-output` then\n");
		sysPrint("`hxq ast … --writer-output-plain`) when constructing a unit-test\n");
		sysPrint("`writerEquals` expected literal: side-by-side output makes the\n");
		sysPrint("pipeline divergence (anon flatten, terminators, comments) visible.\n");
		sysPrint("Exit 0 only when both pipelines succeed.\n");
	}

	private static function stderr(s:String):Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
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
	 */
	private static function parseWalked(
		cmd:String,
		parse:String -> QueryNode,
		path:String,
		source:String,
		singleFile:Bool,
		?skipOut:Array<SkipEntry>
	):Null<QueryNode> {
		return try parse(source)
			catch (exception:ParseError) {
				if (singleFile) stderr('apq $cmd: $path: ${exception.toString()}\n');
				if (skipOut != null) skipOut.push({path: path, locus: formatParseErrorLocus(exception, source)});
				null;
			}
			catch (exception:Exception) {
				if (singleFile) stderr('apq $cmd: $path: ${exception.message}\n');
				if (skipOut != null) skipOut.push({path: path, locus: exception.message});
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
	private static function formatParseErrorLocus(exception:ParseError, source:String):String {
		final pos:Position = exception.span.lineCol(source);
		final base:String = '${pos.line}:${pos.col} ${exception.message}';
		return exception.expected == null ? base : '$base (expected ${exception.expected})';
	}

	/**
	 * Increment `counts[node.kind]` for every node in the tree. Used
	 * by `apq search --explain` to build the kind histogram that
	 * surfaces "pattern's root kind is not present in input" mismatches.
	 */
	private static function tallyKinds(root:QueryNode, counts:Map<String, Int>):Void {
		function walk(n:QueryNode):Void {
			final prev:Null<Int> = counts.get(n.kind);
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
	private static function looksLikeTypeName(s:String):Bool {
		if (s.length == 0) return false;
		final c:Int = StringTools.fastCodeAt(s, 0);
		if (c < 'A'.code || c > 'Z'.code) return false;
		return s.indexOf('/') < 0 && s.indexOf('.') < 0;
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
	private static function looksLikeMixedIdentifier(s:String):Bool {
		if (s.length < 2) return false;
		var hasLower:Bool = false;
		var hasUpper:Bool = false;
		var hasUnderscore:Bool = false;
		var hasLetter:Bool = false;
		var mixedTransition:Bool = false;
		var prevLower:Bool = false;
		for (idx in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, idx);
			final isLower:Bool = c >= 'a'.code && c <= 'z'.code;
			final isUpper:Bool = c >= 'A'.code && c <= 'Z'.code;
			final isDigit:Bool = c >= '0'.code && c <= '9'.code;
			final isUnderscore:Bool = c == '_'.code;
			if (!(isLower || isUpper || isDigit || isUnderscore)) return false;
			if (isLower) { hasLower = true; hasLetter = true; }
			if (isUpper) {
				hasUpper = true; hasLetter = true;
				if (prevLower) mixedTransition = true;
			}
			if (isUnderscore) hasUnderscore = true;
			prevLower = isLower;
		}
		if (!hasLetter) return false;
		// camelCase / PascalCase-with-internal-lower: lower→upper transition
		if (mixedTransition) return true;
		// snake_case: `_` between identifier chars
		if (hasUnderscore && (hasLower || hasUpper)) return true;
		return false;
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
	private static function looksLikeLeadingDotField(s:String):Null<String> {
		if (s.length < 2) return null;
		if (StringTools.fastCodeAt(s, 0) != '.'.code) return null;
		final tail:String = s.substr(1);
		// Tail must be a single identifier — multi-segment chains like
		// `.obj.field` are not the intended shape (they would also
		// produce false positives on the `obj.field` SOURCE form).
		if (tail.indexOf('.') >= 0) return null;
		final first:Int = StringTools.fastCodeAt(tail, 0);
		final firstOk:Bool = (first >= 'a'.code && first <= 'z'.code)
			|| (first >= 'A'.code && first <= 'Z'.code)
			|| first == '_'.code;
		if (!firstOk) return null;
		for (idx in 1...tail.length) {
			final c:Int = StringTools.fastCodeAt(tail, idx);
			final ok:Bool = (c >= 'a'.code && c <= 'z'.code)
				|| (c >= 'A'.code && c <= 'Z'.code)
				|| (c >= '0'.code && c <= '9'.code)
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
	private static function looksLikeRegex(s:String):Null<String> {
		if (s.indexOf('\\|') >= 0) return '`\\|` (regex alternation)';
		if (s.indexOf('[^') >= 0) return '`[^...]` (negated character class)';
		if (s.indexOf('(?:') >= 0) return '`(?:...)` (non-capturing group)';
		if (s.indexOf('(?=') >= 0) return '`(?=...)` (lookahead)';
		if (s.indexOf('(?!') >= 0) return '`(?!...)` (negative lookahead)';
		return null;
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
	private static function detectMacroReification(s:String):Null<String> {
		final tags:Array<String> = ['v', 'i', 'a', 'b', 'p', 'e', 'es'];
		for (tag in tags) {
			final probe:String = "$" + tag + "{";
			if (s.indexOf(probe) >= 0) return "`$" + tag + "{...}`";
		}
		return null;
	}

	private static function looksLikeDottedAccess(s:String):Null<Array<String>> {
		if (s.indexOf('.') < 0) return null;
		final parts:Array<String> = s.split('.');
		if (parts.length < 2) return null;
		for (p in parts) {
			if (p.length == 0) return null;
			final first:Int = StringTools.fastCodeAt(p, 0);
			final firstOk:Bool = (first >= 'a'.code && first <= 'z'.code)
				|| (first >= 'A'.code && first <= 'Z'.code)
				|| first == '_'.code;
			if (!firstOk) return null;
			for (idx in 1...p.length) {
				final c:Int = StringTools.fastCodeAt(p, idx);
				final ok:Bool = (c >= 'a'.code && c <= 'z'.code)
					|| (c >= 'A'.code && c <= 'Z'.code)
					|| (c >= '0'.code && c <= '9'.code)
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
	private static function looksLikePath(s:String):Bool {
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
	private static function degenerateNudge(patternStr:String, rootKind:String):String {
		final prefix:String = 'apq search: pattern "$patternStr" ';
		return switch rootKind {
			case 'Metavar':
				prefix + 'is a lone metavar — matches every node. Narrow with structural '
					+ "context (e.g. \"$x.field\", \"func($x)\"), or look up by name: apq refs <name> --decls / apq uses <Type>. Searching anyway.";
			case 'Literal' | 'StringLit' | 'BoolLit' | 'IntLit' | 'FloatLit'
				| 'SingleStringExpr' | 'DoubleStringExpr' | 'RawString':
				prefix + 'is a bare literal — for literal-content lookup use: apq lit \'$patternStr\' <files>. Searching anyway.';
			case _:
				// Bare identifier (IdentExpr) and anything else that
				// parses to a single leaf.
				prefix + 'has no code structure — search matches shape, not bare names. '
					+ 'Try one of: apq refs $patternStr --decls (value binding), '
					+ 'apq uses $patternStr (type position), '
					+ 'apq lit \'$patternStr\' (string-literal content), '
					+ 'apq ast --select. Searching anyway.';
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
		cmd:String,
		name:Null<String>,
		scanned:Int,
		parseable:Int,
		?skipEntries:Array<SkipEntry>,
		?candidates:Map<String, Bool>
	):String {
		final summary:String = 'apq $cmd: 0 hits ($scanned file(s) scanned, $parseable parseable)';
		final tail:StringBuf = new StringBuf();
		if (name != null) {
			final n:String = name;
			final first:Int = n.length > 0 ? StringTools.fastCodeAt(n, 0) : 0;
			final isUpper:Bool = first >= 'A'.code && first <= 'Z'.code;
			final isLower:Bool = first >= 'a'.code && first <= 'z'.code;
			final leadingDot:Null<String> = looksLikeLeadingDotField(n);
			final dotted:Null<Array<String>> = looksLikeDottedAccess(n);
			final hint:String = if (leadingDot != null && (cmd == 'lit' || cmd == 'refs' || cmd == 'uses')) {
				// Leading-dot query (`.expr`, `.body`) — user is hunting a
				// field-access shape but typed the SLOT name only. lit
				// won't capture the leading `.` (FieldAccess leaves are
				// the identifier after `.`, the `.` is a postfix
				// operator); refs/uses don't know about field positions.
				// The structural answer is `apq search '$x.<tail>'`.
				final t:String = leadingDot;
				' — "$n" is a leading-dot field-name slot. $cmd matches leaf names / single bindings / type positions, never `expr.field` shape. Try: apq search \'$$x.$t\' <dir> (field-access shape), apq lit \'$t\' <dir> --any-kind (every leaf — field-name slots included), or apq refs $t <dir> --decls (where the field is declared).';
			} else if (dotted != null && (cmd == 'lit' || cmd == 'refs' || cmd == 'uses')) {
				// Dotted query (`TypeName.method`, `obj.field`) — never a
				// leaf-name / value-binding / type-position match. The
				// structural answer is `apq search` with the access shape.
				final lhs:String = dotted[0];
				final rhs:String = dotted[dotted.length - 1];
				final lhsFirst:Int = StringTools.fastCodeAt(lhs, 0);
				final lhsIsUpper:Bool = lhsFirst >= 'A'.code && lhsFirst <= 'Z'.code;
				// LHS uppercase ⇒ static call shape; otherwise instance access.
				if (lhsIsUpper)
					' — "$n" is a dotted access (Type.method / pkg.Module). $cmd matches leaf names / single bindings / type positions, never `Type.method` shape. Try: apq search \'$n($$_)\' <dir> (call shape), apq search \'$lhs.$rhs\' <dir> (field-access shape), or apq refs $rhs <dir> --decls (where the method is declared).';
				else
					' — "$n" is a dotted access (obj.field). $cmd matches leaf names / single bindings, never `obj.field` shape. Try: apq search \'$$x.$rhs\' <dir> (field-access shape), apq search \'$n\' <dir> (literal access), or apq refs $rhs <dir> --decls (where the field is declared).';
			} else switch cmd {
				case 'refs':
					if (isUpper) ' — "$n" starts uppercase, looks like a TypeName. Try: apq uses $n <dir> (type positions), apq blast $n <dir> (full change-impact incl. field-access), or apq lit \'$n\' <dir> --any-kind (every leaf — case-patterns / imports / new exprs).';
					else ' — "$n" has no value-binding here. Locals/params are NOT indexed. Try: apq lit \'$n\' <dir> --any-kind (every leaf — strings/idents/field-names) or apq search \'$$x.$n\' <dir> (field-access shape).';
				case 'uses':
					if (isLower) ' — "$n" starts lowercase, not a TypeName. Try: apq refs $n <dir> (value bindings) or apq lit \'$n\' <dir> --any-kind (every leaf).';
					else ' — no type-position references. For full change-impact incl. `.field` access try: apq blast $n <dir>, or apq lit \'$n\' <dir> --any-kind (every leaf — incl. case-patterns).';
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
			final n:Int = skipEntries.length;
			tail.add('\napq $cmd: WARNING: $n file(s) skip-parse — answer may be hiding in unparsed files. Locus shows the parse-failure position; if it is far past the construct you searched for, the warning can be ignored.');
			final shown:Int = n < SKIP_PATHS_SHOWN ? n : SKIP_PATHS_SHOWN;
			for (i in 0...shown) {
				final entry:SkipEntry = skipEntries[i];
				tail.add('\n  skip: ${entry.path} :: ${entry.locus}');
			}
			if (n > shown)
				tail.add('\n  ... and ${n - shown} more');
		}

		// Fuzzy "did you mean": for refs/uses on 0 hits, propose the
		// top-K decl/type names within Levenshtein distance. Stays
		// silent when no candidate qualifies — don't fabricate hints.
		if (name != null && candidates != null && (cmd == 'refs' || cmd == 'uses')) {
			final suggestions:Array<String> = findFuzzy(name, candidates);
			if (suggestions.length > 0)
				tail.add('\napq $cmd: Did you mean: ${suggestions.join(", ")}?');
		}

		return summary + tail.toString();
	}

	/**
	 * Collect every named leaf/inner-node into `out` for fuzzy
	 * "did you mean" suggestions. The full vocabulary covered by the
	 * walked tree — wider than just decls — keeps the suggestion list
	 * useful for either refs (value bindings) or uses (type positions)
	 * without needing a per-shape collector.
	 */
	private static function collectNames(root:QueryNode, out:Map<String, Bool>):Void {
		function walk(n:QueryNode):Void {
			final nm:Null<String> = n.name;
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
	private static function findFuzzy(query:String, pool:Map<String, Bool>):Array<String> {
		final scored:Array<{name:String, tier:Int, score:Int}> = [];
		final qLen:Int = query.length;
		final substringEnabled:Bool = qLen >= FUZZY_SUBSTRING_MIN_QUERY;
		for (cand in pool.keys()) {
			if (cand == query) continue;
			if (substringEnabled && cand.length > qLen && cand.length - qLen <= FUZZY_SUBSTRING_MAX_EXTRA && cand.indexOf(query) >= 0) {
				scored.push({name: cand, tier: 0, score: cand.length - qLen});
				continue;
			}
			final d:Int = levenshtein(query, cand);
			if (d <= FUZZY_MAX_DIST) scored.push({name: cand, tier: 1, score: d});
		}
		scored.sort((a, b) -> a.tier != b.tier ? a.tier - b.tier : (a.score != b.score ? a.score - b.score : (a.name < b.name ? -1 : 1)));
		final take:Int = scored.length < FUZZY_TOP_K ? scored.length : FUZZY_TOP_K;
		return [for (i in 0...take) scored[i].name];
	}

	/** Levenshtein edit distance (insert/delete/substitute = 1). */
	private static function levenshtein(a:String, b:String):Int {
		final la:Int = a.length;
		final lb:Int = b.length;
		if (la == 0) return lb;
		if (lb == 0) return la;
		var prev:Array<Int> = [for (j in 0...lb + 1) j];
		var cur:Array<Int> = [for (j in 0...lb + 1) 0];
		for (i in 1...la + 1) {
			cur[0] = i;
			final ai:Int = StringTools.fastCodeAt(a, i - 1);
			for (j in 1...lb + 1) {
				final cost:Int = ai == StringTools.fastCodeAt(b, j - 1) ? 0 : 1;
				final del:Int = prev[j] + 1;
				final ins:Int = cur[j - 1] + 1;
				final sub:Int = prev[j - 1] + cost;
				var m:Int = del < ins ? del : ins;
				if (sub < m) m = sub;
				cur[j] = m;
			}
			final tmp:Array<Int> = prev;
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
	private static function extractFirstKindToken(selectExpr:String):String {
		final trimmed:String = StringTools.trim(selectExpr);
		if (trimmed.length == 0) return '';
		var end:Int = trimmed.length;
		for (i in 0...trimmed.length) {
			final c:Int = StringTools.fastCodeAt(trimmed, i);
			if (c == '>'.code || c == ':'.code || c == '['.code || c == ' '.code || c == '\t'.code) {
				end = i;
				break;
			}
		}
		return StringTools.trim(trimmed.substr(0, end));
	}

	/** Distinct node-constructor kinds present in a tree, sorted — the
	 * self-discovery list shown when `--select` matches nothing. */
	private static function collectKinds(root:QueryNode):Array<String> {
		final seen:Array<String> = [];
		function walk(n:QueryNode):Void {
			if (!seen.contains(n.kind)) seen.push(n.kind);
			for (c in n.children) walk(c);
		}
		walk(root);
		seen.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return seen;
	}

	private static inline function sysPrint(s:String):Void {
		#if (sys || nodejs)
		Sys.print(s);
		#end
	}
}
