package unit.lowering;

import anyparse.grammar.json.JValue;

/**
 * Schema of `test/testkit/fmt-ownership.json`, the record of which macro module names which `@:fmt` flag. The module names are
 * the document's own keys, so `modules` is a map and each value stays a raw `JValue` (an array of flag names): the grammar
 * has no map-of-lists rule. Read by `FmtOwnershipRecordParser`.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FmtOwnershipRecord = {

	var modules: Map<String, JValue>;
};
