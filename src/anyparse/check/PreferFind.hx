package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a manual first-match `for` loop — one that iterates a collection to return
 * (or capture-and-break) the first element satisfying a condition — which the
 * user's rule replaces with `Lambda.find`: use `.find()` instead of manually
 * iterating to find the first matching element. `Severity.Info`; REPORT-ONLY (the
 * `xs.find(x -> cond)` rewrite needs `using Lambda` in scope, so the import surgery
 * and shadow analysis are out of v1). Purely structural, so it holds without a
 * type-checker. Grammar-agnostic over `RefShape`.
 *
 * ## The two shapes it accepts
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
 *   loop is inspected.
 *
 * ## Soundness gates
 *
 * - **Returned / assigned value is the loop variable.** `return x` / `r = x` where
 *   `x` is the loop variable; `return x.field` or any transformed value is
 *   `map` / `filter` territory and is skipped.
 * - **No `else`.** The `if` must have no `else` branch (a two-way choice is not a
 *   find).
 * - **Form A fallback is a value return.** The trailing sibling must be a
 *   value-returning `return`; a `return null;` yields the plain suggestion, a
 *   non-null fallback the `?? <fallback>` suffix.
 * - **Form B body is exactly assign-then-break.** The `if`-body is a two-statement
 *   block: the loop-variable-to-local assignment, then a `break` (a `continue`
 *   would find the LAST match, so the dedicated break kind is required); the
 *   declaration's initializer must be exactly `null`.
 * - **No key-value loop.** `for (k => v in m)` is skipped — `.find` iterates an
 *   iterable's values, not map key-value pairs.
 * - **Adjacency.** The loop and its trailing `return` (Form A), or the declaration
 *   and its loop (Form B), must be real, immediately adjacent block siblings.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `returnStatementKind`, `blockStmtKind`, `nullLiteralKind`,
 * `identKind` and `ifStatementKinds` (any unset → the check is a no-op), with
 * `opaqueKinds` to skip reification subtrees. Form B additionally needs
 * `localDeclKinds`, `exprStatementKind`, `assignKind` and `breakStatementKind`; any
 * of those unset disables the break form while the return form still runs.
 */
@:nullSafety(Strict)
final class PreferFind implements Check {

	/** A `for` node has exactly [iterable, body] children; the loop variable is its name. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A Form-B `if`-body block has exactly [assignment-statement, break] children. */
	private static inline final BREAK_BODY_CHILD_COUNT: Int = 2;

