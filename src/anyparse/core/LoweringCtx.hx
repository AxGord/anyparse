package anyparse.core;

#if macro
import anyparse.format.Format;

/**
 * Context threaded through the lowering pass. Carries cross-cutting
 * state that several strategies need to read or push/pop:
 *
 * - `skipStack`    — stack of active cross-cutting skip patterns
 *                    (whitespace, comments). `Skip` pushes on enter,
 *                    pops on leave; base lowering reads the top of the
 *                    stack before every terminal.
 * - `captures`     — names of active capture slots for the current
 *                    scope, used by `Capture`/`Backref`.
 * - `indentMode`   — active indent policy string for the current
 *                    scope, consulted by `Indent`.
 * - `activeFormat` — format currently in effect; determines literal
 *                    vocabulary for `Lit` lowerings.
 * - `mode`         — Fast vs Tolerant; drives whether span tracking,
 *                    error recovery and cache lookups are emitted.
 * - `trivia`       — when true, the macro synthesizes paired `*T` AST
 *                    types (struct/enum) for every grammar node that
 *                    transitively contains a `@:trivia`-annotated Star.
 *                    The generated parser emits `Trivial<T>` wrappers
 *                    for those Star elements with `collectTrivia(ctx)`
 *                    calls between them. Default `false` — existing
 *                    parsers keep their bare AST shape.
 *
 * Strategies are free to mutate the fields they own, but only while
 * they are in their own `lower` call — the macro framework saves and
 * restores the relevant state around recursive descents.
 */
class LoweringCtx {

	public final skipStack:Array<CoreIR> = [];
	public final captures:Array<String> = [];

	public var indentMode:Null<String> = null;
	public var activeFormat:Null<Format> = null;
	public var mode:Mode = Mode.Tolerant;
	public var trivia:Bool = false;

	public function new() {}
}
#end
