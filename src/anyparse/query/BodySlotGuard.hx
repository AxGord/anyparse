package anyparse.query;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.LexicalRegions.LexRegionKind;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The structural half of the writer-emit gate: whether an edit set would leave a
 * brace-less construct's body slot EMPTY.
 *
 * ## Why a re-parse gate cannot see this
 *
 * `RefactorSupport.canonicalize` asks one question — does the spliced result still
 * parse, and does the writer settle on it. For this class of edit the answer is YES
 * while the meaning has changed, because the slot does not stay empty: the parser
 * fills it with whatever statement follows.
 *
 * ```haxe
 * if (flag) log.push("in-branch");
 * log.push("after");
 * ```
 *
 * `apq remove-element` on `log.push("in-branch")` wrote `if (flag) log.push("after");`
 * — rc 0, `wrote <file>`, no diagnostic. Both versions compile; the first prints
 * `after` unconditionally, the second only when `flag`. `lint --fix` reached the same
 * result from `unused-local` on `if (c) var y: Int = 1;`, one edit inside a 4-file run
 * that otherwise did exactly what it said.
 *
 * ## What it answers
 *
 * A construct in `ControlFlowSupport.fixedSlotKinds()` holds each of its children in a
 * slot that must be filled. If the edits blank one of those children whole — delete it,
 * or replace it with whitespace — the construct is left reaching for the next statement,
 * and this returns the shape it would have swallowed.
 *
 * A second question the first one cannot answer: `surviving` splices a super-span edit's whole
 * text into every clipped sub-region, so host and slot BOTH read non-blank; and where the
 * REPLACEMENT builds the construct — `a();` ==== `if (c)` in a plain block, or a bare `if (c)`
 * inserted before a statement — no construct in the SOURCE lost anything for the first question
 * to notice. `apq patch` with
 * `if (flag) log.push("x");` ==== `if (flag)` wrote `if (flag)` followed by the next
 * statement — rc 0, `wrote <file>`, and the probe went from printing `in-branch,after` /
 * `after` to printing `after` / nothing. Both are answered on the RESULT: splice, re-parse, and refuse a construct that now covers
 * surviving source the region it came from did not. Everything else answers null.
 *
 * A construct the edits are REMOVING or RESHAPING is not emptied, it is gone, so a host
 * whose own text does not survive is skipped, and so is a slot whose introducing tokens
 * went with it — `if-false-dead-code` deleting a whole `if (false) g();` and a fix that
 * drops an `else g();` branch whole are that shape, not this one.
 *
 * Pure and grammar-agnostic: the kind vocabulary comes from the plugin, and a grammar
 * that declares none makes the guard inert.
 */
@:nullSafety(Strict)
final class BodySlotGuard {

	/**
	 * The refusal message for the first fixed slot `edits` would empty, or null when they
	 * empty none — the answer BOTH the writer-emit gate and `lint --fix`'s per-check
	 * filter read, so the two cannot drift apart on what the rule is.
	 *
	 * Two questions, because one of them cannot be asked of the edits alone. The first is
	 * SOURCE-side and exact whenever every edit covering a slot is CONTAINED in it: does the slot
	 * go blank. The second is RESULT-side: splice, re-parse, and ask whether a construct now
	 * covers surviving text its source counterpart did not — which is the only way to see a
	 * construct the REPLACEMENT built, since nothing in the source lost anything then.
	 *
	 * Neither subsumes the other, measured by disabling each against this guard's own tests:
	 * without the first, five refusals go green that should not; without the second, seven do.
	 *
	 * Costs two parses per call. The pre-filter is only "there is an edit": a pure INSERTION
	 * builds the same swallow (`add-element` with the bare element `if (c)`) and deletes nothing,
	 * so the narrower filter that asked for a deleting edit returned before parsing. Unparseable
	 * input — either side of the edit — answers null: the caller's own parse is about to report
	 * it in its own words.
	 */
	public static function emptiedSlot(source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin): Null<String> {
		if (edits.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final kinds: Array<String> = support.fixedSlotKinds();
		if (kinds.length == 0) return null;
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: Exception) return null;
		return scan(tree, source, edits, kinds) ?? reaching(tree, source, edits, kinds, plugin);
	}

