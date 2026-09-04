package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.Meta.MetaHit;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliWalk;
import anyparse.query.cli.command.ReconCommand.ReconRecord;
import anyparse.query.cli.command.ReconCommand.ReconWalkResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * The reduced `MechanismMetas` variant the recon `--permissive-construct` path uses: optional flag plus lead / trail / sep only (no kw / absentOn), describing the tokens a maximally-permissive reconstruction would emit.
 */
typedef PermissiveMetas = {
	var hasOptional: Bool;
	var lead: Null<String>;
	var trail: Null<String>;
	var sep: Null<String>;
};

/**
 * A single-construct current-parse probe for `apq recon`: whether the construct is `unwired`, whether it parses `ok`, and the `line` / `col` / `msg` of the failure when it does not.
 */
typedef ReconCurrentParse = {
	var unwired: Bool;
	var ok: Bool;
	var line: Int;
	var col: Int;
	var msg: String;
};

/**
 * Tallies from an `apq recon --regression-probe` run: how many corpus constructs `regressed` (parse OK to SKIP), how many `unblocked` (SKIP to OK), how many `scanned`, and whether the target mechanism was `unwired`.
 */
typedef ReconRegressionResult = {
	var regressed: Int;
	var unblocked: Int;
	var scanned: Int;
	var unwired: Bool;
};

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

