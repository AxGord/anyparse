package anyparse.grammar.haxe;

import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.runtime.Span;

using Lambda;

/**
 * Haxe `StringFoldSupport`: a `+` (`Add`) concatenation of two plain string
 * literals of the same quote folds into one. A double-quoted literal is always
 * plain (Haxe never interpolates `"..."`); a single-quoted literal is plain only
 * when it carries no interpolation — every child is a `Literal` fragment, no
 * `Ident` / `Block` (so `'a$$b'`, an escaped `$`, stays plain). `content` is the
 * raw inner source, so escapes survive a same-quote concatenation verbatim.
 */
@:nullSafety(Strict)
final class HaxeStringFoldSupport implements StringFoldSupport {

	public function new() {}

	public function concatKind(): String {
		return 'Add';
	}

	public function literalOf(node: QueryNode, source: String): Null<StringLiteral> {
		final span: Null<Span> = node.span;
		if (span == null || span.to - span.from < 2) return null;
		return switch node.kind {
			case 'DoubleStringExpr': { quote: '"', content: inner(source, span) };
			case 'SingleStringExpr': node.children.foreach(c -> c.kind == 'Literal' || c.kind == 'Dollar')
				? {
					quote: "'",
					content: inner(source, span)
				}
				: null;
			case _: null;
		}
	}

	/** The raw source between the literal's two quote characters. */
	private static inline function inner(source: String, span: Span): String {
		return source.substring(span.from + 1, span.to - 1);
	}

}
