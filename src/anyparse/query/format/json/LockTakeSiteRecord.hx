package anyparse.query.format.json;

/** A written main-thread take of a lock that is not long (`LongLockExplain.LockTakeSite`). */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LockTakeSiteRecord = {
	var file: String;
	@:optional @:writeNull var line: Null<Int>;
	@:optional @:writeNull var col: Null<Int>;
	var lock: String;
	@:key('function') var holder: String;
	var quiet: Bool;
};
