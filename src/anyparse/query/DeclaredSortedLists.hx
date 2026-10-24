package anyparse.query;

import anyparse.query.ModulePathTokens.TextEdit;
import anyparse.runtime.Span;
import haxe.ds.ArraySort;
import haxe.ds.Either;

using Lambda;

/** One part of a declared sorted list: the file and the address (`Address` selector) of its array literal. */
typedef SortedListPart = {
	final file: String;
	final select: String;
}

/** One string element of a part: its literal as written and its content between the quotes. */
private typedef ListEntry = {
	final literal: String;
	final content: String;
}

/** One part read off a source: its array's span, its entries, and the separators that frame them. */
private typedef ReadPart = {
	final array: Span;
	final entries: Array<ListEntry>;
	final lead: String;
	final sep: String;
	final trail: String;
}

/**
 * A list of string literals a project keeps SORTED (code-unit order), possibly cut into consecutive parts across files —
 * a registry of class names, a census of pins — declared to the relocation op so an entry whose text a module move
 * rewrote goes back to its sorted place, in the part whose range holds it.
 *
 * A part's range is fixed by the list as it stood BEFORE the rewrite: part `i` holds the entries from its own first entry
 * up to the next part's first one. Each entry is assigned by that range and each part re-sorted, so the parts concatenated
 * stay sorted. A list that was not sorted before, an element that is not a plain string literal, a part whose separators
 * carry anything but layout (a comment), or a part the rewrite would empty is refused rather than rewritten.
 */
@:nullSafety(Strict)
final class DeclaredSortedLists {

	/**
	 * The edits, per file, that put `parts` back in sorted order in the `after` texts, given the `before` texts the list
	 * was sorted in; `Left` names why the list cannot be re-sorted. A list none of whose files the rewrite changed is not
	 * read, and a list whose entries it left unchanged gets no edit.
	 */
	public static function resort(
		parts: Array<SortedListPart>, before: Map<String, String>, after: Map<String, String>, plugin: GrammarPlugin
	): Either<String, Map<String, Array<TextEdit>>> {
		if (!parts.exists(p -> before[p.file] != after[p.file])) return Right([]);
		final was: Array<ReadPart> = [];
		final now: Array<ReadPart> = [];
		for (part in parts) switch [readIn(part, before, plugin), readIn(part, after, plugin)] {
			case [Right(a), Right(b)]:
				was.push(a);
				now.push(b);
			case [Left(message), _], [_, Left(message)]:
				return Left(message);
		}
		final oldAll: Array<String> = [for (p in was) for (e in p.entries) e.content];
		final newAll: Array<String> = [for (p in now) for (e in p.entries) e.content];
		if (oldAll.join('\n') == newAll.join('\n')) return Right([]);
		for (i in 1...oldAll.length) if (oldAll[i - 1] > oldAll[i])
			return Left('sorted list ${describe(parts)} is not sorted before the move ("${oldAll[i - 1]}" precedes "${oldAll[i]}")');
		final assigned: Array<Array<ListEntry>> = distribute(was, now);
		final out: Map<String, Array<TextEdit>> = [];
		for (i => p in now) {
			final entries: Array<ListEntry> = assigned[i];
			if (entries.length == 0) return Left('sorted list part ${parts[i].file} (${parts[i].select}) would be left empty — refusing');
			ArraySort.sort(entries, (a, b) -> compare(a.content, b.content));
			if ([for (e in entries) e.literal].join('\n') == [for (e in p.entries) e.literal].join('\n')) continue;
			final edits: Array<TextEdit> = out[parts[i].file] ?? [];
			edits.push({ span: p.array, text: '[${p.lead}${[for (e in entries) e.literal].join(p.sep)}${p.trail}]' });
			out[parts[i].file] = edits;
		}
		return Right(out);
	}

	/**
	 * The content of an element written as one quoted literal, or several joined by `+`, none carrying an escape or an
	 * interpolation; null for any other element.
	 */
	public static function plainContent(literal: String): Null<String> {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		final n: Int = literal.length;
		while (true) {
			while (i < n && literal.isSpace(i)) i++;
			if (i >= n) return null;
			final q: String = literal.charAt(i);
			if (q != "'" && q != '"') return null;
			final close: Int = literal.indexOf(q, i + 1);
			if (close < 0) return null;
			final piece: String = literal.substring(i + 1, close);
			if (piece.indexOf('\\') >= 0 || piece.indexOf('$') >= 0) return null;
			buf.add(piece);
			i = close + 1;
			while (i < n && literal.isSpace(i)) i++;
			if (i >= n) return buf.toString();
			if (literal.charAt(i) != '+') return null;
			i++;
		}
	}

