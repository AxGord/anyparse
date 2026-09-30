package anyparse.core;

/**
 * The identity of one `Doc.LeadingBreak`: the measure render records the token of every break it takes, and a
 * `Doc.BreakCommit` names the token it follows. An object rather than the `LeadingBreak` node itself, because a
 * `Doc -> Doc` rebuild (a list regrouping its items) copies the node and keeps the token.
 */
final class BreakToken {

	public function new(): Void {}

}