/**
 * Full result of one `apq recon --predict-relax` probe: its `PredictRelaxKind` plus the `original` / `patched` sources, the `injected` text, and the original vs new fail loci (`origLine`/`origCol`, `newLine`/`newCol`). Consumed by `reportPredictRelax`.
 */
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
 * One field-optionalization candidate surfaced by `apq recon
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
 * `apq recon`'s PREDICTORS — the modes that answer "would this unblock it?".
 *
 * `--predict-strip`, `--predict-relax`, `--permissive` and `--candidates` all
 * re-run the parser over a hypothetical source rather than reporting the one on
 * disk, which is a different job from the sweep and the histogram `ReconCommand`
 * owns.
 */
@:nullSafety(Strict)
final class ReconPredict {

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
			CliIo.stderr('apq recon: --no-target-cluster "$filter" matched no NO TARGET records (predict-relax mode)\n');
			if (noTargetReasonsTop.length > 0) {
				noTargetReasonsTop.sort((a, b) -> b.count - a.count);
				final maxKeys: Int = noTargetReasonsTop.length < ReconCommand.NO_TARGET_TOP_N
					? noTargetReasonsTop.length
					: ReconCommand.NO_TARGET_TOP_N;
				CliIo.stderr('  available NO TARGET keys (top $maxKeys):\n');
				for (entry in noTargetReasonsTop.slice(0, ReconCommand.NO_TARGET_TOP_N)) CliIo.stderr('    ${entry.count}× ${entry.key}\n');
			}
			return EXIT_RUNTIME;
		}
		for (m in matched) reportPredictRelax(m.record.path, m.record.source, m.result, showSource);
		CliIo.sysPrint('--- relax (no-target-cluster "$filter"): ${matched.length} files ---\n');
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
		CliIo.sysPrint(
			'--- relax: $unblockCount unblock, $stillFailCount still fail, $noTargetCount no target (of ${records.length}'
			+ ' skip-parse files) ---\n'
		);
		if (!keepNoTargetPerFile && noTargetReasons.length > 0) {
			noTargetReasons.sort((a, b) -> b.count - a.count);
			CliIo.sysPrint(
				'   no target breakdown ('
				+ 'use --no-target-cluster <key> to drill into a specific shape, or --cluster <locus-key> for forward-locus drill):\n'
			);
			for (entry in noTargetReasons) CliIo.sysPrint('     ${entry.count}× ${entry.key}\n');
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
			names.sort((a: String, b: String) -> if (a < b)
				-1
			else if (a > b)
				1
			else
				0);
			for (name in names) {
				final path: String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!name.endsWith('.hxtest')) continue;
				final relPath: String = ReconCommand.stripRootPrefix(path, root);
				final priorStatus: Null<String> = prior[relPath];
				if (priorStatus == null) continue; // present locally but absent from snapshot — silent
				scanned++;
				final source: String = CliIo.readSourceForParse(path);
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
					CliIo.sysPrint('REGRESSED $relPath: was $priorStatus, now SKIP_PARSE$locus\n');
				} else if (priorSkipParse && current.ok) {
					unblocked++;
					CliIo.sysPrint('UNBLOCKED $relPath: was SKIP_PARSE, now parses OK\n');
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
			return !plugin.reconParse(source)
				? {
					unwired: true,
					ok: false,
					line: 0,
					col: 0,
					msg: ''
				}
				: {
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
				msg: ReconCommand.reconNormalize(exception.expected)
			};
		} catch (exception: Exception) {
			return {
				unwired: false,
				ok: false,
				line: 0,
				col: 0,
				msg: ReconCommand.reconNormalize(exception.message)
			};
		}
	}

	/**
	 * Classify one decl-group's metas as a permissive-construct candidate:
	 * a non-@:optional single Ref with single-char @:lead + @:trail and no
	 * @:sep (Star). Macro/string delimiters (quotes, `$`) are excluded.
	 * Returns null when the group is not a candidate.
	 */
	private static function extractPermissiveCandidate(metas: Array<MetaHit>, source: String, path: String): Null<PermissiveCandidate> {
		final m: PermissiveMetas = readPermissiveMetas(metas);
		if (m.hasOptional || m.lead == null || m.trail == null || m.sep != null) return null;
		final leadStr: String = (m.lead: String);
		final trailStr: String = (m.trail: String);
		// Skip macro/string delimiters — their @:optional
		// relaxation isn't the bracket-pair mechanism (interpolation,
		// string body, etc.).
		if (leadStr.length != 1 || trailStr.length != 1) return null;
		if (leadStr == '"' || leadStr == "'") return null;
		if (leadStr == '$') return null;
		final first: MetaHit = metas[0];
		final fspan: Null<Span> = first.declSpan;
		final pos: Null<Position> = fspan?.lineCol(source);
		return {
			file: path,
			line: pos != null ? pos.line : 0,
			col: pos != null ? pos.col : 0,
			declKind: first.declKind,
			declName: first.declName,
			lead: leadStr,
			trail: trailStr
		};
	}

	/**
	 * Read the @:optional / @:lead / @:trail / @:sep metas off one decl
	 * group (lead/trail are unquoted, sep kept raw).
	 */
	private static function readPermissiveMetas(metas: Array<MetaHit>): PermissiveMetas {
		var hasOptional: Bool = false;
		var lead: Null<String> = null;
		var trail: Null<String> = null;
		var sep: Null<String> = null;
		for (h in metas) switch h.annotation {
			case '@:optional':
				hasOptional = true;
			case '@:lead':
				lead = h.args.length > 0 ? CliArgs.stripQuotes(h.args[0]) : null;
			case '@:trail':
				trail = h.args.length > 0 ? CliArgs.stripQuotes(h.args[0]) : null;
			case '@:sep':
				sep = h.args.length > 0 ? h.args[0] : null;
			case _:
		}
		return {
			hasOptional: hasOptional,
			lead: lead,
			trail: trail,
			sep: sep
		};
	}

	#if (sys || nodejs)
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
	public static function runReconProbeRelax(plugin: GrammarPlugin, path: String, showSource: Bool): Int {
		final original: String = CliIo.readSourceForParse(path);
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
	public static function runReconSweepRelax(
		plugin: GrammarPlugin, root: String, clusterFilter: Null<String>, noTargetClusterFilter: Null<String>, showSource: Bool
	): Int {
		final walk: ReconWalkResult = ReconCommand.collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			CliIo.stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		var records: Array<ReconRecord> = walk.records;
		if (clusterFilter != null) {
			final filter: String = clusterFilter;
			records = records.filter(r -> r.clusterKey == filter);
			if (records.length == 0) {
				CliIo.stderr('apq recon: --cluster "$filter" matched no skip-parse records (predict-relax mode)\n');
				return EXIT_RUNTIME;
			}
		}
		return noTargetClusterFilter != null
			? runReconRelaxNoTargetCluster(plugin, records, noTargetClusterFilter, showSource)
			: runReconRelaxFullSweep(plugin, records, clusterFilter != null, showSource);
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
			// landed after a recent grammar change. Surface as NoTarget with a
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
				CliIo.sysPrint(
					'PREDICT RELAX UNBLOCK   $path :: inserting "${res.injected}" at ${res.origLine}:${res.origCol} unblocks parse\n'
				);
				return EXIT_OK;
			case StillFail:
				final movedHint: String = ReconCommand.movedLocusHint(res.origLine, res.origCol, res.newLine, res.newCol);
				CliIo.sysPrint(
					'PREDICT RELAX STILL FAIL $path :: ${res.newLine}:${res.newCol}$movedHint after inserting "${res.injected}" — '
					+ '${res.message}\n'
				);
				if (showSource && res.newLine > 0) ReconCommand.printReconSourceWindow(res.patched, res.newLine);
				return EXIT_RUNTIME;
			case NoTarget:
				CliIo.sysPrint('PREDICT RELAX NO TARGET $path :: at ${res.origLine}:${res.origCol} — ${res.message}\n');
				// NoTarget has no patched source (the parser found no
				// `expected` hint to inject), so the window is anchored on
				// the ORIGINAL fail-locus. `origLine == 0` is the
				// "already-parseable" / pre-error path (no usable locus);
				// skip the window for those.
				if (showSource && res.origLine > 0) ReconCommand.printReconSourceWindow(res.original, res.origLine);
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
		final t: String = hint.trim();
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
	public static function runReconCandidates(plugin: GrammarPlugin, root: String, pattern: String): Int {
		final re: EReg = try new EReg(pattern, 'g') catch (e: Exception) {
			CliIo.stderr('apq recon: --candidates: pattern "$pattern" is not a valid EReg: ${e.message}\n');
			return EXIT_USAGE;
		}
		final walk: ReconWalkResult = ReconCommand.collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			CliIo.stderr('apq recon: --candidates: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final hits: Array<{ path: String, count: Int }> = [];
		var totalHits: Int = 0;
		for (r in walk.records) {
			final n: Int = StripCommand.countRegexHits(re, r.source);
			if (n <= 0) continue;
			hits.push({ path: r.path, count: n });
			totalHits += n;
		}
		hits.sort((a, b) -> b.count - a.count);
		for (h in hits) CliIo.sysPrint('${h.path} :: ${h.count} match${h.count == 1 ? '' : 'es'}\n');
		CliIo.sysPrint(
			'--- candidates: ${hits.length} file${CliIo.plural(hits.length)} matched ($totalHits total hit${CliIo.plural(totalHits)} across '
			+ '${walk.records.length} skip-parse file${CliIo.plural(walk.records.length)}) ---\n'
		);
		return hits.length == 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * `apq recon --permissive-construct` — field-optionalization
	 * predictor for the `@:optional + @:lead + @:trail` relaxation mechanism.
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
	 * delimiters that don't relax via the bracket-pair optionalization mechanism.
	 *
	 * Output: one block per candidate that has ≥1 UNBLOCK or STILL FAIL
	 * (NO-MATCH-only candidates are summarized in the footer to keep the
	 * useful signal visible).
	 */
	public static function runReconPermissive(plugin: GrammarPlugin, root: String, lang: String): Int {
		final walk: ReconWalkResult = ReconCommand.collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			CliIo.stderr('apq recon: --permissive-construct: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final records: Array<ReconRecord> = walk.records;
		final candidates: Array<PermissiveCandidate> = collectPermissiveCandidates(plugin, lang);
		if (candidates.length == 0) {
			CliIo.stderr(
				'apq recon: --permissive-construct: no mandatory-ref-lead-trail candidates found in src/anyparse/grammar/$lang'
				+ '/ (cross-check with `apq gates --mechanism mandatory-ref-lead-trail`)\n'
			);
			return EXIT_RUNTIME;
		}
		CliIo.sysPrint(
			'=== permissive-construct: ${candidates.length} candidate${CliIo.plural(candidates.length)}'
			+ ' from gates --mechanism mandatory-ref-lead-trail, ${records.length} skip-parse fixture${CliIo.plural(records.length)} ===\n'
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
			final label: String =
				'${cand.file}:${cand.line}: ${cand.declKind}$nameSuffix @:lead(\'${cand.lead}\') @:trail(\'${cand.trail}\')';
			if (unblocks.length == 0 && stillFails.length == 0) {
				noSignalLabels.push('$label ($noMatchCount NO MATCH)');
				continue;
			}
			candidatesWithSignal++;
			totalUnblocks += unblocks.length;
			CliIo.sysPrint('\nCANDIDATE $label\n');
			CliIo.sysPrint('  ${unblocks.length} UNBLOCK / ${stillFails.length} STILL FAIL / $noMatchCount NO MATCH\n');
			for (p in unblocks) CliIo.sysPrint('    UNBLOCK: $p\n');
			for (p in stillFails) CliIo.sysPrint('    STILL FAIL: $p\n');
		}
		CliIo.sysPrint(
			'\n--- permissive-construct summary: $candidatesWithSignal of ${candidates.length} candidate${CliIo.plural(candidates.length)}'
			+ ' have ≥1 UNBLOCK or STILL FAIL ($totalUnblocks UNBLOCK${CliIo.plural(totalUnblocks)} total) across ${records.length}'
			+ ' skip-parse files ---\n'
		);
		if (noSignalLabels.length > 0) {
			CliIo.sysPrint(
				'--- NO MATCH only (${noSignalLabels.length} candidate${CliIo.plural(noSignalLabels.length)} with no fixture match) ---\n'
			);
			for (l in noSignalLabels) CliIo.sysPrint('  $l\n');
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
	 * relaxation isn't the bracket-pair mechanism. Single-char leads only —
	 * the strip function depth-tracker assumes one byte per lead/trail.
	 */
	private static function collectPermissiveCandidates(plugin: GrammarPlugin, lang: String): Array<PermissiveCandidate> {
		final out: Array<PermissiveCandidate> = [];
		final grammarDir: String = 'src/anyparse/grammar/$lang/';
		if (!FileSystem.exists(grammarDir) || !FileSystem.isDirectory(grammarDir)) return out;
		final expanded: ExpandedInputs = CliArgs.expandInputs([grammarDir], '.hx');
		final shape: MetaShape = plugin.metaShape();
		final skipEntries: Array<SkipEntry> = [];
		for (path in expanded.paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('recon', plugin.parseFile, path, source, false, skipEntries);
			if (tree == null) continue;
			final raw: Array<MetaHit> = Meta.find(tree, shape, source);
			final grouped: { order: Array<Int>, groups: Map<Int, Array<MetaHit>> } = GatesCommand.groupMetaHitsByDeclSpan(raw);
			for (key in grouped.order) {
				final metas: Null<Array<MetaHit>> = grouped.groups[key];
				if (metas == null) continue;
				final candidate: Null<PermissiveCandidate> = extractPermissiveCandidate(metas, source, path);
				if (candidate != null) out.push(candidate);
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
		final leadCode: Int = lead.fastCodeAt(0);
		final trailCode: Int = trail.fastCodeAt(0);
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
			final c: Int = source.fastCodeAt(i);
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
			final c: Int = source.fastCodeAt(i);
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
		final c: Int = source.fastCodeAt(i);
		if (c == '/'.code && i + 1 < source.length) {
			final c2: Int = source.fastCodeAt(i + 1);
			if (c2 == '/'.code) {
				var j: Int = i + 2;
				while (j < source.length && source.fastCodeAt(j) != '\n'.code) j++;
				return j;
			}
			if (c2 == '*'.code) {
				var j: Int = i + 2;
				while (j + 1 < source.length) {
					if (source.fastCodeAt(j) == '*'.code && source.fastCodeAt(j + 1) == '/'.code) return j + 2;
					j++;
				}
				return source.length;
			}
		}
		if (c != '"'.code && c != "'".code) return i;
		var j: Int = i + 1;
		while (j < source.length) {
			final cj: Int = source.fastCodeAt(j);
			if (cj == '\\'.code) {
				j += 2;
				continue;
			}
			if (cj == c) return j + 1;
			j++;
		}
		return source.length;
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
	public static function runReconRegressionProbe(plugin: GrammarPlugin, root: String): Int {
		// Load the prior snapshot. Missing / unreadable / malformed JSON
		// is a non-fatal "no baseline" — print a single info line and
		// exit OK so a fresh checkout doesn't fail the probe.
		final snapshotPath: String = 'bin/.last-sweep.json';
		if (!FileSystem.exists(snapshotPath)) {
			CliIo.sysPrint(
				'apq recon: no prior sweep snapshot at $snapshotPath'
				+ ' — run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK first to seed the baseline\n'
			);
			return EXIT_OK;
		}
		final prior: Map<String, String> = SweepCommand.loadSweepFixtureStatus(snapshotPath);
		if (prior.iterator().hasNext() == false) {
			CliIo.sysPrint(
				'apq recon: snapshot at $snapshotPath'
				+ ' has no `fixtures` array — older format, re-run `node bin/test.js` to refresh the baseline\n'
			);
			return EXIT_OK;
		}
		final walk: ReconRegressionResult = walkReconRegression(plugin, root, prior);
		if (walk.unwired) {
			CliIo.stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		CliIo.sysPrint(
			'--- regression-probe: ${walk.regressed} regressed, ${walk.unblocked} unblocked, ${walk.scanned} scanned vs snapshot ---\n'
		);
		return walk.regressed > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	public static function runReconProbePredict(
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
			final hits: Int = regexMode
				? StripCommand.countRegexHits(regexes[idx], stripped)
				: StripCommand.countOccurrences(stripped, patterns[idx]);
			patternHits[idx] = hits;
			fileHits += hits;
			stripped = regexMode ? regexes[idx].replace(stripped, replacements[idx]) : stripped.replace(patterns[idx], replacements[idx]);
		}
		var exitCode: Int = EXIT_OK;
		if (fileHits == 0) {
			CliIo.sysPrint('PREDICT NO MATCH  $path\n');
		} else {
			try {
				if (!plugin.reconParse(stripped)) {
					CliIo.stderr('apq recon: no recon parser wired up for this grammar plugin\n');
					return EXIT_RUNTIME;
				}
				CliIo.sysPrint('PREDICT UNBLOCK   $path\n');
			} catch (pe: ParseError) {
				final pos: Position = pe.span.lineCol(stripped);
				final movedHint: String = ReconCommand.movedLocusHint(origLine, origCol, pos.line, pos.col);
				CliIo.sysPrint('PREDICT STILL FAIL $path :: ${pos.line}:${pos.col}${movedHint} ${pe.message}\n');
				if (showSource) ReconCommand.printReconSourceWindow(stripped, pos.line);
				exitCode = EXIT_RUNTIME;
			} catch (e: Exception) {
				CliIo.sysPrint('PREDICT STILL FAIL $path :: <no locus> ${e.message}\n');
				exitCode = EXIT_RUNTIME;
			}
		}
		// Per-pattern totals — same typo guard contract as sweep mode.
		for (idx => pat in patterns) {
			final total: Int = patternHits[idx];
			CliIo.sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		final anyZero: Bool = patternHits.exists(h -> h == 0);
		if (!anyZero) return exitCode;
		CliIo.stderr('apq recon: --predict-strip --probe: WARNING: one or more patterns matched 0 occurrences — see per-pattern totals\n');
		return EXIT_RUNTIME;
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
	public static function runReconPredictStrip(
		records: Array<ReconRecord>, plugin: GrammarPlugin, patterns: Array<String>, replacements: Array<String>,
		compiledRegex: Null<Array<EReg>>, clusterFilter: Null<String>, showSource: Bool
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
				final hits: Int = regexMode
					? StripCommand.countRegexHits(regexes[idx], stripped)
					: StripCommand.countOccurrences(stripped, patterns[idx]);
				patternHits[idx] += hits;
				fileHits += hits;
				stripped = regexMode
					? regexes[idx].replace(stripped, replacements[idx])
					: stripped.replace(patterns[idx], replacements[idx]);
			}
			if (fileHits == 0) {
				CliIo.sysPrint('PREDICT NO MATCH  ${r.path}\n');
				noMatchCount++;
				continue;
			}
			try {
				if (!plugin.reconParse(stripped)) {
					CliIo.stderr('apq recon: no recon parser wired up for this grammar plugin\n');
					return EXIT_RUNTIME;
				}
				CliIo.sysPrint('PREDICT UNBLOCK   ${r.path}\n');
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
				final movedHint: String = ReconCommand.movedLocusHint(r.line, r.col, pos.line, pos.col);
				CliIo.sysPrint('PREDICT STILL FAIL ${r.path} :: ${pos.line}:${pos.col}${movedHint} ${pe.message}\n');
				if (showSource) ReconCommand.printReconSourceWindow(stripped, pos.line);
				stillFailCount++;
			} catch (e: Exception) {
				CliIo.sysPrint('PREDICT STILL FAIL ${r.path} :: <no locus> ${e.message}\n');
				stillFailCount++;
			}
		}
		CliIo.sysPrint('\n');
		final scope: String = clusterFilter == null ? 'whole sweep' : 'cluster "$clusterFilter"';
		CliIo.sysPrint('--- predict-strip ($scope): ${records.length} skip-parse file${CliIo.plural(records.length)}; ');
		CliIo.sysPrint('$unblockCount would unblock, $stillFailCount still fail, $noMatchCount unchanged ---\n');
		for (idx => pat in patterns) {
			final total: Int = patternHits[idx];
			CliIo.sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		// Mirror `strip --dry-run`: every supplied pattern matching 0
		// across the whole filtered set is a typo signal worth surfacing
		// non-zero. A pattern matching SOMEWHERE but not everywhere is
		// expected behaviour for a targeted predicate; only the global
		// 0 case is the guard.
		final anyZero: Bool = patternHits.exists(h -> h == 0);
		if (!anyZero) return EXIT_OK;
		CliIo.stderr(
			'apq recon: --predict-strip: WARNING: one or more patterns matched 0 occurrences anywhere in the filtered set — see '
			+ 'per-pattern totals\n'
		);
		return EXIT_RUNTIME;
	}
	#end

}
