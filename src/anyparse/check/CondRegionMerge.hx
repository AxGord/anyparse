package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CondDirectives;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags two ADJACENT conditional-compilation regions whose conditions say the same thing, and
 * merges them into one. Two shapes, both of them a pair of directive lines that carry no
 * information:
 *
 * ```haxe
 * #if mobile
 * a();
 * #end
 *
 * #if mobile
 * b();
 * #end
 * // -> one region, `#end` / `#if mobile` deleted
 *
 * #if mobile
 * a();
 * #end
 *
 * #if !mobile
 * b();
 * #end
 * // -> one region, `#end` / `#if !mobile` replaced by `#else`
 * ```
 *
 * The second shape reads the other way round too: an `#else` branch IS the negation of its own
 * `#if`, so a region that closes with `#else … #end` absorbs a following `#if !cond … #end`
 * wholesale — the dogfood corpus's motivating case, where a two-branch API switch was followed by
 * a separate block of members guarded by the negated flag.
 *
 * `Info`: nothing compiles differently, the merged form just spells the condition once. `--fix`
 * rewrites it.
 *
 * ## What is merged, and why exactly this much
 *
 * The fix is a SPLICE of the two directive lines at the boundary and nothing else — no member or
 * statement moves, so the merged region compiles to the same program branch by branch. That is
 * only true when the LAST branch of the first region and the FIRST branch of the second are the
 * same condition, which is what the four accepted combinations below enumerate (`A` is the first
 * region, `B` the second, `C1` / `C2` their conditions):
 *
 *  - `A` plain, `B` plain, `C1 == C2` — the boundary is deleted;
 *  - `A` plain, `B` with `#else`, `C1 == C2` — the boundary is deleted, `B`'s `#else` becomes the
 *    merged region's, meaning `!C1` exactly as it meant `!C2`;
 *  - `A` with `#else`, `B` plain, `C2 == !C1` — the boundary is deleted and `B`'s body lands in
 *    `A`'s `#else`, whose condition it already had;
 *  - `A` plain, `B` plain, `C2 == !C1` — the boundary becomes `#else`.
 *
 * Every other combination is REFUSED, because the splice alone would change what runs and the
 * rewrite that preserves it moves code:
 *
 *  - `A` with `#else` and `C1 == C2` — `B`'s body would land in the `#else`, i.e. under `!C1`;
 *  - `A` plain, `B` with `#else`, `C2 == !C1` — `B`'s `#else` body belongs to `C1`, so it would
 *    have to jump AHEAD of `B`'s own body to merge;
 *  - `#else` on both sides (two `#else` clauses cannot follow one another);
 *  - an `#elseif` anywhere in either region — the merged chain's `#else` would then mean
 *    `!(C1 || C2 || …)` rather than what the branch it came from meant.
 *
 * ## The gates
 *
 * Adjacency is the load-bearing one. The two regions must be consecutive in the directive scan
 * (nothing conditional between them) AND the source between their directive lines must be blank
 * or comment. A single statement in that gap makes the pair a false positive of exactly the kind
 * this rule exists to avoid: a verbose-log region before a lock acquire and another after it share
 * a condition and are two lines apart, and merging them would move the acquire out from between
 * them. Whatever the gap holds is preserved verbatim, in place.
 *
 * A directive must own its line: code before `#end` (an inline `#if cond f(); #end`) refuses
 * the pair outright, since the splice is line-based. A COMMENT the splice would absorb leaves the
 * finding report-only with a note instead: one written in the GAP would end up inside the merged
 * region, where a doc comment belonging to whatever follows the second `#end` would become
 * conditional, and one trailing either DIRECTIVE sits on a line the splice deletes.
 *
 * An unbalanced scan — an `#end` with nothing open, or a region left open at end of file — refuses
 * the WHOLE file: the region model is what decides which branch a body belongs to, and a model
 * that did not close cannot be trusted to pair siblings.
 *
 * ## Why not an arm of `member-order`
 *
 * `member-order` already regroups guarded MEMBERS into one `#if` block per condition and branch
 * shape, so a member-level merge looks like its job. It is not: the rule here is not about order
 * (a perfectly sorted file still carries the duplicate boundary), it compares conditions
 * SEMANTICALLY rather than by text (`#else` against `!cond`), and most of the sites are statements,
 * which `member-order` never sees. Like `redundant-condcomp-parens` this is a pure source scan
 * over `CondDirectives`, so it reaches every position a directive can take — module level, class
 * body, statement list, a branch of another region — and works on a file the grammar cannot parse.
 */
