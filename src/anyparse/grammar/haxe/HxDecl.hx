package anyparse.grammar.haxe;

/**
 * A top-level declaration in a Haxe module.
 *
 * Forms recognised (in source order, which is dispatch order):
 *  - `PackageDecl` / `PackageEmpty` — `package foo.bar;` and the bare
 *    `package;` directive (slice ω-toplevel-package). `@:kw('package')`
 *    drives both branches; `PackageDecl(path:HxTypeName)` is tried
 *    first to consume a dotted path, and the nullary `PackageEmpty`
 *    catches the no-name shape via `tryBranch` rollback when
 *    `HxTypeName`'s regex fails on the bare `;`. Real Haxe accepts at
 *    most one `package` per module at the very top, but the parser
 *    does not enforce position or count — semantic policing belongs to
 *    a later analysis pass, not the grammar.
 *  - `ImportDecl` / `UsingDecl` — `import foo.bar.Baz;` and
 *    `using foo.bar.Util;` (slice ω-toplevel-import-using). Each
 *    carries `@:kw('import') / @:kw('using')` plus `@:trail(';')`;
 *    the payload is the same dotted-ident `HxTypeName` regex that
 *    `PackageDecl` uses, so single-segment (`import L;`),
 *    sub-module (`import Module.SubType;`), and pack-qualified
 *    (`import haxe.io.Bytes;`) forms all parse through one ctor.
 *  - `ImportWildDecl` / `UsingWildDecl` — wildcard form
 *    `import haxe.*;` and `using foo.bar.*;` (slice
 *    ω-toplevel-import-wild). Same `@:kw / @:trail` pair as the plain
 *    ctors; payload is `HxWildPath`, a regex requiring a literal `.*`
 *    suffix. Branch order places the wildcard ctors BEFORE the plain
 *    ones so `tryBranch` rollback tries the longer match first and
 *    falls through to the plain `HxTypeName` ctor when the `.*` tail
 *    isn't present (mirrors the `PackageDecl` → `PackageEmpty`
 *    rollback).
 *  - `ImportAliasDecl` / `ImportAliasInDecl` — single-symbol aliased
 *    import, modern `import Std.is as isOfType;` (slice
 *    ω-import-as-alias) and legacy pre-Haxe-4 `import Std.is in
 *    isOfType;` (slice ω-import-in-alias). Payloads are `HxImportAlias`
 *    / `HxImportAliasIn` (path + mandatory `as` / `in <ident>` suffix
 *    respectively) — two struct shapes rather than one shared shape
 *    with a keyword choice, because the writer must re-emit whichever
 *    spelling the source used verbatim (an `in` import is never
 *    rewritten to `as`). Both are placed BEFORE the plain `ImportDecl`
 *    so `tryBranch` attempts the longer match first; a missing `as` /
 *    `in` rolls back to the plain ctor (same longer-match-first
 *    pattern as `ImportWildDecl` → `ImportDecl`). Order between the
 *    two alias ctors themselves does not matter — `as` and `in` are
 *    mutually exclusive keywords, so at most one ever matches a given
 *    import. `using ... as ...` / `using ... in ...` are not legal
 *    Haxe and get no twin ctors; wildcard imports never carry an alias
 *    (`import foo.*` only) so there is no `ImportWildAliasDecl` either.
 *
 *    Like `Package*`, the parser does not enforce ordering or
 *    position of imports relative to other top-level decls; semantic
 *    policing belongs to a later analysis pass.
 *  - `ClassDecl` — `class Name { ... }` wrapping an `HxClassDecl`.
 *  - `TypedefDecl` — `typedef Name = Type[;]` wrapping an `HxTypedefDecl`.
 *    Carries `@:trailOpt(';')` — the trailing semicolon is optional on
 *    parse (real Haxe accepts both `typedef Foo = Int;` and
 *    `typedef Foo = Int`, and the bare `}` form `typedef T = { x:Int }`
 *    is the dominant convention for anon typedefs in the wild). The
 *    writer keeps emitting `;` as canonical output; preserving source
 *    presence is a separate slice.
 *  - `EnumDecl` — `enum Name { ... }` wrapping an `HxEnumDecl`.
 *  - `InterfaceDecl` — `interface Name { ... }` wrapping an `HxInterfaceDecl`.
 *  - `AbstractDecl` — `abstract Name(Type) [from T]* [to T]* { ... }`
 *    wrapping an `HxAbstractDecl`.
 *  - `VarDecl` — `var name [:Type] [= init];` module-level variable
 *    declaration (slice ω-toplevel-var-fn). Reuses `HxVarDecl` from the
 *    class-member / statement grammar. The `@:kw('var')` lives here, the
 *    body has the same shape, and `@:trailOpt(';')` mirrors
 *    `HxStatement.VarStmt`'s relaxation so a `}`-terminated rhs at module
 *    level (rare, but possible) parses without a trailing semicolon.
 *    Top-level `var`/`function` are not part of Haxe's stable surface
 *    syntax, but the AxGord/haxe-formatter corpus contains plain-snippet
 *    fixtures that drop the `class { ... }` wrapper to keep the test
 *    bodies focused — the formatter accepts module-level `var`/`function`
 *    in those snippets, and so do we to unblock the corpus.
 *  - `FnDecl` — `function name(...) [:Ret] { stmts | expr | ; }` module-
 *    level function declaration (slice ω-toplevel-var-fn). Reuses
 *    `HxFnDecl` from the class-member grammar. The `@:kw('function')`
 *    lives here. Body shape (block / no-body) is unchanged from the
 *    inside-class form.
 *
 * Each branch except `Package*`, `Import*`, `Using*`, `VarDecl`, and
 * `FnDecl` carries no `@:kw` — the enclosed sub-rule's first field
 * already consumes the introducer keyword (`class`, `typedef`,
 * `enum`, `interface`, `abstract`). The kw-led ctors break this
 * symmetry because their payloads (`HxVarDecl`, `HxFnDecl`, the bare
 * `HxTypeName` / `HxWildPath` path on `Package*` / `Import*` /
 * `Using*`) intentionally omit the introducer — the keyword is owned
 * by the calling context (`HxClassMember`, `HxStatement`, now
 * `HxDecl`).
 */
