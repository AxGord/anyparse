package dev;

import anyparse.format.comment.FormatterOff;
import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondDirectives;
import anyparse.query.LexicalRegions;
import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.runtime.Span;
import anyparse.util.Strings;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The one answer to "what is this Haxe source with the author's single line breaks taken out": a whitespace run holding
 * exactly one newline becomes one space, so the program, its comments and its blank lines stay and only the author's
 * choice of where to break a line goes. The writer's output should not depend on that choice; `SquashCensus` counts the
 * files where it does.
 *
 * What a run may not touch is the ENGINE's to say: strings, regexes and comments are the lexical regions of
 * `HaxeQueryPlugin.lexicalRegions`, an `@formatter:off` region is `FormatterOff.regionsOf`, a `#if`/`#elseif`/`#else`/`#end`
 * is a span of `CondDirectives.scan`, and a `#error` is a node of the parse (`ErrorDecl`, `ErrorMember`, `ErrorStmt`; none
 * on a file that does not parse, which the census leaves out). A run is left alone when it touches a comment, a region, or a
 * line meeting one of those directive spans.
 */
@:nullSafety(Strict)
final class Squash {

	/** The node kinds the parse gives a `#error` directive in a declaration, member and statement position. */
	private static final ERROR_KINDS: Array<String> = ['ErrorDecl', 'ErrorMember', 'ErrorStmt'];

	/** `source` squashed. */
	public static function haxe(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final directives: Array<Span> = CondDirectives.scan(source, plugin.refShape(), () -> regions)
			.map(directive -> directive.span)
			.concat(errorSpans(plugin, source));
		return apply(source, regions, offSpans(source), directives);
	}

	/**
	 * `source` with every whitespace run inside a code span of `regions` that holds exactly one newline replaced by one space,
	 * unless the run opens or closes the file, touches a comment region or a `verbatim` span, or sits beside a line meeting a
	 * `directives` span.
	 */
	public static function apply(source: String, regions: Array<LexRegion>, verbatim: Array<Span>, directives: Array<Span>): String {
		final out: StringBuf = new StringBuf();
		var copied: Int = 0;
		for (code in LexicalRegions.codeSpans(source.length, regions)) {
			var i: Int = code.from;
			while (i < code.to) {
				if (!SourceText.isSpace(source.fastCodeAt(i))) {
					i++;
					continue;
				}
				final from: Int = i;
				var breaks: Int = 0;
				while (i < code.to && SourceText.isSpace(source.fastCodeAt(i))) {
					if (source.fastCodeAt(i) == '\n'.code) breaks++;
					i++;
				}
				if (breaks != 1 || !squashable(source, regions, verbatim, directives, from, i)) continue;
				out.add(source.substring(copied, from));
				out.add(' ');
				copied = i;
			}
		}
		out.add(source.substring(copied));
		return out.toString();
	}

	/** The byte spans of `source`'s `@formatter:off` regions: from the start of the `off` line to the end of the `on` line. */
	public static function offSpans(source: String): Array<Span> {
		final starts: Array<Int> = [0];
		for (i in 0...source.length) if (source.fastCodeAt(i) == '\n'.code) starts.push(i + 1);
		return FormatterOff.regionsOf(source, HaxeLexicalRegions.scanComments)
			.map(region -> new Span(starts[region.from], region.to + 1 < starts.length ? starts[region.to + 1] - 1 : source.length));
	}

	private static function squashable(
		source: String, regions: Array<LexRegion>, verbatim: Array<Span>, directives: Array<Span>, from: Int, to: Int
	): Bool {
		return from != 0
			&& to < source.length
			&& !verbatim.exists(span -> from <= span.to && to >= span.from)
			&& !isComment(from - 1, regions)
			&& !isComment(to, regions)
			&& !meets(directives, Strings.lineStart(source, from), from)
			&& !meets(directives, to, Strings.lineEnd(source, to));
	}

	private static function isComment(offset: Int, regions: Array<LexRegion>): Bool {
		final region: Null<LexRegion> = LexicalRegions.regionAt(offset, regions);
		return region != null && LexicalRegions.isComment(region);
	}

	/** Whether a span of `spans` overlaps `[from, to)`. */
	private static function meets(spans: Array<Span>, from: Int, to: Int): Bool {
		return spans.exists(span -> span.from < to && span.to > from);
	}

	/** The spans of the `#error` directives of `source`; none when it does not parse. */
	private static function errorSpans(plugin: HaxeQueryPlugin, source: String): Array<Span> {
		final out: Array<Span> = [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
		if (tree == null) return out;
		function collect(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && ERROR_KINDS.contains(node.kind)) out.push(span);
			for (child in node.children) collect(child);
		}
		collect(tree);
		return out;
	}

}
