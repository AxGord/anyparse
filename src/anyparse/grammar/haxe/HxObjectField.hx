package anyparse.grammar.haxe;

/**
 * One entry inside an anonymous object literal: either a bare
 * `name: value` field or a `#if … #end`-guarded preprocessor block
 * wrapping a run of further field entries.
 *
 * Promoted from typedef to sum-type enum in Slice 18 to host the
 * `Conditional` cond-comp wrapper. The original `name: value` shape
 * lives in `HxObjectFieldBody`; this enum's `Field` ctor wraps it
 * (the typedef indirection is required because Haxe rejects field-
 * level `@:fmt`/`@:lead` metadata on individual enum ctor parameters
 * — see lang-haxe gotcha "Enum Constructor Parameters Cannot Have
 * Metadata — Use a Typedef Instead").
 *
 * Field name uses the `HxObjectKeyLit` terminal: either a bare
 * identifier or a double-quoted string literal (`{ "name": value }`,
 * `{ "kebab-case": v }`). A quoted key is stored WITH its surrounding
 * quotes (`@:rawString` on the terminal), so `(name : String)` returns
 * `"name"` for a quoted key and `name` for a bare one; the writer
 * re-emits the slice verbatim → byte-for-byte round-trip. Single-quoted
 * keys and escaped `\"` inside a key are deferred (see `HxObjectKeyLit`).
 *
 * Value is a full `HxExpr`, parsed with whitespace skipping and the
 * full operator precedence chain — nested object literals, arrays,
 * calls, conditional expressions all compose through the `@:lead(':')`
 * commit point in `HxObjectFieldBody`.
 *
 * `Conditional` covers `#if <cond> <fields> [#elseif …] [#else …] #end`
 * preprocessor regions wrapping whole field entries — the object-literal
 * completion of the cond-comp arc (`HxDecl.Conditional` at decl scope,
 * `HxStatement.Conditional` at stmt scope, `HxClassMember.Conditional`
 * at member scope, `HxMemberModifier.Conditional` for a modifier run).
 * `@:kw('#if')` dispatches with a non-word-char boundary check (so
 * `#iff` is rejected); `@:trail('#end')` consumes the closing directive
 * after `HxConditionalObjectField` parses the cond atom, the field body
 * Star (via Slice 18's `@:sep+@:tryparse-no-close` Lowering branch),
 * the optional `#elseif` chain, and the optional `#else` clause.
 *
 * Branch order: keyword-dispatched `Conditional` (`@:kw('#if')`) comes
 * FIRST, then the catch-all `Field` LAST — mirrors the `HxAnonField`
 * pattern (`Required` last) where the unguarded branch's first token
 * is the field name terminal (`HxIdentLit`) and must not shadow the
 * keyword branch. Structurally `#` isn't a valid `HxObjectKeyLit`
 * prefix so the shadow risk is zero, but the lead/kw-first-then-
 * catch-all ordering matches the established convention.
 *
 * Writer dispatch fans out per-ctor: `Field` re-emits the wrapped body
 * unchanged (the macro splices the `HxObjectFieldBody` writer);
 * `Conditional` delegates to the `HxConditionalObjectField` writer plus
 * the ctor's own `@:kw('#if')` / `@:trail('#end')` literals.
 */
@:peg
enum HxObjectField {

	@:kw('#if') @:trail('#end')
	Conditional(inner:HxConditionalObjectField);

	Field(body:HxObjectFieldBody);
}
