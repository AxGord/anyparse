package anyparse.query;

import anyparse.check.CompilerOracle.OracleExclusion;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.check.FailerBisect;
import anyparse.check.LintConfig.OracleConfig;

using Lambda;

/**
 * What the two safe-pass oracle measurements decided: carry on, carry on but say the
 * net is off (and why), or roll the whole pass back with the compiler's errors.
 */
enum SafePassDecision {
	Proceed;
	NoNet(tail: String);
	Revert(errors: String);
}

/**
 * How far a failing safe pass could be narrowed: the named files were reverted and the rest
 * of the wave verified green again (`Narrowed`), the wave was bisected down to the files and
 * rules the compiler rejects (`Bisected`, settled by the caller), or nothing could be isolated
 * and the caller must roll all of it back.
 *
 * `WholeWave` carries BOTH halves of the surrender: `why` it gave up, and the compiler
 * text AT THAT MOMENT — which is not the text the caller started with once a round has
 * run. Reporting the stale one names files the narrowing already rolled back and hides
 * the file that actually blocked it.
 */
enum SafePassNarrowing {
	Narrowed(reverted: Array<String>, probes: Int);
	Bisected(culprits: Array<SafeCulprit>, probes: Int);
	WholeWave(why: String, errors: String);
}

/**
 * One file a failing safe pass was cut down to: the rules whose edits there went back, and the
 * text the net KEPT — null when the whole file returned to its pre-fix bytes, the first-pass
 * edits of the rules the compiler accepted when only some of them did.
 */
typedef SafeCulprit = {
	final file: String;
	final rules: Array<String>;
	final kept: Null<String>;
};

/**
 * The caller's half of a safe-pass bisection — the disk and the compiler, and the record of
 * which rule wrote what. `LintFixSafePass.isolate` decides; this answers its questions.
 */
typedef SafeBisectSeat = {

	/**
	 * Typecheck the tree with `keep` at the bytes the round left, `partial` at the given texts
	 * and every other written file at its pre-round bytes.
	 */
	final probe: (keep:Array<String>, partial:Map<String, String>) -> OracleOutcome;

	/** The rules whose first-pass edits in `file` can be replayed one subset at a time, or none. */
	final splitRules: (file:String) -> Array<String>;

	/** `file`'s first pass replayed with the edits of `rules` alone, or null when the writer refuses them or they change nothing. */
	final replay: (file:String, rules:Array<String>) -> Null<String>;

	/** Every rule that edited `file` this round — what a whole-file revert takes back. */
	final rulesOf: (file:String) -> Array<String>;

	/** `file`'s text as the round left it, or null when the round deleted it. */
	final fixed: (file:String) -> Null<String>;
};

/** The written files a failing wave came down to, or why a bisection could not tell. */
private enum FileIsolation {
	Culprits(files: Array<String>);
	Unisolated(why: String);
}

/**
 * `apq lint --fix`'s safe-pass revert net: the judgement that decides whether the
 * non-risky fixes may stand, kept apart from the CLI so every arm is exercisable
 * without spawning a compiler.
 *
 * ## The defect it replaces
 *
 * `FixVerifier` takes its baseline AFTER the safe fixes are already on disk. A run
 * whose OWN fixes broke the build therefore reported `risky-fix skipped (oracle
 * baseline does not typecheck)` — a statement about the tree BEFORE `--fix`, which
 * had been green. The message named the wrong cause, the risky-fix insurance
 * switched itself off at exactly the moment it was needed, and the tree was left
 * un-typecheckable with nothing to say `--fix` had done it.
 *
 * Measuring once BEFORE the writes is the whole fix: it is the only way to tell
 * "already broken" from "we broke it".
 *
 * A SECOND defect lived one step further on: the rollback was ALL-OR-NOTHING and named
 * nothing, so one bad edit hid every good file beside it and each bad edit MASKED the next, which is
 * how a queue of fixer defects came to be found one round-trip at a time. `narrow` attributes the failure to the
 * files the compiler blames BEFORE reverting anything, `isolate` bisects the wave down to the files and rules
 * the compiler rejects when attribution names nothing the run wrote, and `revertNotice` says what went back.
 */
@:nullSafety(Strict)
final class LintFixSafePass {

	/**
	 * How many attribute-revert-retest rounds `narrow` will spend before giving up and
	 * telling the caller to roll the whole wave back. Each round costs ONE project-wide
	 * typecheck, and only happens when the previous round's errors blamed new files.
	 */
	public static inline final NARROW_ROUNDS: Int = 4;