@:peg
enum HxDecl {

	@:kw('package') @:trail(';')
	PackageDecl(path: HxTypeName);

	@:kw('package') @:trail(';')
	PackageEmpty;

	@:kw('import') @:trail(';')
	ImportWildDecl(path: HxWildPath);

	@:kw('using') @:trail(';')
	UsingWildDecl(path: HxWildPath);

	@:kw('import') @:trail(';')
	ImportAliasDecl(decl: HxImportAlias);

	@:kw('import') @:trail(';')
	ImportAliasInDecl(decl: HxImportAliasIn);

	@:kw('import') @:trail(';')
	ImportDecl(path: HxTypeName);

	@:kw('using') @:trail(';')
	UsingDecl(path: HxTypeName);

	ClassDecl(decl: HxClassDecl);

	@:trailOpt(';')
	TypedefDecl(decl: HxTypedefDecl);

	/**
	 * `enum abstract Name(Underlying) { Value*; }` — the modern Haxe
	 * enum-abstract form (slice ω-enum-abstract). The `@:kw('enum')`
	 * lives here; the payload reuses `HxAbstractDecl` verbatim, whose
	 * `name` field owns `@:kw('abstract')`. The enum-value body
	 * (`final A = 0;`, `var B;`) is ordinary `HxMemberDecl`, already
	 * handled by `HxAbstractDecl.members`.
	 *
	 * Ordered BEFORE `EnumDecl` so `tryBranch` attempts the
	 * `enum abstract` shape first. For a plain `enum Name { ... }` this
	 * branch consumes `enum`, `HxAbstractDecl` fails on the missing
	 * `abstract` keyword, `tryBranch` rolls back `ctx.pos`, and the
	 * non-kw `EnumDecl` branch then succeeds — the same shared-keyword
	 * rollback pattern as `PackageDecl`→`PackageEmpty` and
	 * `ImportWildDecl`→`ImportDecl`. `@:kw('enum')` enforces a word
	 * boundary (`enumerable` is rejected).
	 *
	 * The legacy `@:enum abstract` metadata form is orthogonal — the
	 * `@:enum` tag rides the `HxTopLevelDecl.meta` Star and reaches the
	 * plain `AbstractDecl` branch.
	 */
	@:kw('enum') @:fmt(propagateEnumAbstractContext)
	EnumAbstractDecl(decl: HxAbstractDecl);