	/** The first emptied slot at or below `node`, in document order. */
	private static function scan(
		node: QueryNode, source: String, edits: Array<{ span: Span, text: String }>, kinds: Array<String>
	): Null<String> {
		final hit: Null<String> = kinds.contains(node.kind) ? emptiedChild(node, source, edits) : null;
		if (hit != null) return hit;
		for (child in node.children) {
			final deeper: Null<String> = scan(child, source, edits, kinds);
			if (deeper != null) return deeper;
		}
		return null;
	}

	/**
	 * The message for the first child of this fixed-slot `host` the edits blank whole, or
	 * null. A host that is itself being removed or rewritten across its own boundary is not
	 * being emptied and answers null.
	 */
	private static function emptiedChild(host: QueryNode, source: String, edits: Array<{ span: Span, text: String }>): Null<String> {
		final hostSpan: Null<Span> = host.span;
		if (hostSpan == null) return null;
		// REDUNDANT with the lead test below, and deliberately kept: measured, disabling
		// either one alone leaves the suite green because the other catches whole-host
		// removal, and only disabling BOTH turns `if (c) a();` into a refusal. This one
		// states the invariant directly; the lead test is a heuristic about tokens.
		if (blank(surviving(source, hostSpan, edits))) return null;
		var previous: Int = hostSpan.from;
		for (child in host.children) {
			final slot: Null<Span> = child.span;
			if (slot == null || slot.to <= slot.from) continue;
			// The tokens between the previous slot and this one are what DEMANDS it — `if (`,
			// `)`, `else`, `while (`. An edit that took them away took the slot with them, so
			// the construct is being reshaped rather than left reaching: removing `else g();`
			// whole leaves a valid `if` with no else branch, and must not be refused.
			final lead: String = surviving(source, new Span(previous, slot.from), edits);
			previous = slot.to;
			if (blank(lead)) continue;
			if (blank(source.substring(slot.from, slot.to))) continue;
			if (!blank(surviving(source, slot, edits))) continue;
			final at: Position = hostSpan.lineCol(source);
			return 'this would leave the ${host.kind} at ${at.line}:${at.col} with an empty ${child.kind} slot, and the construct would'
				+ ' take in whatever follows it — brace the body first (`{ … }`) or remove the whole ${host.kind}';
		}
		return null;
	}

	/**
	 * The text of `[span.from, span.to)` as it would read once `edits` are applied — the
	 * source with every intersecting edit spliced in, each clipped to the span.
	 *
	 * EXACT only for an edit CONTAINED in the span. An edit that reaches across the boundary is
	 * clipped by SPAN and spliced by TEXT, so its whole replacement lands in every sub-region it
	 * touches and host and slot both read non-blank — the reason the blankness question above
	 * cannot see a super-span edit at all, and `reaching` asks the result instead.
	 */
	private static function surviving(source: String, span: Span, edits: Array<{ span: Span, text: String }>): String {
		final inner: Array<{ span: Span, text: String }> = [
			for (edit in edits) if (edit.span.to > span.from && edit.span.from < span.to) edit
		];
		inner.sort((a, b) -> b.span.from - a.span.from);
		var region: String = source.substring(span.from, span.to);
		for (edit in inner) {
			final cut: Span = edit.span;
			final from: Int = (cut.from < span.from ? span.from : cut.from) - span.from;
			final to: Int = (cut.to > span.to ? span.to : cut.to) - span.from;
			region = region.substring(0, from) + edit.text + region.substring(to);
		}
		return region;
	}

