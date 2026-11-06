package anyparse.check.scan;

import anyparse.check.scan.PurityScan.PurityCtx;
import anyparse.check.scan.TailScan.TailSeams;
import anyparse.query.SymbolIndex;
import anyparse.query.UnchangedLocal;
import anyparse.query.WriteSites;

/**
 * The one answer to "may the statements every branch of an if chain OPENS with run once BEFORE the chain, ahead of every
 * condition, instead of first inside the taken branch": the shared prefix of the branches and the gates that decide how much
 * of it may jump over the conditions. Used by `hoist-common-branch-head`; its sibling question about the end of the
 * branches is `TailScan`'s.
 *
 * Moving a run ahead of a condition changes what the condition sees, so the gates are stricter than a tail's, and every
 * one asks the owner of its question rather than a spelling model:
 *
 *  - NO EXIT — no `return` / `throw` / `break` / `continue` anywhere in the run.
 *  - NO DECLARATION CAPTURE — a local the run declares leaves its branch for the enclosing block, so no condition and no
 *    statement after the chain may read that spelling, and no declaration may be left unenumerated.
 *  - PURE CONDITIONS, OR A CONSTANT RUN — a condition `PurityScan.isPure` does not clear (a call, an assignment, a
 *    property getter) admits only a run of local declarations whose initializers are constants: such a run neither reads
 *    nor changes anything the condition can touch.
 *  - LOCALS HOLD — every local a condition reads must keep its value across the run (`UnchangedLocal.holds`: no write in the
 *    run, no function literal or local function that writes it, which a call in the run may invoke).
 *  - ANY OTHER READ MEANS AN INERT RUN — a condition reading a field, an index, a static or any non-local name admits the
 *    run only when it holds no call `PurityScan` does not clear, no constructor call, and no write but to a plain local that
 *    `WriteSites.mayOverlap` cannot match against what the conditions read.
 */
@:nullSafety(Strict)
final class HeadScan {

	/**
	 * The per-file context of the gates, built on first use: the symbol index is forced only for a chain that survived the
	 * structural gates. Null when the index or the grammar's field-access / call seam is missing — the gates then refuse.
	 */
	public static function lazyContext(
		plugin: GrammarPlugin, source: String, tree: QueryNode, symbols: () -> Null<SymbolIndex>
	): () -> Null<HeadCtx> {
		var built: Bool = false;
		var ctx: Null<HeadCtx> = null;
		return () -> {
			if (!built) {
				built = true;
				final index: Null<SymbolIndex> = symbols();
				final purity: Null<PurityCtx> = index == null ? null : PurityScan.contextOf(plugin, source, tree, index);
				if (purity != null) ctx = { unchanged: new UnchangedLocal(tree, purity.shape), purity: purity, tree: tree };
			}
			return ctx;
		};
	}

	/** Length of the longest prefix every list shares under `TailScan.sameStatement`. */
	public static function commonPrefix(lists: Array<Array<QueryNode>>, source: String): Int {
		final first: Array<QueryNode> = lists[0];
		var k: Int = 0;
		while (k < first.length && lists.foreach(l -> k < l.length && TailScan.sameStatement(l[k], first[k], source))) k++;
		return k;
	}

	/**
	 * The longest prefix length every gate admits: the common prefix, shortened from its END until the run may move.
	 * `conds` are the conditions of every link of the chain, `following` the statements after the chain in its block.
	 */
	public static function admissibleLength(
		lists: Array<Array<QueryNode>>, conds: Array<QueryNode>, following: Array<QueryNode>, source: String, seams: TailSeams,
		context: () -> Null<HeadCtx>
	): Int {
		var count: Int = commonPrefix(lists, source);
		while (count > 0 && !mayPrecede(lists[0].slice(0, count), conds, following, seams, context)) count--;
		return count;
	}

