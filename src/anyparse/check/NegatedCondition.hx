package anyparse.check;

import anyparse.query.BoolExprShape;
import anyparse.query.GrammarPlugin;
import anyparse.query.ParenGuard;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * The one place a condition whose TOP-LEVEL node is a logical NOT is read in its positive form —
 * for the branch swap `invert-negated-if-else` performs on an `if` statement, a value-position `if`
 * and a ternary, and for every rule that BUILDS a ternary out of a guard (`prefer-ternary-return`,
 * `return-reassign-ternary`, `prefer-ternary-assignment`, `prefer-ternary-expression`), which emit
 * `c ? b : a` for `if (!c) …a… else …b…` instead of writing the `!c ? a : b` the inversion would
 * then have to undo.
 *
 * Dropping the `!` and swapping the two branches is an EXACT complement, semantics-safe under every
 * value including `NaN` (a De Morgan rewrite is not), on three conditions this class owns:
 *
 *  - the condition's top-level node, outer parentheses unwrapped, IS a not — never a `!=`, never a
 *    `&&` / `||` whose operand happens to be negated (`!a && b` keeps its shape);
 *  - that `!` is the BUILT-IN one: an abstract declaring `@:op(!A)` beside a `to Bool` may make `!f`
 *    and `f` agree, and then the swap runs the other branch (`OperatorSelection`);
 *  - the rebuild drops no comment: the positive form is the not's operand source with a single
 *    redundant paren around it unwrapped, so a comment between `!` and that operand, or inside the
 *    dropped paren, would be lost. A comment INSIDE the kept operand travels verbatim.
 *
 * The operand loses its paren unconditionally; where the result lands in an operator context (a
 * ternary condition) the caller's `ParenGuard` puts back exactly the pair the parser needs.
 */
@:nullSafety(Strict)
final class NegatedCondition {

	/**
	 * The per-run seams, or null when the grammar declares no not kind (every caller then emits the
	 * condition as written). `report` is a fix's report index (see `OperatorSelection.of`).
	 */
	public static function readSeams(
		plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, ?report: SymbolIndex
	): Null<InversionSeams> {
		final shape: RefShape = plugin.refShape();
		final notKind: Null<String> = shape.notKind;
		return notKind == null ? null : {
			notKind: notKind,
			parenKind: shape.parenKind,
			selection: OperatorSelection.of(plugin, files, report)
		};
	}

	/** The negation site of `file`'s `tree`, or null when the run has no `seams` (the grammar declares no not kind). */
	public static function siteOf(seams: Null<InversionSeams>, file: String, source: String, root: Null<QueryNode>): Null<InversionSite> {
		return seams == null ? null : {
			seams: seams,
			file: file,
			source: source,
			root: root
		};
	}

	/**
	 * The node whose source is `cond`'s positive form — the not's operand, a single paren around it
	 * unwrapped — or null when `cond` is not a built-in top-level not. Comments are NOT consulted:
	 * a rule that reports a site it cannot rewrite asks `dropsComment` separately.
	 */
	public static function negatedOperand(cond: QueryNode, site: InversionSite): Null<QueryNode> {
		final s: InversionSeams = site.seams;
		final not: QueryNode = BoolExprShape.unwrapParens(cond, s.parenKind);
		if (not.kind != s.notKind || not.children.length != 1) return null;
		final operand: QueryNode = not.children[0];
		final kept: QueryNode = s.parenKind != null && operand.kind == s.parenKind && operand.children.length == 1
			? operand.children[0]
			: operand;
		return builtinNot(not, site) ? kept : null;
	}

	/** Whether rebuilding `cond` as `kept`'s source alone would drop a comment (one outside `kept`). */
	public static function dropsComment(cond: QueryNode, kept: QueryNode, source: String): Bool {
		final condSpan: Null<Span> = cond.span;
		final keptSpan: Null<Span> = kept.span;
		return condSpan == null || (keptSpan == null || commentOutside(source, condSpan, keptSpan));
	}