	/**
	 * Whether `text` carries no CODE. Whitespace is not code, and neither is a COMMENT:
	 * `patch` replacing the body of `if (c) a();` with `// gone` wrote `if (c) // gone` and
	 * pulled the next statement into the branch — rc 0, and the probe stopped printing —
	 * which is the same corruption the guard already refused when the replacement was
	 * whitespace. A string or regex literal IS code: a bare literal is a statement, so a
	 * slot holding one is filled.
	 *
	 * The `indexOf` is what keeps this off the hot path — a replacement with no `/` in it
	 * cannot hold a comment, and that is nearly every edit the ops emit.
	 */
	private static function blank(text: String): Bool {
		return text.trim() == '' || (text.indexOf('/') >= 0 && codeOnly(text).trim() == '');
	}

	/** `text` with every comment region cut out; string and regex literals stand. */
	private static function codeOnly(text: String): String {
		final out: StringBuf = new StringBuf();
		var at: Int = 0;
		for (region in LexicalRegions.scan(text)) switch region.kind {
			case LineComment, BlockComment:
				out.add(text.substring(at, region.from));
				at = region.to;
			case StringLit, RegexLit:
		}
		out.add(text.substring(at));
		return out.toString();
	}

	/**
	 * The first fixed-slot construct the edits would leave REACHING PAST its own end, into source
	 * text that used to follow it, or null.
	 *
	 * The source-side test above asks whether a slot goes blank, and it answers from `surviving` —
	 * which splices a super-span edit's WHOLE text into every clipped sub-region, so for an edit
	 * that covers the host, host and slot both read non-blank and nothing fires. Measured:
	 * `apq patch` with `if (flag) log.push('x');` ==== `if (flag)` wrote `if (flag)` followed by the
	 * next statement, rc 0 and `wrote <file>`, and the probe went from printing `in-branch,after` /
	 * `after` to printing `after` / nothing.
	 *
	 * And it cannot see the wider half of the same class at all: a construct the REPLACEMENT builds
	 * (`a();` ==== `if (c)` in a plain block) or one an INSERTION drops in front of a statement. No
	 * slot went blank there — no construct in the source was involved — yet the next statement is
	 * inside a branch just the same.
	 *
	 * So this one asks the RESULT: splice, re-parse, and compare each construct's end against the
	 * end of the region it came from. It runs on every edit set, deliberately. A narrower trigger
	 * — only when an edit takes a source construct's own terminator away — was written first and
	 * measured: it costs nothing and misses exactly the two shapes above, which is what its own
	 * mutation now pins.
	 */
	private static function reaching(
		tree: QueryNode, source: String, edits: Array<{ span: Span, text: String }>, kinds: Array<String>, plugin: GrammarPlugin
	): Null<String> {
		final srcComments: Map<Int, Int> = commentStarts(source);
		final ends: Map<Int, Int> = [];
		collectEnds(tree, source, srcComments, kinds, ends);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		final spliced: String = RefactorSupport.applyEdits(source, edits);
		final result: QueryNode = try plugin.parseFile(spliced) catch (exception: Exception) return null;
		return reached(result, {
			tree: tree,
			source: source,
			srcComments: srcComments,
			spliced: spliced,
			outComments: commentStarts(spliced),
			sorted: sorted,
			ends: ends,
			kinds: kinds
		});
	}

	/** Every fixed-slot construct's end in `source`, by its start — the furthest when two share one. */
	private static function collectEnds(
		node: QueryNode, source: String, comments: Map<Int, Int>, kinds: Array<String>, out: Map<Int, Int>
	): Void {
		final span: Null<Span> = node.span;
		if (span != null && kinds.contains(node.kind)) {
			final end: Int = trimmedEnd(source, comments, span.from, span.to);
			final seen: Null<Int> = out[span.from];
			if (seen == null || end > seen) out[span.from] = end;
		}
		for (child in node.children) collectEnds(child, source, comments, kinds, out);
	}

