package anyparse.format;

using StringTools;

/**
 * The formatter's non-whitespace invariant: a correct formatter changes only
 * WHITESPACE, so stripping every whitespace character from the input and from
 * the writer's output must leave two identical strings.
 *
 * This is the gate the writer's own round trip cannot be: that one asks "does
 * the output re-parse to the same tree", and a writer defect is invisible to
 * it whenever the parser accepts its own broken output. The conditional-region
 * separator bug was exactly that shape — `@:forward(a, #if f b, #end, c)`
 * parses here and dies in `haxe` — so `self-status`, `fmt --list` and `lint`
 * were all green on a tree that no longer compiled. Comparing bytes instead of
 * trees is what catches it, and a single pass over a real tree found several such sites.
 *
 * ## What it deliberately does NOT know
 *
 * Some formatter policies are token-level by design, and a divergence they
 * cause is CORRECT: braces added around a single statement
 * (`singleStmtBraces`), an optional `;` normalised in or out, a javadoc close
 * rewritten from `**\/` to `*\/`. This module reports the divergence and says
 * nothing about which kind it is — the caller reads it. Keeping the rule
 * "whitespace only" rather than encoding a policy list is what makes it a
 * useful diagnostic for a defect nobody has classified yet, which is the
 * situation it exists for.
 *
 * It knows exactly ONE token class: a `,` before a closing `]`, `)` or `}`
 * with only whitespace or comments between. The trailing-comma knob adds and
 * removes that token in any layout and it carries no meaning, so with
 * `remove` as the default every tree that holds one would otherwise fail
 * `--verify`. A comma anywhere else is still a divergence.
 *
 * A string or regex literal is NOT code: its text is compared byte for byte,
 * whitespace included, and a `,]` inside one is never the exempt token. The
 * regions come from the grammar's lexical scan, which shares nothing with the
 * parse tree or the writer under audit. Text the scan leaves out of its
 * literals (no literal regions, an unscannable source, a string holding code
 * the writer re-lays) keeps the whitespace-only rule.
 *
 * Pure and grammar-agnostic: whitespace is not a property of any one language,
 * and what a comment or a literal is arrives as the caller's `InertScan`.
 */
@:nullSafety(Strict)
final class WhitespaceInvariant {

	/** Non-whitespace characters quoted on each side of a divergence report. */
	private static inline final WINDOW: Int = 48;

	/**
	 * The first place `written` stops matching `source` once all whitespace is
	 * removed from both, or null when the invariant holds.
	 *
	 * The reported line is the SOURCE line the divergence starts on, so the
	 * caller can point at a file the user still has on disk; `expected` and
	 * `actual` quote the next run of non-whitespace characters from each side.
	 * A side that simply ran out reports an empty window, which is what a
	 * dropped or added trailing token looks like. `scan` reads the comments and
	 * literals of EACH text, so a trailing comma stays invisible through a comment.
	 */
	public static function firstDivergence(source: String, written: String, scan: InertScan): Null<Divergence> {
		final left: Stripped = strip(source, scan);
		final right: Stripped = strip(written, scan);
		final leftLen: Int = left.text.length;
		final rightLen: Int = right.text.length;
		final shared: Int = leftLen < rightLen ? leftLen : rightLen;
		var i: Int = 0;
		while (i < shared && left.text.charCodeAt(i) == right.text.charCodeAt(i)) i++;
		return i == shared && leftLen == rightLen ? null : {
			line: i < left.lines.length ? left.lines[i] : lastLine(left),
			expected: left.text.substr(i, WINDOW),
			actual: right.text.substr(i, WINDOW)
		};
	}

	/**
	 * `text` with every code whitespace character removed, plus the 1-based source line each kept character came from.
	 * A code `,` followed by a closing `]`, `)` or `}` with only whitespace or comments between is dropped: the
	 * trailing-comma knob adds and removes exactly that token in any layout, and the comment it can sit before
	 * (`2, // two` then `]`) stays in the text. Comment bytes never count as code, so a `,` or `]` inside one is inert.
	 * A literal region is kept BYTE FOR BYTE (a carriage return aside) and breaks the comma window: a `,]` inside a
	 * string is text, not a trailing comma.
	 */
	private static function strip(source: String, scan: InertScan): Stripped {
		final zones: ZoneMap = new ZoneMap(source, scan);
		final kept: Array<String> = [];
		final lines: Array<Int> = [];
		var line: Int = 1;
		var pending: Int = -1;
		var dropped: Int = 0;
		for (i in 0...source.length) {
			final c: Int = source.fastCodeAt(i);
			final zone: Zone = zones.zoneAt(i);
			if (zone == Literal) {
				pending = -1;
				if (c != '\r'.code) {
					kept.push(source.charAt(i));
					lines.push(line);
				}
				if (c == '\n'.code) line++;
				continue;
			}
			if (c == '\n'.code) {
				line++;
				continue;
			}
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) continue;
			if (zone == Code) {
				if (pending >= 0 && (c == ']'.code || c == ')'.code || c == '}'.code)) {
					kept[pending] = '';
					dropped++;
				}
				pending = c == ','.code ? kept.length : -1;
			}
			kept.push(source.charAt(i));
			lines.push(line);
		}
		return dropped == 0 ? { text: kept.join(''), lines: lines } : compact(kept, lines);
	}

	/** `kept` and `lines` without the entries emptied by `strip`, which keeps the two arrays aligned. */
	private static function compact(kept: Array<String>, lines: Array<Int>): Stripped {
		final text: StringBuf = new StringBuf();
		final keptLines: Array<Int> = [];
		for (i => piece in kept) if (piece != '') {
			text.add(piece);
			keptLines.push(lines[i]);
		}
		return { text: text.toString(), lines: keptLines };
	}

	/** The last line the stripped source reached — the report position when the SOURCE is the side that ran out. */
	private static function lastLine(stripped: Stripped): Int {
		return stripped.lines.length == 0 ? 1 : stripped.lines[stripped.lines.length - 1];
	}

}

/** Where two whitespace-stripped strings first disagree, with a window of each side for the report. */
typedef Divergence = {
	final line: Int;
	final expected: String;
	final actual: String;
};

/** A whitespace-stripped string plus the 1-based source line of each surviving character. */
private typedef Stripped = {
	final text: String;
	final lines: Array<Int>;
};

/**
 * A grammar's non-code regions, handed to `WhitespaceInvariant` so it stays grammar-agnostic.
 *
 * `scan(source, onRegion)` reports every comment, string literal and regex literal of `source` as a
 * `[start, end)` byte span in source order, with `literal` true for a string or regex and false for a comment.
 * Source the grammar cannot scan reports nothing, so all of it is code.
 */
typedef InertScan = (source:String, onRegion:(start:Int, end:Int, literal:Bool) -> Void) -> Void;

/** What one source byte is to the invariant. */
private enum abstract Zone(Int) {
	final Code = 0;
	final Comment = 1;
	final Literal = 2;
}

/** The `Zone` of each byte of one source. */
private final class ZoneMap {

	private final _zones: Array<Zone>;

	public function new(source: String, scan: InertScan) {
		final zones: Array<Zone> = [for (_ in 0...source.length) Code];
		scan(source, (start, end, literal) -> for (i in start ... (end < source.length ? end : source.length))
			zones[i] = literal ? Literal : Comment);
		_zones = zones;
	}

	public function zoneAt(offset: Int): Zone {
		return _zones[offset];
	}

}
