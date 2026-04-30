package anyparse.grammar.haxe;

/**
 * ω-fmt-prewrite-hook (Haxe plugin) — shape-conditional `HxType`
 * rewrites consumed by the writer's `@:fmt(preWrite('...'))` hook.
 *
 * Each function takes the full enum value and returns either `null`
 * (no rewrite, writer falls through to the default emission) or a
 * substitute `HxType` value the writer re-dispatches through its own
 * `writeHxType`. Routing through the same writer means any ctor in the
 * substitute participates in its own `@:fmt(...)` knobs naturally —
 * the rewrite is structural, not output-shaped.
 *
 * Located in the Haxe format plugin per CLAUDE.md /
 * `feedback_grammar_vs_plugin_transform.md`: source→target
 * format-specific transformations live in plugin code, not in the
 * macro core or runtime helpers.
 */
@:nullSafety(Strict)
final class HaxeTypeRewrites {

	/**
	 * Old-style curried-chain detection for `(Inner) -> R` shapes.
	 *
	 * `(Int->Int)->Int` parses as
	 * `ArrowFn([Positional(Arrow(Int,Int))], Int)` — the parser
	 * canonically routes any `(...)->R` shape through `ArrowFn`. The
	 * writer would then emit ` -> ` per `@:fmt(functionTypeHaxe4)`
	 * (default `Around`), giving `(Int->Int) -> Int`. haxe-formatter's
	 * canonical form is fully tight `(Int->Int)->Int` because the outer
	 * arrow is grammatically the same `T -> X` curry — the parens are
	 * just precedence grouping over the LHS sub-arrow, not a
	 * function-type arglist.
	 *
	 * Detection rule: `args=[Positional(t)]` with `t` itself an `Arrow`
	 * is the unambiguous old-style group. No idiomatic Haxe author
	 * writes `(Int->Bool) -> X` to mean "function taking one
	 * `Int->Bool` arg"; they write `Int->Bool->X` and add parens only
	 * for explicit precedence. Returning
	 * `Arrow(Parens(t_norm), ret_norm)` re-dispatches through
	 * `HxType.Arrow`'s `@:fmt(tight)` writer, dropping all spaces.
	 *
	 * Returns null for every other `HxType` shape (including the
	 * canonical new-style cases `(Int) -> Int`, `(name:String) -> Void`,
	 * `(Int, String) -> Bool`, `() -> Void` — those keep their default
	 * `ArrowFn` writer, around-spaced per `functionTypeHaxe4`).
	 */
	public static function arrowFnOldStyleRewrite(value:HxType):Null<HxType> {
		return switch value {
			case ArrowFn({args: [Positional(inner = Arrow(_, _))], ret: ret}):
				Arrow(Parens(inner), ret);
			case _: null;
		}
	}
}
