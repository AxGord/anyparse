package anyparse.macro.strategy;

#if macro
import haxe.macro.Expr;
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;

/**
 * Skip strategy — cross-cutting whitespace / comment consumption.
 *
 * Phase 2 recognises `@:ws` as "use the active format's `whitespace`
 * field as the skip pattern for every terminal in this grammar". The
 * strategy's annotate pushes that pattern onto `LoweringCtx.skipStack`
 * when it sees the annotation on the root of a rule; Codegen reads the
 * active skip state and emits a `skipWs(ctx)` call immediately before
 * each `Lit`/`Re` emission.
 *
 * There is deliberately no CoreIR primitive for skip — it's purely a
 * codegen concern driven by shared lowering state. A future Phase-3
 * `@:skip("regex")` form will reuse the same slot with a user-provided
 * pattern instead of the format default.
 */
class Skip implements Strategy {

	public var name(default, null):String = 'Skip';
	public var runsAfter(default, null):Array<String> = ['Lit'];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':ws', ':skip'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':ws' || entry.name == ':skip') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':ws') {
			// The active format carries the actual whitespace string; the
			// root rule annotation just records "skip is active".
			node.annotations.set('skip.active', true);
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
