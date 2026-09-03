package anyparse.check;

import anyparse.check.AssignmentTreeHoist.LvalueRef;
import anyparse.check.AssignmentTreeHoist.SwitchArms;
import anyparse.check.AssignmentTreeHoist.TreeSeams;
import anyparse.check.AssignmentTreeHoist.UnitValue;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a local declaration followed by a CHAIN of conditional overwrites of that local -- two or
 * more consecutive statement-position `switch`es, each assigning the local on some paths and
 * leaving it alone on the rest -- and collapses the whole run into ONE declaration whose
 * initializer nests them, LAST construct outermost:
 *
 * ```haxe
 * var tKey:String = null;
 * switch strKey.expr {
 *     case EConst(CString(s, _)): tKey = s;
 *     case _:
 * }
 * switch intKey.expr {
 *     case EConst(CInt(i)): tKey = '$i';
 *     case _:
 * }
 * // ->
 * var tKey:String = switch intKey.expr {
 *     case EConst(CInt(i)): '$i';
 *     case _: switch strKey.expr {
 *         case EConst(CString(s, _)): s;
 *         case _: null;
 *     };
 * };
 * ```
 *
 * The MULTI-STATEMENT axis of the assignment-collapse family (`prefer-switch-expression-assignment`,
 * `prefer-if-expression-assignment`, `prefer-try-expression-assignment`, `prefer-ternary-assignment`,
 * `join-declaration-assignment`, `cond-assign-merge`): every one of those collapses ONE construct and
 * refuses this shape, because the target is written by several. `Info`, and `DefaultOff` -- the
 * collapse REVERSES reading order (the last override is read first), which is the honest shape of
 * "later wins" but not every project's taste; opt in with `"join-override-chain": { "enabled": true }`.
 *
 * ## The load-bearing gate is EVALUATION ORDER, not arm shape
 *
 * The merge moves the LAST construct's subject in front of every earlier one, and makes each earlier
 * construct reachable only on the fallback path -- so an earlier subject may not be evaluated at all,
 * and an earlier arm value that used to be computed and then overwritten is now skipped. Everything
 * the run evaluates therefore has to be PURE: the declaration's initializer (it moves from "always"
 * to "innermost fallback only"), every subject, every guard, and every arm value. Purity is
 * `PurityScan` -- index-backed, so a plain field read passes and a resolvable property getter does not
 * -- widened by `pureValue` for one shape it refuses.
 *
 * ## What is flagged
 *
 * Consecutive DIRECT CHILDREN of one statement list (`ControlFlowSupport.blockKinds`), starting at a
 * single-declarator mutable local declaration WITH an initializer, followed by a maximal run of
 * statement-position `switch`es where each:
 *
 *  - spells its no-match path as a completely EMPTY `case _:` / `default:`
 *    (`AssignmentTreeHoist.hasEmptyDefaultArm`). That arm is the seat everything earlier in the run
 *    gets nested into. A construct that writes on EVERY path would make its predecessors dead
 *    instead, which is a `dead-store` finding and not a merge;
 *  - assigns the declared local, and only it, in every non-empty arm -- a hoistable unit
 *    (`AssignmentTreeHoist`): a plain `x = <expr>;` leaf, or RECURSIVELY a nested `switch` /
 *    `if`-chain whose every leaf assigns it. At least one leaf, or the construct writes nothing;
 *  - does not READ the local anywhere (subject, guard, arm value) -- after the collapse that is a
 *    self-reference in the local's own initializer;
 *  - evaluates only pure expressions, per the section above.
 *
 * The run must hold at least TWO constructs: one is `prefer-switch-expression-assignment`'s shape,
 * and this rule deliberately leaves it there. Beyond the run: every write of the local inside the
 * collapsed region must be one of the counted arm leaves (a stray write would change meaning), and
 * a comment in a region the collapse drops fails the site closed.
 *
 * ## The declaration keyword
 *
 * `var` becomes `final` only when the run holds EVERY write of the local. A write that survives
 * AFTER the run is normal for this shape -- it is what makes the single-construct rules refuse it in
 * the first place -- and the declaration then stays `var`, which is what the motivating site
 * (`macros/Lang.hx` in Tactics Manager) needs: its `tKey` is overwritten once more, further down,
 * behind a null test.
 */
