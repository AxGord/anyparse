package anyparse.grammar.haxe;

/**
 * A class member in the Phase 3 skeleton grammar.
 *
 * Three forms are recognised:
 *  - `VarMember` — `var name:Type;` — a plain mutable field
 *    declaration with a mandatory type annotation and a trailing
 *    semicolon.
 *  - `FinalMember` — `final name:Type = init;` — an immutable field
 *    declaration. The body shape is identical to `VarMember`'s
 *    (`HxVarDecl` covers optional `:Type` and optional `= init`), the
 *    only difference is `@:kw('final')` instead of `@:kw('var')`.
 *    Mirrors `HxStatement.FinalStmt` at the statement level.
 *  - `FnMember`  — `function name():ReturnType {}` — a function
 *    declaration with fixed empty parameter list and empty body (see
 *    `HxFnDecl` for the current limitations).
 *
 * Each constructor uses `@:kw` for its introducer keyword (`var`,
 * `final`, `function`) so the generated parser enforces a word
 * boundary on the match and `classy` does not look like a truncated
 * `class`, `finalists` does not look like `final` followed by `ists`.
 * The trailing `;` on `VarMember` and `FinalMember` is
 * `@:trailOpt(';')` writer-gated by
 * `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))` — the byte
 * twin of `HxStatement.VarStmt` / `FinalStmt`. The `;` is consumed
 * when present and may be omitted when the field initializer ends in
 * `}` (`= function() { … }`, `= switch (e) { … }`, recursive
 * `= try { … } catch …`), matching Haxe's rule that a `}`-closed
 * initializer needs no terminator. Trivia mode preserves the source's
 * `;` presence verbatim through the generic `isAltTrailOptBranch`
 * `trailPresent` synth slot; plain mode falls back to always emitting
 * `;` unless the gate fires.
 *
 * `@:fmt(propagateFieldLevelVar)` on `VarMember` / `FinalMember` (slice
 * ω-fieldlevel-var-value-expr-indent) threads `_setFieldLevelVar` into the
 * `decl` writer call so the descendant `HxVarDecl.init` write knows it is a
 * class-member initializer. The
 * `indentValueIfCtor('IfExpr', 'indentComplexValueExpressions')` entry on
 * `init` then forces its value-expr indent regardless of the config knob —
 * a member `var x = if (…) … else …` (or `= untyped if …`) indents its
 * branches one step deeper. Mirrors haxe-formatter's
 * `Indenter.isFieldLevelVar`, which sets `indentComplexValueExpressions`
 * true for any field-level var/assignment RHS. Local-var statements reach
 * `HxVarDecl` through `HxStatement.VarStmt` / `HxExpr.VarExpr`, never this
 * ctor, so they keep the flag false and stay knob-gated.
 *
 * `final` reaching this enum (instead of being consumed as a member
 * modifier) is enabled by `HxMemberDecl.modifiers` carrying
 * `Array<HxMemberModifier>` — the modifier enum without `Final`. The
 * sealed-class top-level form `final class Foo {}` keeps `Final` via
 * the broader `HxModifier` enum on `HxTopLevelDecl.modifiers`. The
 * legacy `final var x:Int;` form (modifier on `var`) is consequently
 * not accepted at the member position; modern `final x:Int;` is the
 * idiomatic spelling.
 *
 * The one case where member-position `final` IS a modifier — the
 * non-overridable method form `final [static|inline …] function f()` —
 * is handled by `FinalModifiedMember`, tried via ordered first-match
 * BEFORE `FinalMember` (it requires the `function` keyword, so plain
 * `final x:Int;` and the rejected `final var x;` fall through to
 * `FinalMember`). See `HxFinalModifierMember`.
 *
 * `Conditional` covers `#if <cond> <members> [#elseif …] [#else …]
 * #end` preprocessor regions wrapping whole member declarations — the
 * member-scope completion of the cond-comp arc (`HxDecl.Conditional`
 * at decl scope, `HxStatement.Conditional` at stmt scope,
 * `HxMemberModifier.Conditional` for a modifier run). `@:kw('#if')`
 * dispatches with a non-word-char boundary check (so `#iff` is
 * rejected); `@:trail('#end')` consumes the closing directive after
 * `HxConditionalMember` parses the cond atom, the member body Star,
 * the optional `#elseif` chain, and the optional `#else` clause.
 *
 * Position at the end of the enum is by convention (mirror of
 * `HxDecl.Conditional`); branch order does not matter for `#if`
 * because no other `HxClassMember` ctor keyword starts with `#`. A
 * member-level `#if` is reached here only AFTER the modifier-scope
 * `HxMemberModifier.Conditional` is tried via the modifiers Star and
 * rolls back: its `@:trail('#end')` fails on the member introducer
 * keyword (`function` / `var` / `final`), `tryBranch` restores
 * `ctx.pos`, and dispatch falls through to this ctor — the same
 * shared-keyword rollback as `PackageDecl` to `PackageEmpty`. A pure
 * modifier-conditional (`#if X public #end function f()`) still
 * resolves at modifier scope and never reaches this ctor.
 *
 * The single `Conditional` ctor here covers class, interface, and
 * abstract member contexts — all three use `Array<HxMemberDecl>`
 * (`HxClassDecl.members`, `HxInterfaceDecl.members`,
 * `HxAbstractDecl.members`).
 */
@:peg
enum HxClassMember {

	@:kw('var') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'), propagateFieldLevelVar)
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

	@:kw('final') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'), propagateFieldLevelVar)
	FinalMember(decl: HxVarDecl);

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

}
