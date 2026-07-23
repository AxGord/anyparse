package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a bare local declaration immediately followed by its first assignment, joining the
 * pair into an initialized declaration:
 *
 * ```haxe
 * var defaults;
 * defaults = value;
 * // ->
 * var defaults = value;
 * ```
 *
 * `Info` -- the code is correct, this is a readability simplification. The `var`/`final`
 * keyword and any `:type` are preserved; the `var`->`final` upgrade is left to
 * `prefer-final` (this rule does one job -- joining), so on a full `--fix` the two compose
 * to `final defaults = value;`. It also finishes what `prefer-if-expression-assignment`
 * starts: that rule leaves `var x; x = if (…) …`, which this joins to `var x = if (…) …`.
 *
 * ## What is flagged
 *
 * Two CONSECUTIVE statements of one statement list (`ControlFlowSupport.blockKinds`) where:
 *
 * - the first is a local declaration (`localDeclKinds`) with NO initializer (`children`
 *   empty) declaring exactly ONE variable -- a multi-declarator `var a, b;` (which projects
 *   as a single decl whose span still spells `, b`) is skipped, detected by a top-level
 *   comma in the declaration text (a comma inside a `<…>` / `(…)` type is not one);
 * - the second is `name = rhs;` -- a PLAIN `=` (`assignKind`) whose l-value is exactly the
 *   declared identifier (`identKind`, same name), not `name.f = …` / `name[i] = …`;
 * - `rhs` does NOT reference `name` -- `var x; x = x + 1;` reads an uninitialized `x`, and
 *   `var x = x + 1;` is a self-reference the compiler rejects;
 * - no comment sits in a region the join drops (between the declaration and the r-value).
 *
 * Adjacency is required: a statement between the declaration and the assignment would have
 * its evaluation reordered by the join, so only the IMMEDIATELY following assignment
 * qualifies. The reported span is the declaration.
 *
 * ## Autofix
 *
 * `fix` replaces both statements with `<decl> = <rhs>;` -- the declaration verbatim minus
 * its trailing `;` (keyword and `:type` kept), the r-value verbatim from its span. Needs
 * `localDeclKinds`, `exprStatementKind`, `assignKind` and `controlFlowSupport` (any unset
 * makes the check a no-op).
 */
