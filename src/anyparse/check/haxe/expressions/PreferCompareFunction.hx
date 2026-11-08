package anyparse.check.haxe.expressions;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.Supersedes;
import anyparse.check.common.control.BranchChain;
import anyparse.check.haxe.expressions.CompareFunctions.NamedCompare;
import anyparse.check.scan.IfExpressionChain;
import anyparse.check.scan.PurityScan;
import anyparse.check.scan.RunScan;
import anyparse.query.DeclaredNullity;
import anyparse.query.IndexScope;
import anyparse.query.ParseGate;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeResolver;
import anyparse.query.TypingService;

using StringTools;

/**
 * Flags a sort callback that spells a three-way comparison of two values by hand, or uses `Reflect.compare` where the project
 * names a typed function for the operand type. `Severity.Info`, with an autofix.
 *
 *     xs.sort((a, b) -> a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
 *     // -> xs.sort((a, b) -> Reflect.compare(a.path, b.path));
 *     xs.sort((a: Int, b: Int) -> a < b ? -1 : a > b ? 1 : 0);
 *     // -> xs.sort(Reflect.compare);
 *
 * The forms are the ternary chain, the if-expression chain, and the statement chain closing a function body. A descending chain
 * is the ascending one with its operands swapped, so the fix swaps them. A chain of two proved operands, Int or String, in the
 * order of the callback's plain parameters and nothing else in its body is rewritten to the function itself.
 *
 * ## What a site must be
 *
 * - **A sort callback.** The function literal, of two parameters, is an argument of a call named `sort`: only the SIGN of a
 *   comparator's result is read there, and `Reflect.compare` promises a sign, not `-1` / `1`.
 * - **Two strict comparisons of the SAME two operands in opposite directions**, valued `-1` and `1` in either order, and `0`
 *   for the rest.
 * - **Both operands `Int`, or both `String`.** A `Float` operand is out: a `NaN` makes the chain answer `0` where
 *   `Reflect.compare` answers a sign. An operand of unknown type stays silent.
 * - **Pure operands**, since the chain reads each twice and the call once, and **no comment in the replaced text**.
 *
 * ## Where the fix is offered
 *
 * On `null`, `Reflect.compare` answers `-1` in both argument orders where the chain answers `0`, so the fix is offered only where
 * both operands are proved non-null by `TypeResolver.isProvablyNonNull`; any other site is reported without a fix.
 *
 * ## Option
 *
 * `compare` names the project's functions by operand type, `{ "Int": "a.b.C.fn", "String": "a.b.C.fn" }`. A named one takes the
 * place of `Reflect.compare` in every rewrite, with its import, and an existing `Reflect.compare` or `inline Reflect.compare` in a
 * sort callback, or passed bare to a receiver of a proved element type, moves to it; a call the callback does not return
 * is reported without a fix, since only the sign of the result is read. A name the resolution index cannot find, or
 * whose signature is not `(T, T): Int`, is a configuration error that stops the rule on the files it governs (`CompareFunctions`).
 */
@:nullSafety(Strict)
final class PreferCompareFunction extends HaxeRule implements DefaultOff implements Supersedes implements ConfigAware implements GroupedFix {

	private static inline final RULE_ID: String = 'prefer-compare-function';

	/** The method whose callback is read for its sign only. */
	private static inline final SORT: String = 'sort';

	private static inline final REFLECT: String = 'Reflect';
	private static inline final COMPARE_MEMBER: String = 'compare';
	private static inline final COMPARE: String = '$REFLECT.$COMPARE_MEMBER';

	/** The node a call-site `inline` projects as. */
	private static inline final INLINE_EXPR: String = 'InlineExpr';

	/** The option naming the project's compare functions by operand type. */
	private static inline final OPTION_COMPARE: String = 'compare';

	private static inline final MAY_BE_NULL: String = 'an operand may be null and the call then answers differently';
	private static inline final NOT_RETURNED: String =
		'the callback does not return this call, so its value may be read for more than a sign';

	/** A `Reflect.compare` call's children: its callee and two operands. */
	private static inline final OPERANDS_CALL: Int = 3;

