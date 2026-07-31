package anyparse.format.comment;

import anyparse.core.Doc;
import anyparse.format.CommentStyle;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

/**
 * Engine-level adapter for captured C-family block-comment bodies.
 *
 * Lives in `anyparse.format.comment` next to the shared `BlockComment`
 * grammar widget — any grammar (Haxe, AS3, JS, C/C++, Rust, …) wires
 * `processCapturedBlockComment` into its format singleton's
 * `defaultWriteOptions.blockCommentAdapter` and gets full block-
 * comment support (parse, write, indent canonicalization, opt-in
 * canonical styles) without any plugin code.
 *
 * Pipeline:
 *  - Parsing: `BlockCommentParser` (macro-generated from
 *    `BlockComment { lines:Array<BlockCommentLine> @:sep('\n') }`).
 *  - Assembly (Verbatim, indent-canonicalize path): macro writer
 *    `BlockCommentWriter.writeDoc` routes through `@:sep('\n')`
 *    hardline-join with hardlines BETWEEN elements only. The macro
 *    invokes `normalize` via the rule-level `@:fmt(preWrite(…))`
 *    hook on `BlockComment` — engine handles the dispatch, plugin
 *    code never calls `normalize` directly.
 *  - Assembly (Verbatim, byte-preserve path): `Text(content)` for
 *    single-line / firstInline / Javadoc-bodied shapes where
 *    common-prefix-reduce would mangle author intent.
 *  - Assembly (Plain / Javadoc / JavadocNoStars): `canonicalDoc`
 *    builds Doc directly with its own wrap shape (`/**` … ` *\/` for
 *    Javadoc, `/**` … `*\/` for JavadocNoStars, `/*` … `*\/` for
 *    Plain) and per-line ` * ` markers. Reached only for a MULTI-LINE
 *    DOC block — see `canonicalizable`; every other captured comment
 *    takes the Verbatim path whatever `opt.commentStyle` says.
 */
class BlockCommentNormalizer {

	/** The doc-comment opener the canonical styles are scoped to. */
	private static inline final DOC_OPEN: String = '/**';

	public static function processCapturedBlockComment(content: String, opt: WriteOptions): Doc {
		final parsed: Null<BlockComment> = try BlockCommentParser.parse(content) catch (_: haxe.Exception) null;
		if (parsed == null) return Text(content);
		if (opt.commentStyle != CommentStyle.Verbatim && canonicalizable(content)) return canonicalDoc(parsed, opt);
		// Parser's `@:sep('\n') @:trail('*/')` Star elides the trailing
		// separator: source `Xx\n*/` parses as N lines (not N+1 with an
		// empty trailing line). The writer therefore loses the `\n` that
		// would have placed `*/` on its own line. Detect the
		// `<content>\n*/` close-on-own-line shape and append a synthetic
		// empty line so normalize's `body == '' last line` branch routes
		// to the canonical ` */` close pad.
		if (StringTools.endsWith(content, '\n*/') && parsed.lines.length > 0) {
			final lastBody: String = parsed.lines[parsed.lines.length - 1].body;
			if (lastBody.length > 0) parsed.lines.push({ ws: '', body: '' });
		}
		final lines: Array<BlockCommentLine> = parsed.lines;
		return lines.length <= 1
			? Text(content)
			: isJavadocStyle(lines)
				? javadocBytePreserveDoc(content, parsed)
				: isFirstInlineNested(lines) ? firstInlineRebuildDoc(parsed, opt) : BlockCommentWriter.writeDoc(parsed, opt);
	}