@:nullSafety(Strict)
final class JoinDeclarationAssignment implements Check {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'join-declaration-assignment';
	}

	public function description(): String {
		return 'a bare local declaration immediately followed by its first assignment, joinable to an initialized declaration';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			final matches: Array<Match> = [];
			collectMatches(tree, entry.source, comments, seams, matches);
			for (m in matches) violations.push({
				file: entry.file,
				span: m.declSpan,
				rule: 'join-declaration-assignment',
				severity: Severity.Info,
				message: 'this declaration and its next-line assignment can be joined into an initialized declaration'
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final matches: Array<Match> = [];
		collectMatches(tree, source, comments, seams, matches);
		final byKey: Map<String, Match> = [];
		for (m in matches) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.editSpan, text: '${m.declText} = ${m.rhsSource};' });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			localDeclKinds: localDeclKinds,
			exprStmtKind: exprStmtKind,
			assignKind: assignKind,
			identKind: shape.identKind,
			stringInterpKind: shape.stringInterpIdentKind,
			blockKinds: support.blockKinds()
		};
	}

	/** Collect every joinable (declaration, assignment) pair reachable under `node`. */
	private static function collectMatches(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>
	): Void {
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = matchPair(kids[i], kids[i + 1], source, comments, s);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) collectMatches(c, source, comments, s, out);
	}

	/**
	 * The join match for a `decl` immediately followed by `assign`, or null when they are
	 * not a single-var bare declaration and its own first plain assignment (see the class
	 * doc for every gate).
	 */
	private static function matchPair(
		decl: QueryNode, assign: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != 0) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		// The decl span includes its trailing `;`; a bare single-var decl ends in one.
		if (declSpan.to <= declSpan.from || source.charAt(declSpan.to - 1) != ';') return null;
		final declText: String = StringTools.rtrim(source.substring(declSpan.from, declSpan.to - 1));
		if (hasTopLevelComma(declText)) return null; // `var a, b;` — multi-declarator, never joined

		if (assign.kind != s.exprStmtKind || assign.children.length != 1) return null;
		final binary: QueryNode = assign.children[0];
		if (binary.kind != s.assignKind || binary.children.length != ASSIGN_CHILD_COUNT) return null;
		final lhs: QueryNode = binary.children[0];
		if (lhs.kind != s.identKind || lhs.name != name) return null;
		final rhs: QueryNode = binary.children[1];
		if (referencesName(rhs, name, s)) return null; // self-reference in the initializer

		final assignSpan: Null<Span> = assign.span;
		final rhsSpan: Null<Span> = rhs.span;
		if (assignSpan == null || rhsSpan == null) return null;
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final keySpan: Span = declSpan;
		final m: Match = {
			declSpan: keySpan,
			editSpan: new Span(keySpan.from, assignSpan.to),
			declText: declText,
			rhsSource: source.substring(rhsSpan.from, rhsSpan.to)
		};
		return droppedComment(keySpan, rhsSpan, assignSpan.to, comments) ? null : m;
	}

	/**
	 * Whether the declaration text carries a top-level `,` -- a second declarator (`var a, b;`).
	 * A comma nested in a `<…>` / `(…)` / `[…]` / `{…}` type is not one; `->` is skipped so a
	 * function-type arrow does not close a `<…>`.
	 */
	private static function hasTopLevelComma(text: String): Bool {
		var depth: Int = 0;
		var i: Int = 0;
		while (i < text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			switch c {
				case '('.code | '['.code | '{'.code | '<'.code:
					depth++;
				case '>'.code if (i > 0 && StringTools.fastCodeAt(text, i - 1) == '-'.code):
					// the `>` of `->` is not a bracket close
				case ')'.code | ']'.code | '}'.code | '>'.code:
					if (depth > 0) depth--;
				case ','.code if (depth == 0):
					return true;
				case _:
			}
			i++;
		}
		return false;
	}

	/**
	 * Whether any descendant of `node` is an occurrence of the local `name` -- either a plain
	 * `identKind` reference or a `stringInterpKind` one (a braceless `$name` inside a
	 * single-quoted string, which projects as a distinct kind, not `identKind`).
	 */
	private static function referencesName(node: QueryNode, name: String, s: Seams): Bool {
		if ((node.kind == s.identKind || node.kind == s.stringInterpKind) && node.name == name) return true;
		for (c in node.children) if (referencesName(c, name, s)) return true;
		return false;
	}

	/**
	 * Whether a comment sits inside the joined region `[declSpan.from, assignTo)` but outside
	 * the two verbatim-kept spans -- the declaration minus its `;` (`[declSpan.from,
	 * declSpan.to - 1)`) and the r-value. Such a comment (on the dropped `;`, the assignment's
	 * `name =`, or between the statements) would be lost by the rebuild, so the pair is skipped.
	 */
	private static function droppedComment(
		declSpan: Span, rhsSpan: Span, assignTo: Int, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		for (tok in comments) if (tok.from >= declSpan.from && tok.to <= assignTo) {
			final inDecl: Bool = tok.from >= declSpan.from && tok.to <= declSpan.to - 1;
			final inRhs: Bool = tok.from >= rhsSpan.from && tok.to <= rhsSpan.to;
			if (!inDecl && !inRhs) return true;
		}
		return false;
	}

}

/** The kinds `JoinDeclarationAssignment` reads. */
private typedef Seams = {
	var localDeclKinds: Array<String>;
	var exprStmtKind: String;
	var assignKind: String;
	var identKind: String;
	var stringInterpKind: Null<String>;
	var blockKinds: Array<String>;
}

/** A joinable pair: the declaration span (finding key), the replaced span, and the two verbatim text pieces. */
private typedef Match = {
	var declSpan: Span;
	var editSpan: Span;
	var declText: String;
	var rhsSource: String;
}
