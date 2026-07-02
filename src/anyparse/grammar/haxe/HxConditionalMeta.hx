package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <@:meta entries> [#else <@:meta entries>] #end`
 * preprocessor-guarded metadata region. The enclosing
 * `HxMetadata.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them — the
 * condition atom, a try-parse Star of further metadata entries, and an
 * optional `#else` clause with its own metadata Star.
 *
 * Metadata-scope twin of `HxConditionalMod` (modifier run): closes the
 * "conditional platform meta before a decl" gap —
 * `#if windows @:cppFileCode('…') #end final class C {}` (live dogfood shape). Nested `#if` composes for free:
 * `HxMetadata.Conditional` is itself a metadata entry, so a
 * conditional inside the body is just another Star element.
 *
 * `@:tryparse` termination: the body loop attempts a metadata entry
 * each iteration and breaks when the next token is not `@` (or a
 * nested `#if`) — in legal input that terminator is `#else` / `#end`,
 * consumed by the following field / the outer ctor's `@:trail`.
 *
 * `@:fmt(padLeading, padTrailing)` on both Stars closes the boundary
 * gaps against `#if <cond>` / `#else` / `#end` — the same pad pair as
 * the `HxConditionalMod` precedent; empty Stars degrade to `_de()`.
 */
@:peg
typedef HxConditionalMeta = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxMetadata>;
	@:trivia @:tryparse var elseifs: Array<HxElseifMeta>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxMetadata>>;
};