@:nullSafety(Strict)
final class CondRegionMerge implements Check {

	/** The rule id. */
	private static final ID: String = 'cond-region-merge';

	public function new() {}

	public function id(): String {
		return ID;
	}

	public function description(): String {
		return 'two adjacent conditional-compilation regions whose conditions are equal or complementary - mergeable into one';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) for (site in sites(entry.source, plugin))
				{
					file: entry.file,
					span: site.boundary,
					rule: ID,
					severity: Severity.Info,
					message: site.message
				}
		];
	}

	/** Splice each flagged boundary: the two directive lines are replaced by what the merged region needs there, at most an `#else`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (site in sites(source, plugin)) {
			final replacement: Null<String> = site.replacement;
			if (replacement != null && flagged.contains('${site.boundary.from}:${site.boundary.to}'))
				edits.push({ span: site.edit, text: replacement });
		}
		return edits;
	}

	/** Every mergeable boundary in `source`, in source order. */
	private static function sites(source: String, plugin: GrammarPlugin): Array<MergeSite> {
		final shape: RefShape = plugin.refShape();
		final directives: Array<CondDirective> = CondDirectives.scan(source, shape);
		if (directives.length < 4) return [];
		final regions: Null<Array<CondRegion>> = regionsOf(directives, shape);
		if (regions == null) return [];
		final openedAt: Map<Int, CondRegion> = [for (region in regions) region.open => region];
		final comments: Array<Span> = RefactorSupport.collectCommentRegions(source);
		final paired: Array<Int> = [];
		final out: Array<MergeSite> = [];
		for (first in regions) {
			final second: Null<CondRegion> = openedAt[first.close + 1];
			if (second == null || paired.contains(first.open) || paired.contains(second.open)) continue;
			final site: Null<MergeSite> = siteOf(source, directives, shape, first, second, comments);
			if (site == null) continue;
			paired.push(first.open);
			paired.push(second.open);
			out.push(site);
		}
		out.sort((a, b) -> a.boundary.from - b.boundary.from);
		return out;
	}

	/**
	 * The regions `directives` delimits, closed ones only, in closing order — or null when the scan
	 * is unbalanced, which refuses the file (see the type doc).
	 */
	private static function regionsOf(directives: Array<CondDirective>, shape: RefShape): Null<Array<CondRegion>> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		if (ifKeyword == null || endKeyword == null) return null;
		final out: Array<CondRegion> = [];
		final open: Array<CondRegion> = [];
		for (i in 0...directives.length) {
			final keyword: String = directives[i].keyword;
			if (keyword == ifKeyword) {
				open.push({ open: i, branches: [], close: -1 });
				continue;
			}
			if (open.length == 0) return null;
			if (keyword == endKeyword) {
				final region: Null<CondRegion> = open.pop();
				if (region == null) return null;
				region.close = i;
				out.push(region);
			} else {
				open[open.length - 1].branches.push(i);
			}
		}
		return open.length == 0 ? out : null;
	}

	/** The mergeable boundary between `first` and `second`, or null when any gate refuses the pair. */
	private static function siteOf(
		source: String, directives: Array<CondDirective>, shape: RefShape, first: CondRegion, second: CondRegion, comments: Array<Span>
	): Null<MergeSite> {
		final merge: Null<MergeShape> = mergeShapeOf(source, directives, first, second);
		if (merge == null) return null;
		final close: CondDirective = directives[first.close];
		final open: CondDirective = directives[second.open];
		final closeFrom: Int = close.span.from;
		final openTo: Int = open.span.to;
		final closeLineFrom: Int = RefactorSupport.startOfLine(source, closeFrom);
		final closeLineTo: Int = lineEnd(source, close.span.to);
		final openLineFrom: Int = RefactorSupport.startOfLine(source, open.span.from);
		final openLineTo: Int = lineEnd(source, openTo);
		if (source.substring(closeLineFrom, closeFrom).trim() != '') return null;
		if (source.substring(openLineFrom, open.span.from).trim() != '') return null;
		if (!isTriviaOnly(source, closeLineTo, openLineFrom, comments)) return null;
		final elseKeyword: String = branchKeyword(shape) ?? '';
		if (merge.complements && elseKeyword == '') return null;
		final tailsClean: Bool = source.substring(close.span.to, closeLineTo).trim() == ''
			&& source.substring(openTo, openLineTo).trim() == '' && !hasComment(comments, closeLineTo, openLineFrom);
		final gap: String = source.substring(closeLineTo, openLineFrom);
		final indent: String = source.substring(closeLineFrom, closeFrom);
		final replacement: String = merge.complements
			? '$indent$elseKeyword${lineTerminator(source, closeLineTo)}${withoutBlankLines(gap)}'
			: gap;
		final note: String = tailsClean ? '' : ' (comment in the merged span - merge by hand)';
		return {
			boundary: new Span(closeFrom, openTo),
			edit: new Span(closeLineFrom, openLineTo),
			replacement: tailsClean ? replacement : null,
			message: messageOf(merge, elseKeyword, note)
		};
	}

	/**
	 * The grammar's condition-LESS branch keyword (Haxe `#else`), or null when it declares none. A
	 * branch keyword carries a condition exactly when it ends with the opener's bare word, the same
	 * discrimination `CondDirectives` makes when it delimits one.
	 */
	private static function branchKeyword(shape: RefShape): Null<String> {
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		if (ifKeyword == null) return null;
		final bare: String = ifKeyword.substring(1);
		return (shape.conditionalElseKeywords ?? []).find(keyword -> keyword != '' && !keyword.endsWith(bare));
	}

	/** The condition of `directive`, whitespace-normalised for comparison, or null when it carries none. */
	private static function conditionText(source: String, directive: CondDirective): Null<String> {
		final condition: Null<Span> = directive.condition;
		if (condition == null) return null;
		final raw: String = source.substring(condition.from, condition.to).trim();
		return raw == '' ? null : CondDirectives.normalizeCondition(raw);
	}

	/** Whether one of `a` / `b` is the other's negation - `!X`, or `!(X)`, against `X`. */
	private static function isNegation(a: String, b: String): Bool {
		return negates(a, b) || negates(b, a);
	}

	/** Whether `negated` negates `plain`. */
	private static function negates(plain: String, negated: String): Bool {
		return negated.startsWith('!')
			&& CondDirectives.stripOuterParens(negated.substring(1).trim()) == CondDirectives.stripOuterParens(plain);
	}


	/** Whether `source[from,to)` holds nothing but whitespace and comment text. */
	private static function isTriviaOnly(source: String, from: Int, to: Int, comments: Array<Span>): Bool {
		var i: Int = from;
		while (i < to) {
			final c: Int = source.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				i++;
				continue;
			}
			final comment: Null<Span> = commentAt(comments, i);
			if (comment == null) return false;
			i = comment.to;
		}
		return true;
	}

	/** Whether any comment region overlaps `[from, to)` - a comment the splice would move INTO the merged region. */
	private static function hasComment(comments: Array<Span>, from: Int, to: Int): Bool {
		return comments.exists(comment -> comment.from < to && from < comment.to);
	}

	/** The comment region covering `at`, or null. */
	private static function commentAt(comments: Array<Span>, at: Int): Null<Span> {
		return comments.find(comment -> comment.from <= at && at < comment.to);
	}

	/** The index just past the line break ending the line `at` sits on, or the end of `source` when the line is unterminated. */
	private static function lineEnd(source: String, at: Int): Int {
		var i: Int = at;
		while (i < source.length && source.fastCodeAt(i) != '\n'.code) i++;
		return i < source.length ? i + 1 : i;
	}

	/** The line break ending the line that stops at `lineTo` - `\r\n` when the file uses it, `\n` otherwise. */
	private static function lineTerminator(source: String, lineTo: Int): String {
		final crlf: Bool = lineTo > 1 && lineTo <= source.length && source.fastCodeAt(lineTo - 1) == '\n'.code
			&& source.fastCodeAt(lineTo - 2) == '\r'.code;
		return crlf ? '\r\n' : '\n';
	}

	/** `text` with its blank lines dropped, every other line kept verbatim. */
	private static function withoutBlankLines(text: String): String {
		final out: StringBuf = new StringBuf();
		var from: Int = 0;
		while (from < text.length) {
			final to: Int = lineEnd(text, from);
			final line: String = text.substring(from, to);
			if (line.trim() != '') out.add(line);
			from = to;
		}
		return out.toString();
	}


	/**
	 * The merge `first` and `second` admit — which splice, and the conditions the finding names — or
	 * null when their branch shapes or conditions refuse the pair (the four accepted combinations are
	 * enumerated in the type doc).
	 */
	private static function mergeShapeOf(
		source: String, directives: Array<CondDirective>, first: CondRegion, second: CondRegion
	): Null<MergeShape> {
		if (first.branches.length > 1 || second.branches.length > 1) return null;
		final firstElse: Bool = first.branches.length == 1;
		final secondElse: Bool = second.branches.length == 1;
		if (firstElse && directives[first.branches[0]].condition != null) return null;
		if (secondElse && directives[second.branches[0]].condition != null) return null;
		final firstCondition: Null<String> = conditionText(source, directives[first.open]);
		final secondCondition: Null<String> = conditionText(source, directives[second.open]);
		if (firstCondition == null || secondCondition == null) return null;
		final firstText: String = firstCondition;
		final secondText: String = secondCondition;
		final complementary: Bool = isNegation(firstText, secondText);
		final joins: Bool = firstText == secondText ? !firstElse : complementary && firstElse && !secondElse;
		final complements: Bool = complementary && !firstElse && !secondElse;
		return joins || complements ? {
			complements: complements,
			firstElse: firstElse,
			firstCondition: firstText,
			secondCondition: secondText
		} : null;
	}

	/** The finding text for `merge`, naming the branch keyword the merged region keeps and carrying `note`. */
	private static function messageOf(merge: MergeShape, elseKeyword: String, note: String): String {
		return if (merge.complements)
			'conditional-compilation regions with complementary conditions (`${merge.firstCondition}` / `${merge.secondCondition}'
				+ '`) - mergeable into one `$elseKeyword`$note';
		else if (merge.firstElse)
			'the `${merge.secondCondition}` region repeats the `$elseKeyword` branch above it - mergeable into it$note';
		else
			'adjacent conditional-compilation regions share the condition `${merge.firstCondition}` - mergeable into one$note';
	}

}

/**
 * One conditional-compilation region as the directive scan sees it: the INDEX of its opening
 * directive, the indices of its branch directives (`#elseif` / `#else`) in order, and the index of
 * its `#end`. Indices rather than directives because a region is paired with its neighbour by
 * adjacency in that same array.
 */
private typedef CondRegion = {
	final open: Int;
	final branches: Array<Int>;
	var close: Int;
};

/**
 * One mergeable boundary: `boundary` is the reported span (the `#end` through the following `#if`),
 * `edit` the span the fix replaces (both directive LINES and everything between them), `replacement`
 * what goes there — null when the finding is report-only — and `message` the finding's text.
 */
private typedef MergeSite = {
	final boundary: Span;
	final edit: Span;
	final replacement: Null<String>;
	final message: String;
};

/**
 * The merge two adjacent regions admit: `complements` tells the two splices apart (a boundary
 * replaced by `#else` rather than deleted), `firstElse` whether the first region's last branch is
 * its `#else`, and the two conditions are carried for the finding's text.
 */
private typedef MergeShape = {
	final complements: Bool;
	final firstElse: Bool;
	final firstCondition: String;
	final secondCondition: String;
};
