package anyparse.grammar.haxe;

/**
 * A `var` class member whose initializer AND terminator both live inside
 * a `#if` region:
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
 * (`Pony/pony/net/http/HttpTools.hx:24` and `:31`, the latter with an
 * `#elseif js` arm. The only sources in the dependency trees with this
 * shape.)
 *
 * WHY MEMBER SCOPE AND NOT AN `HxExpr` CTOR: the obvious root fix is a
 * new `HxExpr` branch after `ConditionalExpr`, which `HxVarDecl.init`
 * would reach for free. It was built, measured, and REVERTED - it
 * regressed `openfl/net/_internal/websocket/WebSocket.hx` and
 * `Pony/pony/Logable.hx`, both of which carry a STATEMENT-scope region
 * behind a metadata annotation:
 *
 * ```haxe
 * @:privateAccess
 * #if cpp
 * var randomByte:Int = ...;
 * #else
 * var randomByte = ...;
 * #end
 * rngBytes.set(i, randomByte);
 * ```
 *
 * A statement-scope `@meta` routes through `HxExpr.MetaExpr`, so an
 * expression-scope ctor claims that region too - and then the enclosing
 * `ExprStmt` has no `;` after `#end`, so the block's separator gate
 * fails on the NEXT statement. Those two files parse today only because
 * `HxCondSpliceExpr` swallows the region raw and binds `rngBytes.set(...)`
 * as its tail; relaxing the gate that would make the structural parse
 * viable lives in `HxStatement`'s `;`-elision predicates, outside this
 * slice's boundary.
 *
 * Scoping the widening to the member-field initializer keeps `HxExpr`
 * untouched and therefore cannot reach statement position at all - the
 * `HxMemberModifier` vs `HxModifier` discipline again. The cost is that
 * a LOCAL `var x = #if a 1; #else 2; #end` still does not parse; no
 * source in the trees has one.
 *
 * `region` is deliberately NON-optional. `HxClassMember.VarSemiCondInitMember`
 * is tried BEFORE `VarMember`, so an optional region would let this ctor
 * match a plain `var x:Int` - consuming the name and type and leaving
 * `= 1;` to break the enclosing member Star. Mandatory means the ctor
 * fails fast on the `@:kw('#if')` reached through `HxVarSemiInitRegion`
 * and `tryBranch` hands every ordinary field to `VarMember`.
 *
 * The `=` rides `HxVarSemiInitRegion.Conditional` rather than this
 * field: a NON-optional struct-field `@:lead('=')` emits tight, and the
 * ` = ` spacing flags (`spaceBeforeLead` / `spaceAfterLead`) are read off
 * an enum BRANCH only - with the lead here the writer produced
 * `... -> Void= #if nodejs`.
 *
 * `meta` / `access` / `more` from `HxVarDecl` are not mirrored: member
 * metadata rides `HxMemberDecl.meta`, a property accessor clause and a
 * multi-binding `var a, b` have no meaning next to a guarded initializer,
 * and no source pairs them.
 */
@:peg
typedef HxVarSemiCondInitDecl = {
	var name: HxVarNameLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type: Null<HxType>;
	var region: HxVarSemiInitRegion;
}
