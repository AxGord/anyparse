package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <from/to clauses> [#elseif ...] [#else ...] #end`
 * preprocessor-guarded region in abstract-clause position. The enclosing
 * `HxAbstractClause.Conditional` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them - the
 * condition atom, a try-parse Star of further clauses, the `#elseif`
 * chain, and an optional `#else` clause with its own Star.
 *
 * Field-for-field twin of `HxConditionalHeritage`. That is not laziness:
 * `HxAbstractClause` and `HxHeritageClause` are the same grammar shape
 * (a keyword-introduced single-`HxType` clause, gathered by a bare
 * try-parse Star on the owning declaration - see the "structural twin"
 * note in `HxHeritageClause`'s own doc), so the conditional wrapper that
 * works for one works for the other with no adaptation.
 *
 * Motivating shapes - the three lime modules that need it:
 *
 * ```haxe
 * abstract ArrayBuffer(Bytes) from Bytes to Bytes
 *     #if doc_gen from Dynamic to Dynamic
 *     #end
 *
 * abstract OpenGLES2RenderContext(OpenGLES3RenderContext) from OpenGLES3RenderContext
 *     #if (!doc_gen && lime_opengl) from OpenGLRenderContext #end
 *
 * abstract Transferable(Dynamic) #if macro from Dynamic
 *     #else from lime.utils.ArrayBuffer from js.html.MessagePort from js.html.ImageBitmap #end
 * ```
 *
 * The third shape is why `elseBody` is a Star and not a single clause:
 * the `#else` branch contributes three `from` clauses at once.
 *
 * Distinct from `HxConditionalType`, which already covers a conditional
 * in the TYPE slot of a clause (`from #if x A #else B #end`): here the
 * `from` / `to` keyword itself lives inside the region, so the
 * conditional has to be an element of the clause Star rather than of
 * the type it names. The two compose - a conditional clause may carry a
 * conditional type.
 *
 * Rejected alternative: widening `HxAbstractDecl.clauses` to a
 * cond-comp-aware wrapper struct (the `HxAnonMember` / `HxMemberDecl`
 * shape) instead of adding a branch to `HxAbstractClause`. It would
 * have forced every existing `ad.clauses[i]` consumer through an extra
 * unwrap for a construct that appears in three modules, and it breaks
 * the parallel with the heritage scope, where the branch lives on the
 * clause enum.
 *
 * `@:tryparse` termination: the body loop attempts a clause each
 * iteration and breaks when the next token is neither `from`, `to`, nor
 * a nested `#if` - in legal input that terminator is `#elseif` /
 * `#else` / `#end`, consumed by the following field / the outer ctor's
 * `@:trail`.
 *
 * `@:fmt(padLeading, padTrailing)` on the Stars closes the boundary gaps
 * against `#if <cond>` / `#else` / `#end`, the same pad pair as the
 * `HxConditionalHeritage` precedent; empty Stars degrade to `_de()`.
 */
@:peg
typedef HxConditionalAbstractClause = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxAbstractClause>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifAbstractClause>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxAbstractClause>>;
};
