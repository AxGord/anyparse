package anyparse.runtime;

import haxe.Exception;

/**
 * Structured parse error with source span, human-readable message,
 * optional "expected X" hint and severity.
 *
 * Extends `haxe.Exception` so Fast-mode parsers can throw it directly.
 * Tolerant-mode parsers accumulate instances in `Parser.errors` without
 * throwing until parsing finishes.
 */
@:nullSafety(Strict)
class ParseError extends Exception {

	public final span:Span;
	public final expected:Null<String>;
	public final severity:Severity;

	public function new(span:Span, message:String, ?expected:String, severity:Severity = Severity.Error) {
		super(message);
		this.span = span;
		this.expected = expected;
		this.severity = severity;
	}

	override public function toString():String {
		final label:String = severity == Severity.Warning ? 'warning' : 'error';
		final base:String = '$label at $span: $message';
		return expected == null ? base : '$base (expected $expected)';
	}
}
