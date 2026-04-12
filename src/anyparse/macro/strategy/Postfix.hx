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
 * Postfix strategy — owns postfix operator metadata on enum branches.
 *
 * Metadata handled:
 *  - `@:postfix(".")`        — single-literal postfix operator. The
 *                               branch must have two arguments:
 *                               `operand:SelfType` followed by a `Ref`
 *                               to the parsed suffix value (e.g. a
 *                               field identifier for `.`). After the
 *                               literal is consumed the suffix rule
 *                               is called once and the ctor is built
 *                               as `Ctor(left, suffix)`.
 *  - `@:postfix("[", "]")`   — pair-literal postfix operator wrapping
 *                               a recursive expression parse. The
 *                               branch must have two arguments:
 *                               `operand:SelfType` followed by the
 *                               inner `Ref` (typically `SelfType`
 *                               again for `[expr]`). After the open
 *                               literal is consumed the inner rule
 *                               runs, then the close literal is
 *                               expected. Ctor: `Ctor(left, inner)`.
 *  - `@:postfix("(", ")")`   — pair-literal postfix with NO inner
 *                               parse (no-arg call `f()`). The branch
 *                               must have exactly one argument:
 *                               `operand:SelfType`. After the open
 *                               literal is consumed the close literal
 *                               is expected immediately. Ctor:
 *                               `Ctor(left)`. An arg-list variant
 *                               `Call(operand, args:Array<T>)` is
 *                               deferred to a future slice (δ2) — it
 *                               requires shared struct-like emission
 *                               inside enum-branch postfix shapes.
 *
 * All three forms share one runtime trait: they are left-recursive
 * postfix operators. The generated parser applies them through a
 * loop sitting inside the atom wrapper function — `parseXxxAtom`
 * calls `parseXxxAtomCore` for the underlying atom, then repeatedly
 * peeks each postfix operator on the accumulated `left` value until
 * none match. Postfix therefore binds tighter than any binary infix
 * (the Pratt loop only sees the postfix-extended atom) and also
 * tighter than unary prefix (prefix's operand recursion targets the
 * atom wrapper, so `-a.b` parses as `Neg(FieldAccess(a, b))`).
 *
 * The strategy is annotate-only. It writes `postfix.op` (the single
 * literal, or the open literal for the pair form) and, for the pair
 * form only, `postfix.close` (the close literal) onto the branch
 * `ShapeNode`. `lower()` returns `null`. `Lowering.lowerPostfixLoop`
 * reads both keys at macro time, validates the branch shape against
 * the three supported variants, and emits the dispatch chain.
 *
 * Shape validation happens in `Lowering`, not here, because this
 * strategy sees each branch in isolation and does not know the
 * enclosing enum's type path — the "operand must reference the same
 * enum" check needs that context. Same split as Prefix.
 *
 * Scope of the Phase 3 postfix slice δ1:
 *  - Field access, index access, call-no-args. Call-with-args is δ2.
 *  - Symbolic operators only. Word-like postfix ops (hypothetical
 *    `as`, `is`) are rejected at compile time in `Lowering` until a
 *    real grammar needs them.
 *  - No precedence value — all postfix operators share one loop
 *    layer and fold left-recursively by construction.
 *
 * The strategy declares no `runsBefore` / `runsAfter` constraints —
 * Postfix writes a unique namespace (`postfix.*`) and reads nothing
 * that other strategies produce.
 */
class Postfix implements Strategy {

	public var name(default, null):String = 'Postfix';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':postfix'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':postfix') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':postfix') {
			if (entry.params.length < 1 || entry.params.length > 2) {
				Context.fatalError(
					'@:postfix expects one string argument (single literal) or two string arguments (open, close)',
					entry.pos
				);
			}
			final opText:String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:postfix first argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			node.annotations.set('postfix.op', opText);
			if (entry.params.length == 2) {
				final closeText:String = switch entry.params[1].expr {
					case EConst(CString(s, _)): s;
					case _:
						Context.fatalError('@:postfix second argument must be a string literal', entry.params[1].pos);
						throw 'unreachable';
				};
				node.annotations.set('postfix.close', closeText);
			}
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
