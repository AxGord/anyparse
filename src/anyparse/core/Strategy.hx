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
 * Strategies never emit `haxe.macro.Expr` directly. They work through
 * CoreIR; codegen (pass 4 of the macro pipeline) turns CoreIR into
 * concrete expressions. A strategy that calls `macro ...` inline is
 * wrong — it should either emit a plain CoreIR subtree or, as a last
 * resort, a `Host` node wrapping the imperative code.
 *
 * See `docs/strategies.md` for the full design discussion, the list of
 * planned strategies, and the registration rules the framework enforces.
 */
interface Strategy {
	var name(default, null):String;
	var runsAfter(default, null):Array<String>;
	var runsBefore(default, null):Array<String>;
	var ownedMeta(default, null):Array<String>;
	var runtimeContribution(default, null):RuntimeContrib;

	function appliesTo(node:ShapeNode):Bool;

	function annotate(node:ShapeNode, ctx:LoweringCtx):Void;

	function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR>;
}
#end
