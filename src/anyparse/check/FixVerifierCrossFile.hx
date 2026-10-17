package anyparse.check;

import anyparse.check.Check.RiskyArm;
import anyparse.check.Check.RiskyCrossFileEdit;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle.OracleExclusion;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCoverage.OracleCoverageMemo;
import anyparse.check.OracleCoverage.UsableCoverage;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

using Lambda;

/**
 * `FixVerifier`'s CROSS-FILE half: a risky arm's multi-file edit sets (`RiskyArm.riskyCrossFileFix`)
 * written, typechecked and reverted AS A WHOLE. A cross-file rename half-applied does not compile, so
 * the per-file loop's unit — one file's edits — cannot judge one; the unit here is one edit set, over
 * every file it touches.
 *
 * Edit sets that share a file form one COMPONENT and are judged together: their spans are relative to
 * the same original sources, so they combine without re-resolution, and a component that builds costs
 * one typecheck per covering configuration however many renames it carries. A rejected component is
 * bisected over its edit sets with the per-file loop's own search (`FixVerifier.isolateFailers`), the
 * complement confirm-typechecked before anything is kept.
 *
 * Coverage is asked per component before anything is written: every file it edits must be compiled by
 * some judging configuration, or the component is DECLINED — a typecheck that cannot read one of the
 * files would confirm a rename it never saw half of.
 */
@:nullSafety(Strict)
@:access(anyparse.check.FixVerifier)
final class FixVerifierCrossFile {

	/**
	 * `result` — the per-file arms' verdicts — with every `RiskyArm` of `run` asked for its cross-file edit sets and
	 * those verified, over `files` as the per-file arms left them. Each arm's findings are collected AGAIN for this,
	 * since an edit there moved every span after it. The compiled-set answer is `run.memo`'s, the one the per-file
	 * phase asked; when it is unknown here it was asked for the first time here, and the result says so the way the
	 * per-file phase does (`coverageUnknown`, no tallies).
	 */
	public static function extend(
		result: FixVerifyResult, run: CrossFileRun, files: Array<{ file: String, source: String }>
	): FixVerifyResult {
		for (check in run.checks) if (check is RiskyArm) {
			final arm: RiskyArm = cast check;
			final cross: Array<Violation> = arm.riskyCrossFileFindings(
				Linter.collect(files, run.plugin, [check], run.resolveConfig, run.applyEnablement).filter(v -> v.rule == check.id())
			);
			if (cross.length == 0) continue;
			final usable: UsableCoverage = OracleCoverage.usableOnce(run.memo, run.judging, result.excluded);
			result.coverage = run.memo.probes;
			final unknown: Null<String> = usable.stop;
			if (unknown != null) {
				result.coverageUnknown = unknown;
				result.tallies = [];
				return result;
			}
			final sets: Array<RiskyCrossFileEdit> = arm.riskyCrossFileFix(files, cross, run.plugin, IndexScope.report(files, run.plugin));
			final verdicts: CrossFileVerdicts = verify(
				files, check.id(), cross, sets, run.plugin, run.opts, usable, result.excluded, run.write
			);
			for (file in verdicts.applied) if (!result.applied.contains(file)) result.applied.push(file);
			result.appliedEdits += verdicts.appliedEdits;
			result.reverted = result.reverted.concat(verdicts.reverted);
			result.declined = result.declined.concat(verdicts.declined);
			result.tallies = result.tallies.concat(verdicts.tallies);
		}
		return result;
	}

	/**
	 * Verify `sets` (the arm's answer for `findings`, `rule`'s own) over `files`, writing every decided text
	 * through `write` and into `files`. The tallies cover EVERY finding in `findings`, the ones the arm refused
	 * included, one row per file a finding sits in.
	 */
	private static function verify(
		files: Array<{ file: String, source: String }>, rule: String, findings: Array<Violation>, sets: Array<RiskyCrossFileEdit>,
		plugin: GrammarPlugin, optsByFile: Null<Map<String, Null<String>>>, usable: UsableCoverage, excluded: Array<OracleExclusion>,
		write: (String, String) -> Void
	): CrossFileVerdicts {
		final out: CrossFileVerdicts = {
			applied: [],
			appliedEdits: 0,
			reverted: [],
			declined: [],
			tallies: []
		};
		final kept: Array<RiskyCrossFileEdit> = [];
		for (component in componentsOf(sets)) {
			final judge: Judge = {
				files: files,
				sets: component,
				plugin: plugin,
				opts: optsByFile,
				usable: usable,
				excluded: excluded,
				write: write
			};
			switch judgeComponent(judge) {
				case Kept(landed):
					for (set in landed) kept.push(set);
					for (set in landed) for (slice in set.slices) if (!out.applied.contains(slice.file)) out.applied.push(slice.file);
					for (set in landed) out.appliedEdits += editCount(set);
					for (set in component) if (!landed.contains(set))
						out.reverted.push(revertOf(set, rule, OracleRejected));
				case Reverted(cause):
					for (set in component) out.reverted.push(revertOf(set, rule, cause));
				case Declined(reason):
					for (set in component) out.declined.push({
						file: set.violation.file,
						rule: rule,
						edits: editCount(set),
						reason: reason
					});
			}
		}
		out.tallies = talliesOf(rule, findings, kept);
		return out;
	}

