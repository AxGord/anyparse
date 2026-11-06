package anyparse.query.format.json;

/** The written `LongLockExplain.LongLockReport`: each long lock, each main-thread take of a short one, and the dominated locks. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LongLocksRecord = {

	var long: Array<LongLockRecord>;

	var mainShort: Array<LockTakeSiteRecord>;

	var dominated: Array<DominatedLockRecord>;
};
