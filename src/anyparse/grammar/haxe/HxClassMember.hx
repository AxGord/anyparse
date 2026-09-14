package anyparse.grammar.haxe;

/**
 * A class member: `VarMember` — `var name:Type;`; `FinalMember` — `final name:Type = init;`, the same
 * `HxVarDecl` body with `@:kw('final')` instead of `@:kw('var')` (mirrors `HxStatement.FinalStmt`); `FnMember`
 * — `function name(...):Ret body` (see `HxFnDecl`); plus the `final`-modifier, guarded-initializer,
 * conditional and splice forms documented on their ctors. Each constructor uses `@:kw` for its introducer
 * keyword so the generated parser enforces a word boundary (`finalists` is not `final` followed by `ists`).
 *
 * The trailing `;` on `VarMember` and `FinalMember` is `@:trailOpt(';')` writer-gated by
 * `@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon(…))` — the byte twin of
 * `HxStatement.VarStmt` / `FinalStmt`: the `;` may be omitted when the initializer of the LAST binding ends in
 * `}` (`= function() { … }`), Haxe's rule that a `}`-closed initializer needs no terminator; on parse the `;`
 * is optional for every member. Trivia mode preserves the source's `;` presence verbatim through the generic
 * `isAltTrailOptBranch` `trailPresent` synth slot; plain mode always emits `;` unless the gate fires.
 *
 * `@:fmt(propagateFieldLevelVar)` on `VarMember` / `FinalMember` (ω-fieldlevel-var-value-expr-indent) threads
 * `_setFieldLevelVar` into the `decl` writer call so the descendant `HxVarDecl.init` write knows it is a
 * class-member initializer; the `indentValueIfCtor('IfExpr', 'indentComplexValueExpressions')` entry on `init`
 * then forces its value-expr indent regardless of the config knob, mirroring haxe-formatter's
 * `Indenter.isFieldLevelVar`. Local-var statements reach `HxVarDecl` through `HxStatement.VarStmt` /
 * `HxExpr.VarExpr`, never this ctor, and stay knob-gated.
 *
 * `final` reaches this enum (instead of being consumed as a member modifier) because `HxMemberDecl.modifiers`
 * carries `Array<HxMemberModifier>` — the modifier enum without `Final`; the legacy `final var x:Int;` form is
 * consequently not accepted at the member position. The one case where member-position `final` IS a modifier —
 * `final [static|inline …] function f()` — is handled by `FinalModifiedMember`, tried via ordered first-match
 * BEFORE `FinalMember` (it requires the `function` keyword). See `HxFinalModifierMember`.
 *
 * `Conditional` covers `#if <cond> <members> [#elseif …] [#else …] #end` regions wrapping whole member
 * declarations: `@:kw('#if')` dispatches with a non-word-char boundary check; `@:trail('#end')` consumes the
 * closing directive after `HxConditionalMember` parses the region. A member-level `#if` is reached here only
 * AFTER the modifier-scope `HxMemberModifier.Conditional` is tried via the modifiers Star and rolls back (its
 * `@:trail('#end')` fails on the member introducer keyword) — the `PackageDecl` to `PackageEmpty`
 * shared-keyword rollback; a pure modifier-conditional never reaches this ctor. The single `Conditional` ctor
 * covers class, interface and abstract member contexts.
 */
@:peg
enum HxClassMember {

	/**
	 * `var name:Type = #if <cond> <expr>; [#else <expr>;] #end` - a field
	 * whose initializer AND terminator both live inside a `#if` region
	 * (slice C3). See `HxVarSemiCondInitDecl` for the motivating Pony
	 * source and for why the widening is scoped to member position
	 * instead of `HxExpr`.
	 *
	 * Tried BEFORE `VarMember`: the region's mandatory `@:kw('#if')` and
	 * mandatory per-branch `;` make every ordinary field fail fast,
	 * `tryBranch` restores `ctx.pos`, and dispatch falls through - the
	 * same ordered first-match rollback as `FinalModifiedMember` before
	 * `FinalMember`. Ordering it AFTER `VarMember` would be useless:
	 * `HxVarDecl.init` reaches `HxExpr.CondSpliceExpr`, which swallows the
	 * region raw and binds the NEXT member's leading `public` as its tail
	 * - a silently wrong parse rather than the fail-rewind this ctor needs.
	 *
	 * No `@:trailOpt(';')`: the terminator is inside the region.
	 */
	@:kw('var')
	VarSemiCondInitMember(decl: HxVarSemiCondInitDecl);

