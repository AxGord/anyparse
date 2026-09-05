package anyparse.macro;

#if macro
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import anyparse.macro.ParseDispatchLowering.*;

/**
 * Pass 3 — the span-argument instrumentation of an emitted rule body.
 *
 * One question: when a build asks for spans (`ctx.spans`), WHERE in the
 * body `Lowering` has just emitted does a `new Span(_start, ctx.pos)`
 * argument have to be appended? The answer is a single `ExprTools.map`
 * over the finished body plus the three-shape rule for the ctor build
 * expression it lands on (`ECall` grows an argument, a bare ctor
 * reference becomes a one-argument call, a Seq struct literal is left
 * alone).
 *
 * Split out of `Lowering` because it consumes a different KIND of
 * evidence from everything around it: not the shape tree, not the format
 * and not the build's `LoweringCtx`, but the emitted `Expr` itself. Every
 * member is static and `Lowering` reaches them unqualified through
 * `import anyparse.macro.SpanArgLowering.*;` plus a class-level
 * `@:access`, so the move rewrote no call site.
 */
@:access(anyparse.macro.ParseDispatchLowering)
final class SpanArgLowering {

	/**
	 * ω-span-mode-inast — when `ctx.spans=true`, walk the rule body Expr
	 * and append a `Span(_start, ctx.pos)` positional arg to every ctor
	 * build site so the constructed paired enum value carries its own
	 * span in-AST.
	 *
	 * Prepends `final _start:Int = ctx.pos;` at the body top so every
	 * downstream ctor call sees a per-rule entry position. Pratt and
	 * Postfix loops reuse the same `_start` for every iteration — the
	 * span of an iteration's freshly-built composite ctor covers (rule
	 * entry, end of the right operand), which is the correct outer
	 * coverage (`a + b + c` produces `Add(Add(a,b), c)` whose outer
	 * `Add`'s span covers the whole expression).
	 *
	 * Ctor build shapes the walker rewrites:
	 *  - `return $ctorRef;` where `$ctorRef` is the EField chain to a
	 *    paired ctor (zero-arg branches, Case 0/1). Walker wraps the
	 *    reference into `ECall(ctorRef, [spanArg])` so the paired ctor's
	 *    single `_span` arg is supplied.
	 *  - `return ECall($ctorRef, [args])` — every other ctor return
	 *    (Cases 2/3/4/5 + multi-lit dispatch + prefix). Walker appends
	 *    the span arg to the args list.
	 *  - `left = ECall($ctorRef, [args])` — Pratt/Postfix iteration
	 *    composites. Walker appends the span arg.
	 *
	 * Seq struct returns (`return $structLit`) are left untouched —
	 * `EObjectDecl` is structurally distinct and Seq paired typedefs
	 * carry no `_span` field (their parent enum value's span covers
	 * them in the consumer's QueryNode model).
	 *
	 * `return left;` at the tail of Pratt/Postfix loops is excluded by
	 * the `isBareLeft` guard — `left` is already a paired value built
	 * inside the loop iterations; re-wrapping it would be wrong.
	 *
	 * Failed `tryBranch` attempts throw `ParseError` before reaching
	 * the ctor build site, so no incorrect span lands on a rolled-back
	 * branch — `tryBranch`'s own `ctx.pos = _savedPos` rollback handles
	 * recovery.
	 */
	private static function instrumentSpans(body: Expr): Expr {
		final transformed: Expr = transformForSpans(body);
		return macro {
			final _start: Int = ctx.pos;
			$transformed;
		};
	}

	private static function transformForSpans(e: Expr): Expr {
		return switch e.expr {
			case EReturn(returnExpr) if (returnExpr != null && !isBareLeft(returnExpr)):
				final appended: Expr = appendSpanArg(returnExpr);
				macro return $appended;
			case EBinop(OpAssign, lhs, rhs) if (isBareLeft(lhs)):
				final appended: Expr = appendSpanArg(rhs);
				macro left = $appended;
			case _: ExprTools.map(e, transformForSpans);
		};
	}

	/**
	 * Append `new Span(_start, ctx.pos)` as a trailing positional arg
	 * to a ctor build expression. Three shapes:
	 *
	 *  - `ECall(fn, args)` — typical ctor call. Args grow by one. Note:
	 *    this matches BOTH paired ctor calls (the intended case) AND
	 *    helper invocations that wrap the return value, but no helper
	 *    is ever a top-level `return`/`left=` rhs in Lowering's output
	 *    — the only top-level shapes for those positions are ctor refs/
	 *    calls and Seq struct literals.
	 *  - `EField` / `EConst(CIdent)` — bare ctor reference (Case 0/1
	 *    paths `return $ctorRef;`). Wrap into a single-arg call so the
	 *    paired ctor's `_span` arg is supplied.
	 *  - Anything else (EObjectDecl from Seq, the rare untouched form)
	 *    — pass through unchanged.
	 */
	private static function appendSpanArg(e: Expr): Expr {
		final spanArg: Expr = macro new anyparse.runtime.Span(_start, ctx.pos);
		return switch e.expr {
			case ECall(fn, args):
				{ expr: ECall(fn, args.concat([spanArg])), pos: e.pos };
			case EField(_, _), EConst(CIdent(_)):
				{ expr: ECall(e, [spanArg]), pos: e.pos };
			case _: e;
		};
	}

}
#end
