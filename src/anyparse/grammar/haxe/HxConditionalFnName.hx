package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <name> [#elseif <cond> <name>]* [#else <name>]
 * #end` region occupying a function's NAME slot. Reached via
 * `HxFnNameRegion.Conditional`, which owns the `#end` marker; the `#if`
 * rides `HxCondNameFnDecl.region`.
 *
 * Motivating source - `format/format/tools/MemoryInput.hx:46`,
 * byte-identical in the `3,5,0` / `3,7,0` / `3,8,0` haxelib versions:
 *
 * ```haxe
 * override function #if (haxe_211 || haxe3) set_bigEndian #else setEndian #end(b) {
 * ```
 *
 * Confirmed valid Haxe: `haxe -swf` compiles the module with zero
 * diagnostics. The preprocessor runs on the token stream, so a guard may
 * straddle any token boundary - here the two library generations disagree
 * about the setter's name while everything around it is shared.
 *
 * `elseifs` carries `@:trivia` where the type-scope twin
 * (`HxConditionalType.elseifs`) does not, and that is load-bearing rather
 * than cosmetic: every other field of this typedef Refs a TERMINAL
 * (`HxPpCondLit`, `HxIdentLit`), so without a `@:trivia` Star
 * `TriviaAnalysis` would not mark the rule trivia-bearing, `TriviaTypeSynth`
 * would synthesise no paired type, and the `@:optional @:kw('#else')`
 * field's `elseNameBeforeKwLeading` / `elseNameBeforeKwTrailing` slots -
 * which `HaxeModuleTriviaWriter` reads unconditionally - would not exist.
 * The sibling conditional bodies all Ref a bearing rule (`HxExpr`,
 * `HxType`, `HxStatement`) and get the closure for free.
 *
 * `@:fmt(padTrailing)` on `name` / `elseifs` / `elseName` closes the
 * boundaries the default internal-only separator leaves glued (`name` ->
 * `#elseif` / `#else` / the branch's own `#end`); `padLeading` on the Star
 * closes the `name` -> first-clause gap.
 */
@:peg
typedef HxConditionalFnName = {
	var cond: HxPpCondLit;
	@:fmt(padTrailing) var name: HxIdentLit;
	@:trivia @:tryparse @:fmt(padTrailing) var elseifs: Array<HxElseifFnName>;
	@:optional @:kw('#else') @:fmt(padTrailing) var elseName: Null<HxIdentLit>;
};