	/** `parts` named for a diagnostic. */
	private static function describe(parts: Array<SortedListPart>): String {
		return [for (p in parts) '${p.file} (${p.select})'].join(' + ');
	}

	/** One part of `source`: the array `part.select` addresses, its string entries and the text between them. */
	private static function readPart(part: SortedListPart, source: String, plugin: GrammarPlugin): Either<String, ReadPart> {
		final tree: QueryNode = switch ParseGate.parse(plugin, source, part.file) {
			case Parsed(t): t;
			case Unparsed(message): return Left(message);
		};
		final node: QueryNode = switch Address.resolve(tree, source, plugin, { select: part.select }) {
			case Ok(_, found) if (found != null): found;
			case Ok(_, _): return Left('sorted list part ${part.file}: "${part.select}" addresses no node');
			case Err(message): return Left('sorted list part ${part.file}: $message');
		};
		final span: Null<Span> = node.span;
		if (span == null || source.charAt(span.from) != '[' || source.charAt(span.to - 1) != ']')
			return Left('sorted list part ${part.file}: "${part.select}" is not an array literal');
		final entries: Array<ListEntry> = [];
		final gaps: Array<String> = [];
		var at: Int = span.from + 1;
		for (child in node.children) {
			final cs: Null<Span> = child.span;
			if (cs == null) return Left('sorted list part ${part.file}: an element has no source span');
			final literal: String = source.substring(cs.from, cs.to);
			final content: Null<String> = plainContent(literal);
			if (content == null) return Left('sorted list part ${part.file}: element $literal is not a plain string literal');
			gaps.push(source.substring(at, cs.from));
			final plain: String = content;
			entries.push({ literal: literal, content: plain });
			at = cs.to;
		}
		final trail: String = source.substring(at, span.to - 1);
		final lead: String = gaps.length > 0 ? gaps[0] : '';
		// Separators may differ only in layout (the writer sets a blank line around a wrapped element); the shortest one is
		// what the re-sorted list is joined with, and the writer's fixed point puts the blank lines back.
		var sep: String = ',$lead';
		for (i in 1...gaps.length) {
			if (gaps[i].charAt(0) != ',' || !isLayout(gaps[i].substr(1)))
				return Left('sorted list part ${part.file}: something other than layout follows ${entries[i - 1].literal}');
			if (i == 1 || gaps[i].length < sep.length) sep = gaps[i];
		}
		if (!isLayout(lead) || !isLayout(trail.split(',').join('')))
			return Left('sorted list part ${part.file}: something other than layout sits around its elements');
		final array: Span = span;
		return Right({
			array: array,
			entries: entries,
			lead: lead,
			sep: sep,
			trail: trail
		});
	}

	/** Whether `text` is whitespace only. */
	private static function isLayout(text: String): Bool {
		return text.trim() == '';
	}

	/** `part` read off `texts`, or why it cannot be. */
	private static function readIn(part: SortedListPart, texts: Map<String, String>, plugin: GrammarPlugin): Either<String, ReadPart> {
		final text: Null<String> = texts[part.file];
		return text == null ? Left('sorted list part ${part.file} is not in the analysed set') : readPart(part, text, plugin);
	}

	/**
	 * Every entry of `now`, assigned to the part whose range holds it — the range each part had in `was`: from its own first
	 * entry up to the next part's first.
	 */
	private static function distribute(was: Array<ReadPart>, now: Array<ReadPart>): Array<Array<ListEntry>> {
		final bounds: Array<Null<String>> = [for (i => p in was) i > 0 && p.entries.length > 0 ? p.entries[0].content : null];
		final assigned: Array<Array<ListEntry>> = [for (_ in now) []];
		for (p in now) for (e in p.entries) {
			var target: Int = 0;
			for (i => bound in bounds) if (bound != null && compare(bound, e.content) <= 0) target = i;
			assigned[target].push(e);
		}
		return assigned;
	}

	/** Code-unit order. */
	private static function compare(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

}
