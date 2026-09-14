package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * Inline a method / function into its call sites — the method analog of
 * `Inline` (inline-variable), and the third refactoring built on the
 * shared call-site machinery (`CallSites`, also driving `ChangeSig` /
 * `RemoveParam`).
 *
 * Given a cursor on a function DECLARATION (a `FnMember`, a `final`
 * method `FinalModifiedMember`, or a named local function `LocalFnStmt`),
 * the inline:
 *
 *  1. Resolves the decl and its parameters exactly as `RemoveParam` does.
 *  2. Requires the body to be a SINGLE return expression `E` — a
 *     `{ return E; }` block, a `=> E` / `return E;` arrow body, or a bare
 *     expression body. Anything else (void / multi-statement / abstract
 *     body) is refused.
 *  3. Collects EVERY in-file call site through `CallSites.collect`, which
 *     PROVES the set complete (bare + `this.name` for methods, unique
 *     name for local functions) — an unprovable set is refused.
 *  4. Substitutes each call's positional arguments for the parameter
 *     references in `E` (parenthesising to preserve precedence), replaces
 *     the call with the substituted `E`, and deletes the now-dead decl.
 *  5. Re-parses the result; an unparseable rewrite is rejected.
 *
 * Like inline-variable this is FORMAT-PRESERVING: it relocates existing
 * expressions via raw span splices (`RefactorSupport.applyEdits`), NOT
 * through the writer — so the surrounding layout is untouched.
 *
 * ## Safety model — a strict whitelist, refuse the unknown
 *
 * The body is reduced to one expression so there is no statement-order
 * or early-return semantics to preserve. Argument substitution is guarded
 * against changing evaluation:
 *
 *  - A parameter used exactly once consumes its argument once — always safe.
 *  - A parameter used zero times DROPS its argument, and one used 2+ times
 *    DUPLICATES it; both are allowed ONLY when the argument is PURE (a
 *    side-effect-free literal / identifier / operator expression — the
 *    same whitelist `Inline` uses for an initializer). An impure argument
 *    in either case is refused rather than silently dropped / re-evaluated.
 *  - `E` referencing the method itself (recursion), a parameter via simple
 *    `'$p'` string interpolation (no expression can replace it), or a
 *    nested binding that shadows a parameter name — all refused.
 *  - Every call must pass exactly as many positional arguments as the
 *    function has parameters (no default-filling) — else refused.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (1-based), identical to
 * `Inline` / `RemoveParam`.
 */
@:nullSafety(Strict)
final class InlineMethod {

