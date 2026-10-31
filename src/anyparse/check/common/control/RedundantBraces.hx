package anyparse.check.common.control;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.common.control.BranchChain.ChainSeams;
import anyparse.check.scan.IfExpressionChain;
import anyparse.check.scan.LoopScan;
import anyparse.query.CanonicalEdit;
import anyparse.query.CondRegionScan;
import anyparse.query.ParseGate;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;

using StringTools;

/**
 * Flags braces around a single statement that nothing needs: every branch of an if / else-if chain, or a loop body,
 * holding one statement in a block - `if (a) { p(); } else { q(); }`, `for (c in s) { p(); }`. `Info` and `DefaultOff`:
 * which spelling to keep is the project's taste, so opt in with `"redundant-braces": { "enabled": true }`. `fix` strips
 * the braces and the whitespace they carried, leaving the statement as written.
 *
 * A block is kept, and its chain or loop is not a finding, when its braces do work:
 *
 * - its statement could take a following `else` - an else-less conditional anywhere in it, in a position an `else` can
 *   follow (`IfExpressionChain.childShielded`) - which removing the braces would re-bind (the dangling else);
 * - its statement is a declaration (braces scope the binding), an `if` (`collapsible-if` / `collapsible-else-if` own
 *   those shapes), another block (`unnecessary-block` owns it) or a conditional-compilation region;
 * - its statement does not close on a terminator of its own (`BranchChain.selfTerminated`);
 * - a comment sits between a brace and the statement.
 *
 * A chain is the unit, as in `asymmetric-branch-braces`: it is a finding only when EVERY branch can go bare (an
 * `else switch` is neither braced nor bare), so the fix never leaves one braced branch beside a bare one and the two
 * rules never claim one chain. A `do … while` body and a `try` / `catch` are not read.
 */