	EnumDecl(decl: HxEnumDecl);

	InterfaceDecl(decl: HxInterfaceDecl);

	/**
	 * `abstract class Name { ... }` — Haxe 4.2+ abstract-class form
	 * (slice ω-abstract-class). Shares the `abstract` keyword with the
	 * adjacent `AbstractDecl(HxAbstractDecl)` type-form (`abstract
	 * Name(Type) { ... }`); the two are separated by an ordered first-
	 * match dispatch with `tryBranch` rollback — the exact shared-
	 * keyword pattern used by `EnumAbstractDecl` → `EnumDecl` and
	 * `FinalDecl`'s `ClassForm` / `VarForm`. `@:kw('abstract')` consumes
	 * the keyword; the inner `HxClassDecl` then matches its own
	 * `@:kw('class')` for `abstract class Foo`, or fails immediately on
	 * `abstract Foo(Int)` (the type form), allowing rollback to the
	 * following `AbstractDecl` ctor. Placed BEFORE `AbstractDecl` so the
	 * longer-prefix shape is tried first.
	 */
	@:kw('abstract')
	AbstractClassDecl(decl: HxClassDecl);

	AbstractDecl(decl: HxAbstractDecl);

	@:kw('var') @:trailOpt(';')
	VarDecl(decl: HxVarDecl);

	/**
	 * Top-level `final …` (slice ω-module-final), covering both
	 * `final class Foo {}` (sealed class) and `final FOO = 1;`
	 * (module-level immutable binding). `HxModifier` carries no `Final` marker (mirroring `HxMemberModifier`'s member-scope split) — the keyword is owned here so both forms reach dispatch. `@:kw('final')` consumes the
	 * keyword; the inner `HxFinalDecl` enum disambiguates class-vs-var
	 * by ordered first-match with `tryBranch` rollback (no lookahead —
	 * see `HxFinalDecl`). `@:trailOpt(';')` terminates the var form and
	 * is harmlessly optional for the `}`-terminated class form. Placed
	 * after `VarDecl`, before `FnDecl`, mirroring the `HxClassMember`
	 * `VarMember`/`FinalMember`/`FnMember` ordering.
	 */
	@:kw('final') @:trailOpt(';')
	FinalDecl(decl: HxFinalDecl);

	@:kw('function')
	FnDecl(decl: HxFnDecl);

	/**
	 * `#error "msg"` / `#error 'msg'` preprocessor directive (slice
	 * ω-sharp-error). In the corpus it only ever appears as the body
	 * of a `#if … #end` guard for an unsupported target, but the
	 * directive is recognised wherever a declaration is, so it slots
	 * into `HxDecl` directly (reachable from `HxConditionalDecl.body`
	 * via `HxTopLevelDecl`). Structural twin of `@:kw('function')
	 * FnDecl(decl:HxFnDecl)` — `@:kw` + single Ref payload, no
	 * `@:trail`; `HxErrorMsg` captures the quoted message verbatim
	 * (quotes included). `#error` shares no keyword prefix with any
	 * other `HxDecl` ctor, so position is immaterial; placed by the
	 * `Conditional` ctor so preprocessor directives cluster.
	 */
	@:kw('#error')
	ErrorDecl(message: HxErrorMsg);

	/**
	 * `#if <cond> <decls> [#else <decls>] #end` preprocessor-guarded
	 * region wrapping module-level declarations (slice ω-cond-comp-
	 * decl). Mirror of `HxModifier.Conditional` at the decl scope:
	 * `@:kw('#if')` dispatches with a non-word-char boundary check (so
	 * `#iff` is rejected); `@:trail('#end')` consumes the closing
	 * directive after `HxConditionalDecl` parses the cond atom, the
	 * body Star, and the optional `#else` clause. Nested `#if` is
	 * supported transitively because the body re-enters `HxDecl`
	 * through `HxTopLevelDecl`.
	 *
	 * Position at the end of the dispatch enum is by convention
	 * (mirror of `HxModifier.Conditional`); branch order does not
	 * matter for `#if` because no other `HxDecl` ctor's keyword starts
	 * with `#`.
	 */
	@:kw('#if') @:trail('#end') @:fmt(conditionalMarkerDedent)
	Conditional(inner: HxConditionalDecl);

}
