package anyparse.format.text;

/**
 * Policy for input entries with no matching schema field.
 *
 * - `Skip`  — silently drop them (JSON default).
 * - `Error` — reject the input as malformed (strict mode).
 * - `Store` — collect into a dedicated "extras" field on the value if
 *             the schema provides one.
 */
enum abstract UnknownPolicy(Int) {
	final Skip = 0;
	final Error = 1;
	final Store = 2;
}
