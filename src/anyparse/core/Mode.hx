package anyparse.core;

#if macro
/**
 * Compilation mode for a generated parser. Every `@:peg` grammar can be
 * instantiated in one or both modes via `@:generate([Fast, Tolerant])`.
 *
 * - `Fast`     — throws on first error, returns bare `T`, no AST
 *                metadata wrapping. Targets hot paths and batch parsing.
 * - `Tolerant` — returns `ParseResult<Node<T>>`, collects errors,
 *                recovers via `@:commit`/`@:recover`. Targets IDEs,
 *                linters, and any user-facing diagnostics.
 *
 * Phase 1 declares the enum but does not yet wire any parser variant
 * to it — the macro that consumes it lands in Phase 2.
 */
enum abstract Mode(Int) {
	final Fast = 0;
	final Tolerant = 1;
}
#end
