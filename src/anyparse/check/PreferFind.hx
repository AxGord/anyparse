package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.RefactorSupport;

using Lambda;

/**
 * Flags a manual first-match `for` loop — one that iterates a collection to return
 * (or capture-and-break) the first element satisfying a condition — which the
 * user's rule replaces with `Lambda.find`: use `.find()` instead of manually
 * iterating to find the first matching element. `Severity.Info`, with an autofix that rewrites the loop to `xs.find(x -> cond)` and inserts a `using Lambda;` when the file lacks one. Purely structural, so it holds without a
 * type-checker. Grammar-agnostic over `RefShape`.
 *
 * ## The three shapes it accepts
 *
 * - **Form A (return).** `for (x in xs) if (cond) return x;` whose immediately
 *   following block sibling is a value-returning `return` — the fallback. The
 *   `if`-body may be bare (`return x;`) or a `{ … }` wrapping exactly one such
 *   return, and the `for`-body may itself be a single-statement `{ … }` around the
 *   `if`. A `return null;` fallback is the pure `xs.find(x -> cond)`; any other
 *   value fallback is find-able as `xs.find(x -> cond) ?? <fallback>`, and the
 *   message reflects whichever applies.
 * - **Form B (break).** `var r = null; for (x in xs) if (cond) { r = x; break; }` —
 *   a null-initialized local immediately followed by a loop whose `if`-body is
 *   exactly the assignment of the loop variable to that local, then a `break`. The
 *   local's later use is the point (`r = xs.find(x -> cond)`), so nothing after the
 *   loop is inspected. The fix folds the `find` into the declaration and deletes the
 *   loop.
 * - **Form B under a guard.** `var r = null; if (g) for (x in xs) if (cond) { r = x; break; }`
 *   — the same loop as the guard's SOLE statement, under an ARBITRARY guard `g`. Here
 *   the declaration KEEPS its `null` (that is exactly what a false `g` must still
 *   observe) and only the loop collapses: `if (g) r = xs.find(x -> cond);`. Every
 *   Form-B gate carries over unchanged, plus an `else`-less guard.
 *
 * ## Soundness gates
 *
 * - **Returned / assigned value is the loop variable.** `return x` / `r = x` where
 *   `x` is the loop variable; `return x.field` or any transformed value is
 *   `map` / `filter` territory and is skipped.
 * - **No `else`.** The `if` must have no `else` branch (a two-way choice is not a
 *   find) — and, for the guarded form, neither may the guard.
 * - **Form A fallback is a value return.** The trailing sibling must be a
 *   value-returning `return`; a `return null;` yields the plain suggestion, a
 *   non-null fallback the `?? <fallback>` suffix.
 * - **Form B body is exactly assign-then-break.** The `if`-body is a two-statement
 *   block: the loop-variable-to-local assignment, then a `break` (a `continue`
 *   would find the LAST match, so the dedicated break kind is required); the
 *   declaration's initializer must be exactly `null`.
 * - **No key-value loop.** `for (k => v in m)` is skipped — `.find` iterates an
 *   iterable's values, not map key-value pairs. A call iterable (`xs.keys()` / `<expr>.m()`) or a range `a...b` is likewise skipped — a call may yield an `Iterator`, not an `Iterable`, so `Lambda.find` would not compile, and a call result's type is unknowable without types.
 * - **Adjacency.** The loop and its trailing `return` (Form A), or the declaration
 *   and its loop / guard (Form B), must be real, immediately adjacent block siblings.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `returnStatementKind`, `blockStmtKind`, `nullLiteralKind`,
 * `identKind` and `ifStatementKinds` (any unset → the check is a no-op), with
 * `opaqueKinds` to skip reification subtrees. Form B additionally needs
 * `localDeclKinds`, `exprStatementKind`, `assignKind` and `breakStatementKind`; any
 * of those unset disables both break forms while the return form still runs.
 */
@:nullSafety(Strict)
final class PreferFind implements Check {

	/**
	 * A `for` node has exactly [iterable, body] children; the loop variable is its name. A
	 * key-value loop carries a third — its VALUE binder — and is refused before the count.
	 */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A Form-B `if`-body block has exactly [assignment-statement, break] children. */
	private static inline final BREAK_BODY_CHILD_COUNT: Int = 2;

