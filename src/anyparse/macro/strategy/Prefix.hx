package anyparse.macro.strategy;

#if macro
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;
import anyparse.macro.AnnotationKeys;
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;

/**
 * Prefix strategy — owns unary-prefix operator metadata on enum branches.
 *
 * `@:prefix("-")` — unary prefix operator with the given literal. The branch must
 * have exactly one argument, a `Ref` back to the same enum, which becomes the
 * operand. Single-argument form only: no precedence value, no associativity. All
 * prefix operators bind tighter than any binary infix because the lowering routes
 * them through the atom function — the operand is parsed as a single atom
 * (possibly itself a nested prefix), and the surrounding Pratt loop picks up
 * binary operators around the result, so `-x * 2` is `Mul(Neg(x), 2)` without a
 * per-op precedence table.
 *
 * Annotate-only: writes `prefix.op` onto the branch `ShapeNode` and returns `null`
 * from `lower`. `ParseDispatchLowering.branchShape` classifies a branch carrying
 * `prefix.op` BEFORE the single-`Ref` `KwRef` shape it also matches, because that
 * lowering would emit an unguarded left-recursive call that consumes nothing.
 * Symbolic operators only (`-`, `!`, `~`); a word-like prefix op is rejected at
 * compile time until a real grammar needs one, and a distinct-precedence prefix
 * would extend `@:prefix` with a second int argument the same way `@:infix` takes
 * one. No `runsBefore` / `runsAfter`: `prefix.*` is a unique namespace and the
 * strategy reads nothing another one produces.
 */
class Prefix implements Strategy {

	public var name(default, null): String = 'Prefix';
	public var runsAfter(default, null): Array<String> = [];
	public var runsBefore(default, null): Array<String> = [];
	public var ownedMeta(default, null): Array<String> = [':prefix'];
	public var runtimeContribution(default, null): RuntimeContrib = { ctxFields: [], helpers: [], cacheKeyContributors: [] };

	public function new() {}

	public function appliesTo(node: ShapeNode): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		return meta != null && meta.exists(entry -> entry.name == ':prefix');
	}

	public function annotate(node: ShapeNode, ctx: LoweringCtx): Void {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':prefix') {
			if (entry.params.length != 1) {
				Context.fatalError('@:prefix expects exactly one string argument: "op"', entry.pos);
			}
			final opText: String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:prefix argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			node.annotations[AnnotationKeys.PREFIX_OP] = opText;
		}
	}

	public function lower(node: ShapeNode, ctx: LoweringCtx): Null<CoreIR> {
		return null;
	}

}
#end
