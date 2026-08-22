package anyparse.grammar.haxe.checkstyle;

/**
 * The `props` object of one `checks[]` entry in a `checkstyle.json`.
 *
 * checkstyle gives every check its own `props` shape; this typedef is the
 * UNION of the props `CheckstyleConfigLoader` actually reads, so a single
 * schema covers every mapped check. Props belonging to checks we do not
 * model are dropped by the ByName parser's inherited `UnknownPolicy.Skip`
 * — a real `checkstyle.json` carries far more keys than these.
 *
 * Every field is `@:optional`: a check may be configured with an empty
 * `props`, in which case the loader applies checkstyle's own default.
 */
@:peg typedef CheckstyleCheckProps = {

	/** Naming-family checks (`TypeName`, `MemberName`, …): the identifier regex. */
	@:optional var format: String;

	/**
	 * Naming-family checks: the checkstyle tokens narrowing WHERE `format` applies
	 * (`['CLASS', 'PUBLIC', 'PRIVATE', 'TYPEDEF']`, `['ENUM']`, `['INLINE']`, …).
	 * An empty or absent list means every token, which is checkstyle's own
	 * `NameCheckBase.hasToken` reading and not "no narrowing at all" by accident.
	 */
	@:optional var tokens: Array<String>;

	/**
	 * Naming-family checks that extend checkstyle's `NameCheckBase` (every one but
	 * `CatchParameterName`): whether a declaration inside an `extern` type is exempt.
	 * checkstyle's own default is TRUE, so a check that omits the key still ignores them —
	 * which is why dropping this key made the adapter STRICTER than every config that says
	 * nothing about it.
	 */
	@:optional var ignoreExtern: Bool;

	/** `CyclomaticComplexity`: the severity/onset pairs the warning threshold is read from. */
	@:optional var thresholds: Array<CheckstyleThreshold>;

	/** `MagicNumber`: literal values the check never flags. */
	@:optional var ignoreNumbers: Array<Float>;

	/** `UnusedImport`: module paths the check never flags. */
	@:optional var ignoreModules: Array<String>;

	/** `ModifierOrder`: the canonical modifier order, as checkstyle UPPER_SNAKE tokens. */
	@:optional var modifiers: Array<String>;

	/** `StringLiteral`: which quote style the config enforces (`onlySingle`, `doubleAndInterpolation`, …). */
	@:optional var policy: String;

	/** `EmptyBlock`: what an empty block must contain (`empty`, `text`, `stmt`). */
	@:optional var option: String;

	/** `Type`: whether enum-abstract values are exempt from the explicit-type requirement. */
	@:optional var ignoreEnumAbstractValues: Bool;
};
