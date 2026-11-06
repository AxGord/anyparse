package anyparse.query.cli;

/**
 * A walker whose count of leading search texts depends on its argv: `owner` takes a question unless `--list`, `comment-rewrite`
 * a find and a replace, `meta` an annotation only when one is written. `LanguageChoice` asks it, per call, how many leading
 * positionals to leave out of its language decision. The sibling of the `LeadingQuery` marker, which is always exactly one.
 */
@:nullSafety(Strict)
interface LeadingQueryCount {

	/**
	 * How many of the leading positionals of `args` (flags and their values aside) are text.
	 */
	public function leadingQueryCount(args: Array<String>): Int;

}
