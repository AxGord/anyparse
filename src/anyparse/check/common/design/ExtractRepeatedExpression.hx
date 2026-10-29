package anyparse.check.common.design;

import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.PurityScan;
import anyparse.check.scan.SpanRender;
import anyparse.query.IndexScope;
import anyparse.query.MemberKinds;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;
import anyparse.query.WriteSites;

/**
 * Flags a NON-TRIVIAL, PURE value expression that appears three or more times,
 * literally identical up to LAYOUT — whitespace between tokens, never a literal's
 * own interior — within ONE function body: a candidate for a `final x = <expr>;`
 * extraction so the value is computed once and reused.
 * `Info`, REPORT-ONLY: whether an extraction reads better (and where the `final`
 * belongs) is an author judgement, and the safe-extraction preconditions here are
 * heuristic, so `fix` produces no edits.
 *
 * ## What is a candidate
 *
 * - **Value expressions only.** A candidate root is a field-access chain
 *   (`a.b.c`), a call (`Math.max(a, b)`) or an index access (`a.b.c[i]`) — the
 *   `fieldAccessKind` / `callKind` / `indexAccessKind` shapes. A bare identifier,
 *   a literal and an operator expression are not roots; a repeated operator
 *   expression surfaces through its own reusable value sub-parts instead.
 * - **Non-trivial.** The subtree must hold at least one call OR a field-access
 *   chain of depth two or more (`maxFieldChainDepth`). A bare identifier, a
 *   literal, and a single-hop `this.x` / `a.b` therefore never qualify — caching
 *   them buys nothing.
 * - **Pure.** Every node is a side-effect-free skeleton kind
 *   (`RefactorSupport.isSafeKind` — literals, identifiers, operators, ternary), a
 *   field / index READ, or a provably-pure stdlib call (`Math` / `Std` /
 *   `StringTools`, minus the non-deterministic `random`). A call is impure unless
 *   provably pure, so an instance / local call of unknown effect is never a
 *   candidate; a field read whose FIRST resolvable hop is a property GETTER
 *   (`MemberLookup.memberGetter`, via `TypeResolver`) is treated as impure. This
 *   keeps "compute once, reuse" behaviour-preserving: only referentially
 *   transparent expressions are suggested.
 * - **Repeated three or more times** (`MIN_OCCURRENCES`) inside the SAME function
 *   body — a nested function / lambda is a separate body (its expressions never
 *   fold into the enclosing one), and a `MacroExpr` reification subtree is skipped
 *   (its identifiers may be spliced from elsewhere). Occurrences are bucketed by
 *   `CheckScan.normalizeSpan` and every surviving bucket is then re-split by
 *   `SpanRender` (`splitByRender`): the norm is one linear scan and the cheap way
 *   to find a repeat, but it collapses a string literal's own interior, so on its
 *   own it would group `replace(s, "  ", " ")` with `replace(s, " ", " ")` — two
 *   values no single `final` can hold, and a message quoting a spelling the
 *   reported span does not carry.
 *
 * ## Exclusions
 *
 * - **Mutually-exclusive branches.** When every occurrence sits in a DIFFERENT
 *   branch of one common `if` / `switch` (only one branch runs per invocation), the
 *   repeats never co-execute and a shared local buys nothing — the group is
 *   dropped. Two occurrences co-execute unless a shared conditional ancestor puts
 *   them in different branch children (child index >= 1, since `children[0]` is the
 *   always-evaluated condition / subject of every `branchConditionKinds` /
 *   `switchKinds` node).
 * - **Callee position.** An expression in the CALLEE slot of a call (`f.g.h` in `f.g.h(x)`) is
 *   descended into but never counted. It names a METHOD, not a value: a `final` bound to it
 *   holds a bound method, which is not what "compute once, reuse" means and is not what any
 *   author does with the suggestion. The gate is positional, so the same text counted as a
 *   VALUE elsewhere (an argument, a receiver, a right-hand side) still groups normally — and
 *   the callee's own RECEIVER is still a candidate, so a genuinely repeated value inside a
 *   repeated call surfaces in its own right (`a.b.c` out of `a.b.c.d(…)`).
 * - **Write target.** The target of an assignment, compound assignment or increment (`a.b.c` in `a.b.c = v`,
 *   `RefShape.writeParentKinds`' first child) is descended into but never counted either: it is the storage the
 *   write replaces, not a value a `final` could hold — and it would join the reads before its own write as one
 *   more "occurrence" of a value it is about to change. Its receiver (`a.b`) is still a read.
 * - **Subsumed sub-expressions.** A repeated sub-expression whose every occurrence
 *   nests inside an occurrence of an equally- or more-frequent larger repeated
 *   expression is dropped, so a chain reports at its maximal form (`a.b.c()` once,
 *   not also `a.b.c` and `a.b`) — unless the shorter form also recurs on its own.
 *
 * ## Same value
 *
 * Spelled alike is not enough: the occurrences of one group must read ONE value, which an operand written between
 * two of them breaks. Each group is checked against the shared binder and write facts (`Refs` through
 * `WriteSites`), positively — what cannot be placed counts as a write:
 *
 * - **Binding.** Occurrences whose operands bind DIFFERENT declarations (a comprehension binder each, a redeclared
 *   local) are separate groups; one whose operand the binder names nothing for is no group at all.
 * - **A write between two occurrences** — an assignment in any operator spelling, `++` / `--`, a parenthesised,
 *   cast, member or index target on an operand's path (`(i) += 1`, `a.b = …` under `a.b.c`, `this.x` for a bare
 *   `x`), or a target with no nameable root (`f().x = …`) — cuts the group there, at the write's EFFECT point (the
 *   end of its node: `i = Std.int(i) + 1` reads first). Each side is a run of its own and must reach the threshold
 *   alone. A sibling path (`a.x = …` under `a.y`) is no write of it, and neither is one below a group that IS the
 *   chain (`a.b.c.d = …` under `a.b.c`: the same reference).
 * - **A loop's back edge.** A write later in a loop than an occurrence it holds still reaches that occurrence on the
 *   next iteration, so the run is dropped unless the statement list a shared `final` would go into lies inside that
 *   loop, where each iteration recomputes it — never when an occurrence is the loop's condition.
 * - **A write that runs elsewhere** — inside a function nested in the body, or, for a local the body captures, in a
 *   closure other than the one declaring it (a call the body makes may run it) — kills the group whole: no position
 *   decides when it runs. A write in the declaring body cannot run while a closure reading the local does.
 *
 * Not modelled: a MEMBER written by another body, which a call between occurrences may reach — the same assumption
 * the purity rule makes when it reads a field chain as pure across calls.
 *
 * ## Grammar-agnostic
 *
 * Everything is driven off `RefShape`: a grammar without a field-access or call
 * kind makes the check a no-op. The finding is spanned at the earliest occurrence.
 */
