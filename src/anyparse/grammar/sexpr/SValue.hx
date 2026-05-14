package anyparse.grammar.sexpr;

/**
 * Universal S-expression value — the grammar driving `apq ast`'s
 * S-expr output. Mirrors `JValue` for JSON: a small recursive enum the
 * macro pipeline lowers to a single Doc-building writer.
 *
 *  - `SAtom(s)` — bare identifier, emitted verbatim.
 *  - `SString(s)` — double-quoted string, emitted with escape table
 *    from `SExprFormat.escapeChar`.
 *  - `SList(items)` — paren-wrapped, space-separated list. The
 *    underlying `sepList` Doc primitive picks inline vs multi-line
 *    layout based on the configured `lineWidth`.
 *
 * Writer-only — no `Build.buildParser` marker is provided. The grammar
 * carries `@:peg` so ShapeBuilder accepts the type; `SValueWriter`
 * uses the same shape to emit Docs.
 */
@:peg
@:schema(anyparse.format.text.SExprFormat)
@:ws
enum SValue {

	SAtom(s:SAtomLit);
	SString(s:SQuotedStringLit);

	// `@:sep('')` — sepList already inserts a softline (space-or-break)
	// between every pair. A non-empty literal separator would compose
	// with that softline to produce a double space inline.
	// `@:fmt(cuddle)` — Lisp convention: first item cuddles to `(` and
	// last to `)` even on break. Sister knob to JSON arrays which keep
	// the default `[\n  items\n]` layout.
	@:lead('(') @:trail(')') @:sep('')
	@:fmt(cuddle)
	SList(items:Array<SValue>);
}
