package anyparse.grammar.haxe;

import anyparse.query.SourceText;

using StringTools;

/**
 * The Haxe IDENTIFIER layer of the naming policy: the reserved-word vocabulary a derived name
 * must avoid, and the case conversions the policy's `NamingRule.normalize` / `normalizeAlt`
 * function values are drawn from.
 *
 * Split out of `HaxeNamingSupport`, which owns the POLICY — which declarations a grammar
 * projects, which category each falls in, which rule governs it, and which of them a framework
 * already claims. None of that reaches here: every member below is a pure function of a string
 * (plus the keyword list), with no node, no scope and no index. That is the seam `hxq clusters`
 * named — a connected component of six members with no edge to the rest of the type — and it is
 * the reason the two live apart rather than the member count alone.
 *
 * `camelCore` is the single shared conversion; `underscoreCamel` and `snakeToCamel` differ only
 * by the `_` prefix and the keyword test, which is exactly why neither reimplements it.
 */
@:nullSafety(Strict)
final class HaxeIdentifierCase {

	/**
	 * Haxe reserved keywords. A de-prefixed local whose bare name lands on one of
	 * these is not a usable identifier, so its rename is skipped (report-only).
	 * Published through `RefShape.reservedWords` for the checks that DERIVE an
	 * identifier without going through a policy normalizer.
	 */
	public static final KEYWORDS: Array<String> = [
		'abstract',
		'break',
		'case',
		'cast',
		'catch',
		'class',
		'continue',
		'default',
		'do',
		'dynamic',
		'else',
		'enum',
		'extends',
		'extern',
		'false',
		'final',
		'for',
		'function',
		'if',
		'implements',
		'import',
		'in',
		'inline',
		'interface',
		'is',
		'macro',
		'new',
		'null',
		'operator',
		'overload',
		'override',
		'package',
		'private',
		'public',
		'return',
		'static',
		'super',
		'switch',
		'this',
		'throw',
		'true',
		'try',
		'typedef',
		'untyped',
		'using',
		'var',
		'while'
	];

	/**
	 * The mechanical fix for a private field missing its `_` prefix: prepend `_` to the shared
	 * `camelCore` (`shape` -> `_shape`, `Shape` -> `_shape`, `HEIGHT` -> `_height`, `URLPath` ->
	 * `_urlPath`, `CELLS_NUM_X` -> `_cellsNumX`). Sharing `camelCore` - and through it
	 * `smartSegment` - is what stops the fix MANUFACTURING a lowercase-head-over-caps-tail name
	 * (`_hEIGHT`), which the `naming` artifact arm could never report back: its pattern is anchored
	 * at the head, and the `_` prefix hides it. Splitting on `_` is what makes an UPPER_SNAKE
	 * private field FIXABLE rather than report-only - the rule's own format (`^_[a-z][a-zA-Z0-9]*$`)
	 * admits no internal underscore, so a name that keeps one can never satisfy the rule it is
	 * being corrected for. No keyword test: every result opens with `_`, so none can be a keyword.
	 * Not `inline` - passed as a `NamingRule.normalize` function value.
	 */
	public static function underscoreCamel(name: String): Null<String> {
		final core: Null<String> = camelCore(name);
		return core == null ? null : '_$core';
	}

	/**
	 * The mechanical fix for a static final wrongly given a private-field `_` prefix:
	 * strip the leading underscore(s), keeping the result whenever it is a
	 * syntactically valid identifier (`_forceBuild` → `forceBuild`, `_FORCE_BUILD` →
	 * `FORCE_BUILD`). Whether the stripped name actually conforms to the Constant
	 * rule's format is decided by the caller (`Naming.renameEditsFor` gates on
	 * `rule.format.match`), so both camelCase and UPPER_SNAKE pass here while a name
	 * matching neither (`_FORCE_build` → `FORCE_build`) is filtered there. A strip that
	 * leaves an invalid identifier, or one that lands on a Haxe keyword (`_new` → `new`, the
	 * CONSTRUCTOR name), → null. Not `inline` — passed as a `NamingRule.normalize` function value.
	 */
	public static function stripUnderscorePrefix(name: String): Null<String> {
		var i: Int = 0;
		while (i < name.length && name.fastCodeAt(i) == '_'.code) i++;
		if (i == 0) return null;
		final stripped: String = name.substr(i);
		return new EReg("^[a-zA-Z][a-zA-Z0-9_]*$", '').match(stripped) && !KEYWORDS.contains(stripped) ? stripped : null;
	}

	/**
	 * The mechanical fix for a local / param / catch name violating camelCase: the shared
	 * `camelCore` (`_items` -> `items`, `__scaleX` -> `scaleX`, `MyLocal` -> `myLocal`, `min_gap` ->
	 * `minGap`), refused when the result is a Haxe keyword (`_new` -> `new`) - not a usable
	 * identifier here, unlike under `underscoreCamel`'s `_` prefix, so the binding stays
	 * report-only. Subsumes the former de-prefix / lowercase-first normalizers. Not `inline` -
	 * passed as a `NamingRule.normalize` function value.
	 */
	public static function snakeToCamel(name: String): Null<String> {
		final lowered: Null<String> = camelCore(name);
		return lowered == null || KEYWORDS.contains(lowered) ? null : lowered;
	}