@:nullSafety(Strict)
final class ExtractRepeatedExpression extends RuleBase implements VolatileMessage implements NoAutofix {

	/** The least number of identical occurrences within one body to report. */
	private static inline final MIN_OCCURRENCES: Int = 3;

	/** The shortest field-access chain (`a.b` = 1, `a.b.c` = 2) that counts as non-trivial without a call. */
	private static inline final MIN_CHAIN_DEPTH: Int = 2;

	/** The longest normalized expression text shown in a message before truncation. */
	private static inline final MAX_MSG_EXPR: Int = 60;

	private static inline final RULE_ID: String = 'extract-repeated-expression';

	/**
	 * The tail that follows the OCCURRENCE TALLY in a message, shared by the builder and by
	 * `messageIdentity` so the mask anchor cannot drift from the wording it points at. Read
	 * BACKWARDS from, because the count precedes it — anchoring on ` is repeated ` instead
	 * would also mask a digit run inside an expression that happens to spell that phrase.
	 */
	private static inline final REPEAT_TAIL: String = ' times in one function body';

	public function new() {
		super(
			RULE_ID, 'a non-trivial pure expression repeated three or more times in one function body — a candidate for a final local',
			RuleCategory.Design
		);
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskBefore(message, REPEAT_TAIL);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final faKind: Null<String> = shape.fieldAccessKind;
		final callKind: Null<String> = shape.callKind;
		if (faKind == null || callKind == null) return [];
		final faK: String = faKind;
		final callK: String = callKind;
		final indexKind: Null<String> = shape.indexAccessKind;
		final candidateKinds: Array<String> = indexKind == null ? [faKind, callKind] : [faKind, callKind, indexKind];
		final functionUnitKinds: Array<String> = ShapeVocab.functionLikeKinds(shape);
		final exclusiveConditionalKinds: Array<String> = (shape.branchConditionKinds ?? []).concat(shape.switchKinds ?? []);
		final index: SymbolIndex = IndexScope.report(files, plugin);
		final loopKinds: Array<String> = ShapeVocab.loopKinds(shape);
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		return RunScan.collect(files, plugin, (entry, root, violations) -> {
			final purity: Null<PurityCtx> = PurityScan.contextOf(plugin, entry.source, root, index);
			if (purity == null) return;
			final resolved: PurityCtx = purity;
			final units: Array<QueryNode> = [];
			collectUnits(root, functionUnitKinds, units);
			final ctx: Ctx = {
				fieldAccessKind: faK,
				callKind: callK,
				candidateKinds: candidateKinds,
				functionUnitKinds: functionUnitKinds,
				exclusiveConditionalKinds: exclusiveConditionalKinds,
				opaqueKinds: shape.opaqueKinds ?? [],
				purity: resolved,
				shape: shape,
				tree: root,
				units: units,
				loopKinds: loopKinds,
				blockKinds: blockKinds,
				writes: null
			};
			for (unit in units) analyzeUnit(violations, entry.file, entry.source, unit, ctx);
		});
	}

