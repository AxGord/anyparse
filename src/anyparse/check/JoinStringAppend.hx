package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a run of >= 2 ADJACENT statements that all append to the same bare-identifier
 * target — either a plain compound-`+=` chain, or one plain `=` followed by one or more
 * `+=`  — and joins the run into a single statement whose right-hand side is the sum of
 * every appended value:
 *
 * ```haxe
 * str += ' line ';
 * str += line;
 * // ->
 * str += ' line ' + line;
 *
 * str = cname;
 * str += '.';
 * str += meth;
 * // ->
 * str = cname + '.' + meth;
 * ```
 *
 * `Info`, `DefaultOff` — a readability simplification, not a correctness rule, matching
 * the sibling `join-declaration-assignment` / `join-return` family. It composes with
 * `fold-adjacent-string-literals` over successive `lint --fix` passes: a run whose terms
 * are String-typed segments (`str += ' line '; str += line;`) first joins to
 * `str += ' line ' + line;` here, which `fold-adjacent-string-literals` then folds into
 * `str += ' line $line';` on the next pass.
 *
 * ## What is flagged
 *
 * A maximal run starting at a statement of one of two shapes:
 *
 *  - `x += e1;` (`addAssignKind`) — the PLAIN arm, requiring at least one more `x += e;`
 *    immediately following (>= 2 statements total);
 *  - `x = e0;` (`assignKind`) — the BONUS arm, requiring at least one `x += e;`
 *    immediately following.
 *
 * In both arms `x` must be a bare identifier (`identKind`) — a field (`this.x +=`) or
 * index (`a[i] +=`) target is left alone, since a repeated property write may run a
 * setter with side effects the join would collapse from N calls to one. Every statement
 * in the run must target the SAME name; a run stops (without failing the match) at the
 * first following statement that is not `x += …` on that name.
 *
 * ## Gates
 *
 *  - NO SELF-REFERENCE — no `ei` (`i >= 1`, the `+=` terms; the bonus arm's leading `e0`
 *    is exempt) may reference `x`. The fused expression evaluates every term BEFORE the
 *    one enclosing `+=`/`=` runs, so a later term reading `x` would see the PRE-RUN value
 *    instead of the intermediate one the original sequential code produced — the
 *    accumulation would be silently lost. `e0` (and a plain arm's OWN first term) are
 *    exempt: nothing has written `x` yet at that point in EITHER reading, so they agree.
 *    A self-referencing term does not veto the whole block — it stops the run BEFORE
 *    itself (so a shorter prefix run may still be flagged) and, since it is exempt as a
 *    fresh run's own first term, a following statement may start a NEW run with it.
 *  - TYPE-SOUND ACCUMULATION — accepted when EITHER any term's source is a string
 *    literal (`stringLiteralKinds`; this alone proves the whole chain is String-typed,
 *    since Haxe would not otherwise type-check a `+=` mixing it in) OR the target's
 *    explicit declared type (`TypeResolver.identDeclaredTypeSource`, one `Null<…>` layer
 *    unwrapped) is `String` or `Int` — both associative under `+`. An explicitly
 *    `Float`-declared target REFUSES outright: `+` is not associative under rounding, so
 *    `(a + b) + c` and `a + (b + c)` may differ. Everything else (an unresolved / inferred
 *    type with no literal in the run, a custom type, `Dynamic`, …) is a safe miss —
 *    coverage never trumps soundness here.
 *  - NO DROPPED COMMENT — a comment anywhere in the merged region OUTSIDE the individual
 *    terms' own verbatim spans (the target name, the operators, the inter-statement gaps)
 *    would be silently dropped by the rewrite and refuses the WHOLE run, matching
 *    `join-declaration-assignment`'s choice; this check does not hoist such a comment.
 *
 * Side-effectful terms are fine — the fused expression evaluates them in the SAME
 * left-to-right source order the original statements did, so no ordering changes.
 *
 * ## Autofix
 *
 * `fix` replaces the run with `<x> <op> <term1> + <term2> + …;` (`op` is `+=` for the
 * plain arm, `=` for the bonus arm), each term taken VERBATIM from its own span and
 * wrapped in parens when its root node does not provably bind at least as tight as `+`
 * (`RefShape.atomExprKinds` / `atomChainKinds` / `additiveOperandUnwrapKinds` plus the
 * postfix/prefix/call/field/index/new/paren seams — anything absent from that whitelist
 * is wrapped, never assumed safe). Needs `addAssignKind`, `identKind`,
 * `exprStatementKind` and `controlFlowSupport` (any unset makes the check a no-op);
 * `assignKind` gates the bonus arm alone. The statement-list containers scanned are
 * `controlFlowSupport.blockKinds()` PLUS `caseBranchKind` / `defaultBranchKind` (a
 * `switch` case body, scanned the same way — see the class doc above).
 */
@:nullSafety(Strict)
final class JoinStringAppend implements Check implements DefaultOff {

	private static inline final RULE_ID: String = 'join-string-append';

	/** A binary op node (`Assign` / `AddAssign`) has exactly [target, value] children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** Declared target types associative accumulation is sound for. */
	private static final ACCEPTED_TARGET_TYPES: Array<String> = ['String', 'Int'];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a run of x += e; statements (optionally led by x = e0;) on the same target, joinable into one append';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin, files);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> =
				RefactorSupport.collectCommentTokens(plugin.lexicalRegions(entry.source));
			final declaredTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, entry.source);
			final matches: Array<Match> = [];
			collectMatches(tree, tree, entry.source, comments, seams, declaredTypeSources, matches);
			// The operator gate is asked LAST, after every cheaper gate has passed: the per-file type
			// resolver it needs is built on first demand, so a run that never gets this far never
			// pays for one — and on a tree that overloads nothing the answer is one index lookup.
			for (m in matches) if (builtinAppend(m, seams, entry.file, entry.source, tree)) violations.push({
				file: entry.file,
				span: m.anchorSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this run of ${m.termCount} statements on `${m.target}` can be joined into a single append'
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final seams: Null<Seams> = readSeams(plugin, [{ file: violations[0].file, source: source }]);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(plugin.lexicalRegions(source));
		final declaredTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final matches: Array<Match> = [];
		collectMatches(tree, tree, source, comments, seams, declaredTypeSources, matches);
		final byKey: Map<String, Match> = [];
		for (m in matches) byKey['${m.anchorSpan.from}:${m.anchorSpan.to}'] = m;

		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.replacementText }))
		);
	}

	/** Bundle the required grammar seams, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final addAssignKind: Null<String> = shape.addAssignKind;
		if (addAssignKind == null) return null;
		final identKind: String = shape.identKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		// A `switch` case body is a statement LIST exactly like a block's, but it is
		// deliberately NOT one of `ControlFlowSupport.blockKinds()` (that set's other
		// consumers, e.g. `tail-merge`, reason about fall-through, which a case body does
		// not have to the same statement list). Scanned here too, alongside the true
		// blocks: `CaseBranch`'s leading pattern (and optional guard) child never matches
		// `openingTerm`'s `exprStmtKind` shape, so it is skipped as a harmless non-match
		// rather than needing an index offset.
		final caseKinds: Array<String> = [for (k in [shape.caseBranchKind, shape.defaultBranchKind]) if (k != null) k];
		return {
			shape: shape,
			addAssignKind: addAssignKind,
			assignKind: shape.assignKind,
			identKind: identKind,
			exprStmtKind: exprStmtKind,
			blockKinds: support.blockKinds().concat(caseKinds),
			stringInterpKind: shape.stringInterpIdentKind,
			stringLiteralKinds: shape.stringLiteralKinds ?? [],
			safeOperandKinds: safeOperandKindsOf(shape),
			selection: OperatorSelection.of(plugin, files)
		};
	}

	/**
	 * The kinds that provably bind at least as tight as `+` when spliced as one of ITS
	 * operands — the atomic vocabulary (`atomExprKinds`), transparent dotted chains
	 * (`atomChainKinds`), the strictly-tighter arithmetic tier (`additiveOperandUnwrapKinds`:
	 * `*` / `/` / `%`), and the remaining postfix / prefix / primary seams (call, field,
	 * index, `new`, already-parenthesized, unary `-` / `!`, `++`). A kind absent from the
	 * result — every binary operator at or below the additive tier (`+`, `-`, comparisons,
	 * `&&`/`||`, `??`, a ternary, an assignment) — is WRAPPED by `operandText`; unset seams
	 * simply drop from the whitelist, never widen it.
	 */
	private static function safeOperandKindsOf(shape: RefShape): Array<String> {
		final out: Array<String> = (
			shape.atomExprKinds ?? []
		).concat(shape.atomChainKinds ?? []).concat(shape.additiveOperandUnwrapKinds ?? []);
		for (k in [
			shape.callKind,
			shape.fieldAccessKind,
			shape.indexAccessKind,
			shape.newExprKind,
			shape.negationKind,
			shape.notKind,
			shape.postIncrKind,
			shape.arrayLiteralKind,
			shape.parenKind
		]) if (k != null) out.push(k);
		return out;
	}

	/**
	 * Whether the `+=` the join COLLAPSES is the language's own.
	 *
	 * The rewrite turns N appends into one, so an overloaded `+=` runs its body once instead of N
	 * times: measured on an `abstract Route(String)` whose `@:op(A += B)` inserts a separator,
	 * `r += 'a'; r += 'b'` is `root/a/b` while the joined `r += 'a' + 'b'` is `root/ab`. The type
	 * gate cannot catch it — a string-literal term is precisely what makes such a run look
	 * String-typed — so the proof has to come from the target's DECLARATION.
	 *
	 * Asked about the target alone rather than the whole statement: the accumulation runs on that
	 * one type, and the `+` the fix introduces between terms is already covered by the type gate
	 * (a literal term, or a `String` / `Int` declared target). See `OperatorSelection`.
	 */
	private static function builtinAppend(m: Match, s: Seams, file: String, source: String, tree: QueryNode): Bool {
		final selection: Null<OperatorSelection> = s.selection;
		final kinds: Array<String> = [s.addAssignKind];
		if (selection == null || !selection.declared(kinds)) return true;
		final types: Null<(QueryNode) -> Null<String>> = selection.typesFor(file, source, tree);
		return selection.verdictOfOperands([m.targetNode], kinds, types).match(Builtin);
	}

	/** Collect every joinable run reachable under `node`. */
	private static function collectMatches(
		node: QueryNode, tree: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		declaredTypeSources: () -> Map<Int, String>, out: Array<Match>
	): Void {
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			var i: Int = 0;
			while (i < kids.length) {
				final m: Null<Match> = tryMatchRunAt(kids, i, tree, source, comments, s, declaredTypeSources);
				if (m != null) {
					out.push(m);
					i += m.termCount;
				} else {
					i++;
				}
			}
		}
		for (c in node.children) collectMatches(c, tree, source, comments, s, declaredTypeSources, out);
	}

	/**
	 * The maximal joinable run starting exactly at `kids[i]`, or null when `kids[i]` does
	 * not open one (not an `x = e0;` / `x += e1;` on a bare identifier) or the run — after
	 * every gate, including the self-reference truncation — never reaches 2 terms.
	 */
	private static function tryMatchRunAt(
		kids: Array<QueryNode>, i: Int, tree: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		declaredTypeSources: () -> Map<Int, String>
	): Null<Match> {
		final head: Null<{ target: QueryNode, rhs: QueryNode, isBonus: Bool }> = openingTerm(kids[i], s);
		if (head == null) return null;
		final name: Null<String> = head.target.name;
		if (name == null) return null;

		final terms: Array<QueryNode> = [head.rhs];
		var j: Int = i + 1;
		while (j < kids.length) {
			final next: Null<QueryNode> = continuationRhs(kids[j], name, s);
			if (next == null) break;
			if (referencesName(next, name, s)) break; // self-reference: stop BEFORE this term, don't consume it
			terms.push(next);
			j++;
		}
		if (terms.length < 2) return null;

		if (!typeGateOk(head.target, terms, tree, s, declaredTypeSources)) return null;

		final first: QueryNode = kids[i];
		final last: QueryNode = kids[j - 1];
		final firstSpan: Null<Span> = first.span;
		final lastSpan: Null<Span> = last.span;
		final anchorSpan: Null<Span> = first.span;
		if (firstSpan == null || lastSpan == null || anchorSpan == null) return null;
		if (droppedComment(firstSpan, lastSpan.to, terms, comments)) return null;

		final op: String = head.isBonus ? '=' : '+=';
		final text: String = '$name $op ${[for (t in terms) operandText(t, source, s)].join(' + ')};';
		return {
			anchorSpan: anchorSpan,
			editSpan: new Span(firstSpan.from, lastSpan.to),
			replacementText: text,
			target: name,
			targetNode: head.target,
			termCount: terms.length
		};
	}

	/**
	 * Whether `stmt` opens a run: `x = e0;` (bonus arm) or `x += e1;` (plain arm) on a
	 * bare-identifier target. Null for anything else.
	 */
	private static function openingTerm(stmt: QueryNode, s: Seams): Null<{ target: QueryNode, rhs: QueryNode, isBonus: Bool }> {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final binary: QueryNode = stmt.children[0];
		if (binary.children.length != BINARY_CHILD_COUNT) return null;
		final target: QueryNode = binary.children[0];
		return if (target.kind != s.identKind || target.name == null)
			null
		else if (binary.kind == s.addAssignKind)
			{ target: target, rhs: binary.children[1], isBonus: false }
		else if (s.assignKind != null && binary.kind == s.assignKind)
			{ target: target, rhs: binary.children[1], isBonus: true }
		else
			null;
	}

	/** The right-hand side of `stmt` when it is `name += e;` on the SAME bare identifier, else null. */
	private static function continuationRhs(stmt: QueryNode, name: String, s: Seams): Null<QueryNode> {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final binary: QueryNode = stmt.children[0];
		if (binary.kind != s.addAssignKind || binary.children.length != BINARY_CHILD_COUNT) return null;
		final target: QueryNode = binary.children[0];
		return target.kind == s.identKind && target.name == name ? binary.children[1] : null;
	}

	/**
	 * Whether any descendant of `node` is an occurrence of the local `name` — either a
	 * plain `identKind` reference or a `stringInterpKind` one (a braceless `$name` inside
	 * a single-quoted string, which projects as a distinct kind, not `identKind`).
	 */
	private static function referencesName(node: QueryNode, name: String, s: Seams): Bool {
		return (node.kind == s.identKind || node.kind == s.stringInterpKind) && node.name == name
			|| node.children.exists(c -> referencesName(c, name, s));
	}

	/**
	 * Whether the run's target type soundly accumulates under `+`: any term is a string
	 * literal (proves the whole chain String — Haxe would not otherwise type-check mixing
	 * it in), else the target's own explicit declared type, one `Null<…>` layer unwrapped,
	 * is `String` or `Int`. An explicitly `Float` target refuses outright — `+` is not
	 * associative under rounding. Anything else (unresolved, inferred, a custom type) is a
	 * safe miss.
	 */
	private static function typeGateOk(
		target: QueryNode, terms: Array<QueryNode>, tree: QueryNode, s: Seams, declaredTypeSources: () -> Map<Int, String>
	): Bool {
		for (t in terms) if (s.stringLiteralKinds.contains(t.kind)) return true;
		final declared: Null<String> = resolvedTargetType(target, tree, s, declaredTypeSources);
		return declared != 'Float' && declared != null && ACCEPTED_TARGET_TYPES.contains(declared);
	}

	/** The target's explicit declared type source, one `Null<…>` wrapper unwrapped, or null when unresolved. */
	private static function resolvedTargetType(
		target: QueryNode, tree: QueryNode, s: Seams, declaredTypeSources: () -> Map<Int, String>
	): Null<String> {
		final raw: Null<String> = TypeResolver.identDeclaredTypeSource(target, s.shape, tree, declaredTypeSources, false);
		return raw == null ? null : unwrapNullableType(StringTools.trim(raw), s.shape);
	}

	/** `T` from a single `Null<T>` wrapper application (`shape.nullableWrapperTypeNames`), else the input unchanged. */
	private static function unwrapNullableType(t: String, shape: RefShape): String {
		final lt: Int = t.indexOf('<');
		if (lt <= 0 || !t.endsWith('>')) return t;
		final outer: String = t.substring(0, lt);
		final wrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		return wrappers.contains(outer) ? t.substring(lt + 1, t.length - 1) : t;
	}

	/** `term`'s own verbatim source text, wrapped in parens when its root kind is not a provable `+`-safe operand. */
	private static function operandText(term: QueryNode, source: String, s: Seams): String {
		final span: Null<Span> = term.span;
		if (span == null) return '';
		final text: String = source.substring(span.from, span.to);
		return s.safeOperandKinds.contains(term.kind) ? text : '($text)';
	}

	/**
	 * Whether a comment sits inside the merged region `[from, to)` but OUTSIDE every
	 * term's own span — such a comment (on the target name, an operator, or between
	 * statements) would be dropped by the rebuild, so the whole run is refused rather than
	 * hoisted.
	 */
	private static function droppedComment(
		firstSpan: Span, to: Int, terms: Array<QueryNode>, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		for (tok in comments) if (tok.from >= firstSpan.from && tok.to <= to) {
			var inTerm: Bool = false;
			for (t in terms) {
				final ts: Null<Span> = t.span;
				if (!(ts != null && tok.from >= ts.from && tok.to <= ts.to)) continue;
				inTerm = true;
				break;
			}
			if (!inTerm) return true;
		}
		return false;
	}

}

