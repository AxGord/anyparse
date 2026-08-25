package anyparse.query;

import anyparse.check.CompilerOracle.OracleOutcome;

using Lambda;
using StringTools;

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
 * How far a failing safe pass could be narrowed: either the named files were reverted and
 * the rest of the wave verified green again, or the wave could not be attributed and the
 * caller must roll all of it back.
 *
 * `WholeWave` carries BOTH halves of the surrender: `why` it gave up, and the compiler
 * text AT THAT MOMENT — which is not the text the caller started with once a round has
 * run. Reporting the stale one names files the narrowing already rolled back and hides
 * the file that actually blocked it.
 */
enum SafePassNarrowing {
	Narrowed(reverted: Array<String>, probes: Int);
	WholeWave(why: String, errors: String);
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
 * nothing, so one bad edit hid 227 good files and each bad edit MASKED the next, which is
 * how a queue of fixer defects came to be found one round-trip at a time. `narrow`
 * attributes the failure to the files the compiler blames BEFORE reverting anything, and
 * `revertNotice` says which files went back.
 */
@:nullSafety(Strict)
final class LintFixSafePass {

	/**
	 * How many attribute-revert-retest rounds `narrow` will spend before giving up and
	 * telling the caller to roll the whole wave back. Each round costs ONE project-wide
	 * typecheck, and only happens when the previous round's errors blamed new files.
	 */
	public static inline final NARROW_ROUNDS: Int = 4;

	/** The ESC that opens every ANSI control sequence in `-D message.reporting=pretty` output. */
	private static inline final ESCAPE: String = '\x1b';

	/** The lowest byte value that TERMINATES an ANSI CSI sequence; everything below it is a parameter. */
	private static inline final CSI_FINAL_MIN: Int = 0x40;

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
	 * which prefixes the header with an ANSI-coloured ` ERROR ` badge — measured on Haxe
	 * 4.3.7. A colon-digit run NOT followed by a second colon is a message, not a position
	 * (`Could not process argument foo:1`), and a candidate with no extension is not a file.
	 *
	 * A warning is not why a build failed, in either reporting style, so both spellings of
	 * one are skipped — otherwise a deprecation notice in an untouched library would
	 * implicate a file this run wrote.
	 */
	public static function errorFiles(errors: String): Array<String> {
		final found: Array<String> = [];
		for (raw in errors.split('\n')) {
			final line: String = stripAnsi(raw);
			if (line.contains(' : Warning :') || line.ltrim().startsWith('WARNING ')) continue;
			final path: Null<String> = diagnosticPath(line);
			if (path != null && !found.contains(path)) found.push(path);
		}
		return found;
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
		var grew: Bool = hit.length > 0;
		while (grew) {
			grew = false;
			for (group in coupled) if (group.exists(f -> hit.contains(f))) for (file in group) if (
				!hit.contains(file) && changed.contains(file)
			) {
				hit.push(file);
				grew = true;
			}
		}
		return hit;
	}

	/**
	 * Narrow a failing safe pass to the files the compiler blames, keeping the rest.
	 *
	 * Round 1 reverts the files `implicated` names and asks the oracle again; a green answer
	 * ends it (`Narrowed`), a red one is re-attributed and the loop widens by whatever NEW
	 * files the fresh errors blame. An error can name a file this run never wrote — the broken
	 * thing is the CALLER of an edited declaration — and then there is nothing to narrow to, so
	 * the round returns `WholeWave` with the reason rather than reverting something arbitrary.
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
	 * compile at a time. The granular arm names exactly the files it rolled back; the
	 * whole-wave arm names the files the COMPILER blamed and why they could not be narrowed to
	 * anything this run wrote.
	 */
	public static function revertNotice(narrowing: SafePassNarrowing, changed: Int, errors: String): String {
		return switch narrowing {
			case Narrowed(reverted, probes):
				final rolled: String = [for (file in reverted) 'apq lint --fix: safe-fix REVERTED $file\n'].join('');
				'apq lint --fix: the safe fixes broke a build that was green — REVERTED ${reverted.length} of $changed'
					+ ' file(s), KEPT the other ${changed - reverted.length} on disk ($probes extra typecheck(s) to attribute)\n'
					+ '${rolled}apq lint --fix: $errors\n';
			case WholeWave(why, last):
				final blamed: String = errorFiles(last).join(', ');
				'apq lint --fix: the safe fixes broke a build that was green — REVERTED all $changed file(s), nothing was'
					+ ' written ($why)\napq lint --fix: the compiler blames: $blamed\napq lint --fix: $last\n';
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
	 * The line with its ANSI CSI sequences removed. `-D message.reporting=pretty` wraps the
	 * severity badge and the source excerpt in colour codes; nothing downstream wants them,
	 * and the badge is what pushes the path off column 0.
	 */
	private static function stripAnsi(line: String): String {
		if (!line.contains(ESCAPE)) return line;
		final out: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < line.length) {
			if (line.charAt(i) != ESCAPE) {
				out.add(line.charAt(i));
				i++;
				continue;
			}
			i++;
			if (line.charAt(i) != '[') continue;
			// CSI: parameter and intermediate bytes, then one final byte in 0x40..0x7E.
			i++;
			while (i < line.length && line.fastCodeAt(i) < CSI_FINAL_MIN) i++;
			i++;
		}
		return out.toString();
	}

}

/**
 * What the CLI does with the safe-pass verdict: whether the pass was rolled back at all
 * (the caller then aborts), the summary tail to append when it was not, and the full
 * stderr notice when it was — which files went back, which survived, and the compiler
 * errors behind them.
 */
typedef SafePassOutcome = {
	final reverted: Bool;
	final tail: String;
	final notice: String;
};
