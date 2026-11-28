package anyparse.check.haxe.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.common.control.BranchChain;
import anyparse.check.common.expressions.PreferBind;
import anyparse.check.haxe.loops.MappedComprehension.ComprehensionSeams;
import anyparse.check.haxe.loops.MappedComprehension.Mapping;
import anyparse.check.scan.OperandBinder;
import anyparse.query.BinderScan;
import anyparse.query.Constructs;
import anyparse.query.LexicalRegions;
import anyparse.query.NominalTypes;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;

using StringTools;

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
	final checkTypeKind: Null<String>;

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
 * of its name, `super` (a closure cannot call it), a body that never reads the binder, a bare `x`
 * or an ascribed `(x : T)` (a copy, `identity-map`'s), a key-value binder, a map entry body and
 * a comprehension whose dropped punctuation carries a comment. The iterable must be an `Array`
 * (`RefShape.arrayTypeNames`): another collection's `map` returns that collection, and an iterator has none. It must be a
 * postfix operand as written — an identifier, a member, a call, an index or a parenthesis — since the rewrite appends
 * `.map` to its text. Equivalence assumes the body does not resize the very array it is mapped over, and `o.m.bind(a)`
 * reads `o.m` even when the array is empty.
 *
 * A comprehension takes its element type from where it is written (`final ys: Array<Base> = [for (x in xs) new Sub()]`),
 * and `map` takes the body's own type, which an invariant `Array` then refuses. So a comprehension in a position that
 * writes an expected type is flagged only where that type is an `Array` of the one plain type name the body has
 * (`OperandBinder.expectedTypeOf`); an expectation the rule cannot prove equal, an object literal, a ternary or a
 * subclass included, is left alone with no finding. That includes a body whose type `CheckScan.typeNominalResolver`
 * cannot name (a call of a local function) and an expected element that is not one plain type name (`Null<T>`, a generic),
 * though `map` would compile there: a recall loss, never a wrong edit. A callee that declares a parameter the call leaves out is never
 * spelled bare or `bind`: the parameter stays in its function type.
 *
 * `RiskyFix`: a closure also loses the null-safety narrowing of a mutable local it captures. With a compiler oracle the
 * rewrite stands where it compiles; without one the rule is report-only. `DefaultOff`: a style preference, opted in with
 * `"prefer-map": { "enabled": true }`.
 */
@:nullSafety(Strict)
final class PreferMap extends HaxeRule implements DefaultOff implements RiskyFix implements VolatileMessage {

	private static inline final RULE_ID: String = 'prefer-map';

	/** The longest rewrite a finding's message quotes before it is cut. */
	private static inline final MESSAGE_EXCERPT_MAX: Int = 80;

	/** The lead-in of a finding's message; the rewrite it quotes follows, and `messageIdentity` masks that tail. */
	private static final MESSAGE_LEAD: String = 'this comprehension maps each element — it can be ';

	/** The method the rewrite calls on the array. */
	private static final MAP_METHOD: String = 'map';

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
		final build: Null<Constructs> = plugin.constructs();
		final regions: () -> Array<LexRegion> = ElementSpan.lazyRegions(source, plugin);
		var bind: Null<(QueryNode, Int) -> Null<String>> = null;
		var nominal: Null<(QueryNode) -> Null<String>> = null;
		var built: Bool = false;
		var keeps: Null<(QueryNode, QueryNode) -> Bool> = null;
		function walk(node: QueryNode): Void {
			if (seams.opaqueKinds.contains(node.kind)) return;
			final head: Null<Mapping> = MappedComprehension.of(node, seams);
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
				final mapped: Null<Built> = type != null && seams.arrayTypeNames.contains(type) && gapsHoldNoComment(head, at, regions)
					? mapCall(build, source, head, bind, regions, seams)
					: null;
				if (mapped != null) {
					final holds: (QueryNode, QueryNode) -> Bool = keeps ?? (keeps = elementProof(source, plugin, tree, file, index));
					if (holds(node, head.body)) {
						out.push({ span: at, text: mapped.text });
						return;
					}
				}
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** The partial application the body is when it is one call taking the binder as one bare argument and `bind` is proven. */
	private static function boundMapper(
		m: Mapping, bind: Null<(QueryNode, Int) -> Null<String>>, regions: () -> Array<LexRegion>, s: Seams, build: Constructs
	): Null<Built> {
		final call: QueryNode = m.body;
		if (bind == null || call.kind != s.callKind || LexicalRegions.commentIntersects(m.bodySpan.from, m.bodySpan.to, regions()))
			return null;
		var free: Int = -1;
		for (i in 1...call.children.length) {
			final arg: QueryNode = call.children[i];
			if (arg.kind != s.identKind || arg.name != m.binder) continue;
			if (free >= 0) return null;
			free = i - 1;
		}
		final bound: Null<String> = free < 0 ? null : bind(call, free);
		return bound == null ? null : build.copied(bound, new Span(0, bound.length), Expression);
	}

	/** `x -> body` when the body is one value expression reading the binder. */
	private static function lambdaMapper(m: Mapping, source: String, s: Seams, build: Constructs): Null<Built> {
		if (
			!s.lambdaForm
			|| MappedComprehension.isBinder(m.body, m.binder, s)
			|| isAscribedBinder(m.body, m.binder, s)
			|| !readsName(m.body, m.binder, s)
			|| leavesValue(m.body, m.binder, s)
			|| BinderScan.boundNames(m.body, s.shape).contains(m.binder)
		)
			return null;
		final body: Null<Built> = build.copied(source, m.bodySpan, Expression);
		return body == null ? null : build.lambda([m.binder], body);
	}

	/**
	 * The `map` call the comprehension `m` folds into, mapping by the partial application
	 * of its body or else by a lambda; built by the grammar, null when it builds none.
	 */
	private static function mapCall(
		build: Null<Constructs>, source: String, m: Mapping, bind: Null<(QueryNode, Int) -> Null<String>>, regions: () -> Array<LexRegion>,
		s: Seams
	): Null<Built> {
		if (build == null) return null;
		final mapper: Null<Built> = boundMapper(m, bind, regions, s, build) ?? lambdaMapper(m, source, s, build);
		final iterable: Null<Built> = mapper == null ? null : build.copied(source, m.iterableSpan, Expression);
		final callee: Null<Built> = iterable == null ? null : build.qualified(iterable, MAP_METHOD);
		return callee == null || mapper == null ? null : build.call(callee, [mapper]);
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
			|| (s.writeKinds.contains(node.kind) && node.children.length > 0 && MappedComprehension.isBinder(node.children[0], binder, s))
			|| node.children.exists(c -> leavesValue(c, binder, s));
	}

	/** The seams the rule reads, or null when one it cannot do without is unset. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final comprehension: Null<ComprehensionSeams> = MappedComprehension.seamsOf(shape);
		final callKind: Null<String> = shape.callKind;
		final arrayTypes: Null<Array<String>> = shape.arrayTypeNames;
		if (comprehension == null || callKind == null || arrayTypes == null) return null;
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
		final leaving: Array<String> = [ for (k in single) if (k != null) k ];
		final lists: Array<Null<Array<String>>> = [
			blockKinds,
			comprehension.iterationKinds,
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
		for (list in lists) if (list != null) for (k in list) leaving.push(k);
		return {
			arrayLiteralKind: comprehension.arrayLiteralKind,
			callKind: callKind,
			identKind: comprehension.identKind,
			parenKind: comprehension.parenKind,
			arrayTypeNames: arrayTypes,
			iterationKinds: comprehension.iterationKinds,
			valueBinderKinds: comprehension.valueBinderKinds,
			operandKinds: comprehension.operandKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			shape: shape,
			checkTypeKind: shape.checkTypeKind,
			lambdaForm: blockKinds.length > 0,
			leavingKinds: leaving,
			ifExpressionKinds: shape.ifExpressionKinds ?? [],
			writeKinds: shape.writeParentKinds,
			superText: shape.superReferenceText,
			interpIdentKind: shape.stringInterpIdentKind
		};
	}

	/** Whether the text the rewrite drops around the iterable and the body — `[for (x in `, `) `, `]` — holds no comment. */
	private static function gapsHoldNoComment(m: Mapping, whole: Span, regions: () -> Array<LexRegion>): Bool {
		return !CheckScan.regionHoldsComment(regions, whole, [m.iterableSpan, m.bodySpan]);
	}

	/** Whether `node` is the binder under a type ascription, `(x : T)` — the copy that `identity-map` reads. */
	private static function isAscribedBinder(node: QueryNode, binder: String, s: Seams): Bool {
		return node.kind == s.checkTypeKind && node.children.length == 1 && MappedComprehension.isBinder(node.children[0], binder, s);
	}

	/**
	 * Whether `xs.map(...)` types the elements as the comprehension does where it is written. A comprehension takes the type
	 * expected of its position into its body (a subclass element, an object literal leaving out optional fields); the lambda of
	 * `map` infers its result alone, and an invariant `Array` then refuses it. The answer is yes where nothing written fixes the
	 * position's type, and where the expected `Array` holds one plain type name that is the body's own type; else no.
	 */
	private static function elementProof(
		source: String, plugin: GrammarPlugin, tree: QueryNode, file: String, index: String -> Null<SymbolIndex>
	): (QueryNode, QueryNode) -> Bool {
		final scope: Null<SymbolIndex> = index(file);
		final binder: Null<OperandBinder> = scope == null ? null : OperandBinder.forFile(plugin, file, source, tree, scope);
		final bodyType: Null<(QueryNode) -> Null<String>> = scope == null
			? null
			: CheckScan.typeNominalResolver(source, plugin, tree, file, scope);
		if (scope == null || binder == null || bodyType == null) return (_, _) -> true;
		final arrayNames: Array<String> = plugin.refShape().arrayTypeNames ?? [];
		return elementCheck(binder, scope, bodyType, arrayNames);
	}

	/** The one plain type name `text` holds as the element of the standard `Array`; null for any other type. */
	private static function arrayElementName(text: String, arrayNames: Array<String>, index: SymbolIndex): Null<String> {
		return switch index.typeSyntax(text.trim())?.shape {
			case Nominal(path, [element]) if (arrayNames.contains(path) && !NominalTypes.shadowedByNonStdType(index, path)):
				switch element.shape {
					case Nominal(name, []): name;
					case _: null;
				}
			case _: null;
		}
	}

	/** `elementProof`'s answer once the binder and the index it asks are known. */
	private static function elementCheck(
		binder: OperandBinder, scope: SymbolIndex, bodyType: (QueryNode) -> Null<String>, arrayNames: Array<String>
	): (QueryNode, QueryNode) -> Bool {
		return (literal, body) -> {
			final expected: Null<Located> = binder.expectedTypeOf(literal);
			if (expected == null) return true;
			final element: Null<String> = arrayElementName(expected.text, arrayNames, scope);
			return element != null && element == bodyType(body);
		};
	}

}
