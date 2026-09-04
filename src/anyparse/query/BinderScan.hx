package anyparse.query;

using StringTools;
using Lambda;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * Names a construct BINDS that the scope resolver does not see, and the subtree that owns a
 * binding. The resolver indexes declarations; a `case` pattern capture, a bare (unparenthesised)
 * arrow-lambda parameter and a key-value loop's key are bindings the grammar spells without a
 * declaration node, so a scan that trusts the resolver alone reads them as free references to
 * whatever else carries that name.
 *
 * Every collector here produces that SHADOW SET — the names a consumer must subtract before
 * treating an occurrence as a reference. `enclosingFunctionSubtree` and `bindingHostSubtree`
 * are the other half of the same question: which region a binder's scope actually covers.
 */
@:nullSafety(Strict)
final class BinderScan {

	/**
	 * The local name a top-level statement DECLARES, or null — the `name` of
	 * `topLevelDeclaredNode`'s result. ONE `declKinds` list rather than the node walk's
	 * statement/expression pair: its two callers, `exclusiveBranchRedeclaration` and
	 * `condArmDeclarations`, ask with a vocabulary that is already a union.
	 */
	public static function topLevelDeclaredName(stmt: QueryNode, declKinds: Array<String>, metaKinds: Array<String>): Null<String> {
		final decl: Null<QueryNode> = topLevelDeclaredNode(stmt, declKinds, [], metaKinds);
		return decl?.name;
	}

	/**
	 * The declaration NODE a top-level statement DECLARES a local in, or null — the
	 * node `topLevelDeclaredName` reads the name off, exposed for callers that also
	 * need its span (`guard-continue`'s collision rename locates the binder token
	 * inside it). Same walk: a `localDeclKinds` statement answers directly, otherwise
	 * the walk descends through single-payload wrappers (`metaKinds` children skipped)
	 * to an expression-position declaration.
	 */
	public static function topLevelDeclaredNode(
		stmt: QueryNode, localDeclKinds: Array<String>, localDeclExprKinds: Array<String>, metaKinds: Array<String>
	): Null<QueryNode> {
		var cur: QueryNode = stmt;
		while (true) {
			if (localDeclKinds.contains(cur.kind) || localDeclExprKinds.contains(cur.kind)) return cur;
			final payload: Array<QueryNode> = [for (c in cur.children) if (!metaKinds.contains(c.kind)) c];
			if (payload.length != 1) return null;
			cur = payload[0];
		}
	}

	/**
	 * Every name a case PATTERN binds in `node`'s subtree: each name inside a
	 * `casePatternKind` subtree (a capture projects as a bare identifier there, so the
	 * whole pattern is collected — a constructor name coming along only costs the caller a
	 * report) plus the name of every `binderKinds` node, which carries its binding on the
	 * node itself (`case var x:`). Deduped, one walk.
	 */
	public static function casePatternNames(node: QueryNode, casePatternKind: Null<String>, binderKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		collectCasePatternNames(node, false, casePatternKind, binderKinds, out);
		return out;
	}

	/**
	 * Every name bound in `root` by a construct the SCOPE RESOLVER cannot see — the shadow set a
	 * consumer must subtract before reading an unbound identifier as anything but a local. Null when
	 * the grammar exposes no seam for one of the classes, which a consumer must read as "the shadow
	 * cannot be ruled out" rather than as an empty set.
	 *
	 * Two classes, each confirmed against the Haxe grammar rather than assumed (the parenthesized
	 * lambda param, the `catch` binder and a local function's own parameters all DO resolve, and are
	 * deliberately absent):
	 *
	 *  - CASE PATTERNS (`case Leaf(m):`) — the binder lives inside the pattern subtree.
	 *  - the BARE single-parameter arrow lambda (`m -> m.f()`), whose parameter the grammar projects
	 *    as a plain identifier expression indistinguishable from a read — the model carries no binder
	 *    node to resolve, so the resolver has nothing to bind. Recovering that distinction in the
	 *    projection would close this for every consumer at once and delete this arm; until then the
	 *    name is vetoed wherever it appears in the file.
	 */
	public static function resolverInvisibleBinderNames(root: QueryNode, shape: RefShape): Null<Array<String>> {
		final identKind: Null<String> = shape.identKind;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final binderKinds: Array<String> = shape.casePatternBinderKinds ?? [];
		if (identKind == null || lambdaKinds == null || (shape.plainCasePatternKind == null && binderKinds.length == 0)) return null;
		final names: Array<String> = casePatternNames(root, shape.plainCasePatternKind, binderKinds);
		collectBareLambdaParamNames(root, identKind, lambdaKinds, names);
		return names;
	}

	/**
	 * The OPERAND children of an iteration node — its iterable and its body — with the VALUE binder
	 * of a key-value iteration filtered out. A consumer indexing `children[0]` for the iterable, or
	 * comparing `children.length` against a fixed operand count, reads the binder instead on every
	 * key-value loop.
	 */
	public static function loopOperands(loop: QueryNode, valueBinderKinds: Array<String>): Array<QueryNode> {
		return [for (c in loop.children) if (!valueBinderKinds.contains(c.kind)) c];
	}

