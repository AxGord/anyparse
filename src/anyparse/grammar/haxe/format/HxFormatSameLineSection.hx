package anyparse.grammar.haxe.format;

/**
 * `sameLine` section of `hxformat.json`. Each key maps onto the `HxModuleWriteOptions` knob of
 * the same name unless noted; the knob's semantics live there and on the grammar field that
 * consumes it. `ifElse` / `tryCatch` / `doWhile` are two-way same-line knobs for whether
 * `else` / `catch` / `while` sit on the same line as their preceding block. `ifBody` /
 * `elseBody` / `forBody` / `whileBody` / `doWhileBody` (→ `doBody`) / `returnBody` /
 * `returnBodySingleLine` / `catchBody` / `tryBody` / `functionBody` / `untypedBody` /
 * `caseBody` / `expressionCase` are three-way body-placement knobs (`same` / `next` /
 * `fitLine`, plus `keep`); `elseIf` and `elseSwitch` are keyword-placement knobs;
 * `expressionTry` is the same-line knob for an expression-position `try`.
 *
 * `caseBody` and `expressionCase` feed the same Star body site, dispatched on
 * `opt._inExprPosition` rather than OR-ed: `same` and `fitLine` both OVERRIDE a source break,
 * only `keep` reads the source form. So setting `caseBody` alone and testing on a `return
 * switch …` (an EXPRESSION-position switch, governed by `expressionCase`) leaves the source
 * shape untouched and reads exactly like a writer that cannot re-join at all.
 *
 * `expressionIf` fans out into the three runtime knobs `expressionIfBody` /
 * `expressionElseBody` / `expressionForBody` (absent, each keeps its own compiled default —
 * they are NOT uniform) and also drives the per-`else` gap `sameLineExpressionElse`: `same`
 * → `Same`, `keep` → `Keep`, `next` → `SameOnBlock` (the `else` cuddles to a `}` close and
 * keeps its forced break after every other shape), `fitLine` → `Same`.
 * `expressionIfWithBlocks` is a body-CONTENTS flattener for `BlockExpr` branches and nothing
 * else: it never pulls `else` up to a `}` (that is `expressionIf: next`) and never hugs a
 * branch value to its head (that is `expressionIfWithBrackets`, for `[` only).
 *
 * `fitLineIfWithElse`, `loopBodyIfElseNext`, `expressionIfArrowBodyReflow`,
 * `elseIfCommentReflow` and `conditionalExprFit` are `Bool` knobs documented on their
 * `HxModuleWriteOptions` fields; the reflow knobs refuse as a WHOLE whenever a captured
 * comment sits where the glued layout would misplace it, and keep the fork's layout.
 */
