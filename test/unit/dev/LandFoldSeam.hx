package unit.dev;

import dev.LandProbeFold.FoldStep;
import devkit.Summary.Outcome;

/** The stand-in probe-fold step for `LandTest`: it records the slice it was given and how many whole-suite starts came before it. */
@:nullSafety(Strict)
final class LandFoldSeam {

	/** The seam when `wired`, else none, so the land under test has no fold step. */
	public static function of(wired: Null<Bool>, folded: Array<String>, started: Array<String>): Null<FoldStep> {
		return wired != true
			? null
			: (repo, slice, note) -> {
				folded.push('$slice started=${started.length}');
				note('probe-fold: seam ran');
				return Passed;
			};
	}

}
