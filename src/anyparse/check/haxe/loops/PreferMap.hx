package anyparse.check.haxe.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.common.control.BranchChain;
import anyparse.check.common.expressions.PreferBind;
import anyparse.check.scan.RunScan;
import anyparse.query.BinderScan;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;

/**
 * Flags an array comprehension that maps each element — `[for (x in xs) body]` where the body is ONE value
 * expression reading the loop binder — and rewrites it to `xs.map(…)`, keeping the binder's name. `Severity.Info`.
 *
 * Two spellings. A body that is one call taking the binder as exactly one bare argument becomes a partial application,
 * `[for (x in xs) f(a, x)]` → `xs.map(f.bind(a))` (the binder in `_`'s slot when it is not last, the bare `f` when it is
 * alone), where `PreferBind.partialApplication` proves `bind` evaluates the callee and the other arguments the way the
 * comprehension did. Any other value body becomes the lambda `xs.map(x -> body)`: a field chain, a method call, an
 * operator, a ternary, `x?.f`. The lambda runs the body once per element in the same order, so a getter is read exactly
 * when the comprehension read it.
 *
 * The comprehension stays for a body that is not one value expression — an `if` without `else` (a filter), a nested loop,
 * `return` / `break` / `continue`, a block or `var`, a `try`, a `#if` — and for an assignment to the binder, a rebinding
 * of its name, `super` (a closure cannot call it), a body that never reads the binder, a bare `x`, a key-value binder, a map entry body and
 * a comprehension whose dropped punctuation carries a comment. The iterable must be an `Array`
 * (`RefShape.arrayTypeNames`): another collection's `map` returns that collection, and an iterator has none. It must be a
 * postfix operand as written — an identifier, a member, a call, an index or a parenthesis — since the rewrite appends
 * `.map` to its text. Equivalence assumes the body does not resize the very array it is mapped over, and `o.m.bind(a)`
 * reads `o.m` even when the array is empty.
 *
 * `RiskyFix`: a comprehension takes its element type from where it is written (`final ys: Array<Float> = [for (x in
 * xs) f(x)]` with an `Int` result), and `map` takes the callee's or body's own type, which an invariant `Array` then
 * refuses; a closure also loses the null-safety narrowing of a mutable local it captures. With a compiler oracle the
 * rewrite stands where it compiles; without one the rule is report-only. `DefaultOff`: a style preference, opted in with
 * `"prefer-map": { "enabled": true }`.
 */
@:nullSafety(Strict)
final class PreferMap extends HaxeRule implements DefaultOff implements RiskyFix implements VolatileMessage {

	private static inline final RULE_ID: String = 'prefer-map';

	/** The lead-in of a finding's message; the rewrite it quotes follows, and `messageIdentity` masks that tail. */
	private static inline final MESSAGE_LEAD: String = 'this comprehension maps each element — it can be ';

	/** The longest rewrite a finding's message quotes before it is cut. */
	private static inline final MESSAGE_EXCERPT_MAX: Int = 80;

