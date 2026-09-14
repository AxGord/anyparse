package anyparse.core;

#if macro
import anyparse.core.ShapeTree;

/**
 * Strategy plugin contract. A strategy is a Haxe class that knows how
 * to turn a piece of annotated grammar into CoreIR. Every strategy
 * owns a set of metadata tags (`ownedMeta`), declares its dependencies
 * on other strategies (`runsAfter` / `runsBefore`), annotates
 * `ShapeNode`s with namespaced slots (`annotate`), and optionally
 * lowers them into CoreIR (`lower`).
 *
 * Strategies never emit `haxe.macro.Expr`: their contribution is the
 * slots `annotate` writes and, for one that needs its own shape, a
 * CoreIR subtree from `lower`; as shipped every strategy returns `null`
 * and `Lowering` emits the parser expression from the slots directly
 * (`docs/architecture.md` § "Five-pass macro pipeline"). A strategy
 * that calls `macro ...` inline is wrong.
 *
 * See `docs/strategies.md` for the full design discussion, the strategy
 * table, and the registration rules the framework enforces.
 */
interface Strategy {

	/**
	 * A short, stable name. Used in dependency declarations and error messages.
	 */
	var name(default, null): String;

	/**
	 * Names of strategies that must have annotated before this one runs.
	 */
	var runsAfter(default, null): Array<String>;

	/**
	 * Names of strategies that must run after this one.
	 */
	var runsBefore(default, null): Array<String>;

	/**
	 * Which metadata tags this strategy exclusively owns. Two owners of one tag are a registration error.
	 */
	var ownedMeta(default, null): Array<String>;

	/**
	 * What the strategy needs at runtime — context fields, helper methods, cache-key contributions
	 * (`RuntimeContrib`). A strategy with no runtime state declares empty arrays.
	 */
	var runtimeContribution(default, null): RuntimeContrib;

	/**
	 * True when this strategy has something to say about the given shape node.
	 */
	function appliesTo(node: ShapeNode): Bool;

	/**
	 * Annotate the shape node with this strategy's namespaced slots (pass 2). No lowering yet.
	 */
	function annotate(node: ShapeNode, ctx: LoweringCtx): Void;

	/**
	 * Lower the shape node to CoreIR (pass 3), or return `null` to let base lowering handle it —
	 * which every shipped strategy does; `Lowering` reads the slots `annotate` wrote.
	 */
	function lower(node: ShapeNode, ctx: LoweringCtx): Null<CoreIR>;

}
#end
