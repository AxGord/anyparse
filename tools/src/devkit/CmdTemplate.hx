package devkit;

using StringTools;

/**
 * The template language of `Cmd.cmd`, read at compile time into an argument vector: words split on whitespace, a
 * `"…"` run groups literal text that holds spaces (the quotes are dropped, `""` is one empty word), `$name` and
 * `${expr}` interpolate a value, and `$$` is one literal `$`. There is no shell and no escaping: a value never meets a
 * parser, so whatever it holds stays the one word (or, for an array filling a whole word, the words) it was given as.
 */
@:nullSafety(Strict)
final class CmdTemplate {

	/** The words of `template`, each a run of literal text and interpolated values; throws `TemplateError` when malformed. */
	public static function parse(template: String): Array<Array<TemplatePart>> {
		final words: Array<Array<TemplatePart>> = [];
		var word: Null<Array<TemplatePart>> = null;
		var text: String = '';
		var quoted: Bool = false;
		var quoteAt: Int = 0;
		inline function push(part: TemplatePart): Void {
			final current: Array<TemplatePart> = word ?? [];
			current.push(part);
			word = current;
		}
		inline function flushText(): Void {
			if (text != '') push(Text(text));
			text = '';
		}
		inline function close(): Void {
			flushText();
			final current: Null<Array<TemplatePart>> = word;
			if (current != null) words.push(current);
			word = null;
		}
		var i: Int = 0;
		while (i < template.length) {
			final c: String = template.charAt(i);
			switch c {
				case '"':
					// an opened quote starts a word even when nothing follows it: `""` is one empty argument
					if (word == null) word = [];
					quoted = !quoted;
					quoteAt = i;
					i++;
				case '$':
					i = interpolation(template, i, part -> {
						flushText();
						push(part);
					}, literal -> text += literal);
				case _ if (!quoted && c.isSpace(0)):
					close();
					i++;
				case _:
					text += c;
					i++;
			}
		}
		if (quoted) throw new TemplateError('unterminated `"`', quoteAt);
		close();
		return words;
	}

	/** Whether `code` may stand in an identifier — as its first character when `first`. */
	private static inline function isIdentChar(code: Null<Int>, first: Bool): Bool {
		return code != null
			&& (code == '_'.code
				|| (code >= 'a'.code && code <= 'z'.code)
				|| (code >= 'A'.code && code <= 'Z'.code)
				|| (!first && code >= '0'.code && code <= '9'.code));
	}

	/**
	 * Read the `$` at `at`: a `${…}` or `$name` value goes to `value`, a `$$` or a lone `$` to `literal` as one `$`.
	 * Answers the offset just past what it read.
	 */
	private static function interpolation(template: String, at: Int, value: TemplatePart -> Void, literal: String -> Void): Int {
		final next: String = template.charAt(at + 1);
		if (next == '$') {
			literal('$');
			return at + 2;
		}
		if (next == '{') {
			var depth: Int = 1;
			var end: Int = at + 2;
			while (end < template.length && depth > 0) {
				switch template.charAt(end) {
					case '{':
						depth++;
					case '}':
						depth--;
					case _:
				}
				end++;
			}
			if (depth > 0) throw new TemplateError('unterminated `$${`', at);
			final source: String = template.substring(at + 2, end - 1).trim();
			if (source == '') throw new TemplateError('empty `$${}`', at);
			value(Value(source, at + 2));
			return end;
		}
		var end: Int = at + 1;
		while (end < template.length && isIdentChar(template.charCodeAt(end), end == at + 1)) end++;
		if (end == at + 1) {
			literal('$');
			return at + 1;
		}
		value(Value(template.substring(at + 1, end), at + 1));
		return end;
	}

}

/** One run of a template word: literal `Text`, or the Haxe expression `source` of a `Value` at `offset` in the template. */
enum TemplatePart {
	Text(text: String);
	Value(source: String, offset: Int);
}

/** A template `CmdTemplate.parse` cannot read, with the `offset` of the construct at fault. */
class TemplateError extends haxe.Exception {

	public final offset: Int;

	public function new(message: String, offset: Int) {
		super(message);
		this.offset = offset;
	}

}
