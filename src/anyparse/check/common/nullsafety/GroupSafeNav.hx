package anyparse.check.common.nullsafety;

import anyparse.check.Check.FixEdit;
import anyparse.query.DeclaredNullity;
import anyparse.query.SymbolIndex;
import anyparse.query.TailValueScan;
import anyparse.query.TypeInfoProvider;
import anyparse.query.UnchangedLocal;

/**
 * Flags two or more CONSECUTIVE statements that each null-safe-navigate the same local — `r?.a(); r?.b();` — and
 * rewrites them under one guard, `if (r != null) { r.a(); r.b(); }`: one test where the reader saw several, and a
 * body that reads `r` as the non-null value it is there. A single `r?.` stays as it is (`prefer-safe-nav`'s form);
 * `Severity.Info`.
 *
 * A statement joins a run when it is an expression statement whose whole expression is an access chain (member,
 * call, index steps) rooted at `r?.`: when `r` is null such a statement does nothing, the arguments included, which
 * is exactly what the guard skips. Only the root `?.` becomes `.`; a later one stays the author's.
 *
 * ## Soundness — `r` holds one value across the run
 *
 * Each `r?.` reads `r` anew, the guard once, so `r` must be a local or a parameter no write can change while the run
 * executes (`UnchangedLocal`): no write in the run itself, and none in a function literal or local function that does
 * not declare `r` — a callback the run calls may be one. A run ending a block whose value is used (`TailValueScan`)
 * is that value and is left alone. A field is refused: any call of the run may change it. A receiver already proven
 * non-null (`TypeResolver.isProvablyNonNullAtNullComparison`) is `unnecessary-safe-nav`'s, whose fix drops the `?`,
 * and the guard would be `unnecessary-null-check`'s next finding. A comment between `r` and its `?.` refuses the
 * run. Not read: on an abstract overloading `!=` the guard calls the overload, where `?.` tests the raw null.
 *
 * ## Grammar-agnostic
 *
 * Driven by `nullSafeAccessKind`, `exprStatementKind`, `fieldAccessKind`, `callKind` (any unset → no-op), plus
 * `indexAccessKind` for an index step, `ControlFlowSupport.blockKinds` for the statement lists, `localDeclKinds` /
 * `localDeclContinuationKinds` / `paramKinds` for the binding and `opaqueKinds` to skip reification.
 */
@:nullSafety(Strict)
final class GroupSafeNav extends RuleBase {

	private static inline final RULE_ID: String = 'group-safe-nav';

	/** The source spelling of a null-safe access, whose `?` the rewrite drops at the root of each statement. */
	private static inline final SAFE_NAV: String = '?.';