	/**
	 * Engine-wired AST→AST hook for the Verbatim emit path.
	 *
	 * Invoked by the macro writer via the rule-level
	 * `@:fmt(preWrite(BlockCommentNormalizer.normalize))` meta on
	 * `BlockComment` — no plugin call site, the engine handles the
	 * dispatch. Returns a new `BlockComment` with each line's `ws`
	 * field rewritten so the macro `@:sep('\n')` hardline-join's
	 * surrounding nest lands each line at the correct target column.
	 *
	 * Source common-prefix across non-edge non-decoration non-blank
	 * lines is reduced; per-line residual whitespace beyond common
	 * survives. When source common is strictly deeper than the wrap
	 * (closing line's structural ws), content was authored "one
	 * level deeper than the wrap delimiters" — re-emit one indent
	 * unit deeper at target. Otherwise (close inline with content,
	 * common == close ws) emit at wrap level so the close stays
	 * aligned.
	 *
	 * Per-line newWs:
	 *  - Line 0: keep source ws (separator after `/*` for inline
	 *    content like `/* foo\n…`); blank line 0 → `''`.
	 *  - Last line decoration (`**\/` etc.): `''` so it aligns with
	 *    the wrap.
	 *  - Last line empty body (`\n*\/` close on own line): `' '`
	 *    canonical pad before `*\/`. Surrounding nest is applied by
	 *    the renderer via `Line('\n')`.
	 *  - Last line non-empty body (`}*\/` style): structural close
	 *    ws preserved (caller authored the close column).
	 *  - Interior content: `(shouldBake ? indentUnit : '') + relWs`.
	 *  - Interior blank: `''`.
	 */
	public static function normalize(comment: BlockComment, opt: WriteOptions): Null<BlockComment> {
		final lines: Array<BlockCommentLine> = comment.lines;
		if (lines.length <= 1) return null;

		final decoFlags: Array<Bool> = [for (l in lines) isAllStars(l.body)];
		final last: Int = lines.length - 1;
		var commonPrefix: Null<String> = null;
		for (i in 0...lines.length) {
			final body: String = lines[i].body;
			final ws: String = lines[i].ws;
			if (body.length == 0) continue;
			if (i == 0) continue;
			// Last line is the structural close (`*\/` or `<content>*\/`),
			// not interior content. Its ws represents the wrap's structural
			// indent, not the comment body's indent depth.
			if (i == last) continue;
			commonPrefix = commonPrefix == null ? ws : commonPrefixOf(commonPrefix, ws);
		}
		final commonLen: Int = (commonPrefix ?? '').length;
		final closingWs: String = lines[last].ws;
		final closeStructLen: Int = structuralCloseLen(closingWs);
		final structuralClose: String = closingWs.substr(0, closeStructLen);
		final shouldBake: Bool = commonLen > closeStructLen;
		final indentUnit: String = indentUnitOf(opt);

		final newLines: Array<BlockCommentLine> = [];
		for (i in 0...lines.length) {
			final body: String = lines[i].body;
			final ws: String = lines[i].ws;
			var newWs: String;
			if (i == 0) {
				newWs = body.length > 0 ? ws : '';
			} else if (i == last) {
				newWs = if (decoFlags[i])
					''
				else if (body.length == 0)
					' '
				else
					structuralClose;
			} else if (body.length == 0) {
				newWs = '';
			} else {
				final relWs: String = ws.length > commonLen ? ws.substr(commonLen) : '';
				newWs = shouldBake ? indentUnit + relWs : relWs;
			}
			newLines.push({ ws: newWs, body: body });
		}
		return { lines: newLines };
	}

	/**
	 * Whether captured block-comment `content` is eligible for the
	 * canonical (`Plain` / `Javadoc` / `JavadocNoStars`) rewrite. Two
	 * gates, both narrowing the styles to what they were meant for —
	 * re-shaping a doc block that already spans lines:
	 *
	 *  - DOC ONLY. The content must open `/**`. Canonicalizing a plain
	 *    `/* … *\/` would emit `/** … *\/` and mint a haxedoc where the
	 *    author wrote none, changing what the compiler and every doc
	 *    generator extract from the declaration below it.
	 *  - MULTI-LINE ONLY, measured as a PHYSICAL newline in the source
	 *    text — NOT as a parsed line count. The parser's
	 *    `@:sep('\n') @:trail('*\/')` Star elides the trailing separator,
	 *    so `/** doc\n*\/` parses as ONE line while genuinely spanning
	 *    two; counting parsed lines would decline it. A doc the author
	 *    fitted on one physical line stays on one line — expanding it
	 *    into a three-line block is churn, not canonicalization.
	 *
	 * The newline gate duplicates `WriterCodegen.leadingCommentDocRun`,
	 * which already returns before reaching the adapter when the content
	 * holds no newline (so the degenerate `/**\/` never arrives here).
	 * It is restated because the adapter is a public engine seam any
	 * grammar may call directly.
	 *
	 * Everything the gates decline falls through to the Verbatim path,
	 * whose byte behaviour is identical to `commentStyle: Verbatim`.
	 */
	private static function canonicalizable(content: String): Bool {
		return content.indexOf('\n') >= 0 && StringTools.startsWith(content, DOC_OPEN);
	}

