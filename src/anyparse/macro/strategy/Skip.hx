package anyparse.macro.strategy;

#if macro
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;
import anyparse.macro.AnnotationKeys;
import haxe.macro.Expr;

using Lambda;

/**
 * Skip strategy — cross-cutting whitespace / comment consumption, annotate-only.
 *
 * `@:ws` on a rule root marks it `skip.active`, which records intent and is read
 * by nothing yet: the generated `skipWs(ctx)` (`Codegen.skipWsField` — spaces,
 * tabs, LF, CR, the BOM, plus the format's comment delimiters) is emitted before
 * every terminal by the lowering whether or not the tag is present, and the
 * format's `whitespace` field is not consulted. `LoweringCtx.skipStack` is
 * declared for a future scoped skip and is never pushed; a `@:skip("regex")` form
 * with a user-provided pattern is owned but not read. There is deliberately no
 * CoreIR primitive for skip — it is a codegen concern.
 */
class Skip implements Strategy {

	public var name(default, null): String = 'Skip';
	public var runsAfter(default, null): Array<String> = ['Lit'];
	public var runsBefore(default, null): Array<String> = [];
	public var ownedMeta(default, null): Array<String> = [':ws', ':skip'];
	public var runtimeContribution(default, null): RuntimeContrib = { ctxFields: [], helpers: [], cacheKeyContributors: [] };

	public function new() {}

	public function appliesTo(node: ShapeNode): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		return meta != null && meta.exists(entry -> entry.name == ':ws' || entry.name == ':skip');
	}

	public function annotate(node: ShapeNode, ctx: LoweringCtx): Void {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':ws') {
			// The active format carries the actual whitespace string; the
			// root rule annotation just records "skip is active".
			node.annotations['skip.active'] = true;
		}
	}

	public function lower(node: ShapeNode, ctx: LoweringCtx): Null<CoreIR> {
		return null;
	}

}
#end