	/** No mechanical edit — extraction (and where the `final` belongs) is an author decision. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'where the shared `final` belongs, and whether hoisting the value reads better at all, is an author judgement the'
			+ ' heuristic safe-extraction preconditions here cannot make — once it is chosen,'
			+ ' `apq extract-var <file> --match <expr> <name>` performs the hoist';
	}

	/** Whether `outer` strictly contains `inner` (covers it and is not the identical span). */
	private static inline function strictlyContains(outer: Span, inner: Span): Bool {
		return outer.from <= inner.from && inner.to <= outer.to && (outer.from < inner.from || inner.to < outer.to);
	}

	/** Whether `span` holds the byte at `offset`. */
	private static inline function holds(span: Null<Span>, offset: Int): Bool {
		return span != null && span.from <= offset && offset < span.to;
	}

	/** Whether `node`'s span covers `span`. */
	private static inline function covers(node: QueryNode, span: Null<Span>): Bool {
		final outer: Null<Span> = node.span;
		return outer != null && span != null && outer.from <= span.from && span.to <= outer.to;
	}

	/** Whether `inner` is a node other than `outer` inside `outer`'s span. */
	private static inline function strictlyWithin(inner: QueryNode, outer: QueryNode): Bool {
		return inner != outer && covers(outer, inner.span);
	}

	/** Every function / lambda node in `node`'s subtree — each is an independent body unit. */
	private static function collectUnits(node: QueryNode, functionUnitKinds: Array<String>, out: Array<QueryNode>): Void {
		if (functionUnitKinds.contains(node.kind)) out.push(node);
		for (c in node.children) collectUnits(c, functionUnitKinds, out);
	}

	/**
	 * Collect every candidate expression in `unit`'s own body (stopping at nested
	 * units / macro subtrees), group by normalized text, keep groups of at least
	 * `MIN_OCCURRENCES` that are non-trivial, pure and co-executing, drop subsumed
	 * sub-expression groups, and emit one `Info` per surviving group at its earliest
	 * occurrence.
	 */
	private static function analyzeUnit(out: Array<Violation>, file: String, source: String, unit: QueryNode, ctx: Ctx): Void {
		final candidates: Array<Candidate> = [];
		collect(unit, source, ctx, [], candidates, true);
		if (candidates.length < MIN_OCCURRENCES) return;
		final groups: Map<String, Array<Candidate>> = [];
		for (c in candidates) {
			final bucket: Null<Array<Candidate>> = groups[c.norm];
			if (bucket == null)
				groups[c.norm] = [c];
			else
				bucket.push(c);
		}
		final kept: Array<Group> = [];
		for (occ in groups) if (occ.length >= MIN_OCCURRENCES) for (text => exact in splitByRender(source, occ)) {
			if (exact.length < MIN_OCCURRENCES) continue;
			final rep: QueryNode = exact[0].node;
			if (!isNonTrivial(rep, ctx)) continue;
			if (!PurityScan.isPure(rep, ctx.purity)) continue;
			for (run in sameValueRuns(exact, unit, ctx)) if (run.length >= MIN_OCCURRENCES && !allPairsExclusive(run))
				kept.push({ render: text, occ: run });
		}
		for (g in dropSubsumed(kept)) {
			final first: Candidate = g.occ[0];
			out.push({
				file: file,
				span: first.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: buildMessage(g)
			});
		}
	}

