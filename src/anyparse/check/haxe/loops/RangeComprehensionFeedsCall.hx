package anyparse.check.haxe.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.haxe.loops.MappedComprehension.ComprehensionSeams;
import anyparse.check.haxe.loops.MappedComprehension.Mapping;
import anyparse.check.scan.NegationScan;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SymbolIndex;

/** The grammar kinds `RangeComprehensionFeedsCall` reads; the comprehension's own are `MappedComprehension`'s. */
private typedef Seams = {
	final comprehension: ComprehensionSeams;
	final callKind: String;
	final fieldAccessKind: String;
	final returnKind: String;
	final blockKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final lambdaKinds: Array<String>;
	final requiredParamKinds: Array<String>;
	final negation: NegationSeams;
	final support: Null<BooleanLogicSupport>;
};

/** One finding: its span (the statement a fix replaces, when `text` is set), the method fed, and the replacement loop. */
private typedef Match = { final span: Span; final method: String; final text: Null<String>; };

/**
 * Flags an identity comprehension over an integer range, `[for (i in a...b) i]`, that a call consumes at once —
 * `.exists(f)`, `.foreach(f)`, `.filter(f)`, `.map(f)`, `.count(f)`, `.find(f)`: it fills an array only to walk it again,
 * where the range itself is iterable. `Severity.Info`, `DefaultOff`.
 *
 * `--fix` rewrites the two that are loops with an early exit — `exists` and `foreach` — and only where the call is the
 * whole value of a `return` standing in a block, so the one statement becomes two:
 * `return [for (i in a...b) i].exists(p -> c);` is `for (p in a...b) if (c) return true; return false;`, and `foreach`
 * is `for (p in a...b) if (!c) return false; return true;` with the negation `NegationScan` writes. The lambda's own
 * parameter becomes the loop binder, so the condition keeps the scope it had and nothing is renamed or captured. A
 * lambda with a typed parameter or a block body, a call that is not the whole `return` value (the tail of an `&&` chain,
 * a switch arm) and a comment in the text the rewrite drops stay report-only.
 *
 * The reverse of `prefer-exists` / `prefer-foreach`, which turn such a loop over a collection into the call: those
 * decline a range iterable, so the two never take turns on the same code.
 */
@:nullSafety(Strict)
final class RangeComprehensionFeedsCall extends HaxeRule implements DefaultOff {

	private static inline final RULE_ID: String = 'range-comprehension-feeds-call';
	private static inline final CALL_CHILDREN: Int = 2;

	/** The two calls whose consuming loop exits early, so a `return` holding one can become that loop. */
	private static final EXISTS: String = 'exists';

	private static final FOREACH: String = 'foreach';

	/** Every call that consumes an array at once, whatever follows. */
	private static final FEEDING_METHODS: Array<String> = [EXISTS, FOREACH, 'filter', 'map', 'count', 'find'];