	/** An assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** Cap on the condition (and fallback) excerpt length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	/** The module whose `find` the rewrite calls — the `using` the fix inserts when the file lacks it. */
	private static inline final LAMBDA_MODULE: String = 'Lambda';

	/** The extension method the rewrite emits — the name a second `using` must be proven not to supply. */
	private static inline final FIND_METHOD: String = 'find';

	public function new() {}

	public function id(): String {
		return 'prefer-find';
	}

	public function description(): String {
		return 'a manual first-match for loop (return or capture-and-break) replaceable with Lambda.find';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(tree, entry.file, entry.source, s, violations);
		}
		return violations;
	}

	/**
	 * Rewrite each provable first-match loop to `xs.find(v -> cond)`. Form A
	 * (`for … if (cond) return v; return f;`) collapses the loop and its trailing
	 * fallback into one `return xs.find(v -> cond) [?? f];`; Form B
	 * (`var r = null; for … if (cond) { r = v; break; }`) rewrites the declaration's
	 * `null` initializer to the `find` and deletes the loop; the GUARDED Form B
	 * (`var r = null; if (g) for … `) leaves the declaration's `null` in place — a
	 * false `g` must still observe it — and replaces only the loop, in place, with
	 * `r = xs.find(v -> cond);`. When ANY loop is rewritten
	 * and the file lacks a `using Lambda;`, one is inserted after the last import so
	 * `.find` resolves. Beyond the detector's shape gates this fix is stricter — a loop
	 * stays a report-only finding (no edit) unless its condition is provably
	 * side-effect-free (no assignment / `++` / `--` / `new` / free-function call; only
	 * field reads and accessor-style method calls pass) and, for both break forms, the declared
	 * type tolerates a `Null<T>` result (no type, or `Null<…>`). An edit that would
	 * overlap an already-accepted one is skipped (the loser stays a finding).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		// The emitted `xs.find(...)` must reach `Lambda.find`. Haxe resolves static extensions in
		// REVERSE declaration order and the inserted `using Lambda;` goes ABOVE any existing run,
		// so a second `using` declaring `find` would win the new call — refuse the whole file
		// rather than emit a silently retargeted one. The gates run on the plugin's resolution
		// index when it has one, the caller's otherwise.
		final symbols: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		if (CheckScan.conflictingUsing(CheckScan.usingModules(tree), LAMBDA_MODULE, FIND_METHOD, plugin, () -> symbols, [])) return [];
		final byKey: Map<String, FixCandidate> = [];
		collectFixCandidates(tree, source, s, byKey);
		final edits: Array<{ span: Span, text: String }> = [];
		var rewrote: Bool = false;
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final cand: Null<FixCandidate> = byKey['${span.from}:${span.to}'];
			if (cand == null) continue;
			final candEdits: Null<Array<{ span: Span, text: String }>> = buildEdits(cand, source, s);
			if (candEdits == null || RefactorSupport.editsOverlapAny(candEdits, edits)) continue;
			for (e in candEdits) edits.push(e);
			rewrote = true;
		}
		if (rewrote && !CheckScan.hasUsingModule(tree, LAMBDA_MODULE)) {
			final usingEdit: { span: Span, text: String } = CheckScan.usingInsertEdit(tree, LAMBDA_MODULE);
			if (!RefactorSupport.editsOverlapAny([usingEdit], edits)) edits.push(usingEdit);
		}
		return edits;
	}

	/**
	 * Bundle the required + optional `RefShape` kinds, or null when a required one is unset — including the statement-list kinds every form pairs siblings within (the check is then a no-op).
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final forStmtKind: Null<String> = shape.forStmtKind;
		if (forStmtKind == null) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		if (nullLitKind == null) return null;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		// Every form pairs adjacent statement-list siblings, so without the statement-list kinds
		// the check has nothing to walk — a no-op stated up front rather than one that emerges.
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		return ifKinds.length == 0 || blockKinds.length == 0 ? null : {
			forStmtKind: forStmtKind,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind,
			nullLitKind: nullLitKind,
			identKind: shape.identKind,
			ifKinds: ifKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			exprStmtKind: shape.exprStatementKind,
			assignKind: shape.assignKind,
			breakKind: shape.breakStatementKind,
			intervalKind: shape.intervalKind,
			callKind: shape.callKind,
			newExprKind: shape.newExprKind,
			fieldAccessKind: shape.fieldAccessKind,
			nullSafeAccessKind: shape.nullSafeAccessKind,
			forceFieldAccessKind: shape.forceFieldAccessKind,
			indexAccessKind: shape.indexAccessKind,
			parenKind: shape.parenKind,
			ternaryKind: shape.ternaryKind,
			blockKinds: blockKinds
		};
	}

	/** Descend `node`, testing each adjacent child pair against both forms and recursing; skip reification subtrees. */
	private static function walk(node: QueryNode, file: String, source: String, s: Seams, out: Array<Violation>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		if (s.blockKinds.contains(node.kind)) for (i in 0...kids.length - 1) {
			final v: Null<Violation> = tryReturnForm(kids[i], kids[i + 1], file, source, s) ?? tryBreakForm(
				kids[i], kids[i + 1], file, source, s
			) ?? tryGuardedBreakForm(kids[i], kids[i + 1], file, source, s);
			if (v != null) out.push(v);
		}
		for (c in kids) walk(c, file, source, s, out);
	}

	/**
	 * Form A: `forNode` is `for (v in xs) if (cond) return v;` and `next` is a
	 * value-returning `return` fallback. Returns the violation when so, else null.
	 */
	private static function tryReturnForm(forNode: QueryNode, next: QueryNode, file: String, source: String, s: Seams): Null<Violation> {
		final head: Null<{
			loopVar: String,
			iterable: QueryNode,
			cond: QueryNode,
			then: QueryNode
		}> = forIfHead(forNode, s);
		if (head == null) return null;
		final returned: Null<QueryNode> = returnValue(head.then, s);
		if (returned == null || returned.kind != s.identKind || returned.name != head.loopVar) return null;
		if (next.kind != s.returnKind || next.children.length < 1) return null;
		final fallback: QueryNode = next.children[0];
		final tail: String = fallback.kind == s.nullLitKind ? '' : coalesceTail(fallback, source);
		return buildViolation(forNode, head.iterable, head.loopVar, head.cond, tail, file, source);
	}

	/**
	 * Form B: `decl` is a null-initialized local and `forNode` is
	 * `for (v in xs) if (cond) { r = v; break; }`. Returns the violation when so, else null.
	 */
	private static function tryBreakForm(decl: QueryNode, forNode: QueryNode, file: String, source: String, s: Seams): Null<Violation> {
		final declName: Null<String> = nullInitLocalName(decl, s);
		if (declName == null) return null;
		final head: Null<{
			loopVar: String,
			iterable: QueryNode,
			cond: QueryNode,
			then: QueryNode
		}> = forIfHead(forNode, s);
		return head != null && isAssignBreakBody(head.then, declName, head.loopVar, s)
			? buildViolation(forNode, head.iterable, head.loopVar, head.cond, '', file, source)
			: null;
	}

	/**
	 * Form B under a guard: `decl` is a null-initialized local and `ifNode` is
	 * `if (g) for (v in xs) if (cond) { r = v; break; }` — the capture-and-break loop is the
	 * guard's SOLE statement. Returns the violation, anchored at the loop, when so, else null.
	 */
	private static function tryGuardedBreakForm(
		decl: QueryNode, ifNode: QueryNode, file: String, source: String, s: Seams
	): Null<Violation> {
		final found: Null<GuardedBreak> = guardedBreakOf(decl, ifNode, s);
		return found == null ? null : buildViolation(found.forNode, found.iterable, found.loopVar, found.cond, '', file, source);
	}

	/**
	 * The guarded capture-and-break shape `decl` / `ifNode` form, or null when they are not it:
	 * a null-initialized local followed by an `else`-less `if` whose sole statement is
	 * `for (v in xs) if (cond) { <declName> = v; break; }`.
	 *
	 * The guard `g` is ARBITRARY and kept verbatim — what makes the rewrite sound is the `null`
	 * initializer, which is exactly the value the loop leaves behind when it matches nothing, so
	 * `if (g) r = xs.find(v -> cond);` observes what the loop did on both the match and the
	 * no-match path. An `else` branch is refused: the loop is then no longer the guard's sole
	 * statement, and the shape the transformation is proven on is `if (g) <loop>`.
	 */
	private static function guardedBreakOf(decl: QueryNode, ifNode: QueryNode, s: Seams): Null<GuardedBreak> {
		final declName: Null<String> = nullInitLocalName(decl, s);
		if (declName == null || !s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		// The guard runs BETWEEN the declaration and the loop — the one place the unguarded form
		// has nothing at all — so a guard that WRITES the holder breaks the `null` premise:
		// `if ((r = seed) != null) for …` leaves `seed` behind on the no-match path, where the
		// rewrite leaves `null`. A local can only be written through its own name (nothing else
		// can reach it), so refusing any MENTION of it in the guard is exact.
		if (mentionsName(ifNode.children[0], declName, s)) return null;
		final loop: QueryNode = unwrapSole(ifNode.children[1], s);
		final head: Null<{
			loopVar: String,
			iterable: QueryNode,
			cond: QueryNode,
			then: QueryNode
		}> = forIfHead(loop, s);
		if (head == null || !isAssignBreakBody(head.then, declName, head.loopVar, s)) return null;
		return {
			forNode: loop,
			declName: declName,
			loopVar: head.loopVar,
			iterable: head.iterable,
			cond: head.cond
		};
	}

	/**
	 * Whether `name` occurs as an identifier anywhere in `node`'s subtree. An opaque reification
	 * subtree counts as a possible occurrence (conservative).
	 */
	private static function mentionsName(node: QueryNode, name: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return true;
		if (node.kind == s.identKind && node.name == name) return true;
		return node.children.exists(c -> mentionsName(c, name, s));
	}

	/** The name of a `var`/`final` local initialized to exactly `null` — Form B's captured-value holder — or null otherwise. */
	private static function nullInitLocalName(decl: QueryNode, s: Seams): Null<String> {
		return s.localDeclKinds.contains(decl.kind) && decl.children.length == 1 && decl.children[0].kind == s.nullLitKind
			? decl.name
			: null;
	}

	/** Whether `body` is exactly `{ <declName> = <loopVar>; break; }` — the assignment then a `break`, nothing else. */
	private static function isAssignBreakBody(body: QueryNode, declName: String, loopVar: String, s: Seams): Bool {
		final exprStmtKind: Null<String> = s.exprStmtKind;
		final assignKind: Null<String> = s.assignKind;
		final breakKind: Null<String> = s.breakKind;
		if (exprStmtKind == null || assignKind == null || breakKind == null) return false;
		if (body.kind != s.blockStmtKind || body.children.length != BREAK_BODY_CHILD_COUNT) return false;
		if (body.children[1].kind != breakKind) return false;
		final assignStmt: QueryNode = body.children[0];
		if (assignStmt.kind != exprStmtKind || assignStmt.children.length != 1) return false;
		final assign: QueryNode = assignStmt.children[0];
		if (assign.kind != assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return false;
		final lhs: QueryNode = assign.children[0];
		final rhs: QueryNode = assign.children[1];
		return lhs.kind == s.identKind && lhs.name == declName && rhs.kind == s.identKind && rhs.name == loopVar;
	}

	/** Assemble the `Info` violation anchored at the loop, with the `xs.find(v -> cond)<tail>` suggestion in the message. */
	private static function buildViolation(
		forNode: QueryNode, iterable: QueryNode, loopVar: String, cond: QueryNode, tail: String, file: String, source: String
	): Null<Violation> {
		final forSpan: Null<Span> = forNode.span;
		final iterSpan: Null<Span> = iterable.span;
		final condSpan: Null<Span> = cond.span;
		if (forSpan == null || iterSpan == null || condSpan == null) return null;
		final iterSrc: String = normalize(source.substring(iterSpan.from, iterSpan.to));
		final condSrc: String = excerpt(source.substring(condSpan.from, condSpan.to));
		final suggestion: String = '$iterSrc.find($loopVar -> $condSrc)$tail';
		return {
			file: file,
			span: forSpan,
			rule: 'prefer-find',
			severity: Severity.Info,
			message: 'this manual first-match loop can be $suggestion'
		};
	}

	/** Unwrap a single-statement `{ … }` block to its sole child; every other node passes through unchanged. */
	private static function unwrapSole(node: QueryNode, s: Seams): QueryNode {
		return node.kind == s.blockStmtKind && node.children.length == 1 ? node.children[0] : node;
	}

	/** The value of a then-branch that is a single value-returning `return` — bare `return e;` or a `{ … }` wrapping one. */
	private static function returnValue(then: QueryNode, s: Seams): Null<QueryNode> {
		if (then.kind == s.returnKind && then.children.length >= 1) return then.children[0];
		if (then.kind == s.blockStmtKind && then.children.length == 1) {
			final only: QueryNode = then.children[0];
			if (only.kind == s.returnKind && only.children.length >= 1) return only.children[0];
		}
		return null;
	}


	/** Whether the iterable is a range `a...b` — its `IntIterator` is not `Iterable`, so `Lambda.find` would not compile. */
	private static function isRangeIterable(iterable: QueryNode, s: Seams): Bool {
		final intervalKind: Null<String> = s.intervalKind;
		return intervalKind != null && iterable.kind == intervalKind;
	}

	/** Whether the iterable is a call — a `.keys()` / `.iterator()` result is an `Iterator`, not `Iterable`, so `Lambda.find` would not compile (a call result's iterability is unknowable without types — skip conservatively). */
	private static function isCallIterable(iterable: QueryNode, s: Seams): Bool {
		final callKind: Null<String> = s.callKind;
		return callKind != null && iterable.kind == callKind;
	}

	/** The ` ?? <fallback>` suffix for a non-null Form-A fallback, or empty when its span is unavailable. */
	private static function coalesceTail(fallback: QueryNode, source: String): String {
		final span: Null<Span> = fallback.span;
		return span == null ? '' : ' ?? ${excerpt(source.substring(span.from, span.to))}';
	}

	/** Collapse whitespace runs to single spaces and trim, so a multi-line expression fits one message line. */
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
		return flat.length > EXCERPT_MAX ? '${flat.substring(0, EXCERPT_MAX)}…' : flat;
	}


	/**
	 * The shared for-if-head destructure both forms start from: `for (v in xs) if (cond) <then>`
	 * — the loop variable, iterable, condition and if-body — or null when `forNode` is not that
	 * shape (wrong kind/arity, a key-value / range / call iterable, or a non-if / else-bearing body).
	 *
	 * The key-value refusal is an explicit MODEL test, and the operand count that follows it is taken
	 * with the VALUE binder filtered OUT. Read together those look redundant — the refusal already
	 * returned — and that is the point: were the refusal ever dropped, a key-value loop would reach
	 * `FOR_CHILD_COUNT` exactly like a single-binder one and be rewritten, so the refusal is the sole
	 * gate and a test can prove it. Counting raw children instead would let arity mask its removal.
	 * `Lambda.find` iterates values, so rewriting a `k => v` loop would bind the value where the loop
	 * bound the key.
	 */
	private static function forIfHead(forNode: QueryNode, s: Seams): Null<{
		loopVar: String,
		iterable: QueryNode,
		cond: QueryNode,
		then: QueryNode
	}> {
		if (forNode.kind != s.forStmtKind || RefactorSupport.hasIterationValueBinder(forNode, s.valueBinderKinds)) return null;
		final operands: Array<QueryNode> = RefactorSupport.loopOperands(forNode, s.valueBinderKinds);
		final loopVar: Null<String> = forNode.name;
		if (loopVar == null || operands.length != FOR_CHILD_COUNT) return null;
		final iterable: QueryNode = operands[0];
		if (isRangeIterable(iterable, s) || isCallIterable(iterable, s)) return null;
		final body: QueryNode = unwrapSole(operands[1], s);
		return !s.ifKinds.contains(body.kind) || body.children.length != IF_NO_ELSE_CHILD_COUNT ? null : {
			loopVar: loopVar,
			iterable: iterable,
			cond: body.children[0],
			then: body.children[1]
		};
	}


	/** Re-run the two-form shape analysis, keying a fix candidate by its loop's `from:to` span — the same key `run` anchors a violation on. */
	private static function collectFixCandidates(node: QueryNode, source: String, s: Seams, out: Map<String, FixCandidate>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		if (s.blockKinds.contains(node.kind)) for (i in 0...kids.length - 1) {
			final a: QueryNode = kids[i];
			final b: QueryNode = kids[i + 1];
			final headA: Null<{
				loopVar: String,
				iterable: QueryNode,
				cond: QueryNode,
				then: QueryNode
			}> = forIfHead(a, s);
			if (headA != null) {
				final returned: Null<QueryNode> = returnValue(headA.then, s);
				if (
					returned != null && returned.kind == s.identKind && returned.name == headA.loopVar && b.kind == s.returnKind
					&& b.children.length >= 1
				) {
					final span: Null<Span> = a.span;
					if (span != null) out['${span.from}:${span.to}'] = {
						form: FindForm.Return,
						declName: null,
						forNode: a,
						sibling: b,
						loopVar: headA.loopVar,
						iterable: headA.iterable,
						cond: headA.cond
					};
				}
			}
			final declName: Null<String> = nullInitLocalName(a, s);
			if (declName == null) continue;
			final guarded: Null<GuardedBreak> = guardedBreakOf(a, b, s);
			if (guarded != null) {
				final guardedSpan: Null<Span> = guarded.forNode.span;
				if (guardedSpan != null) out['${guardedSpan.from}:${guardedSpan.to}'] = {
					form: FindForm.GuardedBreak,
					declName: guarded.declName,
					forNode: guarded.forNode,
					sibling: a,
					loopVar: guarded.loopVar,
					iterable: guarded.iterable,
					cond: guarded.cond
				};
				continue;
			}
			final headB: Null<{
				loopVar: String,
				iterable: QueryNode,
				cond: QueryNode,
				then: QueryNode
			}> = forIfHead(b, s);
			if (!(headB != null && isAssignBreakBody(headB.then, declName, headB.loopVar, s))) continue;
			final span: Null<Span> = b.span;
			if (span != null) out['${span.from}:${span.to}'] = {
				form: FindForm.Break,
				declName: declName,
				forNode: b,
				sibling: a,
				loopVar: headB.loopVar,
				iterable: headB.iterable,
				cond: headB.cond
			};
		}
		for (c in kids) collectFixCandidates(c, source, s, out);
	}

	/** The span edits rewriting `cand`'s loop to `xs.find(v -> cond)`, or null when a fix gate refuses it (then it stays a finding). */
	private static function buildEdits(cand: FixCandidate, source: String, s: Seams): Null<Array<{ span: Span, text: String }>> {
		if (!condIsPure(cand.cond, s)) return null;
		final iterSpan: Null<Span> = cand.iterable.span;
		final condSpan: Null<Span> = cand.cond.span;
		final forSpan: Null<Span> = cand.forNode.span;
		if (iterSpan == null || condSpan == null || forSpan == null) return null;
		final iterSrc: String = parenthesizeUnless(source.substring(iterSpan.from, iterSpan.to), postfixSafe(cand.iterable.kind, s));
		final findExpr: String = '$iterSrc.find(${cand.loopVar} -> ${source.substring(condSpan.from, condSpan.to)})';
		if (cand.form == FindForm.GuardedBreak) {
			// The declaration is NOT rewritten: its `null` is what the guard's false path must
			// still observe. Only the loop — the guard's whole body — collapses to the assignment.
			final decl: QueryNode = cand.sibling;
			final declName: Null<String> = cand.declName;
			return declName == null || !declTypeTolerable(decl, source) || loopRegionHasComment(source, forSpan, iterSpan, condSpan)
				? null
				: [{ span: forSpan, text: '$declName = $findExpr;' }];
		}
		if (cand.form == FindForm.Break) {
			final decl: QueryNode = cand.sibling;
			if (!declTypeTolerable(decl, source) || decl.children.length < 1) return null;
			final nullSpan: Null<Span> = decl.children[0].span;
			return nullSpan == null ? null : [{ span: nullSpan, text: findExpr }, { span: forSpan, text: '' }];
		}
		final ret: QueryNode = cand.sibling;
		final retSpan: Null<Span> = ret.span;
		if (retSpan == null || ret.children.length < 1 || droppedRegionHasComment(source, forSpan, iterSpan, condSpan, retSpan))
			return null;
		final fallback: QueryNode = ret.children[0];
		var tail: String = '';
		if (fallback.kind != s.nullLitKind) {
			final fbSpan: Null<Span> = fallback.span;
			if (fbSpan == null) return null;
			// `??` binds TIGHTER than the ternary `?:` (and assignment), so a looser fallback needs parens.
			final looser: Bool = fallback.kind == s.ternaryKind || StringTools.endsWith(fallback.kind, 'Assign');
			tail = ' ?? ${parenthesizeUnless(source.substring(fbSpan.from, fbSpan.to), !looser)}';
		}
		return [{ span: new Span(forSpan.from, retSpan.to), text: 'return $findExpr$tail;' }];
	}

	/**
	 * Whether `node`'s subtree is free of the effect shapes this fix refuses when moving a predicate into a `find` lambda: no assignment / compound-assignment (`*Assign`), no `++` / `--`
	 * (`*Incr` / `*Decr`), no `new`, and no free-function call — only field reads and
	 * accessor-style method calls (a call whose callee is an `a.b` / `a?.b` / `a!.b` chain) is ASSUMED effect-free, not proven — a mutating method such as `sink.push(x)` would pass, yet the rewrite stays safe because `Lambda.find` runs the predicate exactly as the loop did. Conservative on refusal: any unrecognised call shape refuses.
	 */
	private static function condIsPure(node: QueryNode, s: Seams): Bool {
		final k: String = node.kind;
		if (StringTools.endsWith(k, 'Assign') || k.indexOf('Incr') != -1 || k.indexOf('Decr') != -1) return false;
		if (k == s.newExprKind) return false;
		if (k == s.callKind && !calleeIsAccessor(node, s)) return false;
		for (c in node.children) if (!condIsPure(c, s)) return false;
		return true;
	}

	/** Whether a call's callee (`children[0]`) is a field-access chain (`a.b` / `a?.b` / `a!.b`) — a method call, not a free-function call. */
	private static function calleeIsAccessor(call: QueryNode, s: Seams): Bool {
		if (call.children.length == 0) return false;
		final callee: String = call.children[0].kind;
		return callee == s.fieldAccessKind || callee == s.nullSafeAccessKind || callee == s.forceFieldAccessKind;
	}

	/**
	 * Whether Form B's declaration tolerates a `Null<T>` `find` result — a bare
	 * `var r = null;` (no type) or a `var r:Null<…> = null;` (nullable) is fine; a
	 * `var r:T = null;` on a non-nullable type is refused. Reads the type from the
	 * declaration prefix — the text between the keyword and the `null` initializer.
	 */
	private static function declTypeTolerable(decl: QueryNode, source: String): Bool {
		final declSpan: Null<Span> = decl.span;
		if (declSpan == null || decl.children.length < 1) return false;
		final initSpan: Null<Span> = decl.children[0].span;
		if (initSpan == null) return false;
		final prefix: String = source.substring(declSpan.from, initSpan.from);
		final colon: Int = prefix.indexOf(':');
		if (colon == -1) return true;
		final eq: Int = prefix.lastIndexOf('=');
		return StringTools.startsWith(StringTools.trim(prefix.substring(colon + 1, eq == -1 ? prefix.length : eq)), 'Null');
	}


	/** `src` verbatim when `safe`, else wrapped in parentheses — keeps a spliced sub-expression's precedence intact. */
	private static function parenthesizeUnless(src: String, safe: Bool): String {
		return safe ? src : '($src)';
	}

	/** Whether `kind` is a postfix / primary expression that `.find(...)` binds directly onto (no wrapping parens needed); a looser operator (ternary / binary) iterable is wrapped. */
	private static function postfixSafe(kind: String, s: Seams): Bool {
		return kind == s.identKind || kind == s.fieldAccessKind || kind == s.nullSafeAccessKind || kind == s.forceFieldAccessKind
			|| kind == s.indexAccessKind || kind == s.parenKind || kind == s.callKind || kind == s.newExprKind;
	}

	/**
	 * Whether a comment sits in a Form-A region the rewrite DROPS — the for-header
	 * (`for (v in `, `) if (`, `) return v;`) or the gap before the fallback return —
	 * where it would be silently lost. The iterable and condition are re-spliced, so
	 * their spans are excluded; refusing here keeps such a loop a report-only finding.
	 */
	private static function droppedRegionHasComment(source: String, forSpan: Span, iterSpan: Span, condSpan: Span, retSpan: Span): Bool {
		return loopRegionHasComment(source, forSpan, iterSpan, condSpan) || CheckScan.hasCommentMarker(source, forSpan.to, retSpan.from);
	}

	/**
	 * Whether a comment sits ANYWHERE in the loop but its two re-spliced sub-expressions — the
	 * for-header around the iterable and the condition, and the whole loop body. Every form
	 * replaces the loop node wholesale, so such a comment is silently dropped; refusing here
	 * leaves the loop a report-only finding.
	 */
	private static function loopRegionHasComment(source: String, forSpan: Span, iterSpan: Span, condSpan: Span): Bool {
		return CheckScan.hasCommentMarker(source, forSpan.from, iterSpan.from)
			|| CheckScan.hasCommentMarker(source, iterSpan.to, condSpan.from)
			|| CheckScan.hasCommentMarker(source, condSpan.to, forSpan.to);
	}

}

