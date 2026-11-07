package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.common.design.ThreadSafety;
import anyparse.check.common.design.threads.LongLockExplain.LongLockReport;
import anyparse.query.Address.TreeAddresser;
import anyparse.query.LintDiff.LintDiffTally;
import anyparse.query.LintDiff.LintMessageIdentities;
import anyparse.query.cli.command.LintCommand.LintOpts;
import anyparse.query.cli.command.LintCommand.LintRange;
import anyparse.query.format.LintFormat;
import anyparse.query.format.Text;
import anyparse.runtime.Span;

using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * The one answer to "what does an `apq lint` run print": which findings are shown, the text / JSON / checkstyle report
 * or the per-rule summary, and the baseline snapshot delta.
 */
@:nullSafety(Strict)
final class LintReport {

	/**
	 * Whether the TEXT report prints `LintFormat.summary` instead of one line per finding.
	 *
	 * `shown` is what the report would list — after the `--all` cap, so hidden advisories never tip a
	 * run into a summary. `forced` is `--summary` (true) / `--full` (false) and wins outright; with
	 * neither, a run listing more than `threshold` findings is summarised, and a `threshold` of zero or
	 * less never is. json and checkstyle are never summarised: their stdout is the answer a tool reads.
	 *
	 * `--rule` is deliberately NOT a second switch. A narrowed run is small in the common case and so
	 * keeps its list by the same threshold; one that is still over it (a single rule across a whole
	 * tree) gets the summary, which for one rule is a by-file breakdown.
	 */
	public static inline function summarises(shown: Int, format: String, forced: Null<Bool>, threshold: Int): Bool {
		return format == LintArgs.FORMAT_TEXT && (forced ?? (threshold > 0 && shown > threshold));
	}

	/**
	 * The findings the REPORT carries, out of everything the run produced.
	 *
	 * `--all` off hides `Info` advisories — a READABILITY affordance for the text report, where a
	 * terminal reader gets the errors and warnings and is TOLD on stderr what was withheld. A machine
	 * format has no such reader: its stdout IS the answer, and a consumer redirecting it keeps nothing
	 * of the stderr note. Capping there returned a truncated record set with nothing in band to say
	 * so — `[]` for a run holding findings, while `--fail-on info` (which counts every finding, capped
	 * or not) exits 1 on that same run. The payload and the exit code disagreed, and the payload was
	 * the one that was wrong; `--all` now governs the human report alone.
	 */
	public static function reportedViolations(all: Array<Violation>, includeInfo: Bool, format: String): Array<Violation> {
		return includeInfo || format == LintArgs.FORMAT_JSON || format == LintArgs.FORMAT_CHECKSTYLE
			? all
			: all.filter(v -> v.severity != Severity.Info);
	}

	/**
	 * The findings a `--range` window keeps: those whose span STARTS on a line inside it.
	 *
	 * A null window keeps everything, so both lint paths — the report and every pass of
	 * the fix loop — call this unconditionally and the flag cannot come to mean two
	 * different things in the two of them. `sourceOf` answers the file's CURRENT bytes,
	 * which is what makes the window re-measurable per pass; see `LintRange`.
	 */
	public static function withinRange(
		all: Array<Violation>, sourceOf: (String) -> Null<String>, range: Null<LintRange>
	): Array<Violation> {
		if (range == null) return all;
		final windows: LintRange = range;
		return all.filter(v -> {
			final span: Null<Span> = v.span;
			final source: Null<String> = sourceOf(v.file);
			if (span == null || source == null) return false;
			final line: Int = span.lineCol(source).line;
			return windows.exists(window -> line >= window.from && line <= window.to);
		});
	}

	/**
	 * The report half of a report-mode run: the findings on stdout — listed, or summarised when
	 * `summarises` says so under the threshold `config` declares — then the stderr breakdown, closed by
	 * the way to the full list when the stdout was a summary. `config` is the run's first path's, the
	 * one every project-level key is read off.
	 */
	public static function reportFindings(
		o: LintOpts, paths: Array<String>, all: Array<Violation>, shown: Array<Violation>, sourceOf: Map<String, String>,
		cached: CachingGrammarPlugin, config: Null<LintConfig>, skipped: Array<String>, explainer: Null<ThreadSafety>
	): Void {
		final threshold: Int = config?.reportSummaryThreshold() ?? LintFormat.DEFAULT_REPORT_SUMMARY_THRESHOLD;
		final summarised: Bool = summarises(shown.length, o.format, o.summary, threshold);
		// a finding naming no file (a rule's own option it could not read) closes the report under the path `''`, in every
		// format, rather than only counting in the summary line
		renderLintReport(
			paths.concat(['']), shown, sourceOf, o.format, o.flat, cached, summarised, LintExplainLong.outcome(o.explainLong, explainer)
		);
		lintSummary(all, paths, shown.length == all.length, summarised ? summaryHint(shown.length, o.summary, threshold) : null, skipped);
	}

