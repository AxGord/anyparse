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
 * comparisons (`(ne.type : String)`) are unaffected. Type-parameter
 * brackets on the constructed type (`new Map<K, V>()`) are a separate,
 * orthogonal grammar gap left for a later slice.
 *
 * The argument list reuses the sep-peek Star field pattern — same as
 * function parameters in `HxFnDecl` and call args in
 * `HxExpr.Call`. Zero Lowering changes.
 */
@:peg
typedef HxNewExpr = {
	var type:HxTypeName;
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaArgs'), wrapRules('callParameterWrap')) var args:Array<HxExpr>;
};
