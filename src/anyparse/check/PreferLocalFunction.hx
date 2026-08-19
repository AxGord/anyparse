package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a function LITERAL — an anonymous `function (…) { … }` or an arrow lambda — bound to a
 * LOCAL, and rewrites the binding into a local function DECLARATION placed where the literal
 * already sat:
 *
 * ```haxe
 * var handler:MouseEvent->Void;
 * o.addEventListener(E.DOWN, handler = function(event:MouseEvent):Void { … }, true, 0);
 * // ->
 * function handler(event:MouseEvent):Void { … }
 * o.addEventListener(E.DOWN, handler, true, 0);
 * ```
 *
 * `Info` — the code is correct; this is the readability form, and the one the Haxe style this
 * project follows prescribes for a local helper. Disjoint from `prefer-arrow-callback`, which
 * owns a literal that is a DIRECT call argument and never touches a binding: an `assignKind`
 * node sits between the call and the literal here, so neither rule sees the other's shape.
 *
 * ## What is flagged
 *
 * Two entry shapes, one emitter:
 *
 * - an ASSIGNMENT `name = <literal>` reached from a statement of a statement list
 *   (`ControlFlowSupport.blockKinds`) without crossing a `branchKinds` / `scopeKinds` node, so
 *   the literal is evaluated exactly once whenever that statement runs, paired with an earlier
 *   BARE declaration of `name` in the SAME list;
 * - a DECLARATION whose initializer IS the literal (`var g = function(x:Int):Int return x;`).
 *
 * ## Gates
 *
 * A local function is not a variable: it cannot be reassigned, and — unlike a `var` — it is
 * invisible ABOVE its own declaration. Both facts become gates, checked over the statement
 * list that owns the binding (the exact extent of a Haxe local's scope):
 *
 * - `name` occurs NOWHERE before the point the declaration moves to. This is what refuses the
 *   mutually-recursive-closure idiom (`var a = cast null; a = function() { … b … };`), whose
 *   whole reason for the `var` is the forward reference a declaration cannot express.
 * - `name` is WRITTEN only by the flagged assignment, and DECLARED exactly once — a rebound
 *   binding has to stay a variable.
 * - the declaration is BARE, or initialized by the definite-assignment placeholder (`null`,
 *   `cast null`); a real initializer would be dropped. A multi-declarator `var a, b;` is never
 *   a candidate.
 * - EVERY parameter of the literal carries a type. The expected type that the declaration's
 *   `:T` annotation supplied is gone after the hoist, and an unannotated parameter whose body
 *   dereferences it no longer types. The RETURN type needs no such gate: a `function` literal
 *   with no explicit `return` is `Void` in both forms. A rest parameter is refused outright.
 * - a lambda whose body is a BLOCK is hoisted only where the declaration's written type names a
 *   `Void` result. `->` takes an expression, and a block IS one — its value is its last
 *   expression (`() -> { 5; }` returns `5`) — while a declaration's block body has no implicit
 *   result at all (`function f() { 5; }` returns `Void`). Without that proof the hoist would
 *   silently retype the binding. A lambda's EXPRESSION body needs no proof: the emitted `return`
 *   carries the value over.
 * - no comment sits in a span the rewrite drops (the declaration statement, the `name = ` head,
 *   the initializer's `;`). A comment INSIDE the literal's body rides along with it — the body
 *   is copied verbatim.
 * - subtrees opaque to reference analysis (`RefShape.opaqueKinds` — macro reification) are
 *   skipped whole: their code splices into a different resolution context.
 *
 * ## Autofix
 *
 * Two or three raw edits per site, applied as one batch: the declaration statement is deleted,
 * `function name(<params>)[:Ret] <body>` is inserted before the host statement, and the
 * assignment collapses to the bare `name`. When the assignment IS the whole statement the
 * declaration REPLACES it — rewriting only the assignment would leave a `name;` no-op behind.
 * A body that does not close on a brace is not self-terminating, so it regains the `;` its
 * statement carried, and a lambda's expression body regains the `return` its arrow implied. The
 * emitted text is re-formatted by the canonical writer, so it carries no indentation of its own.
 */
@:nullSafety(Strict)
final class PreferLocalFunction implements Check {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	private static inline final RULE_ID: String = 'prefer-local-function';
	private static inline final MSG: String = 'this function literal is bound to a local — declare it as a local function';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a function literal bound to a never-reassigned local, replaceable with a local function declaration';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, s)) violations.push({
				file: entry.file,
				span: m.reportSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: MSG
			});
		}
		return violations;
	}

	/** Emit each flagged site's edit batch — the declaration removal, the hoist, and the collapsed assignment. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Map<String, Bool> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted['${span.from}:${span.to}'] = true;
		}
		return [for (m in collectMatches(tree, source, s)) if (wanted.exists('${m.reportSpan.from}:${m.reportSpan.to}')) for (e in m.edits) e];
	}

	/**
	 * Whether the literal's own RESULT survives the hoist. An arrow lambda's `{ … }` body is an
	 * expression — its value is the block's last expression — while a function declaration's block body
	 * has no implicit result at all (`() -> { 5; }` returns `5`, `function f() { 5; }` returns `Void`).
	 * So a bare block body may be hoisted only where the declaration proved the result is `Void`; an
	 * unannotated binding proves nothing and is refused. A bare EXPRESSION body keeps its value through
	 * the `return` the rewrite emits, and a body that arrived wrapped in a body node was never an
	 * expression to begin with — neither needs the proof.
	 */
	private static inline function resultSurvives(parts: FnParts, returnsVoid: Bool): Bool {
		return !parts.bare || !parts.block || returnsVoid;
	}

	/**
	 * Bundle the kinds the check reads, or null when a required one is unset (the check is then a
	 * no-op). `localFunctionKinds` is required for its EXISTENCE only: a grammar that names no
	 * local-function form has nothing to rewrite the binding into.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final literalKinds: Array<String> = literalKindsOf(shape);
		if (literalKinds.length == 0) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		final localFunctionKinds: Null<Array<String>> = shape.localFunctionKinds;
		if (localFunctionKinds == null || localFunctionKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			literalKinds: literalKinds,
			assignKind: assignKind,
			exprStmtKind: exprStmtKind,
			localDeclKinds: localDeclKinds,
			localDeclContinuationKinds: shape.localDeclContinuationKinds ?? [],
			identKind: shape.identKind,
			stringInterpKind: shape.stringInterpIdentKind,
			writeParentKinds: shape.writeParentKinds,
			scopeKinds: shape.scopeKinds,
			branchKinds: shape.branchKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			restParamKind: shape.restParamKind,
			bodyKinds: shape.functionBodyKinds ?? [],
			noBodyKind: shape.noBodyKind,
			typeAnnotationKinds: shape.typeAnnotationKinds ?? [],
			nullLiteralKind: shape.nullLiteralKind,
			castKinds: shape.typedCastKinds ?? [],
			uncheckedCastKind: shape.uncheckedCastKind,
			voidTypeName: shape.voidTypeName,
			blockKinds: support.blockKinds()
		};
	}

	/**
	 * Every function-literal kind the rewrite reads: the anonymous `function (…) { … }` form and the
	 * grammar's lambda kinds. `partsOf` tells the two apart by SHAPE rather than by kind — a body that
	 * arrives wrapped in a body node is copied verbatim, while a lambda's BARE expression child regains
	 * the `return` its arrow implied.
	 */
	private static function literalKindsOf(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		final fnExprKind: Null<String> = shape.fnExprKind;
		if (fnExprKind != null) out.push(fnExprKind);
		for (kind in shape.lambdaKinds ?? []) if (!out.contains(kind)) out.push(kind);
		return out;
	}

	/** Every rewritable binding reachable under `tree`, in document order. */
	private static function collectMatches(tree: QueryNode, source: String, s: Seams): Array<Match> {
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final out: Array<Match> = [];
		walkBlocks(tree, source, comments, s, out);
		return out;
	}

	private static function walkBlocks(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final m: Null<Match> = matchInitializer(node, kids[i], source, comments, s) ?? matchAssignment(
					node, kids, i, source, comments, s
				);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) walkBlocks(c, source, comments, s, out);
	}

	/** The match for a declaration whose initializer IS the literal, or null when a gate refuses it. */
	private static function matchInitializer(
		list: QueryNode, st: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (!s.localDeclKinds.contains(st.kind) || s.localDeclContinuationKinds.contains(st.kind)) return null;
		if (st.children.length != 1 || !s.literalKinds.contains(st.children[0].kind)) return null;
		if (RefactorSupport.isMultiDeclarator(st, s.localDeclContinuationKinds)) return null;
		final fn: QueryNode = st.children[0];
		final name: Null<String> = st.name;
		final stSpan: Null<Span> = st.span;
		final fnSpan: Null<Span> = fn.span;
		if (name == null || stSpan == null || fnSpan == null) return null;
		final parts: Null<FnParts> = partsOf(fn, source, s);
		if (parts == null) return null;
		final declared: DeclaredType = declaredType(source, stSpan, name, s.voidTypeName);
		return if (!declared.survives)
			null
		else if (!resultSurvives(parts, declared.returnsVoid))
			null
		else if (!bindingIsSole(list, name, stSpan.from, null, s))
			null
		else if (commentOverlaps(comments, stSpan.from, fnSpan.from) || commentOverlaps(comments, fnSpan.to, stSpan.to))
			null
		else
			{ reportSpan: fnSpan, edits: [{ span: stSpan, text: declarationText(name, parts, source) }] };
	}

	/** The match for an assignment of the literal paired with an earlier bare declaration, or null when a gate refuses it. */
	private static function matchAssignment(
		list: QueryNode, kids: Array<QueryNode>, index: Int, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams
	): Null<Match> {
		final st: QueryNode = kids[index];
		final assign: Null<QueryNode> = findBinding(st, s);
		if (assign == null) return null;
		final lhs: QueryNode = assign.children[0];
		final fn: QueryNode = assign.children[1];
		final name: Null<String> = lhs.name;
		final stSpan: Null<Span> = st.span;
		final lhsSpan: Null<Span> = lhs.span;
		final assignSpan: Null<Span> = assign.span;
		final fnSpan: Null<Span> = fn.span;
		if (name == null || stSpan == null || lhsSpan == null || assignSpan == null || fnSpan == null) return null;
		final parts: Null<FnParts> = partsOf(fn, source, s);
		if (parts == null) return null;
		final decl: Null<QueryNode> = bareDeclarationBefore(kids, index, name, s);
		final declSpan: Null<Span> = decl?.span;
		if (declSpan == null) return null;
		final declared: DeclaredType = declaredType(source, declSpan, name, s.voidTypeName);
		if (!declared.survives) return null;
		if (!resultSurvives(parts, declared.returnsVoid)) return null;
		if (!bindingIsSole(list, name, stSpan.from, lhsSpan, s)) return null;
		if (commentOverlaps(comments, assignSpan.from, fnSpan.from)) return null;
		final cut: Span = RefactorSupport.lineExtendedSpan(source, declSpan);
		if (commentOverlaps(comments, cut.from, cut.to)) return null;
		// The removal must not touch the host statement's start: an edit batch drops any edit another
		// edit CONTAINS, so a cut ending exactly there would swallow the zero-width hoist insertion.
		if (cut.to >= stSpan.from) return null;
		final text: String = declarationText(name, parts, source);
		final wholeStatement: Bool = st.kind == s.exprStmtKind && st.children.length == 1 && st.children[0] == assign;
		return if (wholeStatement)
			{ reportSpan: fnSpan, edits: [{ span: cut, text: '' }, { span: stSpan, text: text }] }
		else if (assignSpan.from <= stSpan.from)
			null // same containment hazard, from the other side
		else
			{
				reportSpan: fnSpan,
				edits: [
					{ span: cut, text: '' },
					{ span: new Span(stSpan.from, stSpan.from), text: '$text\n' },
					{ span: assignSpan, text: name }
				]
			};
	}

	/**
	 * The `name = <literal>` node reached from `node` without crossing a scope or a conditionally-
	 * evaluated construct, or null when there is none. Stopping at `scopeKinds` keeps a nested
	 * lambda's own binding for the pass over ITS statement list; stopping at `branchKinds` keeps the
	 * hoist from lifting a literal out of the branch that decided whether it was built at all.
	 */
	private static function findBinding(node: QueryNode, s: Seams): Null<QueryNode> {
		if (s.opaqueKinds.contains(node.kind) || s.scopeKinds.contains(node.kind) || s.branchKinds.contains(node.kind)) return null;
		if (isBinding(node, s)) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findBinding(c, s);
			if (found != null) return found;
		}
		return null;
	}

	/** Whether `node` is a plain `<ident> = <function literal>` assignment. */
	private static function isBinding(node: QueryNode, s: Seams): Bool {
		return node.kind == s.assignKind && node.children.length == ASSIGN_CHILD_COUNT && node.children[0].kind == s.identKind
			&& s.literalKinds.contains(node.children[1].kind);
	}

	/** The single-declarator, initializer-free declaration of `name` among `kids[0...index)`, or null when there is none. */
	private static function bareDeclarationBefore(kids: Array<QueryNode>, index: Int, name: String, s: Seams): Null<QueryNode> {
		for (i in 0...index) {
			final st: QueryNode = kids[i];
			if (!s.localDeclKinds.contains(st.kind) || st.name != name) continue;
			return if (RefactorSupport.isMultiDeclarator(st, s.localDeclContinuationKinds))
				null
			else if (declarationIsBare(st, s))
				st
			else
				null;
		}
		return null;
	}

	/** Whether `decl` binds no value, or only the definite-assignment placeholder a hoist may drop. */
	private static function declarationIsBare(decl: QueryNode, s: Seams): Bool {
		return decl.children.length == 0 || decl.children.length == 1 && isNullPlaceholder(decl.children[0], s);
	}

	/**
	 * What the declaration's written type says about the hoist: whether the annotation may be DROPPED, and
	 * whether it named a `Void` result.
	 *
	 * It survives being dropped only when the literal's own signature REPRODUCES it. A written FUNCTION
	 * type does: the parameters are annotated (`partsOf` refuses otherwise) and a `function` literal
	 * without an explicit `return` is `Void`, so the hoisted declaration carries the same type. A NOMINAL
	 * one does not, and the failure is silent: Pony's `var l:Listener1<Int> = null; l = function(n:Int):Void { … }`
	 * binds an abstract whose `@:from` wraps the literal ONCE, at the assignment. Hoisted, `l` is the raw
	 * function and every use site wraps it again — so an `add(l)` / `remove(l)` pair that shared one wrapper
	 * stops doing so, and the code still compiles. No annotation at all is trivially safe.
	 *
	 * The RESULT type it named is what `resultSurvives` needs before a lambda's block body may be hoisted.
	 */
	private static function declaredType(source: String, declSpan: Span, name: String, voidTypeName: Null<String>): DeclaredType {
		final text: String = source.substring(declSpan.from, declSpan.to);
		var i: Int = 0;
		while (i < text.length && RefactorSupport.isIdentChar(text.fastCodeAt(i))) i++; // the var / final keyword
		while (i < text.length && RefactorSupport.isSpace(text.fastCodeAt(i))) i++;
		final nameStart: Int = i;
		while (i < text.length && RefactorSupport.isIdentChar(text.fastCodeAt(i))) i++;
		if (text.substring(nameStart, i) != name) return { survives: false, returnsVoid: false };
		while (i < text.length && RefactorSupport.isSpace(text.fastCodeAt(i))) i++;
		if (i >= text.length || text.fastCodeAt(i) != ':'.code) return { survives: true, returnsVoid: false };
		final returnType: Null<String> = topLevelReturnType(text, i + 1);
		return { survives: returnType != null, returnsVoid: returnType != null && returnType == voidTypeName };
	}

	/**
	 * The result type a written type names after its LAST top-level `->`, or null when it carries none — a
	 * nominal type that merely holds functions (`Array<Int->Void>`, `Null<Void->Void>`). Scanning stops at
	 * the depth-0 `=` / `;` that ends the annotation.
	 */
	private static function topLevelReturnType(text: String, from: Int): Null<String> {
		var depth: Int = 0;
		var arrowEnd: Int = -1;
		var stop: Int = text.length;
		var i: Int = from;
		while (i < text.length) {
			final c: Int = text.fastCodeAt(i);
			if (c == '<'.code || c == '('.code || c == '{'.code || c == '['.code)
				depth++
			else if (c == '>'.code && i > from && text.fastCodeAt(i - 1) == '-'.code) {
				if (depth == 0) arrowEnd = i + 1;
			} else if (c == '>'.code || c == ')'.code || c == '}'.code || c == ']'.code)
				depth--
			else if (depth == 0 && (c == '='.code || c == ';'.code)) {
				stop = i;
				break;
			}
			i++;
		}
		return arrowEnd < 0 ? null : text.substring(arrowEnd, stop).trim();
	}

	/** Whether `node` is `null`, or a cast of it (`cast null`, `cast(null, T)`) — a value the declaration carried only to satisfy definite assignment. */
	private static function isNullPlaceholder(node: QueryNode, s: Seams): Bool {
		if (node.kind == s.nullLiteralKind) return true;
		final isCast: Bool = node.kind == s.uncheckedCastKind || s.castKinds.contains(node.kind);
		return isCast && node.children.length > 0 && isNullPlaceholder(node.children[0], s);
	}

	/**
	 * Whether `name` is declared exactly once inside `list`, written only at `allowedWrite`, and
	 * unreferenced before `hoistFrom` — the three facts that make the binding expressible as a local
	 * function declaration sitting at `hoistFrom`.
	 */
	private static function bindingIsSole(list: QueryNode, name: String, hoistFrom: Int, allowedWrite: Null<Span>, s: Seams): Bool {
		final refs: Refs = { declarations: 0, ok: true };
		scanRefs(list, null, name, hoistFrom, allowedWrite, s, refs);
		return refs.ok && refs.declarations == 1;
	}

	private static function scanRefs(
		node: QueryNode, parent: Null<QueryNode>, name: String, hoistFrom: Int, allowedWrite: Null<Span>, s: Seams, out: Refs
	): Void {
		if (!out.ok) return;
		if (s.localDeclKinds.contains(node.kind) && node.name == name) out.declarations++;
		if ((node.kind == s.identKind || node.kind == s.stringInterpKind) && node.name == name) {
			final span: Null<Span> = node.span;
			if (span == null || span.from < hoistFrom) {
				out.ok = false;
				return;
			}
			final allowed: Bool = allowedWrite != null && allowedWrite.from == span.from && allowedWrite.to == span.to;
			final written: Bool = parent != null && s.writeParentKinds.contains(parent.kind) && parent.children[0] == node;
			if (written && !allowed) {
				out.ok = false;
				return;
			}
		}
		for (c in node.children) scanRefs(c, node, name, hoistFrom, allowedWrite, s, out);
	}

	/**
	 * Split the literal into fully-typed parameter texts, an optional return-type hint and a body — null
	 * when a gate refuses it. A body arriving as a body-kind child is a `function` literal's; a BARE last
	 * child is a lambda's arrow body, which the emitter has to re-terminate itself.
	 */
	private static function partsOf(fn: QueryNode, source: String, s: Seams): Null<FnParts> {
		final params: Array<String> = [];
		final last: Int = fn.children.length - 1;
		var hintSpan: Null<Span> = null;
		var body: Null<QueryNode> = null;
		var bare: Bool = false;
		for (i in 0...fn.children.length) {
			final c: QueryNode = fn.children[i];
			if (s.paramKinds.contains(c.kind)) {
				if (c.kind == s.restParamKind) return null;
				final span: Null<Span> = c.span;
				if (span == null) return null;
				final text: String = source.substring(span.from, span.to).trim();
				if (!parameterIsTyped(text)) return null;
				params.push(text);
			} else if (s.bodyKinds.contains(c.kind))
				body = c;
			else if (s.typeAnnotationKinds.contains(c.kind))
				hintSpan = c.span;
			else if (i == last) {
				body = c;
				bare = true;
			} else
				return null;
		}
		final b: Null<QueryNode> = body;
		if (b == null || b.kind == s.noBodyKind) return null;
		final bodySpan: Null<Span> = b.span;
		return bodySpan == null ? null : {
			params: params,
			hintSpan: hintSpan,
			bodySpan: bodySpan,
			block: s.blockKinds.contains(b.kind),
			bare: bare
		};
	}

	/** Whether a parameter's source text carries a `:type` — an optional `?`, the name, then the colon. */
	private static function parameterIsTyped(text: String): Bool {
		var i: Int = 0;
		if (i < text.length && text.fastCodeAt(i) == '?'.code) i++;
		while (i < text.length && RefactorSupport.isSpace(text.fastCodeAt(i))) i++;
		if (i >= text.length || !RefactorSupport.isIdentStartChar(text.fastCodeAt(i))) return false;
		while (i < text.length && RefactorSupport.isIdentChar(text.fastCodeAt(i))) i++;
		while (i < text.length && RefactorSupport.isSpace(text.fastCodeAt(i))) i++;
		return i < text.length && text.fastCodeAt(i) == ':'.code;
	}

	/**
	 * The local function declaration replacing the binding — body verbatim, `return` restored for an
	 * arrow's expression body and `;` for any body that does not close on a brace.
	 */
	private static function declarationText(name: String, parts: FnParts, source: String): String {
		final hintSpan: Null<Span> = parts.hintSpan;
		final hint: String = hintSpan == null ? '' : ':${source.substring(hintSpan.from, hintSpan.to).trim()}';
		final body: String = source.substring(parts.bodySpan.from, parts.bodySpan.to);
		final lead: String = parts.bare && !parts.block ? 'return ' : '';
		return 'function $name(${parts.params.join(', ')})$hint $lead$body${parts.block ? '' : ';'}';
	}

	/** Whether any comment token overlaps `[from, to)` — a span the rewrite drops. */
	private static function commentOverlaps(comments: Array<{ from: Int, to: Int, isLine: Bool }>, from: Int, to: Int): Bool {
		return comments.exists(tok -> tok.from < to && tok.to > from);
	}

}