	/** Whether an oracle verdict is the green one — the only case worth taking a second measurement for. */
	public static inline function isConfirmed(outcome: OracleOutcome): Bool {
		return switch outcome {
			case Confirmed: true;
			case _: false;
		};
	}

	/**
	 * The verdict, given the oracle reading taken before the safe writes (`pre`) and the
	 * one taken after (`post`).
	 *
	 * `post` is meaningful only when `pre` was green — the other arms cannot use it — so a
	 * null `post` there means the caller declined to measure and the pass is left alone.
	 *
	 *  - pre RED: the tree was already broken, so a red `post` proves nothing about the
	 *    fixes. Report it, keep the writes. This is the case the old message CLAIMED, and
	 *    almost never was.
	 *  - pre UNAVAILABLE: no measurement, no net.
	 *  - green then red: the safe fixes did it — revert.
	 *  - green then UNAVAILABLE: the oracle answered once and then could not run.
	 *    Reverting on no evidence would throw away a good pass, so the writes stand and
	 *    the run says the net could not close.
	 */
	public static function classify(pre: OracleOutcome, post: Null<OracleOutcome>): SafePassDecision {
		switch pre {
			case Rejected(_):
				return NoNet(', the tree did NOT typecheck before --fix ran — the safe-pass revert net is off');
			case Unavailable(reason):
				return NoNet(', safe-pass revert net off (oracle unavailable: $reason)');
			case Confirmed:
		}
		return switch post {
			case null, Confirmed: Proceed;
			case Unavailable(reason): NoNet(', safe-pass revert net could not close (oracle unavailable: $reason)');
			case Rejected(errors): Revert(errors);
		};
	}

	/**
	 * The files a compiler error text names, in first-appearance order and exactly as the
	 * compiler spelled them (relative to ITS cwd, which need not be the lint's).
	 *
	 * A diagnostic carries its position as `<path>:<line>: `, so the path is the last
	 * whitespace-delimited token before the first `:<digits>:` on the line. Anchoring on
	 * that shape rather than on column 0 is what survives `-D message.reporting=pretty`,
	 * which prefixes the header with an ANSI-coloured ` ERROR ` badge. A
	 * colon-digit run NOT followed by a second colon is a message, not a position
	 * (`Could not process argument foo:1`), and a candidate with no extension is not a file.
	 *
	 * A warning is not why a build failed, in either reporting style, so both spellings of
	 * one are skipped — otherwise a deprecation notice in an untouched library would
	 * implicate a file this run wrote.
	 */
	public static function errorFiles(errors: String): Array<String> {
		final found: Array<String> = [];
		for (raw in errors.split('\n')) {
			final line: String = SourceText.stripAnsi(raw);
			if (line.contains(' : Warning :') || line.ltrim().startsWith('WARNING ')) continue;
			final path: Null<String> = diagnosticPath(line);
			if (path != null && !found.contains(path)) found.push(path);
		}
		return found;
	}

	/**
	 * Whether the compiler's `errors` blame `file`: one of the files `errorFiles` reads off them names it (`samePath`).
	 * The one reading of a failed typecheck every revert net attributes by — ANSI colour stripped, warnings skipped, the
	 * path matched by segment-aligned suffix and never by basename, so `other/A.hx` does not blame `src/A.hx`.
	 */
	public static function blames(errors: String, file: String): Bool {
		return errorFiles(errors).exists(path -> samePath(path, file));
	}

	/**
	 * Which of the files this run WROTE the compiler's errors blame, closed under `coupled`.
	 *
	 * The compiler's spelling is matched against a written path by segment-aligned suffix on
	 * either side, so a relative `src/pony/A.hx` finds an absolute `/tmp/pony/src/pony/A.hx`
	 * without either side knowing the other's root.
	 *
	 * `coupled` names the file sets a cross-file fix committed as one unit (a rename and every
	 * file it rewrote). Reverting half of one leaves the tree worse than reverting all of it,
	 * so a group is pulled in WHOLE the moment any of its files is implicated — transitively,
	 * since two passes can couple overlapping sets.
	 *
	 * An empty result is the honest answer that the errors name nothing this run touched — the
	 * caller falls back to the whole-wave revert rather than reverting a file at random.
	 */
	public static function implicated(errors: String, changed: Array<String>, coupled: Array<Array<String>>): Array<String> {
		final hit: Array<String> = [];
		for (path in errorFiles(errors)) for (file in changed) if (!hit.contains(file) && samePath(path, file)) hit.push(file);
		return coupledClosure(hit, changed, coupled);
	}

