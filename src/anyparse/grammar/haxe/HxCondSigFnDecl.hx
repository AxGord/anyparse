package anyparse.grammar.haxe;

/**
 * A class-member `function` whose parameter list closes inside a `#if` region, each branch carrying its own
 * `)` and return type:
 *
 * ```haxe
 * private function f(key:String, get:#if js Void->Array<Float>):Array<Float> #else Layout):Array<Pos> #end
 * {
 * ```
 *
 * The name and the body are nodes; the signature from `(` through `#end` is one raw capture
 * (`HxCondSigRaw`), so its parameters and return type are opaque — the member form sits in
 * `MemberKinds.isOpaqueMemberKind`, and a rename spelled inside the capture is refused. A scope-narrow ctor
 * for the reason `HxCondNameFnDecl` gives: widening `HxFnDecl` would reach every consumer of the ordinary
 * function shape for one library source.
 *
 * Dispatch: `HxClassMember.CondSigFnMember` is tried AFTER `FnMember`, which parses every ordinary signature;
 * only a signature whose `)` hides in a region fails there and falls through to this one.
 */
@:peg
@:fmt(multilineWhenFieldShape('body'))
typedef HxCondSigFnDecl = {
	var name: HxFnNameLit;
	@:lead('(') var signature: HxCondSigRaw;
	@:fmt(leftCurly('blockLeftCurly'), bodyPolicyForCtor('UntypedBlockBody', 'untypedBody'),
		bodyPolicyForCtor('ExprBody', 'functionBody'), metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr')) var body: HxFnBody;
}
