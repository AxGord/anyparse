package anyparse.grammar.haxe;

/**
 * Single field entry in an anonymous structure type — the field-KIND dispatch only. Leading
 * metadata (`@:optional x:Int`) is carried by the `HxAnonMember` wrapper typedef, which
 * `HxType.Anon` iterates — the `HxMemberDecl` to `HxClassMember` split at the anon level.
 *
 * `Conditional(inner:HxConditionalAnonField)` — a `#if <cond> <fields> [#elseif ...] [#else
 * <fields>] #end` preprocessor-guarded run of whole fields, dispatched by `@:kw('#if')` and
 * closed by `@:trail('#end')` on the ctor. The branch has to sit on this enum rather than on
 * the `HxAnonMember` wrapper because `HxAnonMember` is a struct typedef with no alternatives
 * to add one to. A `#if` reaching this dispatch has already been offered to, and rejected by,
 * the wrapper's metadata Star (`HxMetadata.Conditional` fails its own `@:trail('#end')` as
 * soon as the region body holds a field rather than tags, and the try-parse Star rewinds),
 * so `#if <tags> #end var x:T;` and `#if <fields> #end` stay unambiguous.
 *
 * `Optional(field:HxAnonFieldBody)` — the optional short form `?name:Type`, dispatched by
 * `@:lead('?')`. `ExtendsField(type:HxTypeRef)` — a structure-extension clause `> Type`
 * (`typedef Bar = {> Foo, var x:Int}`), dispatched by `@:lead('>')`; it sits in the same
 * comma/semicolon list as the fields, so multiple extensions and a following field list
 * compose through the `@:sep(',') @:sepAlt(';')` loop. `HxTypeRef` is the precise target —
 * Haxe structure extension only takes a type path — and the `>` is unambiguous at the
 * field-dispatch point (the type-param close `>` is consumed inside `HxTypeRef.params`).
 * `VarField(body:HxAnonVarBody)` — class-notation mutable field `var name:Type;`, the shape
 * of `HxClassMember.VarMember`: `@:kw('var')` enforces a word boundary, the per-branch
 * `@:trailOpt(';')` consumes the terminator if present (optional so that `var x:{var
 * name:Int;}` — inner `}` immediately followed by outer `}` — parses), and `HxAnonVarBody`
 * captures an optional post-keyword `?` (`var ?name:Type`) around the inner `HxVarDecl`.
 * `FinalField(body:HxAnonVarBody)` — `final name:Type;`, mirroring `HxClassMember.FinalMember`
 * with the identical body. `FnField(decl:HxFnDecl)` — `function name(params):Ret;` or with a
 * `{ … }` body, mirroring `HxClassMember.FnMember`; the terminator is owned by `HxFnBody`.
 * `Required(field:HxAnonFieldBody)` — the canonical short form `name:Type`, matched when the
 * next token is the field name. `HxAnonFieldBody` is shared by `Optional` and `Required`.
 *
 * Branch order matters: the lead-dispatched branches first, then the keyword-dispatched
 * class-notation branches (`@:kw` enforces a word boundary so a field named `vars` is not
 * `var`), then the `Required` catch-all LAST — its first token is `HxIdentLit`, which would
 * otherwise shadow the keyword branches. The Alt-enum split (over a Boolean presence flag)
 * was chosen because the macro pipeline supports `@:optional` only on `Ref` and `Star`
 * fields. `HxType.Anon`'s `@:sepAlt(';')` close-driven loop consumes an OPTIONAL `,` OR `;`
 * between fields plus an optional trailing separator, tolerating the field's own `;`.
 */
@:peg
enum HxAnonField {

	@:kw('#if') @:trail('#end') Conditional(inner: HxConditionalAnonField);
	@:lead('?') Optional(field: HxAnonFieldBody);
	@:lead('>') @:fmt(spaceAfterLead) ExtendsField(type: HxTypeRef);
	@:kw('var') @:trailOpt(';') VarField(body: HxAnonVarBody);
	@:kw('final') @:trailOpt(';') FinalField(body: HxAnonVarBody);
	@:kw('function') FnField(decl: HxFnDecl);
	Required(field: HxAnonFieldBody);

}