	/**
	 * Narrow a failing safe pass to the files the compiler blames, keeping the rest.
	 *
	 * Round 1 reverts the files `implicated` names and asks the oracle again; a green answer
	 * ends it (`Narrowed`), a red one is re-attributed and the loop widens by whatever NEW
	 * files the fresh errors blame. An error can name a file this run never wrote — the broken
	 * thing is the CALLER of an edited declaration — and then there is nothing to narrow to, so
	 * the round returns `WholeWave` with the reason rather than reverting
	 * something arbitrary, and `isolate` bisects what attribution could not name.
	 *
	 * COST is the point of attributing rather than bisecting: one oracle spawn per round, and
	 * a round only happens when the previous one blamed new files — one spawn for the common
	 * single-culprit case, `maxRounds` in the worst. A per-file bisect over the same wave is
	 * O(log n) spawns at best and O(n) when the failures are scattered, on a project-wide
	 * typecheck that costs seconds each.
	 *
	 * `revert` is the caller's file sink (it restores those files' pre-fix bytes) and
	 * `typecheck` its oracle; neither is called once the verdict is `WholeWave`, so the caller
	 * still owns the whole-wave rollback. `probes` counts the oracle spawns this narrowing spent.
	 */
	public static function narrow(
		errors: String, changed: Array<String>, coupled: Array<Array<String>>, revert: (Array<String>) -> Void,
		typecheck: () -> OracleOutcome, maxRounds: Int
	): SafePassNarrowing {
		final reverted: Array<String> = [];
		var text: String = errors;
		var probes: Int = 0;
		for (round in 1...maxRounds + 1) {
			final next: Array<String> = [
				for (file in implicated(text, changed, coupled)) if (!reverted.contains(file)) file
			];
			if (next.length == 0)
				return WholeWave(
					round == 1 ? 'the compiler blames no file this run wrote' : 'the remaining errors blame no further file this run wrote',
					text
				);
			for (file in next) reverted.push(file);
			if (reverted.length >= changed.length) return WholeWave('every file this run wrote is implicated', text);
			revert(next);
			probes++;
			switch typecheck() {
				case Confirmed:
					return Narrowed(reverted, probes);
				case Rejected(more):
					text = more;
				case Unavailable(reason):
					return WholeWave('the oracle could not re-run ($reason)', text);
			}
		}
		return WholeWave('the errors still blamed new files after $maxRounds narrowing round(s)', text);
	}

	/**
	 * The stderr notice for a safe pass the net rolled back: what was reverted, what survived,
	 * and the compiler errors behind it.
	 *
	 * Naming the culprit is the whole point. The old message said only `REVERTED N file(s),
	 * nothing was written` — on a wave of 228 files, one bad edit hid 227 good ones AND left no
	 * hint which of them it was, so the only way to find out was to bisect the wave one
	 * compile at a time. The granular arms name exactly the files they rolled back — and, bisected, the rules cut out of a file that
	 * kept the rest; the whole-wave arm says why nothing could be isolated; every arm names the files the COMPILER blamed and quotes it.
	 */
	public static function revertNotice(narrowing: SafePassNarrowing, changed: Int, errors: String): String {
		return switch narrowing {
			case Narrowed(reverted, probes):
				final rolled: String = [for (file in reverted) 'apq lint --fix: safe-fix REVERTED $file\n'].join('');
				'apq lint --fix: the safe fixes broke a build that was green — REVERTED ${reverted.length} of $changed'
					+ ' file(s), KEPT the other ${changed - reverted.length} on disk ($probes extra typecheck(s) to attribute)\n'
					+ '$rolled${compilerLines(errors)}';
			case Bisected(culprits, probes):
				final whole: Int = culprits.filter(culprit -> culprit.kept == null).length;
				final split: Int = culprits.length - whole;
				final rolled: String = culprits.map(culpritLine).join('');
				'apq lint --fix: the safe fixes broke a build that was green — REVERTED $whole of $changed file(s)'
					+ (split > 0 ? ' and part of $split more' : '')
					+ ', KEPT everything else on disk ($probes extra typecheck(s) to isolate)\n$rolled${compilerLines(errors)}';
			case WholeWave(why, last):
				'apq lint --fix: the safe fixes broke a build that was green — REVERTED all $changed file(s), nothing was'
					+ ' written ($why)\n${compilerLines(last)}';
		};
	}

