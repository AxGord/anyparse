package anyparse.query.format.json;

/** The target a configuration generates code for (`{"k":"target","n":S}`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactTargetRecord = {
	final n: String;
}
