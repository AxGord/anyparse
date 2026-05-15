package anyparse.query.format.line;

/**
 * One `apq meta` diagnostic line:
 * `locPrefix: annotation[(args)] on declKind[ declName]`.
 *
 * `locPrefix` is precomputed by the renderer — `path:line:col` when
 * the annotation has a span, just `path` otherwise — so the
 * span-presence branch stays out of the grammar. `args` (with its
 * `(`…`)` wrapper) and `declName` (with its leading space) are
 * omitted when absent, matching the previous hand-rolled output
 * byte-for-byte.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef MetaLine = {
	@:trail(": ") var locPrefix:String;
	var annotation:String;
	@:optional @:lead("(") @:trail(")") @:sep(", ") var args:Array<String>;
	@:lead(" on ") var declKind:String;
	@:optional @:lead(" ") var declName:String;
};