	/**
	 * What a `--fix` run must say about its safe-pass revert net BEFORE it writes
	 * anything, or null when it has one.
	 *
	 * Two arms have no net and only one of them used to say so. `--no-oracle` on a
	 * project that DID configure a `compilerOracle` printed the skip line; a project
	 * that configured none printed nothing at all — and that is the state every
	 * foreign project starts in, so the silent arm is the common one. The two are the
	 * same run for the fixer (`applyLintFixes` is handed a null hxml either way), so
	 * they get the same sentence, differing only in the remedy: one is a flag the user
	 * passed, the other a key they can add.
	 *
	 * REPORT MODE IS NOT AN ARM. A lint that writes nothing has no writes to revert, so there is no net to
	 * be missing — `Cli.oracleSkippedNote` covers what report mode loses without an oracle (nullSafety
	 * trust), which is a different fact.
	 *
	 * THE TWO ARMS ARE NOT EQUALLY WORTH SAYING, which is why `verbose` gates only one of them. The
	 * unconfigured arm reports a fact the reader may not know and names a remedy they have not taken, so it
	 * speaks always. The `--no-oracle` arm narrates back a flag the reader just passed — and `--fix` on a
	 * write op passes it for them, so it printed 161 bytes on EVERY `hxq <op> --write --fix`, while the
	 * run's own summary line already carries both consequences it states (`N risky-fix rule(s) left
	 * report-only (no compiler oracle for this run)`). Under `--verbose` it comes back.
	 */
	public static function netNotice(oracles: Array<OracleConfig>, noOracle: Bool, verbose: Bool): Null<String> {
		return if (oracles.length == 0)
			'apq lint --fix: no compilerOracle configured — no safe-pass revert net, risky fixes stay report-only,'
				+ ' oracle-assisted fixes are inert; add a "compilerOracle" hxml to apqlint.json to arm it\n'
		else if (noOracle && verbose)
			'apq lint --fix: compiler oracle SKIPPED (--no-oracle) — no safe-pass revert net, risky fixes stay report-only,'
				+ ' oracle-assisted fixes are inert\n'
		else
			null;
	}

	/**
	 * Cut a failing safe pass down to the edits the compiler rejects, keeping every other one.
	 *
	 * An attributed narrowing already names its files. A surrendered one — the errors blame a file the run never wrote,
	 * the CALLER of an edited declaration — is bisected over the written files instead, a cross-file fix's files as one
	 * unit, with the risky phase's own search (`FailerBisect`), and the files it keeps are confirmed green together
	 * before anything is kept. Each culprit is then split by RULE where its first pass can be replayed (`splitByRule`),
	 * so an innocent import fix beside the poisoning edit stays. Every search is capped at
	 * `FailerBisect.searchBudget` probes; a bisection that cannot isolate within it, or an oracle that stops answering,
	 * leaves the surrender standing with both reasons — fail closed.
	 */
	public static function isolate(
		narrowing: SafePassNarrowing, changed: Array<String>, coupled: Array<Array<String>>, seat: SafeBisectSeat
	): SafePassNarrowing {
		final probes: Array<Int> = [0];
		final files: Array<String> = switch narrowing {
			case Narrowed(reverted, spent):
				probes[0] = spent;
				reverted;
			case WholeWave(why, errors):
				switch bisectFiles(changed, coupled, seat, probes) {
					case Culprits(found): found;
					case Unisolated(failure): return WholeWave('$why; $failure', errors);
				}
			case Bisected(_):
				return narrowing;
		};
		final culprits: Array<SafeCulprit> = splitByRule(files, changed, seat, probes);
		if (culprits.exists(culprit -> culprit.kept != null)) return Bisected(culprits, probes[0]);
		return switch narrowing {
			case Narrowed(_): Narrowed(files, probes[0]);
			case WholeWave(why, errors) if (files.length >= changed.length): WholeWave(
				'$why; every file this run wrote is implicated', errors
			);
			case _: Bisected(culprits, probes[0]);
		};
	}

	/** Whether the character code is an ASCII digit. */
	private static inline function isDigit(code: Int): Bool {
		return code >= '0'.code && code <= '9'.code;
	}

