package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <decl-prefix entries> [#else <entries>] #end`
 * preprocessor-guarded region in declaration-prefix position. The
 * enclosing `HxMetadata.Conditional` ctor consumes the `#if` keyword and
 * the trailing `#end`; this typedef covers the content between them — the
 * condition atom, a try-parse Star of further entries, and an optional
 * `#else` clause with its own Star.
 *
 * Metadata-scope twin of `HxConditionalMod` (modifier run): closes the
 * "conditional platform meta before a decl" gap —
 * `#if windows @:cppFileCode('...') #end final class C {}` (live dogfood shape). Nested `#if` composes for free:
 * `HxMetadata.Conditional` is itself a metadata entry, so a
 * conditional inside the body is just another Star element.
 *
 * The Stars hold `HxCondDeclPrefix`, not `HxMetadata` — a branch may
 * contribute a bare declaration keyword instead of a tag, as in openfl's
 * `#if (haxe_ver >= 4.0) enum #else @:enum #end abstract BlendMode(Null<Int>)`.
 * See that enum for why the widening is scoped to the conditional bodies
 * and cannot shadow the ordinary `enum abstract` / `enum` dispatch.
 *
 * `@:tryparse` termination: the body loop attempts an entry each
 * iteration and breaks when the next token is neither `@`, `enum`, nor a
 * nested `#if` — in legal input that terminator is `#else` / `#end`,
 * consumed by the following field / the outer ctor's `@:trail`.
 *
 * `@:fmt(padLeading, padTrailing)` on both Stars closes the boundary
 * gaps against `#if <cond>` / `#else` / `#end` — the same pad pair as
 * the `HxConditionalMod` precedent; empty Stars degrade to `_de()`.
 */
@:peg
typedef HxConditionalMeta = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxCondDeclPrefix>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifMeta>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxCondDeclPrefix>>;
};
