package anyparse.check.common.control;

import anyparse.check.Check.FixEdit;
import anyparse.check.scan.TailScan;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;

/**
 * Flags a statement-position `if` / `else if` / … / `else` chain whose EVERY branch ends with the same
 * statements, and moves them after the chain:
 *
 * ```haxe
 * if (FileSystem.exists(dir)) { deleteRecursive(dir); FileSystem.createDirectory(dir); } else { FileSystem.createDirectory(dir); }
 * // -> if (FileSystem.exists(dir)) deleteRecursive(dir); FileSystem.createDirectory(dir);
 * ```
 *
 * `tail-merge` is the neighbouring question — a branch tail equal to the code that FOLLOWS the chain; this
 * rule compares the branches with EACH OTHER, so the two never claim the same statement. Only the TAIL moves:
 * a shared HEAD would have to jump over the condition, which can read what the head writes.
 *
 * ## Gates
 *
 *  - FINAL ELSE — an `if` without one never matches, and every `else if` arm counts as a branch.
 *  - SUFFIX — the longest run of statements token-identical in ALL branches (`TailScan.sameStatement`),
 *    shortened from its front until the gates below hold.
 *  - NO EXIT — no statement of the tail is a `return` / `throw` / `break` / `continue`; a branch that ends in
 *    one has no tail. A branch that may leave EARLIER is fine: the moved copy runs exactly when the `if`
 *    completes normally, which is when each branch's own copy ran.
 *  - NO TAIL DECLARATION — a local the tail declares would leave its branch's scope and could capture a
 *    later name of the enclosing block.
 *  - NO CAPTURE — no name bound by a branch's remaining statements (or by a multi-declarator whose names
 *    cannot be enumerated) is read in the tail: the same spelling would mean a different declaration.
 *  - NO CONDITIONAL COMPILATION anywhere in the `if`.
 *
 * ## Report-only
 *
 * `if (c) A else A` is flagged without an edit: dropping `c` is sound only when `c` is pure. An edit is also
 * refused when a branch other than the final `else` would be left empty (it would need an inverted
 * condition) or when a comment sits in a removed region.
 */
@:nullSafety(Strict)
final class HoistCommonBranchTail extends RuleBase {

	private static inline final RULE_ID: String = 'hoist-common-branch-tail';

