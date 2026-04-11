package anyparse.grammar.json;

import anyparse.core.Doc;
import anyparse.core.D;
import anyparse.core.Renderer;
import anyparse.format.text.TextFormat;
import anyparse.format.text.JsonFormat;

/**
 * Formatting options for the JSON writer.
 *
 * - `indent`          — the string used for one level of indentation
 *                       when breaking an object or array onto multiple
 *                       lines.
 * - `lineWidth`       — target width in columns; containers that do not
 *                       fit within this width on their current line
 *                       will be broken. Set to a large value to force
 *                       maximum inlining.
 * - `spaceAfterColon` — whether to emit a single space after the key/
 *                       value separator.
 */
typedef JsonWriteOptions = {
	indent:String,
	lineWidth:Int,
	spaceAfterColon:Bool,
};

/**
 * Writer that converts a `JValue` into formatted JSON text.
 *
 * Internally builds a `Doc` tree and hands it to `Renderer`. Literal
 * characters and escape policy are read from a `TextFormat` instance,
 * defaulting to `JsonFormat.instance`. A user who needs JSON5 or HJSON
 * passes their own `TextFormat` implementation; no other code change
 * is required.
 */
@:nullSafety(Strict)
class JsonWriter {

	/** Default options: two-space indent, 80-column width, space after colon. */
	public static final defaultOptions:JsonWriteOptions = {
		indent: '  ',
		lineWidth: 80,
		spaceAfterColon: true,
	};

	/** Compact single-line output. No indent, no breaks, no spaces. */
	public static final compactOptions:JsonWriteOptions = {
		indent: '',
		lineWidth: 1000000,
		spaceAfterColon: false,
	};

	/**
	 * Write `value` to a JSON string. `options` controls layout; `format`
	 * provides literal vocabulary and escape policy (defaulting to
	 * `JsonFormat.instance`).
	 *
	 * Parameter order keeps `options` before `format` so existing call
	 * sites that only pass `options` continue to work without relying on
	 * Haxe's type-based optional skipping.
	 */
	public static function write(value:JValue, ?options:JsonWriteOptions, ?format:TextFormat):String {
		final fmt:TextFormat = format == null ? JsonFormat.instance : format;
		final opt:JsonWriteOptions = options == null ? defaultOptions : options;
		final doc:Doc = toDoc(value, fmt, opt);
		return Renderer.render(doc, opt.lineWidth);
	}

	/**
	 * Convert a `JValue` to its `Doc` representation. Exposed for
	 * composition — schema-level writers that embed raw JSON in a
	 * field call this directly.
	 */
	public static function toDoc(value:JValue, format:TextFormat, opt:JsonWriteOptions):Doc {
		return switch value {
			case JNull:
				D.text(format.nullLiteral ?? 'null');

			case JBool(true):
				D.text(format.boolLiterals == null ? 'true' : format.boolLiterals.trueLit);

			case JBool(false):
				D.text(format.boolLiterals == null ? 'false' : format.boolLiterals.falseLit);

			case JNumber(n):
				D.text(formatNumber(n));

			case JString(s):
				D.text(escapeString(s, format));

			case JArray(items):
				arrayToDoc(items, format, opt);

			case JObject(entries):
				objectToDoc(entries, format, opt);
		}
	}

	private static function arrayToDoc(items:Array<JValue>, format:TextFormat, opt:JsonWriteOptions):Doc {
		final seqOpen:String = format.sequenceOpen ?? '[';
		final seqClose:String = format.sequenceClose ?? ']';
		if (items.length == 0) return D.text('$seqOpen$seqClose');
		final itemDocs:Array<Doc> = [for (i in items) toDoc(i, format, opt)];
		final inner:Array<Doc> = D.intersperse(itemDocs, itemSeparator(format, opt));
		return D.group(D.concat([
			D.text(seqOpen),
			D.nest(opt.indent.length, D.concat([D.softline(), D.concat(inner)])),
			D.softline(),
			D.text(seqClose),
		]));
	}

	private static function objectToDoc(entries:Array<JEntry>, format:TextFormat, opt:JsonWriteOptions):Doc {
		if (entries.length == 0) return D.text('${format.mappingOpen}${format.mappingClose}');
		final entryDocs:Array<Doc> = [for (e in entries) entryToDoc(e, format, opt)];
		final inner:Array<Doc> = D.intersperse(entryDocs, itemSeparator(format, opt));
		return D.group(D.concat([
			D.text(format.mappingOpen),
			D.nest(opt.indent.length, D.concat([D.softline(), D.concat(inner)])),
			D.softline(),
			D.text(format.mappingClose),
		]));
	}

	/**
	 * Separator between items of an array or entries of an object.
	 *
	 * In pretty mode (`spaceAfterColon == true`) the separator is
	 * `entrySep + line` so the flat layout has a trailing space after
	 * the comma. In compact mode the trailing space is suppressed.
	 * In broken layout the line node becomes a real newline either way.
	 */
	private static inline function itemSeparator(format:TextFormat, opt:JsonWriteOptions):Doc {
		return opt.spaceAfterColon
			? D.concat([D.text(format.entrySep), D.line()])
			: D.concat([D.text(format.entrySep), D.softline()]);
	}

	private static function entryToDoc(e:JEntry, format:TextFormat, opt:JsonWriteOptions):Doc {
		final colon:String = opt.spaceAfterColon ? '${format.keyValueSep} ' : format.keyValueSep;
		return D.concat([
			D.text(escapeString(e.key, format)),
			D.text(colon),
			toDoc(e.value, format, opt),
		]);
	}

	/**
	 * Format a JSON number.
	 *
	 * - Whole numbers within 32-bit signed range are written without a
	 *   decimal point.
	 * - `NaN` and `Infinity` are not representable in JSON; we map them
	 *   to `"null"` as a conservative choice.
	 * - Other finite numbers use Haxe's default float-to-string
	 *   conversion, which is reasonable for the round-trip case.
	 */
	private static function formatNumber(n:Float):String {
		if (!Math.isFinite(n)) return 'null';
		if (n == Math.ffloor(n) && n >= -2147483648.0 && n <= 2147483647.0) {
			return '${Std.int(n)}';
		}
		return '$n';
	}

	/**
	 * Escape a string for output, wrapping it in the format's first
	 * declared string-quote character. Per-character escaping is
	 * delegated to the format's `escapeChar`.
	 */
	private static function escapeString(s:String, format:TextFormat):String {
		final quote:String = format.stringQuote.length > 0 ? format.stringQuote[0] : '"';
		final buf:StringBuf = new StringBuf();
		buf.add(quote);
		for (i in 0...s.length) {
			final c:Null<Int> = s.charCodeAt(i);
			if (c != null) buf.add(format.escapeChar(c));
		}
		buf.add(quote);
		return buf.toString();
	}
}
