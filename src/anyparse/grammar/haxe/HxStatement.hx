package anyparse.grammar.haxe;

/**
 * Statement grammar for Haxe function bodies. Branches in source order — keyword-dispatched
 * branches first, block statement next, the expression-statement catch-all last; every
 * shared keyword (`switch`, `try`, `function`, `return`) is resolved by `tryBranch` rollback
 * in source order. Sub-typedef contracts live on those types.
 *
 * `StaticVarStmt` / `StaticFinalStmt` — `static var|final name = init;` static locals, the
 * byte-twin of `VarStmt` / `FinalStmt` through the kw+lead single-Ref pattern. `VarStmt` /
 * `FinalStmt` — local declarations reusing `HxVarDecl`; the trailing `;` is `@:trailOpt(';')`,
 * shape-gated on write via `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))` so `var
 * foo = switch (x) { … }` emits no redundant `;`. `ReturnStmt` — `return expr`, tried before
 * `VoidReturnStmt` (`return;`, Lowering Case 0 with a trail literal, D48); `@:trailOpt(';')`
 * (Haxe allows `return expr` before `}`) with trivia mode preserving the source's `;` via the
 * `trailPresent` synth slot. `@:fmt(bodyPolicy('returnBody'))` on `value` routes the
 * `return`→value separator through the runtime `BodyPolicy` switch (default `FitLine`), and
 * the opt-in `@:fmt(widthAware)` makes `Same` width-aware (an `IfWidthExceeds` wrap — the
 * probe sums every token of the flat shape, so a multi-line value whose first line fits can
 * still break). `indentValueIfCtor('ObjectLit', …)` / `('IfExpr', …)` on `value` mirror the
 * `HxVarDecl.init` entries. `ThrowStmt` — `throw expr;` with `@:fmt(bodyPolicy('throwBody'))`,
 * default `Same` because haxe-formatter leaves `throw <expr>` inline. `IfStmt`, `WhileStmt`,
 * `ForStmt`, `DoWhileStmt` (`@:trail(';')` after the inner typedef) dispatch into their typedefs.
 * `SwitchStmt` / `SwitchStmtBare` share `@:kw('switch')`; the bare form is tried when
 * `@:lead('(')` fails. `TryCatchStmt` / `TryCatchStmtBare` share `@:kw('try')`; the block
 * form carries `@:fmt(tryPolicy)` (the kw-trail-space axis, orthogonal to `tryBody` through
 * `bodyPolicyWrap`'s `kwOwnsInlineSpace` mode), the bare form does NOT — its first field's
 * `bareBodyBreaks` strips the kw-trailing-space slot, so the flag would silently no-op.
 *
 * `UntypedBlockStmt(body:HxUntypedFnBody)` — `untyped { stmts }` as a block-shape statement
 * with no `;`, before `BlockStmt` so the inner `untyped` peek fires first; it carries NO
 * `bodyPolicy('untypedBody')` (a stmt-level inner wrap would stack with parent separators;
 * `HxTryCatchStmt.body`'s `bodyPolicyOverride` handles `try untyped`) and `@:fmt(blockShape)`
 * so shape-aware writers treat it as block-equivalent. `Conditional` — `#if … #end` at
 * statement scope around `HxConditionalStmt`. `LocalFnStmt` / `LocalInlineFnStmt` — named
 * local functions reusing `HxFnDecl`; an anonymous `function()` fails `HxFnDecl.name` and
 * rolls back to `ExprStmt` → `HxExpr.FnExpr`. `BlockStmt` — `{ stmts }`, Case 4. `EmptyStmt`
 * — a lone `;`. `ExprStmt` — `expr;`, last because it has no keyword guard; its `;` is
 * `@:trailOpt(';')` gated parser-side via `@:fmt(trailOptParseGate('stmtExprNoSemi'))`:
 * REQUIRED (the statement Star relies on `expectLit` throwing for boundary detection)
 * UNLESS the parsed expression is brace-terminated (the `endsWithCloseBrace` set).
 */
@:peg
enum HxStatement {

