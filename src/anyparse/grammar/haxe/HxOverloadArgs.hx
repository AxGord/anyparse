package anyparse.grammar.haxe;

/**
 * Single-field Seq wrapper that consumes the `function` keyword
 * inside an `@:overload(function ...)` metadata arg, then descends
 * into the function-decl body via `HxOverloadFn`.
 *
 * Exists to satisfy a macro pipeline constraint: enum ctor arguments
 * cannot carry field-level `@:kw` metas (Haxe parser rejects), and
 * `@:kw` on an `@:optional Star` first field is rejected at lowering
 * (`Lowering: @:optional Star field "..." does not support @:kw`).
 * Wrapping the kw on a typedef's first MANDATORY Ref field is the
 * established shape (mirror of `HxUntypedFnBody.block` consuming the
 * `untyped` kw before its `HxFnBlock` Ref).
 *
 * Trivia: `HxOverloadFn` is bearing transitively through
 * `HxFnBody.BlockBody(HxFnBlock)`, so this wrapper is bearing too —
 * `TriviaTypeSynth` synthesises `HxOverloadArgsT` automatically.
 */
@:peg
typedef HxOverloadArgs = {
	@:kw('function') @:fmt(kwTight) var fn:HxOverloadFn;
}