	/**
	 * Inline the function whose declaration is at `line:col` in `source`.
	 * `plugin` / `shape` are the caller-owned grammar plugin and its
	 * `RefShape` (the pair the `refs` CLI builds). Returns `Ok(rewritten)`
	 * or an `Err` describing why the inline could not be applied. The
	 * source is never mutated — the caller decides whether to write the
	 * result.
	 */
	public static function inlineMethod(source: String, line: Int, col: Int, plugin: GrammarPlugin, shape: RefShape): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final prep: InlineMethodPrep = resolveInlineMethod(source, line, col, cursor, tree, shape);
		return switch prep {
			case PErr(message): Err(message);
			case POk(target): buildInlineMethodEdits(source, target, plugin, shape);
		};
	}

	/**
	 * Binding kinds that, occurring INSIDE the body expression `E` with a parameter's name,
	 * shadow that parameter — read off the grammar: a parameter slot, a local declaration (its
	 * continuation spelling included, which binds a name of its own), or a local function. A
	 * shadowed parameter name inside `E` would make the naive identifier substitution rewrite
	 * the WRONG binding, so the inline refuses on any such collision.
	 *
	 * Missing a shadowing kind is the dangerous direction (a silent wrong rewrite) and listing
	 * one that cannot occur costs a refusal, so the union is taken whole rather than narrowed.
	 */
	private static function shadowBindKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		inline function add(kinds: Null<Array<String>>): Void if (kinds != null) for (kind in kinds) if (!out.contains(kind))
			out.push(kind);
		add(shape.paramKinds);
		add(shape.localDeclKinds);
		add(shape.localFunctionKinds);
		return out;
	}


	/**
	 * The single return expression `E` of `decl`'s body, or null when the
	 * body is not exactly one returned expression. Handles the three body
	 * shapes the grammar produces:
	 *
	 *  - `BlockBody` with exactly one `ReturnStmt` child → its value.
	 *  - `ExprBody` wrapping a `ReturnExpr` (the `return E;` / `=> E` arrow
	 *    form) → the `ReturnExpr`'s value.
	 *  - `ExprBody` wrapping a bare expression (an expression-statement
	 *    body) → that expression.
	 *
	 * A void `return;` (no value), a multi-statement block, or a missing
	 * body (abstract / interface method) all yield null.
	 */
	private static function singleReturnExpr(decl: QueryNode, shape: RefShape): Null<QueryNode> {
		if (decl.children.length == 0) return null;
		final body: QueryNode = decl.children[decl.children.length - 1];
		// The two body shapes an inline can reduce, asked of the grammar: a statement block
		// (`RefShape.blockBodyKind`) or a wrapper whose single child IS the value
		// (`expressionBodyKinds`). Every other body kind — bodyless, `untyped`, a
		// conditional-compilation region — falls out here, which is the refusal it always was.
		final isBlock: Bool = body.kind == shape.blockBodyKind;
		if (!isBlock && !(shape.expressionBodyKinds ?? []).contains(body.kind)) return null;
		if (body.children.length == 0) return null;

		if (isBlock) {
			if (body.children.length != 1) return null;
			final stmt: QueryNode = body.children[0];
			return if (stmt.kind != shape.returnStatementKind)
				null
			else if (stmt.children.length > 0)
				stmt.children[0]
			else
				null;
		}

		// ExprBody: a single expression, possibly a value-return wrapper (`return E` in expression
		// position — `valueReturnKinds` is the grammar's own superset of `returnStatementKind`).
		final inner: QueryNode = body.children[0];
		return if (!(shape.valueReturnKinds ?? []).contains(inner.kind))
			inner
		else if (inner.children.length > 0)
			inner.children[0]
		else
			null;
	}

	/**
	 * Build the substitution text for one call site: `E`'s source with
	 * every parameter `IdentExpr` replaced by the matching argument's
	 * source (each parenthesised when its root is an operator), then the
	 * whole result parenthesised unless `E`'s root is atomic — so the
	 * substituted expression keeps `E`'s precedence at the call position.
	 */
	private static function substitute(
		source: String, expr: QueryNode, paramNames: Array<String>, args: Array<QueryNode>, shape: RefShape
	): Null<String> {
		final exprSpan: Null<Span> = expr.span;
		if (exprSpan == null) return null;
		final eFrom: Int = exprSpan.from;
		final identKind: String = shape.identKind;
		// Derived once for the whole substitution, not per argument: `argText` runs inside the walk.
		final parenFreeRoots: Array<String> = MemberKinds.parenFreeRootKinds(shape);
		var text: String = source.substring(eFrom, exprSpan.to);

		// Collect parameter-ident occurrences in `E` (absolute spans). A
		// missing span on a target / argument node aborts to null so the
		// caller refuses rather than emit a half-substituted body.
		final hits: Array<{ from: Int, to: Int, text: String }> = [];
		var failed: Bool = false;
		function walk(node: QueryNode): Void {
			if (failed) return;
			if (node.kind == identKind) {
				final nm: Null<String> = node.name;
				final sp: Null<Span> = node.span;
				if (nm != null && sp != null) {
					final idx: Int = paramNames.indexOf(nm);
					if (idx >= 0) {
						final at: Null<String> = argText(source, args[idx], parenFreeRoots);
						if (at == null) {
							failed = true;
							return;
						}
						hits.push({ from: sp.from, to: sp.to, text: at });
					}
				}
			}
			for (c in node.children) walk(c);
		}
		walk(expr);
		if (failed) return null;

		// Splice end-to-start so earlier offsets stay valid.
		hits.sort((a, b) -> b.from - a.from);
		for (h in hits) text = text.substring(0, h.from - eFrom) + h.text + text.substring(h.to - eFrom);

		return parenFreeRoots.contains(expr.kind) ? text : '($text)';
	}

	/**
	 * An argument's source, parenthesised when its root does not outrank the operators; null when it
	 * has no span. Takes the derived root vocabulary rather than the shape — the caller runs this
	 * inside a subtree walk and derives it once.
	 */
	private static function argText(source: String, arg: QueryNode, parenFreeRoots: Array<String>): Null<String> {
		final raw: Null<String> = SourceText.nodeText(arg, source);
		return if (raw == null)
			null
		else if (parenFreeRoots.contains(arg.kind))
			raw
		else
			'($raw)';
	}

	/** Count identifier nodes named `name` in `node`'s subtree. */
	private static function countIdentExprNamed(node: QueryNode, name: String, shape: RefShape): Int {
		final identKind: String = shape.identKind;
		var count: Int = 0;
		function walk(n: QueryNode): Void {
			if (n.kind == identKind && n.name == name) count++;
			for (c in n.children) walk(c);
		}
		walk(node);
		return count;
	}

	/**
	 * Does `node`'s subtree contain a call to bare `name`, or to a `receiver.name` member?
	 *
	 * A grammar that declares no call kind answers false, which is not a hole: the same grammar
	 * gives `CallSites.collect` nothing to collect, and an inline with no proven call site is
	 * refused one step later.
	 */
	private static function callsName(node: QueryNode, name: String, shape: RefShape): Bool {
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return false;
		final identKind: String = shape.identKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			if (n.kind == callKind && n.children.length > 0) {
				final callee: QueryNode = n.children[0];
				if (callee.kind == identKind && callee.name == name)
					found = true;
				else if (callee.kind == fieldAccessKind && callee.name == name)
					found = true;
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return found;
	}

	/**
	 * The first parameter name shadowed by a nested binding inside `expr`, or null. A parameter
	 * slot, a local declaration or a local function whose name matches a parameter rebinds it
	 * within `E` — the vocabulary is `shadowBindKinds`, read off the grammar.
	 */
	private static function shadowedParam(expr: QueryNode, paramNames: Array<String>, shape: RefShape): Null<String> {
		final shadowKinds: Array<String> = shadowBindKinds(shape);
		var hit: Null<String> = null;
		function walk(n: QueryNode): Void {
			if (hit != null) return;
			final nm: Null<String> = n.name;
			if (nm != null && shadowKinds.contains(n.kind) && paramNames.contains(nm)) {
				hit = nm;
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(expr);
		return hit;
	}

	/**
	 * The first parameter referenced via a SIMPLE `'$p'` string interpolation inside `expr`, or
	 * null. Simple interpolation projects the grammar's `stringInterpIdentKind` (distinct from
	 * the `identKind` of normal positions and of `${ ... }` complex interpolation, which the
	 * substitution handles); `$p` cannot be replaced by an arbitrary argument expression, so its
	 * presence is a refusal.
	 */
	private static function interpolatedParam(expr: QueryNode, paramNames: Array<String>, shape: RefShape): Null<String> {
		final interpIdentKind: Null<String> = shape.stringInterpIdentKind;
		if (interpIdentKind == null) return null;
		var hit: Null<String> = null;
		function walk(n: QueryNode): Void {
			if (hit != null) return;
			if (n.kind == interpIdentKind) {
				final nm: Null<String> = n.name;
				if (nm != null && paramNames.contains(nm)) {
					hit = nm;
					return;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(expr);
		return hit;
	}

	/**
	 * Is every node kind in `arg`'s subtree pure — safe to DROP (a 0-use parameter) or DUPLICATE
	 * (a 2+-use parameter) without changing evaluation?
	 *
	 * The vocabulary used to be a 36-name array here, copied from a second one in `MemberKinds`
	 * "per the adapt-not-import rule", and both were widened by a NAME-CONVENTION stub
	 * (`|| kind.endsWith('Lit') || kind.endsWith('StringExpr')`) that readmitted the object and
	 * regex literals the list's own doc said were absent. An argument this call reports pure is
	 * DUPLICATED once per use of its parameter, so an allocating literal admitted here turns one
	 * value into several. Adapting a copy is what let the two spellings drift; the grammar
	 * declaring it once is what ends that.
	 */
	private static function isPure(arg: QueryNode, shape: RefShape): Bool {
		// Derived once and threaded through the walk, not re-derived per node.
		final kinds: Array<String> = MemberKinds.sideEffectFreeExprKinds(shape);
		var pure: Bool = true;
		function walk(node: QueryNode): Void {
			if (!pure) return;
			if (!kinds.contains(node.kind)) {
				pure = false;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(arg);
		return pure;
	}

	/**
	 * Resolve and validate the inline-method target at `cursor`: the binding must
	 * be a function decl whose body is a single return expression `E`, not
	 * recursive, with no parameter shadowed or simple-interpolated inside `E`, and
	 * whose in-file call sites form a proven-complete set. Returns the validated
	 * `InlineMethodTarget` (including the per-parameter substitution counts) or a
	 * `PErr` with the precise refusal reason.
	 */
	private static function resolveInlineMethod(
		source: String, line: Int, col: Int, cursor: Int, tree: QueryNode, shape: RefShape
	): InlineMethodPrep {
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return PErr('position $line:$col is not on a function or a call');
		final cursorNode: QueryNode = node;
		final targetName: Null<String> = cursorNode.name;
		if (targetName == null) return PErr('position $line:$col is not on a function or a call');
		final name: String = targetName;

		final declNode: Null<QueryNode> = CallSites.resolveFnDecl(cursorNode, tree, name, shape);
		if (declNode == null) return PErr('could not resolve a function binding for "$name" at $line:$col');
		final decl: QueryNode = declNode;
		if (!MemberKinds.FN_DECL_KINDS.contains(decl.kind))
			return PErr('"$name" is not a function (inline-method inlines a function declaration)');
		final declSpan: Null<Span> = decl.span;
		if (declSpan == null) return PErr('"$name" declaration has no source span');
		final binding: Int = declSpan.from;
		final declSpanNN: Span = declSpan;

		// Parameter list + names (a nameless param slot cannot be substituted).
		final params: Array<QueryNode> = CallSites.leadingParams(decl, shape);
		final paramNames: Array<String> = [];
		for (p in params) {
			final pn: Null<String> = p.name;
			if (pn == null) return PErr('"$name" has a parameter with no name slot — cannot inline');
			paramNames.push(pn);
		}

		// Body must reduce to a single return expression `E`.
		final body: Null<QueryNode> = singleReturnExpr(decl, shape);
		if (body == null)
			return PErr('"$name" body is not a single return expression — only `{ return E; }` / `=> E` bodies can be inlined');
		final exprBody: QueryNode = body;

		// Recursion: `E` calling `name` would outlive the deleted decl.
		if (callsName(exprBody, name, shape)) return PErr('"$name" is recursive — cannot inline a function that calls itself');

		// A parameter shadowed by a nested binding inside `E` would be
		// substituted at the wrong binding.
		final shadow: Null<String> = shadowedParam(exprBody, paramNames, shape);
		if (shadow != null) return PErr('parameter "$shadow" is shadowed inside the body of "$name" — cannot inline');

		// A parameter referenced via simple `'$p'` interpolation cannot be
		// replaced by an arbitrary argument expression.
		final interp: Null<String> = interpolatedParam(exprBody, paramNames, shape);
		if (interp != null) return PErr('parameter "$interp" is used in string interpolation (\'$$$interp\') in "$name" — cannot inline');

		// Collect + prove-complete the in-file call sites (the same proof
		// `change-sig` / `remove-param` rely on).
		final callSites: Array<QueryNode> = switch CallSites.collect(decl, tree, source, name, binding, shape) {
			case CErr(message): return PErr(message);
			case COk(sites): sites;
		};
		if (callSites.length == 0) return PErr('"$name" has no in-file call sites to inline');

		// Per-parameter substitution count in `E` (the IdentExpr targets).
		final occ: Array<Int> = [for (pn in paramNames) countIdentExprNamed(exprBody, pn, shape)];

		return POk({
			name: name,
			declSpan: declSpanNN,
			params: params,
			paramNames: paramNames,
			exprBody: exprBody,
			occ: occ,
			callSites: callSites
		});
	}

	/**
	 * Build and apply the inline-method edits for a validated `target`: replace
	 * each proven call site with `E`'s source, the call's positional arguments
	 * substituted for the parameter references (refusing an arity mismatch, or a
	 * non-pure argument that would be dropped or duplicated), delete the dead
	 * declaration, then re-parse the rewrite — an unparseable result is rejected.
	 */
	private static function buildInlineMethodEdits(
		source: String, target: InlineMethodTarget, plugin: GrammarPlugin, shape: RefShape
	): EditResult {
		final name: String = target.name;
		final params: Array<QueryNode> = target.params;
		final paramNames: Array<String> = target.paramNames;
		final exprBody: QueryNode = target.exprBody;
		final occ: Array<Int> = target.occ;

		final edits: Array<{ span: Span, text: String }> = [];
		for (call in target.callSites) {
			final args: Array<QueryNode> = call.children.slice(1);
			if (args.length != params.length) {
				final at: String = CallSites.posOf(source, call.span);
				return Err(
					'call at $at passes ${args.length} args, expected ${params.length}'
					+ ' — inline-method cannot fill omitted optional arguments'
				);
			}
			// A dropped (0-use) or duplicated (2+-use) argument must be pure.
			for (i in 0...params.length) {
				if (occ[i] != 1 && !isPure(args[i], shape)) {
					final at: String = CallSites.posOf(source, call.span);
					final reason: String = occ[i] == 0
						? 'dropped (parameter "${paramNames[i]}" is unused)'
						: 'duplicated (parameter "${paramNames[i]}" is used ${occ[i]} times)';
					return Err('argument ${i} at $at would be $reason but is not side-effect-free — cannot inline');
				}
			}
			final callSpan: Null<Span> = call.span;
			if (callSpan == null) return Err('a call site of "$name" has no source span');
			final subText: Null<String> = substitute(source, exprBody, paramNames, args, shape);
			if (subText == null) return Err('a node of "$name" has no source span — cannot inline');
			edits.push({ span: callSpan, text: subText });
		}

		// Delete the now-dead declaration (its whole owned lines).
		final deleteSpan: Null<Span> = ElementSpan.ownedLinesSpan(source, target.declSpan);
		if (deleteSpan == null) return Err('"$name" declaration shares its line with other code — cannot inline cleanly');
		edits.push({ span: deleteSpan, text: '' });

		final rewritten: String = CanonicalEdit.applyEdits(source, edits);
		if (rewritten == source) return Err('inline of "$name" is a no-op');

		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: $exception')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');

		return Ok(rewritten);
	}

}

/**
 * A validated inline-method target: the function name, its decl span (deleted
 * after inlining), the parameter slot nodes and names, the single-return body
 * expression `E`, the per-parameter substitution counts within `E`, and the
 * proven-complete set of in-file call sites.
 */
private typedef InlineMethodTarget = {
	final name: String;
	final declSpan: Span;
	final params: Array<QueryNode>;
	final paramNames: Array<String>;
	final exprBody: QueryNode;
	final occ: Array<Int>;
	final callSites: Array<QueryNode>;
};

/** Resolution outcome of `resolveInlineMethod`: the target or a refusal. */
private enum InlineMethodPrep {

	POk(target: InlineMethodTarget);
	PErr(message: String);

}
