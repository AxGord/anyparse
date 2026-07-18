package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;

/**
 * Flags a manual counter loop — a `var i = A;` declaration immediately followed
 * by `while (i < B) { BODY; i++; }` — which the user's rule replaces with a range
 * `for`: use `for (i in A...B)` instead of a `while` with a manual `i++`.
 * `Severity.Info`; paired with an autofix (the rewrite is sound only under every gate
 * below, and several — i-not-read-after, no-other-write — are exactly the analyses
 * most likely to hide a subtle bug, so the fix refuses any shape the gates do not admit).
 * Purely structural, so it holds without a type-checker. Grammar-agnostic over
 * `RefShape`.
 *
 * ## The shape it accepts
 *
 * Two ADJACENT statements in one block: a `var i = A;` (NOT `final`) whose single
 * initializer `A` is any expression, then a `while (i < B)` whose braced body ends
 * with exactly `i++;`. The suggestion transcribes `A` and `B` verbatim from source
 * as the range bounds — `for (i in A...B)`.
 *
 * ## Soundness gates (all required for a flag)
 *
 * - **Adjacent var-with-init.** The declaration is a single-variable `var` (a
 *   `final` cannot `i++`, and `mutableLocalDeclKinds` excludes it; a multi-
 *   declaration `var i, j = n` — one node, top-level comma — is skipped) with
 *   exactly one initializer child, the immediately preceding block sibling of the
 *   `while`.
 * - **Condition is exactly `i < B`.** The loop variable is on the LEFT of a strict
 *   less-than (`i <= B`, a reversed `B > i` and a `!=` form are not an `A...B`
 *   range and are skipped).
 * - **Trailing `i++`.** The body is a braced block whose LAST statement is exactly
 *   `i++;` (a `++i` / `i += 1` / `i = i + 1` is not matched), and no OTHER statement
 *   writes `i` — the only direct write of `i` in the body is that trailing
 *   increment (`i--`, `i =`, a nested `i++` all disqualify it).
 * - **`i` not read after the loop.** A range `for` scopes `i` to the loop, whereas
 *   the `while` leaves `i == B` visible afterwards; if `i` is referenced anywhere
 *   after the `while`'s span within the enclosing scope, the transform would drop a
 *   live binding, so it is skipped (positional `RefactorSupport.referencedInRange`).
 * - **`B` is stable.** `A...B` evaluates `B` ONCE while `while (i < B)` evaluates it
 *   each iteration, so `B` must be a value the body cannot change: a numeric literal,
 *   or a plain identifier that is NOT `i` (which would read the counter) and is never
 *   written in the body. Anything else (a call, a field / array access, a compound
 *   expression) is skipped.
 * - **No `continue`.** In the `while` form a `continue` SKIPS the trailing `i++`
 *   (a deliberate retry, or a bug); in a range `for` it advances the counter, so a
 *   body containing any `continue` is skipped. A `break` is fine (same semantics).
 * - **Non-empty body.** The body must hold at least one statement besides the
 *   trailing `i++` (an empty range loop is pointless — skipped to avoid noise).
 * - **No shadowing.** Nothing in the body re-declares `i` (a nested `var i` would
 *   confuse the counter identity).
 * - **No capturing closure.** A range `for` re-scopes `i` per iteration, whereas
 *   the `while`'s `i` is one function-scoped binding a closure captures by
 *   reference; if any lambda / local-function subtree in the enclosing scope
 *   references `i`, the transform would change what the closure observes, so it
 *   is skipped.
 *
 * ## Grammar-agnostic
 *
 * Driven by `whileStmtKind`, `ltKind`, `postIncrKind`, `blockStmtKind`,
 * `exprStatementKind`, `continueStatementKind` and `mutableLocalDeclKinds` (any
 * unset → the check is a no-op), plus `identKind` / `writeParentKinds` (the write
 * scan), `numericLiteralKinds` (a literal bound), `localDeclKinds` (the shadow gate),
 * `lambdaKinds` / `localFunctionKinds` (the closure-capture gate) and `opaqueKinds`
 * to skip reification subtrees.
 */
@:nullSafety(Strict)
final class PreferRangeLoop implements Check {

	/** A `while` node has exactly [condition, body] children. */
	private static inline final WHILE_CHILD_COUNT: Int = 2;

	/** A `<` comparison node has exactly [left, right] children. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	/** Minimum body statements: at least one real statement plus the trailing `i++`. */
	private static inline final MIN_BODY_STATEMENTS: Int = 2;