@:nullSafety(Strict)
final class RedundantBraces extends RuleBase implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'redundant-braces';

	/** The then branch is the second child of an if node - `[cond, then, else]`. */
	private static inline final THEN_BRANCH_INDEX: Int = 1;

	/** The else branch is the third child of an if node - `[cond, then, else]`. */
	private static inline final ELSE_BRANCH_INDEX: Int = 2;

	public function new() {
		super(
			RULE_ID, 'braces around the one statement of every branch of an if/else chain, or of a loop body, that nothing needs',
			RuleCategory.Control
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (found in collect(tree, siteOf(plugin, entry.source, seams))) violations.push({
				file: entry.file,
				span: found.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: found.message
			});
		});
	}

	/**
	 * Strips the braces of every block a finding names, all of them or none: the source with them stripped must parse
	 * back as the same construct with each block replaced by its statement (`sameAfter`), or the finding is declined.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.editsWith(plugin, source, resolveSeams(plugin), (tree, seams) -> {
			final site: Site = siteOf(plugin, source, seams);
			final edits: Array<FixEdit> = [];
			for (found in collect(tree, site)) {
				final finding: Null<Violation> = violations.find(v -> v.span?.from == found.span.from && v.span?.to == found.span.to);
				if (finding == null) continue;
				final own: Array<FixEdit> = [for (block in found.blocks) for (e in unbraceEdits(block, site) ?? []) e];
				if (sameAfter(site, found, own))
					for (e in own) edits.push(e);
				else
					finding.declineReason = 'the unbraced source does not parse back as the same statements';
			}
			return edits;
		});
	}

	/** Every finding in `root`, in document order. */
	private static function collect(root: QueryNode, site: Site): Array<Unbrace> {
		final out: Array<Unbrace> = [];
		walk(root, site, out, true, false);
		return out;
	}

	/**
	 * Collects the finding of every chain HEAD - an `if` that is not the else of another (`link` false) - and every loop
	 * below `node`; `shielded` says whether a token after `node` can be an `else` (`IfExpressionChain.childShielded`).
	 */
	private static function walk(node: QueryNode, site: Site, out: Array<Unbrace>, shielded: Bool, link: Bool): Void {
		final seams: Seams = site.seams;
		if (seams.opaqueKinds.contains(node.kind)) return;
		final found: Null<Unbrace> = if (seams.ifKinds.contains(node.kind) && !link)
			chainFinding(node, site, shielded)
		else if (seams.loopKinds.contains(node.kind))
			loopFinding(node, site, shielded)
		else
			null;
		if (found != null) out.push(found);
		final elseLink: Null<QueryNode> = BranchChain.elseOf(node, seams.ifKinds);
		for (i => child in node.children)
			walk(
				child, site, out, IfExpressionChain.childShielded(node, i, seams.shield, shielded),
				child == elseLink && seams.ifKinds.contains(child.kind)
			);
	}

	/**
	 * The finding of the chain `head` starts when every branch of it is a removable block (`removable`): each link's
	 * then branch and a final `else` that is neither a link nor an `else switch`. Null otherwise.
	 */
	private static function chainFinding(head: QueryNode, site: Site, shielded: Bool): Null<Unbrace> {
		final seams: Seams = site.seams;
		final span: Null<Span> = head.span;
		if (span == null) return null;
		final blocks: Array<QueryNode> = [];
		var at: Bool = shielded;
		for (link in BranchChain.linksFrom(head, seams.ifKinds)) {
			final then: QueryNode = link.children[THEN_BRANCH_INDEX];
			if (!removable(then, site, IfExpressionChain.childShielded(link, THEN_BRANCH_INDEX, seams.shield, at))) return null;
			blocks.push(then);
			final last: Null<QueryNode> = BranchChain.elseOf(link, seams.ifKinds);
			at = IfExpressionChain.childShielded(link, ELSE_BRANCH_INDEX, seams.shield, at);
			if (last == null || seams.ifKinds.contains(last.kind) || seams.switchKinds.contains(last.kind)) continue;
			if (!removable(last, site, at)) return null;
			blocks.push(last);
		}
		return {
			span: span,
			node: head,
			blocks: blocks,
			message: 'every branch of this if/else holds one statement in braces it does not need'
		};
	}

	/** The finding of `loop` when its body is a removable block; a `do … while` is not read. */
	private static function loopFinding(loop: QueryNode, site: Site, shielded: Bool): Null<Unbrace> {
		final seams: Seams = site.seams;
		final span: Null<Span> = loop.span;
		final body: Null<QueryNode> = seams.doWhileKinds.contains(loop.kind) ? null : LoopScan.loopBody(loop, seams.doWhileKinds);
		if (span == null || body == null) return null;
		final bodyShielded: Bool = IfExpressionChain.childShielded(loop, loop.children.length - 1, seams.shield, shielded);
		return removable(body, site, bodyShielded) ? {
			span: span,
			node: loop,
			blocks: [body],
			message: 'this loop body holds one statement in braces it does not need'
		} : null;
	}

	/**
	 * Whether `block` is a block of one statement whose braces do no work: not a kept kind, closing on a terminator of
	 * its own, holding no else-less conditional where `shielded` is false (a following `else` would re-bind onto it),
	 * and with nothing but whitespace between each brace and the statement.
	 */
	private static function removable(block: QueryNode, site: Site, shielded: Bool): Bool {
		final seams: Seams = site.seams;
		if (block.kind != seams.closing.blockStmtKind || block.children.length != 1) return false;
		final statement: QueryNode = block.children[0];
		return !seams.keptKinds.contains(statement.kind)
			&& !CondRegionScan.isConditionalKind(statement.kind, seams.shield.shape)
			&& BranchChain.selfTerminated(statement, site.source, seams.closing)
			&& (shielded || !IfExpressionChain.holdsElseLessConditional(statement, seams.shield.conditionalKinds))
			&& unbraceEdits(block, site) != null;
	}

	/**
	 * The two deletions that strip `block`'s braces - the opening brace up to its statement, and the statement's last
	 * token (`IfExpressionChain.tokenSpan`) up to the closing brace - or null when either holds more than the brace and
	 * whitespace.
	 */
	private static function unbraceEdits(block: QueryNode, site: Site): Null<Array<FixEdit>> {
		final outer: Null<Span> = block.span;
		final inner: Null<Span> = block.children.length == 1 ? block.children[0].span : null;
		if (outer == null || inner == null) return null;
		final end: Int = IfExpressionChain.tokenSpan(inner, site.source, site.comments).to;
		return site.source.substring(outer.from, inner.from).trim() == '{' && site.source.substring(end, outer.to).trim() == '}' ? [
			{ span: new Span(outer.from, inner.from), text: '' },
			{ span: new Span(end, outer.to), text: '' }
		] : null;
	}

	/**
	 * Whether the source with `edits` applied parses back with `found`'s construct where it was and, block for block,
	 * the same shape with each stripped block replaced by its statement - nothing re-bound, nothing re-grouped.
	 */
	private static function sameAfter(site: Site, found: Unbrace, edits: Array<FixEdit>): Bool {
		final rewritten: Null<QueryNode> = ParseGate.parseOrNull(site.plugin, CanonicalEdit.applyEdits(site.source, edits));
		final from: Null<Int> = found.node.span?.from;
		if (rewritten == null || from == null || edits.length == 0) return false;
		final after: Null<QueryNode> = TreePath.firstAround(
			rewritten, new Span(from, from), n -> n.span?.from == from && n.kind == found.node.kind
		);
		return after != null && shapeOf(after, []) == shapeOf(found.node, found.blocks);
	}

	/** The kind tree of `node`, each block of `unwrapped` read as its one statement. */
	private static function shapeOf(node: QueryNode, unwrapped: Array<QueryNode>): String {
		final at: QueryNode = unwrapped.contains(node) ? node.children[0] : node;
		final children: String = [for (child in at.children) shapeOf(child, unwrapped)].join(',');
		return '${at.kind}($children)';
	}

	/** The per-file context of one source. */
	private static function siteOf(plugin: GrammarPlugin, source: String, seams: Seams): Site {
		return {
			source: source,
			seams: seams,
			plugin: plugin,
			comments: SourceComments.collectCommentTokens(plugin.lexicalRegions(source))
		};
	}

	/**
	 * The kinds this check reads, or null when the grammar names no statement-position `if` kind or no block-statement
	 * kind (the check is then a no-op).
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final chain: Null<ChainSeams> = BranchChain.chainSeams(shape);
		if (chain == null) return null;
		final kept: Array<String> = chain.ifKinds.concat([chain.blockStmtKind]);
		for (kinds in [
			shape.localDeclKinds,
			shape.staticLocalDeclKinds,
			shape.localFunctionKinds,
			shape.inlineFunctionKinds
		]) for (kind in kinds ?? []) kept.push(kind);
		return {
			ifKinds: chain.ifKinds,
			loopKinds: ShapeVocab.statementLoopKinds(shape),
			doWhileKinds: shape.doWhileLoopKinds ?? [],
			switchKinds: shape.switchStatementKinds ?? [],
			keptKinds: kept,
			opaqueKinds: shape.opaqueKinds ?? [],
			closing: chain,
			shield: IfExpressionChain.shieldSeams(shape, plugin.controlFlowSupport()?.blockKinds() ?? [])
		};
	}

}

/** The seam kinds `RedundantBraces` reads. */
private typedef Seams = {
	final ifKinds: Array<String>;

	/** Every loop statement; a `do … while` one (`doWhileKinds`) is skipped. */
	final loopKinds: Array<String>;

	final doWhileKinds: Array<String>;

	/** The `switch` statement kinds: an `else switch` is neither braced nor bare. */
	final switchKinds: Array<String>;

	/** Statements whose braces are kept: `if`s, blocks and every local declaration kind. */
	final keptKinds: Array<String>;

	/** Subtrees not walked: a macro reification is code the program builds, not code it runs. */
	final opaqueKinds: Array<String>;

	/** The chain and statement-closing seams the brace rules share (`BranchChain.chainSeams`). */
	final closing: ChainSeams;

	/** The dangling-`else` position gate's inputs (`IfExpressionChain.shieldSeams`). */
	final shield: ShieldSeams;
};

/** One file's context: its source and comment tokens, the seams and the grammar. */
private typedef Site = {
	final source: String;
	final seams: Seams;
	final plugin: GrammarPlugin;
	final comments: Array<CommentTok>;
};

/** One finding: the reported span, the chain head or loop it is anchored on, the blocks the fix strips, the message. */
private typedef Unbrace = {
	final span: Span;
	final node: QueryNode;
	final blocks: Array<QueryNode>;
	final message: String;
};
