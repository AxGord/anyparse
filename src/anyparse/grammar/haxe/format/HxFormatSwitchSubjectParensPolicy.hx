package anyparse.grammar.haxe.format;

/**
 * Closed set of values the `whitespace.parenConfig.switchSubjectParens`
 * key accepts (slice ω-switch-subject-parens).
 *
 * - `"keep"` (default) — the parens around a `switch (subject) { … }`
 *   subject are preserved as authored (fork-parity baseline).
 * - `"remove"` — the writer drops the redundant parens around the switch
 *   subject (`switch (v) { … }` → `switch v { … }`), rendering the
 *   idiomatic bare form. Parens are still kept when the subject's leading
 *   token is a brace (object literal / block), where they disambiguate the
 *   subject from the cases block. Statement- and expression-position switch
 *   share the `HxSwitchStmt` grammar, so both are covered.
 *
 * Mapped by `HaxeFormatConfigLoader.applyParenConfig` onto the runtime
 * `HxModuleWriteOptions.dropSwitchSubjectParens` boolean.
 */
enum abstract HxFormatSwitchSubjectParensPolicy(String) to String {

	final Keep = 'keep';

	final Remove = 'remove';

}
