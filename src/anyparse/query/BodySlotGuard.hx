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
 * and this returns the shape it would have swallowed. Everything else answers null.
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
	 * Costs one parse, and only when some edit BLANKS a region: a slot can go empty only
	 * if every edit covering it contributes blank text, so an edit set with no such edit
	 * cannot empty anything and returns before parsing. Unparseable input answers null —
	 * the caller's own parse is about to report it in its own words.
	 */
	public static function emptiedSlot(source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin): Null<String> {
		if (!edits.exists(edit -> edit.span.to > edit.span.from && blank(edit.text))) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final kinds: Array<String> = support.fixedSlotKinds();
		if (kinds.length == 0) return null;
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: Exception) return null;
		return scan(tree, source, edits, kinds);
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

}
