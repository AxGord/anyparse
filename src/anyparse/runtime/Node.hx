package anyparse.runtime;

/**
 * AST node metadata wrapper used by Tolerant-mode parsers.
 *
 * Wraps a typed `value` with its source `span`, any `errors` attached
 * specifically to this node (as opposed to the overall parse), and a
 * unique `id` that identity-based caches can key on.
 *
 * Fast-mode parsers never allocate `Node` — they return bare `T`
 * directly. The class exists in Phase 1 as part of the stable API
 * surface that generated Tolerant-mode code will emit in later phases.
 */
@:nullSafety(Strict)
final class Node<T> {

	public final value:T;
	public final span:Span;
	public final errors:Array<ParseError>;
	public final id:Int;

	public function new(value:T, span:Span, errors:Array<ParseError>, id:Int) {
		this.value = value;
		this.span = span;
		this.errors = errors;
		this.id = id;
	}
}
