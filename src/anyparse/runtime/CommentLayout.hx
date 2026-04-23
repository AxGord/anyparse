package anyparse.runtime;

import anyparse.core.Doc;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

/**
 * Multi-line block-comment re-indent.
 *
 * Port of haxe-formatter's `MarkTokenText.printComment`
 * (src/formatter/marker/MarkTokenText.hx:136-237): normalises the
 * leading indent of each interior line of a captured `/*…*\/` comment
 * to match the current writer's `indentChar` / `indentSize` /
 * `tabWidth`, independent of what the source used.
 *
 * Emit shape: `Concat([Text("/*"+line0), Line+Text(offset+lineN), …, Line+Text(last+"*\/")])`.
 * The Renderer supplies the base indent on each `Line` from its current
 * `Nest`; this helper only prefixes the delta (one indent unit for
 * interior lines of a non-javadoc comment, a single space for javadoc
 * `* foo` alignment, nothing for the closing line aligned with the
 * opening `/*`).
 *
 * Single-line `/*…*\/` comments and `//` comments pass through as-is
 * (single `Doc.Text`): re-indent has no handle when there is no
 * newline.
 */
class CommentLayout {

	public static function buildLeadingCommentDoc(content:String, opt:WriteOptions):Doc {
		if (!StringTools.startsWith(content, '/*')) return Doc.Text(content);
		if (content.indexOf('\n') < 0) return Doc.Text(content);
		final body:String = content.substring(2, content.length - 2);
		final lines:Array<String> = body.split('\n');
		final indentUnit:String = opt.indentChar == IndentChar.Tab
			? '\t'
			: StringTools.rpad('', ' ', opt.indentSize);
		final altIndent:String = opt.indentChar == IndentChar.Tab
			? StringTools.rpad('', ' ', opt.tabWidth)
			: '\t';
		final startsWithStar:Bool = detectStartsWithStar(lines);
		for (i in 0...lines.length) {
			lines[i] = convertLeadingIndent(lines[i], altIndent, indentUnit);
		}
		removeCommentPrefix(lines);
		final parts:Array<Doc> = [];
		parts.push(Doc.Text('/*' + lines[0]));
		final last:Int = lines.length - 1;
		var i:Int = 1;
		while (i < last) {
			parts.push(Doc.Line('\n'));
			final line:String = lines[i];
			if (!isBlankLine(line)) {
				final pref:String = startsWithStar ? ' ' : indentUnit;
				parts.push(Doc.Text(pref + line));
			}
			i++;
		}
		if (lines.length > 1) {
			parts.push(Doc.Line('\n'));
			parts.push(Doc.Text(formatLastLine(lines[last], indentUnit) + '*/'));
		}
		return Doc.Concat(parts);
	}

	static function detectStartsWithStar(lines:Array<String>):Bool {
		if (lines.length < 3) return false;
		var i:Int = 1;
		while (i < lines.length - 1) {
			final l:String = lines[i];
			var k:Int = 0;
			while (k < l.length) {
				final c:Int = StringTools.fastCodeAt(l, k);
				if (c != ' '.code && c != '\t'.code) break;
				k++;
			}
			if (k >= l.length || StringTools.fastCodeAt(l, k) != '*'.code) return false;
			final n:Int = k + 1;
			if (n < l.length) {
				final nc:Int = StringTools.fastCodeAt(l, n);
				if (nc != ' '.code && nc != '\t'.code) return false;
			}
			i++;
		}
		return true;
	}

	static function convertLeadingIndent(line:String, altIndent:String, indentUnit:String):String {
		var k:Int = 0;
		while (k < line.length) {
			final c:Int = StringTools.fastCodeAt(line, k);
			if (c != ' '.code && c != '\t'.code) break;
			k++;
		}
		if (k == 0) return line;
		final pref:String = line.substring(0, k);
		final rest:String = line.substring(k);
		return StringTools.replace(pref, altIndent, indentUnit) + rest;
	}