	/**
	 * Walk `node`, appending each candidate-kind expression (with its whitespace-
	 * normalized text, span and branch path) to `out`. Descent stops at a nested
	 * function / lambda unit and at a macro-reification subtree. Entering a branch
	 * child (index >= 1) of an `if` / `switch` pushes that branch onto `path`, so a
	 * candidate records which mutually-exclusive branches it lives in. The CALLEE child of a call and the TARGET of a
	 * write (`uncounted`) are descended into but never recorded — see the class doc's position rules.
	 */
	private static function collect(
		node: QueryNode, source: String, ctx: Ctx, path: Array<BranchStep>, out: Array<Candidate>, isRoot: Bool, uncounted: Bool = false
	): Void {
		if (!isRoot && (ctx.functionUnitKinds.contains(node.kind) || ctx.opaqueKinds.contains(node.kind))) return;
		final span: Null<Span> = node.span;
		if (!isRoot && !uncounted && span != null && ctx.candidateKinds.contains(node.kind)) {
			final s: Span = span;
			out.push({
				node: node,
				span: s,
				norm: normalize(source, s),
				path: path.copy()
			});
		}
		final condKey: Null<String> = span != null && ctx.exclusiveConditionalKinds.contains(node.kind) ? '${span.from}:${span.to}' : null;
		for (i in 0...node.children.length) {
			final child: QueryNode = node.children[i];
			final childUncounted: Bool = i == 0 && (node.kind == ctx.callKind || ctx.shape.writeParentKinds.contains(node.kind));
			if (condKey != null && i >= 1) {
				final k: String = condKey;
				path.push({ key: k, idx: i });
				collect(child, source, ctx, path, out, false, childUncounted);
				path.pop();
			} else {
				collect(child, source, ctx, path, out, false, childUncounted);
			}
		}
	}

	/** At least one call, or a field-access chain of depth `MIN_CHAIN_DEPTH` — a bare read is trivial. */
	private static function isNonTrivial(node: QueryNode, ctx: Ctx): Bool {
		return MemberKinds.subtreeContainsKind(node, ctx.callKind) || maxFieldChainDepth(node, ctx.fieldAccessKind) >= MIN_CHAIN_DEPTH;
	}

