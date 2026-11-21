package dev;

import devkit.Summary.Outcome;

/**
 * The one answer to "does this machine declare that its checkout has nothing private": the environment variable `ANYPARSE_PRIVATE`
 * is `none`. Only that value counts, so a machine that has a private map and merely forgot to set it still gets the refusal of
 * every gate row that reads it (`scrub`, `infra4`).
 */
@:nullSafety(Strict)
final class PrivateDeclaration {

	/** The environment variable the declaration is read from. */
	public static final VAR: String = 'ANYPARSE_PRIVATE';

	/** The detail a row that the declaration let skip its check shows in the gate table. */
	public static final NOTE: String = 'none configured, declared';

	/** Whether this process's environment declares nothing private. */
	public static function declared(): Bool {
		return Sys.getEnv(VAR) == 'none';
	}

	/** The verdict of a row that has nothing to check without private trees: `Skipped` when declared, else `NotRun` for `why`. */
	public static function unlessDeclared(why: String): Outcome {
		return declared() ? Skipped(NOTE) : NotRun(why);
	}

}
