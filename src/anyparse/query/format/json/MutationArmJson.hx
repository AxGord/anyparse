package anyparse.query.format.json;

import anyparse.grammar.json.JValue;

/**
 * One record of a mutation-arm registry, as far as `move-to-helper --arms` reads it
 * (`guard-pin-arm-reach` keeps a wrong-shaped record to report it, so it reads the raw records); a key
 * named nowhere here is skipped, and the registry's whole schema is the test kit's. `find` is a string or a list of them.
 */
@:peg typedef MutationArmJson = {
	var name: String;
	var type: String;
	var method: String;
	@:optional var kind: String;
	@:optional var find: JValue;
};
