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
 * Pratt strategy — owns operator-precedence metadata on enum branches.
 *
 * Metadata handled:
 *  - `@:infix("+", 6)`               — binary infix operator with the
 *                                      given literal and precedence.
 *                                      Defaults to left-associative.
 *  - `@:infix("=", 1, "Right")`      — same, explicitly right-associative.
 *                                      The optional third argument must
 *                                      be the string literal `"Left"`
 *                                      or `"Right"`. Omitting it means
 *                                      left-associative.
 *
 * Higher precedence binds tighter. Associativity controls how chains
 * of same-precedence operators fold: left-associative yields
 * `(a + b) + c`, right-associative yields `a = (b = c)`.
 *
 * The strategy is annotate-only. It writes `pratt.op`, `pratt.prec`,
 * and `pratt.assoc` onto the branch `ShapeNode` and returns `null`
 * from `lower`. `Lowering` detects the presence of any `pratt.prec`
 * annotation on an enum's branches and splits the classifier into
 * atoms (all non-Pratt branches) and operators (Pratt branches),
 * generating two rule functions for a single Pratt-enabled enum:
 *
 *  - `parseXxxAtom(ctx)` — contains only non-Pratt branches routed
 *    through the existing Cases 1–4 of `lowerEnumBranch`.
 *  - `parseXxx(ctx, ?minPrec = 0)` — the precedence-climbing loop
 *    that calls `parseXxxAtom` for the left operand, then tries each
 *    Pratt operator in a longest-first dispatch chain. `Lowering`
 *    sorts the operator branches by literal length descending before
 *    emitting the chain, so `<=` is attempted before `<` regardless
 *    of how the grammar author orders the branches — declaration
 *    order is a readability choice, not a correctness constraint.
 *
 * Scope of the Phase 3 Pratt slice:
 *  - Binary infix only. No prefix, postfix, calls, field access,
 *    index access, or `new`.
 *  - Both left- and right-associative. Right-assoc shipped with
 *    the assignment slice (`=` / `+=` / `-=`).
 *  - Operator literals are symbolic — word-boundary checks for
 *    word-like operators (e.g. `instanceof`) come when the first
 *    grammar needs them.
 *  - A single shared `parseXxx` entry point; operator recognition
 *    is inlined into the loop body.
 *
 * The strategy declares no `runsBefore` / `runsAfter` constraints —
 * Pratt writes a unique namespace (`pratt.*`) and reads nothing that
 * other strategies produce, so its ordering relative to Lit/Re/Kw is
 * irrelevant.
 */
class Pratt implements Strategy {

	public var name(default, null):String = 'Pratt';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':infix'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':infix') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':infix') {
			if (entry.params.length < 2 || entry.params.length > 3) {
				Context.fatalError(
					'@:infix expects two or three arguments: "op", precedence:Int, and optional associativity ("Left"/"Right")',
					entry.pos
				);
			}
			final opText:String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:infix first argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			final precValue:Int = switch entry.params[1].expr {
				case EConst(CInt(s)): Std.parseInt(s);
				case _:
					Context.fatalError('@:infix second argument must be an integer literal', entry.params[1].pos);
					throw 'unreachable';
			};
			final assocValue:String = if (entry.params.length == 3) {
				switch entry.params[2].expr {
					case EConst(CString(s, _)) if (s == 'Left' || s == 'Right'): s;
					case _:
						Context.fatalError(
							'@:infix third argument must be the string literal "Left" or "Right"',
							entry.params[2].pos
						);
						throw 'unreachable';
				}
			} else 'Left';
			node.annotations.set('pratt.op', opText);
			node.annotations.set('pratt.prec', precValue);
			node.annotations.set('pratt.assoc', assocValue);
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
