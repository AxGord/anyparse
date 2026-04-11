package anyparse.runtime;

/**
 * Severity of a `ParseError`. Tolerant-mode parsers collect both errors
 * and warnings into the same list; Fast mode throws on the first error
 * and ignores warnings entirely.
 */
enum abstract Severity(Int) {
	final Error = 0;
	final Warning = 1;
}