	/** The deepest run of consecutive field accesses anywhere in `node`'s subtree (`a.b.c` = 2). */
	private static function maxFieldChainDepth(node: QueryNode, faKind: String): Int {
		var best: Int = 0;
		function chainLen(n: QueryNode): Int {
			return n.kind == faKind && n.children.length >= 1 ? 1 + chainLen(n.children[0]) : 0;
		}
		function walk(n: QueryNode): Void {
			if (n.kind == faKind) {
				final d: Int = chainLen(n);
				if (d > best) best = d;
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return best;
	}

	/** Whether every pair of occurrences is mutually exclusive — so at most one runs per invocation. */
	private static function allPairsExclusive(occ: Array<Candidate>): Bool {
		for (i in 0...occ.length) for (j in i + 1...occ.length) if (!mutuallyExclusive(occ[i].path, occ[j].path)) return false;
		return true;
	}

	/** Whether two branch paths diverge at a shared conditional — different branch children of one `if` / `switch`. */
	private static function mutuallyExclusive(a: Array<BranchStep>, b: Array<BranchStep>): Bool {
		for (sa in a) for (sb in b) if (sa.key == sb.key && sa.idx != sb.idx) return true;
		return false;
	}

	/**
	 * `occ` — one render-exact group whose purity is settled — cut into the runs that read ONE value (the class doc's
	 * "Same value"), each sorted by position: bucketed by the declarations its operands bind, a bucket dropped whole
	 * when some write of an operand runs where no position in `unit` decides when, then cut at every write of an
	 * operand between two occurrences, and a run dropped when a loop's back edge carries a write into it.
	 */
	private static function sameValueRuns(occ: Array<Candidate>, unit: QueryNode, ctx: Ctx): Array<Array<Candidate>> {
		final out: Array<Array<Candidate>> = [];
		for (bucket in bindingBuckets(occ, ctx)) if (bucket.occ.length >= MIN_OCCURRENCES) {
			final writes: Null<Array<WriteSite>> = ownWrites(bucket, unit, ctx);
			if (writes != null)
				for (run in splitAtWrites(bucket.occ, writes))
					if (run.length >= MIN_OCCURRENCES && !carriedRound(run, writes, unit, ctx)) out.push(run);
		}
		return out;
	}

	/**
	 * `occ` bucketed by the paths of what each occurrence reads (`WriteSites.readPaths`) — occurrences spelled alike whose
	 * operands bind DIFFERENT declarations (three comprehensions, each with its own binder) are different values. Empty
	 * when the binder names nothing for some operand: no write can be proven not to reach it.
	 */
	private static function bindingBuckets(occ: Array<Candidate>, ctx: Ctx): Array<BindingBucket> {
		final out: Array<BindingBucket> = [];
		for (c in occ) {
			final read: Null<Array<String>> = WriteSites.readPaths(c.node, ctx.tree, ctx.shape);
			if (read == null) return [];
			final paths: Array<String> = read;
			final signature: String = paths.join(',');
			final bucket: Null<BindingBucket> = out.find(b -> b.signature == signature);
			if (bucket == null)
				out.push({
					signature: signature,
					paths: paths,
					own: WriteSites.accessPath(c.node, ctx.tree, ctx.shape),
					occ: [c]
				});
			else
				bucket.occ.push(c);
		}
		for (b in out) b.occ.sort((x, y) -> x.span.from - y.span.from);
		return out;
	}

	/**
	 * The writes that may change a value `bucket` reads (`WriteSites.mayOverlap`; the group's own chain, when it is
	 * one, read as a reference) that `unit`'s own body performs — or null when one runs at a time no position in
	 * `unit` decides: inside a function nested in `unit` (it runs whenever it is called), or, for a local `unit`
	 * captures, in a closure other than the body that declares it (a call `unit` makes may run it). A write of the
	 * declaring body itself cannot run while `unit` does, and a member written in another body is outside what the
	 * rule models (the class doc's "Same value"). A write no path names (`WriteSite.path` null) writes every operand.
	 */
	private static function ownWrites(bucket: BindingBucket, unit: QueryNode, ctx: Ctx): Null<Array<WriteSite>> {
		final out: Array<WriteSite> = [];
		for (w in writesOf(ctx)) {
			final written: Null<String> = w.path;
			if (written != null && !bucket.paths.exists(p -> WriteSites.mayOverlap(written, p, p == bucket.own))) continue;
			final body: Null<QueryNode> = innermostUnitAt(w.effect - 1, ctx.units);
			if (body == unit)
				out.push(w);
			else if (body != null && (strictlyWithin(body, unit) || capturedWriteElsewhere(written, body, ctx)))
				return null;
		}
		return out;
	}

	/**
	 * Whether a write of `written` in `body` (a body outside the analyzed one) writes a LOCAL some other body declares —
	 * a binding declared inside a function unit. A member's declaration sits in no unit: a write of it in another body
	 * is outside what the rule models.
	 */
	private static function capturedWriteElsewhere(written: Null<String>, body: QueryNode, ctx: Ctx): Bool {
		final binding: Int = written == null ? -1 : WriteSites.rootBinding(written);
		if (binding < 0) return false;
		final declaring: Null<QueryNode> = innermostUnitAt(binding, ctx.units);
		return declaring != null && declaring != body;
	}

	/** `sorted` cut before every occurrence some write in `writes` takes effect ahead of, since the previous one. */
	private static function splitAtWrites(sorted: Array<Candidate>, writes: Array<WriteSite>): Array<Array<Candidate>> {
		final runs: Array<Array<Candidate>> = [[sorted[0]]];
		for (k in 1...sorted.length) {
			final prev: Int = sorted[k - 1].span.from;
			final cur: Int = sorted[k].span.from;
			if (writes.exists(w -> prev < w.effect && w.effect <= cur))
				runs.push([sorted[k]]);
			else
				runs[runs.length - 1].push(sorted[k]);
		}
		return runs;
	}

	/**
	 * Whether a loop's back edge carries one of `writes` into `run`: the loop holds the write and an occurrence, and
	 * the statement list a shared `final` would go into (`hoistBlock`) is not inside that loop — so no iteration
	 * recomputes the value before the occurrence reads it again. Positive: with no such list, every such loop carries.
	 */
	private static function carriedRound(run: Array<Candidate>, writes: Array<WriteSite>, unit: QueryNode, ctx: Ctx): Bool {
		final home: Null<QueryNode> = hoistBlock(run, unit, ctx);
		inline function recomputed(loop: QueryNode): Bool {
			return home != null && home != loop && covers(loop, home.span);
		}
		for (w in writes)
			for (loop in ancestorsOf(unit, w.effect - 1))
				if (ctx.loopKinds.contains(loop.kind) && !recomputed(loop) && run.exists(c -> covers(loop, c.span))) return true;
		return false;
	}

	/** The innermost `blockKinds` node holding every occurrence of `run` — the statement list a shared `final` goes into. */
	private static function hoistBlock(run: Array<Candidate>, unit: QueryNode, ctx: Ctx): Null<QueryNode> {
		var common: Array<QueryNode> = ancestorsOf(unit, run[0].span.from);
		for (c in run) {
			final chain: Array<QueryNode> = ancestorsOf(unit, c.span.from);
			var n: Int = 0;
			while (n < common.length && n < chain.length && common[n] == chain[n]) n++;
			common = common.slice(0, n);
		}
		var i: Int = common.length - 1;
		while (i >= 0 && !ctx.blockKinds.contains(common[i].kind)) i--;
		return i >= 0 ? common[i] : null;
	}

	/** The nodes from `root` down whose span holds `offset`, outermost first. */
	private static function ancestorsOf(root: QueryNode, offset: Int): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		var node: Null<QueryNode> = root;
		while (node != null) {
			out.push(node);
			node = node.children.find(c -> holds(c.span, offset));
		}
		return out;
	}

	/** The smallest function unit whose span holds `offset`, or null when none does. */
	private static function innermostUnitAt(offset: Int, units: Array<QueryNode>): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestLength: Int = 0;
		for (u in units) {
			final s: Null<Span> = u.span;
			if (s != null && holds(s, offset) && (best == null || s.to - s.from < bestLength)) {
				best = u;
				bestLength = s.to - s.from;
			}
		}
		return best;
	}