	public function new() {
		super(
			RULE_ID, 'an identity comprehension over an integer range consumed at once by a call, replaceable with a loop over the range',
			RuleCategory.Loops
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in matches(tree, entry.source, seams, plugin)) violations.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this range comprehension builds an array only for `.${m.method}` to walk — loop over the range instead'
			});
		});
	}

	/** Replace each flagged `return` with the loop over the range and the return that follows it. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null || violations.length == 0
			? []
			: CheckScan.applyTextMatches(
				plugin, source, violations, (tree, text) -> [ for (m in matches(tree, text, seams, plugin)) {
					final replacement: Null<String> = m.text;
					if (replacement != null) ({ span: m.span, text: replacement });
				} ]
			);
	}

	/** Every call that a range comprehension feeds, each with its rewrite when it is the value of a `return`. */
	private static function matches(tree: QueryNode, source: String, s: Seams, plugin: GrammarPlugin): Array<Match> {
		final out: Array<Match> = [];
		final regions: () -> Array<LexRegion> = ElementSpan.lazyRegions(source, plugin);
		function walk(node: QueryNode, parent: Null<QueryNode>, grandparent: Null<QueryNode>): Void {
			if (s.opaqueKinds.contains(node.kind)) return;
			final m: Null<Match> = matchOf(node, parent, grandparent, source, regions, s);
			if (m != null) out.push(m);
			for (c in node.children) walk(c, node, parent);
		}
		walk(tree, null, null);
		return out;
	}

	/** The finding when `call` is `[for (i in a...b) i].method(…)`, else null. */
	private static function matchOf(
		call: QueryNode, parent: Null<QueryNode>, grandparent: Null<QueryNode>, source: String, regions: () -> Array<LexRegion>, s: Seams
	): Null<Match> {
		if (call.kind != s.callKind || call.children.length != CALL_CHILDREN) return null;
		final callee: QueryNode = call.children[0];
		final method: Null<String> = callee.name;
		final callSpan: Null<Span> = call.span;
		if (method == null || callSpan == null || callee.kind != s.fieldAccessKind || callee.children.length != 1) return null;
		if (!FEEDING_METHODS.contains(method)) return null;
		final loop: Null<Mapping> = MappedComprehension.of(callee.children[0], s.comprehension);
		if (loop == null || !MappedComprehension.isBinder(loop.body, loop.binder, s.comprehension)) return null;
		final statementSpan: Null<Span> = parent != null && parent.kind == s.returnKind && parent.children.length == 1
			&& grandparent != null
			&& s.blockKinds.contains(grandparent.kind)
			? parent.span
			: null;
		final text: Null<String> = statementSpan == null ? null : loopText(call, method, loop, statementSpan, source, regions, s);
		return { span: text == null || statementSpan == null ? callSpan : statementSpan, method: method, text: text };
	}

	/** The loop and the `return` after it that replace `return range.method(p -> c);`, or null when the call has no such form. */
	private static function loopText(
		call: QueryNode, method: String, loop: Mapping, statement: Span, source: String, regions: () -> Array<LexRegion>, s: Seams
	): Null<String> {
		if (method != EXISTS && method != FOREACH) return null;
		final lambda: QueryNode = call.children[1];
		if (!s.lambdaKinds.contains(lambda.kind) || lambda.children.length != CALL_CHILDREN) return null;
		final param: QueryNode = lambda.children[0];
		final binder: Null<String> = param.name;
		final body: QueryNode = lambda.children[1];
		final bodySpan: Null<Span> = body.span;
		if (binder == null || bodySpan == null) return null;
		if (!s.requiredParamKinds.contains(param.kind) || param.children.length > 0 || param.type != null) return null;
		if (s.blockKinds.contains(body.kind) || CheckScan.regionHoldsComment(regions, statement, [loop.iterableSpan, bodySpan]))
			return null;
		final range: String = source.substring(loop.iterableSpan.from, loop.iterableSpan.to);
		final exists: Bool = method == EXISTS;
		final condition: String = exists
			? source.substring(bodySpan.from, bodySpan.to)
			: NegationScan.negateConditionText(body, source, s.negation, s.support, null, null, regions());
		return 'for ($binder in $range) if ($condition) return ${exists ? 'true' : 'false'};\nreturn ${exists ? 'false' : 'true'};';
	}

	/** The seams the rule reads, or null when the grammar names none of a range, a call, a return or a block. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final base: Null<ComprehensionSeams> = MappedComprehension.seamsOf(shape);
		final intervalKind: Null<String> = shape.intervalKind;
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final returnKind: Null<String> = shape.returnStatementKind;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (
			base == null || intervalKind == null || callKind == null || fieldKind == null || returnKind == null || lambdaKinds == null
			|| paramKinds == null || flow == null
		)
			return null;
		final functionForms: Array<Null<String>> = [shape.fnExprKind, shape.namedFnExprKind];
		return {
			comprehension: {
				arrayLiteralKind: base.arrayLiteralKind,
				identKind: base.identKind,
				parenKind: base.parenKind,
				iterationKinds: base.iterationKinds,
				valueBinderKinds: base.valueBinderKinds,
				operandKinds: [intervalKind]
			},
			callKind: callKind,
			fieldAccessKind: fieldKind,
			returnKind: returnKind,
			blockKinds: flow.blockKinds(),
			opaqueKinds: shape.opaqueKinds ?? [],
			lambdaKinds: lambdaKinds.filter(k -> !functionForms.contains(k)),
			requiredParamKinds: paramKinds.filter(k -> k != shape.optionalParamKind && k != shape.restParamKind),
			negation: NegationScan.negationSeams(shape),
			support: plugin.booleanLogicSupport()
		};
	}

}
