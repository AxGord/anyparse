package anyparse.check;

/**
 * The one answer to "how does a check name a file it is handed": its path and its text. Structurally the anonymous
 * `{ file, source }` that `Check.run` and `Linter.collect` spell, so either is accepted where the other is wanted.
 */
typedef SourceEntry = {
	var file: String;
	var source: String;
}
