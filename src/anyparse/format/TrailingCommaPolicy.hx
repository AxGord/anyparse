package anyparse.format;

/**
 * Policy for a trailing separator after the LAST element of a
 * MULTILINE list literal (array literal, object literal, call-argument
 * list — every construct whose grammar field opts in with
 * `@:fmt(trailingCommaRemovable)`).
 *
 * `Keep`   — the source's trailing `,` round-trips, and the per-construct
 * `trailingComma*` knobs may still ADD one. Byte-inert default.
 * `Remove` — a multiline list never ends with a separator, whatever the
 * source had and whatever the per-construct knob asks for.
 *
 * Scope is deliberately BREAK-mode only: a single-line list keeps its
 * source trailing comma (`flatTrailingComma`), which is the shape fork
 * round-trips. Constructs where the trailing separator is MANDATORY
 * (a `{ > Base, }` anon-type extension) never carry the opt-in flag and
 * are unreachable from this policy.
 *
 * Format-neutral — lives in `anyparse.format` so any delimited-list
 * grammar can reuse it.
 */
enum abstract TrailingCommaPolicy(Int) from Int to Int {

	final Keep = 0;

	final Remove = 1;

	/**
	 * Resolves the config string (`hxformat.json`
	 * `wrapping.trailingComma`) into a policy value. Unknown strings
	 * return `null` so callers fall back to the runtime default.
	 */
	@:from public static function resolve(name: String): Null<TrailingCommaPolicy> {
		return switch name {
			case 'keep': Keep;
			case 'remove': Remove;
			case _: null;
		};
	}

}
