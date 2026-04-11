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
 * Prefix strategy — owns unary-prefix operator metadata on enum branches.
 *
 * Metadata handled:
 *  - `@:prefix("-")` — unary prefix operator with the given literal. The
 *                      branch must have exactly one argument, a `Ref`
 *                      back to the same enum, which becomes the operand.
 *
 * Single-argument form only: no precedence value, no associativity. All
 * prefix operators bind tighter than any binary infix because `Lowering`
 * routes them through the atom function — the operand is parsed as a
 * single atom (possibly itself a nested prefix), and the surrounding
 * Pratt loop picks up binary operators around the result. This gives
 * `-x * 2` the correct `Mul(Neg(x), 2)` shape without any per-op
 * precedence table.
 *
 * The strategy is annotate-only. It writes `prefix.op` onto the branch
 * `ShapeNode` and returns `null` from `lower`. `Lowering.lowerEnumBranch`
 * detects `prefix.op` via a new classifier case that runs before the
 * existing single-`Ref` shape (Case 3), because a prefix branch
 * structurally matches Case 3's shape test (single `Ref` child, no
 * `@:lit`) and would otherwise emit a Case-3 body that recurses into
 * the whole-expression rule and loops forever.
 *
 * Scope of the Phase 3 prefix slice:
 *  - Symbolic operators only (`-`, `!`, `~`). Word-like prefix ops
 *    (hypothetical `not`, `typeof`) are rejected at compile time in
 *    `Lowering` until a real grammar needs them.
 *  - No precedence parameter. If a future grammar needs prefix/prefix
 *    interaction with distinct precedences, extend `@:prefix` to take
 *    a second int argument and thread it through the recursion target
 *    in the Lowering classifier case — the same additive pattern
 *    `@:infix` uses.
 *  - Prefix branches are expected to sit in a Pratt-enabled or plain
 *    atom enum. The recursion target (atom function for Pratt enums,
 *    the single function for plain enums) is passed through
 *    `lowerEnum` → `tryBranch` → `lowerEnumBranch` as `recurseFnName`.
 *
 * The strategy declares no `runsBefore` / `runsAfter` constraints —
 * `Prefix` writes a unique namespace (`prefix.*`) and reads nothing
 * that other strategies produce, so its ordering relative to
 * Lit/Re/Kw/Pratt is irrelevant.
 */
class Prefix implements Strategy {

	public var name(default, null):String = 'Prefix';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':prefix'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':prefix') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':prefix') {
			if (entry.params.length != 1) {
				Context.fatalError('@:prefix expects exactly one string argument: "op"', entry.pos);
			}
			final opText:String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:prefix argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			node.annotations.set('prefix.op', opText);
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
