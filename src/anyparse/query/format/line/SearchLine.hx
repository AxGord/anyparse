package anyparse.query.format.line;

/**
 * One `apq search` diagnostic line:
 * `file:line:col: match[ (name=value, …)]`.
 *
 * `line`/`col` are the 1-based line / 0-based column resolved from
 * the match span by the renderer. `bindings` is omitted entirely
 * (with its ` (`…`)` wrapper) when the pattern bound no metavariables
 * — matching the previous hand-rolled output byte-for-byte.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef SearchLine = {
	var file:String;
	@:lead(":") var line:Int;
	@:lead(":") @:trail(": match") var col:Int;
	@:optional @:lead(" (") @:trail(")") @:sep(", ") var bindings:Array<SearchBindingPair>;
};
