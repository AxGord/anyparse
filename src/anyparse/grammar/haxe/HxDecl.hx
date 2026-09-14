package anyparse.grammar.haxe;

/**
 * A top-level declaration in a Haxe module. Forms recognised, in source order (which is
 * dispatch order):
 *
 * `PackageDecl` / `PackageEmpty` — `package foo.bar;` and the bare `package;` directive.
 * `@:kw('package')` drives both; `PackageDecl(path:HxTypeName)` is tried first, and the
 * nullary `PackageEmpty` catches the no-name shape via `tryBranch` rollback when
 * `HxTypeName`'s regex fails on the bare `;`. Position and count are not policed.
 * `ImportDecl` / `UsingDecl` — `@:kw('import') / @:kw('using')` plus `@:trail(';')` over the
 * same dotted-ident `HxTypeName` regex `PackageDecl` uses, so single-segment, sub-module and
 * pack-qualified forms all parse through one ctor. `ImportWildDecl` / `UsingWildDecl` — the
 * wildcard form over `HxWildPath` (a literal `.*` suffix), placed BEFORE the plain ctors so
 * `tryBranch` tries the longer match first. `ImportAliasDecl` / `ImportAliasInDecl` —
 * single-symbol aliased import, modern `as` and legacy pre-Haxe-4 `in`; two struct shapes
 * (`HxImportAlias` / `HxImportAliasIn`) rather than one with a keyword choice, because the
 * writer must re-emit whichever spelling the source used. Both precede the plain
 * `ImportDecl`; order between the two does not matter since `as` and `in` are mutually
 * exclusive. `using ... as` is not legal Haxe and gets no twin; a wildcard import never
 * carries an alias.
 *
 * `ClassDecl` — `class Name { ... }` wrapping an `HxClassDecl`. `TypedefDecl` — `typedef Name
 * = Type[;]` wrapping an `HxTypedefDecl`; carries `@:trailOpt(';')` because real Haxe accepts
 * both spellings and the bare `}` form is the dominant convention for anon typedefs (the
 * writer emits `;` as canonical output). `EnumDecl`, `InterfaceDecl`, `AbstractDecl` wrap
 * their `Hx*Decl` sub-rule. `VarDecl` — `var name [:Type] [= init];` module-level variable,
 * reusing `HxVarDecl` with the `@:kw('var')` here and `@:trailOpt(';')` mirroring
 * `HxStatement.VarStmt`; `FnDecl` — module-level `function`, reusing `HxFnDecl`. Top-level
 * `var`/`function` are not part of Haxe's stable surface syntax, but the haxe-formatter
 * corpus contains plain-snippet fixtures that drop the `class { ... }` wrapper, and the
 * formatter accepts them, so this grammar does too.
 *
 * Each branch except `Package*`, `Import*`, `Using*`, `VarDecl` and `FnDecl` carries no
 * `@:kw` — the enclosed sub-rule's first field already consumes the introducer keyword. The
 * kw-led ctors break this symmetry because their payloads intentionally omit the introducer
 * — the keyword is owned by the calling context (`HxClassMember`, `HxStatement`, `HxDecl`).
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
	 * (module-level immutable binding). `HxModifier` carries no `Final` marker (mirroring `HxMemberModifier`'s
	 * member-scope split) — the keyword is owned here so both forms reach dispatch. `@:kw('final')` consumes the
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

	/**
	 * `#if <cond> <type-decl header> { #else <header> { #end <members> }`
	 * - a conditional region holding PARALLEL type-declaration headers
	 * whose shared body lives after `#end`. See `HxCondSharedBodyDecl`
	 * for the shape, the motivating sources and the rejected
	 * alternatives.
	 *
	 * Tried AFTER `Conditional` so every balanced `#if` declaration
	 * region keeps its structured representation: `Conditional` fails on
	 * this shape because its body Star cannot parse a declaration whose
	 * `}` is outside the region, and rolls back before this ctor is
	 * reached.
	 *
	 * Both braces are consumed inside the payload: the one the FIRST
	 * branch's header opens by `HxDeclHead`'s `@:trail('{')`, the
	 * closer by `HxCondSharedBodyDecl.members`' `@:trail('}')`. The ctor
	 * itself carries no trail.
	 */
	@:kw('#if')
	CondSharedBodyDecl(inner: HxCondSharedBodyDecl);

}
