package anyparse.query.cli;

/**
 * Marker: this command understands `--fix`, so the dispatcher may strip that flag
 * out of its argv and hand the answer over on the `CliContext`.
 *
 * A MARKER rather than a behaviour, because the behaviour is already shared: every
 * command carrying it finishes through `CliEdit.finishEdit`, which owns what `--fix`
 * does after a write. What differs per command is only whether the flag is legal
 * there, and that is one bit.
 *
 * The strip is conditional ON this marker for one reason: `lint` owns a `--fix` of
 * its own, with entirely different semantics — the whole scope, its own fixed-point
 * passes — and an unconditional strip in the dispatcher would eat it.
 */
@:nullSafety(Strict)
interface PostWriteFix {}
