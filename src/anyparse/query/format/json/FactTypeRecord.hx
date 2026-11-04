package anyparse.query.format.json;

/** A type a facts file records (`{"k":"type",…}`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FactTypeRecord = {
	final id: String;
	final f: String;
	final p: Array<Int>;
	final kind: String;
	final pack: String;
	final ?params: Array<String>;
	final ?meta: Array<String>;
	final ?ext: Bool;
	final ?sup: String;
	final ?of: String;
	final ?builds: Array<String>;
	final ?code: Array<Null<String>>;
	final ?ifaces: Array<String>;
	final ?fields: Array<FactTypeFieldRecord>;
	final ?target: String;
	final ?under: String;
	final ?impl: String;
	final ?ctors: Array<FactCtorRecord>;
}
