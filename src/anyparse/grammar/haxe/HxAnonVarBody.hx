package anyparse.grammar.haxe;

/**
 * Optional-marker wrapper for `var` / `final` class-notation fields
 * inside an anonymous structure type — the post-keyword `?` peek that
 * makes the field optional (`final ?additionalTimes:{ … }`,
 * `var ?foldingRangeProvider:EitherType<…>`).
 *
 * Alt-enum-split shape mirroring `HxAnonField.Optional`/`Required`:
 * `@:lead('?') Optional(decl:HxVarDecl)` dispatches when a `?`
 * immediately follows the enclosing `var` / `final` keyword;
 * `Plain(decl:HxVarDecl)` is the catch-all fallthrough used when no
 * `?` is present. Both branches carry the same `HxVarDecl`, so the
 * existing decl shape (name, optional accessor, optional type,
 * optional initializer, multi-var tail) is reused unchanged — every
 * downstream consumer reads the `HxVarDecl` uniformly once the body is
 * unwrapped. Slice 27.
 *
 * Used by `HxAnonField.VarField` and `HxAnonField.FinalField` only.
 * The `var` / `final` keyword and the trailing `;` live on the
 * enclosing ctor via `@:kw` / `@:trailOpt`; this enum dispatches just
 * on the post-keyword `?` peek so the lead consumption is local to the
 * branch and the writer emits `?` tightly (mirroring
 * `HxAnonField.Optional` for the bare `?name:Type` short form).
 *
 * The Alt-enum-split was chosen over a Boolean presence flag on
 * `HxVarDecl` because the macro pipeline supports `@:optional` only on
 * `Ref` and `Star` fields, and `HxVarDecl` is shared across class
 * members / anon-struct fields / local var statements — pushing the
 * optional marker down into the shared decl would either pollute every
 * non-anon consumer or require gating that the macro doesn't express.
 * The wrapper is local to the anon-struct call site, identical
 * mechanism to the existing `HxAnonFieldBody`-wrapped short-form
 * `?name:Type` (`HxAnonField.Optional`).
 */
@:peg
enum HxAnonVarBody {

	@:lead('?') Optional(decl: HxVarDecl);
	Plain(decl: HxVarDecl);

}