@:nullSafety(Strict)
final class JoinOverrideChain implements Check implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'join-override-chain';

	/** The finding message -- reported on the DECLARATION, the statement the whole run collapses into. */
	private static inline final MESSAGE: String =
		'this declaration and the chain of conditional overwrites after it can be one nested switch-expression assignment';

	/** One construct is the single-construct rules' shape; a CHAIN starts at two. */
	private static inline final MIN_CONSTRUCTS: Int = 2;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a local declaration followed by a chain of conditional overwrites of it, collapsible to one nested switch-expression '
			+ 'assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		return [
			for (entry in files) for (m in matches(entry.source, plugin, resolved, index))
				{
					file: entry.file,
					span: m.declSpan,
					rule: RULE_ID,
					severity: Severity.Info,
					message: MESSAGE
				}
		];
	}

	/**
	 * Collapse each flagged run. The match set is re-derived from the re-parsed tree -- with the
	 * caller's report-scoped index when it supplied one -- so a reported span that no longer starts a
	 * collapsible run produces no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final files: Array<{ file: String, source: String }> = [{ file: violations[0].file, source: source }];
		final resolvedIndex: SymbolIndex = index ?? SymbolIndex.build(files, plugin);
		final byKey: Map<String, Match> = [];
		for (m in matches(source, plugin, seams, resolvedIndex)) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;
		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<TreeSeams> = AssignmentTreeHoist.readTreeSeams(shape);
		if (tree == null) return null;
		final resolvedTree: TreeSeams = tree;
		final switchKinds: Null<Array<String>> = resolvedTree.switchKinds;
		if (switchKinds == null || switchKinds.length == 0) return null;
		final mutableKinds: Null<Array<String>> = shape.mutableLocalDeclKinds;
		if (mutableKinds == null || mutableKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			tree: resolvedTree,
			switchKinds: switchKinds,
			mutableKinds: mutableKinds,
			identKind: shape.identKind,
			stringInterpIdentKind: shape.stringInterpIdentKind,
			blockKinds: support.blockKinds(),
			shape: shape
		};
	}

	/** Every collapsible run in `source`, in document order, each with the edit that collapses it. */
	private static function matches(source: String, plugin: GrammarPlugin, s: Seams, index: SymbolIndex): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final purity: Null<PurityCtx> = PurityScan.contextOf(plugin, source, root, index);
		if (purity == null) return [];
		final out: Array<Match> = [];
		collect(root, root, source, RefactorSupport.collectCommentTokens(plugin.lexicalRegions(source)), s, purity, out);
		return out;
	}

	/** Walk every statement list under `node`, trying a run at each position. */
	private static function collect(
		node: QueryNode, root: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		purity: PurityCtx, out: Array<Match>
	): Void {
		if (s.blockKinds.contains(node.kind)) for (i in 0...node.children.length) {
			final m: Null<Match> = matchRun(node.children, i, root, source, comments, s, purity);
			if (m != null) out.push(m);
		}
		for (c in node.children) collect(c, root, source, comments, s, purity, out);
	}

	/**
	 * The collapse match for the run starting at `kids[i]`, or null when that statement is not a
	 * single mutable local declaration with an initializer followed by at least `MIN_CONSTRUCTS`
	 * conditional overwrites of it (see the class doc for every gate).
	 */
	private static function matchRun(
		kids: Array<QueryNode>, i: Int, root: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		purity: PurityCtx
	): Null<Match> {
		final decl: QueryNode = kids[i];
		if (!s.mutableKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		if (RefactorSupport.isMultiDeclarator(decl, s.shape.localDeclContinuationKinds ?? [])) return null; // `var a, b;`
		final init: QueryNode = decl.children[0];
		// The initializer moves from "evaluated always" to "evaluated on the innermost fallback only".
		if (!pureValue(init, s, purity)) return null;
		var fallback: Null<UnitValue> = AssignmentTreeHoist.verbatimUnit(init, source);
		if (fallback == null) return null;

		final ref: LvalueRef = { lvalue: null };
		var leafTotal: Int = 0;
		var last: Null<Span> = null;
		var count: Int = 0;
		while (i + 1 + count < kids.length) {
			final grown: Null<Grown> = grow(kids[i + 1 + count], ref, name, source, s, purity, (fallback: UnitValue));
			if (grown == null) break;
			fallback = grown.unit;
			leafTotal += grown.leafCount;
			last = grown.span;
			count++;
		}
		final region: Null<Span> = last;
		return count < MIN_CONSTRUCTS || region == null
			? null
			: build(name, declSpan, init, new Span(declSpan.from, region.to), (fallback: UnitValue), leafTotal, root, source, comments, s);
	}

	/**
	 * Nest `node` around `fallback` -- the value everything earlier in the run builds -- and hand back
	 * the grown value plus this construct's own leaf-write count. Null when `node` is not a
	 * conditional overwrite of `name`: a statement-position `switch` with an EMPTY default arm, at
	 * least one arm leaf, every arm assigning `name` and nothing else, no read of `name`, and only
	 * pure expressions evaluated.
	 */
	private static function grow(
		node: QueryNode, ref: LvalueRef, name: String, source: String, s: Seams, purity: PurityCtx, fallback: UnitValue
	): Null<Grown> {
		if (!s.switchKinds.contains(node.kind) || node.children.length < MIN_CONSTRUCTS) return null;
		final span: Null<Span> = node.span;
		if (span == null || !AssignmentTreeHoist.hasEmptyDefaultArm(node, s.tree)) return null;
		final sa: Null<SwitchArms> = AssignmentTreeHoist.switchArms(node, ref, source, s.tree, null, fallback);
		if (sa == null || sa.leafCount == 0 || !pureSwitch(node, s, purity)) return null;
		final lvalue: Null<QueryNode> = ref.lvalue;
		if (lvalue == null || lvalue.kind != s.identKind || lvalue.name != name || Refs.readsName(name, node, s.shape)) return null;
		final subjectSrc: Null<String> = AssignmentTreeHoist.slice(source, sa.subject);
		final subjectSpan: Null<Span> = sa.subject.span;
		if (subjectSrc == null || subjectSpan == null) return null;
		final kept: Array<Span> = sa.kept.copy();
		kept.push(subjectSpan);
		// `leafCount: 0` -- the grown value is only ever BORROWED by a later empty default arm, which
		// performs no write of its own; its leaves are already in `leafTotal`.
		return {
			unit: {
				text: 'switch $subjectSrc {${sa.armsText} }',
				kept: kept,
				gaps: sa.gaps,
				atom: null,
				leafCount: 0
			},
			leafCount: sa.leafCount,
			span: span
		};
	}

	/**
	 * Assemble the `<keyword> x:T = <nested value>;` replacement for a run whose constructs all
	 * matched. Null when the local is written inside the region by anything other than the
	 * `leafTotal` counted arm leaves, a span is missing, or a comment sits in a dropped region.
	 */
	private static function build(
		name: String, declSpan: Span, init: QueryNode, region: Span, value: UnitValue, leafTotal: Int, root: QueryNode, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final writes: Array<Span> = [for (h in Refs.find(name, root, s.shape)) if (h.kind == RefKind.Write) h.span];
		var inside: Int = 0;
		for (w in writes) if (w.from >= region.from && w.from < region.to) inside++;
		if (inside != leafTotal) return null;
		// A write that OUTLIVES the run keeps the local mutable -- the shape the single-construct
		// rules refuse, and the one the motivating site has.
		final prefix: Null<{ text: String, keptTo: Int }> = AssignmentTreeHoist.declPrefix(
			declSpan, init, source, writes.length == leafTotal ? 'final' : null
		);
		if (prefix == null) return null;
		final kept: Array<Span> = value.kept.copy();
		kept.push(new Span(declSpan.from, prefix.keptTo));
		return IfExpressionChain.droppedComment(region, kept, comments) ? null : {
			declSpan: declSpan,
			editSpan: region,
			text: '${prefix.text} = ${value.text};'
		};
	}

	/**
	 * Whether every expression a switch EVALUATES is pure -- its subject, each arm's guard, and each
	 * arm body's own evaluated expressions. Case PATTERNS are skipped: they are matched, not
	 * evaluated, and a constructor pattern would read as a call.
	 */
	private static function pureSwitch(switchNode: QueryNode, s: Seams, purity: PurityCtx): Bool {
		if (!pureValue(switchNode.children[0], s, purity)) return false;
		for (i in 1...switchNode.children.length) {
			final branch: QueryNode = switchNode.children[i];
			final guard: Null<QueryNode> = AssignmentTreeHoist.caseGuard(branch, s.tree);
			if (guard != null && !pureValue(guard, s, purity)) return false;
			final body: Null<QueryNode> = AssignmentTreeHoist.armBody(branch, s.tree);
			if (body != null && !pureUnit(body, s, purity)) return false;
		}
		return true;
	}

	/**
	 * Whether every expression a hoistable-unit statement EVALUATES is pure: a leaf's r-value, or
	 * RECURSIVELY a nested switch / `if`-chain's subjects, conditions and leaf values. The leaf
	 * L-VALUE is skipped -- it is the run's target, a plain local the caller has already checked.
	 * Anything that is not a hoistable unit is refused; `switchArms` has already accepted the shape
	 * by the time this runs, so that arm is unreachable for a matched construct and stays as the
	 * fail-closed answer for anything else.
	 */
	private static function pureUnit(stmt: QueryNode, s: Seams, purity: PurityCtx): Bool {
		final assign: Null<QueryNode> = AssignmentTreeHoist.plainAssign(stmt, s.tree);
		if (assign != null) return pureValue(assign.children[1], s, purity);
		final inner: QueryNode = stmt.kind == s.tree.blockStmtKind && stmt.children.length == 1 ? stmt.children[0] : stmt;
		if (s.switchKinds.contains(inner.kind)) return pureSwitch(inner, s, purity);
		final ifKinds: Null<Array<String>> = s.tree.ifKinds;
		if (ifKinds == null || !ifKinds.contains(inner.kind)) return false;
		for (i in 0...inner.children.length) if (!(
			i == 0 ? pureValue(inner.children[0], s, purity) : pureUnit(inner.children[i], s, purity)
		))
			return false;
		return true;
	}

	/**
	 * Whether an evaluated expression is provably side-effect-free: `PurityScan.isPure` widened by ONE
	 * shape, a BARE `$name` interpolation hole (`stringInterpIdentKind`). That leaf is a plain
	 * variable read spelled inside a string, but its kind is neither `identKind` nor a
	 * `RefactorSupport.isSafeKind` member, so BOTH shared purity predicates refuse the whole literal --
	 * and an interpolated key is exactly what the motivating site's arms assign. The widening is
	 * caller-local for the reason `UnnecessarySwitch.droppable`'s is: the safe direction differs per
	 * caller. It is not free -- `Std.string` of an object can run a user `toString()` -- but the value
	 * this rule may skip is one the original code computed and then overwrote unread.
	 *
	 * A `${…}` hole is an arbitrary expression, projects as a different kind, and stays refused.
	 */
	private static function pureValue(node: QueryNode, s: Seams, purity: PurityCtx): Bool {
		return node.kind == s.stringInterpIdentKind || (
			node.kind == s.identKind || !RefactorSupport.isSafeKind(node.kind)
				? PurityScan.isPure(node, purity)
				: node.children.foreach(c -> pureValue(c, s, purity))
		);
	}

}

/** The AST kinds and control-flow support `join-override-chain` reads. */
typedef Seams = {
	var tree: TreeSeams;
	var switchKinds: Array<String>;
	var mutableKinds: Array<String>;
	var identKind: String;
	var stringInterpIdentKind: Null<String>;
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** One collapsible run: the declaration span the finding is reported on, the region the edit replaces, and its text. */
typedef Match = {
	var declSpan: Span;
	var editSpan: Span;
	var text: String;
}

/** One construct nested onto the run so far: the grown value, that construct's own leaf-write count, and its span. */
typedef Grown = {
	var unit: UnitValue;
	var leafCount: Int;
	var span: Span;
}
