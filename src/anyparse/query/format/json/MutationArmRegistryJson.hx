package anyparse.query.format.json;

/** A mutation-arm registry document, as far as `MutationArmJson` reads it. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef MutationArmRegistryJson = {
	var arms: Array<MutationArmJson>;
};
