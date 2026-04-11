package anyparse.macro.strategy;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;

/**
 * Kw strategy — owns keyword literals with word-boundary semantics.
 *
 * Metadata handled:
 *  - `@:kw("word")` — match literal "word", then assert that the next
 *                     input character is not a word character
 *                     (`[A-Za-z0-9_]`). Prevents the common bug where
 *                     a literal keyword match succeeds on the prefix of
 *                     a longer identifier (`class` matching inside
 *                     `classify`).
 *
 * Scope of the Phase 3 skeleton:
 *  - Single-argument form only. Multi-literal `@:kw("true","false")`
 *    (mirror of `Lit`'s multi-literal case) is deferred; only one
 *    keyword per meta is accepted and enforced with `fatalError`.
 *  - Phase 2 annotate-only pattern: `lower()` returns `null`, the
 *    strategy's entire contribution is to populate the `kw.leadText`
 *    annotation slot. `Lowering` reads that slot wherever it already
 *    reads `lit.leadText` and picks `expectKw` instead of `expectLit`.
 *
 * The strategy declares `runsBefore: ['Lit']` even though `@:kw` and
 * `@:lit`/`@:lead` are owned-disjoint — this makes the run order
 * deterministic for a reader following the pipeline and avoids a silent
 * reordering if the topological sort gets a tie.
 */
class Kw implements Strategy {

	public var name(default, null):String = 'Kw';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = ['Lit'];
	public var ownedMeta(default, null):Array<String> = [':kw'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':kw') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':kw') {
			if (entry.params.length != 1) {
				Context.fatalError('@:kw expects exactly one string argument (multi-literal kw is not implemented yet)', entry.pos);
			}
			final text:String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:kw argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			node.annotations.set('kw.leadText', text);
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
