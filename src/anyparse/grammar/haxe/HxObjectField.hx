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
 * Slice ψ₇: `@:fmt(objectFieldColon)` is a writer-side marker (no
 * parser effect) that switches the `:` emission from the tight default
 * (`a:b`) to the runtime-configurable spacing controlled by
 * `HxModuleWriteOptions.objectFieldColon`. Only this site carries the
 * flag — `HxVarDecl.type` / `HxParam.type` / `HxFnDecl.returnType`
 * share the same `@:lead(':')` but keep the tight layout
 * unconditionally (`x:Int`, `f():Void`).
 *
 * `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 * 'objectLiteralLeftCurly'))` (slice ω-indent-objectliteral) mirrors
 * `HxVarDecl.init` for the nested-object case: when the field's value
 * is itself an `ObjectLit` AND `opt.indentObjectLiteral` is true
 * (default) AND `opt.objectLiteralLeftCurly` is `Next` (Allman), the
 * writer applies a `Nest(_cols, …)` wrap so a nested literal lands one
 * extra indent step deeper (`Address:\n\t\t{...}` inside an outer
 * `var u:U =\n\t{Address:...}` chain). Cuddled `Same` placement keeps
 * the inner literal cuddled to `:` — the gate is inert because `{`
 * already sits on the parent line.
 */
@:peg
typedef HxObjectField = {
	var name:HxIdentLit;
	@:fmt(objectFieldColon, indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly')) @:lead(':') var value:HxExpr;
}
