package anyparse.grammar.haxe;

/**
 * A `var` class member whose initializer AND terminator both live inside a `#if` region:
 *
 * ```haxe
 * public static var get:String->(String->Void)->Void =
 * #if nodejs
 * pony.net.http.platform.nodejs.HttpTools.get;
 * #else
 * null;
 * #end
 * ```
 *
 * WHY MEMBER SCOPE AND NOT AN `HxExpr` CTOR: a new `HxExpr` branch after `ConditionalExpr`
 * (which `HxVarDecl.init` would reach for free) also claims a STATEMENT-scope region behind
 * a metadata annotation, because a statement-scope `@meta` routes through
 * `HxExpr.MetaExpr` — and then the enclosing `ExprStmt` has no `;` after `#end`, so the
 * block's separator gate fails on the NEXT statement. Such files parse today only because
 * `HxCondSpliceExpr` swallows the region raw and binds the next call as its tail; relaxing
 * that gate lives in `HxStatement`'s `;`-elision predicates. Scoping the widening to the
 * member-field initializer keeps `HxExpr` untouched — the `HxMemberModifier` vs `HxModifier`
 * discipline; the cost is that a LOCAL `var x = #if a 1; #else 2; #end` does not parse.
 *
 * `region` is deliberately NON-optional. `HxClassMember.VarSemiCondInitMember` is tried
 * BEFORE `VarMember`, so an optional region would let this ctor match a plain `var x:Int`
 * and leave `= 1;` to break the enclosing member Star; mandatory means the ctor fails fast
 * on the `@:kw('#if')` reached through `HxVarSemiInitRegion` and `tryBranch` hands every
 * ordinary field to `VarMember`.
 *
 * The `=` rides `HxVarSemiInitRegion.Conditional` rather than this field: a NON-optional
 * struct-field `@:lead('=')` emits tight (`... -> Void= #if nodejs`), and the ` = ` spacing
 * flags are read off an enum BRANCH only.
 *
 * `access` IS mirrored from `HxVarDecl`, same spelling, for `var x(default, null):Bool = #if
 * !mobile true; #else false; #end`: without it the accessor clause fail-rewinds this ctor and
 * the member falls through to `VarMember`, whose `init` reaches `HxExpr.CondSpliceExpr` — the
 * silently-wrong parse where the raw span binds the NEXT member's `public` as its tail
 * operand, tearing a modifier off its own member. `access` is optional but `region` is not,
 * so `var a(get, set):Int;` rewinds exactly as before. `meta` / `more` stay unmirrored:
 * member metadata rides `HxMemberDecl.meta`; `var a, b` has no meaning next to a guard.
 */
@:peg
typedef HxVarSemiCondInitDecl = {
	var name: HxVarNameLit;
	@:optional @:fmt(tightLead) @:lead('(') var access: Null<HxAccessClause>;
	@:optional @:fmt(typeHintColon) @:lead(':') @:queryTypeSlot var type: Null<HxType>;
	var region: HxVarSemiInitRegion;
}
