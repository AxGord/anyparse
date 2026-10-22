package anyparse.query;

/**
 * An `import` / `using` argument as the caller spelled it: the keyword it opened with, or null for
 * a bare module path, and the path with the keyword and the closing `;` taken off.
 */
typedef ImportSpelled = {
	var keyword: Null<String>;
	var path: String;
};

/**
 * How an op that takes an import ARGUMENT reads it — `add-import`, `remove-import` and `new`'s
 * `@@ imports` section, the three places a caller hands over "an import" as text.
 *
 * Each of them took BARE module paths, and a whole `import x.Y;` / `using x.Y;` line — the spelling
 * every caller reaches for, because it is what the file will contain — was concatenated into
 * `import using x.Y;;` and surfaced two layers later as `result does not parse: error at 2:15`, a column
 * inside a source the caller never wrote. `new` learnt both spellings first (its own copy of this
 * reader); `add-import` did not, so a client agent concluded it "cannot add a using" and patched one in by
 * hand. One reader now serves all three, so the spellings an op accepts cannot drift apart again.
 */
@:nullSafety(Strict)
final class ImportSpelling {

	public static inline final IMPORT_WORD: String = 'import';
	public static inline final USING_WORD: String = 'using';

	/** The width of ` as ` / ` in ` — the alias keyword with the space on each side. */
	private static inline final ALIAS_WORD_WIDTH: Int = 4;

	/** The refusal for an `import …` statement passed under `--using` — `split`'s null. */
	public static inline function flagConflict(text: String): String {
		return '"${text.trim()}" is an `import` statement, but --using asks for a `using` — drop one of the two';
	}

	/** The refusal for an argument `isModulePath` does not accept, naming both spellings it would have. */
	public static inline function notAPath(text: String): String {
		return '"${text.trim()}" is neither a module path nor an import / using statement';
	}

	/**
	 * `text` read as an import argument: `import x.Y;` / `using x.Y;` (the `;` optional) or a bare
	 * `x.Y`, trimmed. A bare keyword (`import`) is a keyword with an EMPTY path — not a path named
	 * `import`, which wrapped into the `import import;` that parses and means nothing — so a caller
	 * refuses it on the empty path.
	 *
	 * `usingFlag` is the op's `--using`: it makes a bare path a `using`, and contradicts an
	 * `import …` statement, which answers null so the op can refuse it by name rather than pick one
	 * of the two requests.
	 */
	public static function split(text: String, usingFlag: Bool = false): Null<ImportSpelled> {
		final line: String = text.trim();
		for (keyword in [IMPORT_WORD, USING_WORD]) if (line == keyword || line.startsWith('$keyword ')) {
			return usingFlag && keyword == IMPORT_WORD
				? null
				: { keyword: keyword, path: withoutSemicolon(line.substr(keyword.length).trim()) };
		}
		return { keyword: usingFlag ? USING_WORD : null, path: withoutSemicolon(line) };
	}

	/**
	 * Is `path` a module path a statement can carry — dot-separated identifier segments, an optional
	 * `.*` last segment, an optional alias tail (` as <Alias>`, or the legacy ` in <Alias>`)?
	 *
	 * A POSITIVE criterion, because the harm side is open-ended. The first cut refused only a line
	 * carrying a `;` — one leak of the class, not the class: `this is not a path` still became
	 * `import this is not a path;` and died with exactly the `unexpected input (expected //)` at a
	 * generated column that naming the bad line exists to replace.
	 */
	public static function isModulePath(path: String): Bool {
		final aliasAt: Int = aliasStart(path);
		if (aliasAt >= 0 && !SourceText.isIdentifier(path.substr(aliasAt + ALIAS_WORD_WIDTH).trim())) return false;
		final segments: Array<String> = (aliasAt < 0 ? path : path.substring(0, aliasAt)).split('.');
		for (i in 0...segments.length) if (
			!(segments[i] == '*' && i > 0 && i == segments.length - 1) && !SourceText.isIdentifier(segments[i])
		)
			return false;
		return true;
	}

	private static inline function withoutSemicolon(body: String): String {
		return body.endsWith(';') ? body.substr(0, body.length - 1).trim() : body;
	}

	/** Where an alias tail (` as ` or ` in `) starts in `path`, or -1. */
	private static function aliasStart(path: String): Int {
		final asAt: Int = path.indexOf(' as ');
		return asAt >= 0 ? asAt : path.indexOf(' in ');
	}

}
