package anyparse.grammar.haxe.format;

/**
 * Per-construct sub-section of the haxe-formatter `lineEnds.*Curly`
 * keys (`objectLiteralCurly`, `anonTypeCurly`, `blockCurly`,
 * `typedefCurly`, `anonFunctionCurly`). Mirrors the formatter's
 * `CurlyLineEndPolicy` shape — `leftCurly` and `emptyCurly` are
 * modelled; `rightCurly` will land with the slice that introduces the
 * matching writer knob.
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
 */
@:peg typedef HxFormatCurlyLineEndPolicy = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;

	@:optional var emptyCurly:HxFormatEmptyCurlyPolicy;
};
