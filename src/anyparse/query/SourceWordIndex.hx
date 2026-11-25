package anyparse.query;

import anyparse.runtime.Span;

using anyparse.util.Strings;

/**
 * The one answer to "at which offsets of which sources does name N stand as a whole word", built
 * in one pass over the sources and asked once per name — the replacement for a text walk per
 * asked name. A word is a maximal run of identifier characters, or the tail of a run that follows
 * a numeric `$` escape (`OccurrenceScan.interpolationEscapeBefore`): the same word-boundary
 * reading `OccurrenceScan.referencedInRange` gives, over raw text, comments and strings included.
 *
 * Instance state of the run-scoped `RawSourceScan` that owns it, never process-scoped.
 */
@:nullSafety(Strict)
final class SourceWordIndex {

	/** The sources' paths, in the order their offsets were recorded; a hit names its file by position here. */
	private final _files: Array<String> = [];

	/** Per word, flat pairs of (file position in `_files`, offset of the word's first character), in source order. */
	private final _hits: Map<String, Array<Int>> = [];

	public function new(sources: Map<String, String>) {
		for (file => source in sources) {
			addSource(_files.length, source);
			_files.push(file);
		}
	}

	/**
	 * Whether `name` stands as a word at an offset that lies in none of its file's `excluded` spans
	 * and in none of the file's `maskOf` spans (sorted, non-overlapping). `name` must be `indexable`.
	 */
	public function occursOutside(name: String, excluded: Map<String, Array<Span>>, maskOf: (file: String) -> Array<Span>): Bool {
		final hits: Null<Array<Int>> = _hits[name];
		if (hits == null) return false;
		var i: Int = 0;
		while (i < hits.length) {
			final file: String = _files[hits[i]];
			final at: Int = hits[i + 1];
			if (!OccurrenceScan.offsetWithinAny(at, excluded[file] ?? []) && !OccurrenceScan.offsetWithinSorted(at, maskOf(file)))
				return true;
			i += 2;
		}
		return false;
	}

	private function addSource(fileIndex: Int, source: String): Void {
		final len: Int = source.length;
		var i: Int = 0;
		while (i < len) {
			if (!source.fastCodeAt(i).isIdentChar()) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < len && source.fastCodeAt(end).isIdentChar()) end++;
			record(source.substring(i, end), fileIndex, i);
			if (i > 0 && source.fastCodeAt(i - 1) == '\\'.code) for (escape in OccurrenceScan.DOLLAR_ESCAPES) {
				final tail: Int = i + escape.length - 1;
				if (tail < end && OccurrenceScan.interpolationEscapeBefore(source, tail))
					record(source.substring(tail, end), fileIndex, tail);
			}
			i = end;
		}
	}

	private function record(word: String, fileIndex: Int, at: Int): Void {
		final seen: Null<Array<Int>> = _hits[word];
		if (seen == null) {
			_hits[word] = [fileIndex, at];
			return;
		}
		seen.push(fileIndex);
		seen.push(at);
	}

	/** Whether `name` is a run of identifier characters, the only shape this index can answer for. */
	public static function indexable(name: String): Bool {
		if (name.length == 0) return false;
		for (i in 0...name.length) if (!name.fastCodeAt(i).isIdentChar()) return false;
		return true;
	}

}
