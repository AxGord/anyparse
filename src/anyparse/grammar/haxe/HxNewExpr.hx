package anyparse.grammar.haxe;

/**
 * Grammar for `new T(args)` constructor call expressions: `new ClassName<params>(arg1, arg2,
 * ...)`. The `new` keyword is consumed at the enum-branch level (`@:kw('new')` on the
 * `NewExpr` ctor in `HxExpr`); this typedef describes the remainder.
 *
 * `type` is `HxNewTypeName` — `HxTypeName`'s byte-twin with an optional `\$?` prefix on the
 * first ident segment for macro type-reification (`new $tp()`, `new $tp.Sub(args)`). Module-
 * and pack-qualified constructor paths round-trip via the regex's dotted continuation — a
 * single-segment terminal would leave `.Sub(...)` to be mis-absorbed by postfix field-access.
 * The `$` prefix is kept LOCAL to the constructor-target slot rather than widening
 * `HxTypeName` itself, so the `HxType.Named` vs `HxType.DollarType` dispatch contract is
 * preserved — a `$`-bearing `HxTypeName` on `HxTypeRef.name` would shadow `DollarType` since
 * `Named` is the first `HxType` branch. Like `HxTypeName` and `HxIdentLit`, the terminal is a
 * `@:rawString abstract(String) from String to String`, so `(ne.type : String)` comparisons
 * work directly.
 *
 * `params` carries the optional angle-bracketed type-parameter list for `new Map<K, V>()`.
 * Byte-twin of `HxTypeRef.params` — the same `@:optional @:lead('<') @:trail('>') @:sep(',')`
 * shape over `Array<HxType>`; an empty Star degrades to no output via the standard
 * optional-Star Lowering path.
 *
 * The argument list reuses the sep-peek Star field pattern of `HxFnDecl.params` and
 * `HxExpr.Call`. It carries `@:trivia` so the args' Star collects per-element `Trivial<HxExpr>`
 * source trivia and the writer drives layout through `triviaSepStarExpr`.
 * `@:fmt(ignoreSourceNewlinesForWrap)` mirrors `HxFnDecl.params`: under the DEFAULT (non-keep)
 * `callParameter` config the intrinsic Ignore semantic DROPS the per-argument source newlines
 * so the wrap cascade — not the source grid — drives layout; under a `callParameter`
 * `defaultWrap: keep` config the `triviaSepStarExpr` `_keepEmit` gate (resolved via
 * `cascadeIsKeep`) wins over Ignore and the per-element `newlineBefore` swap preserves the
 * source per-argument line breaks.
 *
 * `@:fmt(trailingCommaRemovable)` (ω-multiline-trailing-comma-remove) opts the argument list
 * into `wrapping.trailingComma`: under `remove` a broken argument list never ends with a `,`,
 * whatever the source had and whatever `trailingCommas.callArgumentDefault` asks for. The
 * trailing separator is optional here, so the removal direction is always syntactically safe.
 */
@:peg
typedef HxNewExpr = {
	var type: HxNewTypeName;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var params: Null<Array<HxType>>;
	@:trivia @:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaArgs'), trailingCommaRemovable,
		wrapRules('callParameterWrap'), ignoreSourceNewlinesForWrap, groupRestProbe, complexItems) var args: Array<HxExpr>;
};