	public function new() {
		super(
			RULE_ID, 'consecutive statements null-safe-navigating one local (r?.a(); r?.b();), groupable under if (r != null)',
			RuleCategory.NullSafety
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			final runs: Array<SafeNavRun> = [];
			collectRuns(tree, entry.source, seams, runs);
			if (runs.length == 0) return;
			final shape: RefShape = seams.shape;
			final types: DeclaredNullity = DeclaredNullity.of(entry.file, tree, entry.source, shape, typed, plugin.typeSyntax, index);
			final proof: UnchangedLocal = new UnchangedLocal(tree, shape);
			for (r in runs) {
				final head: QueryNode = r.roots[0];
				if (TypeResolver.isProvablyNonNullAtNullComparison(head, tree, shape, types) || !proof.holds(head, r.span)) continue;
				violations.push({
					file: entry.file,
					span: r.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: messageOf(r)
				});
			}
		});
	}

	/** Rewrite each flagged run to `if (r != null) { … }`, the root `?.` of each statement turned into `.`. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyTextMatches(plugin, source, violations, (tree, text) -> {
				final runs: Array<SafeNavRun> = [];
				collectRuns(tree, text, seams, runs);
				return [for (r in runs) { span: r.span, text: guarded(r, text) }];
			});
	}

	private static function messageOf(run: SafeNavRun): String {
		final name: String = run.name;
		return '${run.roots.length} consecutive statements null-safe-navigate $name — one if ($name != null) can guard them';
	}

	/** `if (r != null) { … }` over the run's text, each root `?.` turned into `.`. */
	private static function guarded(run: SafeNavRun, source: String): String {
		final parts: Array<String> = [];
		var at: Int = run.span.from;
		for (root in run.roots) {
			final dot: Int = root.span?.to ?? at;
			parts.push(source.substring(at, dot));
			at = dot + 1;
		}
		parts.push(source.substring(at, run.span.to));
		return 'if (${run.name} != null) {\n${parts.join('')}\n}';
	}

	/**
	 * Every maximal run of two or more consecutive statements of a statement list rooted at `<name>?.` with the same
	 * `name`, in document order. A run that ends a list whose value may be used
	 * (`TailValueScan`) is left out: it is that value, and the guard would make it `Void`.
	 */
	private static function collectRuns(node: QueryNode, source: String, s: Seams, out: Array<SafeNavRun>): Void {
		TailValueScan.walk(node, s.shape, s.blockKinds, (list, tailUsed) -> {
			final kids: Array<QueryNode> = list.children;
			var i: Int = 0;
			while (i < kids.length) {
				final roots: Array<QueryNode> = [];
				var root: Null<QueryNode> = safeRoot(kids[i], source, s);
				final name: Null<String> = root?.name;
				while (root != null && root.name == name) {
					roots.push(root);
					root = i + roots.length < kids.length ? safeRoot(kids[i + roots.length], source, s) : null;
				}
				final last: Int = i + roots.length - 1;
				final from: Null<Int> = kids[i].span?.from;
				// A run ending a list whose value is used is that value; the guard would make it Void.
				final to: Null<Int> = roots.length < 2 || (tailUsed && last == kids.length - 1) ? null : kids[last].span?.to;
				final runName: String = name ?? '';
				if (from != null && to != null && name != null) out.push({ name: runName, span: new Span(from, to), roots: roots });
				i += roots.length < 1 ? 1 : roots.length;
			}
		});
	}

	/**
	 * The identifier `stmt` null-safe-navigates at its root, when `stmt` is an expression statement whose expression is
	 * an access chain down to `<ident>?.` written with no gap before the `?.`; else null.
	 */
	private static function safeRoot(stmt: QueryNode, source: String, s: Seams): Null<QueryNode> {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		var node: QueryNode = stmt.children[0];
		while (s.chainKinds.contains(node.kind) && node.children.length >= 1) {
			final receiver: QueryNode = node.children[0];
			if (receiver.kind == s.identKind) {
				final end: Null<Int> = receiver.span?.to;
				return node.kind == s.safeNavKind && end != null && source.substr(end, SAFE_NAV.length) == SAFE_NAV ? receiver : null;
			}
			node = receiver;
		}
		return null;
	}

	/** The seams the rule reads, or null when one it cannot do without is unset. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final safeNavKind: Null<String> = shape.nullSafeAccessKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final callKind: Null<String> = shape.callKind;
		if (safeNavKind == null || exprStmtKind == null || fieldAccessKind == null || callKind == null) return null;
		final chainKinds: Array<String> = [safeNavKind, fieldAccessKind, callKind];
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		if (indexAccessKind != null) chainKinds.push(indexAccessKind);
		return {
			shape: shape,
			safeNavKind: safeNavKind,
			exprStmtKind: exprStmtKind,
			identKind: shape.identKind,
			chainKinds: chainKinds,
			blockKinds: plugin.controlFlowSupport()?.blockKinds() ?? [],
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

}

/** A maximal run: the receiver's name, the span from the first statement to the last, and each statement's root identifier. */
private typedef SafeNavRun = {
	final name: String;
	final span: Span;
	final roots: Array<QueryNode>;
};

/** The resolved seams `GroupSafeNav` reads in both `run` and `fix`. */
private typedef Seams = {
	final shape: RefShape;
	final safeNavKind: String;
	final exprStmtKind: String;
	final identKind: String;
	final chainKinds: Array<String>;
	final blockKinds: Array<String>;
	final opaqueKinds: Array<String>;
};
