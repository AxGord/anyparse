package anyparse.macro;

/** The `StarPlan` of a block-mode trivia Star (`@:lead(open) @:trail(close) @:trivia`): the inputs only that family reads. */
final class BlockStarPlan extends StarPlan {

	/** The flag names this plan reads and its emitter also spells in a refusal. */
	public static inline final BEGIN_END_TYPE: String = 'beginEndType';

	public static inline final BEGIN_END_TYPE_IF_DOC: String = 'beginEndTypeIfDoc';
	public static inline final EXISTING_BETWEEN_FIELDS: String = 'existingBetweenFields';
	public static inline final UNIFORM_BETWEEN: String = 'uniformBetween';

	public inline function gapRule(): Null<Array<String>> return _meta.args('gapRule');

	public inline function indentCaseLabels(): Bool return _meta.flag('indentCaseLabels');

	public inline function emptyCurlyBreak(): Bool return _meta.flag('emptyCurlyBreak');

	public inline function emptyBlockBreak(): Bool return _meta.flag('emptyBlockBreak');

	public inline function beginEndType(): Bool return _meta.flag(BEGIN_END_TYPE);

	/** The knob names of `@:fmt(beginEndType(…))`: null when absent, empty when bare. */
	public inline function beginEndTypeKnobs(): Null<Array<String>> return flagArgs(BEGIN_END_TYPE);

	/** The knob names of `@:fmt(beginEndTypeIfDoc(…))`: null when absent, empty when bare. */
	public inline function beginEndTypeIfDoc(): Null<Array<String>> return flagArgs(BEGIN_END_TYPE_IF_DOC);

	/** The knob name of `@:fmt(existingBetweenFields(…))`: null when absent, empty when bare. */
	public inline function existingBetweenFields(): Null<Array<String>> return flagArgs(EXISTING_BETWEEN_FIELDS);

	/** The arguments of `@:fmt(uniformBetween(…))`, or null when the flag is absent or bare. */
	public inline function uniformBetween(): Null<Array<String>> return _meta.args(UNIFORM_BETWEEN);

	public inline function keepCurlyBlanks(): Bool return _meta.flag('keepCurlyBlanks');

	public inline function blankBeforeFinalDocCommentInLeading(): Bool return _meta.flag('blankBeforeFinalDocCommentInLeading');

	public inline function betweenMultilineCommentsBlanks(): Bool return _meta.flag('betweenMultilineCommentsBlanks');

	public inline function leftCurlyAnonFnOverride(): Bool return _meta.flag('leftCurlyAnonFnOverride');

	public inline function condSwitchOpenCasesNest(): Bool return _meta.flag('condSwitchOpenCasesNest');

	/** The knob of `@:fmt(emptyCurlyBreak('<knob>'))`, or null. */
	public inline function emptyCurlyBreakKnob(): Null<String> return firstArg('emptyCurlyBreak');

	/** The knob of `@:fmt(rightCurly('<knob>'))`, or null. */
	public inline function rightCurlyKnob(): Null<String> return firstArg('rightCurly');

	/** The knob of `@:fmt(rightCurlyAnonFnOverride('<knob>'))`, or null. */
	public inline function rightCurlyAnonFnOverrideKnob(): Null<String> return firstArg('rightCurlyAnonFnOverride');

}