	public function new() {
		super(RULE_ID, 'every branch of an if chain ends with the same statements — they can run once after the if', RuleCategory.Control);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, TailScan.resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (c in scan(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: c.tailSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: message(c)
			});
		});
	}

	/**
	 * Move each flagged — and comment-clean — common tail. Re-runs the SAME walk as `run` and keeps the
	 * candidates whose reported span is among `violations`. A candidate's edits apply together or not at all:
	 * a chain nested inside another chain that is being rewritten waits for the next pass, because the outer
	 * rewrite deletes or moves the very text the inner edits address.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {

		return RunScan.editsWith(plugin, source, TailScan.resolveSeams(plugin), (tree, seams) -> {
			final flagged: Array<String> = RunScan.spanKeys(violations);
			final applied: Array<Candidate> = [
				for (c in scan(tree, source, seams)) if (c.edits.length != 0 && flagged.contains('${c.tailSpan.from}:${c.tailSpan.to}')) c
			];
			return [
				for (c in applied) if (!applied.exists(o -> o.head != c.head && TreePath.covers(o.head, c.head.span))) for (e in c.edits) e
			];
		});
	}

	/** The reported wording. */
	private static inline function message(c: Candidate): String {
		return if (c.whole)
			'every branch of this if is the same — the condition chooses nothing, keep one copy'
		else if (c.count == 1)
			'every branch of this if ends with the same statement — move it after the if'
		else
			'every branch of this if ends with the same ${c.count} statements — move them after the if';
	}

	/** Every common-tail candidate in `tree`, in document order — the one walk `run` and `fix` share. */
	private static function scan(tree: QueryNode, source: String, seams: TailSeams): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(tree, false, source, seams, out);
		return out;
	}

	/**
	 * Visit `node`; an `if` is a chain head only as a DIRECT statement of a block, so an `else if` arm, an
	 * if-expression and a brace-less body are reached through their head or not at all. A macro-reification
	 * subtree is not walked: its statements may be spliced into a scope this walk never sees.
	 */
	private static function walk(node: QueryNode, inBlock: Bool, source: String, seams: TailSeams, out: Array<Candidate>): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (inBlock && seams.ifKinds.contains(node.kind)) {
			final candidate: Null<Candidate> = tryChain(node, source, seams);
			if (candidate != null) out.push(candidate);
		}
		final isBlock: Bool = seams.blockKinds.contains(node.kind);
		for (c in node.children) walk(c, isBlock, source, seams, out);
	}

	/** The candidate for the chain headed by `head`, or null when any gate refuses (see the class doc). */
	private static function tryChain(head: QueryNode, source: String, seams: TailSeams): Null<Candidate> {
		final branches: Null<Array<QueryNode>> = BranchChain.branchesOf(head, seams.ifKinds);
		if (branches == null) return null;
		final headSpan: Null<Span> = head.span;
		if (headSpan == null) return null;
		if (TailScan.hasConditionalCompilation(source, headSpan.from, headSpan.to)) return null;
		final lists: Array<Array<QueryNode>> = [for (b in branches) statementsOf(b, seams)];
		final count: Int = admissibleLength(lists, source, seams);
		if (count < 1) return null;
		final firsts: Array<Span> = [];
		final lasts: Array<Span> = [];
		for (l in lists) {
			final first: Null<Span> = l[l.length - count].span;
			final last: Null<Span> = l[l.length - 1].span;
			if (first == null) return null;
			if (last == null) return null;
			firsts.push(first);
			lasts.push(last);
		}
		final whole: Bool = lists.foreach(l -> l.length == count);
		return {
			head: head,
			tailSpan: new Span(firsts[0].from, lasts[0].to),
			count: count,
			whole: whole,
			edits: whole ? [] : fixEdits(branches, lists, firsts, lasts, count, source, seams.terminator)
		};
	}

	/** A branch as a statement list: a block's statements, or the one brace-less statement. */
	private static function statementsOf(branch: QueryNode, seams: TailSeams): Array<QueryNode> {
		return seams.blockKinds.contains(branch.kind) ? branch.children : [branch];
	}

	/** The longest tail length every gate admits: the common suffix, shortened from its front until they hold. */
	private static function admissibleLength(lists: Array<Array<QueryNode>>, source: String, seams: TailSeams): Int {
		var count: Int = commonSuffix(lists, source);
		while (count > 0 && !admissible(lists, count, seams)) count--;
		return count;
	}

	/** Length of the longest suffix every list shares under `TailScan.sameStatement`. */
	private static function commonSuffix(lists: Array<Array<QueryNode>>, source: String): Int {
		final first: Array<QueryNode> = lists[0];
		var k: Int = 0;
		while (
			k < first.length
			&& lists.foreach(l -> k < l.length && TailScan.sameStatement(l[l.length - 1 - k], first[first.length - 1 - k], source))
		)
			k++;
		return k;
	}

	/** Whether the last `count` statements of every list may move: no exit, no declaration, no captured name. */
	private static function admissible(lists: Array<Array<QueryNode>>, count: Int, seams: TailSeams): Bool {
		final tail: Array<QueryNode> = lists[0].slice(lists[0].length - count);
		if (tail.exists(s -> seams.support.isTerminal(s))) return false;
		if (TailScan.localDeclNames(tail, seams).length != 0 || TailScan.hasOpaqueDecl(tail, seams)) return false;
		for (l in lists) {
			final kept: Array<QueryNode> = l.slice(0, l.length - count);
			if (TailScan.hasOpaqueDecl(kept, seams)) return false;
			if (TailScan.referencesAny(tail, TailScan.localDeclNames(kept, seams), seams.identKinds)) return false;
		}
		return true;
	}

	/**
	 * The edits that move the tail, or none when the layout or a comment forbids it: each remaining branch
	 * loses its tail with the trivia before it, and the last branch's copy is written after the chain — in
	 * place of the whole `else` when that branch held nothing else. Only the final `else` may end up empty.
	 */
	private static function fixEdits(
		branches: Array<QueryNode>, lists: Array<Array<QueryNode>>, firsts: Array<Span>, lasts: Array<Span>, count: Int, source: String,
		terminator: Null<String>
	): Array<FixEdit> {

		final last: Int = branches.length - 1;
		final chainEnd: Null<Span> = branches[last].span;
		final beforeElse: Null<Span> = branches[last - 1].span;
		if (chainEnd == null) return [];
		if (beforeElse == null) return [];
		final after: Int = terminatorEnd(source, chainEnd.to, terminator);
		final edits: Array<FixEdit> = [];
		for (i => branch in branches) {
			final kept: Int = lists[i].length - count;
			if (kept == 0) {
				if (i != last) return [];
				if (CheckScan.hasCommentMarker(source, beforeElse.to, firsts[i].from)) return [];
				if (CheckScan.hasCommentMarker(source, lasts[i].to, after)) return [];
				continue;
			}
			final prev: Null<Span> = lists[i][kept - 1].span;
			final block: Null<Span> = branch.span;
			if (prev == null) return [];
			if (block == null) return [];
			if (TailScan.runComments(source, lists[i].slice(kept), prev.to).length != 0) return [];
			if (CheckScan.hasCommentMarker(source, lasts[i].to, block.to)) return [];
			edits.push({ span: new Span(prev.to, lasts[i].to), text: '' });
		}
		final copy: String = '\n${source.substring(firsts[last].from, lasts[last].to)}';
		final emptied: Bool = lists[last].length == count;
		edits.push({ span: new Span(emptied ? beforeElse.to : after, after), text: copy });
		return edits;
	}

	/**
	 * The offset just past the statement terminator that follows `from` (whitespace and comments aside), or `from` itself when
	 * none does: a chain written as a statement keeps its `;` outside its node, and the moved tail must go after it, or replace
	 * it, rather than stand in front of a stray empty statement.
	 */
	private static function terminatorEnd(source: String, from: Int, terminator: Null<String>): Int {
		if (terminator == null) return from;
		final at: Int = SourceComments.skipForwardTrivia(source, from);
		return source.substr(at, terminator.length) == terminator ? at + terminator.length : from;
	}

}

/**
 * One common tail: `tailSpan` is what the finding reports (the FIRST branch's tail), `count` how many
 * statements it holds, `whole` whether every branch is nothing but the tail, and `edits` the rewrite
 * (empty when the finding is report-only).
 */
private typedef Candidate = {
	final head: QueryNode;
	final tailSpan: Span;
	final count: Int;
	final whole: Bool;
	final edits: Array<FixEdit>;
};
