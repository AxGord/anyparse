package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.scan.PurityScan;
import anyparse.query.IndexScope;
import anyparse.query.ParseGate;
import anyparse.query.Refs;
import anyparse.query.SameValueRuns;
import anyparse.query.ShapeVocab;
import anyparse.query.StdTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeResolver;
import anyparse.query.UnchangedLocal;
import anyparse.query.WriteSites;

using StringTools;

/**
 * Flags a local or parameter cast to one type several times in one function body, and binds the cast once:
 * `cast(o, Bubble).color = c; cast(o, Bubble).redraw();` becomes `final bubble: Bubble = cast(o, Bubble);
 * bubble.color = c; bubble.redraw();`. It is the cast counterpart of `extract-repeated-expression`, which never
 * counts a cast (a checked cast is not pure: it throws) and is report-only.
 *
 * ## The family
 *
 * - **Checked** (`cast(x, T)`) and **unchecked** (`(cast x : T)`, `(x : T)`) casts are counted apart and never merged:
 *   the checked one carries a runtime check. Thresholds are `minChecked` (default 2: each repeat is a runtime check)
 *   and `minUnchecked` (default 3), read from this rule's options.
 * - **Same value.** The operand is a local or parameter (`UnchangedLocal`), the same binding in every occurrence,
 *   with no write between the first and the last on any path (`SameValueRuns`): a write cuts the run where it
 * takes effect, and a run a loop carries a write into is no run.
 *
 * ## The fix
 *
 * The `final` goes before the statement holding the first occurrence, in the innermost block holding them all, and
 * only when that occurrence runs first and always in that statement (`runsFirst`), so binding it moves nothing — never above a
 * guard that makes the cast valid, a loop, a `try`, or code that does anything. Otherwise the finding stays report-only: so it does
 * when the type suggests no value name (`StdTypes.valueNameOf`). The name is suffixed when any name in the file already uses it.
 */
@:nullSafety(Strict)
final class RepeatedCast extends RuleBase implements ConfigAware implements VolatileMessage {

	private static inline final RULE_ID: String = 'repeated-cast';
	private static inline final DEFAULT_MIN_CHECKED: Int = 2;
	private static inline final DEFAULT_MIN_UNCHECKED: Int = 3;

