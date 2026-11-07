package anyparse.format;

/**
 * Policy for a trailing separator after the LAST element of a list literal,
 * flat or multiline.
 *
 * `Keep`   — the source's trailing `,` round-trips, and the per-construct
 * `trailingComma*` knobs may still ADD one in a multiline list. The Haxe writer
 * defaults to `Remove`; `Keep` is an explicit opt-in, and a config whose
 * `trailingCommas.*Default: "yes"` asks to ADD one while leaving
 * `wrapping.trailingComma` unset loads as `Keep`.
 * `Remove` — a list never ends with a separator, flat or multiline, whatever
 * the source had and whatever the per-construct knob asks for. `Remove`
 * therefore OUTRANKS `trailingCommas.arrayLiteralDefault` /
 * `callArgumentDefault` / `objectLiteralDefault`: those decide whether to
 * add a comma, this decides whether one may survive.
 *
 * `Remove` also suppresses the `forceExceeds` signal a source trailing comma
 * raises, so a list forced multi-line ONLY by its trailing comma may now fit
 * flat; keeping the force while dropping the comma would flip the layout on
 * the next `fmt` pass.
 *
 * Which lists opt in is a GRAMMAR decision — a field or enum branch carries
 * `@:fmt(trailingCommaRemovable)`. In the Haxe grammar that is the array
 * literal, the object literal, and the two argument lists (`f(…)` and
 * `new T(…)`). Constructs where the trailing separator is MANDATORY (a
 * `{ > Base, }` anon-type extension) never carry the flag and are
 * unreachable from this policy; a function parameter list never keeps
 * its trailing separator, whatever the policy.
 *
 * Format-neutral — lives in `anyparse.format` so any delimited-list grammar
 * can reuse it.
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