	/** The file's writes (`WriteSites.of`), collected the first time a group asks. */
	private static function writesOf(ctx: Ctx): Array<WriteSite> {
		final known: Null<Array<WriteSite>> = ctx.writes;
		if (known != null) return known;
		final all: Array<WriteSite> = WriteSites.of(ctx.tree, ctx.shape);
		ctx.writes = all;
		return all;
	}

	/** Drop a group whose every occurrence nests inside an equally- or more-frequent larger group's occurrence. */
	private static function dropSubsumed(groups: Array<Group>): Array<Group> {
		return [for (g in groups) if (!isSubsumed(g, groups)) g];
	}

	/**
	 * `occ` re-bucketed by RENDERED text — the EXACT key, which the whitespace-collapsed `norm`
	 * only approximates.
	 *
	 * `norm` collapses whitespace inside a string literal too, so `replace(s, "  ", " ")` and
	 * `replace(s, " ", " ")` land in one bucket — two expressions that are not the same value,
	 * for which no single `final` local can stand. The split is applied to a SURVIVING bucket
	 * rather than used as the bucket key: `norm` is one linear scan of the span while a render
	 * walks the subtree for its leaves, and a candidate that never repeats never needs the
	 * exact answer. Render equality implies `norm` equality, so no group is ever merged by it.
	 */
	private static function splitByRender(source: String, occ: Array<Candidate>): Map<String, Array<Candidate>> {
		final out: Map<String, Array<Candidate>> = [];
		for (c in occ) {
			final key: String = SpanRender.renderSpan(source, c.span.from, c.span.to, c.node);
			final bucket: Null<Array<Candidate>> = out[key];
			if (bucket == null)
				out[key] = [c];
			else
				bucket.push(c);
		}
		return out;
	}

