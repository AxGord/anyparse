package anyparse.check.oracle;

/**
 * One persisted oracle verdict: the fingerprint it was observed under, the verdict
 * itself (`confirmed` / `rejected`) and the compiler's error text for a rejection.
 *
 * Every field is OPTIONAL so that `@:nullSafety(Strict)` types it `Null<String>`
 * honestly — a record written by hand, or by another engine, may carry any part of it.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef OracleVerdictRecord = {
	var ?fingerprint: String;
	var ?verdict: String;
	var ?errors: String;
}
