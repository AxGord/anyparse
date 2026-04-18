package anyparse.format;

/**
 * Shared three-way layout policy for control-flow bodies and other
 * fields whose placement relative to the preceding token can vary.
 *
 * `Same` — body sits on the same line as the preceding token,
 * separated by a single space (`if (cond) body;`).
 * `Next` — body is always emitted on the next line at one indent
 * level deeper than the preceding token (`if (cond)\n\tbody;`).
 * `FitLine` — body stays flat if the whole `preceding-token + body`
 * fits within `lineWidth`, otherwise breaks to the next line at one
 * indent level deeper.
 *
 * Consumed by the `@:fmt(bodyPolicy("flagName"))` writer knob: the
 * argument names a `BodyPolicy` field on the generated `WriteOptions`
 * struct and the writer reads it at runtime per node. Format-neutral:
 * the enum lives in `anyparse.format` so grammars for other languages
 * (AS3, Python, …) can reuse the same three-way shape.
 */
enum abstract BodyPolicy(Int) from Int to Int {

	final Same = 0;

	final Next = 1;

	final FitLine = 2;
}
