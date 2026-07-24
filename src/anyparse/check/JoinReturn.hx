package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a local declaration whose value is IMMEDIATELY returned, collapsing the pair to a
 * single return:
 *
 * ```haxe
 * final x:Int = compute();
 * return x;
 * // ->
 * return compute();
 * ```
 *
 * `Info` -- the code is correct, this is a readability simplification. The `return` sibling
 * of `join-declaration-assignment`: where that joins a declaration and its next assignment,
 * this joins a declaration and its next return.
 *
 * ## The type annotation can be load-bearing
 *
 * A `:Type` annotation on the local is not always cosmetic -- it can drive an implicit
 * `@:from` conversion the plain value would not:
 *
 * ```haxe
 * final color:types.Color = str; // str : String, Color has @:from String
 * return color;
 * ```
 *
 * So the annotation is preserved unless the enclosing function's OWN explicit return type
 * already re-states it (then the conversion happens at the return boundary regardless):
 *
 * - unannotated decl -> always `return e;`;
 * - annotated decl AND the enclosing function's explicit return type equals the annotation
 *   (byte-identical source, whitespace ignored) -> `return e;`;
 * - annotated decl otherwise (a differing or inferred function return type) -> the
 *   annotation is kept as a type-check ascription `return (e : Type);`.
 *
 * ## What is flagged
 *
 * Two CONSECUTIVE statements of one statement list (`ControlFlowSupport.blockKinds`) where:
 *
 * - the first is a single-variable local declaration (`localDeclKinds`) WITH an initializer
 *   -- exactly one child, the initializer expression; a multi-declarator (`final a, b = …`)
 *   is skipped via a top-level comma in the pre-initializer text;
 * - the second is `return name;` (`returnStatementKind` with one child) whose returned
 *   expression is exactly the declared identifier (`identKind`, same name);
 * - the declared local has NO reference other than that return -- resolved through `Refs`,
 *   so a self-reference in the initializer or a use in unreachable trailing code disqualifies;
 * - no comment sits in a region the collapse drops (anything but the initializer text).
 *
 * Adjacency is required: only the IMMEDIATELY following return qualifies. The reported span
 * is the declaration.
 *
 * ## Autofix
 *
 * `fix` replaces both statements with the single return (verbatim initializer, plus the
 * ascription when the annotation must survive). Needs `localDeclKinds`, `returnStatementKind`
 * and `controlFlowSupport` (any unset makes the check a no-op); function return-type
 * detection additionally reads `functionKinds` / `lambdaKinds` / `paramKinds` /
 * `functionBodyKinds`, and when those are unset an annotated decl always ascribes (a
 * type-check that always compiles).
 */
@:nullSafety(Strict)
final class JoinReturn implements Check {

	/** A single-variable declaration with an initializer projects as exactly one child: the initializer. */
	private static inline final INIT_CHILD_COUNT: Int = 1;

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	public function new() {}

	public function id(): String {
		return 'join-return';
	}

	public function description(): String {
		return 'a local declaration whose value is immediately returned, joinable to a single return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			final declTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, entry.source);
			final matches: Array<Match> = [];
			collectMatches(tree, entry.source, comments, null, seams, tree, declTypeSources, matches);
			for (m in matches) violations.push({
				file: entry.file,
				span: m.declSpan,
				rule: 'join-return',
				severity: Severity.Info,
				message: 'this declaration and its next-line return can be joined into a single return'
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
		final declTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final matches: Array<Match> = [];
		collectMatches(tree, source, comments, null, seams, tree, declTypeSources, matches);
		final byKey: Map<String, Match> = [];
		for (m in matches) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.editSpan, text: m.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final functionKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []);
		return {
			localDeclKinds: localDeclKinds,
			returnKind: returnKind,
			identKind: shape.identKind,
			functionKinds: functionKinds,
			paramKinds: shape.paramKinds ?? [],
			bodyKinds: shape.functionBodyKinds ?? [],
			blockKinds: support.blockKinds(),
			shape: shape
		};
	}

	/**
	 * Collect every joinable (declaration, return) pair reachable under `node`. `retType` is
	 * the source of the nearest enclosing function's explicit return type (null when it has
	 * none), rebound whenever descent enters a function so a pair is judged against its OWN
	 * function.
	 */
	private static function collectMatches(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, retType: Null<String>, s: Seams,
		tree: QueryNode, declTypeSources: () -> Map<Int, String>, out: Array<Match>
	): Void {
		final childRetType: Null<String> = s.functionKinds.contains(node.kind) ? functionReturnTypeSource(node, s, source) : retType;
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = matchPair(kids[i], kids[i + 1], source, comments, retType, s, tree, declTypeSources);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) collectMatches(c, source, comments, childRetType, s, tree, declTypeSources, out);
	}

