package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags an anonymous `function` literal in CALL-ARGUMENT position — `f(function() { … })`,
 * `new T(function(x) { … })` — and rewrites it to the arrow form: `f(() -> { … })`,
 * `new T(x -> { … })`. Only argument position is touched: a local `function name() {}`
 * statement is a different node, and a `var f = function() {}` initializer is out of
 * scope by policy (the arrow idiom targets callbacks). `Severity.Info` with an autofix.
 *
 * ## The type-drift hazard the fix gates on
 *
 * A `function` literal with no explicit `return` has return type `Void`; the arrow
 * form implicitly returns its body's last expression. In a GENERIC argument position
 * (`array.map(function(x) { sideEffect(x); })`) the conversion silently changes the
 * inferred type parameter (`Array<Void>` -> `Array<Int>`) while still compiling — no
 * oracle catches it. The fix therefore applies only when one of these holds:
 *
 * - TYPE-PRESERVING SHAPE, no return-type hint: the body is `return expr` (`ExprBody`),
 *   or a block whose last statement is a `return` (the explicit returns pin the
 *   inferred type in both forms), or a block whose last statement is syntactically
 *   `Void` (empty body, `if` without `else`, loop, local declaration — a value-return
 *   elsewhere could not have compiled, so the type is `Void` in both forms). A `throw`
 *   tail is NOT preserving: the `function` form is `Void` while the arrow form infers
 *   an open monomorph, a silent drift in generic positions — it needs the resolved gate.
 * - A `:Void` hint whose drop is provably a no-op: the hint is `Void` AND the body
 *   shape is one of the above.
 * - RESOLVED EXPECTED TYPE: the callee's parameter signature resolves through the
 *   `SymbolIndex` (member / static / constructor / local binding, walking the
 *   supertype chain and typedef aliases) and the parameter's function-type RETURN
 *   segment is literally `Void` — Haxe unifies any return type with an expected
 *   `Void`, so the conversion cannot change semantics there.
 *
 * A site whose expected return resolves to a callee TYPE PARAMETER (the `map` case)
 * is proven generic: it is not even reported, since the conversion is a semantic
 * change no one should apply by hand. An UNRESOLVABLE site is reported but left
 * unfixed (the `prefer-array-literal` report-then-gate convention), with a message
 * that says so — the fixable and report-only findings carry distinct messages.
 * Subtrees opaque to reference analysis (`RefShape.opaqueKinds` — macro reification)
 * are skipped whole: their code splices into a different resolution context.
 *
 * A comment stranded between the dropped `function` syntax and the kept body span
 * blocks the fix (the rewrite would silently move or lose it).
 *
 * ## Grammar-agnostic
 *
 * The function-literal kind comes from `RefShape.fnExprKind`, argument hosts from
 * `callKind` / `newExprKind`, and the body / parameter / tail-statement
 * classification from the body, param and statement kind seams. Any unset seam
 * makes the check a no-op.
 */
@:nullSafety(Strict)
final class PreferArrowCallback implements Check {

	/** Supertype-chain hop cap for the callee-signature walk. */
	private static inline final MAX_CHAIN_DEPTH: Int = 8;

	/** Typedef-alias hop cap for the function-type source analysis. */
	private static inline final MAX_ALIAS_DEPTH: Int = 4;

	/** The finding message when the fix gates passed — the rewrite is proven safe. */
	private static inline final MSG_FIXABLE: String = 'this function-literal callback can be an arrow lambda';

	/** The finding message when the callee signature stayed unresolved — the finding is report-only. */
	private static inline final MSG_REPORT_ONLY: String =
		'this function-literal callback may be an arrow lambda (callee signature unresolved — verify the expected return type before converting)';

	public function new() {}

	public function id(): String {
		return 'prefer-arrow-callback';
	}

	public function description(): String {
		return 'a function-literal callback argument replaceable with an arrow lambda';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final fnKind: Null<String> = shape.fnExprKind;
		final callKind: Null<String> = shape.callKind;
		if (fnKind == null || callKind == null) return [];
		final getIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final declTrees: Map<String, Null<QueryNode>> = [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final ctx: Ctx = makeCtx(entry.file, entry.source, tree, plugin, shape, fnKind, callKind, getIndex, declTrees);
			walkArgHosts(ctx, tree, (call, arg, span) -> {
				final verdict: Verdict = verdictOf(ctx, call, arg);
				if (verdict == Silent) return false;
				violations.push({
					file: ctx.file,
					span: span,
					rule: 'prefer-arrow-callback',
					severity: Severity.Info,
					message: verdict == Fixable ? MSG_FIXABLE : MSG_REPORT_ONLY
				});
				return true;
			});
		}
		return violations;
	}

