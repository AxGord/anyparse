package anyparse.grammar.json;

/**
	Raw JSON AST — the universal schema for JSON, accepting any valid
	document. Used when the caller does not have a specific typed schema.

	Specific application schemas (e.g. a `User` class with `@:field("id")`)
	will be parsed through generated parsers in later phases; `JValue` is the
	fallback/raw path.
**/
enum JValue {
	JNull;
	JBool(v:Bool);
	JNumber(v:Float);
	JString(v:String);
	JArray(items:Array<JValue>);
	JObject(entries:Array<JEntry>);
}
