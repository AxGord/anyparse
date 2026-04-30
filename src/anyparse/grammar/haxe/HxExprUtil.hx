package anyparse.grammar.haxe;

/**
 * Plugin-side AST predicates over `HxExpr` consumed by macro-neutral
 * runtime adapters on `WriteOptions`.
 *
 * Lives in the grammar package so macro core stays free of any
 * `HxExpr`-specific logic. `HaxeFormat.defaultWriteOptions` wires the
 * static methods here into the adapter fields the macro emits calls
 * for (e.g. `endsWithCloseBrace` for `@:fmt(trailOptShapeGate)`).
 *
 * All predicates take `Dynamic` because the same adapter is invoked
 * from both Plain-mode writers (which pass `HxExpr` enum values) and
 * Trivia-mode writers (which pass `Trivial<HxExprT>` struct wrappers
 * around the paired enum). Constructor identification goes through
 * `Type.enumConstructor` rather than direct pattern matching so the
 * switch arms match against both the Plain `HxExpr` and the synthesised
 * `HxExprT` enum — they share constructor names but are distinct types
 * at runtime, so a literal `case BlockExpr(_)` would only fire on one.
 */
@:nullSafety(Strict)
final class HxExprUtil {

	/**
	 * True iff `raw` is a control-flow expression whose `}` may serve
	 * as a statement terminator on the rhs of `var x = …`. Drives the
	 * writer-side gate for `@:trailOpt(';')` on `var` / `final`
	 * declarations.
	 *
	 * **Drop `;`** (gate true):
	 *  - `SwitchExpr` / `SwitchExprBare` — `var x = switch (y) { … }`
	 *    (haxe-formatter `issue_119_expression_case`,
	 *    `issue_254_case_colon{,_next,_keep}`).
	 *  - `FnExpr` with `body=BlockBody` — `var f = function() { … }`
	 *    (haxe-formatter `inline_calls`). Bare-expression bodies
	 *    (`function(x) trace(x)`) keep the `;`.
	 *  - `TryExpr` whose last catch clause's body is itself in this set
	 *    (recursive). Bare-catch `try foo() catch (_) null` keeps the
	 *    `;` because `null` is not in the set.
	 *
	 * **Keep `;`** (gate false — explicit non-set):
	 *  - `BlockExpr` — `var x = { 1; 2; };` is a block-as-expression
	 *    value, not a statement.
	 *  - `ObjectLit` — `var o = {a: 1};` (haxe-formatter
	 *    `issue_101_comment_in_object_literal`, `space_in_anonymous_object`).
	 *  - `IfExpr` — `var x = if (a) { 1; } else { 2; };` (haxe-formatter
	 *    `issue_42_if_after_assign_with_blocks_on_same_line`).
	 *  - All prefix / infix / postfix wrappers and everything else.
	 *
	 * The discrimination follows haxe-formatter's empirical rule from
	 * the corpus: only "control-flow expressions that visually look
	 * like statements" (switch / try / function-block) drop the
	 * trailing `;`; literal-shaped expressions (object / block / array
	 * / paren / if-as-expression) keep it.
	 */
	public static function endsWithCloseBrace(raw:Null<Dynamic>):Bool {
		final e:Null<Dynamic> = unwrap(raw);
		if (e == null) return false;
		final ctor:Null<String> = Type.enumConstructor(e);
		if (ctor == null) return false;
		return switch ctor {
			case 'SwitchExpr', 'SwitchExprBare': true;
			case 'FnExpr':
				final fn:Null<Dynamic> = Type.enumParameters(e)[0];
				if (fn == null) false;
				else {
					final body:Null<Dynamic> = unwrap(Reflect.field(fn, 'body'));
					body != null && Type.enumConstructor(body) == 'BlockBody';
				}
			case 'TryExpr':
				final stmt:Null<Dynamic> = Type.enumParameters(e)[0];
				if (stmt == null) false;
				else {
					final catches:Null<Array<Dynamic>> = Reflect.field(stmt, 'catches');
					if (catches == null || catches.length == 0) false;
					else {
						final last:Null<Dynamic> = catches[catches.length - 1];
						if (last == null) false;
						else {
							final lastInner:Dynamic = Reflect.hasField(last, 'node') ? last.node : last;
							final body:Null<Dynamic> = Reflect.field(lastInner, 'body');
							body != null && endsWithCloseBrace(body);
						}
					}
				}
			case _: false;
		};
	}

	/**
	 * Returns the inner enum value for `raw`. Handles three shapes:
	 *  - `null` → `null`
	 *  - direct enum value (Plain-mode AST node) → `raw` unchanged
	 *  - `Trivial<T>` struct wrapper (Trivia-mode AST node) → `raw.node`
	 */
	private static inline function unwrap(raw:Null<Dynamic>):Null<Dynamic> {
		if (raw == null) return null;
		return Type.getEnum(raw) != null ? raw : Reflect.field(raw, 'node');
	}
}
