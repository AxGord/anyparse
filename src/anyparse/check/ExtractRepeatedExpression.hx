package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a NON-TRIVIAL, PURE value expression that appears three or more times,
 * literally identical (up to whitespace), within ONE function body — a candidate
 * for a `final x = <expr>;` extraction so the value is computed once and reused.
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
 *   (`SymbolIndex.memberGetter`, via `TypeResolver`) is treated as impure. This
 *   keeps "compute once, reuse" behaviour-preserving: only referentially
 *   transparent expressions are suggested.
 * - **Repeated three or more times** (`MIN_OCCURRENCES`) inside the SAME function
 *   body — a nested function / lambda is a separate body (its expressions never
 *   fold into the enclosing one), and a `MacroExpr` reification subtree is skipped
 *   (its identifiers may be spliced from elsewhere).
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
 * - **Subsumed sub-expressions.** A repeated sub-expression whose every occurrence
 *   nests inside an occurrence of an equally- or more-frequent larger repeated
 *   expression is dropped, so a chain reports at its maximal form (`a.b.c()` once,
 *   not also `a.b.c` and `a.b`) — unless the shorter form also recurs on its own.
 *
 * ## Grammar-agnostic
 *
 * Everything is driven off `RefShape`: a grammar without a field-access or call
 * kind makes the check a no-op. The finding is spanned at the earliest occurrence.
 */
@:nullSafety(Strict)
final class ExtractRepeatedExpression implements Check {

	/** The least number of identical occurrences within one body to report. */
	private static inline final MIN_OCCURRENCES: Int = 3;

	/** The shortest field-access chain (`a.b` = 1, `a.b.c` = 2) that counts as non-trivial without a call. */
	private static inline final MIN_CHAIN_DEPTH: Int = 2;

	/** The longest normalized expression text shown in a message before truncation. */
	private static inline final MAX_MSG_EXPR: Int = 60;

	private static inline final RULE_ID: String = 'extract-repeated-expression';

	/**
	 * Simple receiver names whose static methods are pure (referentially
	 * transparent) stdlib operations — so a call on one is safe to compute once.
	 * The non-deterministic `random` member is rejected separately.
	 */
	private static final PURE_CALL_RECEIVERS: Array<String> = ['Math', 'Std', 'StringTools'];

