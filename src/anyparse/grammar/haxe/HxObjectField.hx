package anyparse.grammar.haxe;

/**
 * One entry inside an anonymous object literal: either a bare `name: value` field or a
 * `#if … #end`-guarded preprocessor block wrapping a run of further field entries.
 *
 * The `name: value` shape lives in `HxObjectFieldBody`; this enum's `Field` ctor wraps it —
 * the typedef indirection is required because Haxe rejects field-level `@:fmt`/`@:lead`
 * metadata on individual enum ctor parameters.
 *
 * The field name uses the `HxObjectKeyLit` terminal: a bare identifier or a double-quoted
 * string literal (`{ "kebab-case": v }`). A quoted key is stored WITH its surrounding quotes
 * (`@:rawString` on the terminal), so `(name : String)` returns `"name"` for a quoted key and
 * `name` for a bare one, and the writer re-emits the slice verbatim. Single-quoted keys and
 * escaped `\"` inside a key are deferred (see `HxObjectKeyLit`). The value is a full `HxExpr`
 * parsed through the `@:lead(':')` commit point in `HxObjectFieldBody`.
 *
 * `Conditional` covers `#if <cond> <fields> [#elseif …] [#else …] #end` regions wrapping
 * whole field entries — the object-literal member of the cond-comp cluster (`HxDecl`,
 * `HxStatement`, `HxClassMember`, `HxMemberModifier` carry the same ctor at their scopes).
 * `@:kw('#if')` dispatches with a non-word-char boundary check (so `#iff` is rejected);
 * `@:trail('#end')` consumes the closing directive after `HxConditionalObjectField` parses the
 * cond atom, the field body Star (the `@:sep+@:tryparse-no-close` Lowering branch), the
 * optional `#elseif` chain and the optional `#else` clause.
 *
 * Branch order: keyword-dispatched `Conditional` FIRST, the catch-all `Field` LAST — the
 * `HxAnonField` pattern, where the unguarded branch's first token is the field-name terminal
 * and must not shadow the keyword branch (`#` is not a valid `HxObjectKeyLit` prefix, so the
 * ordering is convention rather than necessity here).
 *
 * Writer dispatch fans out per ctor: `Field` re-emits the wrapped body unchanged;
 * `Conditional` delegates to the `HxConditionalObjectField` writer plus the ctor's own
 * `@:kw('#if')` / `@:trail('#end')` literals.
 */
@:peg
enum HxObjectField {

	@:kw('#if') @:trail('#end')
	Conditional(inner: HxConditionalObjectField);

	Field(body: HxObjectFieldBody);

}
