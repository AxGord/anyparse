package anyparse.grammar.haxe;

import anyparse.core.Doc;
import anyparse.format.CommentStyle;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

/**
 * Plugin-level adapter for captured block-comment bodies.
 *
 * Lives in the Haxe format plugin package — NOT in the macro core or
 * the generic runtime. `BlockComment` AST is `{content:String}` —
 * opaque text between `/*` and `*\/`. The adapter dispatches on
 * `opt.commentStyle`:
 *
 *  - `Verbatim` (default) — content round-trips byte-identical.
 *    Adapter routes through `BlockCommentWriter` which emits the
 *    content as a single `Text` Doc — newlines inside the content
 *    are preserved as raw `\n` bytes, no nest indent is layered on.
 *  - `Plain` / `Javadoc` / `JavadocNoStars` — opt-in canonicalization.
 *    Adapter splits content into lines, strips wrap-adjacent and per-
 *    line `*` markers, common-prefix-reduces leading whitespace, and
 *    emits a Doc with one `Line('\n')` (hardline) per inter-line
 *    boundary — the surrounding writer's `Nest` context applies its
 *    indent to each interior line and to the close, so a comment in
 *    a class member position gets its lines aligned with the member's
 *    indent column. An additional `Nest(<one-indent-unit>)` wraps the
 *    interior so content sits one indent level deeper than the wrap
 *    delimiters.
 */
class HaxeCommentNormalizer {

	public static function processCapturedBlockComment(content:String, opt:WriteOptions):Doc {
		final parsed:Null<BlockComment> = try BlockCommentParser.parse(content)
			catch (_:haxe.Exception) null;
		if (parsed == null) return Text(content);
		if (opt.commentStyle == CommentStyle.Verbatim) {
			return BlockCommentWriter.writeDoc(parsed, opt);
		}
		return canonicalDoc(parsed.content, opt);
	}

	/**
	 * Build a Doc for canonical (`Plain` / `Javadoc` / `JavadocNoStars`)
	 * comment output. The interior is wrapped in `Nest(_cols, …)` so
	 * surrounding-context indent + `_cols` lines up the body one level
	 * deeper than the wrap. Each interior boundary uses `Line('\n')`
	 * (hardline) so the renderer applies the surrounding nest's indent.
	 */
	private static function canonicalDoc(source:String, opt:WriteOptions):Doc {
		final wantStars:Bool = opt.commentStyle == CommentStyle.Javadoc;
		final wrapDoc:Bool = opt.commentStyle == CommentStyle.Javadoc
			|| opt.commentStyle == CommentStyle.JavadocNoStars;
		final indentUnit:String = opt.indentChar == IndentChar.Tab
			? '\t'
			: StringTools.rpad('', ' ', opt.indentSize);

		final lines:Array<{ws:String, content:String}> = stripMarkers(source.split('\n'));
		// Exclude `firstInline` line 0 from common-prefix compute — its
		// ws is the post-marker separator (typically empty after strip),
		// not real indentation. Without this, source `/** first\n\t    second */`
		// would compute commonPrefix=`` (from line 0's empty ws), forcing
		// line 1's `\t    ` into relWs and adding it on top of the bake-in
		// indent, yielding triple-indented output.
		final firstInline:Bool = lines.length > 0 && lines[0].content.length > 0;
		final commonLen:Int = commonPrefixLen(lines, firstInline);
		final last:Int = lines.length - 1;

		// Build interior line texts. For `Javadoc`, the per-line ` * `
		// marker provides the visual indent inside the comment, so the
		// line text starts with ` * `. For `Plain` / `JavadocNoStars`,
		// the line text starts with one bake-in indent unit so the
		// content sits one level deeper than the wrap delimiters
		// (whose indent comes from the surrounding writer's nest).
		// Fully-blank first / last lines are dropped so wrap
		// delimiters sit on their own lines.
		final interior:Array<String> = [];
		for (i in 0...lines.length) {
			final p = lines[i];
			if ((i == 0 || i == last) && p.content.length == 0) continue;
			final relWs:String = p.ws.length > commonLen ? p.ws.substr(commonLen) : '';
			if (wantStars) {
				interior.push(p.content.length > 0 ? ' * ' + relWs + p.content : ' *');
			} else {
				interior.push(indentUnit + relWs + p.content);
			}
		}

		final docs:Array<Doc> = [Text(wrapDoc ? '/**' : '/*')];
		for (s in interior) {
			docs.push(Line('\n'));
			docs.push(Text(s));
		}
		docs.push(Line('\n'));
		docs.push(Text(wrapDoc ? '**/' : '*/'));
		return Concat(docs);
	}

