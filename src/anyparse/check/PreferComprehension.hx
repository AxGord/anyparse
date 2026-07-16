package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an empty-array local declaration immediately followed by a `for` loop
 * whose only effect is `a.push(<expr>)`, which an array comprehension replaces —
 * `final a = []; for (x in xs) a.push(e);` collapses to `final a = [for (x in xs) e];`.
 * `Severity.Info` (a modernization cleanup toward the idiomatic comprehension),
 * with an autofix. Grammar-agnostic over `RefShape`.
 *
 * ## The shape it accepts
 *
 * Two ADJACENT statements in one block: a local `var` / `final` whose initializer
 * is EXACTLY the empty array literal `[]` (a `new Array()` is left to
 * `prefer-array-literal`; after its `--fix` produces `[]` this check catches it on
 * the next run), then a `for` whose body — descending through single-statement
 * braces, nested `for`s and ONE trailing `if` guard — bottoms out in exactly one
 * `a.push(e)` call statement. The comprehension is assembled by transcribing each
 * `for (...)` header and the `if (cond)` guard verbatim from source (so a
 * key-value `for (k => v in m)` and a nested `for (a) for (b)` transfer intact),
 * with the push argument as the produced element.
 *
 * ## Soundness gates
 *
 * - **Empty literal only.** The initializer's source, whitespace-stripped, must be
 *   `[]` — an array with elements, a `new Array()` or anything else is skipped.
 * - **Push-only body.** Every layer is a `for`, a single-statement block, a
 *   single-branch `if` (no `else`), or the terminal `a.push(e)`; any second
 *   statement, an `else`, a non-push call or an assignment breaks the match. A
 *   `break` / `continue` therefore cannot hide — it would be an extra statement a
 *   single-child layer rejects.
 * - **No self-reference.** `a` must not appear in the produced element `e`, any
 *   iterable, or a guard condition (`a.push(a.length)` would read the array being
 *   built); only the push receiver is the bound name, and it is not scanned.
 * - **Read after the loop.** `a` must be referenced somewhere after the `for`
 *   within its scope, else the comprehension feeds no one (`unused-local`'s
 *   territory).
 * - **Strictly adjacent.** The `for` must be the very next statement; a comment in
 *   the gap between the two would be lost by the merge, so such a pair is skipped.
 *
 * ## Autofix
 *
 * Both statements are replaced by `final a<:T?> = [<comprehension>];`. The binding
 * becomes single-assignment, so the keyword is emitted as `final` regardless of the
 * original `var` / `final` (consistent with `prefer-final`); the type annotation, if
 * written, is preserved verbatim.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `localDeclKinds`, `callKind`, `fieldAccessKind`,
 * `exprStatementKind`, `blockStmtKind`, `identKind` (any required one unset → the
 * check is a no-op), plus `ifStatementKinds` for the guard form and `opaqueKinds`
 * to skip reification subtrees.
 */
@:nullSafety(Strict)
final class PreferComprehension implements Check {

	/** A `for` node has exactly [iterable, body] children. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A `push` call has exactly [callee, single-argument] children. */
	private static inline final PUSH_CALL_CHILD_COUNT: Int = 2;

	/** The declaration keyword the fix always emits, and its length for the `var`→`final` swap. */
	private static inline final VAR_KEYWORD: String = 'var';

	public function new() {}

	public function id(): String {
		return 'prefer-comprehension';
	}

