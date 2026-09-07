package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.query.CondRegionScan;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/** One comment token, or one merged `//` run, exactly as `SourceComments` models it. */
private typedef CommentUnit = {
	from: Int,
	to: Int,
	isLine: Bool
};

/**
 * One over-width comment line: the physical span to report, its rendered width, the unit that
 * owns it, which of that unit's BODY lines it is, and why the reflow may not re-lay-out it —
 * null while it still may.
 */
private typedef WideLine = {
	final owner: CommentUnit;
	final body: Int;
	final from: Int;
	final to: Int;
	final cols: Int;
	var refusal: Null<String>;
};

/**
 * Flags a COMMENT line — a `//` run, a `/* … *\/` banner or a `/** … *\/` doc block — that
 * renders wider than the project's own `wrapping.maxLineLength`. `Severity.Info`; `fix` breaks
 * the line back at spaces into the same block, carrying the prefix that position needs.
 *
 * The one width in this project nothing measured. The writer owns every CODE line's width and
 * re-emits a comment interior BYTE FOR BYTE, so an over-wide comment line leaves `fmt --list`
 * clean and no other rule reads a comment's shape: 468 lines of this tree stood past its
 * configured 140, one of them at 6641 columns, and the only gate any of them had ever met was a
 * human reading a diff.
 *
 * ## Off by default, and reported at `Info`
 *
 * `DefaultOff`, because the threshold is a project's own style choice and a project that has not
 * declared one should not inherit this rule's opinion; a project opts in through `apqlint.json`.
 * `Info` rather than `Warning` for the reason `prefer-line-comment` and
 * `fold-adjacent-string-literals` are: the finding names a layout preference, never a defect, and
 * a rule that can report several hundred lines of standing prose must not flip a warning-gated
 * build the day it is switched on.
 *
 * ## What the line has to be over-width FOR
 *
 * A line is measured whole — `CheckScan.displayColumn`, the project's one answer to what a tab is
 * worth, and the writer's — but it is only this rule's business when the COMMENT is what puts it
 * over. A comment sharing its line with code already past the width is not a comment-width finding,
 * and the code is read on BOTH SIDES of it (`lineWithoutComment`), because a short banner between a
 * call head and a long argument leaves nothing to its left and everything to its right: the
 * comment could vanish and the line would still be too long, and the code's width is the
 * formatter's concern. That single gate is the whole difference between 470 lines and the 468
 * this rule reports on its own tree — the two it drops are `// noqa` markers riding 160-column
 * string-literal fixtures.
 *
 * ## Report-only, and why — the reason travels in the message
 *
 * Wrapping is not always meaning-preserving, and the shapes where it is not are corruptions
 * nothing downstream can see. Those findings stand, with the reason spelled in the message
 * (and in `Violation.declineReason`, which `--fix`'s unfixed ledger reads):
 *
 *  - `SourceComments.reflowRefusal` owns the per-line half — a suppression directive whose
 *    broken `noqa:` widens to every rule, indentation the author wrote, a table row, a heading,
 *    a bullet, a numbered item. One predicate shared with the reflow, so the rule can never
 *    decline a line the reflow would have wrapped, or wrap one it declines.
 *  - a FENCED code block. `reflowRefusal` is per-line and cannot see a ``` fence, whose interior
 *    is flush prose to look at and a code sample to a reader. Tracked per unit here — 212 fence
 *    lines stand in 87 files of this tree.
 *  - a comment TRAILING after code. Its continuation would be a new own-line comment the writer
 *    then relocates; `wrapCommentBody` refuses the same shape.
 *  - a raw `#if` region (`CondRegionScan.opaqueCondRegions`). Nothing inside one projects, so
 *    the AST cannot corroborate an edit there — fail-closed, as every mutating op is. A file
 *    that does not parse is the same answer one step wider.
 *  - NO BREAK POINT inside the width — an 86-character URL or a path written as one word. Asked
 *    of the reflow itself rather than of a second predicate: the line comes back byte-identical,
 *    which is the only honest evidence that nothing can be done with it.
 */
@:nullSafety(Strict)
final class CommentWidth implements Check implements DefaultOff implements VolatileMessage {

	/** This check's `id()`, and the `rule` every finding carries. */
	private static inline final RULE_ID: String = 'comment-width';

