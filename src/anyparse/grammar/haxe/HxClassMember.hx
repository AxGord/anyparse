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
 * `final` reaching this enum (instead of being consumed as a member
 * modifier) is enabled by `HxMemberDecl.modifiers` carrying
 * `Array<HxMemberModifier>` — the modifier enum without `Final`. The
 * sealed-class top-level form `final class Foo {}` keeps `Final` via
 * the broader `HxModifier` enum on `HxTopLevelDecl.modifiers`. The
 * legacy `final var x:Int;` form (modifier on `var`) is consequently
 * not accepted at the member position; modern `final x:Int;` is the
 * idiomatic spelling.
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

	@:kw('var') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))
	VarMember(decl:HxVarDecl);

	@:kw('final') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))
	FinalMember(decl:HxVarDecl);

	@:kw('function')
	FnMember(decl:HxFnDecl);

	/**
	 * `#error "msg"` / `#error 'msg'` preprocessor directive at member
	 * scope (slice ω-sharp-error). Reachable from
	 * `HxConditionalMember.body` (`Array<HxMemberDecl>`) — `#if cs
	 * #error '…' #end` inside a class body. Structural twin of
	 * `@:kw('function') FnMember(decl:HxFnDecl)`: `@:kw` + single Ref,
	 * no `@:trail`. See `HxDecl.ErrorDecl` for the shared rationale.
	 */
	@:kw('#error')
	ErrorMember(message:HxErrorMsg);

	@:kw('#if') @:trail('#end')
	Conditional(inner:HxConditionalMember);
}
