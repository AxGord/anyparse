package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Text search-and-replace scoped to COMMENT bodies — the write-twin of `lit`
 * (which finds text in comments), as `rewrite` is the write-twin of `search`.
 * `rewrite` only reaches AST nodes; comments are trivia and never appear in the
 * parse tree, so neither `rewrite` nor `set-comment` (one block, whole-text)
 * can do a bulk find/replace across comments. This fills that gap.
 *
 * Every comment body (located by `RefactorSupport.collectCommentTokens`, which
 * skips string literals) is searched: in literal mode `find` is a substring and
 * `replace` is verbatim; in `regex` mode `find` is an `EReg` and `replace` is a
 * template where `${0}` / `${1}` / `${N}` expand to capture group N,
 * `${N+K}` / `${N-K}` shift group N (an integer) by K, and `$$` is a literal
 * `$`. Only comment bodies change — code and the comment delimiters are never
 * touched. The result is canonical + re-parse-validated via
 * `RefactorSupport.canonicalize` (canonical-gated unless `reformat`), so a
 * replacement that would break the parse is rejected.
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class CommentRewrite {

	/**
	 * Rewrite text inside every comment of `source`. Returns `Ok(rewritten)`
	 * (unchanged when nothing matched) or an `Err` describing the failure (the
	 * source does not parse, an empty / bad pattern, or a result that does not
	 * parse).
	 */
	public static function rewrite(
		source: String, find: String, replace: String, regex: Bool, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (find.length == 0) return Err('find pattern is empty');

		try
			plugin.parseFile(source)
		catch (exception: ParseError)
			return Err('source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('source does not parse: ${exception.message}');

		var ereg: Null<EReg> = null;
		if (regex) {
			try
				ereg = new EReg(find, 'g')
			catch (exception: Exception)
				return Err('invalid regex: ${exception.message}');
		}
		final compiled: Null<EReg> = ereg;

		final edits: Array<{ span: Span, text: String }> = [];
		try {
			for (tok in RefactorSupport.collectCommentTokens(source)) {
				final bodySpan: Span = RefactorSupport.commentBody(source, tok);
				final body: String = source.substring(bodySpan.from, bodySpan.to);
				final next: String = compiled != null
					? compiled.map(body, m -> expandGroups(replace, m))
					: literalReplace(body, find, replace);
				if (next != body) edits.push({ span: bodySpan, text: next });
			}
		} catch (exception: Exception)
			return Err(exception.message);

		return edits.length == 0 ? Ok(source) : RefactorSupport.canonicalize(source, edits, reformat, plugin, optsJson);
	}

	/**
	 * Expand a `regex`-mode replacement template against the active match `m`:
	 * `$$` becomes `$`; `$<digits>` / `${<digits>}` a capture group; `${N+K}` /
	 * `${N-K}` group N (an integer) shifted by K. Throws on a group the pattern
	 * does not capture, a non-integer group under a shift, or a malformed
	 * brace spec — the caller turns the throw into an `Err`.
	 */
	private static function expandGroups(template: String, m: EReg): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = template.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(template, i);
			if (c != '$'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			if (i + 1 < n && StringTools.fastCodeAt(template, i + 1) == '$'.code) {
				buf.addChar('$'.code);
				i += 2;
				continue;
			}
			if (i + 1 < n && StringTools.fastCodeAt(template, i + 1) == '{'.code) {
				final close: Int = template.indexOf('}', i + 2);
				if (close < 0) throw new Exception('unterminated brace in replacement template');
				buf.add(expandSpec(template.substring(i + 2, close), m));
				i = close + 1;
				continue;
			}
			var j: Int = i + 1;
			while (j < n && isDigit(StringTools.fastCodeAt(template, j))) j++;
			if (j == i + 1) {
				buf.addChar('$'.code);
				i++;
				continue;
			}
			buf.add(groupValue(Std.parseInt(template.substring(i + 1, j)), m));
			i = j;
		}
		return buf.toString();
	}

	/** `N` (group source) or `N+K` / `N-K` (integer group N shifted by K). */
	private static function expandSpec(spec: String, m: EReg): String {
		final plus: Int = spec.indexOf('+');
		final minus: Int = spec.indexOf('-');
		final opAt: Int = plus >= 0 ? plus : minus;
		if (opAt <= 0) return groupValue(Std.parseInt(spec), m);
		final num: Null<Int> = Std.parseInt(spec.substring(opAt + 1));
		if (num == null) throw new Exception('bad shift in template spec "$spec"');
		final shift: Int = plus >= 0 ? num : -num;
		final raw: String = groupValue(Std.parseInt(spec.substring(0, opAt)), m);
		final value: Null<Int> = Std.parseInt(StringTools.trim(raw));
		if (value == null) throw new Exception('template group is not an integer: "$raw"');
		return '${value + shift}';
	}

	/**
	 * Source of capture group `idx` for the active match; empty for an
	 * unmatched optional group. Throws when the spec is not a number or the
	 * pattern has no such group.
	 */
	private static function groupValue(idx: Null<Int>, m: EReg): String {
		if (idx == null) throw new Exception('bad group reference in replacement template');
		final index: Int = idx;
		var matched: Null<String>;
		try
			matched = m.matched(index)
		catch (exception: Exception)
			throw new Exception('replacement references group $index which the pattern does not capture');
		return matched ?? '';
	}

	private static inline function isDigit(c: Int): Bool {
		return c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Literal find/replace inside a comment body, matching ACROSS the body's line
	 * continuations: the body is normalized (each `\n` + ` * ` doc prefix folded to
	 * one space) for the search, and every non-overlapping match is projected back
	 * to its span in the original body via the index map — so a phrase wrapped over
	 * two ` * ` lines is found and replaced. Consuming the continuation between the
	 * two lines is harmless: the spliced replacement is re-wrapped by the writer.
	 */
	private static function literalReplace(body: String, find: String, replace: String): String {
		final normalized: { text: String, map: Array<Int> } = RefactorSupport.normalizeCommentBody(body);
		final norm: String = normalized.text;
		final map: Array<Int> = normalized.map;
		final buf: StringBuf = new StringBuf();
		var cursor: Int = 0;
		var hit: Int = norm.indexOf(find, 0);
		while (hit >= 0) {
			buf.add(body.substring(cursor, map[hit]));
			buf.add(replace);
			cursor = map[hit + find.length];
			hit = norm.indexOf(find, hit + find.length);
		}
		buf.add(body.substring(cursor));
		return buf.toString();
	}

}