	/** Rewrite each fixable flagged literal to its arrow form (report-only findings yield no edit). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final fnKind: Null<String> = shape.fnExprKind;
		final callKind: Null<String> = shape.callKind;
		if (fnKind == null || callKind == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final getIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex([], plugin, index);
		final wanted: Map<String, Bool> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) wanted['${s.from}:${s.to}'] = true;
		}
		final file: String = violations.length > 0 ? violations[0].file : '';
		final ctx: Ctx = makeCtx(file, source, tree, plugin, shape, fnKind, callKind, getIndex, []);
		final edits: Array<{ span: Span, text: String }> = [];
		walkArgHosts(ctx, tree, (call, arg, span) -> {
			if (!wanted.exists('${span.from}:${span.to}')) return false;
			if (verdictOf(ctx, call, arg) == Fixable) {
				final text: Null<String> = rewrite(ctx, arg);
				if (text != null) edits.push({ span: span, text: text });
			}
			return true;
		});
		return edits;
	}

	private static function makeCtx(
		file: String, source: String, tree: QueryNode, plugin: GrammarPlugin, shape: RefShape, fnKind: String, callKind: String,
		getIndex: () -> Null<SymbolIndex>, declTrees: Map<String, Null<QueryNode>>
	): Ctx {
		return {
			file: file,
			source: source,
			tree: tree,
			plugin: plugin,
			shape: shape,
			fnKind: fnKind,
			callKind: callKind,
			getIndex: getIndex,
			typeSources: TypeResolver.memoizedDeclaredTypeSources(plugin, source),
			declTrees: declTrees
		};
	}

	/**
	 * Walk the tree calling `handle` for every function-literal argument of a call /
	 * construction. A true return marks the argument CONSUMED — its subtree is not
	 * descended into, so a nested candidate surfaces on the next fixed-point pass.
	 * Subtrees opaque to reference analysis (`RefShape.opaqueKinds` — macro
	 * reification, whose code splices into a different context) are skipped whole.
	 */
	private static function walkArgHosts(ctx: Ctx, node: QueryNode, handle: (call:QueryNode, arg:QueryNode, span:Span) -> Bool): Void {
		if ((ctx.shape.opaqueKinds ?? []).contains(node.kind)) return;
		final consumed: Array<QueryNode> = [];
		if (isArgHost(ctx, node)) for (arg in argsOf(ctx, node)) if (arg.kind == ctx.fnKind) {
			final span: Null<Span> = arg.span;
			if (span != null && handle(node, arg, span)) consumed.push(arg);
		}
		for (c in node.children) if (!consumed.contains(c)) walkArgHosts(ctx, c, handle);
	}

	/** Whether `node` hosts call arguments — a call or a `new` construction. */
	private static function isArgHost(ctx: Ctx, node: QueryNode): Bool {
		return node.kind == ctx.callKind || node.kind == ctx.shape.newExprKind;
	}

	/** The argument expressions of a call / construction (callee and type-argument children excluded). */
	private static function argsOf(ctx: Ctx, node: QueryNode): Array<QueryNode> {
		if (node.kind == ctx.callKind) return node.children.slice(1);
		return node.children.filter(c -> !isTypeAnnotationKind(ctx, c.kind));
	}

	/** Whether `kind` is a type-annotation child (a `new T<…>` type argument, a return-type hint), never an argument. */
	private static function isTypeAnnotationKind(ctx: Ctx, kind: String): Bool {
		return (ctx.shape.typeAnnotationKinds ?? []).contains(kind);
	}

	private static function verdictOf(ctx: Ctx, call: QueryNode, fnArg: QueryNode): Verdict {
		final parts: Null<FnParts> = partsOf(ctx, fnArg);
		if (parts == null) return Silent;
		final tail: Tail = tailOf(ctx, parts.body);
		if (parts.hint == null && tail != Open) return Fixable;
		final hint: Null<QueryNode> = parts.hint;
		if (hint != null && hintIsVoid(ctx, hint) && tail != Open) return Fixable;
		return switch expectedReturnIsVoid(ctx, call, fnArg) {
			case true: Fixable;
			case false: Silent;
			case null: ReportOnly;
		};
	}

	/** Split a function literal's children into params / return-type hint / body; null when the shape is not convertible. */
	private static function partsOf(ctx: Ctx, fnArg: QueryNode): Null<FnParts> {
		final shape: RefShape = ctx.shape;
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		final restKind: Null<String> = shape.restParamKind;
		final params: Array<QueryNode> = [];
		var hint: Null<QueryNode> = null;
		var body: Null<QueryNode> = null;
		for (c in fnArg.children) {
			if (paramKinds.contains(c.kind)) {
				if (restKind != null && c.kind == restKind) return null;
				params.push(c);
			} else if (bodyKinds.contains(c.kind))
				body = c;
			else if (isTypeAnnotationKind(ctx, c.kind))
				hint = c;
			else
				return null;
		}
		final b: Null<QueryNode> = body;
		if (b == null || b.kind == shape.noBodyKind) return null;
		return { params: params, hint: hint, body: b };
	}

	/** Whether the return-type hint's written source is exactly `Void`. */
	private static function hintIsVoid(ctx: Ctx, hint: QueryNode): Bool {
		final span: Null<Span> = hint.span;
		return span != null && StringTools.trim(ctx.source.substring(span.from, span.to)) == 'Void';
	}