	/** The tail after the occurrence tally, shared by the builder and `messageIdentity`. */
	private static inline final REPEAT_TAIL: String = ' times in one function body';

	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'the same value cast to the same type several times in one function body', RuleCategory.Design);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskBefore(message, REPEAT_TAIL);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collect(files, plugin, (entry, root, violations) -> {
			for (f in analyze(entry.file, entry.source, root, plugin, symbols)) violations.push({
				file: entry.file,
				span: f.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: f.message
			});
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		if (violations.length == 0) return [];
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		final out: Array<FixEdit> = [];
		for (f in analyze(file, source, tree, plugin, symbols)) {
			final at: Span = f.span;
			if (violations.exists(v -> v.span != null && v.span.from == at.from)) for (e in f.edits) out.push(e);
		}
		return out;
	}

	private function analyze(
		file: String, source: String, tree: QueryNode, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Array<Finding> {
		final shape: RefShape = plugin.refShape();
		final out: Array<Finding> = [];
		if (shape.checkedCastKind == null && shape.checkTypeKind == null) return out;
		final cfg: LintConfig = LintConfig.resolveWith(_resolveConfig, file);
		final declKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.mutableLocalDeclKinds ?? []);
		var purity: Null<PurityCtx> = null;
		var purityRead: Bool = false;
		final scan: Scan = {
			source: source,
			tree: tree,
			shape: shape,
			locals: new UnchangedLocal(tree, shape),
			units: ShapeVocab.functionLikeKinds(shape),
			blockKinds: plugin.controlFlowSupport()?.blockKinds() ?? [],
			loopKinds: ShapeVocab.loopKinds(shape),
			inOrderKinds: declKinds.concat([
				for (k in [
					shape.exprStatementKind,
					shape.returnStatementKind,
					shape.assignKind,
					shape.fieldAccessKind,
					shape.callKind,
					shape.indexAccessKind,
					shape.parenKind,
					shape.checkedCastKind,
					shape.checkTypeKind,
					shape.uncheckedCastKind
				]) if (k != null) k
			]),
			conditionKinds: (shape.branchConditionKinds ?? []).concat(shape.switchKinds ?? []),
			castTargets: TypeInfoMemo.castTargetSources(RunScan.typeInfoOf(plugin), source),
			purity: () -> {
				if (!purityRead) {
					purityRead = true;
					final index: Null<SymbolIndex> = symbols();
					purity = index == null ? null : PurityScan.contextOf(plugin, source, tree, index);
				}
				return purity;
			},
			taken: namesIn(tree),
			minChecked: cfg.intOption(RULE_ID, 'minChecked') ?? DEFAULT_MIN_CHECKED,
			minUnchecked: cfg.intOption(RULE_ID, 'minUnchecked') ?? DEFAULT_MIN_UNCHECKED
		};
		scanUnits(tree, scan, out);
		return out;
	}

	private function scanUnits(node: QueryNode, scan: Scan, out: Array<Finding>): Void {
		if (scan.units.contains(node.kind)) {
			final casts: Array<Cast> = [];
			for (c in node.children) collect(c, scan, casts);
			report(node, casts, scan, out);
		}
		for (c in node.children) scanUnits(c, scan, out);
	}

	/** Every cast of a local in `node`, not descending into a nested function (a unit of its own). */
	private function collect(node: QueryNode, scan: Scan, out: Array<Cast>): Void {
		if (scan.units.contains(node.kind)) return;
		final found: Null<Cast> = castOf(node, scan);
		if (found != null) out.push(found);
		for (c in node.children) collect(c, scan, out);
	}

	private function castOf(node: QueryNode, scan: Scan): Null<Cast> {
		final shape: RefShape = scan.shape;
		final span: Null<Span> = node.span;
		if (span == null || node.children.length != 1) return null;
		final checked: Bool = node.kind == shape.checkedCastKind;
		if (!checked && node.kind != shape.checkTypeKind) return null;
		var operand: QueryNode = node.children[0];
		if (!checked && operand.kind == shape.uncheckedCastKind && operand.children.length == 1) operand = operand.children[0];
		final name: Null<String> = operand.name;
		final at: Null<Span> = operand.span;
		if (operand.kind != shape.identKind || name == null || at == null) return null;
		if (name == shape.selfReferenceText || !scan.locals.survivesCalls(operand)) return null;
		final typeText: Null<String> = TypeResolver.castTargetWithin(span, scan.castTargets());
		if (typeText == null) return null;
		final binding: Null<Int> = Refs.bindingAt(name, at.from, scan.tree, shape);
		return binding == null ? null : {
			node: node,
			span: span,
			operand: operand,
			checked: checked,
			binding: binding,
			typeText: typeText
		};
	}

	private function report(unit: QueryNode, casts: Array<Cast>, scan: Scan, out: Array<Finding>): Void {
		final groups: Array<Array<Cast>> = [];
		final byKey: Map<String, Array<Cast>> = [];
		for (c in casts) {
			final family: String = c.checked ? 'C' : 'U';
			final key: String = '$family|${c.binding}|${c.typeText.replace(' ', '')}';
			final bucket: Null<Array<Cast>> = byKey[key];
			if (bucket == null) {
				final fresh: Array<Cast> = [c];
				byKey[key] = fresh;
				groups.push(fresh);
			} else {
				bucket.push(c);
			}
		}
		for (group in groups) {
			group.sort((a, b) -> a.span.from - b.span.from);
			for (run in runsOf(unit, group, scan)) {
				final least: Int = run[0].checked ? scan.minChecked : scan.minUnchecked;
				if (run.length >= least) out.push(finding(unit, run, scan));
			}
		}
	}

	/**
	 * The occurrences of one operand and type split where a write of the operand takes effect, without the runs a loop
	 * carries such a write into; a write below the operand (`o.field = v`) keeps it.
	 */
	private function runsOf(unit: QueryNode, group: Array<Cast>, scan: Scan): Array<Array<Cast>> {
		final key: Null<String> = WriteSites.accessPath(group[0].operand, scan.tree, scan.shape);
		if (key == null) return [];
		final operand: String = key;
		final writes: Array<WriteSite> = scan.locals.writes.filter(w -> {
			final written: Null<String> = w.path;
			return written == null || WriteSites.mayOverlap(written, operand, true);
		});
		return SameValueRuns.splitAtWrites(group, writes)
			.filter(run -> !SameValueRuns.carriedRound(run, writes, unit, scan.blockKinds, scan.loopKinds));
	}

	private function finding(unit: QueryNode, run: Array<Cast>, scan: Scan): Finding {
		final first: Cast = run[0];
		final span: Span = first.span;
		final operand: String = first.operand.name ?? '';
		final message: String = '`${scan.source.substring(span.from, span.to)}` — $operand cast to ${first.typeText} is evaluated '
			+ '${run.length}$REPEAT_TAIL; bind it once to a final local';
		return { span: span, message: message, edits: edits(unit, run, scan) };
	}

	private function edits(unit: QueryNode, run: Array<Cast>, scan: Scan): Array<FixEdit> {
		final first: Cast = run[0];
		final statement: Null<QueryNode> = hoistStatement(unit, run, scan);
		final at: Null<Span> = statement?.span;
		if (statement == null || at == null) return [];
		final name: Null<String> = freshName(first.typeText, scan);
		if (name == null) return [];
		final lineStart: Int = scan.source.lastIndexOf('\n', at.from - 1) + 1;
		final lead: String = scan.source.substring(lineStart, at.from);
		final glue: String = lead.trim().length == 0 ? '\n$lead' : ' ';
		final text: String = 'final $name: ${first.typeText} = ${scan.source.substring(first.span.from, first.span.to)};$glue';
		final out: Array<FixEdit> = [];
		for (c in run) {
			final head: String = c == first && at.from == c.span.from ? text : '';
			out.push({ span: c.span, text: head + name });
		}
		if (at.from != first.span.from) out.push({ span: new Span(at.from, at.from), text: text });
		return out;
	}

	/**
	 * The statement of the innermost block holding every occurrence that holds the first one, when each node from it down to
	 * the first occurrence runs that occurrence first and always (`runsFirst`); else null.
	 */
	private function hoistStatement(unit: QueryNode, run: Array<Cast>, scan: Scan): Null<QueryNode> {
		final home: Null<QueryNode> = SameValueRuns.hoistBlock(run, unit, scan.blockKinds);
		final purity: Null<PurityCtx> = scan.purity();
		if (home == null || purity == null) return null;
		final path: Array<QueryNode> = TreePath.ancestorsAt(unit, run[0].span.from);
		var at: Int = path.indexOf(home) + 1;
		if (at == 0 || at >= path.length) return null;
		final statement: QueryNode = path[at];
		if (declaresOperand(statement, run[0])) return null;
		while (path[at] != run[0].node) {
			if (at + 1 >= path.length || !runsFirst(path[at], path[at + 1], scan, purity)) return null;
			at++;
		}
		return statement;
	}

	/**
	 * Whether `parent` runs `child` first and always, so nothing it does moves when `child`'s cast goes ahead of it: an
	 * in-order node, or a branching statement through its condition slot, with nothing but pure code before `child`. A loop
	 * or a `try` has no such slot: a loop re-evaluates its condition, a `try` catches what the cast throws.
	 */
	private function runsFirst(parent: QueryNode, child: QueryNode, scan: Scan, purity: PurityCtx): Bool {
		if (!scan.inOrderKinds.contains(parent.kind) && !(scan.conditionKinds.contains(parent.kind) && parent.children[0] == child))
			return false;
		for (sibling in parent.children) {
			if (sibling == child) return true;
			if (!PurityScan.isPure(sibling, purity)) return false;
		}
		return false;
	}

	/** The value name the written type suggests, suffixed until no name in the file has it; null when it suggests none. */
	private function freshName(typeText: String, scan: Scan): Null<String> {
		final stem: Null<String> = StdTypes.valueNameOf(typeText);
		if (stem == null || (scan.shape.reservedWords ?? []).contains(stem)) return null;
		var name: String = stem;
		var n: Int = 2;
		while (scan.taken.exists(name)) {
			name = stem + n;
			n++;
		}
		scan.taken[name] = true;
		return name;
	}

	/**
	 * Whether `occurrence`'s operand is declared inside `statement` (`var o = other, y = cast(o, B).n;`): a local put ahead
	 * of it would read whatever that name means there, an outer binding or nothing.
	 */
	private static function declaresOperand(statement: QueryNode, occurrence: Cast): Bool {
		final at: Null<Span> = statement.span;
		return at != null && at.from <= occurrence.binding && occurrence.binding < at.to;
	}

	private static function namesIn(node: QueryNode): Map<String, Bool> {
		final out: Map<String, Bool> = [];
		function walk(n: QueryNode): Void {
			final name: Null<String> = n.name;
			if (name != null) out[name] = true;
			for (c in n.children) walk(c);
		}
		walk(node);
		return out;
	}

}

private typedef Cast = {
	final node: QueryNode;
	final span: Span;
	final operand: QueryNode;
	final checked: Bool;
	final binding: Int;
	final typeText: String;
}

private typedef Finding = {
	final span: Span;
	final message: String;
	final edits: Array<FixEdit>;
}

private typedef Scan = {
	final source: String;
	final tree: QueryNode;
	final shape: RefShape;
	final locals: UnchangedLocal;
	final units: Array<String>;
	final blockKinds: Array<String>;
	final loopKinds: Array<String>;

	/** The nodes that evaluate every child, in order: a statement or expression with no branch in it. */
	final inOrderKinds: Array<String>;

	/** The statements whose first child is the condition or subject they always evaluate first. */
	final conditionKinds: Array<String>;
	final castTargets: () -> Map<Int, String>;
	final purity: () -> Null<PurityCtx>;
	final taken: Map<String, Bool>;
	final minChecked: Int;
	final minUnchecked: Int;
}
