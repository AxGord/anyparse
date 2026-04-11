package anyparse.format.text;

/**
 * Policy for schema fields absent from the input.
 *
 * - `Error`      — reject the input; the field is required.
 * - `Optional`   — leave the field at its default (null, 0, etc.).
 * - `UseDefault` — use the schema-declared default value if any, fall
 *                  back to `Optional` semantics if there is none.
 */
enum abstract MissingPolicy(Int) {
	final Error = 0;
	final Optional = 1;
	final UseDefault = 2;
}