	/**
	 * `name` respelled UPPER_SNAKE, or null when that changes nothing or does not spell an
	 * identifier. The constant rule's `normalizeAlt`: its format's other branch.
	 */
	public static function upperSnakeConstant(name: String): Null<String> {
		final upper: String = SourceText.upperSnake(name);
		return upper != name && SourceText.isIdentifier(upper) ? upper : null;
	}

	/** Whether `c` is an ASCII decimal digit. */
	private static inline function isDigit(c: Int): Bool {
		return c >= '0'.code && c <= '9'.code;
	}

	/**
	 * The camelCase core both `snakeToCamel` and `underscoreCamel` correct through: strip every
	 * leading underscore, split the rest on `_`, apply `smartSegment`'s word policy per segment,
	 * join with capitalised heads, and lowercase the first letter. An all-uppercase segment is
	 * lowercased whole (`MISSING_FILE` -> `missingFile`); a segment opening with an acronym run
	 * keeps only that run's last character capitalised (`URLPath` -> `urlPath`); a mixed-case
	 * segment is preserved (`coachingQualification_Id` -> `coachingQualificationId`). Null when
	 * nothing survives the strip (`_`, `__`), or when a separator falls between two DIGIT runs and
	 * camelCase therefore cannot re-encode it (see the loop). The keyword test and the `_` prefix
	 * belong to the callers - that is the whole of what the two corrections differ by.
	 */
	private static function camelCore(name: String): Null<String> {
		var start: Int = 0;
		while (start < name.length && name.fastCodeAt(start) == '_'.code) start++;
		final segments: Array<String> = [for (s in name.substr(start).split('_')) if (s.length > 0) smartSegment(s)];
		if (segments.length == 0) return null;
		final buf: StringBuf = new StringBuf();
		buf.add(segments[0]);
		for (i in 1...segments.length) {
			final seg: String = segments[i];
			final prev: String = segments[i - 1];
			// A `_` BETWEEN TWO DIGIT RUNS is the one separator camelCase cannot re-encode: the capital
			// that marks every other segment boundary does not exist for a digit, so the two runs fuse
			// into one and the name changes meaning - `_u5_7` (an age band "U5 - 7") would read as
			// `_u57`, and `_u1_14` / `_u11_4` would BOTH land on `_u1114`. A digit run next to a LETTER
			// keeps its boundary either way (`HEADLINE_1` -> `Headline1`, `1_TEXTFORMAT` -> `1Textformat`),
			// so only this pairing refuses. No derivable correction means the declaration stays
			// report-only, which is what the rule already did for every multi-segment name before the
			// split landed.
			if (isDigit(seg.fastCodeAt(0)) && isDigit(prev.fastCodeAt(prev.length - 1))) return null;
			buf.add(seg.charAt(0).toUpperCase() + seg.substr(1));
		}
		final joined: String = buf.toString();
		return joined.charAt(0).toLowerCase() + joined.substr(1);
	}

	/**
	 * One `snake_case` segment normalized. An ALL-UPPERCASE segment (a screaming
	 * constant word like `FILE`) is lowercased whole so the camel join reads
	 * naturally (`missingFile`, not `mISSINGFILE`). A segment OPENING with an acronym
	 * run - two or more uppercase (or embedded digit) characters immediately followed by
	 * a lowercase letter - lowercases that run EXCEPT its last character, which heads the
	 * next word (`URLPath` -> `urlPath`, `HTTP2Server` -> `http2Server`). Any other segment
	 * carrying a lowercase letter is kept verbatim, preserving an already-camel word (`Id`,
	 * `scaleX`). A digit-only segment has no letters and is kept as-is. Not `inline` - a
	 * helper of `snakeToCamel`.
	 */
	private static function smartSegment(segment: String): String {
		if (new EReg("^[A-Z][A-Z0-9]*$", '').match(segment)) return segment.toLowerCase();
		final run: Int = leadingAcronymRun(segment);
		return run < 2 ? segment : segment.substr(0, run - 1).toLowerCase() + segment.substr(run - 1);
	}

	/**
	 * The length of `segment`'s leading uppercase (or embedded-digit) run when a LOWERCASE
	 * letter follows it, else 0: `URLPath` -> 4, `HTTP2Server` -> 6, `MyLocal` -> 1,
	 * `HEIGHT` -> 0 (nothing follows the run), `scaleX` -> 0. A digit counts only inside the
	 * run, never as its first character, so a name can never open with a digit anyway.
	 */
	private static function leadingAcronymRun(segment: String): Int {
		var i: Int = 0;
		while (i < segment.length) {
			final c: Int = segment.fastCodeAt(i);
			final upper: Bool = c >= 'A'.code && c <= 'Z'.code;
			final digit: Bool = i > 0 && c >= '0'.code && c <= '9'.code;
			if (!upper && !digit) break;
			i++;
		}
		if (i == 0 || i >= segment.length) return 0;
		final next: Int = segment.fastCodeAt(i);
		return next >= 'a'.code && next <= 'z'.code ? i : 0;
	}

}
