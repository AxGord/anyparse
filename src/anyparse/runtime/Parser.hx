package anyparse.runtime;

/**
 * Runtime parser context threaded through generated parsers as the
 * first argument to every helper. Owns everything that
 * is mutable during a parse — input, position, error accumulator,
 * cache, indent stack, named captures, cancellation callback.
 *
 * Thread safety by construction: there is zero global mutable state in
 * the runtime. Concurrent parses use independent `Parser` instances and
 * never touch each other's fields.
 *
 * Phase 1 uses only `input` and `pos`. `errors`, `cache`, `indentStack`,
 * `captures`, and `cancelled` are declared so that generated code in
 * Phase 2 and beyond has a stable target; their behaviour is stubbed
 * (empty collections, `NoOpCache`, always-false cancellation) until the
 * corresponding strategies land.
 */
@:nullSafety(Strict)
final class Parser {

	public final input:Input;
	public final errors:Array<ParseError> = [];
	public final indentStack:Array<Int> = [];
	public final captures:Map<String, String> = [];

	public var pos:Int = 0;
	public var cache:ParseCache = NoOpCache.instance;
	public var cancelled:() -> Bool = alwaysFalse;

	/**
	 * Trivia carry-over slot (slice ω₆b). Generated Trivia-mode parsers
	 * stash a leading run captured between an `@:optional @:kw` commit
	 * point and its sub-rule call here; the next `collectTrivia` drains
	 * it as a prefix. Null outside Trivia-mode builds and between drains.
	 */
	public var pendingTrivia:Null<{blankBefore:Bool, leadingComments:Array<String>}> = null;

	public function new(input:Input) {
		this.input = input;
	}

	private static function alwaysFalse():Bool {
		return false;
	}
}