	/** `negatedOperand` when its rebuild drops no comment — the condition a rule may emit positive — else null. */
	public static function positive(cond: QueryNode, site: Null<InversionSite>): Null<QueryNode> {
		if (site == null) return null;
		final kept: Null<QueryNode> = negatedOperand(cond, site);
		return kept == null || dropsComment(cond, kept, site.source) ? null : kept;
	}

	/**
	 * `<head><cond> ? <then> : <else><tail>` replacing `span` as a `ParenGuard` edit, oriented
	 * positive: when `cond` is a negated condition `positive` accepts, the `!` is dropped and the
	 * two values change places, and BOTH values become holes as well as the condition — each now
	 * lands in the other's slot, so the parse round-trip is what proves the swap re-reads as the
	 * same two nodes. Otherwise exactly `ParenGuard.ternaryEdit` over the condition as written.
	 */
	public static function ternaryEdit(
		span: Span, head: String, cond: QueryNode, thenText: String, elseText: String, tail: String, source: String,
		site: Null<InversionSite>
	): GuardedEdit {
		final condSpan: Null<Span> = cond.span;
		if (condSpan == null) throw new Exception('NegatedCondition.ternaryEdit: a condition without a span');
		final kept: Null<QueryNode> = positive(cond, site);
		final keptSpan: Null<Span> = kept?.span;
		if (keptSpan == null)
			return ParenGuard.ternaryEdit(span, head, source.substring(condSpan.from, condSpan.to), thenText, elseText, tail);
		final positiveText: String = source.substring(keptSpan.from, keptSpan.to);
		final edit: GuardedEdit = ParenGuard.ternaryEdit(span, head, positiveText, elseText, thenText, tail);
		final firstFrom: Int = head.length + positiveText.length + ' ? '.length;
		final secondFrom: Int = firstFrom + elseText.length + ' : '.length;
		edit.holes.push(new Span(firstFrom, firstFrom + elseText.length));
		edit.holes.push(new Span(secondFrom, secondFrom + thenText.length));
		return edit;
	}

	/**
	 * Whether the `!` an inversion DROPS is the language's own. A tree declaring no `@:op(!A)` pays a
	 * map lookup and nothing more: `declared` is false and no operand type is ever resolved. A tree
	 * that does declare one is judged per occurrence, which needs the file's tree; a site handed none
	 * answers false — the condition is then emitted as written, never inverted on a guess.
	 */
	private static function builtinNot(not: QueryNode, site: InversionSite): Bool {
		final selection: Null<OperatorSelection> = site.seams.selection;
		if (selection == null) return true;
		final kinds: Array<String> = [site.seams.notKind];
		if (!selection.declared(kinds)) return true;
		final root: Null<QueryNode> = site.root;
		return root != null && selection.verdictFor(not, kinds, selection.typingFor(site.file, site.source, root)).match(Builtin);
	}

	/** Whether a comment lies in `outer` before or after `inner` — the part of `outer` a rebuild as `inner` drops. */
	private static function commentOutside(source: String, outer: Span, inner: Span): Bool {
		return SourceComments.hasCommentMarker(source, outer.from, inner.from) || SourceComments.hasCommentMarker(
			source, inner.to, outer.to
		);
	}

}

/** The per-run half of a negation read: the not and paren kinds, and the run's operator table. */
typedef InversionSeams = {
	final notKind: String;
	final parenKind: Null<String>;

	/** Null when the grammar declares no operator-overload annotation — every `!` is then built in. */
	final selection: Null<OperatorSelection>;
};

/** One file's negation context: the run seams plus the file, its source and its parsed tree. */
typedef InversionSite = {
	final seams: InversionSeams;
	final file: String;
	final source: String;

	/** The file's tree, read only when the run declares an overloaded `!` (to type the operand). */
	final root: Null<QueryNode>;
};
