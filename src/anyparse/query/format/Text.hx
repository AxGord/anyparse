package anyparse.query.format;

import anyparse.format.text.LineDiagFormat;
import anyparse.format.text.SExprFormat;
import anyparse.grammar.sexpr.SValue;
import anyparse.grammar.sexpr.SValueWriter;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta.MetaHit;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.format.line.RefLine;
import anyparse.query.format.line.RefLineList;
import anyparse.query.format.line.RefLineListWriter;
import anyparse.query.format.line.SearchBindingPair;
import anyparse.query.format.line.SearchLine;
import anyparse.query.format.line.SearchLineList;
import anyparse.query.format.line.SearchLineListWriter;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

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

	public static function renderRefs(file:String, source:String, hits:Array<RefHit>):String {
		if (hits.length == 0) return '$file: no refs\n';
		final lines:Array<RefLine> = [for (h in hits) {
			final pos:Position = h.span.lineCol(source);
			final rl:RefLine = {
				file: file,
				line: pos.line,
				col: pos.col - 1,
				kind: h.kind.toString(),
				name: h.name,
			};
			final bindingSpan:Null<Span> = h.bindingSpan;
			if (bindingSpan != null && bindingSpan.from != h.span.from) {
				final bp:Position = bindingSpan.lineCol(source);
				rl.binding = '${bp.line}:${bp.col - 1}';
			}
			rl;
		}];
		final list:RefLineList = {lines: lines};
		return RefLineListWriter.write(list, LineDiagFormat.instance.defaultWriteOptions);
	}

	public static function renderMeta(file:String, source:String, hits:Array<MetaHit>):String {
		if (hits.length == 0) return '$file: no meta\n';
		final buf:StringBuf = new StringBuf();
		for (h in hits) {
			final span:Null<Span> = h.metaSpan;
			if (span != null) {
				final pos:Position = span.lineCol(source);
				buf.add('$file:${pos.line}:${pos.col - 1}: ');
			} else {
				buf.add('$file: ');
			}
			buf.add(h.annotation);
			if (h.args.length > 0) {
				buf.add('(');
				buf.add(h.args.join(', '));
				buf.add(')');
			}
			buf.add(' on ${h.declKind}');
			final dn:Null<String> = h.declName;
			if (dn != null) buf.add(' $dn');
			buf.add('\n');
		}
		return buf.toString();
	}

	public static function renderSearchMatches(file:String, source:String, matches:Array<Match>):String {
		if (matches.length == 0) return '$file: no matches\n';
		final lines:Array<SearchLine> = [for (m in matches) {
			final pos:Position = m.span.lineCol(source);
			final sl:SearchLine = {
				file: file,
				line: pos.line,
				col: pos.col - 1,
			};
			final pairs:Array<SearchBindingPair> = [
				for (name => bound in m.bindings) {name: name, value: summariseBound(source, bound)}
			];
			if (pairs.length > 0) sl.bindings = pairs;
			sl;
		}];
		final list:SearchLineList = {lines: lines};
		return SearchLineListWriter.write(list, LineDiagFormat.instance.defaultWriteOptions);
	}


	private static function summariseBound(source:String, bound:QueryNode):String {
		// Name-position binding (e.g. `$E` in `new $E(...)`) records the
		// matched name string in `bound.name`; the span is borrowed from
		// the parent enum and is not source-tight to the name. Prefer
		// the name string directly so the summary reads `E=IoError` not
		// `E=new IoError(...)`.
		if (bound.kind == 'NameOnly') {
			final n:Null<String> = bound.name;
			return n ?? '';
		}
		final span:Null<Span> = bound.span;
		if (span == null) return '?';
		final from:Int = span.from < 0 ? 0 : span.from;
		final to:Int = span.to > source.length ? source.length : span.to;
		if (from >= to) return '';
		final slice:String = source.substring(from, to);
		final flat:String = StringTools.replace(StringTools.replace(slice, '\n', ' '), '\r', '');
		return StringTools.trim(flat);
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
