package anyparse.macro;

#if macro
import haxe.macro.Context;
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;

/**
 * Registers the set of strategies active for a macro build, validates
 * their `ownedMeta` declarations for conflicts, topo-sorts them by the
 * `runsAfter` / `runsBefore` dependencies, and runs the pass-2 annotate
 * walk across every shape node in the grammar.
 *
 * The registry does not pick lowering semantics — all strategies in
 * Phase 2 return `null` from `lower()` and let `Lowering` interpret the
 * annotations they wrote. The registry's contract is simply: every
 * strategy that `appliesTo` a node gets a chance to `annotate` it, in a
 * stable deterministic order.
 */
class StrategyRegistry {

	private final strategies:Array<Strategy> = [];
	private var ordered:Array<Strategy> = [];

	public function new() {}

	public function register(s:Strategy):Void {
		strategies.push(s);
	}

	/**
	 * Validate ownership uniqueness and build the topological order.
	 * Call this once after all `register` calls, before `runAnnotate`.
	 */
	public function prepare():Void {
		// Conflict check — each owned meta tag can have only one owner.
		final owners:Map<String, String> = new Map();
		for (s in strategies) for (tag in s.ownedMeta) {
			if (owners.exists(tag)) {
				Context.fatalError('metadata $tag is claimed by both ${owners.get(tag)} and ${s.name}', Context.currentPos());
			}
			owners.set(tag, s.name);
		}
		ordered = topoSort(strategies);
	}

	/**
	 * Walk every node in the ShapeResult and give each registered
	 * strategy a chance to annotate it. Order follows the topological
	 * sort computed in `prepare`.
	 */
	public function runAnnotate(shape:ShapeBuilder.ShapeResult, ctx:LoweringCtx):Void {
		for (s in ordered) for (name => root in shape.rules) walkAnnotate(root, s, ctx);
	}

	private function walkAnnotate(node:ShapeNode, s:Strategy, ctx:LoweringCtx):Void {
		if (s.appliesTo(node)) s.annotate(node, ctx);
		for (child in node.children) walkAnnotate(child, s, ctx);
	}

	/**
	 * Kahn-style topological sort. `runsAfter` entries on strategy A
	 * become edges from B (the predecessor) to A; `runsBefore` entries
	 * become edges from A to B. Any cycle is a registration error.
	 */
	private static function topoSort(list:Array<Strategy>):Array<Strategy> {
		final byName:Map<String, Strategy> = new Map();
		for (s in list) byName.set(s.name, s);

		final incoming:Map<String, Array<String>> = new Map();
		for (s in list) incoming.set(s.name, []);

		inline function addEdge(from:String, to:String):Void {
			if (!byName.exists(from) || !byName.exists(to)) return;
			final deps:Null<Array<String>> = incoming.get(to);
			if (deps != null && deps.indexOf(from) == -1) deps.push(from);
		}

		for (s in list) {
			for (dep in s.runsAfter) addEdge(dep, s.name);
			for (dep in s.runsBefore) addEdge(s.name, dep);
		}

		final result:Array<Strategy> = [];
		final ready:Array<String> = [];
		for (s in list) {
			final deps:Null<Array<String>> = incoming.get(s.name);
			if (deps == null || deps.length == 0) ready.push(s.name);
		}

		while (ready.length > 0) {
			final pick:String = ready.shift();
			final s:Null<Strategy> = byName.get(pick);
			if (s != null) result.push(s);
			for (other in list) {
				final deps:Null<Array<String>> = incoming.get(other.name);
				if (deps == null) continue;
				final idx:Int = deps.indexOf(pick);
				if (idx == -1) continue;
				deps.splice(idx, 1);
				if (deps.length == 0 && ready.indexOf(other.name) == -1 && result.indexOf(other) == -1) {
					ready.push(other.name);
				}
			}
		}

		if (result.length != list.length) {
			Context.fatalError('strategy dependency graph has a cycle', Context.currentPos());
		}
		return result;
	}
}
#end
