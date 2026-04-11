package anyparse.runtime;

/**
 * Tolerant-mode parse result wrapping a typed `value` with its covering
 * `span`, any collected `errors` from the parse, and a `complete` flag.
 *
 * `complete` is `true` when parsing consumed all input cleanly; it is
 * `false` when the parser recovered from errors and produced a partial
 * result. Fast mode does not produce `ParseResult` — it returns bare `T`
 * directly and throws on error.
 */
@:nullSafety(Strict)
final class ParseResult<T> {

	public final value:T;
	public final span:Span;
	public final errors:Array<ParseError>;
	public final complete:Bool;

	public function new(value:T, span:Span, errors:Array<ParseError>, complete:Bool) {
		this.value = value;
		this.span = span;
		this.errors = errors;
		this.complete = complete;
	}
}