	/**
	 * Build a Doc for javadoc-bodied verbatim comments (`isJavadocStyle`)
	 * that lets the surrounding writer's nest land on each interior line.
	 *
	 * Splits source content on `\n`, strips the closing line's structural
	 * indent prefix from each interior segment (so already-nested source
	 * at depth N doesn't double-indent under target nest depth N), and
	 * joins segments with `Line('\n')`. Wrap delimiters (`/*`, `*\/`)
	 * ride on segment 0 and the last segment respectively — they are
	 * part of `content`.
	 *
	 * Scoped to javadoc-style (each non-edge non-blank line body starts
	 * with `*`) because that style anchors the visual depth to surrounding
	 * nest by convention. The other byte-preserve cases — `firstInline`-
	 * nested (where authors place subsequent lines at source-absolute
	 * columns relative to the open delimiter, not surrounding nest) and
	 * single-line — keep the literal `Text(content)` path.
	 *
	 * Replaces a former `Text(content)` shortcut whose embedded `\n`
	 * chars bypassed the renderer's lazy-indent path: a col-0 javadoc
	 * comment dropped into a tab-indented context emitted at col 0
	 * instead of following the surrounding nest.
	 */
	private static function javadocBytePreserveDoc(content: String, comment: BlockComment): Doc {
		final segments: Array<String> = content.split('\n');
		if (segments.length <= 1) return Text(content);
		final lines: Array<BlockCommentLine> = comment.lines;
		final closeLine: BlockCommentLine = lines[lines.length - 1];
		final closingWs: String = closeLine.ws;
		// A decoration close (all-stars body, the `**` of `**/`) sits AT the base
		// column with no pad — its whole ws is structural base indent, so strip it
		// in full. A bare `*/` close (empty body) carries a single-space pad before
		// the delimiter that must survive (it mirrors the ` * ` continuation offset);
		// structuralCloseLen drops that pad space. Treating every close as padded
		// over-kept one space on each space-indented javadoc continuation (issue_141).
		final closeIsDecoration: Bool = isAllStars(closeLine.body);
		final closeStructLen: Int = closeIsDecoration ? closingWs.length : structuralCloseLen(closingWs);
		final closeStruct: String = closingWs.substr(0, closeStructLen);
		final docs: Array<Doc> = [Text(segments[0])];
		for (i in 1...segments.length) {
			final raw: String = segments[i];
			final stripped: String = closeStructLen > 0 && StringTools.startsWith(raw, closeStruct) ? raw.substr(closeStructLen) : raw;
			docs.push(Line('\n'));
			docs.push(Text(stripped));
		}
		return Concat(docs);
	}

	/**
	 * `firstInline` shape — line 0 carries body content (not pure `*` decoration) —
	 * IN A NESTED CONTEXT, detected via `structuralCloseLen(lastWs) > 0`. When the
	 * closing `*\/` line carries structural indent beyond a canonical single-space
	 * close pad, the wrap is at depth > 0 and source columns are nest-relative; at
	 * top-level (close structurally at column 0) source columns ARE canonical depth
	 * and `BlockCommentWriter.writeDoc` (with `@:sep('\n')` hardline-join + AST→AST
	 * `normalize`) rewrites them.
	 *
	 * Routes to `firstInlineRebuildDoc` which mirrors haxe-formatter's
	 * `MarkTokenText.printComment` rule for non-startsWithStar comments: strip the
	 * common interior leading-ws prefix, re-emit each interior line at `+1 indent
	 * over surrounding nest`. Replaces the former `Text(content)` byte-preserve
	 * path that left source-relative tab counts unchanged — issue_208 / issue_139
	 * style fixtures lost the deepening continuation indent.
	 */
	private static function isFirstInlineNested(lines: Array<BlockCommentLine>): Bool {
		final firstBody: String = lines[0].body;
		if (firstBody.length == 0 || isAllStars(firstBody)) return false;
		final lastWs: String = lines[lines.length - 1].ws;
		return structuralCloseLen(lastWs) > 0;
	}

