package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <fn-body> [#elseif ...] [#else <fn-body>] #end` region that occupies
 * a function's ENTIRE body slot. The enclosing `HxFnBody.CondBody` ctor consumes the `#if`
 * keyword and the trailing `#end`; this typedef covers the content between them:
 *
 * ```haxe
 * public static function parse(text:String):Dynamic
 *     #if (!haxeJSON && flash11); #else {
 *         return haxe.format.JsonParser.parse(text);
 *     } #end
 *
 * @:op(~A) private static inline function complement(a:Int32):Int32
 *     #if lua return lua.Boot.clampInt32(~a); #else return clamp(~a); #end
 * ```
 *
 * Both shapes are ONE `#if` straddling the whole body slot, and the two branches may
 * disagree about which `HxFnBody` form the body takes (`;` `NoBody` vs `{ ... }` `BlockBody`
 * above), so each branch is a single `HxFnBody` Ref: every body form the plain slot supports,
 * including a nested `#if` (`CondBody` is itself an `HxFnBody`). A Ref and not a Star (the
 * `HxConditionalStmt` shape) because a function has exactly ONE body per compilation
 * variant; a Star would accept `#if a { } { } #end` with no terminator other than the `#end`
 * itself — the `HxConditionalExpr` reasoning. Not `HxCondSpliceRaw` (the `{raw, tail}`
 * idiom) because the region is BALANCED — each branch is a complete body — and the splice
 * idiom would throw away the body AST (and `SymbolIndex`'s view of it) for no gain.
 *
 * Scope discipline: this typedef is referenced ONLY from `HxFnBody.CondBody`, which sits one
 * slot AHEAD of `ExprBody` in that enum. Every whole-body `#if` region whose branches are
 * complete bodies reaches here, the single-EXPRESSION branches included; regions whose
 * sub-parse fails — a dangling `else`, half a ternary — fail-rewind past this ctor into the
 * expression-scope splice. See the `HxFnBody.CondBody` doc for the member-swallow that
 * forced the order, and for the one shape class the order gives up.
 *
 * Field flags mirror `HxConditionalExpr`: `@:fmt(padTrailing)` on `body` / `elseifs` /
 * `elseBody` closes the boundary gaps the default internal-only separator leaves glued, and
 * `captureSourceNewlineAfter` lets the writer pick a hardline over a space when the source
 * broke the line there. `elseifs` must sit BEFORE `elseBody` so the clause loop fully
 * terminates before the optional `#else` dispatch fires. `nestBodyOnSourceNewline` is
 * deliberately NOT mirrored: a function body already owns its indent policy through
 * `HxFnDecl.body`'s flags, and an extra Nest here would double-indent the `{ ... }` branch.
 */
@:peg
typedef HxConditionalFnBody = {
	@:kw('#if') var cond: HxPpCondLit;
	@:fmt(padTrailing, captureSourceNewlineAfter) var body: HxFnBody;
	@:trivia @:tryparse @:fmt(padTrailing) var elseifs: Array<HxElseifFnBody>;
	@:optional @:kw('#else') @:fmt(padTrailing, captureSourceNewlineAfter) var elseBody: Null<HxFnBody>;
};