	/**
	 * The message's lead-in, and the anchor `messageIdentity` masks the MEASURED width behind.
	 *
	 * The configured maximum sits after no anchor and survives the mask, which is the split
	 * `Check.VolatileMessage` asks for: a threshold change IS a change, while a line drifting
	 * from 168 columns to 167 is the same standing finding and must not read as movement.
	 */
	private static inline final WIDTH_LEAD: String = 'comment line is ';

	/** The markdown fence marker whose interior is a code sample, whatever its first character looks like. */
	private static inline final FENCE: String = '```';

	/** Report-only: nothing inside a raw `#if` region projects, so no edit there can be corroborated. */
	private static inline final OPAQUE: String = 'it sits in a conditional-compilation region the parser captured raw';

	/** Report-only: with no tree, a raw `#if` region cannot be ruled out — the same fail-closed answer, one step wider. */
	private static inline final UNPARSED: String = 'the file does not parse, so a raw conditional-compilation region cannot be ruled out';

	/** Report-only: a wrapped trailing comment's continuation is a new own-line comment the writer relocates. */
	private static inline final TRAILING: String = 'it trails after code, so its continuation would be a new own-line comment';

	/** Report-only: the interior of a fenced block is a code sample, and breaking it at spaces rewrites the sample. */
	private static inline final FENCED: String = 'it is inside a fenced code block';

	/** Report-only: the reflow handed the line back byte-identical — one word wider than the width. */
	private static inline final NO_BREAK: String = 'it holds no break point inside the width';

