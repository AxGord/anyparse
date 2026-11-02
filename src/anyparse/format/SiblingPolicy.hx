package anyparse.format;

/**
 * Whether the bodies of one list share one placement decision, read by `SiblingShare`. Format-neutral, so a
 * grammar for another language opts a list in with the same knob shape.
 *
 * - `Off` — each sibling decides alone.
 * - `AnyBreak` — a sibling placed below its head, by width or by shape, moves all of them.
 */
enum abstract SiblingPolicy(Int) from Int to Int {

	final Off = 0;

	final AnyBreak = 1;

}