	@:kw('static') @:lead('var') @:trailOpt(';')
	@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon('varDeclTailEndsWithCloseBrace'), captureKwNewline)
	StaticVarStmt(decl: HxVarDecl);

	@:kw('static') @:lead('final') @:trailOpt(';')
	@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon('varDeclTailEndsWithCloseBrace'), captureKwNewline)
	StaticFinalStmt(decl: HxVarDecl);

	@:kw('var') @:trailOpt(';')
	@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon('varDeclTailEndsWithCloseBrace'), deferKwSpace,
		captureKwNewline)
	VarStmt(decl: HxVarDecl);

	@:kw('final') @:trailOpt(';')
	@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon('varDeclTailEndsWithCloseBrace'), deferKwSpace,
		captureKwNewline)
	FinalStmt(decl: HxVarDecl);

	/**
	 * `return` whose whole value is a SELF-TERMINATING token-splice `#if` region, at STATEMENT
	 * level — the sibling of `HxExpr.CondSpliceReturnExpr`, and the arm that actually runs
	 * whenever another statement FOLLOWS the region.
	 *
	 * Without it the expression ctor only won when nothing followed: `ReturnStmt(value: HxExpr)`
	 * sends the region down the atom dispatch, where `HxExpr.CondSpliceExpr`'s MANDATORY `tail`
	 * is happy to be the NEXT STATEMENT — `return #if js 1; #else 2; #end` followed by
	 * `trace(3);` parsed as `ReturnStmt(CondSpliceExpr(Call trace 3))`, the following statement
	 * swallowed INTO the return. With a `}` right after the region the tail failed, the Star
	 * backtracked and the same source parsed correctly — the tell this defect class shows: "it
	 * parses right when it is the LAST thing in its scope".
	 *
	 * Dispatched BEFORE `ReturnStmt` for the same reason `CondSpliceReturnExpr` precedes
	 * `ReturnExpr`. Keying on `return` keeps it away from the two statement-position regions a
	 * general raw ctor claimed (a guarded `case` region, a `@:meta`-prefixed statement) —
	 * neither opens with `return`.
	 */
	@:kw('return')
	CondSpliceReturnStmt(inner: HxCondSpliceClosedRegion);

	@:kw('return') @:trailOpt(';')
	@:fmt(bodyPolicy('returnBody'),
		bodyPolicySingleLine(
			'returnBodySingleLine', 'IfExpr', 'ForExpr', 'WhileExpr', 'SwitchExpr', 'SwitchExprBare', 'TryExpr', 'BlockExpr'
		), indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'),
		indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'), optionalSemicolon('endsWithCloseBrace'), widthAware,
		captureKwNewline, propagateExprPosition)
	ReturnStmt(value: HxExpr);

	@:kw('return') @:trail(';')
	VoidReturnStmt;

	@:kw('if') @:fmt(ifPolicy)
	IfStmt(stmt: HxIfStmt);

	@:kw('while') @:fmt(whilePolicy)
	WhileStmt(stmt: HxWhileStmt);

	@:kw('for') @:fmt(forPolicy)
	ForStmt(stmt: HxForStmt);

	@:kw('switch') @:fmt(switchPolicy)
	SwitchStmt(stmt: HxSwitchStmt);

	@:kw('switch') @:fmt(switchPolicy)
	SwitchStmtBare(stmt: HxSwitchStmtBare);

	@:kw('throw') @:trail(';') @:fmt(bodyPolicy('throwBody'))
	ThrowStmt(expr: HxExpr);

	@:kw('do') @:trail(';')
	DoWhileStmt(stmt: HxDoWhileStmt);

	@:kw('break') @:trail(';')
	BreakStmt;

	@:kw('continue') @:trail(';')
	ContinueStmt;

	@:kw('try') @:rejectFollowKw('catch') @:fmt(tryPolicy, forwardNewlineForBody)
	TryCatchStmt(stmt: HxTryCatchStmt);

	@:kw('try') @:trail(';')
	TryCatchStmtBare(stmt: HxTryCatchStmtBare);

	@:fmt(blockShape)
	UntypedBlockStmt(body: HxUntypedFnBody);

	/**
	 * `#error "msg"` / `#error 'msg'` preprocessor directive at
	 * statement scope (ω-sharp-error). Reachable from
	 * `HxConditionalStmt.body` (`Array<HxStatement>`) — `#if cs #error
	 * '…' #end` inside a function body. `@:kw` + single Ref, no
	 * `@:trail` (like `LocalFnStmt`); falls before the `ExprStmt`
	 * catch-all because `#error` is keyword-dispatched. See
	 * `HxDecl.ErrorDecl` for the shared rationale.
	 */
	@:kw('#error')
	ErrorStmt(message: HxErrorMsg);

	@:kw('#if') @:trail('#end') @:fmt(sharpCondParensGap, conditionalMarkerDedent)
	Conditional(inner: HxConditionalStmt);

	/**
	 * Token-splice fallback for a `#if` region whose every branch opens an
	 * OUTER block and, inside it, a `switch (...) {` header, with the case
	 * list, the switch's `}` and the outer block's `}` all shared after
	 * `#end` - see `HxCondSpliceSwitchOpen`.
	 *
	 * Tried BEFORE `CondSpliceBlockOpen`: `HxCondBlockOpenRaw` also matches
	 * this region (it ends on `{ #end` with a `#else`), and the block-open
	 * ctor's `Array<HxStatement>` body would strand the shared case list on
	 * its `@:trail('}')`. `HxCondSwitchOpenRaw`'s outer-`{`-before-`switch`
	 * constraint keeps the two terminals disjoint for regions with no
	 * switch.
	 */
	@:kw('#if')
	CondSpliceSwitchOpen(inner: HxCondSpliceSwitchOpen);

	/**
	 * Token-splice fallback for a `#if` region whose every branch OPENS a
	 * block, with the block's body and its closing `}` shared after
	 * `#end` - see `HxCondSpliceBlockOpen`.
	 *
	 * Tried BEFORE `CondSpliceStmt`, which is the one inversion of the
	 * "structured production first" rule in this enum. `CondSpliceStmt`'s
	 * `{raw, tail}` shape matches these regions too - it binds the first
	 * shared statement as `tail` and leaves the region's `{` unclosed, so
	 * the parse dies downstream with no backtracking left. The two are
	 * disjoint anyway because `HxCondBlockOpenRaw` requires the fragment
	 * to end on an unclosed `{`, which no dangling-else fragment and no
	 * structurally representable region does.
	 */
	@:kw('#if')
	CondSpliceBlockOpen(inner: HxCondSpliceBlockOpen);

	/**
	 * BLOCK-TAIL region: the fragment CLOSES the enclosing block and then
	 * opens AND closes a block of its own, all before `#end` - see
	 * `HxCondSpliceBlockTail`. Only the unbalanced head is raw; the region's
	 * own block is a real `HxStatement` the writer formats.
	 *
	 * Tried BEFORE `CondSpliceStmt` for the reason `CondSpliceBlockOpen` is:
	 * `CondSpliceStmt`'s `{raw, tail}` shape matches these regions too, and
	 * swallowing the whole region into `raw` is exactly the defect this ctor
	 * removes. `HxCondBlockTailRaw`'s leading-`}`-before-any-`{` constraint
	 * keeps the two disjoint - no dangling-else fragment opens with a `}`.
	 */
	@:kw('#if')
	CondSpliceBlockTail(inner: HxCondSpliceBlockTail);

	/**
	 * Token-splice fallback for `#if` statement regions the structured
	 * `Conditional` fail-rewinds on (dangling-else if-heads) — see
	 * `HxCondSpliceStmt`. Tried directly after it. Also catches a `#if`
	 * wrapping switch `case` / `default` labels with a shared body after
	 * `#end` (no case-list-scope production represents that shape); the
	 * `@:fmt(condSpliceCaseMarkerDedent)` flag then dedents the `#if`
	 * marker one level to the case-list indent when the raw fragment wraps
	 * case clauses (see `WriterLowering.kwRefParts` /
	 * the generated `condSpliceRawWrapsCases`), aligning it with the verbatim
	 * `case` / `#else` / `#end` markers; a dangling-else splice is left at
	 * the statement indent.
	 */
	@:kw('#if') @:fmt(condSpliceCaseMarkerDedent)
	CondSpliceStmt(inner: HxCondSpliceStmt);

	/**
	 * Token-splice fallback for a `#if` region that CLOSES its enclosing
	 * block and re-opens a continuation of the same if-chain, leaving the
	 * shared `}` after `#end` - see `HxCondBlockCloseRaw`.
	 *
	 * Payload-only: nothing between `#end` and the enclosing block's own
	 * `}` belongs to this statement, so there is no tail field and no
	 * `@:trail`. Tried AFTER `CondSpliceStmt` for the ordinary reason -
	 * every region an earlier ctor can represent is already gone. The
	 * leading-`}` constraint in the terminal keeps this maximally greedy
	 * shape from swallowing regions a future structural production
	 * should own.
	 */
	@:kw('#if')
	CondSpliceBlockClose(raw: HxCondBlockCloseRaw);

	/**
	 * Orphan `else` continuation: an `else` clause whose governing `if` head lives in a
	 * DIFFERENT lexical region, so the two cannot be joined into one `HxIfStmt`. Two live
	 * shapes, both produced by a conditional-compilation boundary cutting an if-chain in half:
	 * the entire `else` branch inside a brace-balanced `#if` region that FOLLOWS a complete
	 * if-statement (`if (d == 0) { reopen(); } #if nodejs else if (d > 0) { … } #end`), which
	 * `HxStatement.Conditional` parses structurally with its body Star dispatching here for the
	 * `else` head, so BOTH compilation variants keep a fully structured representation; and the
	 * `else` trailing a `CondSpliceStmt` whose raw fragment carried the parallel `if` heads
	 * (`#if a if (X) #else if (Y) #end body; else other;`), where the splice's `tail` binds the
	 * shared then-branch and the `else` that follows has no `if` to attach to at this scope.
	 *
	 * Why a statement ctor and NOT an `@:optional @:kw('#if')` else-slot on `HxIfStmt`: an
	 * optional kw field COMMITS on its keyword and never backtracks over the sub-rule
	 * (`StructSeqLowering.emitOptionalRefLeadCommit`, D24), so an ordinary structured `#if`
	 * region that merely FOLLOWS an if-statement would be swallowed by the slot with no way to
	 * hand it back to the statement Star; guarding the slot on a leading `else` INSIDE the
	 * region is not expressible either — the commit literal is a single token and the `else`
	 * sits past the condition atom.
	 *
	 * Dispatch is unambiguous without any ordering constraint: no other `HxStatement` ctor
	 * starts with `else`, and `HxIfStmt.elseBody` is a greedy `@:optional @:kw('else')`, so a
	 * well-formed if/else never leaves an `else` for the enclosing Star to see. The payload is a
	 * bare `HxStatement`, so `else if (...) ...` nests as `OrphanElseStmt(IfStmt(...))`; the
	 * generated `stmtNoSemi` recurses into the payload so the `;`-elision verdict is the inner
	 * statement's, exactly as inside a real if-chain.
	 */
	@:kw('else')
	OrphanElseStmt(stmt: HxStatement);

	@:kw('function')
	LocalFnStmt(decl: HxFnDecl);

	@:kw('inline') @:lead('function')
	LocalInlineFnStmt(decl: HxFnDecl);

	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), keepCurlyBlanks,
		clearExprPositionNonTail, uniformStmtBlanks)
	@:lead('{') @:trail('}') @:trivia
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	BlockStmt(stmts: Array<HxStatement>);

	@:lit(';')
	EmptyStmt;

	/**
	 * `....` placeholder statement.
	 *
	 * Statement-level twin of `HxClassMember.EllipsisMember`.
	 * Accepts the literal four-dot token as a function-body statement,
	 * matching the haxe-formatter test corpus convention for elided
	 * function bodies (`function f() { .... }` placeholder fixtures).
	 * Not standard Haxe syntax, but the formatter must round-trip these
	 * files verbatim. SimpleCtor with `@:lit('....')` — twin of
	 * `EmptyStmt(';')` (a literal-only token with no payload). No
	 * `@:trail` because the placeholder has no terminator; trivia after
	 * it (newlines, comments) is captured by the surrounding statement
	 * Star slot. Placed before `ExprStmt` so the lit dispatch fires
	 * before the expression catch-all; no other `HxStatement` ctor's
	 * lit/keyword starts with `.`, so order relative to siblings is by
	 * convention only.
	 *
	 * Distinct token from `HxClassMember.EllipsisMember`'s three-dot
	 * `...`: the corpus convention uses 3 dots at member scope and 4
	 * dots at statement scope. The three-dot `...` is also reused by
	 * `HxExpr.@:infix('...', 5) Interval` at expression scope, so the
	 * four-dot statement variant avoids any collision with the infix
	 * range operator in expression position.
	 */
	@:lit('....')
	EllipsisStmt;

	/**
	 * Metadata-prefixed statement whose whole body is a self-terminating
	 * `#if … ; #end` region — see `HxMetaCondStmt` for the swallow it stops
	 * and for why the metadata is part of the shape rather than an
	 * ordering accident. BEFORE `ExprStmt`, which is the ctor that
	 * otherwise wins by absorbing the next statement.
	 */
	MetaCondStmt(inner: HxMetaCondStmt);

	@:trailOpt(';') @:fmt(trailOptParseGate('stmtExprNoSemi'))
	ExprStmt(expr: HxExpr);

	/**
	 * Metadata-prefixed keyword statement — the fallback AFTER
	 * `ExprStmt` so every shape the expression route already parses
	 * (`@:meta expr;`) keeps its `ExprStmt(MetaExpr(...))`
	 * representation byte-identically; only `@:meta if/try/...`
	 * statements (whose branch consumed the terminator) reach here.
	 * See `HxMetaStmt`.
	 */
	MetaStmt(inner: HxMetaStmt);

}
