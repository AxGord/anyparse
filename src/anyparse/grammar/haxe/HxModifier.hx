package anyparse.grammar.haxe;

/**
 * Access and storage modifiers for class members.
 *
 * Each constructor is a zero-arg keyword-only branch. The generated
 * parser enforces word boundaries via `expectKw` so `publicly` does
 * not partially match `public`.
 *
 * Semantic validation (e.g. rejecting `public private` or `override`
 * on a `var`) is not the parser's responsibility — it belongs to a
 * later analysis pass.
 */
@:peg
enum HxModifier {
	@:kw('public') Public;
	@:kw('private') Private;
	@:kw('static') Static;
	@:kw('inline') Inline;
	@:kw('override') Override;
	@:kw('final') Final;
	@:kw('dynamic') Dynamic;
	@:kw('extern') Extern;
}
