package anyparse.grammar.haxe;

/**
 * Type reference in the Haxe grammar skeleton.
 *
 * Phase 3 slice carries an identifier with an optional angle-bracketed
 * type-parameter list — enough to cover `Int`, `Array<Int>`,
 * `Map<String, Int>`, `Foo<Bar<Baz>>`, and user-defined class names.
 * Type-parameter declarations on the *declare* site (`function f<T>()`),
 * module paths (`pkg.Type`), function types (`Int -> Void`),
 * and anonymous structure types are deferred to later Phase 3 milestones.
 *
 * `params` is the close-peek-Star sibling of `HxNewExpr.args` — same
 * `@:lead` / `@:trail` / `@:sep` triple, gated on `@:optional` so the
 * common bare-`Int` case does not require the angle brackets. Recursion
 * composes naturally (`Array<Map<String, Int>>`) because the element
 * rule is `HxTypeRef` itself.
 */
@:peg
typedef HxTypeRef = {
	var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') var params:Null<Array<HxTypeRef>>;
}
