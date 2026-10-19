package anyparse.check;

import anyparse.check.ArgumentValues.AffixTest;
import anyparse.core.IdentityMap;
import anyparse.query.CallGraph;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.ShapeVocab;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * One thing a condition guarding a call site fixes there: a parameter of the function (`param`, its index among the
 * function's `tracked` ones), or the main-thread check (`param` = `EdgeConditions.MAIN_CHECK`), is `value` — or, for a
 * null test (`nullTest`), the parameter is null exactly when `value` is true; for a string affix guard (`test`), the
 * parameter's string passes it exactly when `value` is true.
 */
private typedef SiteFact = {
	final param: Int;
	final value: Bool;
	final nullTest: Bool;
	@:optional final test: AffixTest;
}

/**
 * What a call site fixes under every state (`EdgeConditions.siteOf`): the contexts it keeps (`mask`, 0 where nothing runs),
 * and the facts about each tracked parameter its conditions test (`params`, each parameter once).
 */
private typedef EdgeSite = {
	final mask: Int;
	final params: Array<{ param: Int, facts: Array<SiteFact> }>;
}

/**
 * The conditions under which a call site of one function body runs, as far as two kinds of condition decide it: the
 * main-thread check a config names (`mainThreadChecks`), and a parameter of the function a call hands a known value
 * (`ArgumentValues`). A walk over the call graph asks `carried` whether a call runs at all from a state — the
 * function, the context it runs on, the VALUATION of its tracked parameters — and on which threads, and `bind` what the
 * call hands the callee's tracked parameters.
 *
 * A call in a `catch` body no exception reaches runs nowhere (`DeadCatches`, handed in as `dead`).
 *
 * A positive whitelist: a call is cut only where its own body says so in one of these shapes, and any other answers
 * "it runs, on every thread its function does".
 * - The call sits in the `then` / `else` of an `if` or a ternary, in the right operand of `&&` / `||`, or after an
 *   `if (c) <exit>` with no `else` in the same block (a `return`, a `throw`, a loop jump: the rest of the block runs
 *   only where `c` is false).
 * - The condition, read through parentheses, `!`, an `&&` that holds (or an `||` that fails) on that side, is a read
 *   or call of a `mainThreadChecks` entry (the edge the graph records at exactly that expression), a tracked parameter
 *   read bare, compared with `null` or tested by a string affix guard (`ArgumentValues.stringPredicate`), a `final`
 *   local bound once to such a condition, or `v != null` / `v == null` of a
 *   `final` local written once as
 *   `check ? null : new T()` (or the arms swapped): the `new` arm is never null, so the test is the check's answer.
 */
@:nullSafety(Strict)
final class EdgeConditions {

	/** The `param` of a fact about the main-thread check. */
	public static inline final MAIN_CHECK: Int = -1;

	/** Every context bit the main thread runs in: loud or quiet. */
	private static inline final MAIN_BITS: Int = ThreadSafety.CTX_MAIN | ThreadSafety.CTX_QUIET;

	/** `<from>|<file>:<from>-<to>` of a call site -> what its conditions fix there. */
	private final _facts: Map<String, Array<SiteFact>> = [];

	/** Each edge `carried` was asked of -> what its site fixes (`siteOf`). */
	private final _sites: IdentityMap<CallEdge, EdgeSite> = new IdentityMap();

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _shape: RefShape;
	private final _checksOf: (String) -> Array<String>;
	private final _blockKinds: Array<String>;

	/** The kinds whose children run one after another as statements: the blocks, and the branches of a `switch`. */
	private final _sequenceKinds: Array<String>;

	private final _ifKinds: Array<String>;
	private final _nestedFnKinds: Array<String>;
	private final _values: ArgumentValues;

	/** Whether a call site sits where nothing runs at all: a `catch` no exception reaches (`DeadCatches`). */
	private final _dead: Null<(CallEdge) -> Bool>;

	/**
	 * `checksOf` names, per file, the graph ids of the main-thread checks the file's chain configures; `trees` finds the
	 * function bodies.
	 */
	public function new(
		graph: CallGraph, trees: FunctionTrees, plugin: GrammarPlugin, checksOf: (String) -> Array<String>, ?dead: (CallEdge) -> Bool
	) {
		_dead = dead;
		_graph = graph;
		_trees = trees;
		_shape = plugin.refShape();
		_checksOf = checksOf;
		_values = new ArgumentValues(graph, trees, plugin);
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		_blockKinds = flow == null ? [] : flow.blockKinds();
		_sequenceKinds = _blockKinds.concat(ShapeVocab.switchArmKinds(_shape));
		_ifKinds = ShapeVocab.conditionalKinds(_shape);
		_nestedFnKinds = ShapeVocab.nestedFunctionKinds(_shape);
	}

	/** The valuation of `id` that knows nothing: every tracked parameter unknown (`ArgumentValues.unknown`). */
	public inline function unknown(id: String): String {
		return _values.unknown(id);
	}

	/** What a call made under the caller's `valuation` hands `edge.to`'s tracked parameters (`ArgumentValues.bind`). */
	public inline function bind(edge: CallEdge, valuation: String): String {
		return _values.bind(edge, valuation);
	}

	/**
	 * The valuation `edge` enters its target under from `valuation`: what a call hands down (`bind`), nothing
	 * known for a value handed on (`unknown`).
	 */
	public inline function entered(edge: CallEdge, valuation: String): String {
		return edge.kind == Ref ? unknown(edge.to) : bind(edge, valuation);
	}

	/**
	 * The context the call `edge` runs in when its function runs on `ctx` under `valuation`: 0 when a condition around
	 * it is false there — for each parameter the conditions test, no value its valuation holds passes them all —, `ctx`
	 * narrowed to the main thread (or to the others) inside a main-thread check, `ctx` itself otherwise.
	 */
	public function carried(edge: CallEdge, valuation: String, ctx: Int): Int {
		final site: EdgeSite = siteOf(edge);
		for (tested in site.params) {
			final atoms: Null<Array<String>> = _values.atomsOf(valuation.charAt(tested.param));
			if (atoms != null && !atoms.exists(a -> tested.facts.foreach(f -> admits(a, f)))) return 0;
		}
		return ctx & site.mask;
	}

	/**
	 * What the site of `edge` fixes under every state, read once per edge: `carried` is asked of each edge for every state
	 * a walk reaches its function in, and only the valuation and the context differ between those asks.
	 */
	private function siteOf(edge: CallEdge): EdgeSite {
		final known: Null<EdgeSite> = _sites.get(edge);
		if (known != null) return known;
		final site: EdgeSite = readSite(edge);
		_sites.set(edge, site);
		return site;
	}

	/**
	 * The mask of contexts the site of `edge` keeps — none for a site where nothing runs (`_dead`), the main thread's or the
	 * others' inside a main-thread check — and its facts about the tracked parameters, grouped by parameter.
	 */
	private function readSite(edge: CallEdge): EdgeSite {
		final dead: Null<(CallEdge) -> Bool> = _dead;
		if (dead != null && dead(edge)) return { mask: 0, params: [] };
		var mask: Int = MAIN_BITS | ThreadSafety.CTX_BG;
		final byParam: Map<Int, Array<SiteFact>> = [];
		for (fact in siteFacts(edge)) {
			if (fact.param == MAIN_CHECK) {
				mask &= fact.value ? MAIN_BITS : ThreadSafety.CTX_BG;
				continue;
			}
			final list: Array<SiteFact> = byParam[fact.param] ?? [];
			list.push(fact);
			byParam[fact.param] = list;
		}
		return { mask: mask, params: [for (param => facts in byParam) { param: param, facts: facts }] };
	}

	/** What the conditions around the call site of `edge` fix there (cached per site). */
	private function siteFacts(edge: CallEdge): Array<SiteFact> {
		final span: Null<Span> = edge.span;
		if (span == null || edge.spliced != null) return [];
		final key: String = '${edge.from}|${edge.file}:${span.from}-${span.to}';
		final known: Null<Array<SiteFact>> = _facts[key];
		if (known != null) return known;
		final facts: Array<SiteFact> = guardsAround(edge, span);
		_facts[key] = facts;
		return facts;
	}

	/**
	 * What the conditions around the site `span` of `edge` fix there, read from its function's body down to the site. None
	 * for a site inside a nested function, whose body runs whenever its value is called, under none of the conditions
	 * around it — the answer every ask of the site gets, the facts read on the way down to it dropped.
	 */
	private function guardsAround(edge: CallEdge, span: Span): Array<SiteFact> {
		final facts: Array<SiteFact> = [];
		final fn: Null<QueryNode> = _trees.ofEdge(edge);
		if (fn == null) return facts;
		var node: QueryNode = fn;
		while (true) {
			final at: Int = node.children.findIndex(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
			if (at < 0) break;
			final child: QueryNode = node.children[at];
			final childSpan: Null<Span> = child.span;
			final exact: Bool = childSpan != null && childSpan.from == span.from && childSpan.to == span.to;
			if (!exact && _nestedFnKinds.contains(child.kind)) return [];
			for (f in guardFacts(node, at, edge.from, edge.file)) facts.push(f);
			if (exact) break;
			node = child;
		}
		return facts;
	}

	/** What holds when child `at` of `node` runs, by the conditions `node` decides it on. */
	private function guardFacts(node: QueryNode, at: Int, fnId: String, file: String): Array<SiteFact> {
		final kids: Array<QueryNode> = node.children;
		if (_ifKinds.contains(node.kind) && kids.length >= 2 && at >= 1 && at <= 2) return factsOf(kids[0], at == 1, fnId, file);
		if (node.kind == _shape.logicalAndKind && at == 1) return factsOf(kids[0], true, fnId, file);
		if (node.kind == _shape.logicalOrKind && at == 1) return factsOf(kids[0], false, fnId, file);
		if (!_blockKinds.contains(node.kind)) return [];
		final facts: Array<SiteFact> = [];
		// `if (c) return;` with no else: what follows in the block runs only where `c` is false
		for (i in 0...at) {
			final s: QueryNode = kids[i];
			if ((_shape.ifStatementKinds ?? []).contains(s.kind) && s.children.length == 2 && alwaysExits(s.children[1]))
				for (f in factsOf(s.children[0], false, fnId, file)) facts.push(f);
		}
		return facts;
	}

	/** Whether `node` is an exit statement, or a block whose last statement is one. */
	private function alwaysExits(node: QueryNode): Bool {
		final exits: Array<String> = _shape.controlExitKinds ?? [];
		if (exits.contains(node.kind)) return true;
		final kids: Array<QueryNode> = node.children;
		return _blockKinds.contains(node.kind) && kids.length > 0 && alwaysExits(kids[kids.length - 1]);
	}

	/** What `cond` evaluating to `value` fixes, in the body of `fnId`. */
	private function factsOf(cond: QueryNode, value: Bool, fnId: String, file: String): Array<SiteFact> {
		final kind: String = cond.kind;
		final kids: Array<QueryNode> = cond.children;
		if (kind == _shape.parenKind && kids.length == 1) return factsOf(kids[0], value, fnId, file);
		if (kind == _shape.notKind && kids.length == 1) return factsOf(kids[0], !value, fnId, file);
		if (kind == _shape.logicalAndKind && kids.length == 2)
			return value ? factsOf(kids[0], true, fnId, file).concat(factsOf(kids[1], true, fnId, file)) : [];
		if (kind == _shape.logicalOrKind && kids.length == 2)
			return value ? [] : factsOf(kids[0], false, fnId, file).concat(factsOf(kids[1], false, fnId, file));
		if ((kind == _shape.notEqKind || kind == _shape.eqKind) && kids.length == 2)
			return nullFacts(cond, (kind == _shape.notEqKind) == value, fnId, file);
		if (kind == _shape.identKind) {
			final at: Int = _values.tracked(fnId).indexOf(cond.name ?? '');
			if (at >= 0) return [{ param: at, value: value, nullTest: false }];
			// a `final` local bound once to a condition is that condition
			final bound: Null<QueryNode> = finalLocalInit(cond, fnId);
			if (bound != null) return factsOf(bound, value, fnId, file);
		}
		final affix: Null<AffixTest> = _values.stringPredicate(fnId, cond);
		return if (affix != null)
			[
				{
					param: affix.param,
					value: value,
					nullTest: false,
					test: affix
				}
			]
		else if (isMainCheck(cond, fnId, file))
			[{ param: MAIN_CHECK, value: value, nullTest: false }]
		else
			[];
	}

	/**
	 * What the null test `cond` coming out non-null (`nonNull`) fixes: of a tracked parameter, that it is null exactly
	 * when not `nonNull`; of a local, what the check that chose it said (`nullTestFacts`).
	 */
	private function nullFacts(cond: QueryNode, nonNull: Bool, fnId: String, file: String): Array<SiteFact> {
		final tested: Null<QueryNode> = _values.nullTested(cond);
		if (tested == null) return [];
		final at: Int = tested.kind == _shape.identKind ? _values.tracked(fnId).indexOf(tested.name ?? '') : -1;
		return at >= 0 ? [{ param: at, value: !nonNull, nullTest: true }] : nullTestFacts(tested, nonNull, fnId, file);
	}

	/**
	 * What `local` being non-null (`nonNull`) fixes: for a `final` local of the body declared once, as
	 * `check ? null : new T()` or `check ? new T() : null`, the check's answer that picked that arm.
	 */
	private function nullTestFacts(local: QueryNode, nonNull: Bool, fnId: String, file: String): Array<SiteFact> {
		final init: Null<QueryNode> = finalLocalInit(local, fnId);
		if (init == null || init.kind != _shape.ternaryKind || init.children.length != 3) return [];
		final newKind: Null<String> = _shape.newExprKind;
		final nullFirst: Bool = init.children[1].kind == _shape.nullLiteralKind && init.children[2].kind == newKind;
		final newFirst: Bool = init.children[1].kind == newKind && init.children[2].kind == _shape.nullLiteralKind;
		if (!(nullFirst || newFirst)) return [];
		// the `new` arm is the non-null one: the check took it exactly where the local is non-null
		return factsOf(init.children[0], nonNull == newFirst, fnId, file);
	}

	/**
	 * The value of `local` when it reads a `final` local the body of `fnId` declares once, with one, in a block the read
	 * sits in, before it (`BareNames.localOf`): a read outside that block, a nested function's own local, means some
	 * other binding. Null otherwise.
	 */
	private function finalLocalInit(local: QueryNode, fnId: String): Null<QueryNode> {
		final fn: Null<QueryNode> = _trees.ofId(fnId);
		final decl: Null<QueryNode> = fn == null ? null : BareNames.localOf(fn, local, _shape, _sequenceKinds);
		if (decl == null) return null;
		final declKinds: Array<String> = _shape.localDeclKinds ?? [];
		return !declKinds.contains(decl.kind) || (_shape.mutableLocalDeclKinds ?? []).contains(decl.kind) || decl.children.length == 0
			? null
			: decl.children[decl.children.length - 1];
	}

	/** Whether `expr` is a read or call of a `mainThreadChecks` entry: the graph records an invocation of one at exactly its range. */
	private function isMainCheck(expr: QueryNode, fnId: String, file: String): Bool {
		final span: Null<Span> = expr.span;
		final checks: Array<String> = _checksOf(file);
		return span != null && checks.length > 0
			&& _graph.outEdges(fnId).exists(
				e -> e.kind.isInvocation() && checks.contains(e.to) && e.span != null && e.span.from == span.from && e.span.to == span.to
			);
	}

	/**
	 * Whether a parameter holding the atom `atom` (`ArgumentValues.atomsOf`) may pass `fact`: a null test by whether it is
	 * `null`, a `Bool` condition by its `Bool`, a string affix guard by its string — and any atom that says nothing of what
	 * the fact tests passes.
	 */
	private static function admits(atom: String, fact: SiteFact): Bool {
		final test: Null<AffixTest> = fact.test;
		if (fact.nullTest) return ArgumentValues.isNullAtom(atom) == fact.value;
		if (test == null) return atom == ArgumentValues.TRUE ? fact.value : atom != ArgumentValues.FALSE || !fact.value;
		final s: Null<String> = ArgumentValues.stringOf(atom);
		return s == null || (test.suffix ? s.endsWith(test.text) : s.startsWith(test.text)) == fact.value;
	}

}
