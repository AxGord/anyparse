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
 *    builds Doc directly with custom wrap shape (`/** … **\/`) and
 *    per-line ` * ` markers.
 */
class BlockCommentNormalizer {

	public static function processCapturedBlockComment(content:String, opt:WriteOptions):Doc {
		final parsed:Null<BlockComment> = try BlockCommentParser.parse(content)
			catch (_:haxe.Exception) null;
		if (parsed == null) return Text(content);
		if (opt.commentStyle == CommentStyle.Verbatim) {
			final lines:Array<BlockCommentLine> = parsed.lines;
			if (lines.length <= 1) return Text(content);
			if (isJavadocStyle(lines)) return javadocBytePreserveDoc(content, parsed);
			if (isFirstInlineNested(lines)) return firstInlineRebuildDoc(parsed, opt);
			return BlockCommentWriter.writeDoc(parsed, opt);
		}
		return canonicalDoc(parsed, opt);
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
	private static function javadocBytePreserveDoc(content:String, comment:BlockComment):Doc {
		final segments:Array<String> = content.split('\n');
		if (segments.length <= 1) return Text(content);
		final lines:Array<BlockCommentLine> = comment.lines;
		final closingWs:String = lines[lines.length - 1].ws;
		final closeStructLen:Int = structuralCloseLen(closingWs);
		final closeStruct:String = closingWs.substr(0, closeStructLen);
		final docs:Array<Doc> = [Text(segments[0])];
		for (i in 1...segments.length) {
			final raw:String = segments[i];
			final stripped:String = closeStructLen > 0 && StringTools.startsWith(raw, closeStruct)
				? raw.substr(closeStructLen)
				: raw;
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
	private static function isFirstInlineNested(lines:Array<BlockCommentLine>):Bool {
		final firstBody:String = lines[0].body;
		if (firstBody.length == 0 || isAllStars(firstBody)) return false;
		final lastWs:String = lines[lines.length - 1].ws;
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
	private static function firstInlineRebuildDoc(comment:BlockComment, opt:WriteOptions):Doc {
		final lines:Array<BlockCommentLine> = comment.lines;
		final last:Int = lines.length - 1;
		final lastBody:String = lines[last].body;
		final lastIsClosingBrace:Bool = lastBody.length > 0 && StringTools.fastCodeAt(lastBody, 0) == '}'.code;
		final lastIsDecoOrEmpty:Bool = lastBody.length == 0 || isAllStars(lastBody);
		final includeLastInPrefix:Bool = !lastIsClosingBrace && !lastIsDecoOrEmpty;

		var commonPrefix:Null<String> = null;
		for (i in 1...lines.length) {
			if (i == last && !includeLastInPrefix) continue;
			final body:String = lines[i].body;
			if (body.length == 0) continue;
			final ws:String = lines[i].ws;
			if (commonPrefix == null) {
				commonPrefix = ws;
			} else {
				commonPrefix = commonPrefixOf(commonPrefix, ws);
			}
		}
		final cp:String = commonPrefix ?? '';
		final cpLen:Int = cp.length;

		final indentUnit:String = indentUnitOf(opt);

		final docs:Array<Doc> = [Text('/*' + lines[0].ws + lines[0].body)];

		for (i in 1...lines.length) {
			final ws:String = lines[i].ws;
			final body:String = lines[i].body;

			if (body.length == 0) {
				docs.push(Line('\n'));
				continue;
			}

			final stripWs:String = cpLen > 0 && StringTools.startsWith(ws, cp)
				? ws.substr(cpLen)
				: ws;

			if (i == last) {
				if (lastIsClosingBrace) {
					docs.push(Line('\n'));
					docs.push(Text(StringTools.trim(stripWs + body)));
				} else if (StringTools.fastCodeAt(body, 0) == '*'.code) {
					docs.push(Line('\n'));
					docs.push(Text(stripWs + body));
				} else {
					var line:String = StringTools.rtrim(indentUnit + stripWs + body);
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

	private static inline function indentUnitOf(opt:WriteOptions):String {
		return opt.indentChar == IndentChar.Tab ? '\t' : StringTools.rpad('', ' ', opt.indentSize);
	}

	private static function commonPrefixOf(a:String, b:String):String {
		final lim:Int = a.length < b.length ? a.length : b.length;
		var j:Int = 0;
		while (j < lim && StringTools.fastCodeAt(a, j) == StringTools.fastCodeAt(b, j)) j++;
		return a.substr(0, j);
	}

	/**
	 * Structural indent length of a closing line's ws — `ws.length`
	 * minus a single trailing space (canonical close pad before
	 * `*\/`). Distinguishes `\t *\/` (1 char structural) from `*\/`
	 * with single-space pad (0 char structural).
	 */
	private static function structuralCloseLen(ws:String):Int {
		final len:Int = ws.length;
		if (len > 0 && StringTools.fastCodeAt(ws, len - 1) == ' '.code) return len - 1;
		return len;
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
	public static function normalize(comment:BlockComment, opt:WriteOptions):Null<BlockComment> {
		final lines:Array<BlockCommentLine> = comment.lines;
		if (lines.length <= 1) return null;

		final decoFlags:Array<Bool> = [for (l in lines) isAllStars(l.body)];
		final last:Int = lines.length - 1;
		var commonPrefix:String = '';
		var havePrefix:Bool = false;
		for (i in 0...lines.length) {
			final body:String = lines[i].body;
			final ws:String = lines[i].ws;
			if (body.length == 0) continue;
			if (i == 0) continue;
			// Last line is the structural close (`*\/` or `<content>*\/`),
			// not interior content. Its ws represents the wrap's structural
			// indent, not the comment body's indent depth.
			if (i == last) continue;
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
		final commonLen:Int = commonPrefix.length;
		final closingWs:String = lines[last].ws;
		final closeStructLen:Int = structuralCloseLen(closingWs);
		final structuralClose:String = closingWs.substr(0, closeStructLen);
		final shouldBake:Bool = commonLen > closeStructLen;
		final indentUnit:String = indentUnitOf(opt);

		final newLines:Array<BlockCommentLine> = [];
		for (i in 0...lines.length) {
			final body:String = lines[i].body;
			final ws:String = lines[i].ws;
			var newWs:String;
			if (i == 0) {
				newWs = body.length > 0 ? ws : '';
			} else if (i == last) {
				if (decoFlags[i]) {
					newWs = '';
				} else if (body.length == 0) {
					newWs = ' ';
				} else {
					newWs = structuralClose;
				}
			} else if (body.length == 0) {
				newWs = '';
			} else {
				final relWs:String = ws.length > commonLen ? ws.substr(commonLen) : '';
				newWs = shouldBake ? indentUnit + relWs : relWs;
			}
			newLines.push({ws: newWs, body: body});
		}
		return {lines: newLines};
	}

	/**
	 * Heuristic: every non-edge, non-blank interior line's body
	 * starts with `*`, indicating per-line ` * ` markers. Common-
	 * prefix-reduce on these would consume the marker space and
	 * destroy the visual marker column on emit.
	 */
	private static function isJavadocStyle(lines:Array<BlockCommentLine>):Bool {
		if (lines.length < 3) return false;
		final last:Int = lines.length - 1;
		var contentCount:Int = 0;
		var starredCount:Int = 0;
		for (i in 1...last) {
			final body:String = lines[i].body;
			if (body.length == 0) continue;
			contentCount++;
			if (StringTools.fastCodeAt(body, 0) == '*'.code) starredCount++;
		}
		return contentCount > 0 && starredCount == contentCount;
	}

	private static function isAllStars(s:String):Bool {
		if (s.length == 0) return false;
		for (i in 0...s.length) {
			if (StringTools.fastCodeAt(s, i) != '*'.code) return false;
		}
		return true;
	}

	/**
	 * Build a Doc for canonical (`Plain` / `Javadoc` /
	 * `JavadocNoStars`) comment output. Picks its own wrap shape
	 * (`/*`/`*\/` for Plain, `/**`/`**\/` for the other two) and
	 * per-line markers, so it bypasses the macro writer's line-by-
	 * line emission. Each interior boundary uses `Line('\n')` so the
	 * renderer applies the surrounding nest's indent.
	 */
	private static function canonicalDoc(comment:BlockComment, opt:WriteOptions):Doc {
		final wantStars:Bool = opt.commentStyle == CommentStyle.Javadoc;
		final wrapDoc:Bool = opt.commentStyle == CommentStyle.Javadoc
			|| opt.commentStyle == CommentStyle.JavadocNoStars;
		final indentUnit:String = indentUnitOf(opt);

		final stripped:Array<{ws:String, content:String}> = stripMarkers(comment.lines);
		final firstInline:Bool = stripped.length > 0 && stripped[0].content.length > 0;
		final commonLen:Int = commonPrefixLen(stripped, firstInline);
		final last:Int = stripped.length - 1;

		final interior:Array<String> = [];
		for (i in 0...stripped.length) {
			final p = stripped[i];
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

	private static function stripMarkers(lines:Array<BlockCommentLine>):Array<{ws:String, content:String}> {
		final out:Array<{ws:String, content:String}> = [];
		for (ln in lines) {
			final ws:String = ln.ws;
			var rest:String = ln.body;
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
}
