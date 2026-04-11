package anyparse.format.text;

/**
 * Key syntax policy for mapping-based text formats.
 *
 * - `Quoted`   — keys must be surrounded by the format's string quote
 *                character (JSON).
 * - `Unquoted` — keys are bare identifiers matching a format-defined
 *                regex (TOML bare keys).
 * - `Either`   — both forms are accepted (YAML flow, HJSON).
 */
enum abstract KeySyntax(Int) {
	final Quoted = 0;
	final Unquoted = 1;
	final Either = 2;
}