	public function new() {
		super(
			RULE_ID, 'an array comprehension mapping each element, replaceable with xs.map(f.bind(a)) or xs.map(x -> body)',
			RuleCategory.Loops
		);
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskRestAfter(message, MESSAGE_LEAD);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: String -> Null<SymbolIndex> = PreferBind.coveringIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in matches(tree, entry.file, entry.source, seams, plugin, index)) violations.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: '$MESSAGE_LEAD${SourceText.excerpt(m.text, MESSAGE_EXCERPT_MAX)}'
			});
		});
	}

	/** Rewrite each flagged comprehension to `xs.map(<partial application or lambda>)`. */
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
			final head: Null<Mapping> = mappedLoop(node, seams);
			final span: Null<Span> = node.span;
			if (head != null && span != null) {
				final at: Span = span;
				if (!built) {
					built = true;
					bind = PreferBind.partialApplication(tree, file, source, plugin, index);
					nominal = CheckScan.typeNominalResolver(source, plugin, tree, file, index(file), true);
				}
				final types: Null<(QueryNode) -> Null<String>> = nominal;
				final type: Null<String> = types == null ? null : types(head.iterable);
				final mapper: Null<String> = type != null && seams.arrayTypeNames.contains(type) && gapsHoldNoComment(head, at, source)
					? boundMapper(head, bind, source, seams) ?? lambdaMapper(head, source, seams)
					: null;
				if (mapper != null) {
					out.push({ span: at, text: '${source.substring(head.iterableSpan.from, head.iterableSpan.to)}.map($mapper)' });
					return;
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * The iterable, the binder and the body when `node` is `[for (x in xs) body]`: an array literal holding only a loop
	 * over a postfix-operand iterable with no value binder. Else null.
	 */
	private static function mappedLoop(node: QueryNode, s: Seams): Null<Mapping> {
		if (node.kind != s.arrayLiteralKind || node.children.length != 1) return null;
		final loop: QueryNode = node.children[0];
		final binder: Null<String> = loop.name;
		if (!s.iterationKinds.contains(loop.kind) || binder == null || loop.children.exists(c -> s.valueBinderKinds.contains(c.kind)))
			return null;
		final operands: Array<QueryNode> = BinderScan.loopOperands(loop, s.valueBinderKinds);
		if (operands.length != 2 || !s.operandKinds.contains(operands[0].kind)) return null;
		final iterableSpan: Null<Span> = operands[0].span;
		final bodySpan: Null<Span> = operands[1].span;
		return iterableSpan == null || bodySpan == null ? null : {
			iterable: operands[0],
			body: operands[1],
			binder: binder,
			iterableSpan: iterableSpan,
			bodySpan: bodySpan
		};
	}

	/** The partial application the body is when it is one call taking the binder as one bare argument and `bind` is proven. */
	private static function boundMapper(m: Mapping, bind: Null<(QueryNode, Int) -> Null<String>>, source: String, s: Seams): Null<String> {
		final call: QueryNode = m.body;
		if (bind == null || call.kind != s.callKind || CheckScan.hasCommentMarker(source, m.bodySpan.from, m.bodySpan.to)) return null;
		var free: Int = -1;
		for (i in 1...call.children.length) {
			final arg: QueryNode = call.children[i];
			if (arg.kind != s.identKind || arg.name != m.binder) continue;
			if (free >= 0) return null;
			free = i - 1;
		}
		return free < 0 ? null : bind(call, free);
	}

	/** `x -> body` when the body is one value expression reading the binder. */
	private static function lambdaMapper(m: Mapping, source: String, s: Seams): Null<String> {
		return !s.lambdaForm
			|| isBinder(m.body, m.binder, s)
			|| !readsName(m.body, m.binder, s)
			|| leavesValue(m.body, m.binder, s)
			|| BinderScan.boundNames(m.body, s.shape).contains(m.binder)
			? null
			: '${m.binder} -> ${source.substring(m.bodySpan.from, m.bodySpan.to)}';
	}

	/** Whether `node` is the bare binder, parentheses peeled. */
	private static function isBinder(node: QueryNode, binder: String, s: Seams): Bool {
		var n: QueryNode = node;
		while (n.kind == s.parenKind && n.children.length == 1) n = n.children[0];
		return n.kind == s.identKind && n.name == binder;
	}

	private static function readsName(node: QueryNode, name: String, s: Seams): Bool {
		return ((node.kind == s.identKind || node.kind == s.interpIdentKind) && node.name == name)
			|| node.children.exists(c -> readsName(c, name, s));
	}

	/**
	 * Whether anything under `node` is not part of one value expression, or would act differently in a closure: control
	 * flow or a declaration, a filtering `if`, `super`, a write to the binder.
	 */
	private static function leavesValue(node: QueryNode, binder: String, s: Seams): Bool {
		final isIdent: Bool = node.kind == s.identKind;
		return s.leavingKinds.contains(node.kind)
			|| (s.ifExpressionKinds.contains(node.kind) && !BranchChain.hasElse(node))
			|| (isIdent && node.name == s.superText)
			|| (s.writeKinds.contains(node.kind) && node.children.length > 0 && isBinder(node.children[0], binder, s))
			|| node.children.exists(c -> leavesValue(c, binder, s));
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
		// Without the statement-list kinds a block body cannot be told from a value, so the lambda spelling is off.
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		final single: Array<Null<String>> = [
			shape.blockStmtKind,
			shape.blockBodyKind,
			shape.whileStmtKind,
			shape.whileExprKind,
			shape.forStmtKind,
			shape.fnExprKind,
			shape.namedFnExprKind,
			shape.mapLiteralEntryKind
		];
		final leaving: Array<String> = [for (k in single) if (k != null) k];
		final lists: Array<Null<Array<String>>> = [
			blockKinds,
			iterationKinds,
			shape.localDeclKinds,
			shape.localDeclExprKinds,
			shape.staticLocalDeclKinds,
			shape.loopStatementKinds,
			shape.doWhileLoopKinds,
			shape.ifStatementKinds,
			shape.tryStatementKinds,
			shape.tryExpressionKinds,
			shape.controlExitKinds,
			shape.localFunctionKinds,
			shape.inlineFunctionKinds,
			shape.conditionalRegionKinds,
			shape.opaqueKinds
		];
		for (list in lists) for (k in list ?? []) leaving.push(k);
		return {
			arrayLiteralKind: arrayKind,
			callKind: callKind,
			identKind: shape.identKind,
			parenKind: shape.parenKind,
			arrayTypeNames: arrayTypes,
			iterationKinds: iterationKinds,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			operandKinds: operandKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			shape: shape,
			lambdaForm: blockKinds.length > 0,
			leavingKinds: leaving,
			ifExpressionKinds: shape.ifExpressionKinds ?? [],
			writeKinds: shape.writeParentKinds,
			superText: shape.superReferenceText,
			interpIdentKind: shape.stringInterpIdentKind
		};
	}

	/** Whether the text the rewrite drops around the iterable and the body — `[for (x in `, `) `, `]` — holds no comment. */
	private static function gapsHoldNoComment(m: Mapping, whole: Span, source: String): Bool {
		return !CheckScan.hasCommentMarker(source, whole.from, m.iterableSpan.from)
			&& !CheckScan.hasCommentMarker(source, m.iterableSpan.to, m.bodySpan.from)
			&& !CheckScan.hasCommentMarker(source, m.bodySpan.to, whole.to);
	}

}

/** One `[for (x in xs) body]`: the iterable, the loop binder and the body, with the spans the rewrite splices. */
private typedef Mapping = {
	final iterable: QueryNode;
	final body: QueryNode;
	final binder: String;
	final iterableSpan: Span;
	final bodySpan: Span;
};

/** The resolved seams `PreferMap` reads in both `run` and `fix`. */
private typedef Seams = {

	final arrayLiteralKind: String;
	final callKind: String;
	final identKind: String;
	final parenKind: Null<String>;
	final arrayTypeNames: Array<String>;
	final iterationKinds: Array<String>;
	final valueBinderKinds: Array<String>;
	final operandKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final shape: RefShape;

	/** Whether the lambda spelling is available: the grammar names its statement lists, so a block body is recognisable. */
	final lambdaForm: Bool;

	/** The kinds a body may not contain: control flow, declarations, blocks, loops, `try`, `#if`, local functions. */
	final leavingKinds: Array<String>;
	final ifExpressionKinds: Array<String>;
	final writeKinds: Array<String>;
	final superText: Null<String>;

	/** The identifier node a bare `$x` interpolation projects as. */
	final interpIdentKind: Null<String>;

};
