package anyparse.query.format;

import anyparse.format.text.SExprFormat;
import anyparse.grammar.sexpr.SValue;
import anyparse.grammar.sexpr.SValueWriter;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta.MetaHit;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.SourceSlice;
import anyparse.query.Uses.UsesHit;
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

	public static function render(node:QueryNode, spans:Bool = false):String {
		return SValueWriter.write(toSValue(node, spans), SExprFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderMatches(matches:Array<QueryNode>, source:String, doc:Bool, src:Bool, spans:Bool = false):String {
		if (matches.length == 0) return '(no matches)\n';
		final buf:StringBuf = new StringBuf();
		for (m in matches) {
			buf.add(SValueWriter.write(toSValue(m, spans), SExprFormat.instance.defaultWriteOptions));
			buf.add('\n');
			appendDocSource(buf, source, m.span, doc, src);
		}
		return buf.toString();
	}

	public static function renderRefs(file:String, source:String, hits:Array<RefHit>, doc:Bool, src:Bool, flat:Bool = false):String {
		if (hits.length == 0) return '$file: no refs\n';
		final buf:StringBuf = new StringBuf();
		if (!flat) buf.add('$file:\n');
		for (h in hits) {
			final pos:Position = h.span.lineCol(source);
			if (flat) buf.add('$file:${pos.line}:${pos.col - 1}: [${h.kind.toString()}] ${h.name}');
			else buf.add('  ${pos.line}:${pos.col - 1}: [${h.kind.toString()}] ${h.name}');
			final bindingSpan:Null<Span> = h.bindingSpan;
			if (bindingSpan != null && bindingSpan.from != h.span.from) {
				final bp:Position = bindingSpan.lineCol(source);
				buf.add(' -> ${bp.line}:${bp.col - 1}');
			}
			buf.add('\n');
			appendDocSource(buf, source, h.span, doc, src);
		}
		return buf.toString();
	}

	public static function renderUses(file:String, source:String, hits:Array<UsesHit>, doc:Bool, src:Bool, flat:Bool = false):String {
		if (hits.length == 0) return '$file: no uses\n';
		final buf:StringBuf = new StringBuf();
		if (!flat) buf.add('$file:\n');
		for (h in hits) {
			final pos:Position = h.span.lineCol(source);
			if (flat) buf.add('$file:${pos.line}:${pos.col - 1}: ${h.name}\n');
			else buf.add('  ${pos.line}:${pos.col - 1}: ${h.name}\n');
			appendDocSource(buf, source, h.span, doc, src);
		}
		return buf.toString();
	}

	/**
	 * Emit the optional `--doc` / `--source` blocks after a hit line.
	 * Each block is 2-space indented and followed by a blank line.
	 * No-op when neither flag is set or nothing resolves — so default
	 * output is unchanged.
	 */
	private static function appendDocSource(buf:StringBuf, source:String, span:Null<Span>, doc:Bool, src:Bool):Void {
		if (doc) {
			final d:Null<String> = SourceSlice.leadingDoc(source, span);
			if (d != null) {
				buf.add(indentBlock(d));
				buf.add('\n');
			}
		}
		if (src) {
			final s:String = SourceSlice.slice(source, span);
			if (s.length > 0) {
				buf.add(indentBlock(s));
				buf.add('\n');
			}
		}
	}

	private static inline function indentBlock(text:String):String {
		return '  ' + text.split('\n').join('\n  ') + '\n';
	}

	public static function renderMeta(file:String, source:String, hits:Array<MetaHit>, flat:Bool = false):String {
		if (hits.length == 0) return '$file: no meta\n';
		final buf:StringBuf = new StringBuf();
		if (!flat) buf.add('$file:\n');
		for (h in hits) {
			final span:Null<Span> = h.metaSpan;
			if (span != null) {
				final pos:Position = span.lineCol(source);
				if (flat) buf.add('$file:${pos.line}:${pos.col - 1}: ');
				else buf.add('  ${pos.line}:${pos.col - 1}: ');
			} else {
				if (flat) buf.add('$file: ');
				else buf.add('  (no-span): ');
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

	public static function renderSearchMatches(file:String, source:String, matches:Array<Match>, flat:Bool = false):String {
		if (matches.length == 0) return '$file: no matches\n';
		final buf:StringBuf = new StringBuf();
		if (!flat) buf.add('$file:\n');
		for (m in matches) {
			final pos:Position = m.span.lineCol(source);
			if (flat) buf.add('$file:${pos.line}:${pos.col - 1}: match');
			else buf.add('  ${pos.line}:${pos.col - 1}: match');
			final bindingsCount:Int = countBindings(m);
			if (bindingsCount > 0) {
				buf.add(' (');
				var first:Bool = true;
				for (name => bound in m.bindings) {
					if (!first) buf.add(', ');
					first = false;
					buf.add(name);
					buf.add('=');
					buf.add(summariseBound(source, bound));
				}
				buf.add(')');
			}
			buf.add('\n');
		}
		return buf.toString();
	}

	private static inline function countBindings(m:Match):Int {
		var n:Int = 0;
		for (_ in m.bindings) n++;
		return n;
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

	private static function toSValue(node:QueryNode, spans:Bool = false):SValue {
		final items:Array<SValue> = [SAtom(node.kind)];
		final n:Null<String> = node.name;
		if (n != null) items.push(makeNameValue(n));
		if (spans) {
			final span:Null<Span> = node.span;
			if (span != null) items.push(SAtom('@${span.from}-${span.to}'));
		}
		for (c in node.children) items.push(toSValue(c, spans));
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
