package anyparse.grammar.haxe;

/**
 * `#else <type>;` clause of a type-position conditional-compilation
 * region. Reached via `HxConditionalType.elseClause`'s
 * `@:optional @:kw('#else')` Ref.
 *
 * Exists as a one-field wrapper purely so the branch type's
 * `@:trailOpt(';')` sits on a NON-optional field — `@:trailOpt` is
 * dropped on `@:optional` fields, so the trailing `;` of the
 * `#else`-branch type could not otherwise be consumed before the
 * host's `@:trail('#end')`. See `HxConditionalType` for the full
 * rationale. The `#else` keyword itself is owned by the parent
 * optional-kw-Ref, not by this typedef.
 */
@:peg
typedef HxConditionalTypeElse = {
	@:trailOpt(';') var type:HxType;
};
