package dev;

import devkit.Command;
import devkit.Result;
import devkit.Summary;
import haxe.io.Path;

using Lambda;

/**
 * The one answer to "does the writer round-trip the fork's tree?": `fmt --verify --one-pass` over the fork's `src`, which is not
 * canonical, so every round trip is exercised. Both failure lines of the battery's fmt row, and the slice gate's when the fmt
 * scope widens to the whole tree. The command's exit status is no verdict: a file the grammar cannot parse exits non-zero on a clean tree.
 */
@:nullSafety(Strict)
final class ForkFmt {

	private static inline final DIVERGED: String = 'formatting changed more than whitespace';
	private static inline final ONE_PASS: String = 'fmt --one-pass:';
	private static inline final VERIFY_LINE: String = 'fmt --verify:';
	private static inline final FIXED_POINT: String = 'rewrites to reach its fixed point';

	/**
	 * The verdict of the verify over `fork`'s `src` (the value of `GateTree.FORK_VAR`; null or empty has nothing to verify and
	 * fails). `hxq` is the command that runs the engine over the given arguments.
	 */
	public static function verify(hxq: Array<String> -> Command, fork: Null<String>): ForkVerdict {
		if (fork == null || fork == '') return { shown: [], why: ['${GateTree.FORK_VAR} is unset — the fork tree cannot be verified'] };
		final src: String = '$fork/src';
		final run: Result = hxq(['fmt', '--verify', '--one-pass', src]).run();
		final text: String = run.out + run.err;
		final lines: Array<String> = text.split('\n');
		final shown: Array<String> = lines.filter(line -> line.indexOf(VERIFY_LINE) >= 0);
		final why: Array<String> = [];
		if (text.indexOf(DIVERGED) >= 0) {
			for (line in lines) if (!shown.contains(line)) shown.push(line);
			why.push('fmt --verify found a non-whitespace divergence in $src');
		}
		if (text.indexOf(ONE_PASS) >= 0) {
			for (line in lines) if ((line.indexOf(ONE_PASS) >= 0 || line.indexOf(FIXED_POINT) >= 0) && !shown.contains(line))
				shown.push(line);
			why.push('the writer needed more than one rewrite on a file in $src');
		}
		return { shown: shown, why: why };
	}

	/**
	 * Whether a slice that changed `touched` owes the fork verify: the engine or a formatter config moved, so any file may format
	 * otherwise than at the base — the same trigger that widens the fmt row to the whole tree.
	 */
	public static function owedBy(touched: Array<String>): Bool {
		return touched.exists(file -> GateTree.isEngineInput(file) || GateTree.FORMATTER_CONFIGS.contains(Path.withoutDirectory(file)));
	}

	/**
	 * The gate's row for the fork verify: `verify` over the fork `GateTree.FORK_VAR` names, a failure's lines excerpted into `summary`.
	 * A gate that cannot name the fork fails, as the battery refuses to start without it.
	 */
	public static function outcome(hxq: Array<String> -> Command, summary: Summary): Outcome {
		final verdict: ForkVerdict = verify(hxq, Sys.getEnv(GateTree.FORK_VAR));
		if (verdict.why.length == 0) return Passed;
		summary.excerpt(verdict.shown);
		return Failed(GateTree.clip(verdict.why.join('; ')));
	}

}

/** What a fork verify found: the lines worth showing, and one reason per failure (none when it holds). */
typedef ForkVerdict = {
	var shown: Array<String>;
	var why: Array<String>;
}
