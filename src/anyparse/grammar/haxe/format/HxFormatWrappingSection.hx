package anyparse.grammar.haxe.format;

/**
 * `wrapping` section of `hxformat.json`. `maxLineLength` → `lineWidth`. Every `WrapRules`
 * cascade key feeds the `HxModuleWriteOptions` knob of the same family — `arrayWrap` →
 * `arrayLiteralWrap`, `anonType`, `methodChain`, `opBoolChain`, `opAddSubChain`,
 * `callParameter`, `objectLiteral`, `conditionWrapping` → `conditionWrap`,
 * `ternaryExpression` → `ternaryWrap`, `functionSignature`, `anonFunctionSignature`,
 * `metadataCallParameter`, `typeParameter`, `multiVar`, `casePattern`,
 * `expressionWrapping` — through `HaxeFormatConfigLoader.wrapRulesFromConfig`, which ingests
 * `rules` verbatim and drops a rule with an unmodelled predicate so the cascade falls
 * through; the defaults mirror the fork's rule sets and are stated on
 * `HaxeFormat.default*Wrap`, the site of each knob on `HxModuleWriteOptions`.
 *
 * Two mappings deserve a note. The fork's `multiVar` rule `anyItemLength <= n` (MIN ≤ n) is
 * mapped to `AllItemLengthsLessThan` (MAX ≤ n) — anyparse has no min≤n condition, and the two
 * coincide on every corpus target. The `objectLiteral` cascade is consulted only for a
 * literal the SOURCE kept on ONE line: a source-multiline literal is force-one-per-lined
 * before the cascade runs (the Star carries no `@:fmt(reflowSourceMultiline)`), mirroring
 * the fork's `objectLiteralWrapping`, which returns early on `!isOriginalSameLine`. A
 * break-mode default therefore does not reach its own output in one pass — pass 1's leading
 * break makes the literal multiline, so pass 2 lands on OnePerLine; `apq fmt` absorbs that
 * by writing the FIXED POINT and reporting the extra rewrite (`FormatFixedPoint`).
 * `anonType`, `callParameter`, `arrayWrap`, `anonFunctionSignature` and `typeParameter` share
 * the shape. `conditionWrapping` and `expressionWrapping` are loader-side scaffolds whose
 * engine wiring is partial; the paren cascade in particular waits on a Doc-level mechanism
 * that decides paren wrap BEFORE the enclosing chain commits its break, the fork's two-pass
 * marker order — a writer-time prototype had the chain commit first and over-indented.
 *
 * Four keys are not cascades: `arrayMatrixWrap` (string → `ArrayMatrixWrap.resolve`, default
 * `matrixWrapWithAlign`, whether a source-detected matrix grid is preserved and its columns
 * right-aligned); and three `Bool` layout policies defaulting to `false` (absent = byte-inert),
 * documented on their `WriteOptions` fields — `comprehensionCuddledOpen` (a sole
 * expression-bodied `for` comprehension keeps its head on the `[` line when it fits),
 * `methodChainCuddledLinks` (a link after a multi-line predecessor that ends in a dedented
 * `})` starts on that closing line) and `soleItemCuddledBrackets` (a `[…]` holding exactly ONE
 * element that owns a wrap point of its own keeps both brackets cuddled to it).
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength: Int;

	@:optional var arrayMatrixWrap: String;

	@:optional var trailingComma: HxFormatWrappingTrailingCommaPolicy;

	@:optional var comprehensionCuddledOpen: Bool;

	@:optional var methodChainCuddledLinks: Bool;

	@:optional var soleItemCuddledBrackets: Bool;

	@:optional var ternaryCuddledBraces: Bool;

	@:optional var arrayWrap: HxFormatWrapRules;

	@:optional var mapWrap: HxFormatWrapRules;

	@:optional var multiVar: HxFormatWrapRules;

	@:optional var casePattern: HxFormatWrapRules;

	@:optional var anonType: HxFormatWrapRules;

	@:optional var methodChain: HxFormatWrapRules;

	@:optional var opBoolChain: HxFormatWrapRules;

	@:optional var opAddSubChain: HxFormatWrapRules;

	@:optional var callParameter: HxFormatWrapRules;

	@:optional var objectLiteral: HxFormatWrapRules;

	@:optional var conditionWrapping: HxFormatWrapRules;

	@:optional var ternaryExpression: HxFormatWrapRules;

	@:optional var functionSignature: HxFormatWrapRules;

	@:optional var anonFunctionSignature: HxFormatWrapRules;

	@:optional var metadataCallParameter: HxFormatWrapRules;

	@:optional var typeParameter: HxFormatWrapRules;

	@:optional var expressionWrapping: HxFormatWrapRules;

	@:optional var implementsExtends: HxFormatWrapRules;
};
