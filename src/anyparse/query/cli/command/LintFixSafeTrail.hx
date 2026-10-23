package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.query.Cli.RuleEdits;
import anyparse.query.LintFixSafePass;

using Lambda;

/** One per-file pass that rewrote a file: the text it started from and the rule groups whose edits landed. */
typedef SafeFixStep = {
	final base: String;
	final groups: Array<RuleEdits>;
};

/**
 * What the safe rounds of one `lint --fix` run recorded about their own edits: per file, the per-file passes that
 * rewrote it and every rule that edited it, so a round the compiler rejects can be cut down to the edits it rejects
 * (`LintFixSafePass.isolate`) — and the (file, rule) pairs a revert took back, so no later round of the run applies
 * them again. One instance per run and nothing static: the record is the run's, never the process's.
 */
@:nullSafety(Strict)
final class LintFixSafeTrail {

	/** Per file, each per-file pass that rewrote it this round: the text it started from and the rule groups that landed. */
	private final _steps: Map<String, Array<SafeFixStep>> = [];

	/** Per file, every rule that edited it this round, the cross-file rules included. */
	private final _rules: Map<String, Array<String>> = [];

	/** The (file, rule) pairs a safe-pass revert took back this run. */
	private final _banned: Array<{ file: String, rule: String }> = [];

	/** The canonical text of `base` with the edits of `groups` alone applied, or null when the writer refuses them. */
	private final _replayer: (file:String, base:String, groups:Array<RuleEdits>) -> Null<String>;

	public function new(replayer: (file:String, base:String, groups:Array<RuleEdits>) -> Null<String>) {
		_replayer = replayer;
	}

	/** Forget what the previous round recorded; the bans stay for the run. */
	public function startRound(): Void {
		_steps.clear();
		_rules.clear();
	}

	/** Record that `rule` edited `file` this round. */
	public function noteRule(file: String, rule: String): Void {
		final list: Array<String> = _rules[file] ?? [];
		if (!list.contains(rule)) list.push(rule);
		_rules[file] = list;
	}

	/** Record one per-file pass that rewrote `file` from `base` with `groups`, the groups whose edits landed. */
	public function noteStep(file: String, base: String, groups: Array<RuleEdits>): Void {
		final list: Array<SafeFixStep> = _steps[file] ?? [];
		list.push({ base: base, groups: groups });
		_steps[file] = list;
		for (group in groups) noteRule(file, group.rule);
	}

	/** Whether a revert earlier in this run took `rule`'s edits in `file` back. */
	public function isBanned(file: String, rule: String): Bool {
		return _banned.exists(pair -> pair.file == file && pair.rule == rule);
	}

	/** Every rule that edited `file` this round. */
	public function rulesOf(file: String): Array<String> {
		return (_rules[file] ?? []).copy();
	}

	/** Never apply the culprits' rules again this run in the files the net took them back from. */
	public function ban(culprits: Array<SafeCulprit>): Void {
		for (culprit in culprits)
			for (rule in culprit.rules)
				if (!isBanned(culprit.file, rule)) _banned.push({ file: culprit.file, rule: rule });
	}

	/** `ban` for files the net reverted whole: every rule that edited them this round. */
	public function banFiles(files: Array<String>): Void {
		ban([for (file in files) { file: file, rules: rulesOf(file), kept: null }]);
	}

	/** How many of the first-pass edits of `culprit.file` the split KEPT — the ones whose rule the compiler accepted. */
	public function keptEdits(culprit: SafeCulprit): Int {
		final first: Null<SafeFixStep> = firstStep(culprit.file);
		return first == null
			? 0
			: LintFixDriver.contributedEdits([for (group in first.groups) if (!culprit.rules.contains(group.rule)) group]).length;
	}

	/**
	 * The IO a bisection of this round runs through: a probe puts its candidate on disk — `keep` at the bytes the round
	 * left (`fixedOf`), `partial` at the given texts, every other written file at its pre-round bytes (`originalOf`), a
	 * file with no bytes on that side deleted — and typechecks it over `judging`.
	 */
	public function seat(
		changed: Array<String>, coupled: Array<Array<String>>, originalOf: Map<String, String>, fixedOf: Map<String, String>,
		judging: Array<OracleConfig>
	): SafeBisectSeat {
		return {
			probe: (keep, partial) -> {
				place(
					changed,
					file -> if (partial.exists(file))
						partial[file]
					else if (keep.contains(file))
						fixedOf[file]
					else
						originalOf[file]
				);
				CompilerOracle.typecheckAll(judging);
			},
			splitRules: file -> splitRules(file, changed, coupled, originalOf),
			replay: replay,
			rulesOf: rulesOf,
			fixed: file -> fixedOf[file]
		};
	}