	/**
	 * The message for the first construct in the RESULT that reaches past what the region it came
	 * from covered, or null.
	 *
	 * Two readings decide it, and each was wrong in a first draft. A node span carries trailing
	 * trivia and the two sides carry DIFFERENT amounts of it, so both ends are taken at the last
	 * CODE position — whitespace AND comments. And a construct whose end sits inside a replacement
	 * is only AUTHORED when that replacement reaches back into what the construct already owned:
	 * otherwise the end is simply inside somebody else's edit.
	 */
	private static function reached(node: QueryNode, at: Reach): Null<String> {
		final span: Null<Span> = node.span;
		if (span != null && at.kinds.contains(node.kind)) {
			final start: Origin = origin(at.sorted, span.from, false);
			final limit: Int = limitOf(at, start);
			if (limit >= 0) {
				final end: Int = trimmedEnd(at.spliced, at.outComments, span.from, span.to);
				final finish: Origin = origin(at.sorted, end, true);
				// Measured, on the two readings this line got wrong first time round: removing a sole
				// `catch` left a `TryCatchStmt` whose span ran to the next statement's first character
				// while its source counterpart stopped at its own `;` — hence `trimmedEnd` on BOTH
				// sides. And two independent `patch` pairs, one on a brace-less body and one on the
				// statement after it, wrote `if (flag) log.push('one') + log.push('2');` with the
				// second statement inside the branch — a replacement authors an end only when it
				// reaches back into what the construct already owned, not merely by containing it.
				final authored: Bool = finish.editEnd >= 0 && finish.editFrom <= limit;
				if (!authored && finish.pos > limit) {
					final where: Position = new Span(start.pos, start.pos).lineCol(at.source);
					return 'this would leave the ${node.kind} at ${where.line}:${where.col} reaching past its own body into what'
						+ ' follows it — the edit drops the body without removing the construct, so the next statement becomes the'
						+ ' body; brace the body first (`{ … }`) or remove the whole ${node.kind}';
				}
			}
		}
		for (child in node.children) {
			final deeper: Null<String> = reached(child, at);
			if (deeper != null) return deeper;
		}
		return null;
	}

	/**
	 * How far in the SOURCE a construct starting at `start` may reach, or -1 when nothing in the
	 * source answers for it.
	 *
	 * A start in surviving text has a counterpart of its own — the source construct at the same
	 * position — so that construct's end IS the limit. A start inside a replacement has no
	 * counterpart, and reaches only as far as that replacement OWNS.
	 */
	private static function limitOf(at: Reach, start: Origin): Int {
		return start.editEnd < 0 ? at.ends[start.pos] ?? -1 : ownedEnd(at, start.editFrom, start.editEnd);
	}

	/**
	 * Where result position `at` came from in the source. `pos` is that source position; `editEnd`
	 * is the source end of the edit whose REPLACEMENT text `at` fell inside, or -1 when it fell in
	 * surviving source text.
	 *
	 * `end` reads `at` as an EXCLUSIVE end, so a position on a run boundary belongs to the run that
	 * ends there rather than the one that starts there — which is what makes a construct ending
	 * exactly where a replacement ends read as authored rather than as reaching.
	 */
	private static function origin(sorted: Array<{ span: Span, text: String }>, at: Int, end: Bool): Origin {
		var src: Int = 0;
		var res: Int = 0;
		for (edit in sorted) {
			final from: Int = edit.span.from;
			final to: Int = edit.span.to;
			final length: Int = edit.text.length;
			final kept: Int = from - src;
			if (end ? at <= res + kept : at < res + kept) return { pos: src + (at - res), editFrom: -1, editEnd: -1 };
			res += kept;
			if (end ? at <= res + length : at < res + length) return { pos: end ? to : from, editFrom: from, editEnd: to };
			res += length;
			src = to;
		}
		return { pos: src + (at - res), editFrom: -1, editEnd: -1 };
	}

	/**
	 * `to` backed up past trailing trivia — the last CODE position of `[from, to)` in `text`.
	 *
	 * Whitespace AND comments: `comments` maps each comment region's end to its start, so the walk
	 * steps over a `// note` and keeps going. Trimming only whitespace turned an ordinary
	 * `remove-element` on a sole `catch` into a refusal as soon as a comment sat after it, and the
	 * comment was the entire discriminator against the same file without one.
	 */
	private static function trimmedEnd(text: String, comments: Map<Int, Int>, from: Int, to: Int): Int {
		var at: Int = to;
		while (true) {
			while (at > from && text.isSpace(at - 1)) at--;
			final opens: Null<Int> = comments[at];
			if (opens == null || opens < from) return at;
			at = opens;
		}
	}

