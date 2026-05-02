package anyparse.grammar.haxe.format;

/**
 * Per-construct sub-section of the haxe-formatter `lineEnds.*Curly`
 * keys (`objectLiteralCurly`, `anonTypeCurly`, `blockCurly`,
 * `typedefCurly`, `anonFunctionCurly`). Mirrors the formatter's
 * `CurlyLineEndPolicy` shape — only `leftCurly` is modelled here for
 * now; `rightCurly` and `emptyCurly` will land with the slices that
 * introduce the matching writer knobs.
 *
 * When present in `lineEnds.<construct>Curly`, the `leftCurly` value
 * overrides the global `lineEnds.leftCurly` cascade for that construct
 * only — same precedence as haxe-formatter's `MarkLineEnds.getCurlyPolicy`.
 */
@:peg typedef HxFormatCurlyLineEndPolicy = {

	@:optional var leftCurly:HxFormatLeftCurlyPolicy;
};