	/** Whether `run` may execute before `conds` instead of after the first of them, see the class doc. */
	public static function mayPrecede(
		run: Array<QueryNode>, conds: Array<QueryNode>, following: Array<QueryNode>, seams: TailSeams, context: () -> Null<HeadCtx>
	): Bool {
		if (run.exists(s -> exits(s, seams)) || TailScan.hasOpaqueDecl(run, seams)) return false;
		final declared: Array<String> = TailScan.localDeclNames(run, seams);
		if (TailScan.referencesAny(conds.concat(following), declared, seams.identKinds)) return false;
		final first: Null<Span> = run[0].span;
		final last: Null<Span> = run[run.length - 1].span;
		final ctx: Null<HeadCtx> = context();
		if (first == null || last == null || ctx == null) return false;
		if (!conds.foreach(c -> PurityScan.isPure(c, ctx.purity))) return run.foreach(s -> isConstantDecl(s, ctx.purity.safeKinds, seams));
		final region: Span = new Span(first.from, last.to);
		return !readsBeyondHeldLocals(conds, region, seams, ctx) || isInert(run, conds, region, ctx);
	}

	/** Whether any node of `stmt`'s subtree leaves the enclosing flow. */
	private static function exits(stmt: QueryNode, seams: TailSeams): Bool {
		return seams.support.isTerminal(stmt) || stmt.children.exists(c -> exits(c, seams));
	}

	/** Whether a condition reads a field, an index or a name that is no local `UnchangedLocal` proves unchanged across `region`. */
	private static function readsBeyondHeldLocals(conds: Array<QueryNode>, region: Span, seams: TailSeams, ctx: HeadCtx): Bool {
		final purity: PurityCtx = ctx.purity;
		function visit(node: QueryNode): Bool {
			if (node.kind == purity.fieldAccessKind || node.kind == purity.indexAccessKind) return true;
			final unheld: Bool = seams.identKinds.contains(node.kind)
				&& !(node.kind == purity.identKind && ctx.unchanged.holds(node, region));
			return unheld || node.children.exists(visit);
		}
		return conds.exists(visit);
	}

	/**
	 * Whether `run` can change nothing a condition reads through a non-local name: no call `PurityScan` leaves uncleared, no
	 * constructor call (its body runs), and every write targets a plain local that no condition read may overlap.
	 */
	private static function isInert(run: Array<QueryNode>, conds: Array<QueryNode>, region: Span, ctx: HeadCtx): Bool {
		final purity: PurityCtx = ctx.purity;
		function quiet(node: QueryNode): Bool {
			final runsCode: Bool = node.kind == purity.shape.newExprKind
				|| (node.kind == purity.callKind && !PurityScan.isPure(node, purity));
			return !runsCode && node.children.foreach(quiet);
		}
		if (!run.foreach(quiet)) return false;
		final reads: Array<String> = [];
		for (c in conds) {
			final paths: Null<Array<String>> = WriteSites.readPaths(c, ctx.tree, purity.shape);
			if (paths == null) return false;
			for (p in paths) reads.push(p);
		}
		for (w in ctx.unchanged.writes) {
			final at: Null<Span> = w.node.span;
			if (at == null || at.from < region.from || region.to < at.to) continue;
			final path: Null<String> = w.path;
			if (path == null || path.indexOf('.') >= 0 || !ctx.unchanged.isLocal(WriteSites.rootBinding(path))) return false;
			if (reads.exists(r -> WriteSites.mayOverlap(path, r, false))) return false;
		}
		return true;
	}

	/** Whether `stmt` declares one local whose initializer (if any) is built from constants and operators alone. */
	private static function isConstantDecl(stmt: QueryNode, safeKinds: Array<String>, seams: TailSeams): Bool {
		final decl: Null<QueryNode> = TailScan.declaredNode(stmt, seams);
		if (decl == null || seams.fnDeclKinds.contains(decl.kind)) return false;
		final init: Null<QueryNode> = decl.children[decl.children.length - 1];
		return init == null || constant(init, safeKinds, seams);
	}

	private static function constant(node: QueryNode, safeKinds: Array<String>, seams: TailSeams): Bool {
		return safeKinds.contains(node.kind)
			&& !seams.identKinds.contains(node.kind)
			&& node.children.foreach(c -> constant(c, safeKinds, seams));
	}

}

/** The resolved facts the head gates ask of the owners: the unchanged-locals scan, the purity context and the tree. */
typedef HeadCtx = {
	final unchanged: UnchangedLocal;
	final purity: PurityCtx;
	final tree: QueryNode;
};
