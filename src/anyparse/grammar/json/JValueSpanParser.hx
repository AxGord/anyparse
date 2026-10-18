package anyparse.grammar.json;

/**
 * Marker class for the macro-generated SPAN-mode parser of `JValue` — the parser the
 * `json` query plugin (`JsonQueryPlugin`) and the format-preserving writer
 * (`JsonLayoutWriter`) read.
 *
 * `Build.buildParser(..., {spans: true})` synthesises the paired `*S` types in
 * `anyparse.grammar.json.spans.Pairs`: every `JValueS` ctor carries a trailing `_span`, and
 * `JEntryS` — `@:spanned('Member')` — carries its own, from the key's opening quote to the
 * value's last byte. The spans are tight (whitespace before a value is not inside its span)
 * except the ROOT's, which starts at offset 0 because the root rule skips the leading
 * whitespace itself.
 *
 * The class body is empty on purpose: every method is contributed by the macro.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.json.JValue, { spans: true }))
@:nullSafety(Strict)
class JValueSpanParser {}