	/**
	 * Report-only: the block's `*\/` shares this line, and `wrapCommentBody` measures the BODY, which
	 * ends two characters short of it — so the reflow reads a 142-column line as 140 and leaves it.
	 * Every one of the 20 lines this names in this tree is a one-line doc block at 141 or 142 columns,
	 * over by exactly the closer.
	 */
	private static inline final CLOSER: String = 'the block closer shares this line and the reflow measures the body without it';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a comment line wider than the configured maximum line length';
	}

	/** Mask the measured width; the configured maximum after it is a threshold and stays. */
	public function messageIdentity(message: String): String {
		return MessageMask.maskAfter(message, WIDTH_LEAD);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(FormatConfigDiscovery.discover(entry.file));
			if (metrics == null) continue;
			for (wide in classify(entry.source, plugin, metrics)) violations.push({
				file: entry.file,
				span: new Span(wide.from, wide.to),
				rule: RULE_ID,
				severity: Severity.Info,
				message: messageFor(wide, metrics.lineWidth)
			});
		}
		return violations;
	}

	/**
	 * Break each flagged line back into the width, inside the block it already lives in.
	 *
	 * The candidate set is re-derived from `source`, so a stale or foreign finding names no line
	 * and yields no edit. Only the lines THESE violations name are handed to the reflow — every
	 * other line of the same block goes in as one the reflow must leave byte-identical, which is
	 * `wrapCommentBody`'s own contract and what keeps a whole-body edit justified by the findings
	 * that asked for it rather than by the block it lands in.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final file: String = violations[0].file;
		final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(FormatConfigDiscovery.discover(file));
		if (metrics == null) return [];
		final layout: LayoutMetrics = metrics;
		final wanted: Array<Int> = [for (v in violations) if (v.span != null) (v.span: Span).from];
		final wide: Array<WideLine> = classify(source, plugin, layout);
		for (v in violations) {
			final span: Null<Span> = v.span;
			final line: Null<WideLine> = span == null ? null : wide.find(w -> w.from == span.from);
			final refusal: Null<String> = line?.refusal;
			if (refusal != null) v.declineReason = refusal;
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (unit in ownersOf(wide)) {
			final open: Array<Int> = [
				for (w in wide) if (w.owner.from == unit.from && w.refusal == null && wanted.contains(w.from)) w.body
			];
			if (open.length == 0) continue;
			final bodySpan: Span = SourceComments.commentBody(source, unit);
			final body: String = source.substring(bodySpan.from, bodySpan.to);
			final continuation: String = SourceComments.commentContinuation(source, unit);
			final next: String = reflow(source, unit, body, open, layout);
			if (next == body) continue;
			// A ONE-LINE doc block that has just grown has to be re-opened, or its closer rides the
			// last content line and the writer eats the space before that line's star. The block's
			// own guards do the rest: a plain `/* … *\/` body does not start on a star, and a
			// continuation with no gutter is handed back untouched.
			final grown: Bool = body.indexOf('\n') < 0 && next.indexOf('\n') >= 0;
			edits.push({ span: bodySpan, text: grown ? SourceComments.openGrownDocBlock(next, continuation) : next });
		}
		return edits;
	}

	/** `wide`'s owning units, first occurrence first — one entry per comment unit that carries a finding. */
	private static function ownersOf(wide: Array<WideLine>): Array<CommentUnit> {
		final out: Array<CommentUnit> = [];
		for (w in wide) if (!out.exists(u -> u.from == w.owner.from)) out.push(w.owner);
		return out;
	}

	/** The finding text: the measured width, the configured maximum, and the refusal when there is one. */
	private static function messageFor(wide: WideLine, width: Int): String {
		final head: String = '$WIDTH_LEAD${wide.cols} columns wide, past the configured maximum of $width';
		final refusal: Null<String> = wide.refusal;
		return refusal == null ? head : '$head — not reflowed: $refusal';
	}

	/**
	 * Every over-width comment line of `source`, each carrying the reason it may not be reflowed
	 * or null. Two comments on ONE physical line yield it once.
	 *
	 * Three passes, cheapest first, because 1548 of this tree's 1778 files carry no candidate at
	 * all: the per-line shape gates need only the lexical scan, the reflow probe runs once per
	 * unit that still has an open candidate, and the PARSE — which the raw-`#if` question needs —
	 * is paid only by a file that reached the end with a finding.
	 */
	private static function classify(source: String, plugin: GrammarPlugin, metrics: LayoutMetrics): Array<WideLine> {
		final units: Array<CommentUnit> = SourceComments.collectCommentUnits(source, plugin.lexicalRegions(source));
		final wide: Array<WideLine> = [];
		final seen: Array<Int> = [];
		for (unit in units) collectUnit(source, unit, metrics, wide, seen);
		if (wide.length == 0) return wide;
		for (unit in ownersOf(wide)) probeReflow(source, unit, wide, metrics);
		final opaque: Null<Array<Span>> = opaqueRegionsOf(source, plugin);
		// A line that already named its own shape keeps that reason: both answers are report-only, and
		// the narrower one is the one a reader can act on.
		for (w in wide) if (w.refusal == null) {
			if (opaque == null)
				w.refusal = UNPARSED;
			else if (opaque.exists(r -> r.from < w.owner.to && w.owner.from < r.to))
				w.refusal = OPAQUE;
		}
		return wide;
	}

	/** Walk one unit's body lines, appending every over-width one with the shape gates already applied. */
	private static function collectUnit(
		source: String, unit: CommentUnit, metrics: LayoutMetrics, out: Array<WideLine>, seen: Array<Int>
	): Void {
		final tab: Int = metrics.indentWidth;
		final bodySpan: Span = SourceComments.commentBody(source, unit);
		final head: String = SourceComments.commentHead(source, unit);
		// `commentHead` runs from the line start THROUGH the opener, so anything past those two
		// characters is code standing to the comment's left.
		final headHasCode: Bool = head.trim().length > 2;
		final lines: Array<String> = source.substring(bodySpan.from, bodySpan.to).split('\n');
		var at: Int = bodySpan.from;
		var fenced: Bool = false;
		for (i => raw in lines) {
			final lineFrom: Int = i == 0 ? SourceText.lineStartOf(source, unit.from) : at;
			at += raw.length + 1;
			final line: String = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
			final text: String = line.substring(SourceComments.commentLineBodyAt(line, i == 0, head, unit.isLine));
			final marker: Bool = text.startsWith(FENCE);
			final inFence: Bool = fenced || marker;
			if (marker) fenced = !fenced;
			final lineTo: Int = lineEnd(source, lineFrom);
			final cols: Int = CheckScan.displayColumn(source, lineFrom, lineTo, tab);
			if (cols <= metrics.lineWidth || seen.contains(lineFrom)) continue;
			// The COMMENT has to be what puts the line over. Code already past the width would be
			// too long with the comment deleted, and its width is the formatter's business. Read on
			// BOTH sides of the unit: a short banner between a call head and a long argument
			// (`g(\n\t/* n */ "…")`) puts nothing on the line that measuring only its left would see.
			final code: String = lineWithoutComment(source, lineFrom, lineTo, unit);
			if (CheckScan.displayColumn(code, 0, code.length, tab) > metrics.lineWidth) continue;
			seen.push(lineFrom);
			var ink: Int = lineFrom;
			while (ink < lineTo && SourceText.isSpace(source.fastCodeAt(ink))) ink++;
			out.push({
				owner: unit,
				body: i,
				from: ink,
				to: lineTo,
				cols: cols,
				refusal: i == 0 && headHasCode ? TRAILING : inFence ? FENCED : SourceComments.reflowRefusal(text)
			});
		}
	}

	/**
	 * Ask the reflow which of `unit`'s still-open lines it can actually break, and refuse the rest
	 * by name.
	 *
	 * The question is put to `wrapCommentBody` rather than to a second break-point predicate, for
	 * the reason the shape gates are shared: a copy of `fillText`'s cut search would answer this
	 * rule's report while the fix went on using the original, and the two would drift silently.
	 * A line the reflow hands back byte-identical is one it could not break.
	 */
	private static function probeReflow(source: String, unit: CommentUnit, wide: Array<WideLine>, metrics: LayoutMetrics): Void {
		final open: Array<WideLine> = [for (w in wide) if (w.owner.from == unit.from && w.refusal == null) w];
		if (open.length == 0) return;
		final bodySpan: Span = SourceComments.commentBody(source, unit);
		final body: String = source.substring(bodySpan.from, bodySpan.to);
		// A body span two characters short of its unit is a CLOSED block, so its last body line is
		// the one the closer rides — the two columns the reflow measures nothing of.
		final closer: Int = bodySpan.to == unit.to - 2 ? 2 : 0;
		final last: Int = body.split('\n').length - 1;
		// ONE line at a time, so the answer is about THAT line. Wrapping the whole open set at once and
		// looking for each line's text in the result reads a surviving IDENTICAL twin — a prose line
		// whose copy sits inside a fenced block, say — as evidence that this line could not be broken.
		for (w in open) if (reflow(source, unit, body, [w.body], metrics) == body)
			w.refusal = w.body == last && w.cols - closer <= metrics.lineWidth ? CLOSER : NO_BREAK;
	}

	/**
	 * `body` with the lines at `open` broken back into the width and every other line byte-identical.
	 *
	 * `wrapCommentBody` takes the body BEFORE an edit and leaves every line it finds there
	 * unchanged; handing it this unit's own lines MINUS the open ones is that contract read as a
	 * protection list, which is what keeps a whole-body edit answerable to the findings that asked
	 * for it. A line blanked out of the protection list is never over-width in it either, so the
	 * reflow's own trigger fires exactly when an open line stands.
	 */
	private static function reflow(source: String, unit: CommentUnit, body: String, open: Array<Int>, metrics: LayoutMetrics): String {
		return SourceComments.wrapCommentBody(
			body, body, SourceComments.commentHead(source, unit), SourceComments.commentContinuation(source, unit), metrics, unit.isLine,
			open
		);
	}

	/** Where the physical line starting at `from` ends, a trailing carriage return excluded — it is not ink. */
	private static function lineEnd(source: String, from: Int): Int {
		final nl: Int = source.indexOf('\n', from);
		final to: Int = nl < 0 ? source.length : nl;
		return to > from && source.fastCodeAt(to - 1) == '\r'.code ? to - 1 : to;
	}

	/**
	 * The physical line `[from, to)` with `unit`'s own bytes cut out and the remainder right-trimmed —
	 * the CODE this comment shares its line with, on both sides of it.
	 *
	 * Both sides, because a comment can sit between two pieces of code: a short banner between a call
	 * head and a long argument leaves nothing to its left and everything to its right, and a gate that
	 * read only the left would call the whole line the comment's doing.
	 */
	private static function lineWithoutComment(source: String, from: Int, to: Int, unit: CommentUnit): String {
		return (source.substring(from, clamp(unit.from, from, to)) + source.substring(clamp(unit.to, from, to), to)).rtrim();
	}

	/** `at` pulled inside `[from, to]` — a comment unit's ends reach past the line it is being read on. */
	private static function clamp(at: Int, from: Int, to: Int): Int {
		return if (at < from)
			from
		else if (at > to)
			to
		else
			at;
	}

	/** Every raw `#if` region of `source`, or null when it does not parse — the fail-closed answer. */
	private static function opaqueRegionsOf(source: String, plugin: GrammarPlugin): Null<Array<Span>> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		return tree == null ? null : [
			for (region in CondRegionScan.opaqueCondRegions(tree, source, plugin.refShape())) region.region
		];
	}

}
