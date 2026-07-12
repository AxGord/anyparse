package anyparse.grammar.haxe;

/**
 * Expression-position `if` — `if (cond) thenBranch [else elseBranch]`
 * used where a value is expected (object-literal field, call argument,
 * RHS of assignment, array element, etc.).
 *
 * Structurally parallel to `HxIfStmt` but both branches are `HxExpr`,
 * not `HxStatement` — no block-statement fallthrough. The
 * statement-level construct still dispatches through
 * `HxStatement.IfStmt(HxIfStmt)` because enum-branch source order puts
 * `IfStmt` ahead of `ExprStmt` in `HxStatement` — the `if` keyword is
 * consumed by the statement branch before the expression parser ever
 * looks at it.
 *
 * `thenBranch` carries `@:trailOpt(';')`: Haxe accepts an optional
 * `;` terminating the then-branch before `else` (or before the
 * enclosing context when there is no `else`), e.g.
 * `final x = if (c) a; else b;` — the formatter emits this shape, and
 * `if (c) TPath({...}); else if (c) ...; else ...;` in macro code is
 * the common form. Without it the `;` had no host and the parse
 * failed. The `;` is consumed, not stored — the AST is identical to
 * the no-semicolon form. Same `@:trailOpt(';')` meta as
 * `HxStatement.VarStmt`/`FinalStmt` (there paired with
 * `trailOptShapeGate`); here the generic writer-emit default applies
 * since no corpus fixture pins a byte-exact `if-expr; else` layout.
 *
 * Dangling-else follows the same rule as `HxIfStmt`: the nearest
 * enclosing `if` greedily consumes the next `else`, so
 * `if (a) if (b) x else y` binds `else y` to the inner `if`.
 *
 * `@:fmt(bodyPolicy('expressionIfBody'))` on `thenBranch` and
 * `@:fmt(bodyPolicy('expressionElseBody'))` on `elseBranch` — distinct
 * from `HxIfStmt`'s `ifBody` / `elseBody` knobs because expression-
 * position `if` needs different default behaviour. Default `Keep`
 * preserves source layout via the `<field>BeforeNewline:Bool` synth
 * slot (then-branch via the bare-Ref non-first synth, else-branch via
 * the existing optional-kw `BodyOnSameLine` synth). Matches haxe-
 * formatter's `sameLine.expressionIf: @:default(Keep)`. The single
 * JSON key `sameLine.expressionIf` fans out into all three expression
 * body knobs at load time. Single-line branches under any policy
 * stay flat — short flat-fitting expression-`if` (object field
 * values, call args) is unaffected.
 *
 * `elseBranch` carries `@:fmt(sameLine('sameLineExpressionElse'))` —
 * the SameLinePolicy companion for the pre-`else` gap, distinct from
 * statement-`if`'s `sameLineElse`. Default `Same` matches the
 * pre-slice hardcoded space behaviour. JSON `sameLine.expressionIf`
 * fans out unconditionally (Same/Keep/Next/FitLine→Same fallback) —
 * the pre-`else` gap has no arrow-body interaction, so the
 * BodyPolicy Next/FitLine gate does not apply here. `Keep` consults
 * the synth `elseBranchBeforeKwNewline` slot (computed against the
 * preceding field's last non-whitespace position via `_prevEnd`,
 * see `Lowering.hx` ω-prev-content-end).
 *
 * `@:fmt(shapeAware)` on `elseBranch` (parity with
 * `HxIfStmt.elseBody`) — when the preceding sibling `thenBranch`'s
 * runtime ctor is non-block (anything other than `BlockExpr` /
 * `ObjectLit`) AND `expressionElseBody` is `Next` / `FitLine`, the
 * pre-`else` separator switches to a hardline regardless of the
 * `sameLineExpressionElse` flag. Block-shape `thenBranch` (block /
 * object literal) keeps the flag-driven separator so `} else {`
 * cuddles when the source did. `Same`-policy and `Keep`+inline-slot
 * suppress the shape-aware break (matches the gate at
 * `WriterLowering.hx:2670+`).
 *
 * `@:fmt(elseIf)` on `elseBranch` — when the body is itself an
 * `HxIfExpr` (recursive `else if (...)` chain), the body-placement
 * dispatch consults `opt.elseIf:KeywordPlacement` (default `Same`)
 * instead of `expressionElseBody`, so `else if` cuddles inline
 * regardless of the outer body policy. The `findCtorPattern` lookup
 * in `bodyPolicyWrap` tries both `IfStmt` and `IfExpr` ctor names so
 * the same `opt.elseIf` knob covers statement and expression forms.
 * `fitLineIfWithElse` is intentionally absent — the expression form
 * uses the inverse-polarity `noSiblingFallback('ifBody')` mechanism
 * on `thenBranch` (below) for the no-else fallback case.
 *
 * `@:fmt(inlineBlockBodyIfFlag('expressionIfWithBlocks'))` on both
 * branches — runtime override that bypasses the policy-decided
 * layout when `opt.expressionIfWithBlocks == true` AND the body's
 * runtime ctor is `BlockExpr`. Wraps the body's writeCall result in
 * `D.flatten(…)` to collapse `{<hardline>stmt;<hardline>}` to
 * `{stmt;}` regardless of width. Mirrors fork's
 * `sameLine.expressionIfWithBlocks` knob (`MarkSameLine.markBody`
 * with `includeBrOpen=true` triggers `markBlockBody` Same-policy
 * collapse). Non-BlockExpr bodies and `expressionIfWithBlocks=false`
 * fall through to the regular `bodyPolicy` cascade. Caveat: under
 * Trivia mode `// line comments` inside the block body fold against
 * the next token and break syntax — same limitation as fork; the
 * knob is opt-in.
 *
 * `@:fmt(noSiblingFallback('ifBody'))` on `thenBranch` — runtime
 * fallback when the next optional sibling (`elseBranch`) is null:
 * `bodyPolicyWrap` swaps `opt.expressionIfBody` for `opt.ifBody`
 * before any ctor / Keep / Next / FitLine dispatch fires. Mirrors
 * fork's `MarkSameLine.markIf` short-circuits onto `ifBody` for
 * `parent.tok==Arrow` (arrow-body if-without-else) and
 * `isComprehensionFilterIf` (no-else filter form): under
 * `expressionIf=next` the body would otherwise force-break and
 * regress `item -> if (cond) body` and `[for (x in xs) if (cond) x]`.
 * The "inverse polarity" relative to `HxIfStmt`'s
 * `fitLineIfWithElse` is intentional — `fitLineIfWithElse` degrades
 * `FitLine` to `Next` when an `else` IS present; this knob degrades
 * `Next/FitLine/...` to a separate flag when `else` is ABSENT.
 *
 * `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 * 'objectLiteralLeftCurly'))` on `thenBranch` — subtractive variant of
 * the meta carried by `HxVarDecl.init` / `HxObjectField.value` /
 * `HxStatement.ReturnStmt`. When the body is a multi-line ObjectLit AND
 * `indentObjectLiteral=false` AND `objectLiteralLeftCurly=Next`, the
 * default `bodyPolicyWrap` Next-layout's outer Nest is dropped so the
 * obj-lit's `{` aligns with the `if` keyword's column instead of one
 * indent step deeper. Single-line obj-lit bodies (and any other ctor)
 * fall through to the default `Nest(_cols, …)`. Mirrors haxe-formatter's
 * `indentation.indentObjectLiteral=false` rule for the
 * `if (cond)\n{...}` shape. Asymmetry: `elseBranch` does NOT carry the
 * meta — its optional `@:kw('else')` Ref routes through
 * `bodyPolicyWrap`'s kw-trivia slot path (`nextLayoutKwGapDoc`) which
 * the current gate excludes; threading `indentObjArgs` into that helper
 * is deferred until a corpus consumer needs it.
 *
 * `@:fmt(propagateValueIfBranch)` on both branches — sets the narrow
 * `opt._inValueIfBranch` flag on the branch's direct value writer call
 * (via `_setValueIfBranch`, which gates on `opt._inExprPosition` so a
 * statement-position `if` never flips it). Read by `HxObjectLit.fields`
 * (`@:fmt(reflowInExprPosition)`) so a source-multiline object literal
 * that is the immediate branch value collapses to single-line — mirroring
 * haxe-formatter's rule of collapsing object literals only when they are
 * the value of a value-yielded `if`/`else` branch. The flag is cleared on
 * any deeper expression-position descent (`_setExprPosition` resets it),
 * so an object literal nested as e.g. a call argument inside the branch
 * (`if (c) f({obj})`) keeps its source-multiline shape.
 */
@:peg
typedef HxIfExpr = {
	@:lead('(') @:trail(')') @:fmt(condWrap('conditionWrap')) var cond: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('ifBody', 'expressionIfBody'),
		indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'), noSiblingFallback('ifBody'),
		inlineBlockBodyIfFlag('expressionIfWithBlocks'), propagateValueIfBranch) var thenBranch: HxExpr;
	@:optional @:kw('else') @:fmt(bodyPolicy('elseBody', 'expressionElseBody'), sameLine('sameLineExpressionElse'), shapeAware, elseIf,
		inlineBlockBodyIfFlag('expressionIfWithBlocks'), propagateValueIfBranch) var elseBranch: Null<HxExpr>;
};
