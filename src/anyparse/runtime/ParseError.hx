package anyparse.runtime;

import anyparse.runtime.Span.Position;
import haxe.Exception;

/**
 * Structured parse error with source span, human-readable message,
 * optional "expected X" hint and severity.
 *
 * Extends `haxe.Exception` so Fast-mode parsers can throw it directly.
 * Tolerant-mode parsers accumulate instances in `Parser.errors` without
 * throwing until parsing finishes.
 *
 * `source` is optional. When set (the public entry point attaches the
 * input string in its catch-and-decorate before re-throwing), `toString`
 * resolves `span.from` to a 1-indexed `line:col` so the message reads
 * `error at 142:5: …` instead of the raw-byte-offset `error at 3989: …`
 * — directly actionable in any editor. The field is mutable specifically
 * so the entry point can decorate an error built deep in the generated
 * parser body without having to thread the source through every
 * construction site. When unset (e.g. a unit test constructs a
 * `ParseError` in isolation), `toString` falls back to the byte-offset
 * form so existing assertions stay green.
 */
@:nullSafety(Strict)
class ParseError extends Exception {

	/**
	 * Shared backtracking signal thrown by generated PEG parsers when an
	 * ordered-choice alternative fails. One pre-allocated instance makes a
	 * backtracking throw free — no allocation and, crucially, no V8 stack-trace
	 * capture (which every `new ParseError` incurs via `extends Exception`).
	 * Recursive-descent parsers throw tens of these per source line, so eager
	 * stack capture was the dominant parse cost; reusing this token removes it.
	 *
	 * The payload is never read: the public entry rebuilds the surfaced error
	 * from `Parser.maxFailPos`. The `(-2, -2)` span — strictly below the `-1` `maxFailPos` floor — guarantees the entry's
	 * `maxFailPos > e.span.from` check always selects the farthest-failure
	 * rebuild over this token, so it never reaches a `source`-mutating path. MUST
	 * stay immutable — it is shared across every parse, so `source` must remain
	 * null.
	 */
	public static final backtrack: ParseError = new ParseError(new Span(-2, -2), 'backtrack');

	public final span: Span;
	public final expected: Null<String>;

	public final severity: Severity;

	/**
	 * Source string the parser was running over when the error was
	 * thrown. Used by `toString` to render `line:col` instead of raw
	 * byte offsets. The public entry point sets this in its catch
	 * decorator; in-body construction sites leave it null and rely on
	 * the entry's re-decoration. Direct callers (tests) may leave it
	 * null and accept the byte-offset form.
	 *
	 * Assigned in the constructor body rather than at the declaration
	 * site so the implicit `super()` call (extern haxe.Exception
	 * constructor) runs first — Haxe forbids touching `this` before
	 * `super()` in subclasses of an extern with a constructor.
	 */
	public var source: Null<String>;

	public function new(span: Span, message: String, ?expected: String, severity: Severity = Severity.Error) {
		super(message);
		this.span = span;
		this.expected = expected;
		this.severity = severity;
		source = null;
	}

	override public function toString(): String {
		final label: String = severity == Severity.Warning ? 'warning' : 'error';
		final src: Null<String> = source;
		final locus: String = if (src != null) {
			final pos: Position = span.lineCol(src);
			'${pos.line}:${pos.col}';
		} else {
			'$span';
		};
		final base: String = '$label at $locus: $message';
		return expected == null ? base : '$base (expected $expected)';
	}

}
