package anyparse.format;

/**
 * Four-way placement policy for keyword-and-preceding-token joins
 * (`} else`, `} catch`, `} while`).
 *
 * `Same` — keyword sits on the same line as the preceding token,
 * separated by a single space (`} else {`).
 * `Next` — keyword moves to the next line at the current indent level
 * (`}\n\telse {`).
 * `Keep` — preserve the source shape. The writer reads a per-node
 * boolean captured by the trivia-mode parser and dispatches between
 * `Same` and `Next` layouts at runtime. In plain (non-trivia) mode the
 * parser does not capture the slot, so `Keep` degrades to `Same`.
 *
 * `SameOnBlock` — shape-aware cuddle: the keyword sits on the same line
 * as the preceding token when that token closes a CURLY block
 * (`} else {`), because a block owns its own indent and its `}` is a
 * complete close. After any other shape the `@:fmt(shapeAware)` sites
 * keep the answer they already gave — a forced break after a non-block
 * sibling, and `Keep` (source-preserving) after a BRACKET block, since a
 * bracket body hugging its head is house style owned by a config flag,
 * not a structural fact. A caller with no shape information degrades it
 * to `Same`. Produced by a config fanout (Haxe: `sameLine.expressionIf:
 * next`), never by a JSON value of its own.
 *
 * Consumed by the `@:fmt(sameLine("flagName"))` writer knob: the
 * argument names a `SameLinePolicy` field on the generated
 * `WriteOptions` struct and the writer reads it at runtime per node.
 * Format-neutral: the enum lives in `anyparse.format` so grammars for
 * other languages (AS3, Python, …) can reuse the same shape.
 */
enum abstract SameLinePolicy(Int) from Int to Int {

	final Same = 0;

	final Next = 1;

	final Keep = 2;

	final SameOnBlock = 3;

}