	/** Cap on the init / bound excerpt length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	/** The `Int` nominal every range operand must not provably differ from. */
	private static inline final INT_TYPE: String = 'Int';

	public function new() {}

	public function id(): String {
		return 'prefer-range-loop';
	}

	public function description(): String {
		return 'a var-counter while loop (var i = A; while (i < B) { … i++; }) replaceable with for (i in A...B)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final dt: Null<Map<Int, String>> = typed == null ? null : typed.declaredTypes(entry.source);
			walk(tree, tree, entry.file, entry.source, dt, s, violations);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged `var i = A; while (i < B) { … i++; }` into
	 * `for (i in A...B) { … }` — dropping the counter declaration and the trailing
	 * increment. A non-atomic lower bound `A` (a ternary, a compound expression) is
	 * parenthesised so it re-parses as the interval's operand regardless of `...`'s
	 * precedence; a comment in any dropped region (see `buildRangeEdit`) refuses the
	 * rewrite, leaving that finding report-only.
	 *
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (seams == null || tree == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final dt: Null<Map<Int, String>> = typed == null ? null : typed.declaredTypes(source);
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(tree, tree, source, dt, s, wanted, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final whileStmtKind: Null<String> = shape.whileStmtKind;
		if (whileStmtKind == null) return null;
		final ltKind: Null<String> = shape.ltKind;
		if (ltKind == null) return null;
		final postIncrKind: Null<String> = shape.postIncrKind;
		if (postIncrKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final continueKind: Null<String> = shape.continueStatementKind;
		if (continueKind == null) return null;
		final mutableKinds: Array<String> = shape.mutableLocalDeclKinds ?? [];
		final closureKinds: Array<String> = (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []);
		final atomicKinds: Array<String> = [
			for (k in [
				(shape.identKind: Null<String>),
				shape.callKind,
				shape.fieldAccessKind,
				shape.forceFieldAccessKind,
				shape.nullSafeAccessKind,
				shape.indexAccessKind,
				shape.newExprKind,
				shape.parenKind,
				shape.boolLitKind
			]) if (k != null) k
		];
		for (n in shape.numericLiteralKinds ?? []) atomicKinds.push(n);
		return mutableKinds.length == 0 ? null : {
			shape: shape,
			whileStmtKind: whileStmtKind,
			ltKind: ltKind,
			postIncrKind: postIncrKind,
			identKind: shape.identKind,
			blockStmtKind: blockStmtKind,
			exprStmtKind: exprStmtKind,
			continueKind: continueKind,
			mutableKinds: mutableKinds,
			localDeclKinds: shape.localDeclKinds ?? [],
			writeParentKinds: shape.writeParentKinds,
			numericLiteralKinds: shape.numericLiteralKinds ?? [],
			closureKinds: closureKinds,
			atomicKinds: atomicKinds,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/**
	 * Descend `node`, testing each adjacent child pair `(decl, while)` and recursing;
	 * `node` doubles as the enclosing scope for the read-after gate. A reification
	 * subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, source: String, dt: Null<Map<Int, String>>, s: Seams, out: Array<Violation>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final v: Null<Violation> = tryMatch(kids[i], kids[i + 1], node, root, file, source, dt, s);
			if (v != null) out.push(v);
		}
		for (c in kids) walk(c, root, file, source, dt, s, out);
	}

	/**
	 * Whether `decl` is a `var i = A;` immediately followed by the qualifying counter
	 * loop `whileNode` inside `scope`; returns the `Info` violation when so, else null.
	 */
	private static function tryMatch(
		decl: QueryNode, whileNode: QueryNode, scope: QueryNode, root: QueryNode, file: String, source: String, dt: Null<Map<Int, String>>,
		s: Seams
	): Null<Violation> {
		final m = analyze(decl, whileNode, scope, root, source, dt, s);
		if (m == null) return null;
		final initSpan: Null<Span> = m.initNode.span;
		final boundSpan: Null<Span> = m.boundNode.span;
		if (initSpan == null || boundSpan == null) return null;
		final a: String = excerpt(source.substring(initSpan.from, initSpan.to));
		final b: String = excerpt(source.substring(boundSpan.from, boundSpan.to));
		return {
			file: file,
			span: m.declSpan,
			rule: 'prefer-range-loop',
			severity: Severity.Info,
			message: 'this var-counter while loop can be for (${m.loopVar} in $a...$b)'
		};
	}

	/** Whether `stmt` is exactly `<loopVar>++;` — an expression statement wrapping a post-increment of the loop variable. */
	private static function isPostIncrementOf(stmt: QueryNode, loopVar: String, s: Seams): Bool {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return false;
		final incr: QueryNode = stmt.children[0];
		if (incr.kind != s.postIncrKind || incr.children.length < 1) return false;
		final target: QueryNode = incr.children[0];
		return target.kind == s.identKind && target.name == loopVar;
	}

	/**
	 * The number of DIRECT writes of `name` in `node`'s subtree — a `writeParentKinds`
	 * node whose first child is an `identKind` named `name` (so `arr[name] = v` /
	 * `obj.name = v`, whose target is not that bare identifier, are reads not writes).
	 * Reification subtrees are not counted.
	 */
	private static function countWritesTo(node: QueryNode, name: String, s: Seams): Int {
		if (s.opaqueKinds.contains(node.kind)) return 0;
		var count: Int = 0;
		if (s.writeParentKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			if (target.kind == s.identKind && target.name == name) count++;
		}
		for (c in node.children) count += countWritesTo(c, name, s);
		return count;
	}

	/** Whether `node`'s subtree contains a node of `kind`, skipping reification subtrees. */
	private static function containsKind(node: QueryNode, kind: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (node.kind == kind) return true;
		for (c in node.children) if (containsKind(c, kind, s)) return true;
		return false;
	}

	/** Whether `node`'s subtree re-declares a local named `name`, skipping reification subtrees. */
	private static function declaresName(node: QueryNode, name: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (s.localDeclKinds.contains(node.kind) && node.name == name) return true;
		for (c in node.children) if (declaresName(c, name, s)) return true;
		return false;
	}


	/** Collapse whitespace runs to single spaces and trim, so a multi-line bound fits one message line. */
	private static function normalize(text: String): String {
		final buf: StringBuf = new StringBuf();
		var prevSpace: Bool = false;
		for (i in 0...text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			final isSpace: Bool = c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
			if (isSpace) {
				if (!prevSpace) buf.addChar(' '.code);
				prevSpace = true;
			} else {
				buf.addChar(c);
				prevSpace = false;
			}
		}
		return StringTools.trim(buf.toString());
	}

	/** The normalized source, truncated with an ellipsis beyond the excerpt cap. */
	private static function excerpt(text: String): String {
		final flat: String = normalize(text);
		return flat.length > EXCERPT_MAX ? flat.substring(0, EXCERPT_MAX) + '…' : flat;
	}

	/** The bound's identifier name when `B` is a bare identifier, else null (a literal bound has no name to track). */
	private static function boundIdentName(bound: QueryNode, s: Seams): Null<String> {
		return bound.kind == s.identKind ? bound.name : null;
	}

	/** The counter variable of a `var i = A;` single-var declaration (not `final`, one initializer, no multi-declaration comma), or null. */
	private static function matchCounterDecl(decl: QueryNode, source: String, s: Seams): Null<String> {
		if (!s.mutableKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final name: Null<String> = decl.name;
		final span: Null<Span> = decl.span;
		if (name == null || span == null) return null;
		final declSource: String = source.substring(span.from, span.to);
		return RefactorSupport.hasTopLevelComma(declSource) ? null : name;
	}

	/**
	 * The bound `B` of a `while (i < B)` whose loop variable is on the LEFT and whose
	 * bound is a simple identifier (not `i`) or a numeric literal, or null.
	 */
	private static function matchCondition(whileNode: QueryNode, loopVar: String, s: Seams): Null<QueryNode> {
		if (whileNode.kind != s.whileStmtKind || whileNode.children.length != WHILE_CHILD_COUNT) return null;
		final cond: QueryNode = whileNode.children[0];
		if (cond.kind != s.ltKind || cond.children.length != COMPARISON_CHILD_COUNT) return null;
		final left: QueryNode = cond.children[0];
		if (left.kind != s.identKind || left.name != loopVar) return null;
		final bound: QueryNode = cond.children[1];
		final boundName: Null<String> = boundIdentName(bound, s);
		final notSimpleBound: Bool = boundName == null && !s.numericLiteralKinds.contains(bound.kind);
		final boundReadsCounter: Bool = boundName != null && boundName == loopVar;
		return notSimpleBound || boundReadsCounter ? null : bound;
	}

	/**
	 * Whether `body` is a braced block ending in exactly `i++;`, with no OTHER write of
	 * `i`, no write of an identifier bound, no `continue`, no re-declaration of `i`, and
	 * at least one statement besides the increment.
	 */
	private static function bodyIsRangeConvertible(body: QueryNode, loopVar: String, bound: QueryNode, s: Seams): Bool {
		if (body.kind != s.blockStmtKind || body.children.length < MIN_BODY_STATEMENTS) return false;
		if (!isPostIncrementOf(body.children[body.children.length - 1], loopVar, s)) return false;
		if (countWritesTo(body, loopVar, s) != 1) return false;
		final boundName: Null<String> = boundIdentName(bound, s);
		final boundWritten: Bool = boundName != null && countWritesTo(body, boundName, s) != 0;
		return !boundWritten && !containsKind(body, s.continueKind, s) && !declaresName(body, loopVar, s);
	}


	/**
	 * Whether any lambda / local-function subtree within `scope` references `loopVar`
	 * (a word-boundary match inside the closure's span). Such a closure captures the
	 * `while`'s one function-scoped counter by reference, so the range `for`'s
	 * per-iteration re-scoping would change what it observes — a conservative bail.
	 */
	private static function capturedByClosure(scope: QueryNode, source: String, loopVar: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(scope.kind)) return false;
		if (s.closureKinds.contains(scope.kind)) {
			final span: Null<Span> = scope.span;
			if (span != null && RefactorSupport.referencedInRange(source, loopVar, span.from, span.to, [])) return true;
		}
		for (c in scope.children) if (capturedByClosure(c, source, loopVar, s)) return true;
		return false;
	}


	/**
	 * The matched counter loop `(decl, whileNode)` inside `scope` — the loop variable,
	 * its init and bound nodes, the `while` and its body block — or null when any gate
	 * fails. Shared by `tryMatch` (report) and `fixWalk` (rewrite) so both see one
	 * decision. Haxe's `...` interval requires `Int` operands, so a counter or bound
	 * that is PROVABLY non-Int — a float-syntax literal, a declared non-Int counter
	 * type, or an identifier whose declared type resolves to a non-Int nominal — also
	 * fails; an unannotated or unresolvable type still matches (the residual risk of an
	 * inferred-Float operand is undetectable without a type checker).
	 */
	private static function analyze(
		decl: QueryNode, whileNode: QueryNode, scope: QueryNode, root: QueryNode, source: String, dt: Null<Map<Int, String>>, s: Seams
	): Null<{
		declSpan: Span,
		loopVar: String,
		initNode: QueryNode,
		boundNode: QueryNode,
		whileNode: QueryNode,
		body: QueryNode
	}> {
		final loopVar: Null<String> = matchCounterDecl(decl, source, s);
		if (loopVar == null) return null;
		final bound: Null<QueryNode> = matchCondition(whileNode, loopVar, s);
		if (bound == null) return null;
		final body: QueryNode = whileNode.children[1];
		if (!bodyIsRangeConvertible(body, loopVar, bound, s)) return null;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = decl.children[0].span;
		final whileSpan: Null<Span> = whileNode.span;
		final scopeSpan: Null<Span> = scope.span;
		if (declSpan == null || initSpan == null || whileSpan == null || scopeSpan == null || bound.span == null) return null;
		if (declaredNonInt(declSpan.from, dt)) return null;
		if (provablyNonInt(decl.children[0], root, source, dt, s)) return null;
		if (provablyNonInt(bound, root, source, dt, s)) return null;
		if (RefactorSupport.referencedInRange(source, loopVar, whileSpan.to, scopeSpan.to, [])) return null;
		if (capturedByClosure(scope, source, loopVar, s)) return null;
		final result = {
			declSpan: declSpan,
			loopVar: loopVar,
			initNode: decl.children[0],
			boundNode: bound,
			whileNode: whileNode,
			body: body
		};
		return result;
	}

	/** Mirror of `walk` for the fix path: emit the range-loop rewrite for each wanted, convertible loop. */
	private static function fixWalk(
		node: QueryNode, root: QueryNode, source: String, dt: Null<Map<Int, String>>, s: Seams, wanted: Array<String>,
		out: Array<{ span: Span, text: String }>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final m = analyze(kids[i], kids[i + 1], node, root, source, dt, s);
			if (!(m != null && wanted.contains('${m.declSpan.from}:${m.declSpan.to}'))) continue;
			final e: Null<{ span: Span, text: String }> = buildRangeEdit(m, source, s);
			if (e != null) out.push(e);
		}
		for (c in kids) fixWalk(c, root, source, dt, s, wanted, out);
	}

	/**
	 * The single `{span, text}` replacing `[decl start, while end)` with the range loop —
	 * or null when a comment sits in ANY region the rewrite drops: before the init inside
	 * the declaration, between the init and the body's `{` (covering the decl tail, the
	 * gap to the `while`, and its condition header), or between the increment and the
	 * body's `}`. The interior `[body {, increment)` and the init/bound spans are carried
	 * verbatim, so comments there survive.
	 *
	 */
	private static function buildRangeEdit(
		m: {
			declSpan: Span,
			loopVar: String,
			initNode: QueryNode,
			boundNode: QueryNode,
			whileNode: QueryNode,
			body: QueryNode
		},
		source: String, s: Seams
	): Null<{ span: Span, text: String }> {
		final incr: QueryNode = m.body.children[m.body.children.length - 1];
		final bodySpan: Null<Span> = m.body.span;
		final incrSpan: Null<Span> = incr.span;
		final whileSpan: Null<Span> = m.whileNode.span;
		final initSpan: Null<Span> = m.initNode.span;
		final boundSpan: Null<Span> = m.boundNode.span;
		if (bodySpan == null || incrSpan == null || whileSpan == null || initSpan == null || boundSpan == null) return null;
		if (gapHasComment(source, incrSpan.to, bodySpan.to - 1)) return null;
		if (gapHasComment(source, m.declSpan.from, initSpan.from)) return null;
		if (gapHasComment(source, initSpan.to, bodySpan.from)) return null;
		final interior: String = source.substring(bodySpan.from + 1, incrSpan.from);
		final rawStart: String = source.substring(initSpan.from, initSpan.to);
		final start: String = s.atomicKinds.contains(m.initNode.kind) ? rawStart : '($rawStart)';
		final boundText: String = source.substring(boundSpan.from, boundSpan.to);
		final text: String = 'for (${m.loopVar} in $start...$boundText) {' + interior + '}';
		return { span: new Span(m.declSpan.from, whileSpan.to), text: text };
	}

	/** Whether the `[from, to)` gap holds a `//` or `/*` comment opener (a region the rewrite would drop). */
	private static function gapHasComment(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final gap: String = source.substring(from, to);
		return gap.indexOf('//') != -1 || gap.indexOf('/*') != -1;
	}


	/** Whether the declaration binding at `from` carries an explicit non-`Int` nominal type annotation (per `declaredTypes`). */
	private static function declaredNonInt(from: Int, dt: Null<Map<Int, String>>): Bool {
		if (dt == null) return false;
		final typeName: Null<String> = dt[from];
		return typeName != null && typeName != INT_TYPE;
	}

	/**
	 * Whether `node` is PROVABLY not an `Int` range operand — a numeric literal in
	 * float syntax (a `.` / exponent in a non-hex literal), or a bare identifier whose
	 * binding's declared type resolves to a non-`Int` nominal. Unannotated /
	 * unresolvable stays false (the check is type-checker-free by design).
	 */
	private static function provablyNonInt(node: QueryNode, root: QueryNode, source: String, dt: Null<Map<Int, String>>, s: Seams): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return false;
		if (s.numericLiteralKinds.contains(node.kind)) return isFloatSyntax(source.substring(span.from, span.to));
		if (node.kind != s.identKind || dt == null) return false;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, s.shape);
		return bindingFrom != null && declaredNonInt(bindingFrom, dt);
	}

	/** Whether a numeric literal's source is float syntax — a `.` or a decimal exponent (hex literals are `Int`). */
	private static function isFloatSyntax(text: String): Bool {
		return !StringTools.startsWith(text, '0x') && !StringTools.startsWith(text, '0X')
			&& (text.indexOf('.') != -1 || text.indexOf('e') != -1 || text.indexOf('E') != -1);
	}

}

/**
 * The `RefShape` kinds `PreferRangeLoop` reads (plus the shape itself for binding resolution), bundled once so the walkers take one argument.
 */
private typedef Seams = {
	var shape: RefShape;
	var whileStmtKind: String;
	var ltKind: String;
	var postIncrKind: String;
	var identKind: String;
	var blockStmtKind: String;
	var exprStmtKind: String;
	var continueKind: String;
	var mutableKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var writeParentKinds: Array<String>;
	var numericLiteralKinds: Array<String>;
	var closureKinds: Array<String>;
	var atomicKinds: Array<String>;
	var opaqueKinds: Array<String>;
}