	/**
	 * The verbatim source of `fn`'s explicit return type, or null when it declares none. The
	 * return type is the child immediately before the body (`functionBodyKinds`) when that
	 * child is not a parameter (`paramKinds`).
	 */
	private static function functionReturnTypeSource(fn: QueryNode, s: Seams, source: String): Null<String> {
		final kids: Array<QueryNode> = fn.children;
		var bodyIdx: Int = -1;
		for (i in 0...kids.length) if (s.bodyKinds.contains(kids[i].kind)) {
			bodyIdx = i;
			break;
		}
		if (bodyIdx <= 0) return null;
		final candidate: QueryNode = kids[bodyIdx - 1];
		if (s.paramKinds.contains(candidate.kind)) return null;
		final span: Null<Span> = candidate.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/**
	 * The join match for a `decl` immediately followed by `ret`, or null when they are not a
	 * single-var initialized declaration and its own sole-reference return (see the class doc
	 * for every gate). `retType` is the enclosing function's return-type source.
	 */
	private static function matchPair(
		decl: QueryNode, ret: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, retType: Null<String>,
		s: Seams, tree: QueryNode, declTypeSources: () -> Map<Int, String>
	): Null<Match> {
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != INIT_CHILD_COUNT) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		// The decl span includes its trailing `;`; a bare single-var decl ends in one.
		if (declSpan.to <= declSpan.from || source.charAt(declSpan.to - 1) != ';') return null;
		final init: QueryNode = decl.children[0];
		final initSpan: Null<Span> = init.span;
		if (initSpan == null) return null;
		if (hasTopLevelComma(source.substring(declSpan.from, initSpan.from))) return null; // multi-declarator

		if (ret.kind != s.returnKind || ret.children.length != RETURN_VALUE_CHILD_COUNT) return null;
		final retIdent: QueryNode = ret.children[0];
		if (retIdent.kind != s.identKind || retIdent.name != name) return null;
		final retSpan: Null<Span> = ret.span;
		if (retSpan == null) return null;

		// The declared local must be referenced ONLY by this return: exactly one non-decl
		// reference resolving to it. A self-reference in the initializer or a use in
		// unreachable trailing code makes the join unsafe.
		final declNameFrom: Null<Int> = soleReferenceNameFrom(name, declSpan, tree, s);
		if (declNameFrom == null) return null;

		if (droppedComment(declSpan, initSpan, retSpan.to, comments)) return null;

		final annotation: Null<String> = declTypeSources()[declNameFrom];
		final initSource: String = source.substring(initSpan.from, initSpan.to);
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final keySpan: Span = declSpan;
		final m: Match = {
			declSpan: keySpan,
			editSpan: new Span(keySpan.from, retSpan.to),
			text: buildReturn(initSource, annotation, retType)
		};
		return m;
	}

	/**
	 * The `from` of the declaration's own name token when the local `name` bound at `declSpan`
	 * has EXACTLY one non-declaration reference resolving to it, or null otherwise. Reads the
	 * name token (a self-binding hit inside `declSpan`) and counts every other hit whose
	 * binding falls inside `declSpan`.
	 */
	private static function soleReferenceNameFrom(name: String, declSpan: Span, tree: QueryNode, s: Seams): Null<Int> {
		var declNameFrom: Null<Int> = null;
		var otherRefs: Int = 0;
		for (h in Refs.find(name, tree, s.shape)) {
			final hs: Span = h.span;
			final bs: Null<Span> = h.bindingSpan;
			final selfBind: Bool = bs != null && bs.from == hs.from && bs.to == hs.to;
			if (selfBind && hs.from >= declSpan.from && hs.to <= declSpan.to) {
				declNameFrom = hs.from;
				continue;
			}
			if (bs != null && bs.from >= declSpan.from && bs.to <= declSpan.to) otherRefs++;
		}
		return otherRefs == 1 ? declNameFrom : null;
	}

	/** The single-return replacement text -- plain, or a type-check ascription when the annotation must survive. */
	private static function buildReturn(initSource: String, annotation: Null<String>, retType: Null<String>): String {
		if (annotation == null) return 'return $initSource;';
		final ann: String = annotation;
		if (retType != null && TypeResolver.stripWs(retType) == TypeResolver.stripWs(ann)) return 'return $initSource;';
		return 'return ($initSource : $ann);';
	}

	/**
	 * Whether the pre-initializer text carries a top-level `,` -- a second declarator
	 * (`var a, b = …`). A comma nested in a `<…>` / `(…)` / `[…]` / `{…}` type is not one; `->`
	 * is skipped so a function-type arrow does not close a `<…>`.
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
	 * Whether a comment sits inside the joined region `[declSpan.from, retTo)` but outside the
	 * only verbatim-kept span, the initializer. Such a comment (on the declaration keyword /
	 * name / `:type` / `;` or on the `return`) would be lost by the rebuild, so the pair is
	 * skipped.
	 */
	private static function droppedComment(
		declSpan: Span, initSpan: Span, retTo: Int, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		for (tok in comments) if (tok.from >= declSpan.from && tok.to <= retTo) {
			final inInit: Bool = tok.from >= initSpan.from && tok.to <= initSpan.to;
			if (!inInit) return true;
		}
		return false;
	}

}

/** The kinds `JoinReturn` reads. */
private typedef Seams = {
	var localDeclKinds: Array<String>;
	var returnKind: String;
	var identKind: String;
	var functionKinds: Array<String>;
	var paramKinds: Array<String>;
	var bodyKinds: Array<String>;
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** A joinable pair: the declaration span (finding key), the replaced span, and the single-return replacement text. */
private typedef Match = {
	var declSpan: Span;
	var editSpan: Span;
	var text: String;
}
