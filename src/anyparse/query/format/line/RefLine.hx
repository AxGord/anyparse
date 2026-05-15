package anyparse.query.format.line;

/**
 * One `apq refs` diagnostic line:
 * `file:line:col: [kind] name[ -> bline:bcol]`.
 *
 * Punctuation lives entirely in the field metadata (the
 * `LineDiagFormat` injects none of its own). `line`/`col` are the
 * 1-based line / 0-based column already resolved from the hit span by
 * the renderer; `binding` is the pre-formatted `"bline:bcol"` of the
 * resolved declaration, omitted (the ` -> ` lead with it) for decl
 * self-binds and unresolved reads.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef RefLine = {
	var file:String;
	@:lead(":") var line:Int;
	@:lead(":") var col:Int;
	@:lead(": [") @:trail("] ") var kind:String;
	var name:String;
	@:optional @:lead(" -> ") var binding:String;
};
