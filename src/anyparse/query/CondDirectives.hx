package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexDirective;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.BodySkip.SkipMark;
import anyparse.runtime.BodySkip.SkipMarkRole;
import anyparse.runtime.CondCondition;
import anyparse.runtime.Input;
import anyparse.runtime.Span;

using anyparse.util.Strings;

/**
 * The shared conditional-compilation directive reader: the one place its consumers locate a
 * grammar's `#if` / `#elseif` / `#else` / `#end` occurrences in a source text and delimit each one's
 * condition.
 *
 * A directive is not a node. A `Conditional` region projects its BRANCH STATEMENTS as children and
 * the directive text itself survives only as trivia on the line, so every consumer that needs the
 * text has to read the source — and until this class there was no shared read, only per-caller
 * probes. The consumers of this class — the `redundant-condcomp-parens`, `cond-region-merge`,
 * `cond-assign-merge` and `member-order` checks, the branch projection's gap reading
 * (`CondBranchProjection.conditionalBranchRuns`) and `apq lit --include-directives` — would
 * otherwise have grown a lexer each.
 *
 * The scan is lexical: the keyword occurrences come from the grammar's generated lexical pass
 * (`RefShape.conditionalDirectives`), and the caller's non-code mask — the engine's single lexer through
 * `RefactorSupport.collectNonCodeRegions` — drops a `#if` written inside a comment, a string literal or
 * a regex literal. That masking bounds where a directive may START; the condition
 * scan itself reads raw text, so a block comment written INSIDE a condition is not masked and its
 * closing delimiter is read as ordinary condition text. An unterminated string swallows the rest of
 * the file as non-code, which costs a directive after it — acceptable, since the alternative is
 * guessing where the literal was meant to end.
 *
 * Needing no parse is what lets a consumer run on a file the grammar cannot parse.
 *
 * Grammar-agnostic: the keyword vocabulary comes from `RefShape.conditionalIfKeyword`,
 * `conditionalElseKeywords` and `conditionalEndKeyword`, which the grammar declares once with
 * `@:condDirectives`; a grammar declaring no opener, or publishing no directive walk, scans to nothing.
 */
@:nullSafety(Strict)
final class CondDirectives {

	/** The verbatim directive text of `directive` — its keyword plus its condition, e.g. `#if (sys)` / `#elseif js` / `#end`. */
	public static inline function text(source: String, directive: CondDirective): String {
		return source.substring(directive.span.from, directive.span.to);
	}

	/**
	 * Whether `source` holds an identifier character at `at` — the positional form of
	 * `isIdentChar`, for a caller asking whether a neighbour would lex into one token with an
	 * identifier spliced next to it. Out of range answers false: nothing there to weld with.
	 */
	public static inline function isIdentCharAt(source: String, at: Int): Bool {
		return at >= 0 && at < source.length && source.fastCodeAt(at).isIdentChar();
	}

