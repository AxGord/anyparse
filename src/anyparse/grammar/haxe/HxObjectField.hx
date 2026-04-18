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
 */
@:peg
typedef HxObjectField = {
	var name:HxIdentLit;
	@:lead(':') var value:HxExpr;
}