	/**
	 * Build a Doc for non-javadoc firstInline-bodied multi-line comments in nested
	 * context. Mirrors haxe-formatter's `MarkTokenText.printComment` for
	 * `startsWithStar = false`:
	 *
	 *  - Strip the common leading-ws prefix shared by interior lines (and the last
	 *    line if its body doesn't match `^\s*(\**$|\})` — i.e. content-bearing
	 *    last lines participate in the prefix calc).
	 *  - Line 0: keep as-is (`Text("/*" + ws + body)`).
	 *  - Interior lines: emit `Line('\n') + Text(indentUnit + strippedWs + body)`.
	 *    `indentUnit` is the `+1` over surrounding nest; surrounding nest contributes
	 *    its depth via the renderer's lazy-indent on `Line('\n')`.
	 *  - Blank interior lines: emit only `Line('\n')` so the renderer's
	 *    consecutive-Line discard suppresses trailing whitespace.
	 *  - Last line — three cases:
	 *      (a) `^\s*\}` style → trim, no extra indent (close-brace stays aligned
	 *          with the wrap column).
	 *      (b) `^\s*\*` star-prefixed → no extra indent, leave star alignment.
	 *      (c) other content → `+1 indent`, rtrim then add trailing space if
	 *          !endsWith('*') so `*\/` doesn't collide with last char.
	 *  - Close `*\/` appended as `Text('*\/')`.
	 */
	private static function firstInlineRebuildDoc(comment: BlockComment, opt: WriteOptions): Doc {
		final lines: Array<BlockCommentLine> = comment.lines;
		final last: Int = lines.length - 1;
		final lastBody: String = lines[last].body;
		final lastIsClosingBrace: Bool = lastBody.length > 0 && StringTools.fastCodeAt(lastBody, 0) == '}'.code;
		final lastIsDecoOrEmpty: Bool = lastBody.length == 0 || isAllStars(lastBody);
		final includeLastInPrefix: Bool = !lastIsClosingBrace && !lastIsDecoOrEmpty;

		var commonPrefix: Null<String> = null;
		for (i in 1...lines.length) if (!(i == last && !includeLastInPrefix)) {
			final body: String = lines[i].body;
			if (body.length == 0) continue;
			final ws: String = lines[i].ws;
			commonPrefix = commonPrefix == null ? ws : commonPrefixOf(commonPrefix, ws);
		}
		final cp: String = commonPrefix ?? '';
		final cpLen: Int = cp.length;

		final indentUnit: String = indentUnitOf(opt);

		final docs: Array<Doc> = [Text('/*${lines[0].ws}${lines[0].body}')];

		for (i in 1...lines.length) {
			final ws: String = lines[i].ws;
			final body: String = lines[i].body;

			if (body.length == 0) {
				docs.push(Line('\n'));
				continue;
			}

			final stripWs: String = cpLen > 0 && StringTools.startsWith(ws, cp) ? ws.substr(cpLen) : ws;

			if (i == last) {
				if (lastIsClosingBrace) {
					docs.push(Line('\n'));
					docs.push(Text(StringTools.trim(stripWs + body)));
				} else if (StringTools.fastCodeAt(body, 0) == '*'.code) {
					docs.push(Line('\n'));
					docs.push(Text(stripWs + body));
				} else {
					var line: String = StringTools.rtrim(indentUnit + stripWs + body);
					if (!StringTools.endsWith(line, '*')) line += ' ';
					docs.push(Line('\n'));
					docs.push(Text(line));
				}
			} else {
				docs.push(Line('\n'));
				docs.push(Text(indentUnit + stripWs + body));
			}
		}

		docs.push(Text('*/'));
		return Concat(docs);
	}

	private static inline function indentUnitOf(opt: WriteOptions): String {
		return opt.indentChar == IndentChar.Tab ? '\t' : StringTools.rpad('', ' ', opt.indentSize);
	}

	private static function commonPrefixOf(a: String, b: String): String {
		final lim: Int = a.length < b.length ? a.length : b.length;
		var j: Int = 0;
		while (j < lim && StringTools.fastCodeAt(a, j) == StringTools.fastCodeAt(b, j)) j++;
		return a.substr(0, j);
	}

	/**
	 * Structural indent length of a closing line's ws — `ws.length`
	 * minus a single trailing space (canonical close pad before
	 * `*\/`). Distinguishes `\t *\/` (1 char structural) from `*\/`
	 * with single-space pad (0 char structural).
	 */
	private static function structuralCloseLen(ws: String): Int {
		final len: Int = ws.length;
		return len > 0 && StringTools.fastCodeAt(ws, len - 1) == ' '.code ? len - 1 : len;
	}

