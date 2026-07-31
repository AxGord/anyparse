package anyparse.grammar.haxe.format;

/**
 * `comments` section of a haxe-formatter `hxformat.json` config.
 *
 * Anyparse-only: the fork has no `comments` block, so the key is an
 * additive extension rather than a modelled subset. It exists because
 * `WriteOptions.commentStyle` — the block-comment canonicalization knob
 * `BlockCommentNormalizer` reads — had no config surface at all: the
 * enum shipped with the engine and only a hand-built `WriteOptions`
 * could reach it.
 *
 * `blockCommentStyle` (slice ω-comment-style) drives
 * `opt.commentStyle`. Accepted tokens: `"verbatim"` (default — source
 * content round-trips byte-identical), `"javadoc"`, `"javadocNoStars"`.
 * An unrecognised token leaves the default in place, matching every
 * other string-mapped key in the loader.
 *
 * `CommentStyle.Plain` has NO token. Its only reachable input is a
 * multi-line `/**` doc, and it re-wraps that as `/* … *\/`, deleting the
 * doc from the compiler's and every doc generator's view; a formatter
 * config must not be able to demote a doc, so `"plain"` falls through
 * to `Verbatim` like any unknown value.
 *
 * The accepted styles reshape MULTI-LINE DOC blocks only — content
 * opening `/**` and carrying a physical newline. A plain `/* … *\/` and
 * a one-physical-line `/** … *\/` keep their source bytes whatever the
 * token says. A reshaped block whose interior is a SINGLE content line
 * collapses back to the one-line form when it fits `wrapping.maxLineLength`
 * at its indent. See `CommentStyle` for the full contract.
 */
@:peg typedef HxFormatCommentsSection = {

	@:optional var blockCommentStyle: String;
};
