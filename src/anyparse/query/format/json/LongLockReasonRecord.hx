package anyparse.query.format.json;

import anyparse.grammar.json.JValue;

/**
 * One written reason a lock is long (`LongLockExplain.LongLockReason`): the site, the function holding it and the kind;
 * a reason spanning a call adds the call, the chain and `via`, and the `catch` its error path passes when there is one;
 * a blind one adds the calls the graph resolves to nothing. `via` is a raw value because it has three states — absent
 * with no call, `null` for a call that blocks other than by a lock, the lock otherwise.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LongLockReasonRecord = {
	var file: String;
	@:optional @:writeNull var line: Null<Int>;
	@:optional @:writeNull var col: Null<Int>;
	@:key('function') var holder: String;
	var kind: String;
	@:optional var call: Null<String>;
	@:optional var chain: Null<Array<String>>;
	@:optional var via: Null<JValue>;
	@:optional var errorPath: Null<String>;
	@:optional var unresolved: Null<Array<BlindCallRecord>>;
};
