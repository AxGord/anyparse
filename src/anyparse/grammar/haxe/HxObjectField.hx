package anyparse.grammar.haxe;

/**
 * Single field entry in an anonymous object literal: `name : value`.
 *
 * The field name uses the `HxIdentLit` terminal — quoted-string keys
 * (`"key": value`) are deferred; Haxe itself only recently added that
 * form and the fork corpus uses bare identifiers exclusively.
 *
 * The value is a full `HxExpr`, parsed with whitespace skipping and
 * the full operator precedence chain — nested object literals, arrays,
 * calls, conditional expressions all compose through the `@:lead(':')`
 * commit point.
 *
 * Slice ψ₇: `@:objectFieldColon` is a writer-side marker (no parser
 * effect) that switches the `:` emission from the tight default
 * (`a:b`) to the runtime-configurable spacing controlled by
 * `HxModuleWriteOptions.objectFieldColon`. Only this site carries the
 * meta — `HxVarDecl.type` / `HxParam.type` / `HxFnDecl.returnType`
 * share the same `@:lead(':')` but keep the tight layout
 * unconditionally (`x:Int`, `f():Void`).
 */
@:peg
typedef HxObjectField = {
	var name:HxIdentLit;
	@:objectFieldColon @:lead(':') var value:HxExpr;
}