	/**
	 * The deepest function / lambda subtree containing `cursor`, or the whole tree when none
	 * does — the region a local binding can be referenced from, and therefore the scope a
	 * name-agnostic net (an unreadable interpolation hole, a same-block re-declaration) has
	 * to sweep.
	 *
	 * No containment pruning: the parse root (and other synthesized wrappers) carries NO
	 * span, so a prune at a null-span node would stop at the root and silently widen the
	 * scope to the whole file (false refusals for a same-named local in a SIBLING function).
	 * Gate only the match.
	 */
	public static function enclosingFunctionSubtree(tree: QueryNode, cursor: Int, shape: RefShape): QueryNode {
		final fnKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []);
		var best: QueryNode = tree;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && cursor >= span.from && cursor < span.to && fnKinds.contains(node.kind)) best = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * The function subtree the same-name guards sweep - the one that OWNS `binding`.
	 *
	 * Those guards ask a question about the BINDING - can a reference to this name past an `#end`
	 * belong to a declaration that another build configuration does not have? - so the anchor is the
	 * binding's declaration, never the cursor. A read inside a nested local function or lambda resolves
	 * to a binding declared in the OUTER function, and a cursor anchor confines the sweep to that
	 * nested body, which holds no conditional region: the guard passes and the rename rewrites the
	 * references of one configuration only.
	 *
	 * A local `function g` is declared in its PARENT's block while its own span contains that
	 * declaration offset, so an anchor landing exactly on the function it names steps out one level.
	 * Otherwise renaming `g` from its own declaration would sweep only its body and miss a conditional
	 * region two statements down that declares the same name. That is the climb the cursor anchor also
	 * needed, now gated on the binding's identity instead of on its name.
	 *
	 * A binding no function owns is a TYPE MEMBER, for which `enclosingFunctionSubtree` answers the
	 * whole tree. A local declared in some other method shadows the member and binds only to itself, so
	 * sweeping the module for one would cost working renames and prove nothing (measured: 433 extra
	 * refusals across the installed haxelib). Such a binding keeps the cursor's own function, which is
	 * what shipped.
	 *
	 * Every step widens, which is the safe direction: `exclusiveBranchRedeclaration` recurses through
	 * everything under the scope it is given, so a scope that is too wide can only over-refuse.
	 */
	public static function bindingHostSubtree(tree: QueryNode, cursor: Int, binding: Null<Int>, shape: RefShape): QueryNode {
		final cursorHost: QueryNode = enclosingFunctionSubtree(tree, cursor, shape);
		if (binding == null) return cursorHost;
		final host: QueryNode = enclosingFunctionSubtree(tree, binding, shape);
		if (host == tree) return cursorHost;
		final localFnKinds: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final span: Null<Span> = host.span;
		if (span == null || span.from != binding || !localFnKinds.contains(host.kind)) return host;
		final parentSpan: Null<Span> = TreePath.parentOf(tree, host)?.span;
		return parentSpan == null ? tree : enclosingFunctionSubtree(tree, parentSpan.from, shape);
	}

	/**
	 * Every identifier a `case` pattern in `tree` BINDS — the pattern wrapper is a case
	 * branch's first child. Sibling case-branch captures flatten into ONE scope frame, so a
	 * member sharing a capture's name can be mis-attributed by the resolver; the member
	 * operations refuse a rename or a move when the member name is in this set.
	 *
	 * An identifier the LANGUAGE cannot bind as a pattern variable is left out: it is a
	 * reference to a constant, and counting it as a capture refused every rename of an
	 * `enum abstract` value that its own type spells in a `switch`. Governed by
	 * `RefShape.upperInitialNeverCaptures`; unset keeps every pattern identifier.
	 */
	public static function casePatternCaptures(tree: QueryNode, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		final identKind: String = shape.identKind;
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		if (caseBranchKind == null) return out;
		final skipUpperInitial: Bool = shape.upperInitialNeverCaptures == true;
		function walkPattern(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (node.kind == identKind && name != null && !(skipUpperInitial && SourceText.isUpperInitial(name)) && !out.contains(name))
				out.push(name);
			for (c in node.children) walkPattern(c);
		}
		function walk(node: QueryNode): Void {
			if (node.kind == caseBranchKind && node.children.length > 0) walkPattern(node.children[0]);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** Recursive worker of `casePatternNames`; `inPattern` marks a subtree already inside a pattern. */
	private static function collectCasePatternNames(
		node: QueryNode, inPattern: Bool, casePatternKind: Null<String>, binderKinds: Array<String>, out: Array<String>
	): Void {
		final within: Bool = inPattern || (casePatternKind != null && node.kind == casePatternKind);
		final name: Null<String> = node.name;
		if (name != null && (within || binderKinds.contains(node.kind)) && !out.contains(name)) out.push(name);
		for (child in node.children) collectCasePatternNames(child, within, casePatternKind, binderKinds, out);
	}

	/**
	 * Append every bare (unparenthesized) arrow-lambda parameter name in `node`'s subtree to
	 * `out`. A lambda that binds a bare parameter always carries a BODY after it, so the
	 * `children.length > 1` guard is what separates a parameter at `children[0]` from a
	 * zero-parameter lambda whose only child IS its body: `() -> foo` projects as
	 * `ThinParenLambdaExpr(IdentExpr foo)` and without the guard vetoed `foo` - 15 sites in
	 * this project alone, each one a name `implicit-this` resolution then refused to answer.
	 */
	private static function collectBareLambdaParamNames(
		node: QueryNode, identKind: String, lambdaKinds: Array<String>, out: Array<String>
	): Void {
		if (lambdaKinds.contains(node.kind) && node.children.length > 1) {
			final first: QueryNode = node.children[0];
			final name: Null<String> = first.name;
			if (first.kind == identKind && name != null && !out.contains(name)) out.push(name);
		}
		for (child in node.children) collectBareLambdaParamNames(child, identKind, lambdaKinds, out);
	}

}
