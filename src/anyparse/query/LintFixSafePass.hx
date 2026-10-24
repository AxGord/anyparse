package anyparse.query;

import anyparse.check.CompilerOracle.OracleExclusion;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.check.FailerBisect;
import anyparse.check.LintConfig.OracleConfig;
import haxe.Exception;

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
 * One file a failing safe pass was cut down to: the rules whose edits there went back (named, and banned for the rest of
 * the run), the text the net KEPT — null when the whole file returned to its pre-fix bytes — and the rules whose
 * first-pass edits that text holds.
 */
typedef SafeCulprit = {
	final file: String;
	final rules: Array<String>;
	final keptRules: Array<String>;
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

	/**
	 * The rules that edited `file` AFTER its first per-file pass — in a later pass or through a cross-file fix. Keeping
	 * the first pass alone discards their edits, a rule of the first pass included.
	 */
	final laterRules: (file:String) -> Array<String>;

	/** Every rule that edited `file` this round — what a whole-file revert takes back. */
	final rulesOf: (file:String) -> Array<String>;

	/** `file`'s text as the round left it, or null when the round deleted it. */
	final fixed: (file:String) -> Null<String>;
};

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

	/** The default run budget of the typechecks the safe-pass net may spend isolating culprits (`--fix-probes`). */
	public static inline final PROBE_CAP: Int = 32;

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
	 * An attributed narrowing already names its files. A surrendered one — the errors blame a file the run never wrote, the
	 * CALLER of an edited declaration — is bisected over the written files instead (`bisectFiles`). Each culprit is then split by
	 * rule where its first pass can be replayed (`splitFile`). Nothing is named without a probe that shows its removal turns
	 * the tree green, and the settled cut is itself a confirmed tree. Every probe counts against the run's budget `cap`
	 * (`IsolationProbes`); reaching it, an oracle that stops answering, or a failure only a combination of files produces
	 * leaves the narrowing as it was — the whole-wave revert for a surrender, with both reasons. Fail closed.
	 */
	public static function isolate(
		narrowing: SafePassNarrowing, changed: Array<String>, coupled: Array<Array<String>>, seat: SafeBisectSeat, cap: Int = PROBE_CAP
	): SafePassNarrowing {
		final known: Array<{ keep: Array<String>, green: Bool }> = [{ keep: changed, green: false }, { keep: [], green: true }];
		final narrowed: Null<Array<String>> = switch narrowing {
			case Narrowed(reverted, _): reverted;
			case WholeWave(_): null;
			case Bisected(_): return narrowing;
		};
		if (narrowed != null) known.push({ keep: [for (file in changed) if (!narrowed.contains(file)) file], green: true });
		final probes: IsolationProbes = new IsolationProbes(seat, cap, known);
		final spentBefore: Int = switch narrowing {
			case Narrowed(_, spent): spent;
			case _: 0;
		};
		return try {
			final units: Array<Array<String>> = narrowed != null ? unitsOf(narrowed, coupled) : bisectFiles(changed, coupled, probes);
			final culprits: Array<SafeCulprit> = splitAll(units, changed, seat, probes);
			// The cut the caller will put on disk must be a tree the oracle confirmed — free when an earlier probe or the
			// narrowing already did, one typecheck otherwise.
			final partial: Map<String, String> = [];
			for (culprit in culprits) {
				final kept: Null<String> = culprit.kept;
				if (kept != null) partial[culprit.file] = kept;
			}
			if (!probes.green([for (file in changed) if (!culprits.exists(c -> c.file == file)) file], partial))
				throw new IsolationStop('the cut the isolation settled on does not typecheck');
			settledNarrowing(narrowing, culprits, changed, spentBefore + probes.spent);
		} catch (stop: IsolationStop) switch narrowing {
			case Narrowed(reverted, spent): Narrowed(reverted, spent + probes.spent);
			case WholeWave(why, errors): WholeWave('$why; ${stop.message}', errors);
			case Bisected(_): narrowing;
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
	 * The culprit units a failing wave comes down to — one per file, one per set of files a cross-file fix committed together —
	 * by binary-split group testing (`FailerBisect`): a probe keeps a subset of units at the round's bytes and every other
	 * written file at its pre-round bytes. The complement of the failers must typecheck, and each failer must turn it red on
	 * its own. One unit needs no probe: the wave failed and the tree without it is the one the pre-write verdict judged.
	 */
	private static function bisectFiles(
		changed: Array<String>, coupled: Array<Array<String>>, probes: IsolationProbes
	): Array<Array<String>> {
		final units: Array<Array<String>> = unitsOf(changed, coupled);
		if (units.length < 2) return units;
		function keepOf(indices: Array<Int>): Array<String> {
			return [for (i in indices) for (file in units[i]) file];
		}
		final budget: Int = FailerBisect.searchBudget(units.length);
		final failers: Null<Array<Int>> = FailerBisect.isolateFailers(
			units.length, budget, indices -> probes.green(keepOf(indices), []), [0]
		);
		if (failers == null)
			throw new IsolationStop('bisecting the ${units.length} written unit(s) isolated no culprit within $budget typecheck(s)');
		final kept: Array<Int> = [for (i in 0...units.length) if (!failers.contains(i)) i];
		if (kept.length == 0) return units;
		if (!probes.green(keepOf(kept), [])) throw new IsolationStop('the files the bisection kept still do not typecheck together');
		// A unit is named only once its OWN addition turns the kept tree red: when both halves of a block typecheck alone the
		// search hands back a side it never proved, and that is an interaction it cannot pin on either side.
		for (i in failers) if (probes.green(keepOf(kept.concat([i])), []))
			throw new IsolationStop(
				'the written files break the build only in combination — an interaction no bisection can pin on one side'
			);
		return [for (i in failers) units[i]];
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
			: 'apq lint --fix: safe-fix REVERTED the edits $rules made in ${culprit.file}, KEPT the first-pass edits of '
				+ culprit.keptRules.join(', ') + '\n';
	}

	/** The verdict a settled cut amounts to: `Bisected` when a file kept part of its edits, the arm it started from otherwise. */
	private static function settledNarrowing(
		narrowing: SafePassNarrowing, culprits: Array<SafeCulprit>, changed: Array<String>, probes: Int
	): SafePassNarrowing {
		if (culprits.exists(culprit -> culprit.kept != null)) return Bisected(culprits, probes);
		return switch narrowing {
			case Narrowed(_): Narrowed([for (culprit in culprits) culprit.file], probes);
			case WholeWave(why, errors) if (culprits.length >= changed.length): WholeWave(
				'$why; every file this run wrote is implicated', errors
			);
			case _: Bisected(culprits, probes);
		};
	}

	/** `files` grouped into units: a file alone, or with every written file a cross-file fix committed together with it. */
	private static function unitsOf(files: Array<String>, coupled: Array<Array<String>>): Array<Array<String>> {
		final units: Array<Array<String>> = [];
		for (file in files) if (!units.exists(unit -> unit.contains(file))) units.push(coupledClosure([file], files, coupled));
		return units;
	}

	/**
	 * Each culprit unit settled: a single file split by rule where `splitFile` can, every other file of every unit back whole
	 * with every rule that edited it this round. A split's kept text joins the context the next file is judged in.
	 */
	private static function splitAll(
		units: Array<Array<String>>, changed: Array<String>, seat: SafeBisectSeat, probes: IsolationProbes
	): Array<SafeCulprit> {
		final keep: Array<String> = [for (file in changed) if (!units.exists(unit -> unit.contains(file))) file];
		final partial: Map<String, String> = [];
		final culprits: Array<SafeCulprit> = [];
		for (unit in units) {
			final cut: Null<SafeCulprit> = unit.length == 1 ? splitFile(unit[0], keep, partial, seat, probes) : null;
			final text: Null<String> = cut?.kept;
			if (cut != null && text != null) {
				partial[cut.file] = text;
				culprits.push(cut);
				continue;
			}
			for (file in unit) culprits.push({
				file: file,
				rules: seat.rulesOf(file),
				keptRules: [],
				kept: null
			});
		}
		return culprits;
	}

	/**
	 * `file` cut down to the edits the compiler accepts, or null when it goes back whole. Nothing is blamed without a probe:
	 * the round's text must be rejected in the current context (`keep` at the round's bytes, `partial` as settled, every
	 * other culprit at its pre-round bytes) before any part of it is. Then the first pass alone, when a later pass changed
	 * the file again — every rule of those later passes goes with them, one that also landed in the first pass included;
	 * then a bisection over the first pass's rules, whose kept text must typecheck and each of whose rejected rules must
	 * turn it red on its own — an interaction between rules is not pinned on either.
	 */
	private static function splitFile(
		file: String, keep: Array<String>, partial: Map<String, String>, seat: SafeBisectSeat, probes: IsolationProbes
	): Null<SafeCulprit> {
		final rules: Array<String> = seat.splitRules(file);
		if (rules.length == 0) return null;
		function green(text: Null<String>): Bool {
			if (text == null) return false;
			final candidate: Map<String, String> = partial.copy();
			candidate[file] = text;
			return probes.green(keep, candidate);
		}
		final fixed: Null<String> = seat.fixed(file);
		if (fixed == null || green(fixed)) return null;
		final later: Array<String> = seat.laterRules(file);
		final first: Null<String> = seat.replay(file, rules);
		if (later.length > 0 && first != null && first != fixed && green(first)) return {
			file: file,
			rules: later,
			keptRules: rules,
			kept: first
		};
		return rules.length < 2 ? null : bisectRules(file, rules, later, seat, green);
	}

	/**
	 * The first pass of `file` bisected over its `rules` with `green` (the candidate holding a text): the kept text must
	 * typecheck, and each rejected rule must turn it red on its own, or nothing is pinned. The rejected rules and every rule
	 * of a `later` pass go back.
	 */
	private static function bisectRules(
		file: String, rules: Array<String>, later: Array<String>, seat: SafeBisectSeat, green: (Null<String>) -> Bool
	): Null<SafeCulprit> {
		final failers: Null<Array<Int>> = FailerBisect.isolateFailers(
			rules.length, FailerBisect.searchBudget(rules.length), indices -> green(seat.replay(file, [for (i in indices) rules[i]])), [0]
		);
		if (failers == null) return null;
		final keptRules: Array<String> = [for (i in 0...rules.length) if (!failers.contains(i)) rules[i]];
		final text: Null<String> = keptRules.length == 0 ? null : seat.replay(file, keptRules);
		if (!green(text)) return null;
		for (i in failers) if (green(seat.replay(file, keptRules.concat([rules[i]])))) return null;
		final dropped: Array<String> = [for (i in failers) rules[i]];
		for (rule in later) if (!dropped.contains(rule)) dropped.push(rule);
		return {
			file: file,
			rules: dropped,
			keptRules: keptRules,
			kept: text
		};
	}

}

/** Why an isolation stopped short — its run budget, an oracle that stopped answering, or a failure it cannot attribute. */
private class IsolationStop extends Exception {}

/**
 * The typechecks one isolation spends, through one door. Every probe counts against the run's budget, an oracle that
 * cannot answer stops the isolation, and a candidate already judged — the same files at the same texts — is answered
 * from the verdict it got rather than compiled again.
 */
private class IsolationProbes {

	/** How many candidates were compiled. */
	public var spent(default, null): Int = 0;

	/** Verdicts by candidate (`keyOf`). */
	private final _verdicts: Map<String, Bool> = [];

	private final _seat: SafeBisectSeat;
	private final _cap: Int;

	/**
	 * `known` seeds the verdicts already in hand: the round's whole wave is red, the tree before it green, and a narrowing
	 * that confirmed a tree gives it here.
	 */
	public function new(seat: SafeBisectSeat, cap: Int, known: Array<{ keep: Array<String>, green: Bool }>) {
		_seat = seat;
		_cap = cap;
		for (verdict in known) _verdicts[keyOf(verdict.keep, [])] = verdict.green;
	}

	/**
	 * Whether the tree with `keep` at the round's bytes, `partial` at the given
	 * texts and every other written file at its pre-round bytes typechecks.
	 */
	public function green(keep: Array<String>, partial: Map<String, String>): Bool {
		final key: String = keyOf(keep, partial);
		final known: Null<Bool> = _verdicts[key];
		if (known != null) return known;
		if (spent >= _cap)
			throw new IsolationStop('the isolation reached the run budget of $_cap typecheck(s) — raise it with --fix-probes <n>');
		spent++;
		final verdict: Bool = switch _seat.probe(keep, partial) {
			case Confirmed: true;
			case Rejected(_): false;
			case Unavailable(reason): throw new IsolationStop('the oracle could not re-run ($reason)');
		};
		_verdicts[key] = verdict;
		return verdict;
	}

	/**
	 * One candidate as text: each file it holds at the round's bytes or at another
	 * text, sorted — a partial text equal to the round's bytes is the kept file.
	 */
	private function keyOf(keep: Array<String>, partial: Map<String, String>): String {
		final parts: Array<String> = [for (file in keep) if (!partial.exists(file)) '$file\n='];
		for (file => text in partial) parts.push(text == _seat.fixed(file) ? '$file\n=' : '$file\n:$text');
		parts.sort(Reflect.compare);
		return parts.join('\n\n');
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
