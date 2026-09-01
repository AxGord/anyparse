package unit;

/**
 * Which conditional-compilation flags THIS build defines — asked of the compiler through
 * `#if <flag>` rather than recorded as a claim about it.
 *
 * Split out of `DeadTestGuardTest` so that gate needs no exemption of its own. Asking `#if sys`
 * is unprovable by construction — it IS the question — so the sweep in `DeadTestGuardTest`
 * skips the guards THIS module carries, and only those whose flag this build does not define.
 * The module holds no test method, which is what keeps that exemption from being a hiding
 * place: there is nothing here for a dead guard to swallow.
 */
@:nullSafety(Strict)
final class BuildDefines {

	/**
	 * Every conditional-compilation flag this module can decide. Extend it and `definedFlags`
	 * together: `DeadTestGuardTest.testProbedFlagsAndDefinedFlagsAgree` can only check the
	 * containment for flags THIS build defines, so a name added to one and not the other passes
	 * unnoticed until a build that defines it comes along.
	 */
	public static final PROBED: Array<String> = ['sys', 'nodejs'];

	/** The subset of `PROBED` this build defines. */
	public static function definedFlags(): Array<String> {
		final defined: Array<String> = [];
		#if sys
		defined.push('sys');
		#end
		#if nodejs
		defined.push('nodejs');
		#end
		return defined;
	}

	/** The probed flags this build does NOT define. */
	public static function undefinedFlags(): Array<String> {
		final defined: Array<String> = definedFlags();
		return PROBED.filter(flag -> !defined.contains(flag));
	}

}