/** The kinds `prefer-local-function` reads. */
private typedef Seams = {
	var literalKinds: Array<String>;
	var assignKind: String;
	var exprStmtKind: String;
	var localDeclKinds: Array<String>;
	var localDeclContinuationKinds: Array<String>;
	var identKind: String;
	var stringInterpKind: Null<String>;
	var writeParentKinds: Array<String>;
	var scopeKinds: Array<String>;
	var branchKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var paramKinds: Array<String>;
	var restParamKind: Null<String>;
	var bodyKinds: Array<String>;
	var noBodyKind: Null<String>;
	var typeAnnotationKinds: Array<String>;
	var nullLiteralKind: Null<String>;
	var castKinds: Array<String>;
	var uncheckedCastKind: Null<String>;
	var voidTypeName: Null<String>;
	var blockKinds: Array<String>;
}

/** One rewritable binding: the literal's span (the finding key) and the edits that hoist it. */
private typedef Match = {
	var reportSpan: Span;
	var edits: Array<{ span: Span, text: String }>;
}

/**
 * A literal's emitted pieces: typed parameter texts, the return-type hint span, the body span, whether
 * that body is a block, and whether it arrived BARE — a lambda's arrow body rather than a body node.
 */
private typedef FnParts = {
	var params: Array<String>;
	var hintSpan: Null<Span>;
	var bodySpan: Span;
	var block: Bool;
	var bare: Bool;
}

/**
 * What a binding's written type says: whether the hoist may drop it, and whether it named a `Void` result.
 */
private typedef DeclaredType = {
	var survives: Bool;
	var returnsVoid: Bool;
}

/**
 * Occurrence tally for one name: how many declarations were seen, and whether every occurrence passed its gate.
 */
private typedef Refs = {
	var declarations: Int;
	var ok: Bool;
}
