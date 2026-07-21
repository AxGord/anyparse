package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <fields> [#elseif ...] [#else <fields>] #end`
 * preprocessor-guarded region wrapping whole fields of an ANONYMOUS
 * STRUCTURE TYPE. The enclosing `HxAnonField.Conditional` ctor consumes
 * the `#if` keyword and the trailing `#end`; this typedef covers the
 * content between them - the condition atom, the then-body Star of
 * further anon members, an optional `#elseif` chain, and an optional
 * `#else` clause with its own Star.
 *
 * Type-level sibling of `HxConditionalObjectField`, which does the same
 * job for an object-LITERAL (`{a: 1, #if x b: 2 #end}`). The two cannot
 * share a body typedef: the object-literal scope holds `HxObjectField`
 * elements separated by a mandatory `,`, while an anon-type field run is
 * `HxAnonMember` and its elements terminate themselves with `;` through
 * `HxAnonField.VarField`'s `@:trailOpt(';')`. Reusing the obj-lit body
 * outright was tried first and rejected on that element-type mismatch.
 *
 * Motivating shapes:
 *
 * ```haxe
 * // format/bmp/Data.hx (byte-identical in format 3.7.0 and 3.8.0)
 * typedef Data = {
 *     var pixels : haxe.io.Bytes;
 * #if (haxe_ver < 4)
 *     var colorTable : Null<haxe.io.Bytes>;
 * #else
 *     var ?colorTable : haxe.io.Bytes;
 * #end
 * }
 *
 * // lime/tools/WindowData.hx, lime/graphics/RenderContextAttributes.hx
 * #if (js && html5)
 * @:optional var element:js.html.Element;
 * #end
 * ```
 *
 * The lime pair is why the Stars hold `HxAnonMember` rather than the
 * bare `HxAnonField` kind-dispatch enum: a guarded field carries its own
 * `@:optional` tag and (in RenderContextAttributes) its own doc comment,
 * both of which live on the wrapper.
 *
 * No `@:sep`: every observed body uses the `;`-terminated class notation
 * (`var name:Type;`), whose terminator is already consumed by
 * `HxAnonField.VarField` / `FinalField`'s `@:trailOpt(';')`, so a
 * separator peek has nothing to do. A comma-separated SHORT-form body
 * (`#if x a:Int, b:Int #end`) therefore stops after its first field and
 * the region fails to parse. Adding `@:sep(',', sepFaithful)` was
 * considered and deferred: it would make the separator mandatory
 * between the `;`-terminated elements that DO occur in real source,
 * trading three working modules for a shape no checkout in the
 * dependency trees contains. Revisit if such a fixture ever lands.
 *
 * `@:tryparse` termination: the body loop attempts a member each
 * iteration and breaks when the next token starts neither a field nor a
 * nested `#if` - in legal input that terminator is `#elseif` / `#else` /
 * `#end`, consumed by the following field / the outer ctor's `@:trail`.
 *
 * `@:fmt(padLeading, padTrailing)` on the Stars closes the boundary gaps
 * against `#if <cond>` / `#else` / `#end`, the same pad pair as the
 * `HxConditionalHeritage` / `HxConditionalObjectField` precedents; empty
 * Stars degrade to `_de()`.
 */
@:peg
typedef HxConditionalAnonField = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxAnonMember>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifAnonField>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxAnonMember>>;
};