	/**
	 * The edit sets grouped by shared file: two sets touching one file land in one component, transitively.
	 * Order is first appearance, so a fixture's verdicts are reproducible.
	 */
	private static function componentsOf(sets: Array<RiskyCrossFileEdit>): Array<Array<RiskyCrossFileEdit>> {
		final groups: Array<{ sets: Array<RiskyCrossFileEdit>, files: Array<String> }> = [];
		for (set in sets) {
			final touched: Array<String> = [for (slice in set.slices) slice.file];
			final merged: { sets: Array<RiskyCrossFileEdit>, files: Array<String> } = { sets: [set], files: touched.copy() };
			for (group in groups.copy()) if (group.files.exists(f -> touched.contains(f))) {
				groups.remove(group);
				merged.sets = group.sets.concat(merged.sets);
				for (f in group.files) if (!merged.files.contains(f)) merged.files.push(f);
			}
			groups.push(merged);
		}
		return [for (group in groups) group.sets];
	}

	/** Every file `judge`'s edit sets touch, at its current text, or null when one of them is not among the run's files. */
	private static function originalsOf(judge: Judge): Null<Map<String, String>> {
		final out: Map<String, String> = [];
		for (set in judge.sets) for (slice in set.slices) if (!out.exists(slice.file)) {
			final entry: Null<{ file: String, source: String }> = judge.files.find(f -> f.file == slice.file);
			if (entry == null) return null;
			out[slice.file] = entry.source;
		}
		return out;
	}

	/** The verdict on one component — see the type doc. Leaves the disk and `judge.files` at the decided text. */
	private static function judgeComponent(judge: Judge): ComponentVerdict {
		final originals: Null<Map<String, String>> = originalsOf(judge);
		if (originals == null) return Reverted(NotCanonical('an edit set touches a file that is not one of the run\'s files'));
		final before: Map<String, String> = originals;
		final verifying: Null<Array<OracleConfig>> = coveringConfigs(judge, before);
		if (verifying == null)
			return Declined(OracleCoverage.gapSentence(
				['a file this rename edits is compiled by no judging configuration'].concat(CompilerOracle.sentencesOf(judge.excluded))
			));
		final configs: Array<OracleConfig> = verifying;
		final n: Int = judge.sets.length;
		function restore(): Void {
			for (file => text in before) judge.write(file, text);
		}
		function attempt(indices: Array<Int>): Null<OracleOutcome> {
			final texts: Null<Map<String, String>> = candidate(judge, before, indices);
			if (texts == null) return null;
			for (file => text in texts) judge.write(file, text);
			return CompilerOracle.typecheckAll(configs);
		}
		function keep(indices: Array<Int>): ComponentVerdict {
			final texts: Null<Map<String, String>> = candidate(judge, before, indices);
			if (texts != null) for (file => text in texts) for (entry in judge.files) if (entry.file == file) entry.source = text;
			return Kept([for (i in indices) judge.sets[i]]);
		}
		final all: Array<Int> = [for (i in 0...n) i];
		final settled: Null<ComponentVerdict> = wholeVerdict(attempt(all), n);
		if (settled != null) {
			if (settled.match(Kept(_))) return keep(all);
			restore();
			return settled;
		}
		final spent: Array<Int> = [0];
		final failers: Null<Array<Int>> = FixVerifier.isolateFailers(
			n, 2 * FixVerifier.ceilLog2(n), indices -> attempt(indices)?.match(Confirmed) == true, spent
		);
		final safe: Array<Int> = failers == null ? [] : [for (i in all) if (!failers.contains(i)) i];
		if (safe.length > 0 && attempt(safe)?.match(Confirmed) == true) return keep(safe);
		restore();
		return Reverted(OracleRejected);
	}

	/**
	 * What the WHOLE component's typecheck `outcome` settles on its own, or null when the edit sets must be bisected:
	 * a confirmation keeps them all (`Kept`, its sets filled in by the caller), an unavailable oracle reverts them, and so
	 * does a rejection or a writer refusal (`outcome == null`) of a single set — there is nothing to bisect.
	 */
	private static function wholeVerdict(outcome: Null<OracleOutcome>, n: Int): Null<ComponentVerdict> {
		if (outcome == null) return n < 2 ? Reverted(NotCanonical('the writer refused the rewritten files')) : null;
		return switch outcome {
			case Confirmed: Kept([]);
			case Unavailable(reason): Reverted(OracleUnavailable(reason));
			case Rejected(_): n < 2 ? Reverted(OracleRejected) : null;
		};
	}