	private static inline final LESS: String = 'lt';
	private static inline final GREATER: String = 'gt';

	/** A callback of this many parameters is a comparator. */
	private static inline final COMPARATOR_PARAMS: Int = 2;

	/** A chain of this many comparisons, then a terminal value, is a three-way comparison. */
	private static inline final RUNGS: Int = 2;

	private static inline final ASCENDING: String = '-1';
	private static inline final DESCENDING: String = '1';
	private static inline final EQUAL: String = '0';

	/** The linter's per-file config resolver (`compare`), or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID,
			'a sort callback spelling a three-way comparison by hand, or using Reflect.compare where the project names a typed function',
			RuleCategory.Expressions
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final problems: Array<ConfigProblem> = [];
		final found: Array<Violation> = RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, out) -> {
			final named: CompareFunctions = compareFunctionsOf(entry.file, plugin, seams, index);
			final enabled: Bool = Linter.enabledBy(LintConfig.resolveWith(_resolveConfig, entry.file), this);
			for (problem in named.problems) anchorProblem(problems, problem, entry.file, enabled);
			// A broken name stops the rule on the files it governs: a fix would otherwise write another function than the project named.
			if (named.problems.length > 0) return;
			for (m in matches(tree, entry.file, entry.source, seams, plugin, index, named)) out.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: m.message + (m.noFix == null ? '' : '; no fix, ${m.noFix}'),
				remedy: m.compare?.typePath
			});
		});
		for (problem in problems) found.push({
			file: problem.file,
			span: null,
			rule: RULE_ID,
			severity: Severity.Error,
			message: problem.message
		});
		return found;
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return fixGrouped(source, violations, plugin, index).map(edit -> {span: edit.span, text: edit.text });
	}

	/** An `import` and the rewrites that need it are kept or dropped together. */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		// A configuration error has no site to fix: said here, or `--fix`, which lists no findings, would never mention it.
		for (v in violations) if (v.span == null) v.declineReason = v.message;
		final sites: Array<Violation> = violations.filter(v -> v.span != null);
		if (seams == null || sites.length == 0) return [];
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final file: String = RunScan.oneFile(sites, RULE_ID);
		final scope: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		final named: CompareFunctions = compareFunctionsOf(file, plugin, seams, scope);
		if (named.problems.length > 0) return [];
		final wanted: Array<String> = sites.map(v -> spanKey(v.span));
		final fixed: Array<Match> = matches(
			tree, file, source, seams, plugin, scope, named
		).filter(m -> m.noFix == null && wanted.contains(spanKey(m.span)));
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(
			file, source, tree, RunScan.typeInfoOf(plugin)?.importMap(source, file) ?? [], plugin, scope()
		);
		final texts: Array<String> = fixed.map(replacementOf.bind(_, printer));
		final imports: Array<PendingImportEdit> = printer.pendingImportEdits();
		final groupOf: Map<String, Int> = [];
		for (group => edit in imports) for (path in edit.paths) groupOf[path] = group;
		final edits: Array<GroupedEdit> = [
			for (i => m in fixed) {
				final path: Null<String> = m.compare?.typePath;
				{ span: m.replaced, text: texts[i], group: path == null ? null : groupOf[path] };
			}
		];
		for (group => edit in imports) edits.push({ span: edit.span, text: edit.text, group: group });
		return edits;
	}

	public function supersedes(): Array<String> {
		return [
			'prefer-if-expression-chain',
			'prefer-if-expression-return',
			'redundant-lambda-wrapper'
		];
	}

	private function compareFunctionsOf(file: String, plugin: GrammarPlugin, s: Seams, index: () -> Null<SymbolIndex>): CompareFunctions {
		return new CompareFunctions(
			LintConfig.resolveWith(_resolveConfig, file).jsonOption(RULE_ID, OPTION_COMPARE), OPTION_COMPARE, [s.intType, s.stringType],
			s.intType, plugin.typeSyntax, index
		);
	}

	/** Every hand-written comparison in a sort callback under `tree`, and every call of `Reflect.compare` a named function replaces. */
	private static function matches(
		tree: QueryNode, file: String, source: String, seams: Seams, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>,
		named: CompareFunctions
	): Array<Match> {
		final out: Array<Match> = [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		var typed: Null<Typed> = null;
		var built: Bool = false;
		function typing(): Null<Typed> {
			if (!built) {
				built = true;
				final idx: Null<SymbolIndex> = index();
				final purity: Null<PurityCtx> = idx == null ? null : PurityScan.contextOf(plugin, source, tree, idx);
				final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, idx);
				final written: Null<(QueryNode) -> Null<String>> = CheckScan.typeSourceResolver(source, plugin, tree, file, idx);
				final nullity: DeclaredNullity = DeclaredNullity.of(
					file, tree, source, seams.shape, RunScan.typeInfoOf(plugin), plugin.typeSyntax, index
				);
				typed = purity == null || nominal == null || written == null ? null : {
					purity: purity,
					nominal: nominal,
					element: elementResolver(written, seams, plugin),
					nonNull: operand -> TypeResolver.isProvablyNonNull(operand, tree, seams.shape, nullity),
					elementNonNull: elementProof(tree, seams),
					isStdReflect: type -> !NominalTypes.shadowedByNonStdType(idx, REFLECT) && !isBoundHere(type, tree, seams)
				};
			}
			return typed;
		}
		function walk(node: QueryNode): Void {
			final callee: Null<QueryNode> = node.children[0];
			if (
				node.kind == seams.callKind && callee != null && callee.kind == seams.fieldAccessKind && callee.name == SORT
			) for (arg in node.children) {
				if (isComparator(arg, seams))
					fromCallback(arg, source, seams, typing, comments, named, out);
				else if (!named.isEmpty() && isReflectCompare(arg, seams))
					fromBareReference(callee, arg, typing, named, out);
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	private static function isComparator(node: QueryNode, s: Seams): Bool {
		return s.lambdaKinds.contains(node.kind) && node.children.count(c -> s.paramKinds.contains(c.kind)) == COMPARATOR_PARAMS;
	}

	/** The comparisons a callback's body holds: its value, a returned value, or the statements closing it. */
	private static function fromCallback(
		fn: QueryNode, source: String, s: Seams, typing: () -> Null<Typed>, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		named: CompareFunctions, out: Array<Match>
	): Void {
		final body: Null<QueryNode> = fn.children[fn.children.length - 1];
		if (body == null) return;
		final chains: Array<Chain> = [];
		var sole: Null<QueryNode> = null;
		if (s.blockKinds.contains(body.kind)) {
			final stmts: Array<QueryNode> = body.children;
			final alone: Bool = stmts.length == 1;
			for (st in stmts) {
				final value: Null<QueryNode> = returnValue(st, s);
				if (value == null) continue;
				addIfSome(chains, valueChain(value, s), alone);
				if (alone) sole = value;
			}
			final last: Null<QueryNode> = stmts[stmts.length - 1];
			if (last != null) {
				final statements: Bool = s.ifStatementKinds.contains(last.kind);
				addIfSome(
					chains, statements ? statementChain(last, s) : sequentialChain(stmts, s),
					statements ? alone : stmts.length == RUNGS + 1
				);
			}
		} else {
			final inner: QueryNode = s.expressionBodyKinds.contains(body.kind) && body.children.length == 1 ? body.children[0] : body;
			sole = returnValue(inner, s) ?? inner;
			addIfSome(chains, valueChain(sole ?? inner, s), true);
		}
		for (chain in chains) {
			final called: Null<Called> = comparison(chain, source, s, typing);
			final extent: Span = IfExpressionChain.tokenSpan(chain.extent, source, comments);
			if (called == null) continue;
			final found: Match = matched(fn, chain, extent, called, named.of(called.type), source, s);
			if (!CheckScan.hasCommentMarker(source, found.replaced.from, found.replaced.to)) out.push(found);
		}
		final t: Null<Typed> = named.isEmpty() ? null : typing();
		if (t != null) movedCalls(body, fn, sole == null ? null : peeled(sole, s), returnedValues(body, sole, s), source, s, t, named, out);
	}

	/** The finding of a hand-written chain: the whole function when it is nothing but the comparison of its parameters in order. */
	private static function matched(
		fn: QueryNode, chain: Chain, extent: Span, called: Called, compare: Null<NamedCompare>, source: String, s: Seams
	): Match {
		final whole: Null<Span> = chain.whole && comparesParameters(fn, called.left, called.right, s) ? fn.span : null;
		final left: String = textOf(called.left, source);
		final right: String = textOf(called.right, source);
		return {
			span: extent,
			replaced: whole ?? extent,
			compare: compare,
			operands: whole == null ? { left: left, right: right } : null,
			message: 'this sort callback spells ${shortName(compare)}($left, $right) by hand',
			noFix: called.nonNull ? null : MAY_BE_NULL,
			asReturn: chain.asReturn
		};
	}

	private static function rung(cond: QueryNode, value: QueryNode): Rung {
		return { cond: cond, value: value };
	}

	private static function addIfSome(chains: Array<Chain>, chain: Null<Chain>, whole: Bool): Void {
		if (chain == null) return;
		chain.whole = whole;
		chains.push(chain);
	}

	/**
	 * The ternary or if-expression chain `node` is, parentheses peeled at the head and at every `else`. It stays beside
	 * `IfExpressionChain.unrollTernaryTail`, which unrolls ternary links only and leaves an `else` link's parentheses.
	 */
	private static function valueChain(node: QueryNode, s: Seams): Null<Chain> {
		final rungs: Array<Rung> = [];
		final head: QueryNode = BoolExprShape.unwrapParens(node, s.parenKind);
		var at: QueryNode = head;
		while ((at.kind == s.ternaryKind || s.ifExpressionKinds.contains(at.kind)) && BranchChain.hasElse(at)) {
			rungs.push(rung(BranchChain.condOf(at), BranchChain.thenOf(at)));
			at = BoolExprShape.unwrapParens(BranchChain.elseBranch(at), s.parenKind);
		}
		return chained(head, rungs, at);
	}

	/** An `if (…) return v; else if (…) return v; else return v;` chain. */
	private static function statementChain(node: QueryNode, s: Seams): Null<Chain> {
		final found: Null<IfChain> = IfExpressionChain.collect(node, s.ifStatementKinds, s.blockStmtKind, RUNGS);
		final extent: Null<Span> = node.span;
		return found == null || extent == null ? null : returning(found, extent, s);
	}

	/** `if (…) return v; if (…) return v; return v;` closing a block. */
	private static function sequentialChain(stmts: Array<QueryNode>, s: Seams): Null<Chain> {
		final n: Int = stmts.length;
		if (n < RUNGS + 1) return null;
		final found: Null<IfChain> = IfExpressionChain.collectCascade(stmts, n - RUNGS - 1, s.ifStatementKinds, s.blockStmtKind, RUNGS);
		final from: Null<Span> = stmts[n - RUNGS - 1].span;
		final to: Null<Span> = stmts[n - 1].span;
		return found == null || from == null || to == null ? null : returning(found, new Span(from.from, to.to), s);
	}

	/** The chain `found` is when it is exactly two rungs and a terminal that each return a value. */
	private static function returning(found: IfChain, extent: Span, s: Seams): Null<Chain> {
		if (found.branches.length != RUNGS) return null;
		final first: Null<QueryNode> = returnValue(found.branches[0].stmt, s);
		final second: Null<QueryNode> = returnValue(found.branches[1].stmt, s);
		final terminal: Null<QueryNode> = returnValue(found.terminal, s);
		return first == null || second == null || terminal == null ? null : {
			rungs: [rung(found.branches[0].cond, first), rung(found.branches[1].cond, second)],
			terminal: terminal,
			extent: extent,
			asReturn: true,
			whole: false
		};
	}

	/** The value a `return v;` statement returns. */
	private static function returnValue(node: QueryNode, s: Seams): Null<QueryNode> {
		return s.returnKinds.contains(node.kind) && node.children.length == 1 ? node.children[0] : null;
	}

	/**
	 * The `Reflect.compare(…)` call the chain computes, or null when it computes something else or cannot be proved to. It
	 * answers `nonNull` only when both operands are proved non-null: on `null` the call answers `-1` in both argument
	 * orders where the chain answers `0`, so a rewrite there changes an answer.
	 */
	private static function comparison(chain: Chain, source: String, s: Seams, typing: () -> Null<Typed>): Null<Called> {
		final first: Null<Order> = order(chain.rungs[0].cond, s);
		final second: Null<Order> = order(chain.rungs[1].cond, s);
		final v1: String = valueText(chain.rungs[0].value, source, s);
		final v2: String = valueText(chain.rungs[1].value, source, s);
		if (first == null || second == null) return null;
		if (
			valueText(chain.terminal, source, s) != EQUAL
			|| ((v1 != ASCENDING || v2 != DESCENDING) && (v1 != DESCENDING || v2 != ASCENDING))
			|| !IfExpressionChain.sameSource(first.smallNode, second.bigNode, source)
			|| !IfExpressionChain.sameSource(first.bigNode, second.smallNode, source)
		)
			return null;
		final t: Null<Typed> = typing();
		if (t == null) return null;
		final left: QueryNode = v1 == ASCENDING ? first.smallNode : first.bigNode;
		final right: QueryNode = v1 == ASCENDING ? first.bigNode : first.smallNode;
		final type: Null<String> = t.nominal(left);
		return type != null
			&& (type == s.intType || type == s.stringType)
			&& t.nominal(right) == type
			&& PurityScan.isPure(left, t.purity)
			&& PurityScan.isPure(right, t.purity)
			? {
				type: type,
				left: left,
				right: right,
				nonNull: t.nonNull(left) && t.nonNull(right)
			}
			: null;
	}

	/** The two operands of a strict comparison, the smaller first. */
	private static function order(cond: QueryNode, s: Seams): Null<Order> {
		final node: QueryNode = BoolExprShape.unwrapParens(cond, s.parenKind);
		if (node.children.length != 2) return null;
		final lhs: QueryNode = node.children[0];
		final rhs: QueryNode = node.children[1];
		final ascending: Bool = node.kind == s.ltKind;
		return !ascending && node.kind != s.gtKind ? null : { smallNode: ascending ? lhs : rhs, bigNode: ascending ? rhs : lhs };
	}

	/** An integer literal's text, spaces dropped; empty for anything else. */
	private static function valueText(node: QueryNode, source: String, s: Seams): String {
		return s.valueKinds.contains(node.kind) ? textOf(node, source).split(' ').join('') : '';
	}

	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final lt: Null<String> = orderedKind(shape, LESS);
		final gt: Null<String> = orderedKind(shape, GREATER);
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final ternaryKind: Null<String> = shape.ternaryKind;
		final ifStatementKinds: Null<Array<String>> = shape.ifStatementKinds;
		final returnKinds: Null<Array<String>> = shape.valueReturnKinds;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final intType: Null<String> = shape.coreValueTypes?.integer;
		final stringType: Null<String> = TypingService.stringType(shape);
		return lt == null
			|| gt == null
			|| callKind == null
			|| fieldAccessKind == null
			|| ternaryKind == null
			|| ifStatementKinds == null
			|| returnKinds == null
			|| lambdaKinds == null
			|| paramKinds == null
			|| blockKinds.length == 0
			|| blockStmtKind == null
			|| intType == null
			|| stringType == null
			? null
			: {
				ltKind: lt,
				gtKind: gt,
				callKind: callKind,
				fieldAccessKind: fieldAccessKind,
				ternaryKind: ternaryKind,
				ifExpressionKinds: shape.ifExpressionKinds ?? [],
				ifStatementKinds: ifStatementKinds,
				returnKinds: returnKinds,
				expressionBodyKinds: shape.expressionBodyKinds ?? [],
				lambdaKinds: lambdaKinds,
				paramKinds: paramKinds,
				nestedFunctionKinds: lambdaKinds.concat(shape.localFunctionKinds ?? []),
				identKind: shape.identKind,
				blockKinds: blockKinds,
				blockStmtKind: blockStmtKind,
				shape: shape,
				parenKind: shape.parenKind,
				valueKinds: (shape.numericLiteralKinds ?? []).concat(shape.unaryMinusKinds ?? []),
				intType: intType,
				stringType: stringType
			};
	}

	/** The chain `host` spells, when it is exactly the comparisons of a three-way comparison. */
	private static function chained(host: QueryNode, rungs: Array<Rung>, terminal: QueryNode): Null<Chain> {
		final extent: Null<Span> = host.span;
		return extent == null || rungs.length != RUNGS ? null : {
			rungs: rungs,
			terminal: terminal,
			extent: extent,
			asReturn: false,
			whole: false
		};
	}

	/** The kind of the ordered comparison `op` (`lt`, `gt`), by the grammar's own naming. */
	private static function orderedKind(shape: RefShape, op: String): Null<String> {
		final ordered: Null<Map<String, String>> = shape.execution?.orderedComparisonOperators;
		return ordered == null ? null : [for (kind => named in ordered) if (named == op) kind][0];
	}

	/** What a fix writes for `m`: the function alone, the call of it, or the `return` of that call in place of statements. */
	private static function replacementOf(m: Match, printer: TypeRefPrinter): String {
		final compare: Null<NamedCompare> = m.compare;
		final fn: String = compare == null ? COMPARE : '${printer.printTypeExpr(compare.typePath, m.replaced.from)}.${compare.member}';
		final operands: Null<Operands> = m.operands;
		if (operands == null) return fn;
		final call: String = '$fn(${operands.left}, ${operands.right})';
		return m.asReturn ? 'return $call;' : call;
	}

	/** The name a finding's message gives the function. */
	private static function shortName(compare: Null<NamedCompare>): String {
		return compare == null ? COMPARE : '${SourceText.lastSegment(compare.typePath)}.${compare.member}';
	}

	/** `xs.sort(Reflect.compare)`, where the element type of `xs` is proved and a function is named for it. */
	private static function fromBareReference(
		callee: QueryNode, reference: QueryNode, typing: () -> Null<Typed>, named: CompareFunctions, out: Array<Match>
	): Void {
		final t: Null<Typed> = typing();
		final receiver: Null<QueryNode> = callee.children[0];
		final span: Null<Span> = reference.span;
		if (t == null || !t.isStdReflect(reference.children[0]) || receiver == null || span == null) return;
		final type: Null<String> = t.element(receiver);
		final compare: Null<NamedCompare> = named.of(type);
		if (type != null && compare != null) out.push(moved(span, compare, null, t.elementNonNull(type, span) ? null : MAY_BE_NULL));
	}

	/**
	 * Each `Reflect.compare` call or `inline Reflect.compare` call under `node`, nested functions apart, whose two operands have
	 * one proved type a function is named for. Only the sign of what the callback RETURNS is read, so a fix is offered only for
	 * a call in `results`: anywhere else its value may be read for more than a sign, which the named function need not match.
	 */
	private static function movedCalls(
		node: QueryNode, fn: QueryNode, sole: Null<QueryNode>, results: Array<QueryNode>, source: String, s: Seams, t: Typed,
		named: CompareFunctions, out: Array<Match>
	): Void {
		if (s.nestedFunctionKinds.contains(node.kind)) return;
		final call: QueryNode = peeled(node, s);
		if (!isReflectCompareCall(call, s) || !t.isStdReflect(call.children[0].children[0])) {
			for (c in node.children) movedCalls(c, fn, sole, results, source, s, t, named, out);
			return;
		}
		final left: QueryNode = call.children[1];
		final right: QueryNode = call.children[2];
		final type: Null<String> = t.nominal(left);
		final compare: Null<NamedCompare> = t.nominal(right) == type ? named.of(type) : null;
		final whole: Null<Span> = call == sole && comparesParameters(fn, left, right, s) ? fn.span : null;
		final span: Null<Span> = whole ?? node.span;
		if (compare == null || span == null) return;
		if (CheckScan.hasCommentMarker(source, span.from, span.to)) return;
		final operands: Null<Operands> = whole == null ? { left: textOf(left, source), right: textOf(right, source) } : null;
		final noFix: Null<String> = if (!results.contains(call))
			NOT_RETURNED
		else if (t.nonNull(left) && t.nonNull(right))
			null
		else
			MAY_BE_NULL;
		out.push(moved(span, compare, operands, noFix));
	}

	private static function moved(span: Span, compare: NamedCompare, operands: Null<Operands>, noFix: Null<String>): Match {
		return {
			span: span,
			replaced: span,
			compare: compare,
			operands: operands,
			message: 'this sort callback uses $COMPARE where the project names ${shortName(compare)}',
			noFix: noFix,
			asReturn: false
		};
	}

	/** `node` with its parentheses and a call-site `inline` taken off. */
	private static function peeled(node: QueryNode, s: Seams): QueryNode {
		final open: QueryNode = BoolExprShape.unwrapParens(node, s.parenKind);
		return open.kind == INLINE_EXPR && open.children.length == 1 ? open.children[0] : open;
	}

	/** The value `Reflect.compare` written without a call. */
	private static function isReflectCompare(node: QueryNode, s: Seams): Bool {
		final type: Null<QueryNode> = node.children[0];
		return node.kind == s.fieldAccessKind
			&& node.name == COMPARE_MEMBER
			&& node.children.length == 1
			&& type != null
			&& type.kind == s.identKind
			&& type.name == REFLECT;
	}

	private static function isReflectCompareCall(node: QueryNode, s: Seams): Bool {
		final callee: Null<QueryNode> = node.children[0];
		return node.kind == s.callKind && node.children.length == OPERANDS_CALL && callee != null && isReflectCompare(callee, s);
	}

	/** Whether `left` and `right` are the two plain parameters of `fn`, read in the order they are declared. */
	private static function comparesParameters(fn: QueryNode, left: QueryNode, right: QueryNode, s: Seams): Bool {
		final params: Array<QueryNode> = fn.children.filter(c -> s.paramKinds.contains(c.kind));
		return params.length == COMPARATOR_PARAMS
			&& params.foreach(p -> p.kind != s.shape.optionalParamKind && p.kind != s.shape.restParamKind && p.children.length == 0)
			&& left.kind == s.identKind
			&& right.kind == s.identKind
			&& left.name == params[0].name
			&& right.name == params[1].name;
	}

	/** The bare type name of the elements of a receiver, as `written` answers its type: `Null<T>` elements answer `Null`, never `T`. */
	private static function elementResolver(
		written: (QueryNode) -> Null<String>, s: Seams, plugin: GrammarPlugin
	): (QueryNode) -> Null<String> {
		final params: Map<String, Int> = s.shape.indexedElementTypeParams ?? [];
		return receiver -> {
			final source: Null<String> = written(receiver);
			final element: Null<String> = source == null ? null : NominalTypes.elementTypeSourceOf(source, params, [], plugin.typeSyntax);
			return element == null ? null : NominalTypes.outerNominalOf(element, plugin.typeSyntax);
		};
	}

	private static function spanKey(span: Null<Span>): String {
		return span == null ? '' : '${span.from}:${span.to}';
	}

	/**
	 * Whether an element of a type read at a span excludes `null`: a value type does on its own, any other type under
	 * null safety, the proof `TypeResolver.isProvablyNonNull` asks of a declared binding.
	 */
	private static function elementProof(tree: QueryNode, s: Seams): (String, Span) -> Bool {
		final shape: RefShape = s.shape;
		final values: Array<String> = shape.nonNullableTypeNames ?? [];
		final meta: Null<String> = shape.nullSafetyMetaName;
		if (meta == null) return (type, _) -> values.contains(type);
		final name: String = meta;
		return (type, at) ->
			values.contains(type) || TypeResolver.enclosingIsNullSafe(tree, at, name, shape.nullSafetyDisableArg, shape.refsCache);
	}

	/** Whether a value binding of that name holds at `type`, so that the name reads the value and not the type. */
	private static function isBoundHere(type: QueryNode, tree: QueryNode, s: Seams): Bool {
		final span: Null<Span> = type.span;
		return span == null || TypeResolver.resolveBindingFrom(REFLECT, span, tree, s.shape) != null;
	}

	/**
	 * Records `message` once, on a file the rule is enabled on when there is one: the linter's per-file gate drops a finding
	 * of a default-off rule on any other file, so a problem anchored there would vanish from a normal run.
	 */
	private static function anchorProblem(problems: Array<ConfigProblem>, message: String, file: String, enabled: Bool): Void {
		final known: Null<ConfigProblem> = problems.find(p -> p.message == message);
		if (known == null) {
			problems.push({ message: message, file: file, enabled: enabled });
		} else if (enabled && !known.enabled) {
			known.file = file;
			known.enabled = true;
		}
	}

	/**
	 * The call or other value each path of a callback answers with: its expression body or each returned value, through
	 * parentheses, a call-site `inline` and the branches of a conditional. Nested functions answer for themselves.
	 */
	private static function returnedValues(body: QueryNode, sole: Null<QueryNode>, s: Seams): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function value(node: QueryNode): Void {
			final open: QueryNode = peeled(node, s);
			if ((open.kind == s.ternaryKind || s.ifExpressionKinds.contains(open.kind)) && BranchChain.hasElse(open)) {
				value(BranchChain.thenOf(open));
				value(BranchChain.elseBranch(open));
			} else {
				out.push(open);
			}
		}
		function walk(node: QueryNode): Void {
			if (s.nestedFunctionKinds.contains(node.kind)) return;
			final returned: Null<QueryNode> = returnValue(node, s);
			if (returned != null)
				value(returned);
			else
				for (c in node.children) walk(c);
		}
		if (sole == null || s.blockKinds.contains(body.kind))
			walk(body);
		else
			value(sole);
		return out;
	}

}