	/**
	 * The rules of `file`'s first per-file pass, when that pass can be replayed one subset at a time: it started from the
	 * round's own bytes and the file is not one of several a cross-file fix committed together. Empty otherwise.
	 */
	private function splitRules(
		file: String, changed: Array<String>, coupled: Array<Array<String>>, originalOf: Map<String, String>
	): Array<String> {
		final first: Null<SafeFixStep> = firstStep(file);
		if (first == null || first.base != originalOf[file]) return [];
		if (coupled.exists(group -> group.contains(file) && group.exists(other -> other != file && changed.contains(other)))) return [];
		final rules: Array<String> = [];
		for (group in first.groups) if (!rules.contains(group.rule)) rules.push(group.rule);
		return rules;
	}

	/** The first per-file pass that rewrote `file` this round, or null when none did. */
	private function firstStep(file: String): Null<SafeFixStep> {
		final list: Null<Array<SafeFixStep>> = _steps[file];
		return list == null || list.length == 0 ? null : list[0];
	}

	/**
	 * `file`'s first per-file pass replayed with the groups of `rules`
	 * alone, or null when the writer refuses them or they change nothing.
	 */
	private function replay(file: String, rules: Array<String>): Null<String> {
		final first: Null<SafeFixStep> = firstStep(file);
		if (first == null) return null;
		final groups: Array<RuleEdits> = [for (group in first.groups) if (rules.contains(group.rule)) group];
		if (groups.length == 0) return null;
		final text: Null<String> = _replayer(file, first.base, groups);
		return text == first.base ? null : text;
	}

	/**
	 * Put the cut a bisection settled on in place, on disk and in `files`: every written file it did not blame at the
	 * bytes the round left, a split culprit at the text it kept, and a whole culprit back at its pre-round bytes through
	 * `restore` — the same sink the attributing narrowing reverts through. Answers every file the net took edits back
	 * from, whole or in part.
	 */
	public static function settle(
		culprits: Array<SafeCulprit>, changed: Array<String>, files: Array<{ file: String, source: String }>,
		originalOf: Map<String, String>, fixedOf: Map<String, String>, created: Array<String>, restore: (Array<String>) -> Void
	): Array<String> {
		function target(file: String): Null<String> {
			final culprit: Null<SafeCulprit> = culprits.find(c -> c.file == file);
			return culprit == null ? fixedOf[file] : culprit.kept ?? originalOf[file];
		}
		place(changed, target);
		for (file in changed) if (!culprits.exists(c -> c.file == file && c.kept == null))
			hold(files, created, originalOf, file, target(file));
		restore([for (culprit in culprits) if (culprit.kept == null) culprit.file]);
		return [for (culprit in culprits) culprit.file];
	}

	/** Take every finding a revert earlier in this run banned out of `violations`, in place; a run with no trail keeps them all. */
	public static function dropBanned(trail: Null<LintFixSafeTrail>, violations: Array<Violation>): Void {
		if (trail != null) for (v in violations.copy()) if (trail.isBanned(v.file, v.rule)) violations.remove(v);
	}

	/** Record `rule` against every file one cross-file fix's slices touch. */
	public static function noteSlices(trail: Null<LintFixSafeTrail>, slices: Array<CrossFileEdits>, rule: String): Void {
		if (trail != null) for (slice in slices) trail.noteRule(slice.file, rule);
	}

	/** Record a per-file pass that landed `landed` edits in `file` from `base`: the groups of `groups` whose edits it wrote. */
	public static function noteLanded(
		trail: Null<LintFixSafeTrail>, file: String, base: String, groups: Array<RuleEdits>, landed: Int
	): Void {
		if (trail != null && landed > 0) trail.noteStep(file, base, [for (group in groups) if (LintFixDriver.contributes(group)) group]);
	}

	/** Write every file of `changed` whose `textOf` is a text and delete every one whose is null — one `writeFiles`. */
	private static function place(changed: Array<String>, textOf: (String) -> Null<String>): Void {
		final writes: Array<{ path: String, content: String }> = [];
		for (file in changed) {
			final text: Null<String> = textOf(file);
			if (text == null)
				CliIo.deletePath(file)
			else
				writes.push({ path: file, content: text });
		}
		CliIo.writeFiles(writes);
	}

	/** Make the run hold `file` at `text`, or drop it when `text` is null; a held file with no pre-round bytes is one the run created. */
	private static function hold(
		files: Array<{ file: String, source: String }>, created: Array<String>, originalOf: Map<String, String>, file: String,
		text: Null<String>
	): Void {
		final entry: Null<{ file: String, source: String }> = files.find(e -> e.file == file);
		if (text == null) {
			if (entry != null) files.remove(entry);
			return;
		}
		if (entry != null)
			entry.source = text
		else
			files.push({ file: file, source: text });
		if (!originalOf.exists(file) && !created.contains(file)) created.push(file);
	}

}