	static function removeCommentPrefix(lines:Array<String>):Void {
		final lastIdx:Int = lines.length - 1;
		final last:String = lines[lastIdx];
		var lp:Int = 0;
		while (lp < last.length) {
			final c:Int = StringTools.fastCodeAt(last, lp);
			if (c != ' '.code && c != '\t'.code) break;
			lp++;
		}
		var closeOnly:Bool = false;
		if (lp < last.length && StringTools.fastCodeAt(last, lp) == '}'.code) {
			closeOnly = true;
		} else {
			var sp:Int = lp;
			while (sp < last.length && StringTools.fastCodeAt(last, sp) == '*'.code) sp++;
			if (sp == last.length) closeOnly = true;
		}
		final endIdx:Int = closeOnly ? lastIdx : lines.length;
		var prefix:String = null;
		for (idx in 1...endIdx) {
			final l:String = lines[idx];
			var k:Int = 0;
			while (k < l.length) {
				final c:Int = StringTools.fastCodeAt(l, k);
				if (c != ' '.code && c != '\t'.code) break;
				k++;
			}
			if (k <= 0) continue;
			final p:String = l.substring(0, k);
			if (prefix == null || prefix.length > p.length) prefix = p;
		}
		if (prefix != null) {
			final startPrefix:String = prefix + ' *';
			for (idx in 0...lines.length) {
				var cur:String = lines[idx];
				if (StringTools.startsWith(cur, startPrefix)) {
					cur = cur.substring(startPrefix.length - 1);
				}
				if (StringTools.startsWith(cur, prefix)) {
					cur = cur.substring(prefix.length);
				}
				lines[idx] = cur;
			}
		}
		final finalLast:String = lines[lastIdx];
		var flp:Int = 0;
		while (flp < finalLast.length) {
			final c:Int = StringTools.fastCodeAt(finalLast, flp);
			if (c != ' '.code && c != '\t'.code) break;
			flp++;
		}
		if (flp < finalLast.length && StringTools.fastCodeAt(finalLast, flp) == '*'.code) {
			var si:Int = flp + 1;
			while (si < finalLast.length && StringTools.fastCodeAt(finalLast, si) == '*'.code) si++;
			if (si == finalLast.length) lines[lastIdx] = finalLast.substring(flp);
		}
	}

	static function isBlankLine(line:String):Bool {
		for (k in 0...line.length) {
			final c:Int = StringTools.fastCodeAt(line, k);
			if (c != ' '.code && c != '\t'.code) return false;
		}
		return true;
	}

	static function formatLastLine(raw:String, indentUnit:String):String {
		var line:String = raw;
		if (matchLastLeadingStarNonStar(line)) line = ' ' + line;
		if (matchLeadingCloseBrace(line)) return StringTools.trim(line);
		var extra:String = '';
		if (matchLeadingNonStarNonWs(line)) extra = indentUnit;
		line = StringTools.rtrim(line);
		if (line.length == 0 || StringTools.fastCodeAt(line, line.length - 1) != '*'.code) line += ' ';
		if (isBlankLine(line)) line = ' ';
		return extra + line;
	}

	static function matchLastLeadingStarNonStar(line:String):Bool {
		var k:Int = 0;
		while (k < line.length) {
			final c:Int = StringTools.fastCodeAt(line, k);
			if (c != ' '.code && c != '\t'.code) break;
			k++;
		}
		if (k >= line.length || StringTools.fastCodeAt(line, k) != '*'.code) return false;
		k++;
		while (k < line.length) {
			final c:Int = StringTools.fastCodeAt(line, k);
			if (c != ' '.code && c != '\t'.code) break;
			k++;
		}
		if (k >= line.length) return false;
		final c:Int = StringTools.fastCodeAt(line, k);
		return c != '*'.code;
	}

	static function matchLeadingCloseBrace(line:String):Bool {
		var k:Int = 0;
		while (k < line.length) {
			final c:Int = StringTools.fastCodeAt(line, k);
			if (c != ' '.code && c != '\t'.code) break;
			k++;
		}
		return k < line.length && StringTools.fastCodeAt(line, k) == '}'.code;
	}

	static function matchLeadingNonStarNonWs(line:String):Bool {
		var k:Int = 0;
		while (k < line.length) {
			final c:Int = StringTools.fastCodeAt(line, k);
			if (c != ' '.code && c != '\t'.code) break;
			k++;
		}
		if (k >= line.length) return false;
		final c:Int = StringTools.fastCodeAt(line, k);
		return c != '*'.code;
	}
}
