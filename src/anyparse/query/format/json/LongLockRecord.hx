package anyparse.query.format.json;

/** One written long lock (`LongLockExplain.LongLock`): its reasons, the circular ones counted, and `aside` — `null` when none. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LongLockRecord = {
	var lock: String;
	var reasons: Array<LongLockReasonRecord>;
	var circular: Int;
	@:optional @:writeNull var aside: Null<Array<LongLockReasonRecord>>;
};