	/**
	 * Heuristic: every non-edge, non-blank interior line's body
	 * starts with `*`, indicating per-line ` * ` markers. Common-
	 * prefix-reduce on these would consume the marker space and
	 * destroy the visual marker column on emit.
	 */
	private static function isJavadocStyle(lines: Array<BlockCommentLine>): Bool {
		if (lines.length < 3) return false;
		final last: Int = lines.length - 1;
		var contentCount: Int = 0;
		var starredCount: Int = 0;
		for (i in 1...last) {
			final body: String = lines[i].body;
			if (body.length == 0) continue;
			contentCount++;
			if (StringTools.fastCodeAt(body, 0) == '*'.code) starredCount++;
		}
		return contentCount > 0 && starredCount == contentCount;
	}

	private static function isAllStars(s: String): Bool {
		if (s.length == 0) return false;
		for (i in 0...s.length) {
			if (StringTools.fastCodeAt(s, i) != '*'.code) return false;
		}
		return true;
	}

	/**
	 * Build a Doc for canonical (`Plain` / `Javadoc` / `JavadocNoStars`)
	 * comment output. Picks its own wrap shape (`/*`/`*\/` for Plain,
	 * `/**` plus ` *\/` for Javadoc and `*\/` for JavadocNoStars) and
	 * per-line markers, so it bypasses the macro writer's line-by-line
	 * emission. Each interior boundary uses `Line('\n')` so the renderer
	 * applies the surrounding nest's indent.
	 *
	 * A line that carried a ` * ` gutter marker re-emits at the canonical
	 * column with NO residual whitespace: its source `ws` was the marker's
	 * own column, not the text's depth. Only unmarked lines — tab-style
	 * bodies, where the whitespace really is the author's indentation —
	 * keep what they have beyond the block's common prefix.
	 *
	 * A blank interior line emits the bare marker (` *`) under Javadoc and
	 * NOTHING under the star-less styles: an `indentUnit` on an empty line
	 * would be trailing whitespace.
	 *
	 * A doc whose interior reduces to exactly ONE content line COLLAPSES to
	 * the one-line form — see `collapsedDoc`.
	 */
	private static function canonicalDoc(comment: BlockComment, opt: WriteOptions): Doc {
		final wantStars: Bool = opt.commentStyle == CommentStyle.Javadoc;
		final wrapDoc: Bool = opt.commentStyle == CommentStyle.Javadoc || opt.commentStyle == CommentStyle.JavadocNoStars;
		final indentUnit: String = indentUnitOf(opt);

		final stripped: Array<StrippedLine> = stripMarkers(comment.lines);
		final firstInline: Bool = stripped.length > 0 && stripped[0].content.length > 0;
		final commonLen: Int = commonPrefixLen(stripped, firstInline);
		final last: Int = stripped.length - 1;

		final interior: Array<String> = [];
		final contents: Array<String> = [];
		for (i in 0...stripped.length) {
			final p: StrippedLine = stripped[i];
			if ((i == 0 || i == last) && p.content.length == 0) continue;
			final relWs: String = p.marker || p.ws.length <= commonLen ? '' : p.ws.substr(commonLen);
			if (p.content.length == 0) {
				interior.push(wantStars ? ' *' : '');
			} else {
				interior.push(wantStars ? ' * $relWs${p.content}' : indentUnit + relWs + p.content);
				contents.push(relWs + p.content);
			}
		}

		final docs: Array<Doc> = [Text(wrapDoc ? '/**' : '/*')];
		for (s in interior) {
			docs.push(Line('\n'));
			docs.push(Text(s));
		}
		docs.push(Line('\n'));
		// Javadoc's close carries one pad space so its `*` lands in the
		// same column as the interior ` * ` markers; the star-less styles
		// have no marker column to align with, so they close flush.
		docs.push(Text(wantStars ? ' */' : '*/'));
		final expanded: Doc = Concat(docs);
		return wrapDoc && contents.length == 1 ? collapsedDoc(contents[0], expanded, opt) : expanded;
	}

