package anyparse.macro;

/** The `StarPlan` of a separated-list trivia Star (`@:trivia` + `@:sep`): the inputs only that family reads. */
final class SepStarPlan extends StarPlan {

	public inline function forceMultiInTypedef(): Bool return _meta.flag('forceMultiInTypedef');

	public inline function groupRestProbe(): Bool return _meta.flag('groupRestProbe');

	public inline function ignoreSourceNewlinesForWrap(): Bool return _meta.flag('ignoreSourceNewlinesForWrap');

	public inline function reflowSourceMultiline(): Bool return _meta.flag('reflowSourceMultiline');

	public inline function arrayMatrixWrap(): Bool return _meta.flag('arrayMatrixWrap');

	public inline function reflowInExprPosition(): Bool return _meta.flag('reflowInExprPosition');

	public inline function trailingCommaRemovable(): Bool return _meta.flag('trailingCommaRemovable');

	public inline function complexItems(): Bool return _meta.flag('complexItems');

	public inline function typedefBodyBlanks(): Bool return _meta.flag('typedefBodyBlanks');

	/** `@:fmt(wrapRules('<knob>'))`: the `WrapRules` option the list's wrap cascade reads, or null. */
	public inline function wrapRules(): Null<String> return _meta.string('wrapRules');

	/** `@:fmt(trailingComma('<knob>'))`: the option appending a trailing separator to a broken list, or null. */
	public inline function trailingComma(): Null<String> return _meta.string('trailingComma');

	/** `@:fmt(rightCurly('<knob>'))` with exactly one argument, or null. */
	public inline function rightCurly(): Null<String> return _meta.string('rightCurly');

	/** `@:fmt(leftCurly('<knob>'))`: the `LeftCurlyPlacement` option placing the list's open brace, or null. */
	public inline function leftCurly(): Null<String> return _meta.string('leftCurly');

	/** `@:fmt(matrixCollapseRules('<knob>'))`: the `WrapRules` option deciding whether a source grid may go on one line, or null. */
	public inline function matrixCollapseRules(): Null<String> return _meta.string('matrixCollapseRules');

	/** `@:fmt(mapWrapRules('<knob>'))`: the option of a map literal's wrap rules, or null. */
	public inline function mapWrapRules(): Null<String> return _meta.string('mapWrapRules');

	public inline function bracketKindPad(): Bool return _meta.flag('bracketKindPad');

	public inline function bodyAwareCompactIndent(): Bool return _meta.flag('bodyAwareCompactIndent');

}
