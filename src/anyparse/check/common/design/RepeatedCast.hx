package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.scan.PurityScan;
import anyparse.query.BranchPaths;
import anyparse.query.CasePatterns;
import anyparse.query.IndexScope;
import anyparse.query.ParseGate;
import anyparse.query.SameValueRuns;
import anyparse.query.ShapeVocab;
import anyparse.query.StableChain;
import anyparse.query.StdTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.UnchangedLocal;
import anyparse.query.WriteSites;

using StringTools;

/**
 * Flags one value cast to one type several times in one function body, and binds the cast once:
 * `cast(o, Bubble).color = c; cast(o, Bubble).redraw();` becomes `final bubble: Bubble = cast(o, Bubble);
 * bubble.color = c; bubble.redraw();`. It is the cast counterpart of `extract-repeated-expression`, which never
 * counts a cast (a checked cast is not pure: it throws) and is report-only.
 *
 * ## The family
 *
 * - **Checked** (`cast(x, T)`) and **unchecked** (`(cast x : T)`, `(x : T)`) casts are counted apart and never merged:
 *   the checked one carries a runtime check. Thresholds are `minChecked` (default 2: each repeat is a runtime check)
 *   and `minUnchecked` (default 3), read from this rule's options, against the most casts one execution runs: of the
 *   branches of one `if`, `switch` or ternary only the one holding the most counts (`BranchPaths.mostOnOnePath`).
 * - **Same value.** The operand is a stable chain (`StableChain`): a local or parameter no call writes, or a `final`
 *   field with no getter, then `final` fields only — a `var` field a call may reassign is no operand. Every occurrence
 *   reads the same storage with no write between the first and the last on any path (`SameValueRuns`): a write cuts
 *   the run where it takes effect, and a run a loop carries a write into is no run.
 * - **Function literals.** A cast in a function literal joins the run of the function holding it, after a cast of its
 *   own there, when nothing in the outermost function writes the operand: the literal then captures the bound local.
 *
 * ## The fix
 *
 * The `final` goes before the statement holding the first occurrence, in the innermost block or case arm holding them all,
 * and only when that occurrence runs first and always in that statement (`runsFirst`: in order, or in the slot a condition,
 * a subject or a short-circuit operator evaluates first), so binding it moves nothing — never above a guard that makes the
 * cast valid, a loop, a `try`, or code that does anything. Otherwise the finding stays report-only: so it does when the type
 * suggests no value name (`StdTypes.valueNameOf`). The name is suffixed when any name in the file already uses it.
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

		final shortCircuit: Array<String> = [
			for (k in [
				shape.logicalAndKind,
				shape.logicalOrKind,
				shape.nullCoalesceKind,
				shape.ternaryKind
			]) if (k != null) k
		];
		final branching: Array<String> = (shape.branchConditionKinds ?? []).concat(shape.switchKinds ?? []);
		final locals: UnchangedLocal = new UnchangedLocal(tree, shape);
		final typeInfo: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		var purity: Null<PurityCtx> = null;
		var purityRead: Bool = false;
		final scan: Scan = {
			source: source,
			tree: tree,
			shape: shape,
			locals: locals,
			chains: new StableChain(tree, shape, locals, TypeInfoMemo.declaredTypeSources(typeInfo, source), symbols, file),
			units: ShapeVocab.functionLikeKinds(shape),
			blockKinds: (plugin.controlFlowSupport()?.blockKinds() ?? []).concat([
				for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k
			]),
			loopKinds: ShapeVocab.loopKinds(shape),
			inOrderKinds: inOrderKinds(shape, shortCircuit),
			conditionKinds: branching.concat(shortCircuit),
			exclusiveKinds: branching.concat([for (k in [shape.ternaryKind]) if (k != null) k]),
			castTargets: TypeInfoMemo.castTargetSources(typeInfo, source),
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

	/** Each outermost function under `node`, analysed whole: the casts of the function literals in it with its own (`homes`). */
	private function scanUnits(node: QueryNode, scan: Scan, out: Array<Finding>): Void {
		if (!scan.units.contains(node.kind)) {
			for (c in node.children) scanUnits(c, scan, out);
			return;
		}
		final casts: Array<Cast> = [];
		for (c in node.children) collect(c, scan, [node], casts);
		report(node, casts, scan, out);
	}

	/** Every cast of a stable chain in `node`, each with the functions holding it, outermost first. */
	private function collect(node: QueryNode, scan: Scan, units: Array<QueryNode>, out: Array<Cast>): Void {
		final holders: Array<QueryNode> = scan.units.contains(node.kind) ? units.concat([node]) : units;
		final found: Null<Cast> = castOf(node, scan, holders);
		if (found != null) out.push(found);
		for (c in node.children) collect(c, scan, holders, out);
	}

	private function castOf(node: QueryNode, scan: Scan, units: Array<QueryNode>): Null<Cast> {
		final shape: RefShape = scan.shape;
		final span: Null<Span> = node.span;
		if (span == null || node.children.length != 1) return null;
		final checked: Bool = node.kind == shape.checkedCastKind;
		if (!checked && node.kind != shape.checkTypeKind) return null;
		var operand: QueryNode = node.children[0];
		if (!checked && operand.kind == shape.uncheckedCastKind && operand.children.length == 1) operand = operand.children[0];
		final typeText: Null<String> = TypeResolver.castTargetWithin(span, scan.castTargets());
		if (typeText == null) return null;
		final read: Null<StableRead> = scan.chains.read(operand);
		return read == null ? null : {
			node: node,
			span: span,
			operand: operand,
			checked: checked,
			binding: read.binding,
			key: read.key,
			typeText: typeText,
			units: units
		};
	}

	private function report(top: QueryNode, casts: Array<Cast>, scan: Scan, out: Array<Finding>): Void {
		final groups: Array<Array<Cast>> = [];
		final byKey: Map<String, Array<Cast>> = [];
		for (c in casts) {
			final family: String = c.checked ? 'C' : 'U';
			final key: String = '$family|${c.key}|${c.typeText.replace(' ', '')}';
			final bucket: Null<Array<Cast>> = byKey[key];
			if (bucket == null) {
				final fresh: Array<Cast> = [c];
				byKey[key] = fresh;
				groups.push(fresh);
			} else {
				bucket.push(c);
			}
		}
		final found: Array<Finding> = [];
		for (group in groups) {
			group.sort((a, b) -> a.span.from - b.span.from);
			for (home in homes(top, group, scan)) for (run in runsOf(home.unit, home.occ, scan)) {
				final least: Int = run[0].checked ? scan.minChecked : scan.minUnchecked;
				final most: Int = BranchPaths.mostOnOnePath([for (c in run) BranchPaths.of(home.unit, c.node, scan.exclusiveKinds)]);
				if (most >= least) found.push(finding(home.unit, run, most, scan));
			}
		}
		found.sort((a, b) -> a.span.from - b.span.from);
		for (f in found) out.push(f);
	}

	/**
	 * The occurrences of one operand and type split where a write of the operand takes effect, without the runs a loop
	 * carries such a write into; a write below the operand (`o.field = v`) keeps it.
	 */
	private function runsOf(unit: QueryNode, group: Array<Cast>, scan: Scan): Array<Array<Cast>> {
		final found: Null<Array<WriteSite>> = operandWrites(group, scan);
		if (found == null) return [];
		final writes: Array<WriteSite> = found;
		return SameValueRuns.splitAtWrites(group, writes)
			.filter(run -> !SameValueRuns.carriedRound(run, writes, unit, scan.blockKinds, scan.loopKinds));
	}

	/**
	 * `group` split by the function that binds each cast once: the innermost one holding it, or — when nothing in `top`
	 * writes the operand, so a cast reads one value whenever it runs — the outermost one holding it with a cast of its own
	 * ahead of it, whose local a function literal then captures.
	 */
	private function homes(top: QueryNode, group: Array<Cast>, scan: Scan): Array<Home> {
		final writes: Null<Array<WriteSite>> = operandWrites(group, scan);
		final unwritten: Bool = writes != null && !writes.exists(w -> TreePath.covers(top, w.node.span));
		final out: Array<Home> = [];
		for (c in group) {
			final own: QueryNode = c.units[c.units.length - 1];
			var unit: QueryNode = own;
			if (unwritten)
				unit = c.units.find(u ->
					u == own || group.exists(o -> o.units[o.units.length - 1] == u && o.span.from < c.span.from)
				) ?? own;
			final home: Null<Home> = out.find(h -> h.unit == unit);
			if (home == null)
				out.push({ unit: unit, occ: [c] })
			else
				home.occ.push(c);
		}
		return out;
	}

	/** The writes that may change what `group`'s operand reads, one below it (`o.field = v`) aside; null when no path names it. */
	private function operandWrites(group: Array<Cast>, scan: Scan): Null<Array<WriteSite>> {
		final key: Null<String> = WriteSites.accessPath(group[0].operand, scan.tree, scan.shape);
		if (key == null) return null;
		final operand: String = key;
		return scan.locals.writes.filter(w -> {
			final written: Null<String> = w.path;
			return written == null || WriteSites.mayOverlap(written, operand, true);
		});
	}

	/** The finding of `run`, `most` of whose casts one execution of `unit` runs at most (`BranchPaths.mostOnOnePath`). */
	private function finding(unit: QueryNode, run: Array<Cast>, most: Int, scan: Scan): Finding {
		final first: Cast = run[0];
		final span: Span = first.span;
		final at: Null<Span> = first.operand.span;
		final operand: String = at == null ? '' : scan.source.substring(at.from, at.to);
		final message: String = '`${scan.source.substring(span.from, span.to)}` — $operand cast to ${first.typeText} is evaluated '
			+ '$most$REPEAT_TAIL; bind it once to a final local';
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
	 * The statement of the innermost block holding every occurrence that holds the first one, a case arm's patterns and guard
	 * aside, when each node from it down to the first occurrence runs that occurrence first and always (`runsFirst`); else null.
	 */
	private function hoistStatement(unit: QueryNode, run: Array<Cast>, scan: Scan): Null<QueryNode> {
		final home: Null<QueryNode> = SameValueRuns.hoistBlock(run, unit, scan.blockKinds);
		final purity: Null<PurityCtx> = scan.purity();
		if (home == null || purity == null) return null;
		final path: Array<QueryNode> = TreePath.ancestorsAt(unit, run[0].span.from);
		var at: Int = path.indexOf(home) + 1;
		if (at == 0 || at >= path.length || home.children.indexOf(path[at]) < CasePatterns.bodyStart(home, scan.shape)) return null;
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

	/** `Scan.inOrderKinds`: the declarations, statements and expressions with no branch, and the operators not in `shortCircuit`. */
	private static function inOrderKinds(shape: RefShape, shortCircuit: Array<String>): Array<String> {
		final declKinds: Array<String> = (shape.localDeclKinds ?? []).concat(shape.mutableLocalDeclKinds ?? []);
		return declKinds.concat([
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
		]).concat([for (k in shape.pureOperatorKinds ?? []) if (!shortCircuit.contains(k)) k]);
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

	/** The binding offset of the operand's root when that is a local, else -1 (`StableChain`). */
	final binding: Int;

	/** What the operand reads (`StableRead.key`): two casts with one key read one storage. */
	final key: String;
	final typeText: String;

	/** The functions holding the cast, outermost first. */
	final units: Array<QueryNode>;

}

/** The casts of one group a function binds once (`homes`). */
private typedef Home = {
	final unit: QueryNode;
	final occ: Array<Cast>;
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
	final chains: StableChain;
	final units: Array<String>;

	/** The statement lists a `final` goes into: the grammar's blocks and its case arms. */
	final blockKinds: Array<String>;
	final loopKinds: Array<String>;

	/**
	 * The nodes that evaluate every child, in order: a statement or expression
	 * with no branch in it, an operator that does not short-circuit.
	 */
	final inOrderKinds: Array<String>;

	/** The nodes whose first child is the condition, subject or operand they always evaluate first, the rest perhaps never. */
	final conditionKinds: Array<String>;

	/** The conditionals two of whose branches never both run (`BranchPaths`). */
	final exclusiveKinds: Array<String>;
	final castTargets: () -> Map<Int, String>;
	final purity: () -> Null<PurityCtx>;
	final taken: Map<String, Bool>;
	final minChecked: Int;
	final minUnchecked: Int;

}