	/**
	 * The width-gated one-line form of a doc that carries a single content line:
	 * `/** <content> *\/` when it fits, the `expanded` multi-line Doc when it does not.
	 *
	 * The choice cannot be made here — the adapter is handed a comment, not a column, and
	 * the same block may be re-emitted at any depth — so it is deferred to the renderer via
	 * `IfLineExceeds`, whose probe is `col + flatTokenWidth(flat) + rest-of-stack >= n`. The
	 * threshold is `lineWidth + 1` so a line landing EXACTLY on `lineWidth` still fits (the
	 * probe asks "reaches n", not "exceeds n").
	 *
	 * One-way by design: a multi-line doc collapses, a single-line doc is never expanded.
	 * The single-line result re-parses as a newline-free comment, which
	 * `WriterCodegen.leadingCommentDocRun` returns before ever reaching this adapter — so
	 * the collapse is a fixed point, not a step in a cycle.
	 *
	 * Scoped to the doc styles (`wrapDoc`). `Plain`'s one-line form would be `/* … *\/`,
	 * which is the doc-demotion this pass exists to avoid.
	 */
	private static function collapsedDoc(content: String, expanded: Doc, opt: WriteOptions): Doc {
		return IfLineExceeds(opt.lineWidth + 1, expanded, Text('/** $content */'));
	}

	private static function stripMarkers(lines: Array<BlockCommentLine>): Array<StrippedLine> {
		final out: Array<StrippedLine> = [];
		for (ln in lines) {
			final body: String = ln.body;
			// A body of nothing but stars is WRAP DECORATION — the `**` left by a
			// `**\/` close, a `***` rule line, the `*` of a bare `/**` open. It
			// carries no content and no indent information.
			if (isAllStars(body)) {
				out.push({ ws: ln.ws, content: '', marker: true });
				continue;
			}
			final run: Int = leadingStarRun(body);
			// A leading star run is the ` * ` GUTTER MARKER only when WHITESPACE
			// follows it. Without that test a tab-style content line opening
			// `**bold**` loses its first run and re-emits as `bold**`. The
			// whitespace is any of space / tab / CR, not the literal space alone:
			// on a CRLF file the last gutter line of `/**\r\n * a\r\n */` ends
			// `*\r`, and a `*\ttext` gutter is legal too — testing for `' '` there
			// classified the marker as content and emitted a spurious ` * *` row.
			// `isAllStars` already returned for a body of pure stars, so the run is
			// always shorter than the body here.
			final marker: Bool = run > 0 && isSpace(StringTools.fastCodeAt(body, run));
			final rest: String = marker ? body.substr(run + 1) : body;
			// Trailing stars are the AUTHOR'S — `**bold**`, a backticked `/**`, a
			// prose `the unused-*` all end in one. Only the all-stars decoration
			// above is delimiter, and it never reaches here.
			out.push({ ws: ln.ws, content: StringTools.rtrim(rest), marker: marker });
		}
		return out;
	}

	/** Whether `c` is comment-body whitespace — the separator a ` * ` gutter marker may carry. */
	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\r'.code;
	}

	/** The length of `body`'s leading run of `*`. */
	private static function leadingStarRun(body: String): Int {
		var i: Int = 0;
		while (i < body.length && StringTools.fastCodeAt(body, i) == '*'.code) i++;
		return i;
	}

	/**
	 * The length of the leading whitespace shared by the lines whose `ws` actually
	 * carries CONTENT INDENT — non-blank, and not gutter-marked. A ` * `-marked
	 * line's `ws` is the marker COLUMN (whatever the author aligned the star to),
	 * not the depth of the text after it; folding those columns into the common
	 * prefix left every marked line with stray residual whitespace as soon as one
	 * line in the block was indented differently from its siblings.
	 */
	private static function commonPrefixLen(lines: Array<StrippedLine>, excludeFirstInline: Bool): Int {
		var commonPrefix: Null<String> = null;
		for (i in 0...lines.length) if (i != 0 || !excludeFirstInline) {
			final line: StrippedLine = lines[i];
			if (line.marker || line.content.length == 0) continue;
			commonPrefix = commonPrefix == null ? line.ws : commonPrefixOf(commonPrefix, line.ws);
		}
		return (commonPrefix ?? '').length;
	}

}

/** One comment body line with its wrap markers removed: `marker` records whether it carried a ` * ` gutter. */
private typedef StrippedLine = { ws: String, content: String, marker: Bool };
