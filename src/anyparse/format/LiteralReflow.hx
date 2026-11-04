package anyparse.format;

/**
 * Where a writer's descent stands towards a literal that drops its source newlines, so its wrap cascade decides by width alone.
 * One field holds the whole state because each position of the descent is in exactly one of them. Format-neutral.
 *
 * - `Off` — no literal below reflows.
 * - `Here` — the literal this descent reaches directly reflows; a fresh expression-position frame ends it.
 * - `ThroughWrap` — this descent enters a wrapper (a paren) that hands `Here` to a literal directly inside it.
 */
enum abstract LiteralReflow(Int) from Int to Int {

	final Off = 0;

	final Here = 1;

	final ThroughWrap = 2;

}