	/**
	 * Every conditional-compilation directive in `source`, in source order. Empty when the
	 * grammar declares no opener keyword, or when the text holds none.
	 */
	public static function scan(source: String, shape: RefShape, regions: () -> Array<LexRegion>): Array<CondDirective> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final occurrences: Null<(source: String) -> Array<LexDirective>> = shape.conditionalDirectives;
		if (ifKeyword == null || ifKeyword == '' || occurrences == null || source.indexOf(ifKeyword) == -1) return [];
		final keywords: DirectiveKeywords = declaredKeywords(ifKeyword, shape);
		final masked: Array<Span> = SourceComments.collectNonCodeRegions(regions());
		final out: Array<CondDirective> = [];
		var region: Int = 0;
		var after: Int = 0;
		for (occurrence in occurrences(source)) {
			final at: Int = occurrence.from;
			// A keyword the previous directive's condition already read is part of that condition.
			if (at < after) continue;
			while (region < masked.length && masked[region].to <= at) region++;
			if (region < masked.length && at >= masked[region].from) continue;
			final directive: CondDirective = read(source, at, occurrence.keyword, keywords);
			out.push(directive);
			after = directive.span.to;
		}
		return out;
	}

	/**
	 * The TOP-LEVEL regions `directives` delimits, in source order — one entry per `#if` that no
	 * other region encloses, each carrying what a caller has to know before it may treat the
	 * region as a single lexical unit: whether it opens a branch of its own, whether it holds a
	 * nested region, and whether its two directives own their lines.
	 *
	 * A caller that MOVES a region's text needs all three. `move` carries a `#if`-guarded import
	 * block into another file: an `#else` arm has to travel with the `#if` (so the region is the
	 * unit, not the statement), a nested region cannot be reasoned about branch by branch, and an
	 * inline `#if sys import a; #end` shares its line with code the caller is not moving.
	 *
	 * An UNBALANCED scan stops the walk: the regions read so far are returned and the rest is not
	 * guessed at. A region left open at the end is not returned at all — the direction that costs a
	 * refusal rather than a text slice ending somewhere nobody chose.
	 */
	public static function topLevelBlocks(source: String, directives: Array<CondDirective>, shape: RefShape): Array<CondBlock> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		if (ifKeyword == null || endKeyword == null) return [];
		final out: Array<CondBlock> = [];
		for (region in ownRegions(directives, ifKeyword, shape.conditionalElseKeywords ?? [], endKeyword)) {
			final open: CondDirective = region.directives[0];
			final close: CondDirective = region.directives[region.directives.length - 1];
			out.push({
				span: new Span(open.span.from, close.span.to),
				condition: open.condition,
				headerEnd: open.span.to,
				closeFrom: close.span.from,
				singleBranch: region.directives.length == 2,
				flat: !region.nested,
				linewise: endsItsLine(source, open.span.to) && SourceText.startsItsLine(source, close.span.from)
			});
		}
		return out;
	}

	/**
	 * The one answer to "which directives does a region own at its own depth": for every `#if` that no
	 * other region encloses, its opener, its same-depth `#elseif` / `#else` and its closer, in source
	 * order — the directives of a NESTED region are skipped by depth. `nested` records that a region
	 * sat between them.
	 *
	 * An UNBALANCED list stops the walk at a closer with no opener: the regions read so far are
	 * returned. A region left open at the end is not returned at all.
	 */
	public static function ownRegions(
		directives: Array<CondDirective>, ifKeyword: String, elseKeywords: Array<String>, endKeyword: String
	): Array<OwnRegion> {
		final out: Array<OwnRegion> = [];
		var own: Array<CondDirective> = [];
		var nested: Bool = false;
		var depth: Int = 0;
		for (directive in directives) {
			if (directive.keyword == ifKeyword) {
				if (depth == 0) {
					own = [directive];
					nested = false;
				} else {
					nested = true;
				}
				depth++;
			} else if (directive.keyword == endKeyword) {
				if (depth == 0) return out;
				depth--;
				if (depth == 0) {
					own.push(directive);
					out.push({ directives: own, nested: nested });
				}
			} else if (depth == 1 && elseKeywords.contains(directive.keyword)) {
				own.push(directive);
			}
		}
		return out;
	}

	/**
	 * The own directives (`ownRegions`) of the ONE region that `region` spans, or null when the
	 * directives inside it do not form exactly one cleanly closed region — a stray closer, an
	 * unclosed opener, a second sibling region or a branch keyword outside any region.
	 */
	public static function ownDirectives(
		directives: Array<CondDirective>, region: Span, ifKeyword: String, elseKeywords: Array<String>, endKeyword: String
	): Null<Array<CondDirective>> {
		final inside: Array<CondDirective> = directives.filter(d -> d.span.from >= region.from && d.span.to <= region.to);
		final regions: Array<OwnRegion> = ownRegions(inside, ifKeyword, elseKeywords, endKeyword);
		if (regions.length != 1) return null;
		final own: Array<CondDirective> = regions[0].directives;
		return own[0] == inside[0] && own[own.length - 1] == inside[inside.length - 1] ? own : null;
	}

	/**
	 * Whether `span` owns the line it sits on — nothing but blanks on either side of it, with one
	 * optional statement terminator allowed after it (a grammar's own statement span may or may not
	 * reach over its `;`).
	 *
	 * The question a caller asks before MOVING a statement's text: an inline `#if sys import a; #end`
	 * puts a directive on the same line, and taking the statement alone would leave the directive
	 * behind with nothing between it and its `#end`.
	 */
	public static function ownsItsLine(source: String, span: Span): Bool {
		if (!SourceText.startsItsLine(source, span.from)) return false;
		var at: Int = span.to;
		if (at < source.length && source.fastCodeAt(at) == ';'.code) at++;
		return endsItsLine(source, at);
	}

	/**
	 * Whether only blanks stand between `at` and the end of its line — the forward half of
	 * `SourceText.startsItsLine`, which has no twin there.
	 *
	 * Public because the pair is what decides WHOLE-LINE hygiene for a caller rewriting a region:
	 * `CondResolve` widens an emptied region to its full lines only when its `#if` starts one and
	 * its `#end` ends one, and asking that of a private twin would mean a second copy of this scan.
	 */
	public static function endsItsLine(source: String, at: Int): Bool {
		var i: Int = at;
		while (
			i < source.length
			&& (source.fastCodeAt(i) == ' '.code || source.fastCodeAt(i) == '\t'.code || source.fastCodeAt(i) == '\r'.code)
		)
			i++;
		return i >= source.length || source.fastCodeAt(i) == '\n'.code;
	}

	/** Collapse internal whitespace runs in `condition` to single spaces, so two spellings of one condition compare equal. */
	public static function normalizeCondition(condition: String): String {
		return (~/\s+/g).replace(condition.trim(), ' ');
	}

	/**
	 * Whether `keyword` carries a condition. The declared CLOSER never does — checked first, because
	 * a closer spelled `#endif` would otherwise satisfy the branch test below. The opener always does;
	 * a branch keyword does exactly when it ENDS with the opener's bare word — `#elseif` does, `#else`
	 * does not. That is the shape of the branch keyword in every C-preprocessor-descended grammar, and
	 * the only discrimination the declared seams support without a third keyword list. A grammar whose
	 * branch keyword is spelled otherwise loses its condition span, never its directive.
	 */
	public static function takesCondition(keyword: String, ifKeyword: String, endKeyword: Null<String>): Bool {
		return keyword != endKeyword && (keyword == ifKeyword || keyword.endsWith(ifKeyword.substring(1)));
	}

	/**
	 * `source`'s directives as a declarations-only parse balances a skipped body against them (`BodySkip`): the
	 * grammar's opener opens a region, each else keyword starts its next branch, the closer ends it.
	 */
	public static function skipMarks(source: String, shape: RefShape, regions: Array<LexRegion>): Array<SkipMark> {
		final elseKeywords: Array<String> = shape.conditionalElseKeywords ?? [];
		return scan(source, shape, () -> regions)
			.map(directive -> {
				from: directive.span.from,
				to: directive.span.to,
				role: if (directive.keyword == shape.conditionalIfKeyword)
					SkipMarkRole.Open
				else if (directive.keyword == shape.conditionalEndKeyword)
					SkipMarkRole.Close
				else if (elseKeywords.contains(directive.keyword))
					SkipMarkRole.Next
				else
					SkipMarkRole.Other
			});
	}

	/**
	 * The grammar's condition-LESS branch keyword (Haxe `#else`), or null when it declares none. A branch
	 * keyword carries a condition exactly when `takesCondition` says so, so the bare one is the declared
	 * branch keyword it refuses.
	 */
	public static function bareBranchKeyword(shape: RefShape): Null<String> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		if (ifKeyword == null) return null;
		final closer: Null<String> = shape.conditionalEndKeyword;
		final bare: Array<String> = (
			shape.conditionalElseKeywords ?? []
		).filter(keyword -> keyword != '' && !takesCondition(keyword, ifKeyword, closer));
		return bare.length == 0 ? null : bare[0];
	}

	/** The directives of `directives` that START inside `[from, to)`, in source order. */
	public static function startingIn(directives: Array<CondDirective>, from: Int, to: Int): Array<CondDirective> {
		var i: Int = lowerBound(directives, from);
		return [while (i < directives.length && directives[i].span.from < to) directives[i++]];
	}

	/** The directive that starts exactly at `at`, or null. */
	public static function startingAt(directives: Array<CondDirective>, at: Int): Null<CondDirective> {
		final i: Int = lowerBound(directives, at);
		return i < directives.length && directives[i].span.from == at ? directives[i] : null;
	}

	/** The first directive spelled `keyword` that starts at or after `from`, or null. */
	public static function firstOf(directives: Array<CondDirective>, keyword: String, from: Int): Null<CondDirective> {
		for (i in lowerBound(directives, from) ... directives.length) if (directives[i].keyword == keyword) return directives[i];
		return null;
	}

	/** The condition of `directive`, whitespace-normalised for comparison, or null when it carries none. */
	public static function normalizedCondition(source: String, directive: CondDirective): Null<String> {
		final condition: Null<Span> = directive.condition;
		if (condition == null) return null;
		final raw: String = source.substring(condition.from, condition.to).trim();
		return raw == '' ? null : normalizeCondition(raw);
	}

	/**
	 * The opener and closer a keyword's condition-bearing-ness is decided against, and the grammar's readers of where a
	 * condition ends and of the blank around it.
	 */
	private static function declaredKeywords(ifKeyword: String, shape: RefShape): DirectiveKeywords {
		return {
			opener: ifKeyword,
			closer: shape.conditionalEndKeyword,
			conditionEnd: shape.conditionEnd,
			conditionBlankEnd: shape.conditionBlankEnd
		};
	}

	/**
	 * The directive starting at `from` with the already-matched `keyword`, condition included when it
	 * takes one.
	 */
	private static function read(source: String, from: Int, keyword: String, keywords: DirectiveKeywords): CondDirective {
		final afterKeyword: Int = from + keyword.length;
		final reader: Null<(input: Input, at: Int) -> Int> = keywords.conditionEnd;
		final blank: Null<(input: Input, at: Int) -> Int> = keywords.conditionBlankEnd;
		final condition: Null<Span> = reader != null && blank != null && takesCondition(keyword, keywords.opener, keywords.closer)
			? CondCondition.conditionAt(source, afterKeyword, reader, blank)
			: null;
		return { keyword: keyword, span: new Span(from, condition == null ? afterKeyword : condition.to), condition: condition };
	}

	/** The index of the first directive of the source-ordered `directives` that starts at or after `at`. */
	private static function lowerBound(directives: Array<CondDirective>, at: Int): Int {
		var low: Int = 0;
		var high: Int = directives.length;
		while (low < high) {
			final mid: Int = (low + high) >> 1;
			if (directives[mid].span.from < at)
				low = mid + 1
			else
				high = mid;
		}
		return low;
	}

}