/** The `RefShape` kinds `PreferFind` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var forStmtKind: String;
	var returnKind: String;
	var blockStmtKind: String;
	var nullLitKind: String;
	var identKind: String;
	var ifKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var valueBinderKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var exprStmtKind: Null<String>;
	var assignKind: Null<String>;
	var breakKind: Null<String>;
	var intervalKind: Null<String>;
	var callKind: Null<String>;
	var newExprKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var nullSafeAccessKind: Null<String>;
	var forceFieldAccessKind: Null<String>;
	var indexAccessKind: Null<String>;
	var parenKind: Null<String>;
	var ternaryKind: Null<String>;

	/**
	 * The STATEMENT-LIST kinds (`ControlFlowSupport.blockKinds`) whose direct children may be
	 * paired. A conditional-compilation region is deliberately absent: its branches project as
	 * FLATTENED siblings, so pairing under it would join a declaration in one `#if` branch to a
	 * loop in another and rewrite across the boundary.
	 */
	var blockKinds: Array<String>;
}

/** A recovered first-match loop ready to rewrite: the form flag, the loop node, its partner (Form A trailing return / Form B declaration) and the destructured head. */
private typedef FixCandidate = {
	/** Which of the three shapes was recovered — the tag `buildEdits` dispatches on. */
	var form: FindForm;

	/** The holder local's name for either break form, null for the return form. */
	var declName: Null<String>;
	var forNode: QueryNode;
	var sibling: QueryNode;
	var loopVar: String;
	var iterable: QueryNode;
	var cond: QueryNode;
}

/** A recovered GUARDED capture-and-break loop: the loop node, the holder local's name, and the destructured head. */
private typedef GuardedBreak = {
	var forNode: QueryNode;
	var declName: String;
	var loopVar: String;
	var iterable: QueryNode;
	var cond: QueryNode;
}

/**
 * Which of the three first-match shapes a fix candidate recovered. A single tag rather than
 * two booleans: the guarded break form IS a break form, so an `isBreak` flag alone could not
 * discriminate it and the two branches would depend on their own order.
 */
private enum abstract FindForm(Int) {

	final Return = 0;
	final Break = 1;
	final GuardedBreak = 2;

}