	/**
	 * The body's tail class: `Preserving` when explicit returns pin the inferred type in
	 * both forms, `VoidTail` when the last statement is syntactically `Void`, `Open` when
	 * the implicit arrow return could pick up the last expression's type. A `throw` tail
	 * is `Open`: the `function` form is `Void` while the arrow form infers an open
	 * monomorph — a silent drift in generic positions.
	 */
	private static function tailOf(ctx: Ctx, body: QueryNode): Tail {
		final shape: RefShape = ctx.shape;
		final valueReturns: Array<String> = shape.valueReturnKinds ?? [];
		if (body.kind != shape.blockBodyKind) {
			final expr: Null<QueryNode> = body.children[0];
			return expr != null && valueReturns.contains(expr.kind) ? Preserving : Open;
		}
		if (body.children.length == 0) return VoidTail;
		final last: QueryNode = body.children[body.children.length - 1];
		if (valueReturns.contains(last.kind) || last.kind == shape.voidReturnKind) return Preserving;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.contains(last.kind)) return last.children.length <= 2 ? VoidTail : Open;
		final voidTails: Array<String> = voidTailKinds(shape);
		return voidTails.contains(last.kind) ? VoidTail : Open;
	}

	/** Statement kinds that are `Void`-typed by construction when they close a block body. */
	private static function voidTailKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (k in shape.loopStatementKinds ?? []) out.push(k);
		for (k in shape.doWhileLoopKinds ?? []) out.push(k);
		for (k in shape.localDeclKinds ?? []) out.push(k);
		for (k in shape.localFunctionKinds ?? []) out.push(k);
		final empty: Null<String> = shape.emptyStmtKind;
		if (empty != null) out.push(empty);
		return out;
	}

	/** The arrow-form replacement text for a fixable literal, or null when a stranded comment blocks it. */
	private static function rewrite(ctx: Ctx, fnArg: QueryNode): Null<String> {
		final parts: Null<FnParts> = partsOf(ctx, fnArg);
		if (parts == null) return null;
		final fnSpan: Null<Span> = fnArg.span;
		if (fnSpan == null) return null;
		final kept: Array<Span> = [];
		final paramTexts: Array<String> = [];
		for (p in parts.params) {
			final ps: Null<Span> = p.span;
			if (ps == null) return null;
			kept.push(ps);
			paramTexts.push(StringTools.trim(ctx.source.substring(ps.from, ps.to)));
		}
		final hint: Null<QueryNode> = parts.hint;
		if (hint != null) {
			final hs: Null<Span> = hint.span;
			if (hs == null) return null;
			kept.push(hs);
		}
		final bodyText: Null<String> = bodyTextOf(ctx, parts.body, kept);
		if (bodyText == null) return null;
		if (gapHasComment(ctx, fnSpan, kept)) return null;
		final single: Null<QueryNode> = parts.params.length == 1 ? parts.params[0] : null;
		final head: String = single != null && paramTexts[0] == single.name ? paramTexts[0] : '(' + paramTexts.join(', ') + ')';
		return '$head -> $bodyText';
	}

	/**
	 * The arrow body text: a `return expr` expression body becomes the bare expression, a
	 * block holding a single expression statement or a single `return expr;` collapses to
	 * that expression (unless a comment hides inside the braces), any other block is kept
	 * verbatim. Appends the consumed span to `kept` for the stranded-comment gap scan.
	 */
	private static function bodyTextOf(ctx: Ctx, body: QueryNode, kept: Array<Span>): Null<String> {
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return null;
		if (body.kind != ctx.shape.blockBodyKind) {
			final ret: Null<QueryNode> = body.children[0];
			final expr: Null<QueryNode> = ret == null ? null : ret.children[0];
			final es: Null<Span> = expr == null ? null : expr.span;
			if (es == null) return null;
			kept.push(bodySpan);
			final gap: String = ctx.source.substring(bodySpan.from, es.from) + ctx.source.substring(es.to, bodySpan.to);
			if (RefactorSupport.textHasCommentMarker(gap)) return null;
			return ctx.source.substring(es.from, es.to);
		}
		kept.push(bodySpan);
		final lone: Null<QueryNode> = body.children.length == 1 ? body.children[0] : null;
		final valueReturns: Array<String> = ctx.shape.valueReturnKinds ?? [];
		final collapsible: Bool = lone != null && (lone.kind == ctx.shape.exprStatementKind || valueReturns.contains(lone.kind));
		if (lone != null && collapsible && lone.children.length == 1) {
			final inner: Null<Span> = lone.children[0].span;
			if (inner != null) {
				final interior: String = ctx.source.substring(bodySpan.from, inner.from) + ctx.source.substring(inner.to, bodySpan.to);
				if (!RefactorSupport.textHasCommentMarker(interior)) return ctx.source.substring(inner.from, inner.to);
			}
		}
		return ctx.source.substring(bodySpan.from, bodySpan.to);
	}

	/** Whether the parts of `outer` NOT covered by the `kept` spans contain a comment marker. */
	private static function gapHasComment(ctx: Ctx, outer: Span, kept: Array<Span>): Bool {
		final sorted: Array<Span> = kept.copy();
		sorted.sort((a, b) -> a.from - b.from);
		var cursor: Int = outer.from;
		var gaps: String = '';
		for (s in sorted) {
			if (s.from > cursor) gaps += ctx.source.substring(cursor, s.from);
			if (s.to > cursor) cursor = s.to;
		}
		if (outer.to > cursor) gaps += ctx.source.substring(cursor, outer.to);
		return RefactorSupport.textHasCommentMarker(gaps);
	}

	/**
	 * Whether the callee parameter receiving `fnArg` has a function type whose RETURN is
	 * `Void`: true = proven `Void` (safe), false = proven non-`Void` / type-parameter
	 * (generic hazard, stay silent), null = unresolvable (report-only).
	 */
	private static function expectedReturnIsVoid(ctx: Ctx, call: QueryNode, fnArg: QueryNode): Null<Bool> {
		final idx: Null<SymbolIndex> = ctx.getIndex();
		if (idx == null) return null;
		final args: Array<QueryNode> = argsOf(ctx, call);
		final argIndex: Int = args.indexOf(fnArg);
		if (argIndex < 0) return null;
		final argCount: Int = args.length;
		if (call.kind == ctx.shape.newExprKind) {
			final typeName: Null<String> = call.name;
			if (typeName == null) return null;
			return chainLookup(
				ctx, idx, idx.resolveTypeRefsFrom(typeName, ctx.file), ctx.shape.constructorName ?? 'new', argIndex, argCount, [], 0
			);
		}
		final callee: Null<QueryNode> = call.children[0];
		if (callee == null) return null;
		if (callee.kind == ctx.shape.identKind) return bareCalleeExpected(ctx, idx, call, callee, argIndex, argCount);
		if (callee.kind == ctx.shape.fieldAccessKind || callee.kind == ctx.shape.nullSafeAccessKind)
			return memberCalleeExpected(ctx, idx, call, callee, argIndex, argCount);
		return null;
	}

	/** Expected-type resolution for a bare-identifier callee: a local binding first, else an enclosing-type member. */
	private static function bareCalleeExpected(
		ctx: Ctx, idx: SymbolIndex, call: QueryNode, callee: QueryNode, argIndex: Int, argCount: Int
	): Null<Bool> {
		final name: Null<String> = callee.name;
		final span: Null<Span> = callee.span;
		if (name == null || span == null) return null;
		final bindingFrom: Null<Int> = TypeResolver.resolveBindingFrom(name, span, ctx.tree, ctx.shape);
		if (bindingFrom != null) {
			final fnDecl: Null<QueryNode> = findFnDeclAt(ctx, ctx.tree, bindingFrom);
			if (fnDecl != null)
				return paramReturnVoid(
					ctx, idx, fnDecl, argIndex, argCount, ctx.typeSources, ctx.file, typeParamsAround(ctx, ctx.tree, span)
				);
			final typeSrc: Null<String> = ctx.typeSources()[bindingFrom];
			if (typeSrc == null) return null;
			final paramType: Null<String> = paramOfFnTypeSource(typeSrc, argIndex, argCount);
			if (paramType == null) return null;
			return fnTypeReturnVoid(ctx, idx, paramType, ctx.file, typeParamsAround(ctx, ctx.tree, span), 0);
		}
		final callSpan: Null<Span> = call.span;
		if (callSpan == null) return null;
		final enclosing: Null<String> = TypeResolver.enclosingTypeName(ctx.tree, callSpan);
		if (enclosing == null) return null;
		return chainLookup(ctx, idx, idx.resolveTypeRefsFrom(enclosing, ctx.file), name, argIndex, argCount, [], 0);
	}

	/** Expected-type resolution for a `recv.member(…)` callee: `this`, a typed value receiver, a static / dotted type path. */
	private static function memberCalleeExpected(
		ctx: Ctx, idx: SymbolIndex, call: QueryNode, callee: QueryNode, argIndex: Int, argCount: Int
	): Null<Bool> {
		final member: Null<String> = callee.name;
		final recv: Null<QueryNode> = callee.children[0];
		if (member == null || recv == null) return null;
		if (recv.kind == ctx.shape.identKind) {
			if (recv.name == ctx.shape.selfReferenceText) {
				final callSpan: Null<Span> = call.span;
				if (callSpan == null) return null;
				final enclosing: Null<String> = TypeResolver.enclosingTypeName(ctx.tree, callSpan);
				if (enclosing == null) return null;
				return chainLookup(ctx, idx, idx.resolveTypeRefsFrom(enclosing, ctx.file), member, argIndex, argCount, [], 0);
			}
			final typeSrc: Null<String> = TypeResolver.identDeclaredTypeSource(recv, ctx.shape, ctx.tree, ctx.typeSources, false);
			if (typeSrc != null) {
				final nominal: Null<String> = receiverNominal(typeSrc);
				if (nominal == null) return null;
				return chainLookup(ctx, idx, idx.resolveTypeRefsFrom(nominal, ctx.file), member, argIndex, argCount, [], 0);
			}
			final recvName: Null<String> = recv.name;
			final recvSpan: Null<Span> = recv.span;
			if (recvName == null || recvSpan == null) return null;
			// A static-callee lookup is sound only when the receiver is demonstrably NOT a
			// value binding: identDeclaredTypeSource's null also covers a binding whose
			// type it deliberately refused to trust (shadowed re-declaration), and that
			// conservative null must not be read as "this is a type name".
			if (TypeResolver.resolveBindingFrom(recvName, recvSpan, ctx.tree, ctx.shape) != null) return null;
			return chainLookup(ctx, idx, idx.resolveTypeRefsFrom(recvName, ctx.file), member, argIndex, argCount, [], 0);
		}
		final path: Null<String> = dottedPathOf(ctx, recv);
		if (path == null) return null;
		return chainLookup(ctx, idx, idx.resolveTypeRefsFrom(path, ctx.file), member, argIndex, argCount, [], 0);
	}

	/** The `a.b.C` text of a pure ident / field-access chain, or null when any link is another expression. */
	private static function dottedPathOf(ctx: Ctx, node: QueryNode): Null<String> {
		if (node.kind == ctx.shape.identKind) return node.name;
		if (node.kind != ctx.shape.fieldAccessKind) return null;
		final head: Null<QueryNode> = node.children[0];
		final name: Null<String> = node.name;
		if (head == null || name == null) return null;
		final prefix: Null<String> = dottedPathOf(ctx, head);
		return prefix == null ? null : '$prefix.$name';
	}

	/** The head nominal of a receiver's declared type source (`Null<Signal<Int>>` -> `Signal`). */
	private static function receiverNominal(typeSrc: String): Null<String> {
		final s: String = StringTools.trim(typeSrc);
		final lt: Int = s.indexOf('<');
		final head: String = lt < 0 ? s : StringTools.trim(s.substr(0, lt));
		if (head == 'Null' && lt >= 0 && StringTools.endsWith(s, '>')) return receiverNominal(s.substring(lt + 1, s.length - 1));
		return TypeResolver.simpleNominalName(head) == null ? null : head;
	}

	/**
	 * Resolve `member`'s parameter at `argIndex` across every candidate declaration and
	 * combine by AGREEMENT: an ambiguous reference (a vendored std fork next to the real
	 * std) is accepted when every resolvable candidate yields the same verdict; a
	 * disagreement or an empty candidate set stays unresolved. Each candidate walks with
	 * its own copy of `visited` so one candidate's supertype closure cannot starve a
	 * sibling of its verdict.
	 */
	private static function chainLookup(
		ctx: Ctx, idx: SymbolIndex, candidates: Array<Candidate>, member: String, argIndex: Int, argCount: Int, visited: Array<String>,
		depth: Int
	): Null<Bool> {
		final verdicts: Array<Bool> = [];
		for (rt in candidates) {
			final v: Null<Bool> = chainLookupOne(ctx, idx, rt, member, argIndex, argCount, visited.copy(), depth);
			if (v != null) verdicts.push(v);
		}
		if (verdicts.length == 0) return null;
		for (v in verdicts) if (v != verdicts[0]) return null;
		return verdicts[0];
	}

	/**
	 * Resolve `member`'s parameter at `argIndex` through ONE candidate declaration and its
	 * supertype chain, and test its function-type return for `Void`. A member declared more
	 * than once in one type (overloads) or an unresolvable hop yields null.
	 */
	private static function chainLookupOne(
		ctx: Ctx, idx: SymbolIndex, rt: Candidate, member: String, argIndex: Int, argCount: Int, visited: Array<String>, depth: Int
	): Null<Bool> {
		if (depth > MAX_CHAIN_DEPTH) return null;
		final key: String = '${rt.file.file}#${rt.type.name}';
		if (visited.contains(key)) return null;
		visited.push(key);
		var declared: Int = 0;
		var declaredTypeSrc: Null<String> = null;
		for (m in rt.type.members) if (m.name == member) {
			declared++;
			declaredTypeSrc = m.typeSource;
		}
		if (declared > 1) return null;
		if (declared == 1) {
			final valueTypeSrc: Null<String> = declaredTypeSrc;
			if (valueTypeSrc != null) {
				final paramType: Null<String> = paramOfFnTypeSource(valueTypeSrc, argIndex, argCount);
				if (paramType == null) return null;
				return fnTypeReturnVoid(ctx, idx, paramType, rt.file.file, typeHeaderParams(ctx, idx, rt), 0);
			}
			return memberParamReturnVoid(ctx, idx, rt, member, argIndex, argCount);
		}
		for (raw in rt.type.supertypesRaw) {
			final v: Null<Bool> = chainLookup(
				ctx, idx, idx.resolveTypeRefsFrom(raw, rt.file.file), member, argIndex, argCount, visited, depth + 1
			);
			if (v != null) return v;
		}
		return null;
	}

	/** Parse `rt`'s declaring file and test `member`'s parameter at `argIndex` for a `Void`-returning function type. */
	private static function memberParamReturnVoid(
		ctx: Ctx, idx: SymbolIndex, rt: Candidate, member: String, argIndex: Int, argCount: Int
	): Null<Bool> {
		final declSource: Null<String> = idx.sourceOf(rt.file.file);
		if (declSource == null) return null;
		final declTree: Null<QueryNode> = declTreeOf(ctx, rt.file.file, declSource);
		if (declTree == null) return null;
		final typeDecl: Null<QueryNode> = findNamedDecl(declTree, rt.type.name);
		if (typeDecl == null) return null;
		final functionKinds: Array<String> = ctx.shape.functionKinds ?? [];
		final found: Array<QueryNode> = [];
		collectNamedFnMembers(typeDecl, member, functionKinds, ctx.shape.conditionalMemberKind, found);
		if (found.length != 1) return null;
		final fn: QueryNode = found[0];
		final typeParams: Array<String> = headerTypeParams(declSource, typeDecl, '{');
		for (p in headerTypeParams(declSource, fn, '(')) typeParams.push(p);
		return paramReturnVoid(
			ctx, idx, fn, argIndex, argCount, TypeResolver.memoizedDeclaredTypeSources(ctx.plugin, declSource), rt.file.file, typeParams
		);
	}

	/**
	 * Locate a top-level type declaration by name, descending into nameless wrappers (an
	 * `#if` region, a `final class` FinalDecl) whose interior may hold it.
	 */
	private static function findNamedDecl(tree: QueryNode, name: String): Null<QueryNode> {
		for (c in tree.children) {
			if (c.name == name && c.children.length > 0) return c;
			if (c.name == null && c.children.length > 0) {
				final nested: Null<QueryNode> = findNamedDecl(c, name);
				if (nested != null) return nested;
			}
		}
		return null;
	}

	/**
	 * Collect every function member of `typeDecl` named `member`, descending into `#if`
	 * region wrappers. Same-named members across sibling branches count separately, so
	 * an `#if`/`#else` pair of one member reads as an overload and stays report-only —
	 * conservative, since the branches may disagree on the signature.
	 */
	private static function collectNamedFnMembers(
		typeDecl: QueryNode, member: String, functionKinds: Array<String>, condKind: Null<String>, out: Array<QueryNode>
	): Void {
		for (c in typeDecl.children) {
			if (c.name == member && functionKinds.contains(c.kind)) out.push(c);
			if (condKind != null && c.kind == condKind) collectNamedFnMembers(c, member, functionKinds, condKind, out);
		}
	}

	/** The parsed tree of a declaring file's source, memoized by file path. */
	private static function declTreeOf(ctx: Ctx, file: String, declSource: String): Null<QueryNode> {
		if (ctx.declTrees.exists(file)) return ctx.declTrees[file];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(ctx.plugin, declSource);
		ctx.declTrees[file] = tree;
		return tree;
	}

	/** The function-declaration node whose span starts at `from`, or null. */
	private static function findFnDeclAt(ctx: Ctx, node: QueryNode, from: Int): Null<QueryNode> {
		final fnKinds: Array<String> = ctx.shape.functionKinds ?? [];
		final localFnKinds: Array<String> = ctx.shape.localFunctionKinds ?? [];
		final span: Null<Span> = node.span;
		if (span != null && span.from == from && (fnKinds.contains(node.kind) || localFnKinds.contains(node.kind))) return node;
		for (c in node.children) {
			final cs: Null<Span> = c.span;
			if (cs != null && (from < cs.from || from >= cs.to)) continue;
			final found: Null<QueryNode> = findFnDeclAt(ctx, c, from);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * Test a function-declaration node's parameter at `argIndex` for a `Void`-returning
	 * function type. Alignment is positional and refuses the optional-skipping ambiguity:
	 * when the call's argument count differs from the declared parameter count, every
	 * parameter up to `argIndex` must be required and default-free.
	 */
	private static function paramReturnVoid(
		ctx: Ctx, idx: SymbolIndex, fnDecl: QueryNode, argIndex: Int, argCount: Int, typeSources: () -> Map<Int, String>, declFile: String,
		typeParams: Array<String>
	): Null<Bool> {
		final paramKinds: Array<String> = ctx.shape.paramKinds ?? [];
		final optionalKind: Null<String> = ctx.shape.optionalParamKind;
		final params: Array<QueryNode> = fnDecl.children.filter(c -> paramKinds.contains(c.kind));
		if (argIndex >= params.length || argCount > params.length) return null;
		if (argCount != params.length) for (i in 0...argIndex + 1) {
			final p: QueryNode = params[i];
			if (p.kind == optionalKind || p.children.length > 0) return null;
		}
		final ps: Null<Span> = params[argIndex].span;
		if (ps == null) return null;
		final typeSrc: Null<String> = typeSources()[ps.from];
		if (typeSrc == null) return null;
		return fnTypeReturnVoid(ctx, idx, typeSrc, declFile, typeParams, 0);
	}

	/**
	 * Whether `typeSrc` is a function type whose return segment is `Void`: true / false as
	 * proven, null as unresolvable. A bare nominal hops through its typedef alias.
	 */
	private static function fnTypeReturnVoid(
		ctx: Ctx, idx: SymbolIndex, typeSrc: String, fromFile: String, typeParams: Array<String>, depth: Int
	): Null<Bool> {
		if (depth > MAX_ALIAS_DEPTH) return null;
		final s: String = stripOuterParens(StringTools.trim(typeSrc));
		final segs: Array<String> = splitTopArrows(s);
		if (segs.length >= 2) return returnSegmentIsVoid(ctx, idx, StringTools.trim(segs[segs.length - 1]), fromFile, typeParams, depth);
		final rhs: Null<String> = typedefAlias(ctx, idx, s, fromFile);
		return rhs == null ? null : fnTypeReturnVoid(ctx, idx, rhs, fromFile, typeParams, depth + 1);
	}

	/** Whether a function type's RETURN segment is `Void` (typedef aliases hopped; a type parameter is proven non-`Void`). */
	private static function returnSegmentIsVoid(
		ctx: Ctx, idx: SymbolIndex, segment: String, fromFile: String, typeParams: Array<String>, depth: Int
	): Null<Bool> {
		if (segment == 'Void') return true;
		if (depth > MAX_ALIAS_DEPTH) return null;
		if (typeParams.contains(segment)) return false;
		if (splitTopArrows(segment).length >= 2 || StringTools.startsWith(segment, '(') || StringTools.startsWith(segment, '{'))
			return false;
		final rhs: Null<String> = typedefAlias(ctx, idx, segment, fromFile);
		if (rhs == null) return null;
		return returnSegmentIsVoid(ctx, idx, stripOuterParens(StringTools.trim(rhs)), fromFile, typeParams, depth + 1);
	}

	/** The right-hand side of a nominal's `typedef` declaration, or null when it is not a resolvable typedef. */
	private static function typedefAlias(ctx: Ctx, idx: SymbolIndex, nominal: String, fromFile: String): Null<String> {
		final lt: Int = nominal.indexOf('<');
		final head: String = StringTools.trim(lt < 0 ? nominal : nominal.substr(0, lt));
		if (TypeResolver.simpleNominalName(head) == null) return null;
		final all: Array<Candidate> = idx.resolveTypeRefsFrom(head, fromFile);
		final rt: Null<Candidate> = all.length == 1 ? all[0] : null;
		if (rt == null || rt.type.kind != 'TypedefDecl') return null;
		final declSource: Null<String> = idx.sourceOf(rt.file.file);
		if (declSource == null) return null;
		final declText: String = declSource.substring(rt.type.span.from, rt.type.span.to);
		final eq: Int = topLevelIndexOf(declText, '=');
		if (eq < 0) return null;
		var rhs: String = StringTools.trim(declText.substr(eq + 1));
		if (StringTools.endsWith(rhs, ';')) rhs = StringTools.trim(rhs.substr(0, rhs.length - 1));
		return rhs;
	}

	/** The parameter segment at `argIndex` of a function-type SOURCE (`(a:Int, b:X)->Void` / `A->B->Void`), or null. */
	private static function paramOfFnTypeSource(typeSrc: String, argIndex: Int, argCount: Int): Null<String> {
		final s: String = stripOuterParens(StringTools.trim(typeSrc));
		final segs: Array<String> = splitTopArrows(s);
		if (segs.length < 2) return null;
		if (segs.length == 2 && StringTools.startsWith(StringTools.trim(segs[0]), '(')) {
			final interior: String = stripOuterParens(StringTools.trim(segs[0]));
			// An empty interior is a zero-parameter list — splitTopCommas('') would report
			// arity 1 (a single empty element) and defeat the alignment gate below.
			if (StringTools.trim(interior) == '') return null;
			final parts: Array<String> = splitTopCommas(interior);
			if (parts.length != argCount || argIndex >= parts.length) return null;
			var part: String = StringTools.trim(parts[argIndex]);
			final colon: Int = topLevelIndexOf(part, ':');
			if (colon >= 0) part = StringTools.trim(part.substr(colon + 1));
			return part;
		}
		if (segs.length - 1 != argCount || argIndex >= segs.length - 1) return null;
		return StringTools.trim(segs[argIndex]);
	}

	/** Type-parameter names in scope at `span` — the enclosing member's and type declaration's header params. */
	private static function typeParamsAround(ctx: Ctx, tree: QueryNode, span: Span): Array<String> {
		final out: Array<String> = [];
		collectEnclosingTypeParams(ctx, tree, span, out);
		return out;
	}

	/** Accumulate header type-parameter names of every declaration enclosing `span` into `out`. */
	private static function collectEnclosingTypeParams(ctx: Ctx, node: QueryNode, span: Span, out: Array<String>): Void {
		for (c in node.children) {
			final cs: Null<Span> = c.span;
			if (cs != null && (span.from < cs.from || span.from >= cs.to)) continue;
			if (cs != null && c.name != null) {
				final fnKinds: Array<String> = ctx.shape.functionKinds ?? [];
				final isFn: Bool = fnKinds.contains(c.kind);
				final isType: Bool = c.kind.indexOf('Decl') >= 0 || c.kind.indexOf('Form') >= 0;
				if (isFn || isType) for (p in headerTypeParams(ctx.source, c, isFn ? '(' : '{')) out.push(p);
			}
			collectEnclosingTypeParams(ctx, c, span, out);
		}
	}

	/** The type-parameter names of `rt`'s declaration header (`class Box<T, U>` -> `[T, U]`). */
	private static function typeHeaderParams(ctx: Ctx, idx: SymbolIndex, rt: Candidate): Array<String> {
		if (rt.type.typeParamArity == 0) return [];
		final declSource: Null<String> = idx.sourceOf(rt.file.file);
		if (declSource == null) return [];
		final declTree: Null<QueryNode> = declTreeOf(ctx, rt.file.file, declSource);
		final decl: Null<QueryNode> = declTree == null ? null : findNamedDecl(declTree, rt.type.name);
		return decl == null ? [] : headerTypeParams(declSource, decl, '{');
	}

	/**
	 * The `<…>` type-parameter names written right after `decl`'s name, extracted from the
	 * header slice of its source span (the projection drops type parameters). The name is
	 * matched as a WHOLE WORD — a short name is otherwise found inside a preceding
	 * modifier keyword (`n` inside `function`) and the scan silently misses the list.
	 */
	private static function headerTypeParams(source: String, decl: QueryNode, stop: String): Array<String> {
		final span: Null<Span> = decl.span;
		final name: Null<String> = decl.name;
		if (span == null || name == null) return [];
		final text: String = source.substring(span.from, span.to);
		var end: Int = text.indexOf(stop);
		if (end < 0) end = text.length;
		final head: String = text.substr(0, end);
		final nameAt: Int = wholeWordIndexOf(head, name);
		if (nameAt < 0) return [];
		var i: Int = nameAt + name.length;
		while (i < head.length && StringTools.isSpace(head, i)) i++;
		if (i >= head.length || head.charAt(i) != '<') return [];
		var d: Int = 0;
		var j: Int = i;
		while (j < head.length) {
			final c: String = head.charAt(j);
			if (c == '<') d++;
			if (c == '>') {
				d--;
				if (d == 0) break;
			}
			j++;
		}
		if (d != 0) return [];
		final out: Array<String> = [];
		for (part in splitTopCommas(head.substring(i + 1, j))) {
			var p: String = StringTools.trim(part);
			final colon: Int = topLevelIndexOf(p, ':');
			if (colon >= 0) p = StringTools.trim(p.substr(0, colon));
			if (p.length > 0) out.push(p);
		}
		return out;
	}

	/** The first WHOLE-WORD occurrence of `word` in `s` (identifier-boundary on both sides), or -1. */
	private static function wholeWordIndexOf(s: String, word: String): Int {
		var from: Int = 0;
		while (from <= s.length - word.length) {
			final at: Int = s.indexOf(word, from);
			if (at < 0) return -1;
			final beforeOk: Bool = at == 0 || !isIdentChar(s.charAt(at - 1));
			final afterOk: Bool = at + word.length >= s.length || !isIdentChar(s.charAt(at + word.length));
			if (beforeOk && afterOk) return at;
			from = at + 1;
		}
		return -1;
	}

	/** Whether `c` is an identifier character (`[A-Za-z0-9_]`). */
	private static function isIdentChar(c: String): Bool {
		return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
	}

	/** Strip one balanced pair of parentheses wrapping the WHOLE string, repeatedly. */
	private static function stripOuterParens(s: String): String {
		var out: String = s;
		while (StringTools.startsWith(out, '(') && StringTools.endsWith(out, ')')) {
			var d: Int = 0;
			var wraps: Bool = true;
			for (i in 0...out.length) {
				final c: String = out.charAt(i);
				if (c == '(') d++;
				if (c == ')') {
					d--;
					if (d == 0 && i < out.length - 1) {
						wraps = false;
						break;
					}
				}
			}
			if (!wraps) return out;
			out = StringTools.trim(out.substring(1, out.length - 1));
		}
		return out;
	}

	/** Split on `->` at bracket depth 0 (respecting `()`, `<>`, `{}`; the arrow token is consumed atomically). */
	private static function splitTopArrows(s: String): Array<String> {
		final out: Array<String> = [];
		var d: Int = 0;
		var start: Int = 0;
		var i: Int = 0;
		while (i < s.length) {
			final c: String = s.charAt(i);
			if (c == '-' && i + 1 < s.length && s.charAt(i + 1) == '>') {
				if (d == 0) {
					out.push(s.substring(start, i));
					i += 2;
					start = i;
				} else
					i += 2;
				continue;
			}
			if (c == '(' || c == '<' || c == '{' || c == '[') d++;
			if (c == ')' || c == '>' || c == '}' || c == ']') d--;
			i++;
		}
		out.push(s.substr(start));
		return out;
	}

	/** Split on `,` at bracket depth 0 (the `->` token is consumed atomically, its `>` never closes a bracket). */
	private static function splitTopCommas(s: String): Array<String> {
		final out: Array<String> = [];
		var d: Int = 0;
		var start: Int = 0;
		var i: Int = 0;
		while (i < s.length) {
			final c: String = s.charAt(i);
			if (c == '-' && i + 1 < s.length && s.charAt(i + 1) == '>') {
				i += 2;
				continue;
			}
			if (c == '(' || c == '<' || c == '{' || c == '[') d++;
			if (c == ')' || c == '>' || c == '}' || c == ']') d--;
			if (d == 0 && c == ',') {
				out.push(s.substring(start, i));
				start = i + 1;
			}
			i++;
		}
		out.push(s.substr(start));
		return out;
	}

	/** The index of the first `needle` at bracket depth 0, or -1 (the `->` token is consumed atomically). */
	private static function topLevelIndexOf(s: String, needle: String): Int {
		var d: Int = 0;
		var i: Int = 0;
		while (i < s.length) {
			final c: String = s.charAt(i);
			if (c == '-' && i + 1 < s.length && s.charAt(i + 1) == '>') {
				i += 2;
				continue;
			}
			if (c == '(' || c == '<' || c == '{' || c == '[') d++;
			if (c == ')' || c == '>' || c == '}' || c == ']') d--;
			if (d == 0 && c == needle) return i;
			i++;
		}
		return -1;
	}

}

/** The per-file analysis context threaded through the walk. */
private typedef Ctx = {
	final file: String;
	final source: String;
	final tree: QueryNode;
	final plugin: GrammarPlugin;
	final shape: RefShape;
	final fnKind: String;
	final callKind: String;
	final getIndex: () -> Null<SymbolIndex>;
	final typeSources: () -> Map<Int, String>;
	final declTrees: Map<String, Null<QueryNode>>;
};

/** A resolved type-reference candidate — a declaration paired with its declaring file. */
private typedef Candidate = {
	file: FileInfo,
	type: TypeDeclInfo
};

/** A function literal's children split into parameters, return-type hint and body. */
private typedef FnParts = {
	final params: Array<QueryNode>;
	final hint: Null<QueryNode>;
	final body: QueryNode;
};

/** What a candidate literal deserves: an autofixed finding, a report-only finding, or nothing. */
private enum Verdict {
	Fixable;
	ReportOnly;
	Silent;
}

/** A convertible body's tail class — see `tailOf`. */
private enum Tail {
	Preserving;
	VoidTail;
	Open;
}
