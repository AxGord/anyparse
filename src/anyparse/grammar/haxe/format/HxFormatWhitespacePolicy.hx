package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `whitespace.*Policy` fields
 * accept. Mirrors `formatter.config.WhitespacePolicy` in the fork's
 * schema 1:1 so a `hxformat.json` written for upstream haxe-formatter
 * parses without unknown-value errors.
 *
 * Mapped by `HaxeFormatConfigLoader` to `anyparse.format.WhitespacePolicy`:
 *
 * - `"before"` / `"onlyBefore"` → `WhitespacePolicy.Before`
 * - `"after"`  / `"onlyAfter"`  → `WhitespacePolicy.After`
 * - `"around"`                   → `WhitespacePolicy.Both`
 * - `"none"` / `"noneBefore"` / `"noneAfter"` → `WhitespacePolicy.None`
 *
 * The `onlyBefore` / `onlyAfter` / `noneBefore` / `noneAfter` values in
 * haxe-formatter carry extra semantics about the surrounding operator
 * context (e.g. suppress the opposite side's space). Collapsing them
 * into the four-way `WhitespacePolicy` surface is a lossy but honest
 * approximation — the writer currently has no way to introspect the
 * opposite side's policy.
 */
enum abstract HxFormatWhitespacePolicy(String) to String {

	final None = 'none';

	final Before = 'before';

	final NoneBefore = 'noneBefore';

	final OnlyBefore = 'onlyBefore';

	final After = 'after';

	final OnlyAfter = 'onlyAfter';

	final NoneAfter = 'noneAfter';

	final Around = 'around';
}
