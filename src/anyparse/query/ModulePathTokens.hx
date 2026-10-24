package anyparse.query;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.LexicalRegions.LexRegionKind;
import anyparse.runtime.Span;

/** One relocated module: its module path before and after, dotted (`pkg.sub.Mod`). */
typedef ModuleRename = {
	final oldPath: String;
	final newPath: String;
}

/** One text edit: replace `span` with `text`. */
typedef TextEdit = {
	final span: Span;
	final text: String;
}

/**
 * The lexical half of a module relocation: every spelling of a relocated module's path in a text — dotted (`pkg.sub.Mod`,
 * which is also how a sub-type `pkg.sub.Mod.Sub` and a member `pkg.sub.Mod.f` begin) and as a slash path (`pkg/sub/Mod`,
 * the module's file path under its source root) — found as a whole TOKEN and rewritten to the new path.
 *
 * A token is bounded: the character before it is not part of a name (and, for the dotted spelling, not a dot, so
 * `x.pkg.sub.Mod` is a different path), and the character after it is not part of a name (so `pkg.sub.ModTest` is a
 * different module). That is the whole proof the rewrite rests on, and it holds in code, strings, comments and plain text
 * alike: the bounded token can only name the relocated module.
 */
@:nullSafety(Strict)
final class ModulePathTokens {

	/** The slash spelling of a dotted module path: `pkg.sub.Mod` -> `pkg/sub/Mod`. */
	public static inline function slashPath(dotted: String): String {
		return dotted.replace('.', '/');
	}

	/** Every bounded occurrence of `token` in `text`, as start offsets in document order. */
	public static function occurrences(text: String, token: String, dotted: Bool): Array<Int> {
		final out: Array<Int> = [];
		if (token.length == 0) return out;
		var from: Int = 0;
		while (true) {
			final at: Int = text.indexOf(token, from);
			if (at < 0) return out;
			from = at + 1;
			final before: Int = at == 0 ? -1 : text.fastCodeAt(at - 1);
			final afterIdx: Int = at + token.length;
			final after: Int = afterIdx >= text.length ? -1 : text.fastCodeAt(afterIdx);
			if (before >= 0 && (SourceText.isIdentChar(before) || (dotted && before == '.'.code))) continue;
			if (after >= 0 && SourceText.isIdentChar(after)) continue;
			out.push(at);
		}
	}

	/** Every edit that rewrites each rename's dotted and slash spellings in `text`, ascending and non-overlapping. */
	public static function edits(text: String, renames: Array<ModuleRename>): Array<TextEdit> {
		final out: Array<TextEdit> = [];
		for (rename in renames) {
			for (at in occurrences(text, rename.oldPath, true))
				out.push({ span: new Span(at, at + rename.oldPath.length), text: rename.newPath });
			final oldSlash: String = slashPath(rename.oldPath);
			if (oldSlash != rename.oldPath) for (at in occurrences(text, oldSlash, false))
				out.push({ span: new Span(at, at + oldSlash.length), text: slashPath(rename.newPath) });
		}
		out.sort((a, b) -> a.span.from - b.span.from);
		return out;
	}

	/** `text` with every rename applied — `edits` spliced. */
	public static function rewrite(text: String, renames: Array<ModuleRename>): String {
		return apply(text, edits(text, renames));
	}

	/** `text` with ascending, non-overlapping `edits` spliced in. */
	public static function apply(text: String, edits: Array<TextEdit>): String {
		if (edits.length == 0) return text;
		final buf: StringBuf = new StringBuf();
		var at: Int = 0;
		for (e in edits) {
			buf.add(text.substring(at, e.span.from));
			buf.add(e.text);
			at = e.span.to;
		}
		buf.add(text.substring(at));
		return buf.toString();
	}

	/**
	 * Every string literal of `source` whose content ENDS with `prefix` — the shape of a path COMPOSED at run time
	 * (`'pkg.sub.' + name`), which names a module through its package without spelling its path, so no token rewrite can
	 * follow it. `regions` are the source's lexical regions; the answer is offsets in document order.
	 */
	public static function stringsEndingWith(source: String, regions: Array<LexRegion>, prefix: String): Array<Int> {
		final out: Array<Int> = [];
		for (r in regions) if (r.kind == LexRegionKind.StringLit && r.to - r.from >= 2) {
			final content: String = source.substring(r.from + 1, r.to - 1);
			if (content.endsWith(prefix)) out.push(r.from);
		}
		return out;
	}

	/** Whether `offset` lies inside one of the non-code `regions` (a comment, a string or a regex literal). */
	public static function inNonCode(offset: Int, regions: Array<LexRegion>): Bool {
		for (r in regions) if (offset >= r.from && offset < r.to) return true;
		return false;
	}

	/**
	 * Every identifier written as CODE in `source` and not reached through a dot — the simple names whose meaning a
	 * relocation can change (a type, or the module a `Mod.Sub` path starts from) — each occurrence with its offset, in
	 * document order. `inert` are the spans that are not code (comments and literal TEXT: an interpolation hole inside a
	 * string IS code), sorted by start; `upperOnly` keeps the upper-initial ones, for a grammar whose type names are.
	 */
	public static function bareNames(source: String, inert: Array<Span>, upperOnly: Bool): Array<{ name: String, at: Int }> {
		final out: Array<{ name: String, at: Int }> = [];
		var maskIdx: Int = 0;
		var i: Int = 0;
		final n: Int = source.length;
		while (i < n) {
			while (maskIdx < inert.length && inert[maskIdx].to <= i) maskIdx++;
			if (maskIdx < inert.length && i >= inert[maskIdx].from) {
				i = inert[maskIdx].to;
				continue;
			}
			final c: Int = source.fastCodeAt(i);
			if (!SourceText.isIdentStartChar(c)) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n && SourceText.isIdentChar(source.fastCodeAt(i))) i++;
			if ((!upperOnly || (c >= 'A'.code && c <= 'Z'.code)) && !dotBefore(source, start))
				out.push({ name: source.substring(start, i), at: start });
		}
		return out;
	}

	/**
	 * The spans of `source` that are not code — its comments and the TEXT of its literals, an interpolation hole left out
	 * (`InertRegions`) — sorted by start; the whole literals when the source does not parse.
	 */
	public static function inertSpans(source: String, plugin: GrammarPlugin): Array<Span> {
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		final out: Array<Span> = tree == null
			? [for (r in regions) new Span(r.from, r.to)]
			: InertRegions.of(tree, regions, plugin.refShape());
		out.sort((a, b) -> a.from - b.from);
		return out;
	}

	/**
	 * Every string literal of `source` whose content IS the package `pkg` or ends with `.<its last segment>` — a package
	 * name held as a value, which code joins to a module name at run time (`pk + '.A'`) out of any token rewrite's sight.
	 */
	public static function stringsNamingPackage(source: String, regions: Array<LexRegion>, pkg: String): Array<Int> {
		final last: String = '.${pkg.substr(pkg.lastIndexOf('.') + 1)}';
		final out: Array<Int> = [];
		for (r in regions) if (r.kind == LexRegionKind.StringLit && r.to - r.from >= 2) {
			final content: String = source.substring(r.from + 1, r.to - 1);
			if (content == pkg || content.endsWith(last)) out.push(r.from);
		}
		return out;
	}

	/** Whether the nearest non-blank character before `at` is a dot — a member or a qualified path segment. */
	private static function dotBefore(source: String, at: Int): Bool {
		var j: Int = at - 1;
		while (j >= 0 && source.isSpace(j)) j--;
		return j >= 0 && source.fastCodeAt(j) == '.'.code;
	}

}
