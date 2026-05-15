package anyparse.grammar.haxe;

/**
 * Single field entry in an anonymous structure type.
 *
 * This enum is the field-KIND dispatch only. Leading metadata
 * (`@:optional x:Int`, `@:lead('(') var v:T;`, ...) is carried by the
 * `HxAnonMember` wrapper typedef, which `HxType.Anon` iterates — the
 * same `HxMemberDecl` to `HxClassMember` split at the anon-struct
 * level. `HxAnonField` itself never sees the metadata prefix.
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
 *  - `FnField(decl:HxFnDecl)` — class-notation function field
 *    `function name(params):Ret;` (interface-method shape) or with a
 *    `{ … }` body. Mirrors `HxClassMember.FnMember`; the `function`
 *    keyword is the `@:kw` dispatcher and the terminator (`;` for the
 *    `NoBody` signature form, `}` for a braced body) is owned by
 *    `HxFnBody`, not a per-branch `@:trail` — same as `FnMember`.
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
 * `var`, nor `functions` for `function`), then the fallthrough
 * `Required` catch-all LAST — its first token is `HxIdentLit`, which
 * would otherwise shadow the keyword branches. This mirrors the
 * `HxStatement` / `HxClassMember` pattern where keyword-/lead-
 * dispatched branches precede the no-guard catch-all.
 *
 * Multi-field anon (`{ var a:T; var b:T; }`) parses in every build:
 * `HxType.Anon` opts into `@:sepAlt(';')`, which in the non-trivia
 * build (`{trivia:false}`, used by both `HaxeParser` and the span
 * parser `apq` uses) selects a close-driven loop that consumes an
 * OPTIONAL `,` OR `;` between fields plus an optional trailing
 * separator. `VarField`/`FinalField` keep their `@:trail(';')` (the
 * field eats its own `;`); the loop tolerates that as well as
 * `;`-separated short fields, classic `,`, mixed, and `{}`.
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
	@:kw('function') FnField(decl:HxFnDecl);
	Required(field:HxAnonFieldBody);
}
