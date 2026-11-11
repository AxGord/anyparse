package anyparse.query.format.json;

/**
 * A value of an enum abstract a facts file's node record holds: the abstract `t`, the constant the compiler read in the
 * value's place — its kind `k` (`n` number, `s` string, `b` bool) and its text `v` — at `p`.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef FactValRecord = {
	final t: String;
	final k: String;
	final v: String;
	final p: Array<Int>;
}