/** The seams `JoinStringAppend` reads. */
private typedef Seams = {
	var shape: RefShape;
	var addAssignKind: String;
	var assignKind: Null<String>;
	var identKind: String;
	var exprStmtKind: String;
	var blockKinds: Array<String>;
	var stringInterpKind: Null<String>;
	var stringLiteralKinds: Array<String>;
	var safeOperandKinds: Array<String>;

	/**
	 * The run OPERATOR table, or null when the grammar declares no operator-overload annotation.
	 * The join turns N appends into ONE, so an overloaded `+=` runs its own body once instead of
	 * N times — measured on an `abstract Route(String)` whose `@:op(A += B)` inserts a separator:
	 * `p += 'a'; p += 'b'` is `root/a/b`, the joined `p += 'a' + 'b'` is `root/ab`. The type gate
	 * above does not catch it, because a string-literal term is exactly what makes such a run
	 * look String-typed.
	 */
	var selection: Null<OperatorSelection>;
}

/** One joinable run: the reported anchor (the first statement's span, also the finding key), the replaced region, and the built replacement text. */
private typedef Match = {
	var anchorSpan: Span;
	var editSpan: Span;
	var replacementText: String;
	var target: String;

	/** The target's own identifier node — what the operator gate resolves to a type (`builtinAppend`). */
	var targetNode: QueryNode;
	var termCount: Int;
}