/**
 * One conditional-compilation directive recovered by `CondDirectives.scan`: the `keyword` as the
 * grammar declares it, the `span` of the whole directive — from its marker character to the end
 * of its condition, or to the end of the keyword when it carries none — and `condition`, the span
 * of the condition text alone (null for a keyword that takes none, and for a condition-bearing
 * keyword whose tail the reader could not delimit).
 *
 * The span deliberately stops at the condition rather than at the end of the physical line: an
 * inline region (`#if sys trace(1); #end`) continues with ordinary code on the same line, and
 * neither a text search nor a fixer may be handed that as directive text.
 */
typedef CondDirective = { final keyword: String; final span: Span; final condition: Null<Span>; };

/**
 * One TOP-LEVEL conditional region, as `CondDirectives.topLevelBlocks` delimits it: `span` runs
 * from the `#if` marker to the end of the `#end` keyword, `headerEnd` is where the opening
 * directive stops and `closeFrom` where the closing one starts — the two offsets that bound the
 * region's BODY — and the three flags say how far the region may be treated as one unit.
 *
 * `singleBranch` is false once the region opens an `#elseif` / `#else` of its own; `flat` is false
 * once it holds a nested region; `linewise` is false for an inline `#if sys f(); #end`, whose
 * directives share their lines with code.
 */
typedef CondBlock = {
	final span: Span;
	final condition: Null<Span>;
	final headerEnd: Int;
	final closeFrom: Int;
	final singleBranch: Bool;
	final flat: Bool;
	final linewise: Bool;
};

/**
 * One top-level region's OWN directives as `CondDirectives.ownRegions` reads them (opener, same-depth
 * `#elseif` / `#else`, closer, in source order); `nested` is true once a region sat between them.
 */
typedef OwnRegion = { final directives: Array<CondDirective>; final nested: Bool; };

/**
 * What `CondDirectives.scan` threads through one walk: the opener / closer a keyword's condition-bearing-ness is
 * decided against, and the grammar's readers of where a condition ends and of the blank around it.
 */
private typedef DirectiveKeywords = {
	final opener: String;
	final closer: Null<String>;
	final conditionEnd: Null<(input: Input, at: Int) -> Int>;
	final conditionBlankEnd: Null<(input: Input, at: Int) -> Int>;
};