	/** An assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** Cap on the condition (and fallback) excerpt length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	public function new() {}

	public function id(): String {
		return 'prefer-find';
	}

	public function description(): String {
		return 'a manual first-match for loop (return or capture-and-break) replaceable with Lambda.find';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
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

	/** Report-only: the `Lambda.find` rewrite needs `using Lambda` at file scope (import + shadow analysis out of v1). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final forStmtKind: Null<String> = shape.forStmtKind;
		if (forStmtKind == null) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		if (nullLitKind == null) return null;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		return ifKinds.length == 0 ? null : {
			forStmtKind: forStmtKind,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind,
			nullLitKind: nullLitKind,
			identKind: shape.identKind,
			ifKinds: ifKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			exprStmtKind: shape.exprStatementKind,
			assignKind: shape.assignKind,
			breakKind: shape.breakStatementKind,
			intervalKind: shape.intervalKind
		};
	}

	/** Descend `node`, testing each adjacent child pair against both forms and recursing; skip reification subtrees. */
	private static function walk(node: QueryNode, file: String, source: String, s: Seams, out: Array<Violation>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final v: Null<Violation> = tryReturnForm(kids[i], kids[i + 1], file, source, s) ?? tryBreakForm(
				kids[i], kids[i + 1], file, source, s
			);
			if (v != null) out.push(v);
		}
		for (c in kids) walk(c, file, source, s, out);
	}

	/**
	 * Form A: `forNode` is `for (v in xs) if (cond) return v;` and `next` is a
	 * value-returning `return` fallback. Returns the violation when so, else null.
	 */
	private static function tryReturnForm(forNode: QueryNode, next: QueryNode, file: String, source: String, s: Seams): Null<Violation> {
		if (forNode.kind != s.forStmtKind || forNode.children.length != FOR_CHILD_COUNT) return null;
		final loopVar: Null<String> = forNode.name;
		if (loopVar == null) return null;
		final iterable: QueryNode = forNode.children[0];
		if (isKeyValueLoop(source, forNode, iterable) || isRangeIterable(iterable, s)) return null;
		final body: QueryNode = unwrapSole(forNode.children[1], s);
		if (!s.ifKinds.contains(body.kind) || body.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final cond: QueryNode = body.children[0];
		final returned: Null<QueryNode> = returnValue(body.children[1], s);
		if (returned == null || returned.kind != s.identKind || returned.name != loopVar) return null;
		if (next.kind != s.returnKind || next.children.length < 1) return null;
		final fallback: QueryNode = next.children[0];
		final tail: String = fallback.kind == s.nullLitKind ? '' : coalesceTail(fallback, source);
		return buildViolation(forNode, iterable, loopVar, cond, tail, file, source);
	}

	/**
	 * Form B: `decl` is a null-initialized local and `forNode` is
	 * `for (v in xs) if (cond) { r = v; break; }`. Returns the violation when so, else null.
	 */
	private static function tryBreakForm(decl: QueryNode, forNode: QueryNode, file: String, source: String, s: Seams): Null<Violation> {
		final declName: Null<String> = nullInitLocalName(decl, s);
		if (declName == null) return null;
		if (forNode.kind != s.forStmtKind || forNode.children.length != FOR_CHILD_COUNT) return null;
		final loopVar: Null<String> = forNode.name;
		if (loopVar == null) return null;
		final iterable: QueryNode = forNode.children[0];
		if (isKeyValueLoop(source, forNode, iterable) || isRangeIterable(iterable, s)) return null;
		final body: QueryNode = unwrapSole(forNode.children[1], s);
		if (!s.ifKinds.contains(body.kind) || body.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final then: QueryNode = body.children[1];
		final cond: QueryNode = body.children[0];
		return isAssignBreakBody(then, declName, loopVar, s) ? buildViolation(forNode, iterable, loopVar, cond, '', file, source) : null;
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
		final suggestion: String = iterSrc + '.find(' + loopVar + ' -> ' + condSrc + ')' + tail;
		return {
			file: file,
			span: forSpan,
			rule: 'prefer-find',
			severity: Severity.Info,
			message: 'this manual first-match loop can be ' + suggestion
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

	/** Whether the `for` header carries a `k => v` key-value binding (`.find` iterates values, not KV pairs). */
	private static function isKeyValueLoop(source: String, forNode: QueryNode, iterable: QueryNode): Bool {
		final forSpan: Null<Span> = forNode.span;
		final iterSpan: Null<Span> = iterable.span;
		return forSpan != null && iterSpan != null && source.substring(forSpan.from, iterSpan.from).indexOf('=>') != -1;
	}

	/** Whether the iterable is a range `a...b` — its `IntIterator` is not `Iterable`, so `Lambda.find` would not compile. */
	private static function isRangeIterable(iterable: QueryNode, s: Seams): Bool {
		final intervalKind: Null<String> = s.intervalKind;
		return intervalKind != null && iterable.kind == intervalKind;
	}

	/** The ` ?? <fallback>` suffix for a non-null Form-A fallback, or empty when its span is unavailable. */
	private static function coalesceTail(fallback: QueryNode, source: String): String {
		final span: Null<Span> = fallback.span;
		return span == null ? '' : ' ?? ' + excerpt(source.substring(span.from, span.to));
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
		return flat.length > EXCERPT_MAX ? flat.substring(0, EXCERPT_MAX) + '…' : flat;
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
	var localDeclKinds: Array<String>;
	var exprStmtKind: Null<String>;
	var assignKind: Null<String>;
	var breakKind: Null<String>;
	var intervalKind: Null<String>;
}