	public function description(): String {
		return 'an empty-array local plus a push-only for loop replaceable with an array comprehension ([for])';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final s: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, s)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'prefer-comprehension',
				severity: Severity.Info,
				message: 'this empty-array declaration and push-only for loop can be an array comprehension ([for])'
			});
		}
		return violations;
	}

	/** Replace each flagged declaration-plus-loop pair with the assembled comprehension declaration. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final s: Seams = seams;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final textBySpan: Map<String, String> = [];
		for (m in collectMatches(tree, source, s)) textBySpan['${m.span.from}:${m.span.to}'] = m.text;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final text: Null<String> = textBySpan['${span.from}:${span.to}'];
			if (text != null) edits.push({ span: span, text: text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final forStmtKind: Null<String> = shape.forStmtKind;
		if (forStmtKind == null) return null;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		if (localDeclKinds.length == 0) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			forStmtKind: forStmtKind,
			localDeclKinds: localDeclKinds,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			identKind: shape.identKind,
			ifKinds: shape.ifStatementKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/** Walk `tree` and return every declaration-plus-loop pair that qualifies, each with its replacement span and text. */
	private static function collectMatches(tree: QueryNode, source: String, s: Seams): Array<Match> {
		final out: Array<Match> = [];
		walk(tree, source, s, out);
		return out;
	}

	/**
	 * Descend `node`, testing each adjacent child pair `(decl, for)` and recursing.
	 * `node` doubles as the enclosing scope for the read-after gate (the pair are its
	 * direct children). A reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(node: QueryNode, source: String, s: Seams, out: Array<Match>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final m: Null<Match> = tryMatch(kids[i], kids[i + 1], node, source, s);
			if (m != null) out.push(m);
		}
		for (c in kids) walk(c, source, s, out);
	}

	/**
	 * Whether `decl` is an empty-array local immediately followed by the qualifying
	 * push-only loop `forNode` inside `scope`; returns the replacement span and text
	 * when so, else null.
	 */
	private static function tryMatch(decl: QueryNode, forNode: QueryNode, scope: QueryNode, source: String, s: Seams): Null<Match> {
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != 1) return null;
		if (forNode.kind != s.forStmtKind) return null;
		final declName: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = decl.children[0].span;
		final forSpan: Null<Span> = forNode.span;
		final scopeSpan: Null<Span> = scope.span;
		if (declName == null || declSpan == null || initSpan == null || forSpan == null || scopeSpan == null) return null;
		if (!isEmptyArrayLiteral(source.substring(initSpan.from, initSpan.to))) return null;
		if (gapHasComment(source, declSpan.to, forSpan.from)) return null;
		final checkNodes: Array<QueryNode> = [];
		final inner: Null<String> = buildInner(forNode, declName, source, s, checkNodes);
		if (inner == null) return null;
		for (cn in checkNodes) if (referencesName(cn, declName, s)) return null;
		if (!RefactorSupport.referencedInRange(source, declName, forSpan.to, scopeSpan.to, [])) return null;
		final prefix: String = source.substring(declSpan.from, initSpan.from);
		final keyword: String = source.substring(declSpan.from, declSpan.from + VAR_KEYWORD.length);
		final normalized: String = keyword == VAR_KEYWORD ? 'final' + prefix.substring(VAR_KEYWORD.length) : prefix;
		return { span: new Span(declSpan.from, forSpan.to), text: normalized + '[' + inner + '];' };
	}

	/**
	 * Transcribe the comprehension body of a qualifying `for` — recursing through
	 * `for` headers, single-statement braces and one no-`else` `if` guard down to the
	 * terminal `<name>.push(e)` — returning the text between the comprehension
	 * brackets, or null when any layer is off-shape. Appends every iterable, guard
	 * condition and the produced element to `checkNodes` (for the self-reference gate);
	 * the push receiver, being the bound name itself, is never appended.
	 */
	private static function buildInner(
		node: QueryNode, name: String, source: String, s: Seams, checkNodes: Array<QueryNode>
	): Null<String> {
		if (node.kind == s.forStmtKind) {
			if (node.children.length != FOR_CHILD_COUNT) return null;
			final iterable: QueryNode = node.children[0];
			final body: QueryNode = node.children[1];
			final nodeSpan: Null<Span> = node.span;
			final bodySpan: Null<Span> = body.span;
			if (nodeSpan == null || bodySpan == null) return null;
			checkNodes.push(iterable);
			final rest: Null<String> = buildInner(body, name, source, s, checkNodes);
			return rest == null ? null : StringTools.rtrim(source.substring(nodeSpan.from, bodySpan.from)) + ' ' + rest;
		}
		if (node.kind == s.blockStmtKind)
			return node.children.length == 1 ? buildInner(node.children[0], name, source, s, checkNodes) : null;
		if (s.ifKinds.contains(node.kind)) {
			if (node.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
			final cond: QueryNode = node.children[0];
			final then: QueryNode = node.children[1];
			final nodeSpan: Null<Span> = node.span;
			final thenSpan: Null<Span> = then.span;
			if (nodeSpan == null || thenSpan == null) return null;
			checkNodes.push(cond);
			final rest: Null<String> = buildInner(then, name, source, s, checkNodes);
			return rest == null ? null : StringTools.rtrim(source.substring(nodeSpan.from, thenSpan.from)) + ' ' + rest;
		}
		return node.kind == s.exprStmtKind ? pushArgument(node, name, source, s, checkNodes) : null;
	}

	/**
	 * The source of the single argument of a terminal `<name>.push(e)` statement — the
	 * produced element — appended to `checkNodes`, or null when `node` is not exactly
	 * that call.
	 */
	private static function pushArgument(
		node: QueryNode, name: String, source: String, s: Seams, checkNodes: Array<QueryNode>
	): Null<String> {
		if (node.children.length != 1) return null;
		final call: QueryNode = node.children[0];
		if (call.kind != s.callKind || call.children.length != PUSH_CALL_CHILD_COUNT) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != s.fieldAccessKind || callee.name != 'push' || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		if (receiver.kind != s.identKind || receiver.name != name) return null;
		final arg: QueryNode = call.children[1];
		final argSpan: Null<Span> = arg.span;
		if (argSpan == null) return null;
		checkNodes.push(arg);
		return source.substring(argSpan.from, argSpan.to);
	}

	/** Whether any identifier in `node`'s subtree carries `name` — the self-reference test, skipping reification. */
	private static function referencesName(node: QueryNode, name: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (node.kind == s.identKind && node.name == name) return true;
		for (c in node.children) if (referencesName(c, name, s)) return true;
		return false;
	}

	/** Whether `s`, ignoring whitespace, is exactly the empty array literal `[]`. */
	private static function isEmptyArrayLiteral(source: String): Bool {
		final buf: StringBuf = new StringBuf();
		for (i in 0...source.length) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) buf.addChar(c);
		}
		return buf.toString() == '[]';
	}

	/** Whether the `[from, to)` gap holds a `//` or `/*` comment opener (which the merge would drop). */
	private static function gapHasComment(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final gap: String = source.substring(from, to);
		return gap.indexOf('//') != -1 || gap.indexOf('/*') != -1;
	}

}

/** The `RefShape` kinds `PreferComprehension` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var forStmtKind: String;
	var localDeclKinds: Array<String>;
	var callKind: String;
	var fieldAccessKind: String;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var identKind: String;
	var ifKinds: Array<String>;
	var opaqueKinds: Array<String>;
}

/** A flagged declaration-plus-loop pair: the full replacement span and its comprehension text. */
private typedef Match = {
	var span: Span;
	var text: String;
}