	/**
	 * The configurations that judge a component: every one compiling at least one file it edits, plus every
	 * one whose compiled set is unknown — or null when some edited file is compiled by none of them.
	 */
	private static function coveringConfigs(judge: Judge, before: Map<String, String>): Null<Array<OracleConfig>> {
		final out: Array<OracleConfig> = [];
		for (file => source in before) {
			final spans: Array<Span> = [
				for (set in judge.sets) for (slice in set.slices) if (slice.file == file) for (edit in slice.edits) edit.span
			];
			final regions: Array<LexRegion> = judge.plugin.lexicalRegions(source);
			var covered: Bool = false;
			for (i in 0...judge.usable.configs.length) if (judge.usable.coverages[i].uncovered(
				file, source, spans, judge.plugin.refShape(), regions
			) == null) {
				covered = true;
				if (!out.contains(judge.usable.configs[i])) out.push(judge.usable.configs[i]);
			}
			if (!covered) return null;
		}
		for (config in judge.usable.unknown) if (!out.contains(config)) out.push(config);
		return out;
	}

	/**
	 * Each edited file's text with the edit sets at `indices` applied to its ORIGINAL source, or null when the
	 * writer refuses one of them. A file none of those sets touches answers its original text, so writing the
	 * map restores it.
	 */
	private static function candidate(judge: Judge, before: Map<String, String>, indices: Array<Int>): Null<Map<String, String>> {
		final out: Map<String, String> = [];
		for (file => source in before) {
			final edits: Array<{ span: Span, text: String }> = [];
			for (i in indices) for (slice in judge.sets[i].slices) if (slice.file == file) for (edit in slice.edits) edits.push(edit);
			if (edits.length == 0) {
				out[file] = source;
				continue;
			}
			final opts: Null<String> = judge.opts == null ? null : judge.opts[file];
			switch CanonicalEdit.canonicalize(source, edits, false, judge.plugin, opts) {
				case Ok(text):
					out[file] = text;
				case Err(_):
					return null;
			}
		}
		return out;
	}

	/** The revert record for `set`: the file its finding sits in, under `rule`. */
	private static inline function revertOf(set: RiskyCrossFileEdit, rule: String, cause: FixRevertCause): FixVerifyRevert {
		return { file: set.violation.file, rule: rule, cause: cause };
	}

	/** The number of edits `set` makes across all its files. */
	private static function editCount(set: RiskyCrossFileEdit): Int {
		var n: Int = 0;
		for (slice in set.slices) n += slice.edits.length;
		return n;
	}

	/**
	 * The tally rows for `findings`: per file a finding sits in, one row for the findings whose edit set LANDED
	 * (its edits all count there, wherever they were written) and one for the rest, carrying the sentences the
	 * arm wrote on them. Two rows rather than one, because the ledger reads a row with edits as fixed and would
	 * drop the refusals of a file where one rename landed and another was refused.
	 */
	private static function talliesOf(rule: String, findings: Array<Violation>, kept: Array<RiskyCrossFileEdit>): Array<FixVerifyTally> {
		final rows: Array<FixVerifyTally> = [];
		for (v in findings) {
			final set: Null<RiskyCrossFileEdit> = kept.find(s -> s.violation == v);
			final landed: Bool = set != null;
			var row: Null<FixVerifyTally> = rows.find(r -> r.file == v.file && (r.edits > 0) == landed);
			if (row == null) {
				final fresh: FixVerifyTally = {
					rule: rule,
					file: v.file,
					findings: 0,
					edits: 0,
					declineReasons: []
				};
				rows.push(fresh);
				row = fresh;
			}
			final tally: FixVerifyTally = row;
			tally.findings++;
			if (set != null) {
				tally.edits += editCount(set);
				continue;
			}
			final reason: Null<String> = v.declineReason;
			if (reason == null) continue;
			final seen: Null<{ text: String, count: Int }> = tally.declineReasons.find(r -> r.text == reason);
			if (seen != null)
				seen.count++
			else
				tally.declineReasons.push({ text: reason, count: 1 });
		}
		return rows;
	}

}

/** What the cross-file half adds to a `FixVerifyResult`. */
typedef CrossFileVerdicts = {
	var applied: Array<String>;
	var appliedEdits: Int;
	var reverted: Array<FixVerifyRevert>;
	var declined: Array<FixVerifyDecline>;
	var tallies: Array<FixVerifyTally>;
};

/** What `FixVerifierCrossFile.extend` reads of the verifier's run beside its result. */
typedef CrossFileRun = {
	final checks: Array<Check>;
	final plugin: GrammarPlugin;
	final opts: Null<Map<String, Null<String>>>;
	final memo: OracleCoverageMemo;
	final judging: Array<OracleConfig>;
	final write: (String, String) -> Void;
	final resolveConfig: Null<(String) -> LintConfig>;
	final applyEnablement: Bool;
};

/** Everything one component's verdict reads. */
private typedef Judge = {
	final files: Array<{ file: String, source: String }>;
	final sets: Array<RiskyCrossFileEdit>;
	final plugin: GrammarPlugin;
	final opts: Null<Map<String, Null<String>>>;
	final usable: UsableCoverage;
	final excluded: Array<OracleExclusion>;
	final write: (String, String) -> Void;
};

/** One component's verdict: the edit sets kept on disk, a whole revert, or a decline before anything was written. */
private enum ComponentVerdict {
	Kept(sets: Array<RiskyCrossFileEdit>);
	Reverted(cause: FixRevertCause);
	Declined(reason: String);
}
