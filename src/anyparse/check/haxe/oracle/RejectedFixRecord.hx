package anyparse.check.haxe.oracle;

/**
 * The file `RejectedFixes` keeps: the keys of the candidate edits the compiler rejected, oldest first. The field is
 * optional so that `@:nullSafety(Strict)` types it honestly — a record written by hand or by another engine may lack it.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef RejectedFixRecord = { var ?rejects: Array<String>; }
