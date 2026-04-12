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
 * Ternary strategy — owns mixfix operator metadata on enum branches.
 *
 * Metadata handled:
 *  - `@:ternary("?", ":", 1)` — ternary (mixfix) operator with the
 *                                given opening operator, middle separator,
 *                                and precedence. Always right-associative
 *                                by construction (both middle and right
 *                                operands parse at minPrec=0).
 *
 * The branch must have exactly three children, all `Ref` back to the
 * same enum: condition (left, from the Pratt loop accumulator), then
 * expression (middle, parsed at minPrec=0), else expression (right,
 * parsed at minPrec=0).
 *
 * The strategy is annotate-only. It writes `ternary.op`, `ternary.sep`,
 * and `ternary.prec` onto the branch `ShapeNode` and returns `null`
 * from `lower`. `Lowering.lowerPrattLoop` detects `ternary.op` branches
 * and merges them into the operator dispatch chain alongside binary
 * `@:infix` branches, sorted by literal length descending (D33).
 *
 * Right-associativity is inherent in the minPrec=0 recursion for both
 * middle and right operands — no explicit `assoc` field is needed.
 * `a ? b : c ? d : e` parses as `Ternary(a, b, Ternary(c, d, e))`
 * because the right operand at prec 0 accepts the nested ternary.
 *
 * The strategy declares no `runsBefore` / `runsAfter` constraints —
 * `Ternary` writes a unique namespace (`ternary.*`) and reads nothing
 * that other strategies produce.
 */
class Ternary implements Strategy {

	public var name(default, null):String = 'Ternary';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':ternary'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':ternary') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':ternary') {
			if (entry.params.length != 3)
				Context.fatalError(
					'@:ternary expects exactly three arguments: "op", "sep", precedence:Int',
					entry.pos
				);
			final opText:String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:ternary first argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			final sepText:String = switch entry.params[1].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:ternary second argument must be a string literal', entry.params[1].pos);
					throw 'unreachable';
			};
			final precValue:Int = switch entry.params[2].expr {
				case EConst(CInt(s)): Std.parseInt(s);
				case _:
					Context.fatalError('@:ternary third argument must be an integer literal', entry.params[2].pos);
					throw 'unreachable';
			};
			node.annotations.set('ternary.op', opText);
			node.annotations.set('ternary.sep', sepText);
			node.annotations.set('ternary.prec', precValue);
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
