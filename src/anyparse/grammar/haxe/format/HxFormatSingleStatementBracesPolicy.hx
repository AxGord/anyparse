package anyparse.grammar.haxe.format;

/**
 * Closed set of values the `whitespace.bracesConfig.singleStatementBraces`
 * key accepts (slice ω-single-stmt-braces).
 *
 * - `"keep"` (default) — braces around single-statement `if` / `else` / `for` / `while` / `do-while` bodies are preserved as authored.
 * - `"remove"` — the writer drops the braces around a body whose block
 *   contains exactly one safe statement (`if (cond) { return x; }` →
 *   `if (cond) return x;`). Safety gates (dangling-else, comments,
 *   terminator presence) live in `anyparse.format.SingleStmtBraces`.
 *
 * - `"symmetric"` - the removal direction stays OFF and only the SYMMETRY
 * repair runs: when an if/else (or a try/catch group, or a value-`if`) has
 * exactly one braced branch, the bare one GAINS braces. A bare branch with
 * no braced sibling is left alone - this is not "brace everything".
 *
 * Mapped by `HaxeFormatConfigLoader.applyBracesConfig` onto the runtime
 * `HxModuleWriteOptions.dropSingleStmtBraces` / `singleStmtBraceSymmetry`
 * pair: `"remove"` sets BOTH (the repair has always been part of it),
 * `"symmetric"` only the second, `"keep"` neither.
 */
enum abstract HxFormatSingleStatementBracesPolicy(String) to String {

	final Keep = 'keep';

	final Remove = 'remove';

	final Symmetric = 'symmetric';

}
