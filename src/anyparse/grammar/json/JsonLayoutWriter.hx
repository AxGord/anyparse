package anyparse.grammar.json;

import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * The `json` grammar's FORMAT-PRESERVING writer: it re-emits a document from its projected tree
 * (`JsonProjection`) keeping the file's own layout, and lays out only what an edit introduced.
 *
 * Every structural token — `{` `}` `[` `]` `,` `:` — is written by the writer from the format's
 * vocabulary (`JsonFormat`), every scalar and key from its own source span, and every gap
 * between two tokens from the source, verbatim. A document written with no edit is therefore
 * its own bytes: indentation (tabs or spaces), key order, one-per-line or inline containers, the
 * leading and trailing whitespace of the document. That is `writeRoundTrip`, the canonical gate
 * every writer-emit op puts on its input — any parseable JSON passes it.
 *
 * An EDIT is laid out by `layout(text, marks)`, where `text` is the spliced document and each
 * mark one edit's footprint in it: the range its text now occupies, zero-width for a deletion.
 * Two rules, and nothing else changes:
 *
 *  - a NODE wholly inside a mark is new, and is written the way its siblings are written: an
 *    object or array takes the expanded (one entry per line) or inline shape of the nearest
 *    sibling of its kind (its MODEL), and when there is none, the shape of the container it sits
 *    in; a member's `:` takes the spacing of its sibling members, else the document's first
 *    member's; nested containers follow the model's matching child, else their parent.
 *  - a GAP a mark touches — the whitespace before an entry, before a `,`, around a `:`, or before
 *    the closing bracket — is re-derived from the container's own untouched gaps: an expanded
 *    container gives each entry its own line at the indentation its other entries carry (or one
 *    indent unit past the container's line when none survives), an inline one the separator its
 *    other entries use. A container left with no untouched gap takes its parent's shape.
 *
 * The indent unit is the document's own — the leading whitespace of its first indented line —
 * else the format default (`JsonFormat.defaultWriteOptions`), and a new line ends the way the
 * document's lines do (`\r\n` when the document holds one).
 */
@:nullSafety(Strict)
final class JsonLayoutWriter {

	private final _text: String;
	private final _marks: Array<Span>;
	private final _root: QueryNode;
	private final _unit: String;
	private final _lineEnd: String;

	private var _out: String = '';

	private function new(text: String, marks: Array<Span>, root: QueryNode) {
		_text = text;
		_marks = marks;
		_root = root;
		_unit = indentUnit(text);
		_lineEnd = lineEndOf(text);
	}

	private inline function slice(span: Span): String {
		return _text.substring(span.from, span.to);
	}

	/** The document: its leading and trailing whitespace verbatim around its one value. */
	private function writeDocument(value: QueryNode): String {
		final span: Span = spanOf(value);
		_out = _text.substring(0, span.from);
		writeValue(value, null, documentSpansLines(span));
		_out += _text.substring(span.to);
		return _out;
	}

	/** One value at an existing position: new → laid out, a container → token by token, a scalar → its source. */
	private function writeValue(node: QueryNode, model: Null<QueryNode>, parentExpanded: Bool): Void {
		if (isNew(node))
			writeNew(node, model, parentExpanded)
		else if (JsonProjection.isContainer(node))
			writeContainer(node, parentExpanded)
		else
			_out += slice(spanOf(node));
	}

	/** An existing container: its delimiters from the format, each gap from the source unless a mark touched it. */
	private function writeContainer(node: QueryNode, parentExpanded: Bool): Void {
		final layout: ContainerLayout = layoutOf(node);
		final style: Null<ContainerStyle> = needsStyle(node, layout) ? styleOf(node, layout, parentExpanded) : null;
		final expanded: Bool = style == null ? spansLines(node) : style.expanded;
		_out += openOf(node);
		for (i => item in node.children) {
			final lead: Span = layout.leads[i];
			_out += style != null && (isNew(item) || isDirty(lead)) ? style.lead(i) : slice(lead);
			if (node.kind == JsonProjection.OBJECT)
				writeMember(item, node, style, expanded)
			else
				writeValue(item, isNew(item) ? elementModel(node, item) : null, expanded);
			final preComma: Null<Span> = layout.preCommas[i];
			if (preComma != null) _out += (style != null && isDirty(preComma) ? style.preComma : slice(preComma)) + entrySep();
		}
		_out += (style != null && isDirty(layout.close) ? style.close : slice(layout.close)) + closeOf(node);
	}

	/** An existing member's key, `:` and value; a new member is laid out whole. */
	private function writeMember(member: QueryNode, object: QueryNode, style: Null<ContainerStyle>, expanded: Bool): Void {
		final value: QueryNode = member.children[0];
		if (isNew(member)) {
			final sep: KeySep = style?.keySep ?? keySepOf(object);
			_out += keyText(member) + sep.before + keyValueSep() + sep.after;
			writeNew(value, valueModel(object, member), expanded);
			return;
		}
		final gaps: MemberGaps = memberGaps(member);
		_out += slice(new Span(spanOf(member).from, gaps.before.from));
		final sep: Null<KeySep> = style?.keySep;
		_out += (sep != null && isDirty(gaps.before) ? sep.before : slice(gaps.before)) + keyValueSep()
			+ (sep != null && isDirty(gaps.after) ? sep.after : slice(gaps.after));
		writeValue(value, isNew(value) ? valueModel(object, member) : null, expanded);
	}

	/**
	 * A node an edit introduced, laid out like `model` — the nearest sibling of its kind — or, with
	 * none, expanded exactly when `expandedDefault` says its container is. A scalar is its own source;
	 * an empty container stays `[]` / `{}`.
	 */
	private function writeNew(node: QueryNode, model: Null<QueryNode>, expandedDefault: Bool): Void {
		if (!JsonProjection.isContainer(node)) {
			_out += slice(spanOf(node));
			return;
		}
		if (node.children.length == 0) {
			_out += openOf(node) + closeOf(node);
			return;
		}
		final shaped: Null<QueryNode> = model != null && model.kind == node.kind && model.children.length > 0 ? model : null;
		final expanded: Bool = shaped == null ? expandedDefault : spansLines(shaped);
		final indent: String = currentLineIndent();
		final gaps: InlineGaps = shaped == null ? { first: '', sep: ' ', close: '' } : inlineGapsOf(shaped);
		final sep: KeySep = node.kind == JsonProjection.OBJECT ? keySepOf(shaped ?? node) : { before: '', after: ' ' };
		_out += openOf(node);
		final last: Int = node.children.length - 1;
		for (i => child in node.children) {
			_out += expanded ? _lineEnd + indent + _unit : i == 0 ? gaps.first : gaps.sep;
			if (node.kind == JsonProjection.OBJECT) {
				_out += keyText(child) + sep.before + keyValueSep() + sep.after;
				writeNew(child.children[0], shaped == null ? null : memberValueModel(shaped, child), expanded);
			} else
				writeNew(child, shaped?.children.find(c -> c.kind == child.kind), expanded);
			if (i < last) _out += entrySep();
		}
		_out += (expanded ? _lineEnd + indent : gaps.close) + closeOf(node);
	}

	/**
	 * The gap and comma positions of `node`'s entries: the gap before each entry, the gap between
	 * an entry and its following `,` (null when none follows — only the last entry may lack one), and
	 * the gap before the closing delimiter.
	 */
	private function layoutOf(node: QueryNode): ContainerLayout {
		final span: Span = spanOf(node);
		final close: Int = span.to - 1;
		expectAt(span.from, openOf(node));
		expectAt(close, closeOf(node));
		final leads: Array<Span> = [];
		final preCommas: Array<Null<Span>> = [];
		var at: Int = span.from + 1;
		final last: Int = node.children.length - 1;
		for (i => item in node.children) {
			final itemSpan: Span = spanOf(item);
			leads.push(new Span(at, itemSpan.from));
			final next: Int = skipSpace(itemSpan.to, close);
			if (next < close && _text.charAt(next) == entrySep()) {
				preCommas.push(new Span(itemSpan.to, next));
				at = next + 1;
			} else {
				if (i < last) throw new Exception('json writer: no "${entrySep()}" after the entry at offset ${itemSpan.from}');
				preCommas.push(null);
				at = itemSpan.to;
			}
		}
		return { leads: leads, preCommas: preCommas, close: new Span(at, close) };
	}

	/** Does `node` need a style — is one of its entries new, or one of its gaps touched by a mark? */
	private function needsStyle(node: QueryNode, layout: ContainerLayout): Bool {
		if (isDirty(layout.close) || layout.leads.exists(isDirty)) return true;
		if (node.children.exists(isNew)) return true;
		if (layout.preCommas.exists(gap -> gap != null && isDirty(gap))) return true;
		return node.kind == JsonProjection.OBJECT && node.children.exists(member -> {
			final gaps: MemberGaps = memberGaps(member);
			isDirty(gaps.before) || isDirty(gaps.after);
		});
	}

	/**
	 * The gaps `node`'s untouched entries use, which a touched gap and a new entry take over: expanded
	 * when an untouched gap before an entry holds a line break (else when the untouched closing gap
	 * does, else when an existing entry survives — inline — else the parent's shape).
	 */
	private function styleOf(node: QueryNode, layout: ContainerLayout, parentExpanded: Bool): ContainerStyle {
		final indent: String = currentLineIndent();
		final kept: Array<Span> = [
			for (i => item in node.children) if (!isNew(item) && !isDirty(layout.leads[i])) layout.leads[i]
		];
		final closeKept: Bool = !isDirty(layout.close);
		final expanded: Bool = expandedOf(node, kept, closeKept ? layout.close : null, parentExpanded);
		final broken: Null<Span> = kept.find(gap -> slice(gap).indexOf('\n') >= 0);
		final childIndent: String = broken == null ? indent + _unit : afterLastBreak(slice(broken));
		final first: Null<Span> = layout.leads.length > 0 && kept.contains(layout.leads[0]) ? layout.leads[0] : null;
		final later: Null<Span> = kept.find(gap -> gap != layout.leads[0]);
		final preComma: Null<Span> = layout.preCommas.find(gap -> gap != null && !isDirty(gap));
		final firstGap: String = first == null ? '' : slice(first);
		final sepGap: String = later == null ? ' ' : slice(later);
		final close: String = if (node.children.length == 0)
			''
		else if (expanded)
			_lineEnd + indent
		else if (closeKept)
			slice(layout.close)
		else
			'';
		return new ContainerStyle(
			expanded, expanded ? _lineEnd + childIndent : firstGap, expanded ? _lineEnd + childIndent : sepGap, close,
			preComma == null ? '' : slice(preComma), node.kind == JsonProjection.OBJECT ? keySepOf(node) : { before: '', after: ' ' }
		);
	}

	/**
	 * Is the touched container `node` laid out one entry per line: when an untouched gap before an entry
	 * (`kept`) holds a line break; else when its untouched closing gap (`close`, null when touched) does;
	 * else not when an existing entry survives — it is inline; else, with nothing left to copy, when its
	 * parent is.
	 */
	private function expandedOf(node: QueryNode, kept: Array<Span>, close: Null<Span>, parentExpanded: Bool): Bool {
		return if (kept.length > 0)
			kept.exists(gap -> slice(gap).indexOf('\n') >= 0)
		else if (close != null && slice(close).indexOf('\n') >= 0)
			true
		else if (node.children.exists(item -> !isNew(item)))
			false
		else
			parentExpanded;
	}

	/** The `:` spacing of `object`'s first untouched member, else the document's first member's, else `": "`. */
	private function keySepOf(object: QueryNode): KeySep {
		final own: Null<KeySep> = cleanKeySep(object);
		if (own != null) return own;
		final first: Null<KeySep> = firstKeySep(_root);
		return first ?? { before: '', after: ' ' };
	}

	/** The `:` spacing of `object`'s first member no mark touches, or null. */
	private function cleanKeySep(object: QueryNode): Null<KeySep> {
		for (member in object.children) if (!isNew(member)) {
			final gaps: MemberGaps = memberGaps(member);
			if (!isDirty(gaps.before) && !isDirty(gaps.after)) return { before: slice(gaps.before), after: slice(gaps.after) };
		}
		return null;
	}

	/** The `:` spacing of the first untouched member in `node`'s subtree, pre-order, or null. */
	private function firstKeySep(node: QueryNode): Null<KeySep> {
		if (node.kind == JsonProjection.OBJECT) {
			final own: Null<KeySep> = cleanKeySep(node);
			if (own != null) return own;
		}
		for (child in node.children) {
			final found: Null<KeySep> = firstKeySep(child);
			if (found != null) return found;
		}
		return null;
	}

	/** The inline gaps of the existing non-empty container `model`: before its first entry, between entries, before its closer. */
	private function inlineGapsOf(model: QueryNode): InlineGaps {
		final layout: ContainerLayout = layoutOf(model);
		return {
			first: slice(layout.leads[0]),
			sep: layout.leads.length > 1 ? slice(layout.leads[1]) : ' ',
			close: slice(layout.close)
		};
	}

	/** The nearest untouched sibling of the new element `item` in the array `array` with `item`'s kind, preceding first. */
	private function elementModel(array: QueryNode, item: QueryNode): Null<QueryNode> {
		final at: Int = array.children.indexOf(item);
		var i: Int = at - 1;
		while (i >= 0) {
			final sibling: QueryNode = array.children[i];
			if (!isNew(sibling) && sibling.kind == item.kind) return sibling;
			i--;
		}
		for (j in at + 1...array.children.length) {
			final sibling: QueryNode = array.children[j];
			if (!isNew(sibling) && sibling.kind == item.kind) return sibling;
		}
		return null;
	}

	/** The value of the nearest untouched sibling member of `member` in `object` whose value has the kind `member`'s has. */
	private function valueModel(object: QueryNode, member: QueryNode): Null<QueryNode> {
		final kind: String = member.children[0].kind;
		final at: Int = object.children.indexOf(member);
		var i: Int = at - 1;
		while (i >= 0) {
			final sibling: QueryNode = object.children[i];
			if (!isNew(sibling) && sibling.children[0].kind == kind) return sibling.children[0];
			i--;
		}
		for (j in at + 1...object.children.length) {
			final sibling: QueryNode = object.children[j];
			if (!isNew(sibling) && sibling.children[0].kind == kind) return sibling.children[0];
		}
		return null;
	}

	/** The value in the model object `model` that models `member`'s: the same key's when its kind matches, else the first of that kind. */
	private function memberValueModel(model: QueryNode, member: QueryNode): Null<QueryNode> {
		final kind: String = member.children[0].kind;
		final same: Null<QueryNode> = model.children.find(m -> m.name == member.name && m.children[0].kind == kind);
		final any: Null<QueryNode> = same ?? model.children.find(m -> m.children[0].kind == kind);
		return any?.children[0];
	}

	/** The two gaps around a member's `:` — before it (after the key) and after it (before the value). */
	private function memberGaps(member: QueryNode): MemberGaps {
		final colon: Int = JsonProjection.colonOf(member, _text);
		return {
			before: new Span(JsonProjection.keyEndOf(member, _text), colon),
			after: new Span(colon + 1, spanOf(member.children[0]).from)
		};
	}

	/** A member's key as written — its quotes and escapes included. */
	private function keyText(member: QueryNode): String {
		return slice(new Span(spanOf(member).from, memberGaps(member).before.from));
	}

	/**
	 * Does a mark touch the gap `gap`: overlap it, or — when either of the two is empty — share an
	 * offset with it. An edit that inserted the text after a `,` touches the gap that starts there; a
	 * deletion touches the gap it closed up.
	 */
	private function isDirty(gap: Span): Bool {
		return _marks.exists(
			mark ->
				(mark.from < gap.to && gap.from < mark.to)
				|| ((mark.from == mark.to || gap.from == gap.to) && mark.from <= gap.to && gap.from <= mark.to)
		);
	}

	/** Did an edit introduce `node` — does a non-empty mark cover its whole span? */
	private function isNew(node: QueryNode): Bool {
		final span: Span = spanOf(node);
		return _marks.exists(mark -> mark.to > mark.from && mark.from <= span.from && span.to <= mark.to);
	}

	/** The leading horizontal whitespace of the output's current last line. */
	private function currentLineIndent(): String {
		final start: Int = _out.lastIndexOf('\n') + 1;
		var end: Int = start;
		while (end < _out.length && isIndent(_out.fastCodeAt(end))) end++;
		return _out.substring(start, end);
	}

	/** Is the root value written across several lines — the shape a container with nothing to copy falls back to? */
	private function documentSpansLines(span: Span): Bool {
		return slice(span).indexOf('\n') >= 0;
	}

	/** Is `node` written across several lines? */
	private function spansLines(node: QueryNode): Bool {
		return slice(spanOf(node)).indexOf('\n') >= 0;
	}

	private function skipSpace(from: Int, limit: Int): Int {
		var at: Int = from;
		while (at < limit && isSpace(_text.fastCodeAt(at))) at++;
		return at;
	}

	private function expectAt(at: Int, token: String): Void {
		if (_text.charAt(at) != token) throw new Exception('json writer: expected "$token" at offset $at');
	}

	/**
	 * `text` written back with every node inside a mark laid out like its siblings and every
	 * gap a mark touches re-derived — see the type doc. With no mark it is `text` itself. Throws the
	 * parser's `ParseError` when `text` does not parse.
	 */
	public static function layout(text: String, marks: Array<Span>): String {
		final document: QueryNode = JsonProjection.parse(text);
		final writer: JsonLayoutWriter = new JsonLayoutWriter(text, marks, document);
		return writer.writeDocument(document.children[0]);
	}

	/**
	 * Each edit's footprint in the document `CanonicalEdit.applyEdits` makes of `edits`: the range its
	 * text occupies there, zero-width for a deletion. Ascending by offset, ties narrowest first —
	 * the order `applyEdits` leaves the texts of two edits sharing an offset in.
	 */
	public static function marksOf(edits: Array<{ span: Span, text: String }>): Array<Span> {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from != b.span.from ? a.span.from - b.span.from : a.span.to - b.span.to);
		final marks: Array<Span> = [];
		var delta: Int = 0;
		for (edit in sorted) {
			final at: Int = edit.span.from + delta;
			marks.push(new Span(at, at + edit.text.length));
			delta += edit.text.length - (edit.span.to - edit.span.from);
		}
		return marks;
	}

	private static inline function spanOf(node: QueryNode): Span {
		return JsonProjection.spanOf(node);
	}

	private static inline function isIndent(code: Int): Bool {
		return code == ' '.code || code == '\t'.code;
	}

	private static inline function isSpace(code: Int): Bool {
		return JsonProjection.isSpace(code);
	}

	private static inline function openOf(node: QueryNode): String {
		return node.kind == JsonProjection.OBJECT ? JsonFormat.instance.mappingOpen : JsonFormat.instance.sequenceOpen ?? '[';
	}

	private static inline function closeOf(node: QueryNode): String {
		return node.kind == JsonProjection.OBJECT ? JsonFormat.instance.mappingClose : JsonFormat.instance.sequenceClose ?? ']';
	}

	private static inline function entrySep(): String {
		return JsonFormat.instance.entrySep;
	}

	private static inline function keyValueSep(): String {
		return JsonFormat.instance.keyValueSep;
	}

	/** The source text after the last line break of `gap` — the indentation it gives the line it opens. */
	private static function afterLastBreak(gap: String): String {
		return gap.substring(gap.lastIndexOf('\n') + 1);
	}

	/** The document's indent unit: its first indented line's leading whitespace, else the format default. */
	private static function indentUnit(text: String): String {
		var at: Int = text.indexOf('\n');
		while (at >= 0 && at + 1 < text.length) {
			var end: Int = at + 1;
			while (end < text.length && isIndent(text.fastCodeAt(end))) end++;
			if (end > at + 1 && end < text.length && text.fastCodeAt(end) != '\n'.code && text.fastCodeAt(end) != '\r'.code) {
				final first: String = text.charAt(at + 1);
				return first == IndentChar.Tab ? first : text.substring(at + 1, end);
			}
			at = text.indexOf('\n', at + 1);
		}
		final options: WriteOptions = JsonFormat.instance.defaultWriteOptions;
		return options.indentChar == IndentChar.Tab ? '\t' : ''.lpad(' ', options.indentSize);
	}

	/** The line end a line an edit adds takes: `\r\n` when the document holds one, else `\n`. */
	private static function lineEndOf(text: String): String {
		return text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
	}

}

