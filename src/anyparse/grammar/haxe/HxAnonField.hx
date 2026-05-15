package anyparse.grammar.haxe;

/**
 * Single field entry in an anonymous structure type.
 *
 * Branches:
 *
 *  - `Optional(field:HxAnonFieldBody)` — the optional short form
 *    `?name:Type` (`{?name:String}`). Dispatched by `@:lead('?')`.
 *
 *  - `VarField(decl:HxVarDecl)` — class-notation mutable field
 *    `var name:Type;`. Same shape as `HxClassMember.VarMember`:
 *    `@:kw('var')` enforces a word boundary, the per-branch
 *    `@:trail(';')` consumes the terminator. `HxVarDecl` covers the
 *    optional `:Type` and optional `= init`.
 *
 *  - `FinalField(decl:HxVarDecl)` — class-notation immutable field
 *    `final name:Type;`. Mirrors `HxClassMember.FinalMember`; body
 *    shape is identical to `VarField`, only the introducer keyword
 *    differs.
 *
 *  - `Required(field:HxAnonFieldBody)` — the canonical short form
 *    `name:Type`. No keyword/lead — the branch matches when the next
 *    token is the field name (`HxIdentLit`).
 *
 * The body of the short forms is `HxAnonFieldBody` (`name : Type`),
 * shared by `Optional` and `Required` so the `?` marker dispatches at
 * the Alt-enum level without duplicating the name-and-type body.
 *
 * Branch order matters. `Optional` (`@:lead('?')`) comes first, then
 * the keyword-dispatched class-notation branches (`@:kw` enforces a
 * word boundary so a field literally named `vars` is not mistaken for
 * `var`), then the fallthrough `Required` catch-all LAST — its first
 * token is `HxIdentLit`, which would otherwise shadow the keyword
 * branches. This mirrors the `HxStatement` / `HxClassMember` pattern
 * where keyword-/lead-dispatched branches precede the no-guard
 * catch-all.
 *
 * SCOPE LIMIT: only a SINGLE class-notation field per anon type
 * parses in a non-trivia build (`{trivia:false}`). `HxType.Anon`'s
 * Star is strictly `@:sep`-char-separated there (`Lowering.hx:1376`
 * hard-requires `,`, then `expectLit('}')`), so `{ var a:T; var b:T; }`
 * — the dominant anyparse-schema shape — fails: after the first
 * `;`-terminated field the loop sees no `,` and the close `expectLit`
 * fails on the next field. The trivia-mode path (`Lowering.hx:1349`)
 * is tolerant, but both `HaxeParser` (Fast) and the span parser used
 * by `apq` (Tolerant) are non-trivia builds, so neither benefits —
 * the discriminator is `ctx.trivia`, orthogonal to Fast/Tolerant.
 * Multi `;`-separated fields need a core dual-separator change to the
 * anon Star (tracked separately); this enum's branches are correct
 * and additive on their own.
 *
 * The Alt-enum-split shape (over a Boolean presence flag) was chosen
 * because the macro pipeline currently supports `@:optional` only on
 * `Ref` and `Star` fields.
 */
@:peg
enum HxAnonField {
	@:lead('?') Optional(field:HxAnonFieldBody);
	@:kw('var') @:trail(';') VarField(decl:HxVarDecl);
	@:kw('final') @:trail(';') FinalField(decl:HxVarDecl);
	Required(field:HxAnonFieldBody);
}
