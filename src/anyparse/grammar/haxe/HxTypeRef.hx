package anyparse.grammar.haxe;

/**
 * Type reference in the Haxe grammar skeleton.
 *
 * Phase 3 slice carries a possibly module-qualified name with an optional
 * angle-bracketed type-parameter list — enough to cover `Int`,
 * `Array<Int>`, `Map<String, Int>`, `Foo<Bar<Baz>>`, sub-module forms
 * (`Module.SubType`), and pack-qualified forms (`haxe.io.Bytes`). Function
 * types (`Int -> Void`) and anonymous structure types are deferred to
 * later Phase 3 milestones.
 *
 * The `name` field is `HxTypeName`, a terminal that matches a dotted
 * identifier sequence as one regex slice — keeping the type-ref shape
 * flat at the cost of forfeiting structured access to individual pack
 * segments. A future analysis pass can split on `.` if needed.
 *
 * `params` is the close-peek-Star sibling of `HxNewExpr.args` — same
 * `@:lead` / `@:trail` / `@:sep` triple, gated on `@:optional` so the
 * common bare-`Int` case does not require the angle brackets. Recursion
 * composes naturally (`Array<Map<String, Int>>`) because the element
 * rule is `HxTypeRef` itself.
 */
@:peg
typedef HxTypeRef = {
	var name:HxTypeName;
	@:optional @:lead('<') @:trail('>') @:sep(',') var params:Null<Array<HxTypeRef>>;
}
