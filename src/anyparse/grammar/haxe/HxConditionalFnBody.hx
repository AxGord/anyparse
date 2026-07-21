package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <fn-body> [#elseif ...] [#else <fn-body>] #end`
 * region that occupies a function's ENTIRE body slot. The enclosing
 * `HxFnBody.CondBody` ctor consumes the `#if` keyword and the trailing
 * `#end`; this typedef covers the content between them.
 *
 * Motivating sources (std, 3 modules):
 *
 * ```haxe
 * public static function parse(text:String):Dynamic
 *     #if (!haxeJSON && flash11); #else {
 *         return haxe.format.JsonParser.parse(text);
 *     } #end                       // flash/_std/haxe/Json.hx, js/_std/haxe/Json.hx
 *
 * @:op(~A) private static inline function complement(a:Int32):Int32
 *     #if lua return lua.Boot.clampInt32(~a); #else return clamp(~a); #end
 *                                  // haxe/Int32.hx:175
 * ```
 *
 * Both shapes are ONE `#if` straddling the whole body slot, and the two
 * branches disagree about which `HxFnBody` form the body takes: `;`
 * (`NoBody`) vs `{ ... }` (`BlockBody`) in the Json case, `return ...;` vs
 * `return ...;` (`ExprBody`) in the Int32 case. Making each branch a
 * single `HxFnBody` Ref therefore costs nothing and buys every body
 * form the plain slot already supports, including a nested `#if`
 * (`CondBody` is itself an `HxFnBody`).
 *
 * Why a Ref and not a Star (the `HxConditionalStmt` / `HxConditionalMember`
 * shape): a function has exactly ONE body per compilation variant. A
 * Star would accept `#if a { } { } #end` - two bodies for one function -
 * and would have no terminator to stop on other than the `#end` itself.
 * This mirrors `HxConditionalExpr`, whose branches are single `HxExpr`
 * for the same "one value per branch" reason.
 *
 * Why not `HxCondSpliceRaw` (the `{raw, tail}` idiom): the region is
 * BALANCED - each branch is a complete, well-formed body - so nothing
 * is left dangling outside it and no tail needs re-joining. The splice
 * idiom exists for fragments that are NOT parseable subtrees; using it
 * here would throw away the body AST (and with it `SymbolIndex`'s view
 * of the code inside the branches) for no gain.
 *
 * Scope discipline (the `HxMemberModifier` vs `HxModifier` precedent):
 * this typedef is referenced ONLY from `HxFnBody.CondBody`, which sits
 * LAST in that enum. `HxFnBody.ExprBody` -> `HxExpr.ConditionalExpr`
 * keeps every `#if` region whose branches are single EXPRESSIONS
 * (`function f() #if a { 1; } #else { 2; } #end` already parsed that
 * way), so this ctor only fires on regions the expression-scope
 * conditional cannot represent - branch bodies that are `;`, or
 * statements terminated by `;` inside the region.
 *
 * Field flags mirror `HxConditionalExpr`, the single-Ref-body sibling:
 * `@:fmt(padTrailing)` on `body` / `elseifs` / `elseBody` closes the
 * boundary gaps the default internal-only separator leaves glued
 * (`body` -> `#elseif` / `#else` / `#end`, `elseBody` -> `#end`), and
 * `captureSourceNewlineAfter` lets the writer pick a hardline over a
 * space when the source broke the line there - the std sources put
 * `#end` on the body's own line. `elseifs` must sit BEFORE `elseBody`
 * so the clause loop fully terminates before the optional `#else`
 * dispatch fires.
 *
 * `nestBodyOnSourceNewline` (used by `HxConditionalExpr`) is
 * deliberately NOT mirrored: at expression scope the fork indents the
 * branch value one step deeper than the `#if` line, but a function body
 * already owns its own indent policy through
 * `HxFnDecl.body`'s `leftCurly` / `bodyPolicyForCtor` flags, and an
 * extra Nest here would double-indent the `{ ... }` branch.
 */
@:peg
typedef HxConditionalFnBody = {
	@:kw('#if') var cond: HxPpCondLit;
	@:fmt(padTrailing, captureSourceNewlineAfter) var body: HxFnBody;
	@:trivia @:tryparse @:fmt(padTrailing) var elseifs: Array<HxElseifFnBody>;
	@:optional @:kw('#else') @:fmt(padTrailing, captureSourceNewlineAfter) var elseBody: Null<HxFnBody>;
};
