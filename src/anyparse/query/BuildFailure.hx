package anyparse.query;

using Lambda;
using StringTools;

/**
 * Why a mutated tree refused to compile.
 *
 * A build failure is not evidence about any fixture, so `tools/mutation-check.sh`
 * has always reported `BUILD-FAIL` — and then handed over a log path, which is
 * where the reading stopped. These are the causes an ARM run actually produces,
 * each one measured rather than imagined: three of the five known arm-authoring
 * blind spots land here, and the registry's own build-macro cross-checks land
 * here too, because an arm being authored is an arm no `@:killer` names yet.
 */
enum BuildFailureCause {

	/**
	 * A nullable value reached an anonymous-structure literal whose field is not
	 * nullable — the fifth arm-authoring blind spot, and the only one of the five
	 * that no walk over the record and the tree can name (S147).
	 */
	NullSafetyStructure;

	/** Any other strict-null-safety refusal. */
	NullSafety;

	/** A forced `return` ahead of the body of an `inline` member (S96). */
	InlineReturn;

	/** The arm registry's own build-macro cross-checks — a `@:killer`/`@:pin` pairing. */
	ArmRegistry;

	/** The cut left the file unparseable. */
	Syntax;

	/** The cut typechecks as something the site cannot take. */
	TypeError;

	/** A compiler line none of the above names; the line itself is the report. */
	Other;

	/** The log holds no compiler error at all — the caller's failure is elsewhere. */
	NoError;
}

/** One classified build log: the cause, and the compiler line it was read off. */
typedef BuildFailureResult = {

	/** The named cause. */
	cause: BuildFailureCause,

	/** The first error line, capped for a report row; empty when there is none. */
	line: String
};

/**
 * `apq mutation-verdict --build <log>` — name the reason a mutated tree did not compile.
 *
 * The classification is PURE over the log text, for the same reason
 * `MutationVerdict` is pure over a parsed transcript: the alternative is a
 * `case` ladder inside a shell function, and this repo has the receipts on what
 * that costs — two bugs in the awk copy of the transcript parser, 316 changed
 * lines apart, neither reachable by a test.
 *
 * Order matters. `Null safety: Cannot unify {` is tested before the general
 * null-safety marker and before the general unify marker, because that one
 * shape is the whole point: it is the arm-authoring blind spot a static
 * predicate cannot decide, so it gets its own name in the report rather than
 * being folded into `type`.
 */
@:nullSafety(Strict)
final class BuildFailure {

	/** Longest compiler line a report row carries before the tail is elided. */
	private static inline final LINE_LIMIT: Int = 200;

	/** What a haxe diagnostic stamps ahead of its line number. */
	private static inline final POSITION_MARKER: String = '.hx:';

	/**
	 * Marker of the registry's own build-macro cross-checks.
	 *
	 * The registry's own path rather than a message template, because a message
	 * gets reworded and a path does not — and rather than the two metadata
	 * spellings that also appear in those messages, because this layer is
	 * grammar-agnostic and `unit.check.BuildMacroMetaSeamTest` is right to
	 * refuse a target-language tag here. The price is narrow and known: an
	 * error about a fixture's own pin SHAPE carries no path, so it lands in
	 * `other` with its line quoted.
	 */
	private static final ARM_REGISTRY_MARKER: String = 'mutation-arms.json';

	/** Markers of a cut that left the source unparseable. */
	private static final SYNTAX_MARKERS: Array<String> = [
		'Missing ;',
		'Unexpected ',
		'Expected ',
		'Unterminated ',
		'Invalid escape sequence',
		'Unclosed '
	];

	/** Markers of a cut whose result typechecks as the wrong thing. */
	private static final TYPE_MARKERS: Array<String> = [
		'should be',
		'Cannot unify',
		'has no field',
		'Too many arguments',
		'Not enough arguments',
		'Unknown identifier',
		'Invalid number of type parameters'
	];

	/** `null-safety-structure` / `inline-return` / … — the token the report row carries. */
	public static function label(cause: BuildFailureCause): String {
		return switch cause {
			case NullSafetyStructure: 'null-safety-structure';
			case NullSafety: 'null-safety';
			case InlineReturn: 'inline-return';
			case ArmRegistry: 'arm-registry';
			case Syntax: 'syntax';
			case TypeError: 'type';
			case Other: 'other';
			case NoError: 'no-error';
		};
	}

	/** Classify one `haxe` build log by its FIRST error line. */
	public static function classify(log: String): BuildFailureResult {
		final line: Null<String> = firstError(log);
		return line == null ? { cause: NoError, line: '' } : { cause: causeOf(line), line: cap(line) };
	}

	/**
	 * The first line of the log that is a compiler ERROR.
	 *
	 * A warning carries a position exactly like an error does — every build of
	 * this tree emits utest's deprecated-enum-abstract one — so the position
	 * shape alone would name the wrong line on every single run.
	 */
	private static function firstError(log: String): Null<String> {
		for (raw in log.split('\n')) {
			final line: String = raw.trim();
			if (line.length == 0 || line.indexOf('Warning :') >= 0) continue;
			if (line.startsWith('Error:') || positioned(line)) return line;
		}
		return null;
	}

	/** Does the line carry a `<file>.hx:<line>:` position stamp? */
	private static function positioned(line: String): Bool {
		final at: Int = line.indexOf(POSITION_MARKER);
		if (at < 0) return false;
		final digits: Int = at + POSITION_MARKER.length;
		var i: Int = digits;
		while (i < line.length && line.charAt(i) >= '0' && line.charAt(i) <= '9') i++;
		return i > digits && line.charAt(i) == ':';
	}

	/** The cause one error line names. */
	private static function causeOf(line: String): BuildFailureCause {
		return if (line.indexOf('Null safety: Cannot unify {') >= 0)
			NullSafetyStructure
		else if (line.indexOf('Null safety:') >= 0)
			NullSafety
		else if (line.indexOf('Cannot inline a not final return') >= 0)
			InlineReturn
		else if (line.indexOf(ARM_REGISTRY_MARKER) >= 0)
			ArmRegistry
		else if (SYNTAX_MARKERS.exists(marker -> line.indexOf(marker) >= 0))
			Syntax
		else if (TYPE_MARKERS.exists(marker -> line.indexOf(marker) >= 0))
			TypeError
		else
			Other;
	}

	/** `<head>…` — a unify message naming every field of a structure must not push the row off screen. */
	private static function cap(line: String): String {
		return line.length <= LINE_LIMIT ? line : '${line.substr(0, LINE_LIMIT)}…';
	}

}