	/**
	 * `found` narrowed to what the `--baseline` snapshot does not already carry, and the
	 * snapshot refreshed with `found` itself.
	 *
	 * The IO half of `LintBaseline` — the one place that reads the file, catches what a
	 * missing or malformed snapshot throws, and writes the new one. `LintBaseline.added` is
	 * pure and knows none of it.
	 *
	 * THE SNAPSHOT IS THE FULL SET, never the delta. Writing the delta would make each run's
	 * baseline the previous run's surplus, so a finding reported once would be reported again
	 * on the next edit and the second answer would be wrong in the direction that matters —
	 * the reader would stop believing the first.
	 *
	 * A snapshot that cannot be READ is not fatal and not silent: every finding is reported
	 * (the fail-open direction for a nudge — say too much rather than nothing) and the reason
	 * is named, because "0 new" and "could not compare" look identical otherwise. A snapshot
	 * that cannot be WRITTEN is the same shape: the run's own answer stands, and the next run
	 * will simply have no baseline again.
	 */
	public static function baselineDelta(found: Array<Violation>, path: Null<String>, sourceOf: Map<String, String>): Array<Violation> {
		#if (sys || nodejs)
		if (path == null) return found;
		final snapshot: String = path;
		// The rule -> `messageIdentity` map, asked of the check registry exactly as `lint-diff`
		// asks it, so a rule that masks a coordinate in its message masks it on both sides.
		final identities: LintMessageIdentities = Linter.messageIdentities();
		var delta: Array<Violation> = found;
		// A path that exists and is not a lint report is not a stale snapshot — it is a file the caller
		// named by mistake, and the refresh below would atomically REPLACE its content. `--baseline`
		// carries no `--write` and no `--fix`, so a mistyped path must not be able to destroy a file.
		var refresh: Bool = true;
		if (FileSystem.exists(snapshot)) try {
			final before: LintDiffTally = LintDiff.tally(LintDiff.parseReport(CliIo.readFile(snapshot)), '', identities);
			delta = LintBaseline.added(found, before, '', identities);
			CliIo.stderr('apq lint: baseline $snapshot: ${delta.length} new of ${found.length} finding(s)\n');
		} catch (exception: Exception) {
			refresh = false;
			CliIo.stderr(
				'apq lint: baseline $snapshot is unreadable (${exception.message}) — reporting every finding'
				+ ' and leaving the file alone; delete it to start a fresh snapshot\n'
			);
		}
		if (refresh) try
			CliIo.writeFile(snapshot, LintFormat.json(found, sourceOf))
		catch (exception: Exception)
			CliIo.stderr('apq lint: baseline $snapshot could not be refreshed (${exception.message})\n');
		return delta;
		#else
		return found;
		#end
	}

	/** Source-offset sort key for a violation span; null spans sort last. */
	private static inline function spanStart(span: Null<Span>): Int {
		return span != null ? span.from : CliArgs.MAX_INT;
	}

	/** The stderr line that closes a summarised report: why it is a summary, and the ways to the full list. */
	private static function summaryHint(shown: Int, forced: Null<Bool>, threshold: Int): String {
		final why: String = forced == true ? '--summary' : '$shown finding(s), over the reportSummaryThreshold of $threshold';
		return 'apq lint: summarised ($why) — the full list: --full, or narrow with --rule <id> / a smaller scope, or --format json\n';
	}

