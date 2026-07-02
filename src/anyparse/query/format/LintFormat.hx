package anyparse.query.format;

import anyparse.check.Check.Violation;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;
import haxe.Json;

/**
 * Machine-readable renderers for analysis-check violations — the JSON and
 * checkstyle-XML counterparts of `Text.renderViolations`. Both take a flat
 * violation list (already filtered and ordered by the caller) plus a
 * `file -> source` map for line/column resolution via `Span.lineCol`.
 * Symmetric with the `checkstyle.json` config the project already consumes:
 * emitting checkstyle XML lets the same CI tooling ingest apq findings.
 */
@:nullSafety(Strict)
final class LintFormat {

	/**
	 * Render `violations` as a pretty-printed JSON array of
	 * `{file, line, col, severity, rule, message}` records. A violation with
	 * no span resolves `line`/`col` to null. `addressOf` (when given) adds an
	 * `address` field — the finding's canonical edit-stable selector
	 * (`Address.describe`), directly usable as a mutation-op `--select`
	 * argument. Escaping is delegated to `Json.stringify`.
	 */
	public static function json(violations: Array<Violation>, sourceOf: Map<String, String>, ?addressOf: Violation -> Null<String>): String {
		final records: Array<Dynamic> = [
			for (v in violations) {
				final record: Dynamic = recordOf(v, sourceOf);
				if (addressOf != null) {
					final address: Null<String> = addressOf(v);
					if (address != null) Reflect.setField(record, 'address', address);
				}
				record;
			}
		];
		return Json.stringify(records, null, '  ');
	}

	/**
	 * Render `violations` as a checkstyle XML document, grouped by file in
	 * first-seen order. Each finding becomes an
	 * `<error line= column= severity= message= source=/>` with
	 * `source="apq.<rule>"`; attribute values are XML-escaped. A null span
	 * yields `line="0" column="0"`.
	 */
	public static function checkstyle(violations: Array<Violation>, sourceOf: Map<String, String>): String {
		final order: Array<String> = [];
		final byFile: Map<String, Array<Violation>> = [];
		for (v in violations) {
			var list: Null<Array<Violation>> = byFile[v.file];
			if (list == null) {
				list = [];
				byFile[v.file] = list;
				order.push(v.file);
			}
			list.push(v);
		}

		final buf: StringBuf = new StringBuf();
		buf.add('<?xml version="1.0" encoding="UTF-8"?>\n');
		buf.add('<checkstyle version="8.0">\n');
		for (file in order) {
			final group: Null<Array<Violation>> = byFile[file];
			if (group == null) continue;
			final source: String = sourceOf[file] ?? '';
			buf.add('  <file name="${xml(file)}">\n');
			for (v in group) {
				final pos: Null<Position> = posOf(v, source);
				final line: Int = pos != null ? pos.line : 0;
				final col: Int = pos != null ? pos.col : 0;
				buf.add('    <error line="$line" column="$col" severity="${v.severity.label()}"');
				buf.add(' message="${xml(v.message)}" source="apq.${xml(v.rule)}"/>\n');
			}
			buf.add('  </file>\n');
		}
		buf.add('</checkstyle>\n');
		return buf.toString();
	}

	/** One JSON record for a violation; null span yields null line/col. */
	private static function recordOf(v: Violation, sourceOf: Map<String, String>): Dynamic {
		final pos: Null<Position> = posOf(v, sourceOf[v.file] ?? '');
		return {
			file: v.file,
			line: pos != null ? pos.line : null,
			col: pos != null ? pos.col : null,
			severity: v.severity.label(),
			rule: v.rule,
			message: v.message
		};
	}

	/** Resolve a violation's 1-indexed position, or null when it has no span. */
	private static function posOf(v: Violation, source: String): Null<Position> {
		final span: Null<Span> = v.span;
		return span != null ? span.lineCol(source) : null;
	}

	/** XML-escape an attribute value. */
	private static function xml(s: String): String {
		return s.split('&')
			.join('&amp;')
			.split('<')
			.join('&lt;')
			.split('>')
			.join('&gt;')
			.split('"')
			.join('&quot;');
	}

}