	@:kw('var') @:trailOpt(';')
	@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon('varDeclTailEndsWithCloseBrace'), propagateFieldLevelVar)
	VarMember(decl: HxVarDecl);

	/**
	 * `final` as a non-overridable METHOD MODIFIER (`final static function
	 * main()`, `final function f()`, `final inline function g()`) rather
	 * than the introducer of an immutable field. Tried BEFORE `FinalMember`
	 * so the modifier form wins when `final` precedes an optional modifier
	 * run and the `function` keyword; for a plain `final foo:Int;` (and the
	 * rejected legacy `final var x;`) the inner `HxFinalModifierMember`'s
	 * mandatory `@:kw('function')` fails on the field name / `var` keyword,
	 * `tryBranch` restores `ctx.pos`, and dispatch falls through to
	 * `FinalMember`. Mirrors `HxFinalDecl`'s ordered class-vs-var
	 * first-match at the top-level decl scope. No `@:trailOpt(';')`: the
	 * inner function block `}` is self-terminating, so this branch carries
	 * no terminator of its own. See `HxFinalModifierMember` for full
	 * rationale (issue_5_final_lineend).
	 */
	@:kw('final')
	FinalModifiedMember(rest: HxFinalModifierMember);

	@:kw('final') @:trailOpt(';')
	@:fmt(trailOptShapeGate('varDeclTailEndsWithCloseBrace'), optionalSemicolon('varDeclTailEndsWithCloseBrace'), propagateFieldLevelVar)
	FinalMember(decl: HxVarDecl);

	/**
	 * `function #if <cond> <name> [#else <name>] #end(params) ...` - a
	 * method whose NAME is a preprocessor-guarded region (slice C2). See
	 * `HxCondNameFnDecl` for the motivating haxelib `format` source and
	 * for why the widening is confined to a scope-narrow ctor instead of
	 * relaxing `HxFnDecl.name`.
	 *
	 * Tried BEFORE `FnMember` so the guarded form wins when it applies;
	 * a plain `function foo(...)` fails `HxCondNameFnDecl`'s mandatory
	 * leading `@:kw('#if')`, `tryBranch` restores `ctx.pos`, and dispatch
	 * falls through - the `FinalModifiedMember`-before-`FinalMember`
	 * ordering pattern one member up.
	 */
	@:kw('function')
	CondNameFnMember(decl: HxCondNameFnDecl);

	@:kw('function')
	FnMember(decl: HxFnDecl);

	/**
	 * `#error "msg"` / `#error 'msg'` preprocessor directive at member
	 * scope (slice ω-sharp-error). Reachable from
	 * `HxConditionalMember.body` (`Array<HxMemberDecl>`) — `#if cs
	 * #error '…' #end` inside a class body. Structural twin of
	 * `@:kw('function') FnMember(decl:HxFnDecl)`: `@:kw` + single Ref,
	 * no `@:trail`. See `HxDecl.ErrorDecl` for the shared rationale.
	 */
	@:kw('#error')
	ErrorMember(message: HxErrorMsg);

	/**
	 * `...` placeholder member (slice 33).
	 *
	 * Accepts the literal three-dot token as a class-body member,
	 * matching the haxe-formatter test corpus convention for elided
	 * code (`class A { ... }` placeholder fixtures). Not standard
	 * Haxe syntax, but the formatter must round-trip these files
	 * verbatim. SimpleCtor with `@:lit('...')` — twin of
	 * `HxStatement.EmptyStmt(';')` (a literal-only token with no
	 * payload). No `@:trail` because the placeholder has no
	 * terminator; trivia after it (newlines, comments) is captured
	 * by the surrounding `HxMemberDecl` Star slot.
	 */
	@:lit('...')
	EllipsisMember;

	/**
	 * Stray `;` at class-member scope — legal Haxe the compiler
	 * tolerates after any member (`function f():Void {};`, found live in dogfood sources).
	 * Parsed as its own empty member so sibling spans stay untouched
	 * (a `@:trailOpt(';')` on `FnMember` extended the member span over
	 * the probe trivia and broke span-dependent ops). Literal-only
	 * token with no payload — twin of `HxStatement.EmptyStmt`.
	 */
	@:lit(';')
	EmptySemiMember;

	@:kw('#if') @:trail('#end') @:fmt(conditionalMarkerDedent)
	Conditional(inner: HxConditionalMember);

	/**
	 * Token-splice fallback for a member-scope `#if` region holding
	 * parallel SIGNATURES whose shared function body follows the `#end`
	 * (slice C5) - see `HxCondSharedBodyMember` for the motivating Pony
	 * source and for why the tail is typed `HxFnBody`.
	 *
	 * Tried directly after `Conditional`, the same ordering as
	 * `HxStatement.CondSpliceStmt` after `HxStatement.Conditional`: the
	 * structured ctor fail-rewinds on this shape, and going first would
	 * let the raw swallow + `ExprBody` tail mis-claim ordinary guarded
	 * members.
	 */
	@:kw('#if')
	CondSpliceMember(inner: HxCondSharedBodyMember);

}