@:peg typedef HxFormatSameLineSection = {

	@:optional var ifElse: HxFormatSameLinePolicy;

	@:optional var tryCatch: HxFormatSameLinePolicy;

	@:optional var doWhile: HxFormatSameLinePolicy;

	@:optional var ifBody: HxFormatBodyPolicy;

	@:optional var elseBody: HxFormatBodyPolicy;

	@:optional var forBody: HxFormatBodyPolicy;

	@:optional var whileBody: HxFormatBodyPolicy;

	@:optional var doWhileBody: HxFormatBodyPolicy;

	@:optional var elseIf: HxFormatKeywordPlacement;

	@:optional var elseSwitch: HxFormatKeywordPlacement;

	@:optional var fitLineIfWithElse: Bool;

	@:optional var fitLineBodyGlue: Bool;

	@:optional var loopBodyIfElseNext: Bool;

	@:optional var conditionalExprFit: Bool;

	@:optional var ifElseSemicolonNextLine: Bool;

	@:optional var expressionTry: HxFormatSameLinePolicy;

	@:optional var returnBody: HxFormatBodyPolicy;

	@:optional var returnBodySingleLine: HxFormatBodyPolicy;

	@:optional var catchBody: HxFormatBodyPolicy;

	@:optional var tryBody: HxFormatBodyPolicy;

	@:optional var caseBody: HxFormatBodyPolicy;

	@:optional var expressionCase: HxFormatBodyPolicy;

	@:optional var functionBody: HxFormatBodyPolicy;

	@:optional var anonFunctionBody: HxFormatBodyPolicy;

	@:optional var untypedBody: HxFormatBodyPolicy;

	@:optional var expressionIf: HxFormatBodyPolicy;

	@:optional var expressionIfWithBlocks: Bool;

	/**
	 * omega-bracket-body-glue: the `[` sibling of `expressionIfWithBlocks`.
	 * When `true`, an opening `[` — an array literal AND an array
	 * comprehension, which share one ctor — that is the value of an
	 * expression-`if` branch HUGS the branch head (`return if (c) [` … `] else
	 * [];`) exactly as a `{` block body already does, instead of dropping to
	 * its own line under the `expressionIf` policy. Default `false`; the fork
	 * has no such key, so an absent one is fork parity. A NEW key rather than a
	 * widening of `expressionIfWithBlocks`, whose job is to collapse a block
	 * body's CONTENTS: a config wanting the bracket hug would otherwise have to
	 * flatten every value-`if` block body it owns as well.
	 *
	 * The knob owns the CLOSE side too: a branch value it hugs also drops the
	 * optional `;` the source wrote before `else` and pulls the `else` up to the
	 * `]`, so `return if (c) [` closes as `] else [];` and not as `];` on a line
	 * of its own. Without that half the hug is half a shape -- the pre-`else` gap
	 * resolves to `Keep` under `sameLine.expressionIf: next`, so a break the
	 * source wrote there would survive forever. The `;` drop overrides
	 * `whitespace.semicolonBeforeElse` for this one shape. The curly twin (`};`)
	 * is deliberately NOT covered: `expressionIfWithBlocks` collapses a block
	 * body's CONTENTS and hugs nothing.
	 *
	 * All three seams read the flag ALONE, never the resolved layout: a hug that
	 * sat inside the policy switch which the outer `Keep` arm of
	 * `WriterBodyPolicyLowering.buildBodyCoreWrap` bypasses would, under
	 * `sameLine.expressionIf: keep`, drop the `;` and pull `else` up to the `]`
	 * while leaving the `[` on a line of its own -- the half shape the two close
	 * seams exist to prevent, mirrored. The substitution sits on the policy
	 * VALUE (the seam `loopBodyIfElseNext` uses), so `same` / `next` / `keep`
	 * emit ONE byte-identical result under the knob while every knob-off cell
	 * keeps the bytes it had. `keep` decides the layout POLICY; it never decides
	 * whether an explicit knob applies.
	 */
	@:optional var expressionIfWithBrackets: Bool;

	@:optional var expressionIfArrowBodyReflow: Bool;

	/**
	 * omega-value-if-fit: fit-decides EVERY value-`if`, not only an arrow body -- flat on one line
	 * when it fits, otherwise the exact layout `expressionIf` gives it. Sibling of
	 * `expressionIfArrowBodyReflow`, which wins in an arrow body. Default `false`.
	 */
	@:optional var expressionIfFit: Bool;

	/**
	 * Largest number of value branches an `expressionIfFit` chain may hold and still collapse onto
	 * one line -- `if (c) a else b` is 2, `if (c) a else if (d) b else e` is 3. `0` (default) is no
	 * cap. Inert while `expressionIfFit` is off.
	 */
	@:optional var expressionIfFitMaxBranches: Int;

	@:optional var elseIfCommentReflow: Bool;

	/**
	 * Body placement for an expression-position `for` — the array-comprehension
	 * generator (`[for (x in xs) <body>]`) and any value-position `for`. Reaches
	 * `HxForExpr.body` / `HxForReif.body` through
	 * `@:fmt(bodyPolicy('expressionForBody'))`, the knob `expressionIf` also fans
	 * out into; this key is read AFTER that fanout, so the specific value wins.
	 *
	 * `same` puts the body on the head's line, `next` on its own line one level
	 * in, `keep` reproduces the source break, `fitLine` glues a body whose first
	 * line fits the head line and breaks one whose does not — the engine's own
	 * `BodyPolicy` semantics, identical to `forBody` / `ifBody`.
	 *
	 * An ABSENT key leaves `expressionForBody` at its `Keep` default rather than
	 * the fork's declared `Same`: every corpus fixture omits the key, and a
	 * `Same` default would re-lay every comprehension body the corpus wrote on
	 * its own line.
	 *
	 * `fitLine` ALSO pads the comprehension brackets (`[ for … ]`) through
	 * `HaxeFormatConfigLoader.applyComprehensionForPadding`, mirroring the fork's
	 * `MarkSameLine.markArrayComprehension` FitLine arm, which forces that
	 * spacing whenever `whitespace.bracketConfig.comprehensionBrackets` has not
	 * already asked for it. State the padding through that key when the body
	 * policy you want is not `fitLine`.
	 */
	@:optional var comprehensionFor: HxFormatBodyPolicy;
};