	/** Whether the character code is a space or a tab — the token boundary a path ends at. */
	private static inline function isSpace(code: Int): Bool {
		return code == ' '.code || code == '\t'.code;
	}

	/**
	 * The path a diagnostic line carries: the whitespace-delimited token that ends at the
	 * first `:<digits>:` on the line, or null when the line holds no position at all.
	 */
	private static function diagnosticPath(line: String): Null<String> {
		var from: Int = 0;
		while (true) {
			final colon: Int = line.indexOf(':', from);
			if (colon <= 0) return null;
			from = colon + 1;
			var scan: Int = from;
			while (scan < line.length && isDigit(line.fastCodeAt(scan))) scan++;
			if (scan == from || line.charAt(scan) != ':') continue;
			var start: Int = colon;
			while (start > 0 && !isSpace(line.fastCodeAt(start - 1))) start--;
			final path: String = line.substring(start, colon);
			// No extension, no file: a message can carry its own `word:12:` and must not be
			// read as a position (nothing would match it, but it would be PRINTED as blamed).
			if (path.contains('.')) return path;
		}
	}

	/**
	 * Whether two spellings name one file: equal after separator normalisation, or one a
	 * segment-aligned suffix of the other. Suffix rather than basename, because the compiler's
	 * relative path carries enough of the tree to tell two same-named files apart.
	 */
	private static function samePath(a: String, b: String): Bool {
		final x: String = a.replace('\\', '/');
		final y: String = b.replace('\\', '/');
		return x == y || suffixSegment(x, y) || suffixSegment(y, x);
	}

	/** Whether `whole` ends with `part` on a separator boundary. */
	private static function suffixSegment(whole: String, part: String): Bool {
		final cut: Int = whole.length - part.length;
		return cut > 0 && part.length > 0 && whole.substr(cut) == part && whole.charAt(cut - 1) == '/';
	}

	/**
	 * `seed` grown by every written file a cross-file fix committed together with one of it — transitively, since two
	 * passes can couple overlapping sets. Answers `seed` itself, grown in place.
	 */
	private static function coupledClosure(seed: Array<String>, changed: Array<String>, coupled: Array<Array<String>>): Array<String> {
		var grew: Bool = seed.length > 0;
		while (grew) {
			grew = false;
			for (group in coupled) if (group.exists(f -> seed.contains(f))) for (file in group) if (
				!seed.contains(file) && changed.contains(file)
			) {
				seed.push(file);
				grew = true;
			}
		}
		return seed;
	}

	/**
	 * The written files a failing wave comes down to, by binary-split group testing over UNITS — one per file, one per
	 * set of files a cross-file fix committed together. A probe keeps a subset of units at the bytes the round left and
	 * every other written file at its pre-round bytes; the complement of the failers is confirmed before it is trusted.
	 * One unit needs no probe: the wave failed and the tree without it is the green one the pre-write verdict judged.
	 */
	private static function bisectFiles(
		changed: Array<String>, coupled: Array<Array<String>>, seat: SafeBisectSeat, probes: Array<Int>
	): FileIsolation {
		final units: Array<Array<String>> = [];
		for (file in changed) if (!units.exists(unit -> unit.contains(file))) units.push(coupledClosure([file], changed, coupled));
		if (units.length < 2) return Culprits(changed.copy());
		var unavailable: Null<String> = null;
		function probe(indices: Array<Int>): Bool {
			if (unavailable != null) return false;
			probes[0]++;
			return switch seat.probe([for (i in indices) for (file in units[i]) file], []) {
				case Confirmed: true;
				case Rejected(_): false;
				case Unavailable(reason):
					unavailable = reason;
					false;
			};
		}
		final budget: Int = FailerBisect.searchBudget(units.length);
		final failers: Null<Array<Int>> = FailerBisect.isolateFailers(units.length, budget, probe, [0]);
		final kept: Array<Int> = failers == null ? [] : [for (i in 0...units.length) if (!failers.contains(i)) i];
		final confirmed: Bool = kept.length > 0 && probe(kept);
		final lost: Null<String> = unavailable;
		if (lost != null) return Unisolated('the oracle could not re-run ($lost)');
		if (failers == null)
			return Unisolated('bisecting the ${units.length} written unit(s) isolated no culprit within $budget typecheck(s)');
		if (kept.length == 0) return Culprits(changed.copy());
		if (!confirmed) return Unisolated('the files the bisection kept still do not typecheck together');
		return Culprits([for (i in failers) for (file in units[i]) file]);
	}

