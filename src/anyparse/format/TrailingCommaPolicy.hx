package anyparse.format;

/**
 * Policy for a trailing separator after the LAST element of a MULTILINE
 * list literal.
 *
 * `Keep`   — the source's trailing `,` round-trips, and the per-construct
 * `trailingComma*` knobs may still ADD one. Byte-inert default.
 * `Split`  — `Keep`, plus the authorial lever: a list whose source wrote a separator after its last element is laid out one element
 * per line whatever the cascade and the width answer, and a list without one is laid out by policy and width as
 * under `Keep`. A per-construct add-knob then writes its comma only in the one-per-line shape: the next pass reads
 * any comma the writer wrote as the lever, so a knob comma in a filled layout would split the list a pass later.
 * `Remove` — a multiline list never ends with a separator, whatever the
 * source had and whatever the per-construct knob asks for. `Remove`
 * therefore OUTRANKS `trailingCommas.arrayLiteralDefault` /
 * `callArgumentDefault` / `objectLiteralDefault`: those decide whether to
 * add a comma, this decides whether one may survive.
 *
 * Two consequences worth stating. `Remove` also suppresses the
 * `forceExceeds` signal a source trailing comma raises, so a list that was
 * forced multi-line ONLY by its trailing comma may now fit flat — and a
 * flat list keeps its source comma (see the scope note below), so the comma
 * can reappear in the collapsed shape. That suppression is required: keeping
 * the force while dropping the comma would flip the layout on the next
 * `fmt` pass.
 *
 * Scope is deliberately BREAK-mode only: a single-line list keeps its source
 * trailing comma, which is the shape the fork round-trips.
 *
 * Which lists opt in is a GRAMMAR decision — a field or enum branch carries
 * `@:fmt(trailingCommaRemovable)`. In the Haxe grammar that is the array
 * literal, the object literal, and the two argument lists (`f(…)` and
 * `new T(…)`). Constructs where the trailing separator is MANDATORY (a
 * `{ > Base, }` anon-type extension) never carry the flag and are
 * unreachable from this policy; function parameter lists are left out too.
 *
 * Format-neutral — lives in `anyparse.format` so any delimited-list grammar
 * can reuse it.
 */
enum abstract TrailingCommaPolicy(Int) from Int to Int {

	final Keep = 0;
	final Remove = 1;
	final Split = 2;

	/**
	 * Resolves the config string (`hxformat.json`
	 * `wrapping.trailingComma`) into a policy value. Unknown strings
	 * return `null` so callers fall back to the runtime default.
	 */
	@:from public static function resolve(name: String): Null<TrailingCommaPolicy> {
		return switch name {
			case 'keep': Keep;
			case 'remove': Remove;
			case 'split': Split;
			case _: null;
		};
	}

}
