package anyparse.macro;

using StringTools;

/**
 * Reads a terminal's regex pattern into a `ScanNode` tree, or answers `null` for a pattern outside the subset it
 * knows: a capture group, a lazy or counted quantifier, a backreference, `^`, `$`, a non-ASCII character.
 * A refusal costs the terminal its compiled scan, never a wrong answer: it stays on the regex engine.
 *
 * Where the engines disagree on a set (`.`, `\s`) the tree spells the ECMAScript one, the engine the project runs on.
 * Not `#if macro`, for the reason `CodeSet` is not.
 */
@:nullSafety(Strict)
final class RegexScanReader {

	/** The highest code a pattern may spell. */
	private static inline final MAX_ASCII: Int = 0x7F;

	private static inline final FORM_FEED: Int = 12;
	private static inline final VERTICAL_TAB: Int = 11;

	private final _pattern: String;

	private var _pos: Int = 0;
	private var _refused: Bool = false;

	private function new(pattern: String) {
		_pattern = pattern;
	}

	private inline function peek(): Int {
		return _pos < _pattern.length ? _pattern.fastCodeAt(_pos) : -1;
	}

	private inline function nextIsBracketEnd(): Bool {
		return _pos + 1 < _pattern.length && _pattern.fastCodeAt(_pos + 1) == ']'.code;
	}

	private function refuse(): ScanNode {
		_refused = true;
		_pos = _pattern.length;
		return Seq([]);
	}

	private function alternation(): ScanNode {
		final branches: Array<ScanNode> = [sequence()];
		while (peek() == '|'.code) {
			_pos++;
			branches.push(sequence());
		}
		return branches.length == 1 ? branches[0] : Alt(branches);
	}

	private function sequence(): ScanNode {
		final items: Array<ScanNode> = [];
		while (true) {
			final c: Int = peek();
			if (c == -1 || c == '|'.code || c == ')'.code) break;
			items.push(quantified(element()));
		}
		return items.length == 1 ? items[0] : Seq(items);
	}

	private function quantified(node: ScanNode): ScanNode {
		final c: Int = peek();
		final quantifier: Bool = c == '*'.code || c == '+'.code || c == '?'.code;
		if (!quantifier) return c == '{'.code ? refuse() : node;
		_pos++;
		final next: Int = peek();
		if (next == '?'.code || next == '+'.code || next == '{'.code) return refuse();
		return switch node {
			case Ahead(_, _), WordBoundary: refuse();
			case _: Repeat(node, c == '+'.code ? 1 : 0, c != '?'.code);
		};
	}

	private function element(): ScanNode {
		final c: Int = peek();
		_pos++;
		return switch c {
			case '('.code: group();
			case '['.code: bracket();
			case '.'.code: Chars(CodeSet.ofChars('\n\r  ').complement());
			case '\\'.code: escape();
			case '^'.code, '$'.code, '*'.code, '+'.code, '?'.code, '{'.code, '}'.code, ']'.code: refuse();
			case _: c > MAX_ASCII ? refuse() : Chars(CodeSet.single(c));
		};
	}

	/** The rest of a group whose `(` is consumed. */
	private function group(): ScanNode {
		if (peek() != '?'.code) return refuse();
		_pos++;
		final kind: Int = peek();
		_pos++;
		if (kind != ':'.code && kind != '='.code && kind != '!'.code) return refuse();
		final body: ScanNode = alternation();
		if (peek() != ')'.code) return refuse();
		_pos++;
		return kind == ':'.code ? body : Ahead(body, kind == '!'.code);
	}

	/** An escape whose `\` is consumed, outside a bracket. */
	private function escape(): ScanNode {
		if (peek() == 'b'.code) {
			_pos++;
			return WordBoundary;
		}
		final set: Null<CodeSet> = escapedSet();
		return set == null ? refuse() : Chars(set);
	}

	/** The set of the escape at the cursor, consumed, or `null` for one this reader does not know. */
	private function escapedSet(): Null<CodeSet> {
		final c: Int = peek();
		_pos++;
		return switch c {
			case 'n'.code: CodeSet.single('\n'.code);
			case 'r'.code: CodeSet.single('\r'.code);
			case 't'.code: CodeSet.single('\t'.code);
			case 'f'.code: CodeSet.single(FORM_FEED);
			case 'v'.code: CodeSet.single(VERTICAL_TAB);
			case 'd'.code: digitSet();
			case 'D'.code: digitSet().complement();
			case 'w'.code: wordSet();
			case 'W'.code: wordSet().complement();
			case 's'.code: spaceSet();
			case 'S'.code: spaceSet().complement();
			case _: isPunctuation(c) ? CodeSet.single(c) : null;
		};
	}

	/** The rest of a `[…]` whose `[` is consumed. */
	private function bracket(): ScanNode {
		final negated: Bool = peek() == '^'.code;
		if (negated) _pos++;
		var set: CodeSet = CodeSet.empty();
		while (peek() != ']'.code) {
			final member: Null<CodeSet> = bracketMember();
			if (member == null) return refuse();
			set = set.union(member);
		}
		_pos++;
		return Chars(negated ? set.complement() : set);
	}

	/** One member at the cursor, a range when it holds one, or `null` for one this reader does not know. */
	private function bracketMember(): Null<CodeSet> {
		final low: Null<CodeSet> = bracketAtom();
		if (low == null || peek() != '-'.code || nextIsBracketEnd()) return low;
		_pos++;
		final high: Null<CodeSet> = bracketAtom();
		if (high == null) return null;
		final lo: Int = low.soleCode();
		final hi: Int = high.soleCode();
		return lo < 0 || hi < lo ? null : CodeSet.of([lo, hi]);
	}

	/** One character or class escape inside a bracket, consumed; `null` at the end of the pattern too. */
	private function bracketAtom(): Null<CodeSet> {
		final c: Int = peek();
		if (c == -1 || c == '['.code || c > MAX_ASCII) return null;
		_pos++;
		return c == '\\'.code ? escapedSet() : CodeSet.single(c);
	}

	/** The tree of `pattern`, or `null` when the reader does not know all of it. */
	public static function read(pattern: String): Null<ScanNode> {
		final reader: RegexScanReader = new RegexScanReader(pattern);
		final node: ScanNode = reader.alternation();
		return reader._refused || reader._pos < pattern.length ? null : node;
	}

	/** `\w`. */
	public static function wordSet(): CodeSet {
		return CodeSet.of(['0'.code, '9'.code, 'A'.code, 'Z'.code, '_'.code, '_'.code, 'a'.code, 'z'.code]);
	}

	/** `\s` in ECMAScript. */
	private static inline function spaceSet(): CodeSet {
		return CodeSet.ofChars('\t\n\u000B\u000C\r                  　﻿');
	}

	private static function isPunctuation(c: Int): Bool {
		if (c < 0 || c > MAX_ASCII) return false;
		final letterOrDigit: Bool = c >= '0'.code && c <= '9'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code;
		return !letterOrDigit;
	}

	/** `\d`. */
	private static function digitSet(): CodeSet {
		return CodeSet.of(['0'.code, '9'.code]);
	}

}
