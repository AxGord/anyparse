package anyparse.grammar.haxe;

/**
 * Type-position carrier in the Haxe grammar.
 *
 * `HxType` is the outer Alt enum that fronts every type-position field
 * (var-decl `:Type`, function-decl return type, abstract underlying
 * type, catch-clause type, etc.). The current foundation slice carries
 * a single `Named` variant wrapping `HxTypeRef` — the named-and-
 * optionally-parameterised type reference (`Int`, `Array<Int>`,
 * `Map<String, Int>`, `haxe.io.Bytes`, `Foo<Bar<Baz>>`).
 *
 * Future additions land as new Alt branches:
 *
 *  - `Arrow(args:Array<HxType>, ret:HxType)` for function types
 *    (`Int -> Void`, `(Int, String) -> Bool`). Right-associative,
 *    parsed via Pratt-style operator dispatch.
 *  - `Anon(fields:Array<HxAnonField>)` for anonymous structure types
 *    (`{a:Int, b:String}`).
 *
 * The wrapper is introduced as a foundation so each new variant lands
 * as a small additive slice rather than retrofitting the type-position
 * shape across the whole grammar each time.
 *
 * `HxTypeRef.params` carries `Array<HxType>`, not `Array<HxTypeRef>`,
 * so type parameters can themselves be arrows or anon structs once
 * those branches are added (`Array<Int -> Void>`, `Map<{a:Int}, B>`).
 */
@:peg
enum HxType {
	Named(ref:HxTypeRef);
}