	private static function renderLintReport(
		paths: Array<String>, shown: Array<Violation>, sourceOf: Map<String, String>, format: String, flat: Bool,
		plugin: CachingGrammarPlugin, summarised: Bool, explain: Null<ExplainedLocks>
	): Void {
		// Group findings per file, each group sorted by source position so the report
		// reads top-to-bottom. ONE pass rather than a filter per path: that scan was
		// O(paths x findings) and the text branch below ran a second one. `paths` is
		// deduplicated and order-preserving (`expandFor`), and a file's findings enter
		// a group in `shown` order exactly as the filter yielded them, so every format's
		// emitted sequence is unchanged.
		final byFile: Map<String, Array<Violation>> = [];
		for (v in shown) {
			final group: Null<Array<Violation>> = byFile[v.file];
			if (group == null)
				byFile[v.file] = [v];
			else
				group.push(v);
		}
		for (group in byFile) group.sort((a, b) -> spanStart(a.span) - spanStart(b.span));
		// The two record formats want the groups concatenated in input-file order; the text
		// branch prints them one group at a time and needs no such array.
		inline function orderedByPath(): Array<Violation> {
			final flatten: Array<Violation> = [];
			for (path in paths) {
				final group: Null<Array<Violation>> = byFile[path];
				if (group != null) for (v in group) flatten.push(v);
			}
			return flatten;
		}

		switch format {
			case LintArgs.FORMAT_JSON:
				// Each record carries the finding's canonical edit-stable selector
				// (`address`) — directly usable as a mutation-op --select argument.
				// The plugin is the one the CHECKS just ran through, so its parse cache
				// already holds every reported file; a fresh wrapper here would parse each
				// of them a second time, which dominated the whole annotation.
				final ordered: Array<Violation> = orderedByPath();
				// Addressing a node probes its tree several times, so an index per FINDING
				// makes the annotation cost far more than the analysis it annotates.
				// `ordered` groups a file's findings together, so the addresser's ONE slot
				// serves a whole file and retains nothing past it — it is a local of this
				// call, which is the run-scoped place for the memo. The slot keys on the
				// TREE, not the path: the parse cache is keyed by CONTENT, and an index
				// handed a node it never saw degrades every address to `<line>:<col>` in
				// silence.
				final addresser: TreeAddresser = new TreeAddresser(plugin.selectKindEquivalence());
				CliIo.sysPrint(LintFormat.json(ordered, sourceOf, v -> {
					final span: Null<Span> = v.span;
					final source: Null<String> = sourceOf[v.file];
					if (span == null || source == null) return null;
					final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
					return tree == null ? null : addresser.addressAt(tree, source, span.from);
				}, explain));
			case LintArgs.FORMAT_CHECKSTYLE:
				CliIo.sysPrint(LintFormat.checkstyle(orderedByPath(), sourceOf));
			case _ if (summarised):
				CliIo.sysPrint(LintFormat.summary(shown));
			case _:
				for (path in paths) {
					final group: Null<Array<Violation>> = byFile[path];
					if (group != null) CliIo.sysPrint(Text.renderViolations(path, sourceOf[path] ?? '', group, flat));
				}
		}
		final longLocks: Null<LongLockReport> = explain?.report;
		if (format == LintArgs.FORMAT_TEXT && longLocks != null)
			CliIo.sysPrint((shown.length > 0 ? '\n' : '') + LintFormat.longLocksText(longLocks, sourceOf));
	}

	/**
	 * The stderr breakdown under a lint report: the files the grammar could not read, the severity
	 * counts, when the report was CAPPED how much it withheld, and — when it was summarised — `hint`, the way to
	 * the full list (null otherwise).
	 *
	 * `reportedAll` is what the report actually carried, not the `--all` flag: a machine format is
	 * never capped, so telling its reader that advisories were hidden would be a lie the run has no
	 * way to make true.
	 */
	private static function lintSummary(
		all: Array<Violation>, paths: Array<String>, reportedAll: Bool, hint: Null<String>, ?skipped: Array<String>
	): Void {
		// A file the grammar cannot read is a hole in the analysis, and one that stays SILENT
		// otherwise: the per-member confinement gates decline for anything such a file mentions,
		// and nothing in the report says so. Naming the files is what lets a reader tell "no
		// findings" from "could not look".
		if (skipped != null && skipped.length > 0) {
			CliIo.stderr('apq lint: ${skipped.length} file(s) could not be parsed and are invisible to cross-file proofs:\n');
			for (path in skipped.slice(0, CliWalk.SKIP_PATHS_SHOWN)) CliIo.stderr('  $path\n');
			if (skipped.length > CliWalk.SKIP_PATHS_SHOWN) CliIo.stderr('  ... +${skipped.length - CliWalk.SKIP_PATHS_SHOWN} more\n');
		}
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
			CliIo.stderr('apq lint: no issues in ${paths.length} file(s)\n');
		} else {
			CliIo.stderr('apq lint: $errors error(s), $warnings warning(s), $infos info(s) in ${paths.length} file(s)\n');
			if (!reportedAll && infos > 0) CliIo.stderr('apq lint: $infos info advisory(ies) hidden — pass --all to show\n');
		}
		if (hint != null) CliIo.stderr(hint);
	}

}
