package anyparse.runtime;

import anyparse.core.Doc;
import anyparse.format.CommentStyle;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.grammar.haxe.BlockCommentBody;
import anyparse.grammar.haxe.BlockCommentBodyParser;

/**
 * Multi-line block-comment emit.
 *
 * Tokenization via `BlockCommentBodyParser` — the macro-generated
 * Fast-mode parser for the `BlockCommentBody` grammar. The grammar
 * strips leading whitespace and any javadoc `*` marker per line via
 * `@:captureGroup(1)`, so each `parsed.lines[i]` is already the
 * **dry content** (no tabs / no stars), matching the project
 * principle that output style should be writer-policy, not echoed
 * from source.
 *
 * Emit shape: `Concat([Text("/*"), Line, Text(indentUnit + content), …, Line, Text("*\/")])`.
 * First and last lines of the parsed body (typically emptied out by
 * the capture-group strip — they carried the `*` markers of `/**`
 * and `**\/`) are collapsed into the opening / closing delimiters.
 * The Renderer supplies the base indent on every `Line` from its
 * current `Nest`; this helper only prefixes the delta (one indent
 * unit for interior lines, nothing for the closing line).
 *
 * Single-line `/*…*\/` comments and `//` comments pass through as
 * a single `Doc.Text`.
 */
class CommentLayout {

	public static function buildLeadingCommentDoc(content:String, opt:WriteOptions):Doc {
		if (!StringTools.startsWith(content, '/*')) return Doc.Text(content);
		if (content.indexOf('\n') < 0) return Doc.Text(content);
		final parsed:BlockCommentBody = BlockCommentBodyParser.parse(content);
		final javadoc:Bool = opt.commentStyle == CommentStyle.Javadoc;
		final open:String = javadoc ? '/**' : '/*';
		final close:String = javadoc ? '**/' : '*/';
		final linePrefix:String = javadoc
			? ' * '
			: (opt.indentChar == IndentChar.Tab ? '\t' : StringTools.rpad('', ' ', opt.indentSize));
		final blankPrefix:String = javadoc ? ' *' : '';
		final parts:Array<Doc> = [Doc.Text(open)];
		final last:Int = parsed.lines.length - 1;
		// A purely-empty first or last line carries nothing but the
		// `/*` / `*\/` delimiter's extra `*` markers that got stripped
		// at capture time — skip it so the delimiters sit on their own
		// lines without a spurious blank row. Empty interior lines are
		// preserved as blank rows (the author's in-comment paragraph
		// break); javadoc style adds a bare ` *` marker on blank rows
		// to match the canonical doc-block appearance.
		for (i in 0...parsed.lines.length) {
			final raw:String = parsed.lines[i];
			final line:String = StringTools.rtrim(raw);
			if ((i == 0 || i == last) && line.length == 0) continue;
			parts.push(Doc.Line('\n'));
			if (line.length > 0) parts.push(Doc.Text(linePrefix + line));
			else if (blankPrefix.length > 0) parts.push(Doc.Text(blankPrefix));
		}
		parts.push(Doc.Line('\n'));
		parts.push(Doc.Text(close));
		return Doc.Concat(parts);
	}
}
