package anyparse.grammar.haxe;

/**
 * Grammar for `new T(args)` constructor call expressions.
 *
 * Shape: `new ClassName(arg1, arg2, ...)`.
 *
 * The `new` keyword is consumed at the enum-branch level (`@:kw('new')`
 * on the `NewExpr` ctor in `HxExpr`). This typedef describes the
 * remainder: a constructor type name followed by a parenthesised,
 * comma-separated argument list.
 *
 * `type` is `HxTypeName` (not the bare-identifier `HxIdentLit`) so a
 * module- or pack-qualified constructor path round-trips correctly —
 * `new haxe.Exception(...)`, `new haxe.ds.StringMap(...)`. A bare
 * `HxIdentLit` matched only the leading segment, leaving `.Sub(...)`
 * to be (mis-)absorbed by postfix field-access at statement level and
 * failing outright in switch-case-body position. Both terminals are
 * `@:rawString abstract(String) from String to String`, so this is a
 * zero-ripple terminal swap on the generic raw-String single-Ref path
 * (same precedent as `HxTypeRef.name:HxTypeName`); call-site string
 * comparisons (`(ne.type : String)`) are unaffected.
 *
 * `params` carries the optional angle-bracketed type-parameter list
 * for `new Map<K, V>()` / `new Holder<A, B, C>(args)`. Byte-twin of
 * `HxTypeRef.params` — same `@:optional @:lead('<') @:trail('>')
 * @:sep(',')` shape over `Array<HxType>`, so the full type Alt
 * (named, function, anon-struct) composes naturally as a type-param.
 * Empty Star degrades to no output via the standard optional-Star
 * Lowering path. Zero new Lowering branches.
 *
 * The argument list reuses the sep-peek Star field pattern — same as
 * function parameters in `HxFnDecl` and call args in
 * `HxExpr.Call`. Zero Lowering changes.
 */
@:peg
typedef HxNewExpr = {
	var type:HxTypeName;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var params:Null<Array<HxType>>;
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaArgs'), wrapRules('callParameterWrap')) var args:Array<HxExpr>;
};
