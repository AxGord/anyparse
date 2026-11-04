package anyparse.check.oracle;

import anyparse.query.InertRegions;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Whether the sources a compile parsed READ a define — the one answer to "may a define a probe adds to a compile
 * change what the build does". A source reads it when a conditional-compilation directive or any other code names it,
 * when a call of a define reader (`defined`, `definedValue`, `getDefine`) takes its name as the whole of a literal, and
 * whenever it calls `getDefines`, which hands a macro every name at once. Comments and the text of a literal read
 * nothing (`InertRegions`). Out of reach: a name that comes to a reader by any way but a literal argument — a constant
 * (`Context.defined(K)` with `K` holding the name), a variable, a string a macro assembles — since a whole literal of
 * the name elsewhere is not counted (a list of defines, such as a probe's own, reads nothing). A source that cannot be
 * read or parsed counts as a reader, so a doubt costs a compile, never a wrong answer.
 */
@:nullSafety(Strict)
final class DefineReads {

	/** The macro API that hands every define at once. */
	private static inline final ALL_DEFINES: String = 'getDefines';

	/** The keyword a declaration of `ALL_DEFINES` opens with — the standard library's own, which reads nothing. */
	private static inline final DECLARATION: String = 'function';

	/** The macro API that reads one define by the name its first argument spells. */
	private static final READERS: Array<String> = ['defined', 'definedValue', 'getDefine'];

	/**
	 * Whether any of `paths` reads one of `names` (`reads`), each path read once per `known` — the verdicts a caller keeps
	 * for the paths it asked before, since several configurations of one run parse mostly the same files.
	 */
	public static function anyReads(paths: Array<String>, names: Array<String>, grammar: GrammarPlugin, known: Map<String, Bool>): Bool {
		if (names.length == 0) return false;
		for (path in paths) {
			var verdict: Null<Bool> = known[path];
			if (verdict == null) {
				final source: Null<String> = try sys.io.File.getContent(path) catch (exception: Exception) null;
				verdict = source == null || reads(source, names, grammar);
				known[path] = verdict;
			}
			if (verdict) return true;
		}
		return false;
	}

	/** Whether `source` reads one of the defines `names` (either spelling, `-` or `_`), as the class doc describes. */
	public static function reads(source: String, names: Array<String>, grammar: GrammarPlugin): Bool {
		final words: Array<String> = [ALL_DEFINES];
		for (name in names) for (s in spellings(name)) if (!words.contains(s)) words.push(s);
		if (!words.exists(w -> source.indexOf(w) >= 0)) return false;
		final root: Null<QueryNode> = try grammar.parseFile(source) catch (exception: Exception) null;
		if (root == null) return true;
		final regions: Array<LexRegion> = grammar.lexicalRegions(source);
		final comments: Array<Span> = SourceComments.collectCommentRegions(regions);
		final inert: Array<Span> = InertRegions.of(root, regions, grammar.refShape());
		for (word in words) {
			var at: Int = source.indexOf(word);
			while (at >= 0) {
				if (wordAt(source, at, word) && !inside(comments, at) && readAt(source, at, word, inert)) return true;
				at = source.indexOf(word, at + word.length);
			}
		}
		return false;
	}

	/** Both spellings of the define `name` — with `-` and with `_` — which the compiler takes for one define. */
	public static function spellings(name: String): Array<String> {
		final dashed: String = name.replace('_', '-');
		final underscored: String = name.replace('-', '_');
		return dashed == underscored ? [name] : [dashed, underscored];
	}

	/**
	 * Whether the occurrence of `word` at `at`, outside every comment, reads a define: in literal text only as the whole
	 * of a literal a define reader takes, in code always — save the declaration of `ALL_DEFINES` itself.
	 */
	private static function readAt(source: String, at: Int, word: String, inert: Array<Span>): Bool {
		final literal: Null<Span> = inert.find(s -> s.from <= at && at < s.to);
		return literal != null
			? word != ALL_DEFINES && wholeLiteral(source, literal, at, word.length) && readerBefore(source, at)
			: word != ALL_DEFINES || precedingWord(source, at) != DECLARATION;
	}

	/**
	 * Whether the `length` characters at `at` are the whole text of `literal`, the inert span holding them: one quote opens
	 * them and the same closes them, and the span reaches no further than those quotes — a name inside a longer literal,
	 * quoted there in turn, is that literal's text.
	 */
	private static function wholeLiteral(source: String, literal: Span, at: Int, length: Int): Bool {
		final open: String = at > 0 ? source.charAt(at - 1) : '';
		return (open == '\'' || open == '"')
			&& source.charAt(at + length) == open
			&& literal.from >= at - 1
			&& literal.to <= at + length + 1;
	}

	/** Whether the literal whose text starts at `at` is the first argument of a define reader's call. */
	private static function readerBefore(source: String, at: Int): Bool {
		final i: Int = backOverSpaces(source, at - 2);
		return i >= 0 && source.charAt(i) == '(' && READERS.contains(precedingWord(source, i));
	}

	/** The identifier that ends right before `at`, spaces between them skipped; empty when none does. */
	private static function precedingWord(source: String, at: Int): String {
		final end: Int = backOverSpaces(source, at - 1) + 1;
		var start: Int = end;
		while (start > 0 && SourceText.isIdentChar(source.fastCodeAt(start - 1))) start--;
		return source.substring(start, end);
	}

	/** The last offset at or before `at` that holds no space. */
	private static function backOverSpaces(source: String, at: Int): Int {
		var i: Int = at;
		while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) i--;
		return i;
	}

	/** Whether `word` at `at` is a whole word: no identifier character touches either end. */
	private static function wordAt(source: String, at: Int, word: String): Bool {
		final end: Int = at + word.length;
		return (at == 0 || !SourceText.isIdentChar(source.fastCodeAt(at - 1)))
			&& (end >= source.length || !SourceText.isIdentChar(source.fastCodeAt(end)));
	}

	private static function inside(spans: Array<Span>, at: Int): Bool {
		return spans.exists(s -> s.from <= at && at < s.to);
	}

}