private typedef Seams = {
	final ltKind: String;
	final gtKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final ternaryKind: String;
	final ifExpressionKinds: Array<String>;
	final ifStatementKinds: Array<String>;
	final returnKinds: Array<String>;
	final expressionBodyKinds: Array<String>;
	final lambdaKinds: Array<String>;
	final paramKinds: Array<String>;
	final nestedFunctionKinds: Array<String>;
	final identKind: String;
	final blockKinds: Array<String>;
	final blockStmtKind: String;
	final parenKind: Null<String>;
	final shape: RefShape;
	final valueKinds: Array<String>;
	final intType: String;
	final stringType: String;
}

/** One comparison of the chain and the value it selects. */
private typedef Rung = { cond: QueryNode, value: QueryNode }

/** The chain, the span a fix replaces, and whether that span is statements (so the replacement is a `return`). */
private typedef Chain = {
	rungs: Array<Rung>,
	terminal: QueryNode,
	extent: Span,
	asReturn: Bool,
	whole: Bool
}

/** The two operands of a strict comparison, the smaller first. */
private typedef Order = {
	smallNode: QueryNode,
	bigNode: QueryNode
}

/** What the type, purity and null proofs answer about an operand. */
private typedef Typed = {
	purity: PurityCtx,
	nominal: (QueryNode) -> Null<String>,
	element: (QueryNode) -> Null<String>,
	nonNull: (QueryNode) -> Bool,
	elementNonNull: (String, Span) -> Bool,
	isStdReflect: (QueryNode) -> Bool
}

/** The comparison a chain computes, and whether both its operands are proved non-null. */
private typedef Called = {
	type: Null<String>,
	left: QueryNode,
	right: QueryNode,
	nonNull: Bool
}

/**
 * A finding. `span` is what it reports, `replaced` what its fix rewrites, a whole function when `operands` is null;
 * `compare` is null for `Reflect.compare`, and `noFix` says why the rewrite would not be behaviour-preserving, null where it is.
 */
private typedef Match = {
	span: Span,
	replaced: Span,
	compare: Null<NamedCompare>,
	operands: Null<Operands>,
	message: String,
	noFix: Null<String>,
	asReturn: Bool
}

/** A configuration error, and the file it is reported on; `enabled` says the rule runs on that file. */
private typedef ConfigProblem = {
	message: String,
	file: String,
	enabled: Bool
}

/** The two operands of a written call, as source text. */
private typedef Operands = { left: String, right: String }