	/**
	 * How far a construct born inside a replacement may reach: the end of the innermost fixed-slot
	 * construct — or fixed SLOT — that the replaced region sat in.
	 *
	 * A replacement owns the syntactic region it replaced and nothing past it, and saying which
	 * region that is takes the slot vocabulary. Replacing `a()` inside `if (c) a();` leaves the
	 * `;` standing to be consumed, so the region is the SLOT and a construct born there may end at
	 * that `;`; replacing `a();` — the slot itself — leaves nothing, so a construct that ends
	 * later has taken in the statement after it. The two differ by one character of edit span and
	 * by nothing else, which is why neither the edit's own end nor the innermost containing node
	 * can tell them apart: the first reads a header rewrite (`while (c)` for `if (c)`, whose body
	 * stays exactly where it was) as a swallow, the second reads the swallow as legal.
	 *
	 * Falls back to the innermost containing node where no fixed-slot construct is involved at
	 * all — a replaced statement in a plain block owns exactly itself, which is what catches a
	 * construct built out of a statement that had none around it.
	 */
	private static function ownedEnd(at: Reach, from: Int, to: Int): Int {
		// A pure INSERTION replaced nothing, so it owns nothing: a construct born there may end
		// inside the inserted text and nowhere else.
		if (to <= from) return from;
		var node: QueryNode = at.tree;
		var host: Bool = at.kinds.contains(node.kind);
		var inner: Null<Span> = node.span;
		var owned: Null<Span> = null;
		while (true) {
			var next: Null<QueryNode> = null;
			for (child in node.children) {
				final span: Null<Span> = child.span;
				if (span != null && span.from <= from && span.to >= to) {
					next = child;
					break;
				}
			}
			if (next == null) break;
			if (host || at.kinds.contains(next.kind)) owned = next.span;
			inner = next.span;
			host = at.kinds.contains(next.kind);
			node = next;
		}
		final chosen: Null<Span> = owned ?? inner;
		return chosen == null ? at.source.length : trimmedEnd(at.source, at.srcComments, chosen.from, chosen.to);
	}

	/**
	 * Every COMMENT region of `text` as end -> start, so a span's trailing trivia can be stepped
	 * over backwards. String and regex literals are code here and are deliberately absent.
	 */
	private static function commentStarts(text: String): Map<Int, Int> {
		final out: Map<Int, Int> = [];
		for (region in LexicalRegions.scan(text)) switch region.kind {
			case LineComment, BlockComment:
				out[region.to] = region.from;
			case StringLit, RegexLit:
		}
		return out;
	}

}

/**
 * Where a RESULT position came from in the source: `pos` is that source position, and
 * `editFrom` / `editEnd` are the source span of the edit whose REPLACEMENT text it fell inside —
 * both -1 when it fell in surviving source text.
 */
private typedef Origin = {
	var pos: Int;
	var editFrom: Int;
	var editEnd: Int;
};
/**
 * Everything the result-side walk reads, in one value: the SOURCE tree and text with its comment
 * regions, the SPLICED text with its own, the edits sorted ascending, every source fixed-slot
 * construct's end by its start, and the fixed-slot kind vocabulary.
 *
 * The two comment maps are the reason this is a struct rather than a parameter list: a node span
 * carries trailing trivia, the two sides carry DIFFERENT amounts of it, and telling code from
 * trivia takes the lexical scan of the text the span belongs to.
 */
private typedef Reach = {
	var tree: QueryNode;
	var source: String;
	var srcComments: Map<Int, Int>;
	var spliced: String;
	var outComments: Map<Int, Int>;
	var sorted: Array<{ span: Span, text: String }>;
	var ends: Map<Int, Int>;
	var kinds: Array<String>;
};