/**
 * The gaps a touched container hands a new entry or a touched gap: before an entry (`first` for the
 * first, else `later`), before the closing delimiter, before a `,`, and around a member's `:`.
 */
@:nullSafety(Strict)
private final class ContainerStyle {

	public final expanded: Bool;
	public final close: String;
	public final preComma: String;
	public final keySep: KeySep;

	private final _first: String;
	private final _later: String;

	public function new(expanded: Bool, first: String, later: String, close: String, preComma: String, keySep: KeySep) {
		this.expanded = expanded;
		this.close = close;
		this.preComma = preComma;
		this.keySep = keySep;
		_first = first;
		_later = later;
	}

	/** The gap before entry `i`. */
	public inline function lead(i: Int): String {
		return i == 0 ? _first : _later;
	}

}

/** Where the gaps of one container sit: before each entry, before each entry's `,` (null: none follows), before the closer. */
private typedef ContainerLayout = {
	final leads: Array<Span>;
	final preCommas: Array<Null<Span>>;
	final close: Span;
}

/** The whitespace before and after a member's `:`. */
private typedef KeySep = {
	final before: String;
	final after: String;
}

/** The two gaps around one member's `:`. */
private typedef MemberGaps = {
	final before: Span;
	final after: Span;
}

/** The gaps of an inline container: before its first entry, between two entries, before its closer. */
private typedef InlineGaps = {
	final first: String;
	final sep: String;
	final close: String;
}
