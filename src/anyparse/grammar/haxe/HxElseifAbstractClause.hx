package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <from/to clauses>` clause inside a
 * `HxConditionalAbstractClause` chain. Abstract-clause-scope twin of
 * `HxElseifHeritage`: the `#elseif` keyword commits the clause, the
 * condition atom follows, and the body is a try-parse Star of
 * `HxAbstractClause` terminated by the next `#elseif` / `#else` /
 * `#end` token.
 *
 * No lime / openfl / std module currently chains `#elseif` in an
 * abstract clause run - the field exists because every other
 * conditional-compilation scope (`HxElseifHeritage`, `HxElseifMeta`,
 * `HxElseifParam`, `HxElseifType`, ...) carries one, and omitting it
 * here would make the abstract-clause region the single scope where a
 * three-branch guard silently fails to parse. Cost is one typedef; the
 * alternative (defer until a fixture appears) buys nothing because the
 * shape is a byte-copy of the heritage twin.
 */
@:peg
typedef HxElseifAbstractClause = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxAbstractClause>;
};
