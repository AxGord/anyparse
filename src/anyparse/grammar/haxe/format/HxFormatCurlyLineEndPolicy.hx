package anyparse.grammar.haxe.format;

/**
 * Per-construct sub-section of the haxe-formatter `lineEnds.*Curly`
 * keys (`objectLiteralCurly`, `anonTypeCurly`, `blockCurly`,
 * `typedefCurly`, `anonFunctionCurly`). Mirrors the formatter's
 * `CurlyLineEndPolicy` shape — `leftCurly`, `emptyCurly` and
 * `rightCurly` are modelled.
 *
 * When present in `lineEnds.<construct>Curly`, the `leftCurly` value
 * overrides the global `lineEnds.leftCurly` cascade for that construct
 * only — same precedence as haxe-formatter's `MarkLineEnds.getCurlyPolicy`.
 *
 * `emptyCurly` (slice ω-anonfunction-empty-curly) overrides the global
 * `lineEnds.emptyCurly` cascade for the construct's empty body
 * dispatch. Currently consumed only by the `anonFunctionCurly`
 * sub-section via `opt.anonFunctionEmptyCurly`; sibling sub-sections
 * (`objectLiteralCurly`, `blockCurly`, …) land with their own slices.
 *
 * `rightCurly` (slice ω-blockright-curly) overrides the global
 * `lineEnds.rightCurly` cascade for the construct's closing-brace
 * placement. Currently consumed only by the `blockCurly` sub-section
 * via `opt.blockRightCurly`; sibling sub-sections land with their own
 * slices. Mirrors haxe-formatter's `RightCurlyLineEndPolicy` —
 * `"before"`/`"both"` collapse to `Same` (hardline before `}`,
 * default), `"after"`/`"none"` collapse to `Inline` (no hardline
 * before `}`) because the trailing newline after `}` is contributed
 * by the surrounding sibling sep, not by `blockBody`.
 */
@:peg typedef HxFormatCurlyLineEndPolicy = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;

	@:optional var emptyCurly:HxFormatEmptyCurlyPolicy;

	@:optional var rightCurly:HxFormatRightCurlyPolicy;
};