	/**
	 * Per-line strip: `<ws> <stars*> <space?> <content> <stars*>` —
	 * unifies wrap-adjacent `*` runs (line 0 leading, line last
	 * trailing) and javadoc per-line ` * ` markers under one rule.
	 * Returns each line's effective `ws` (whitespace before any
	 * marker) and rtrim'd `content` (after marker + separator).
	 */
	private static function stripMarkers(lines:Array<String>):Array<{ws:String, content:String}> {
		final out:Array<{ws:String, content:String}> = [];
		for (i in 0...lines.length) {
			final raw:String = lines[i];
			final ws:String = leadingWs(raw);
			var rest:String = raw.substr(ws.length);
			var starEnd:Int = 0;
			while (starEnd < rest.length && StringTools.fastCodeAt(rest, starEnd) == '*'.code) starEnd++;
			if (starEnd > 0) {
				rest = rest.substr(starEnd);
				if (rest.length > 0 && StringTools.fastCodeAt(rest, 0) == ' '.code) rest = rest.substr(1);
			}
			var trailEnd:Int = rest.length;
			while (trailEnd > 0 && StringTools.fastCodeAt(rest, trailEnd - 1) == '*'.code) trailEnd--;
			rest = rest.substring(0, trailEnd);
			out.push({ws: ws, content: StringTools.rtrim(rest)});
		}
		return out;
	}

	/**
	 * Common-prefix length across non-blank lines' leading whitespace.
	 * Used to strip the source's outer indent so the canonical output
	 * starts content at column 0 (relative; the surrounding writer's
	 * `Nest` adds back the target indent).
	 */
	private static function commonPrefixLen(lines:Array<{ws:String, content:String}>, excludeFirstInline:Bool):Int {
		var commonPrefix:String = '';
		var havePrefix:Bool = false;
		for (i in 0...lines.length) {
			if (i == 0 && excludeFirstInline) continue;
			if (lines[i].content.length == 0) continue;
			final ws:String = lines[i].ws;
			if (!havePrefix) {
				commonPrefix = ws;
				havePrefix = true;
			} else {
				final lim:Int = commonPrefix.length < ws.length ? commonPrefix.length : ws.length;
				var j:Int = 0;
				while (j < lim && StringTools.fastCodeAt(commonPrefix, j) == StringTools.fastCodeAt(ws, j)) j++;
				commonPrefix = commonPrefix.substr(0, j);
			}
		}
		return commonPrefix.length;
	}

	private static function leadingWs(s:String):String {
		var i:Int = 0;
		while (i < s.length) {
			final c:Int = StringTools.fastCodeAt(s, i);
			if (c != ' '.code && c != '\t'.code) break;
			i++;
		}
		return s.substr(0, i);
	}

	/**
	 * Normalize a captured single-line `//…` comment for emission.
	 *
	 * Mirrors haxe-formatter's `MarkTokenText.printCommentLine`:
	 *  - body matches `^[/\*\-\s]+` (decoration runs like `//*****`,
	 *    `//---------`, `////`, or already-spaced bodies) → keep tight,
	 *    rtrim trailing whitespace
	 *  - `addSpace == true` → emit `// <trimmed body>` (insert one
	 *    space after `//`)
	 *  - `addSpace == false` → emit `//<trimmed body>` (knob off:
	 *    no leading-space pass)
	 *
	 * `verbatim` is the captured string WITH the `//` delimiter
	 * (`leadingComments[i]` and the `collectTrailingFull` close-trail
	 * slot store it that way). For the body-only `collectTrailing`
	 * trailing form, callers pass `'//' + body`.
	 *
	 * Non-`//` input (block comment, plain text, anything else) is
	 * returned untouched — the helper short-circuits so callers can
	 * route every captured trivia string through here without a
	 * type-tag dispatch.
	 */
	public static function normalizeLineComment(verbatim:String, addSpace:Bool):String {
		if (!StringTools.startsWith(verbatim, '//')) return verbatim;
		final body:String = verbatim.substr(2);
		if (isDecorationPrefix(body)) return '//' + StringTools.rtrim(body);
		final trimmed:String = StringTools.trim(body);
		return addSpace ? '// ' + trimmed : '//' + trimmed;
	}

	private static function isDecorationPrefix(body:String):Bool {
		if (body.length == 0) return false;
		final c:Int = StringTools.fastCodeAt(body, 0);
		return c == '/'.code || c == '*'.code || c == '-'.code
			|| c == ' '.code || c == '\t'.code || c == '\r'.code;
	}
}
