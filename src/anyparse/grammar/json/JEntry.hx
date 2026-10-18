package anyparse.grammar.json;

/**
 * One key-value pair of a JSON object.
 *
 * Represented as a typedef over an anonymous structure so that
 * construction sites can use struct literals (`{key: "x", value: v}`)
 * and `==`-style field comparison stays structural.
 *
 * The `@:peg` metadata marks this typedef as part of a grammar so the
 * macro pipeline picks it up as a named sub-rule; `key` uses the
 * `JStringLit` terminal (a transparent abstract over `String`) and
 * `value` carries `@:lead(":")` so the generated parser inserts the
 * key/value separator between the two fields.
 *
 * The `var ... ;` form is used here (instead of the terser
 * `field:Type,` form) because Haxe only accepts field-level metadata
 * on the long form.
 *
 * `@:spanned('Member')` and `@:queryName` are read by the SPAN pipeline alone: the span parser
 * (`JValueSpanParser`) gives each entry its own span, from the key's opening quote to the
 * value's last byte, and the query walker (`JsonQueryWalker`) projects it as a `Member` node
 * NAMED by its decoded key — what `--select 'Member:rules'` addresses. The plain parser, the
 * writer and the transform ignore both.
 */
@:peg
@:spanned('Member')
typedef JEntry = {
	@:queryName var key: JStringLit;
	@:lead(':') var value: JValue;
}
