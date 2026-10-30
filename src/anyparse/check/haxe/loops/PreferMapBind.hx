package anyparse.check.haxe.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.common.expressions.PreferBind;
import anyparse.check.scan.RunScan;
import anyparse.query.BinderScan;
import anyparse.query.SymbolIndex;

/**
 * Flags an array comprehension that maps each element through ONE call — `[for (x in xs) f(a, x)]` — and rewrites it
 * to `xs.map(f.bind(a))`: the element in `_`'s slot when it is not the last argument (`f.bind(_, a)`), the bare `f`
 * when it is the only one. A body that is anything but that call keeps the comprehension. `Severity.Info`.
 *
 * The comprehension evaluates the callee and the other arguments once per element, `bind` once before the first:
 * both go through `PreferBind.partialApplication`, the proof a `() -> f(a, b)` wrapper gets, and the loop binder may
 * appear only as the one free argument. The iterable must be an `Array` (`RefShape.arrayTypeNames`): another
 * collection's `map` returns that collection, and an iterator has none. It must be a postfix operand as written — an
 * identifier, a member, a call, an index or a parenthesis — since the rewrite appends `.map` to its text. Equivalence assumes
 * the callee does not resize the very array it is mapped over, and `o.m.bind(a)` reads `o.m` even when the array is empty.
 *
 * `RiskyFix`: a comprehension takes its element type from where it is written (`final ys: Array<Float> = [for (x in
 * xs) f(x)]` with an `Int` result), and `map` takes the callee's return type, which an invariant `Array` then refuses.
 * With a compiler oracle the rewrite stands where it compiles; without one the rule is report-only. `DefaultOff`: a
 * style preference, opted in with `"prefer-map-bind": { "enabled": true }`.
 */
@:nullSafety(Strict)
final class PreferMapBind extends HaxeRule implements DefaultOff implements RiskyFix {

	private static inline final RULE_ID: String = 'prefer-map-bind';

	public function new() {
		super(
			RULE_ID, 'an array comprehension mapping each element through one call, replaceable with xs.map(f.bind(a))', RuleCategory.Loops
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: String -> Null<SymbolIndex> = PreferBind.coveringIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in matches(tree, entry.file, entry.source, seams, plugin, index)) violations.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this comprehension maps each element through one call — it can be ${m.text}'
			});
		});
	}

	/** Rewrite each flagged comprehension to `xs.map(<partial application>)`. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final scope: String -> Null<SymbolIndex> = PreferBind.coveringIndex([{ file: file, source: source }], plugin, index);
		return CheckScan.applyTextMatches(plugin, source, violations, (tree, text) -> matches(tree, file, text, seams, plugin, scope));
	}

	/** Every mappable comprehension under `tree` with its rewrite; a nested one is the next `--fix` pass. */
	private static function matches(
		tree: QueryNode, file: String, source: String, seams: Seams, plugin: GrammarPlugin, index: String -> Null<SymbolIndex>
	): Array<FixEdit> {
		final out: Array<FixEdit> = [];
		var bind: Null<(QueryNode, Int) -> Null<String>> = null;
		var nominal: Null<(QueryNode) -> Null<String>> = null;
		var built: Bool = false;
		function walk(node: QueryNode): Void {
			if (seams.opaqueKinds.contains(node.kind)) return;
			final head: Null<{ iterable: QueryNode, call: QueryNode, free: Int }> = mappedCall(node, seams);
			final span: Null<Span> = node.span;
			final iterableSpan: Null<Span> = head?.iterable?.span;
			if (head != null && span != null && iterableSpan != null) {
				final at: Span = span;
				if (!built) {
					built = true;
					bind = PreferBind.partialApplication(tree, file, source, plugin, index);
					nominal = CheckScan.typeNominalResolver(source, plugin, tree, file, index(file), true);
				}
				final binds: Null<(QueryNode, Int) -> Null<String>> = bind;
				final types: Null<(QueryNode) -> Null<String>> = nominal;
				final bound: Null<String> = binds == null ? null : binds(head.call, head.free);
				final type: Null<String> = types == null ? null : types(head.iterable);
				if (bound != null && type != null && seams.arrayTypeNames.contains(type)) {
					out.push({ span: at, text: '${source.substring(iterableSpan.from, iterableSpan.to)}.map($bound)' });
					return;
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * The iterable, the call and the index of its free argument when `node` is `[for (x in xs) f(…, x, …)]`: an array
	 * literal holding only a loop over a postfix-operand iterable with no value binder, whose body is a call taking the
	 * loop binder as exactly one argument, bare. Else null.
	 */
	private static function mappedCall(node: QueryNode, s: Seams): Null<{ iterable: QueryNode, call: QueryNode, free: Int }> {
		if (node.kind != s.arrayLiteralKind || node.children.length != 1) return null;
		final loop: QueryNode = node.children[0];
		final binder: Null<String> = loop.name;
		if (!s.iterationKinds.contains(loop.kind) || binder == null || loop.children.exists(c -> s.valueBinderKinds.contains(c.kind)))
			return null;
		final operands: Array<QueryNode> = BinderScan.loopOperands(loop, s.valueBinderKinds);
		if (operands.length != 2 || !s.operandKinds.contains(operands[0].kind)) return null;
		final call: QueryNode = operands[1];
		if (call.kind != s.callKind) return null;
		var free: Int = -1;
		for (i in 1...call.children.length) {
			final arg: QueryNode = call.children[i];
			if (arg.kind != s.identKind || arg.name != binder) continue;
			if (free >= 0) return null;
			free = i - 1;
		}
		return free < 0 ? null : { iterable: operands[0], call: call, free: free };
	}

	/** The seams the rule reads, or null when one it cannot do without is unset. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final arrayKind: Null<String> = shape.arrayLiteralKind;
		final callKind: Null<String> = shape.callKind;
		final arrayTypes: Null<Array<String>> = shape.arrayTypeNames;
		final iterationKinds: Null<Array<String>> = shape.iterationBindingKinds;
		if (arrayKind == null || callKind == null || arrayTypes == null || iterationKinds == null) return null;
		final operandKinds: Array<String> = [shape.identKind, callKind];
		for (k in [shape.fieldAccessKind, shape.indexAccessKind, shape.parenKind]) if (k != null) operandKinds.push(k);
		return {
			arrayLiteralKind: arrayKind,
			callKind: callKind,
			identKind: shape.identKind,
			arrayTypeNames: arrayTypes,
			iterationKinds: iterationKinds,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			operandKinds: operandKinds,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

}

/** The resolved seams `PreferMapBind` reads in both `run` and `fix`. */
private typedef Seams = {
	final arrayLiteralKind: String;
	final callKind: String;
	final identKind: String;
	final arrayTypeNames: Array<String>;
	final iterationKinds: Array<String>;
	final valueBinderKinds: Array<String>;
	final operandKinds: Array<String>;
	final opaqueKinds: Array<String>;
};
