package anyparse.grammar.haxe;

/**
 * Member-scope token-splice conditional: `#if <cond> <signature> [#else <signature>] #end
 * <shared-body>` — a `#if` region holding two PARALLEL member signatures with the function
 * body living AFTER the `#end`, shared by both compilation variants:
 *
 * ```haxe
 * #if (haxe_ver >= 3.300)
 * @:generic public static inline function sget<A, B:haxe.Constraints.Constructible<Void -> Void>>(m: Map<A, B>, key: A): B
 * #else
 * @:generic public static inline function sget<A, B: { function new(): Void; }>(m: Map<A, B>, key: A): B
 * #end
 *     return m.exists(key) ? m[key] : m[key] = new B();
 * ```
 *
 * Braces BALANCE inside the region (the `#else` branch's constraint carries `{ function
 * new(): Void; }`), which is what makes the shape deceptive: a naive splice-to-`#end` looks
 * structural but would ORPHAN the `return ...;` that follows. `HxClassMember.Conditional`
 * fail-rewinds here because each branch is a signature with NO body — `HxFnBody` has no
 * branch that matches `#else` / `#end`, the member parse throws, the body Star rolls back to
 * zero elements, and the outer `@:trail('#end')` then fails on the still-unconsumed
 * `@:generic`.
 *
 * `{raw, tail}` — the `HxCondSpliceStmt` / `HxCondSpliceExpr` idiom — with `tail` typed as
 * `HxFnBody` rather than `HxMemberDecl`: what follows `#end` is not a member, it is the shared
 * function BODY, so `ExprBody(ReturnExpr(...))` with its `@:trailOpt(';')` is the exact fit,
 * and a `{ ... }` block form parses through `BlockBody` for free. Chosen over the
 * `HxCondDeclPrefix` "split-prefix" model (region captures a partial declaration, the plain
 * dispatch consumes the tail) because that model needs a tail the ordinary dispatch already
 * parses; here the tail is a bare body no member production accepts, so its type has to be
 * named explicitly.
 *
 * Dispatch: `HxClassMember.CondSpliceMember` is tried AFTER `Conditional`, mirroring
 * `HxStatement.CondSpliceStmt` after `HxStatement.Conditional`. Ordering it earlier would be
 * unsafe in a way the statement-scope twin is not: `raw` swallows every byte up to the first
 * `#end`, and `HxFnBody.ExprBody` accepts a bare identifier, so a plain `#if a var x:Int;
 * #end` followed by `public function f() {}` would parse with `public` as the "shared body".
 * After `Conditional`, every region that ctor can represent is already gone.
 */
@:peg
typedef HxCondSharedBodyMember = {
	var raw: HxCondSpliceRaw;
	var tail: HxFnBody;
}