	/**
	 * Each culprit file split by RULE where its first per-file pass can be replayed one subset at a time. The first pass
	 * alone goes first when a later pass changed the file again — the poisoning edit may be one of those; then the
	 * pass's rules are bisected and the accepted ones confirmed. A file that cannot be split, or whose split finds no
	 * accepted rule, goes back whole. A probe holds every file the bisection kept at the round's bytes and every split
	 * already settled at its kept text.
	 */
	private static function splitByRule(
		files: Array<String>, changed: Array<String>, seat: SafeBisectSeat, probes: Array<Int>
	): Array<SafeCulprit> {
		final keep: Array<String> = [for (file in changed) if (!files.contains(file)) file];
		final partial: Map<String, String> = [];
		final culprits: Array<SafeCulprit> = [];
		for (file in files) {
			final every: Array<String> = seat.rulesOf(file);
			final rules: Array<String> = seat.splitRules(file);
			function green(text: Null<String>): Bool {
				if (text == null) return false;
				partial[file] = text;
				probes[0]++;
				final verdict: Bool = seat.probe(keep, partial).match(Confirmed);
				partial.remove(file);
				return verdict;
			}
			final first: Null<String> = rules.length == 0 ? null : seat.replay(file, rules);
			var keptRules: Array<String> = rules;
			var accepted: Bool = first != null && first != seat.fixed(file) && green(first);
			if (!accepted && rules.length > 1) {
				final failers: Null<Array<Int>> = FailerBisect.isolateFailers(
					rules.length, FailerBisect.searchBudget(rules.length),
					indices -> green(seat.replay(file, [for (i in indices) rules[i]])), [0]
				);
				keptRules = failers == null ? [] : [for (i in 0...rules.length) if (!failers.contains(i)) rules[i]];
				accepted = keptRules.length > 0 && green(seat.replay(file, keptRules));
			}
			final text: Null<String> = accepted ? seat.replay(file, keptRules) : null;
			if (text == null) {
				culprits.push({ file: file, rules: every, kept: null });
				continue;
			}
			partial[file] = text;
			final dropped: Array<String> = [for (rule in every) if (!keptRules.contains(rule)) rule];
			culprits.push({ file: file, rules: dropped.length > 0 ? dropped : every, kept: text });
		}
		return culprits;
	}

	/**
	 * The compiler's half of every revert notice, printed at any verbosity: the files its errors blame and the errors
	 * themselves. Without them a revert cannot be diagnosed — the blamed file is often one the run never wrote.
	 */
	private static function compilerLines(errors: String): String {
		return 'apq lint --fix: the compiler blames: ${errorFiles(errors).join(', ')}\napq lint --fix: $errors\n';
	}

	/** One culprit's line of a bisected revert notice: the whole file, or the rules cut out of a file that kept the rest. */
	private static function culpritLine(culprit: SafeCulprit): String {
		final rules: String = culprit.rules.join(', ');
		return culprit.kept == null
			? 'apq lint --fix: safe-fix REVERTED ${culprit.file} ($rules)\n'
			: 'apq lint --fix: safe-fix REVERTED the $rules edit(s) of ${culprit.file}, KEPT its other edits\n';
	}

}

/**
 * What the CLI does with the safe-pass verdict: whether the pass was rolled back at all, the
 * summary tail to append, and the full stderr notice when it was — which files went back, which
 * survived, and the compiler errors behind them. A rolled-back pass ends on a tree the oracle
 * confirmed green, so the caller goes on to its later phases and fails the run at the end.
 */
typedef SafePassOutcome = {
	final reverted: Bool;

	/** The files the net rolled back (empty when it rolled back nothing), for the caller to take off its edit count. */
	final revertedFiles: Array<String>;

	/**
	 * The files of `revertedFiles` the net only SPLIT, each with how many of the round's edits it KEPT there — the edits
	 * of the rules the compiler accepted. Absent when the net split nothing.
	 */
	@:optional final partialKept: Map<String, Int>;
	final tail: String;
	final notice: String;

	/**
	 * The configurations the net ran WITHOUT, each named with its cause (`OracleBaseline`) — for the
	 * caller to name, since a net silently shrunk to the green subset reads as covering every build.
	 */
	final excluded: Array<OracleExclusion>;
};
