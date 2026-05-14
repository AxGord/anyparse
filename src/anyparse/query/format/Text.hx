package anyparse.query.format;

import anyparse.format.text.SExprFormat;
import anyparse.grammar.sexpr.SValue;
import anyparse.grammar.sexpr.SValueWriter;
import anyparse.query.QueryNode;

/**
 * S-expression renderer for `apq ast` output.
 *
 * Thin adapter — converts a generic `QueryNode` tree into an `SValue`
 * (the universal S-expression AST in `anyparse.grammar.sexpr`) and
 * delegates serialization to the macro-generated `SValueWriter`. The
 * library claim is that any text format can be expressed declaratively;
 * this file dogfoods the claim for `apq` text output, sister to the
 * JSON renderer in `Json.hx`.
 *
 * Layout:
 *  - `(kind)` — node with no name and no children.
 *  - `(kind name)` — node with a name and no children.
 *  - `(kind child1 child2 ...)` / `(kind name child1 ...)` — full form.
 *
 * Multi-line break-up is owned by the underlying `sepList` Doc primitive
 * driven by `SExprFormat.defaultWriteOptions.lineWidth`. Names containing
 * whitespace / parens / quote characters are emitted as double-quoted
 * strings; bare-safe names use the atom form.
 */
@:nullSafety(Strict)
final class Text {

	public static function render(node:QueryNode):String {
		return SValueWriter.write(toSValue(node), SExprFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderMatches(matches:Array<QueryNode>):String {
		if (matches.length == 0) return '(no matches)\n';
		final buf:StringBuf = new StringBuf();
		for (m in matches) {
			buf.add(SValueWriter.write(toSValue(m), SExprFormat.instance.defaultWriteOptions));
			buf.add('\n');
		}
		return buf.toString();
	}

	private static function toSValue(node:QueryNode):SValue {
		final items:Array<SValue> = [SAtom(node.kind)];
		final n:Null<String> = node.name;
		if (n != null) items.push(makeNameValue(n));
		for (c in node.children) items.push(toSValue(c));
		return SList(items);
	}

	/**
	 * Pick `SAtom` for bare-safe names (no whitespace, no parens, no
	 * quotes); `SString` otherwise. Keeps simple Haxe identifiers
	 * unquoted while still handling pathological corner cases.
	 */
	private static function makeNameValue(name:String):SValue {
		return isSafeAtom(name) ? SAtom(name) : SString(name);
	}

	private static function isSafeAtom(s:String):Bool {
		if (s.length == 0) return false;
		for (i in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, i);
			if (c <= 0x20) return false;
			if (c == '('.code || c == ')'.code || c == '"'.code) return false;
		}
		return true;
	}
}
