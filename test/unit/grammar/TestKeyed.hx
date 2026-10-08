package unit.grammar;

/**
 * A schema whose keys are not Haxe identifiers: `function` is a keyword and `content-type` is no identifier at all, so
 * each field declares the key it is spelled with (`@:key`), which the parser and the writer must both read. Its own
 * module, as a writer's grammar root must be.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef TestKeyed = {

	@:key('function') var member: String;

	@:optional @:key('content-type') var contentType: Null<String>;
};
