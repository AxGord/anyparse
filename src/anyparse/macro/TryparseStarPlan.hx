package anyparse.macro;

/**
 * The `StarPlan` of a `@:trivia @:tryparse` Star (member lists, case bodies,
 * conditional-compilation branch bodies, heritage clauses): the inputs only that family reads.
 */
final class TryparseStarPlan extends StarPlan {

	/** `@:fmt(sameLine('<knob>'))`: the knob placing the separator before every element, or null. */
	public inline function sameLine(): Null<String> return _meta.string('sameLine');

	public inline function nestBody(): Bool return _meta.flag('nestBody');

	public inline function padLeading(): Bool return _meta.flag('padLeading');

	public inline function padTrailing(): Bool return _meta.flag('padTrailing');

	public inline function fillItems(): Bool return _meta.flag('fillItems');

	public inline function conditionalBodyIndent(): Bool return _meta.flag('conditionalBodyIndent');

	public inline function refuseFlatOnComplexExpr(): Bool return _meta.flag('refuseFlatOnComplexExpr');

	public inline function refuseGlueOnControlFlowRoot(): Bool return _meta.flag('refuseGlueOnControlFlowRoot');

	public inline function lineLengthAwareSeps(): Bool return _meta.flag('lineLengthAwareSeps');

	public inline function forceInlineSep(): Bool return _meta.flag('forceInlineSep');

	public inline function elemSelfTrailsNewline(): Bool return _meta.flag('elemSelfTrailsNewline');

	public inline function operandBreakAfterMultilineBrace(): Bool return _meta.flag('operandBreakAfterMultilineBrace');

	public inline function sepBeforeOpt(): Bool return _meta.flag('sepBeforeOpt');

	public inline function condExprFitBreak(): Bool return _meta.flag('condExprFitBreak');

	public inline function belowWrappedLabel(): Bool return _meta.flag('belowWrappedLabel');

	public inline function elementPerLine(): Bool return _meta.flag('elementPerLine');

	public inline function bodyPolicy(): Null<Array<String>> return _meta.args('bodyPolicy');

	public inline function flatChildOpt(): Null<Array<String>> return _meta.args('flatChildOpt');

	public inline function listLayout(): Null<Array<String>> return _meta.args('listLayout');

	public inline function siblingSlot(): Null<Array<String>> return _meta.args('siblingSlot');

	public inline function siblingPad(): Null<Array<String>> return _meta.args('siblingPad');

}
