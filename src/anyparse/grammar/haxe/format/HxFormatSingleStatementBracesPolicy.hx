package anyparse.grammar.haxe.format;

/**
 * Closed set of values the `whitespace.bracesConfig.singleStatementBraces`
 * key accepts (slice ω-single-stmt-braces).
 *
 * - `"keep"` (default) — braces around single-statement `if` / `else` /
 *   `for` / `while` bodies are preserved as authored.
 * - `"remove"` — the writer drops the braces around a body whose block
 *   contains exactly one safe statement (`if (cond) { return x; }` →
 *   `if (cond) return x;`). Safety gates (dangling-else, comments,
 *   terminator presence) live in `anyparse.format.SingleStmtBraces`.
 *
 * Mapped by `HaxeFormatConfigLoader.applyBracesConfig` onto the runtime
 * `HxModuleWriteOptions.dropSingleStmtBraces` boolean.
 */
enum abstract HxFormatSingleStatementBracesPolicy(String) to String {

	final Keep = 'keep';

	final Remove = 'remove';

}
