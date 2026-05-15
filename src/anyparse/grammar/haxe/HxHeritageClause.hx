package anyparse.grammar.haxe;

/**
 * Grammar type for `extends`/`implements` heritage clauses on a Haxe
 * class or interface declaration.
 *
 * Shape: `extends Type` or `implements Type` — each clause is a
 * keyword-introduced type reference. Zero or more clauses may appear
 * between the (optional) `<TypeParams>` and the `{` body of a class or
 * interface.
 *
 * Structural twin of `HxAbstractClause` (`from`/`to`): both branches
 * are Case 3 (single-Ref wrapping with `@:kw`) in
 * `Lowering.lowerEnumBranch` — zero Lowering changes. `SpanTypeSynth` /
 * `TriviaTypeSynth` synthesize the bare-Star + Case-3 `@:kw` shape
 * exactly as they already do for `HxAbstractClause`.
 *
 * The parser is intentionally permissive: it does not enforce Haxe's
 * semantic rules (a class has at most one `extends` and uses
 * `implements` for interfaces; an interface uses only `extends`, and
 * may repeat it). Multiple `extends` on a class, `implements` on an
 * interface, or ordering are all accepted here — semantic policing
 * belongs to a later analysis pass, consistent with the `HxDecl`
 * philosophy.
 *
 * `extends` and `implements` are reserved Haxe keywords; the `@:kw`
 * strategy enforces word boundaries, so `extendsFoo` and
 * `implementsBar` do not match.
 */
@:peg
enum HxHeritageClause {
	@:kw('extends')
	ExtendsClause(type:HxType);

	@:kw('implements')
	ImplementsClause(type:HxType);
}