	/** Whether every occurrence of `g` is strictly contained in some occurrence of a distinct group at least as frequent. */
	private static function isSubsumed(g: Group, groups: Array<Group>): Bool {
		return groups.exists(
			h ->
				h.render != g.render && h.occ.length >= g.occ.length
				&& g.occ.foreach(go -> h.occ.exists(ho -> strictlyContains(ho.span, go.span)))
		);
	}

	/**
	 * The finding message: occurrence count plus the truncated expression, RENDERED — whitespace
	 * between tokens collapsed, whitespace inside a token left alone.
	 *
	 * The text is quoted back to a reader expected to find it at the span the finding carries, so
	 * it has to be that span's bytes. It is well-defined only because the group is render-exact:
	 * `splitByRender` has already separated occurrences whose literals differ, so every member of
	 * `g` spells this text identically and the earliest one — the one the finding is spanned at —
	 * is not a special case.
	 */
	private static function buildMessage(g: Group): String {
		final text: String = g.render.length > MAX_MSG_EXPR ? '${g.render.substr(0, MAX_MSG_EXPR)}...' : g.render;
		return 'the expression `${text}` is repeated ${g.occ.length}$REPEAT_TAIL — extract into a `final` local (report-only)';
	}

	/**
	 * `source[span]` with every run of whitespace collapsed to a single space and the ends
	 * trimmed — `CheckScan.normalizeSpan`'s text half, shared with `duplicate-code` and
	 * `tail-merge`; this check has no use for its non-whitespace count.
	 *
	 * The cheap PREFILTER key only: it collapses whitespace inside a string literal as well, so a
	 * bucket it builds may hold expressions that are not the same value. `splitByRender` decides
	 * the ones that survive the occurrence threshold.
	 */
	private static function normalize(source: String, span: Span): String {
		return CheckScan.normalizeSpan(source, span.from, span.to).norm;
	}

}

/** A collected candidate expression: its node, span, normalized text, and enclosing branch path. */
private typedef Candidate = {
	var node: QueryNode;
	var span: Span;
	var norm: String;
	var path: Array<BranchStep>;
}

/** One step of a branch path: the span key of an `if` / `switch` node and the branch child index taken. */
private typedef BranchStep = {
	var key: String;
	var idx: Int;
}

/** A repeated-expression group: the shared RENDERED text (`SpanRender`) and its occurrences (earliest first). */
private typedef Group = {
	var render: String;
	var occ: Array<Candidate>;
}

/** Per-file resolved constants threaded through the recursive walk. */
private typedef Ctx = {
	var fieldAccessKind: String;
	var callKind: String;
	var candidateKinds: Array<String>;
	var functionUnitKinds: Array<String>;
	var exclusiveConditionalKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var purity: PurityCtx;
	var shape: RefShape;

	/** The file's tree — what `Refs` binds the operands against. */
	var tree: QueryNode;

	/** Every function unit of the file (`collectUnits`): a write's body, and a binding's declaring one, is the smallest holding it. */
	var units: Array<QueryNode>;
	var loopKinds: Array<String>;

	/** `ControlFlowSupport.blockKinds`: the statement lists a shared `final` can go into. */
	var blockKinds: Array<String>;

	/** The file's writes once a group has asked for them (`writesOf`). */
	var writes: Null<Array<WriteSite>>;
}

/**
 * Occurrences of one group whose operands bind the same declarations: the joined paths, the paths, the group's own
 * access path when it is a chain (`WriteSites.accessPath`), the occurrences by position.
 */
private typedef BindingBucket = {
	var signature: String;
	var paths: Array<String>;
	var own: Null<String>;
	var occ: Array<Candidate>;
}
