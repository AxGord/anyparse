package anyparse.grammar.haxe;

/**
 * Single field entry in an anonymous structure type.
 *
 * Two branches:
 *
 *  - `Required(field:HxAnonFieldBody)` — the canonical form `name:Type`.
 *    No keyword/lead — the branch matches when the next token is the
 *    field name (`HxIdentLit`).
 *
 *  - `Optional(field:HxAnonFieldBody)` — the optional form
 *    `?name:Type` (`{?name:String}`). Dispatched by `@:lead('?')`. The
 *    body is identical to `Required` after the `?` is consumed, so both
 *    branches share `HxAnonFieldBody` as their inner shape.
 *
 * The Alt-enum-split shape was chosen over a Boolean presence flag
 * because the macro pipeline currently supports `@:optional` only on
 * `Ref` and `Star` fields. A presence-flag approach would require
 * extending Lowering / WriterLowering to handle `@:optional` on a
 * `Bool` field with `@:lead`/`@:kw`. The split keeps the macro infra
 * unchanged and reuses Case 3 (single-Ref-child branch with optional
 * lead) on both the parser and writer sides.
 *
 * Branch order matters: `Optional` comes first so the `@:lead('?')`
 * dispatch is tried before the fallthrough `Required`. This mirrors
 * the `HxStatement` pattern where keyword-/lead-dispatched branches
 * precede the no-guard catch-all (`ExprStmt`).
 *
 * The four corpus fixtures using this marker (issue_140, issue_642 and
 * two siblings) need additional grammar features (lambda `?param`,
 * type-param constraints) to pass end-to-end — landing the Alt-enum
 * split on its own only flips fixtures whose ONLY blocker is the `?`.
 */
@:peg
enum HxAnonField {
	@:lead('?') Optional(field:HxAnonFieldBody);
	Required(field:HxAnonFieldBody);
}