	/** Members on a `PURE_CALL_RECEIVERS` receiver that are NOT pure (non-deterministic). */
	private static final IMPURE_MEMBERS: Array<String> = ['random'];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a non-trivial pure expression repeated three or more times in one function body — a candidate for a final local';
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
		final functionUnitKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []);
		final exclusiveConditionalKinds: Array<String> = (shape.branchConditionKinds ?? []).concat(shape.switchKinds ?? []);
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(entry.source) : new Map<Int, String>();
			final ctx: Ctx = {
				shape: shape,
				identKind: shape.identKind,
				fieldAccessKind: faK,
				callKind: callK,
				indexAccessKind: indexKind,
				candidateKinds: candidateKinds,
				functionUnitKinds: functionUnitKinds,
				exclusiveConditionalKinds: exclusiveConditionalKinds,
				opaqueKinds: shape.opaqueKinds ?? [],
				selfReferenceText: shape.selfReferenceText,
				declaredTypes: declaredTypes,
				index: index,
				root: root
			};
			final units: Array<QueryNode> = [];
			collectUnits(root, functionUnitKinds, units);
			for (unit in units) analyzeUnit(violations, entry.file, entry.source, unit, ctx);
		}
		return violations;
	}

	/** No mechanical edit — extraction (and where the `final` belongs) is an author decision. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
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
		for (norm => occ in groups) {
			if (occ.length < MIN_OCCURRENCES) continue;
			final rep: QueryNode = occ[0].node;
			if (!isNonTrivial(rep, ctx)) continue;
			if (!isPureExpr(rep, ctx)) continue;
			if (allPairsExclusive(occ)) continue;
			occ.sort((a, b) -> a.span.from - b.span.from);
			kept.push({ norm: norm, occ: occ });
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
	 * candidate records which mutually-exclusive branches it lives in.
	 */
	private static function collect(
		node: QueryNode, source: String, ctx: Ctx, path: Array<BranchStep>, out: Array<Candidate>, isRoot: Bool
	): Void {
		if (!isRoot && (ctx.functionUnitKinds.contains(node.kind) || ctx.opaqueKinds.contains(node.kind))) return;
		final span: Null<Span> = node.span;
		if (!isRoot && span != null && ctx.candidateKinds.contains(node.kind)) {
			final s: Span = span;
			out.push({
				node: node,
				span: s,
				norm: normalize(source, s),
				path: path.copy()
			});
		}
		final isConditional: Bool = span != null && ctx.exclusiveConditionalKinds.contains(node.kind);
		for (i in 0...node.children.length) {
			final child: QueryNode = node.children[i];
			if (isConditional && i >= 1 && span != null) {
				path.push({ key: '${span.from}:${span.to}', idx: i });
				collect(child, source, ctx, path, out, false);
				path.pop();
			} else {
				collect(child, source, ctx, path, out, false);
			}
		}
	}

	/** At least one call, or a field-access chain of depth `MIN_CHAIN_DEPTH` — a bare read is trivial. */
	private static function isNonTrivial(node: QueryNode, ctx: Ctx): Bool {
		return RefactorSupport.subtreeContainsKind(node, ctx.callKind) || maxFieldChainDepth(node, ctx.fieldAccessKind) >= MIN_CHAIN_DEPTH;
	}

	/** The deepest run of consecutive field accesses anywhere in `node`'s subtree (`a.b.c` = 2). */
	private static function maxFieldChainDepth(node: QueryNode, faKind: String): Int {
		var best: Int = 0;
		function chainLen(n: QueryNode): Int {
			return (n.kind == faKind && n.children.length >= 1) ? 1 + chainLen(n.children[0]) : 0;
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

	/**
	 * Whether every node in `node`'s subtree is side-effect-free: a safe skeleton
	 * kind (`RefactorSupport.isSafeKind`), a field / index READ, or a provably-pure
	 * stdlib call. A field read whose resolvable first hop is a property getter, and
	 * any non-whitelisted call, make it impure.
	 */
	private static function isPureExpr(node: QueryNode, ctx: Ctx): Bool {
		final k: String = node.kind;
		if (RefactorSupport.isSafeKind(k)) return node.children.foreach(c -> isPureExpr(c, ctx));
		if (k == ctx.fieldAccessKind) {
			if (isSideEffectingGetter(node, ctx)) return false;
			return node.children.foreach(c -> isPureExpr(c, ctx));
		}
		if (ctx.indexAccessKind != null && k == ctx.indexAccessKind) return node.children.foreach(c -> isPureExpr(c, ctx));
		if (k == ctx.callKind) return isPureCall(node, ctx) && node.children.foreach(c -> isPureExpr(c, ctx));
		return false;
	}

	/**
	 * Whether a `callKind` node is a provably-pure stdlib call — its callee is a
	 * `Recv.method` field access where `Recv` is a bare identifier in
	 * `PURE_CALL_RECEIVERS` and `method` is not an `IMPURE_MEMBERS` name. Any other
	 * callee (an instance method, a local function, a complex receiver) is unproven
	 * and therefore impure.
	 */
	private static function isPureCall(call: QueryNode, ctx: Ctx): Bool {
		if (call.children.length < 1) return false;
		final callee: QueryNode = call.children[0];
		if (callee.kind != ctx.fieldAccessKind || callee.children.length != 1) return false;
		final method: Null<String> = callee.name;
		if (method == null || IMPURE_MEMBERS.contains(method)) return false;
		final recv: QueryNode = callee.children[0];
		return recv.kind == ctx.identKind && recv.name != null && PURE_CALL_RECEIVERS.contains(recv.name);
	}

	/**
	 * Whether a `fieldAccessKind` node reads a member proven to be a property GETTER
	 * — resolvable only when the receiver is a bare identifier (its declared type) or
	 * `this` (the enclosing type); a deeper receiver is left unresolved (assumed a
	 * plain read). Reuses `SymbolIndex.memberGetter` (the getter-property map).
	 */
	private static function isSideEffectingGetter(fa: QueryNode, ctx: Ctx): Bool {
		final field: Null<String> = fa.name;
		if (field == null || fa.children.length != 1) return false;
		final recv: QueryNode = fa.children[0];
		if (recv.kind != ctx.identKind) return false;
		final recvName: Null<String> = recv.name;
		if (recvName == null) return false;
		final typeName: Null<String> = if (recvName == ctx.selfReferenceText) {
			final span: Null<Span> = fa.span;
			span == null ? null : TypeResolver.enclosingTypeName(ctx.root, span);
		} else {
			TypeResolver.identTypeName(recv, ctx.root, ctx.shape, ctx.declaredTypes);
		}
		return typeName != null && ctx.index.memberGetter(typeName, field) == true;
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

	/** Drop a group whose every occurrence nests inside an equally- or more-frequent larger group's occurrence. */
	private static function dropSubsumed(groups: Array<Group>): Array<Group> {
		return [for (g in groups) if (!isSubsumed(g, groups)) g];
	}

	/** Whether every occurrence of `g` is strictly contained in some occurrence of a distinct group at least as frequent. */
	private static function isSubsumed(g: Group, groups: Array<Group>): Bool {
		for (h in groups) {
			if (h.norm == g.norm || h.occ.length < g.occ.length) continue;
			if (g.occ.foreach(go -> h.occ.exists(ho -> strictlyContains(ho.span, go.span)))) return true;
		}
		return false;
	}

	/** Whether `outer` strictly contains `inner` (covers it and is not the identical span). */
	private static function strictlyContains(outer: Span, inner: Span): Bool {
		return outer.from <= inner.from && inner.to <= outer.to && (outer.from < inner.from || inner.to < outer.to);
	}

	/** The finding message: occurrence count plus the truncated normalized expression. */
	private static function buildMessage(g: Group): String {
		final text: String = g.norm.length > MAX_MSG_EXPR ? g.norm.substr(0, MAX_MSG_EXPR) + '...' : g.norm;
		return
			'the expression `${text}` is repeated ${g.occ.length} times in one function body — extract into a `final` local (report-only)';
	}

	/** `source[span]` with every run of whitespace collapsed to a single space and the ends trimmed. */
	private static function normalize(source: String, span: Span): String {
		final buf: StringBuf = new StringBuf();
		var nonWs: Int = 0;
		var pendingSpace: Bool = false;
		for (i in span.from ... span.to) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				pendingSpace = true;
			} else {
				if (pendingSpace && nonWs > 0) buf.addChar(' '.code);
				pendingSpace = false;
				buf.addChar(c);
				nonWs++;
			}
		}
		return buf.toString();
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

/** A repeated-expression group: the shared normalized text and its occurrences (earliest first). */
private typedef Group = {
	var norm: String;
	var occ: Array<Candidate>;
}

/** Per-file resolved constants threaded through the recursive walk. */
private typedef Ctx = {
	var shape: RefShape;
	var identKind: String;
	var fieldAccessKind: String;
	var callKind: String;
	var indexAccessKind: Null<String>;
	var candidateKinds: Array<String>;
	var functionUnitKinds: Array<String>;
	var exclusiveConditionalKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var selfReferenceText: Null<String>;
	var declaredTypes: Map<Int, String>;
	var index: SymbolIndex;
	var root: QueryNode;
}
