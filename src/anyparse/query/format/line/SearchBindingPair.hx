package anyparse.query.format.line;

/**
 * One `name=value` metavariable binding inside an `apq search`
 * diagnostic line. Punctuation (`=`, and the surrounding
 * ` (`…`)` / `, ` separators) lives in the field metadata here and
 * on `SearchLine`; the `LineDiagFormat` injects none of its own.
 */
@:peg @:schema(anyparse.format.text.LineDiagFormat) @:ws
typedef SearchBindingPair = {
	var name:String;
	@:lead("=") var value:String;
};
