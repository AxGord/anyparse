package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.CondBranchProjection;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a hand-rolled iterator protocol — `while (it.hasNext()) { final x = it.next(); … }` —
 * which the language's own `for (x in it)` expresses directly. `Severity.Info` and `DefaultOff`
 * (a modernization cleanup, not a defect), with an autofix. Grammar-agnostic over `RefShape`.
 *
 * ## Why the rewrite is behaviour-preserving
 *
 * `for (x in it)` DESUGARS to exactly the loop being replaced: test `hasNext()`, bind `next()`,
 * run the body. So `break` / `continue` / `return` keep their meaning, and the iterator is left
 * in the same exhausted state afterwards — which is why the plain arm can leave the iterator
 * binding standing and rewrite the loop alone.
 *
 * ## The shape it accepts
 *
 * A `while` whose CONDITION is exactly `<ident>.hasNext()` (a bare identifier receiver, no
 * arguments) and whose body is a BRACED BLOCK of at least two statements whose FIRST statement
 * is a local declaration initialized to exactly `<the same ident>.next()`. That first statement
 * is doing double duty: it supplies the `for` binder, and its position proves `next()` runs
 * exactly ONCE PER ITERATION — a `next()` nested inside an `if` deeper in the body does not, and
 * the `for` form would then advance the iterator where the `while` did not.
 *
 * The iterator identifier must occur EXACTLY TWICE inside the loop (the two protocol receivers)
 * — a second `it.next()`, a re-assignment, or a `$it` interpolation all push the count past two
 * and refuse. Nothing else about the body matters: it is spliced VERBATIM, minus the binding
 * statement, so nested loops, conditional-compilation regions and comments ride along unchanged.
 *
 * The binder's own type annotation is DROPPED — `for (x:T in xs)` is not valid Haxe, and the
 * binder's type comes from the iterator either way. The binder may be a `var`: a `for` binder is
 * WRITABLE in Haxe (measured on `--interp`, `-js` and `-cpp`), so a body that reassigns it
 * converts as safely as one that does not.
 *
 * ## The inlining arm
 *
 * When the statement IMMEDIATELY BEFORE the loop declares the iterator and nothing anywhere else
 * reads that name, the declaration is dropped and its initializer becomes the `for` iterable:
 * `final it = xs.iterator(); while (it.hasNext()) { final x = it.next(); … }` becomes
 * `for (x in xs.iterator()) { … }`. The no-other-read test is a WHOLE-FILE occurrence count, not
 * a scope-local one: a conditional-compilation region is not a scope in Haxe, so a declaration
 * inside `#if` is visible after `#end`, and a scope-local count would miss exactly that read.
 * Over-counting a same-named local in an unrelated function only costs the arm, never soundness.
 *
 * A comment between the declaration and the loop refuses the arm (the merge would drop it), as
 * does a comment on the LAST line of the initializer (it would swallow the `)` that follows).
 * Either refusal falls back to the plain arm, which keeps the declaration — the finding is never
 * lost, only its wider edit.
 *
 * ## What must NOT fire — the census this rule was measured against
 *
 * `hasNext()` has three other idiomatic uses, and every one of them is a legitimate construct the
 * rule must leave alone: a bare NON-EMPTINESS test (`if (xml.elements().hasNext())`,
 * `if (!xml.elements().hasNext()) return null;`, `final has = it.hasNext();`), the PEEK idiom
 * (`it.hasNext() ? it.next() : null`), and a drain loop whose body is a single push
 * (`while (it.hasNext()) out.push(it.next());`) — the last has no statement to take the binder
 * from, and inventing a name is not something a fixer should do. All four fall out of the shape
 * gate: none of them is a `while` over a braced two-or-more statement body starting with the
 * `next()` binding.
 *
 * ## Grammar-agnostic
 *
 * `readSeams` names the required kinds — the `while`, block, call, field-access, local-declaration
 * and identifier kinds — and returns null when any is unset, making the check a no-op. The two
 * protocol METHOD NAMES and the `for (… in …)` header are written as literals, the same way
 * `map-keys-lookup` names `keys` and `prefer-range-loop` emits its `for` header: they are the
 * shape of the iterator protocol in the grammars that have one, not a `RefShape` axis.
 */
@:nullSafety(Strict)
final class PreferForIn implements Check implements DefaultOff {

	/** The protocol method a qualifying `while` condition must call, on a bare identifier, with no arguments. */
	private static inline final HAS_NEXT_METHOD: String = 'hasNext';

	/** The protocol method the body's first statement must be initialized from. */
	private static inline final NEXT_METHOD: String = 'next';

	/** A `while` node has exactly [condition, body] children. */
	private static inline final WHILE_CHILD_COUNT: Int = 2;

	/** A no-argument call has exactly [callee] children, and a field access exactly [receiver]. */
	private static inline final SOLE_CHILD_COUNT: Int = 1;

	/** The binding plus at least one real statement — a body that only drains would become an empty loop. */
	private static inline final MIN_BODY_STATEMENTS: Int = 2;

	/** `hasNext()` in the condition and `next()` in the binding, and nothing else reads the iterator. */
	private static inline final PROTOCOL_OCCURRENCES: Int = 2;

	/**
	 * Element types whose name makes a POOR binder — the basic types, whose lower-cased name
	 * (`int`, `string`, `bool`) reads as a type rather than as the value it holds and tells the
	 * reader nothing the annotation did not. A domain type (`CodePoint` -> `codePoint`) does, which
	 * is the whole reason the derivation is worth having. These fall through to the generic names.
	 */
	private static final UNINFORMATIVE_TYPES: Array<String> = ['Int', 'Float', 'Bool', 'String', 'Dynamic', 'Any', 'UInt'];

	/** Binder names to fall back on, in order, when the declaration carries no element type. */
	private static final FALLBACK_BINDERS: Array<String> = ['value', 'element', 'item'];

	/**
	 * Annotation heads whose single type ARGUMENT is the element the loop binds. Matched
	 * against `QueryNode.type`'s own name, so a same-named field or a qualified lookalike
	 * cannot stand in for one — which a scan of the declaration's source text could not
	 * promise.
	 */
	private static final ELEMENT_TYPE_HEADS: Array<String> = ['Array', 'Iterator', 'Iterable'];

	public function new() {}

	public function id(): String {
		return 'prefer-for-in';
	}

	public function description(): String {
		return 'a hand-rolled iterator loop (while (it.hasNext()) { final x = it.next(); … }) replaceable with for (x in it)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'prefer-for-in',
				severity: Severity.Info,
				message: 'this hand-rolled iterator loop can be a for-in loop (for (x in it))'
			});
		}
		return violations;
	}

	/** Replace each flagged loop — plus its iterator declaration, where the inlining arm fired — with the `for` form. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		return CheckScan.applyTextMatches(plugin, source, violations, (tree, src) -> collectMatches(tree, src, s));
	}

	/** Bundle the `RefShape` kinds this check reads, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final whileStmtKind: Null<String> = shape.whileStmtKind;
		if (whileStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return null;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		return localDeclKinds.length == 0 ? null : {
			whileStmtKind: whileStmtKind,
			whileExprKind: shape.whileExprKind,
			blockStmtKind: blockStmtKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			localDeclKinds: localDeclKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			interpIdentKind: shape.stringInterpIdentKind,
			scopeKinds: readScopeKinds(plugin)
		};
	}

	/**
	 * The block kinds a local declaration's visibility is bounded by — the grammar's own block
	 * kinds MINUS the conditional-branch projection, which is NOT a scope: a `#if` region does
	 * not bind names in Haxe, so a declaration inside one stays visible after `#end`, and
	 * treating the branch as a scope would hide exactly that read. That subtraction is FORWARD
	 * DEFENCE, not a live path: `CheckScan.parseOrNull` goes through `parseFile`, which does not
	 * project branches (`projectBranchAware` is a separate opt-in entry), so no unit fixture can
	 * flip it today — the raw `Conditional` kind is not a block kind at all, which is what makes
	 * `testConditionalRegionIsNotAScope` pass. A grammar with no control-flow support returns an
	 * empty list, and the occurrence scan then falls back to the whole file.
	 */
	private static function readScopeKinds(plugin: GrammarPlugin): Array<String> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? [] : [for (k in support.blockKinds()) if (k != CondBranchProjection.COND_BRANCH_KIND) k];
	}

	/** Walk `tree` and return every qualifying loop, each with its replacement span and text. */
	private static function collectMatches(tree: QueryNode, source: String, s: Seams): Array<Match> {
		final ctx: Ctx = { source: source, seams: s };
		final out: Array<Match> = [];
		walk(tree, tree, null, ctx, out);
		return out;
	}

	/**
	 * Descend `node`, testing each child as a candidate loop with its preceding sibling as the
	 * inlining arm's declaration. `scope` is the nearest enclosing BLOCK, which bounds a local's
	 * visibility and so bounds the inlining arm's occurrence scan. A reification subtree
	 * (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(node: QueryNode, scope: QueryNode, decl: Null<QueryNode>, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.opaqueKinds.contains(node.kind)) return;
		final here: QueryNode = ctx.seams.scopeKinds.contains(node.kind) ? node : scope;
		final holder: Null<QueryNode> = ctx.seams.localDeclKinds.contains(node.kind) ? node : decl;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length) {
			final m: Null<Match> = tryMatch(kids[i], i == 0 ? null : kids[i - 1], here, holder, ctx);
			if (m != null) out.push(m);
		}
		for (c in kids) walk(c, here, holder, ctx, out);
	}

	/**
	 * Whether `loop` is the hand-rolled protocol; returns the replacement span and text when so,
	 * else null. `prev` is the loop's preceding sibling, the inlining arm's only candidate.
	 */
	private static function tryMatch(
		loop: QueryNode, prev: Null<QueryNode>, scope: QueryNode, decl: Null<QueryNode>, ctx: Ctx
	): Null<Match> {
		final s: Seams = ctx.seams;
		final isWhile: Bool = loop.kind == s.whileStmtKind || (s.whileExprKind != null && loop.kind == s.whileExprKind);
		if (!isWhile || loop.children.length != WHILE_CHILD_COUNT) return null;
		final body: QueryNode = loop.children[1];
		final iterator: Null<String> = protocolReceiver(loop.children[0], HAS_NEXT_METHOD, s);
		if (iterator == null) return null;
		if (body.kind != s.blockStmtKind || body.children.length < MIN_BODY_STATEMENTS) {
			return tryUnbound(loop, body, iterator, scope, decl, ctx);
		}
		final binding: QueryNode = body.children[0];
		final binder: Null<String> = binding.name;
		if (loop.kind != s.whileStmtKind) return tryUnbound(loop, body, iterator, scope, decl, ctx);
		if (!s.localDeclKinds.contains(binding.kind) || binding.children.length != SOLE_CHILD_COUNT) return null;
		if (binder == null || binder == iterator) return null;
		if (protocolReceiver(binding.children[0], NEXT_METHOD, s) != iterator) return null;
		if (occurrences(loop, iterator, s) != PROTOCOL_OCCURRENCES) return null;
		final loopSpan: Null<Span> = loop.span;
		final bodySpan: Null<Span> = body.span;
		final bindSpan: Null<Span> = binding.span;
		if (loopSpan == null || bodySpan == null || bindSpan == null) return null;
		final source: String = ctx.source;
		final interior: String = source.substring(bodySpan.from, bodySpan.from + 1)
			+ source.substring(bodySpan.from + 1, bindSpan.from).rtrim() + source.substring(bindSpan.to, bodySpan.to);
		final inlined: Null<Match> = inlineDeclaration(prev, scope, loopSpan, iterator, binder, interior, ctx);
		return inlined ?? { span: loopSpan, text: 'for ($binder in $iterator) $interior' };
	}

	/**
	 * The arm for a loop that binds NOTHING — `while (it.hasNext()) out.push(it.next());` and the
	 * comprehension header `[while (it.hasNext()) it.next()]`. Both are the same protocol as the
	 * bound form; what they lack is a statement to take the `for` binder's NAME from, which is why
	 * this rule refused them until now.
	 *
	 * The name is DERIVED, never invented — the order is the enclosing declaration's element type
	 * (`final a:Array<CodePoint> = [while …]` gives `codePoint`), then the fallback `value`. A
	 * derived name that is already live at the loop's position is skipped for the next candidate,
	 * so the rewrite can never capture an existing binding.
	 *
	 * `occurrences == PROTOCOL_OCCURRENCES` carries the whole soundness argument, exactly as it
	 * does for the bound arm: the iterator's identifier appears TWICE in the loop, once in
	 * `hasNext()` and once in `next()`. That proves in one test that `next()` runs exactly once per
	 * iteration (two calls would advance the iterator twice where `for` advances once), that the
	 * iterator is not re-assigned, and that nothing else reads it.
	 */
	private static function tryUnbound(
		loop: QueryNode, body: QueryNode, iterator: String, scope: QueryNode, decl: Null<QueryNode>, ctx: Ctx
	): Null<Match> {
		final s: Seams = ctx.seams;
		if (occurrences(loop, iterator, s) != PROTOCOL_OCCURRENCES) return null;
		// A braced body holding ONLY the `next()` binding is a loop that drains and does nothing;
		// it was refused before this arm existed and stays refused, since rewriting it buys the
		// reader nothing and the dead binding is `unused-local`'s finding, not this rule's.
		if (
			body.kind == s.blockStmtKind && body.children.length < MIN_BODY_STATEMENTS && body.children.length == 1
			&& s.localDeclKinds.contains(body.children[0].kind)
		)
			return null;
		final drain: Null<QueryNode> = findProtocolCall(body, iterator, s);
		if (drain == null) return null;
		final loopSpan: Null<Span> = loop.span;
		final bodySpan: Null<Span> = body.span;
		final drainSpan: Null<Span> = drain.span;
		if (loopSpan == null || bodySpan == null || drainSpan == null) return null;
		if (drainSpan.from < bodySpan.from || drainSpan.to > bodySpan.to) return null;
		final binder: Null<String> = deriveBinder(decl, scope, ctx);
		if (binder == null) return null;
		final source: String = ctx.source;
		final interior: String = source.substring(bodySpan.from, drainSpan.from) + binder + source.substring(drainSpan.to, bodySpan.to);
		return { span: loopSpan, text: 'for ($binder in $iterator) $interior' };
	}

	/** The one `<iterator>.next()` call in `node`'s subtree, or null when the subtree holds none. */
	private static function findProtocolCall(node: QueryNode, iterator: String, s: Seams): Null<QueryNode> {
		if (protocolReceiver(node, NEXT_METHOD, s) == iterator) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findProtocolCall(c, iterator, s);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * A binder name derived from the declaration, or null when every candidate is already live.
	 * The element type of the enclosing declaration is the only real signal.
	 */
	private static function deriveBinder(decl: Null<QueryNode>, scope: QueryNode, ctx: Ctx): Null<String> {
		final candidates: Array<String> = [];
		final fromType: Null<String> = elementTypeName(decl);
		if (fromType != null) candidates.push(fromType);
		for (fallback in FALLBACK_BINDERS) candidates.push(fallback);
		return candidates.find(name -> !nameIsLive(scope, name, ctx.seams));
	}

	/**
	 * Whether `name` is already taken anywhere in `scope` — as a read, as an interpolation, or as a
	 * DECLARATION. The declaration arm is the load-bearing one: `occurrences` counts identifier
	 * nodes, and a `final value = 1;` carries its name on the declaration node instead, so a check
	 * built on reads alone would hand the loop a binder that shadows a live local.
	 */
	private static function nameIsLive(node: QueryNode, name: String, s: Seams): Bool {
		final self: Bool = node.name == name
			&& (node.kind == s.identKind || node.kind == s.interpIdentKind || s.localDeclKinds.contains(node.kind));
		return self || node.children.exists(c -> nameIsLive(c, name, s));
	}

	/**
	 * `final a:Array<CodePoint> = …` -> `codePoint`; null when the declaration carries no such
	 * annotation, or when its element type says nothing a binder should repeat.
	 *
	 * Asks the TREE. It used to match
	 * `~/:\s*(?:Array|Iterator|Iterable)\s*<\s*([A-Za-z_][A-Za-z0-9_.]*)/` against the source
	 * between the declaration's start and its initializer's, because the grammar projected no
	 * node for a type annotation at all. `QueryNode.type` now carries it — kind = the type
	 * ctor, name = the nominal head, children = the type ARGUMENTS — so the head is compared
	 * to a list instead of being spelled inside a pattern, and the element is a node rather
	 * than a capture group.
	 *
	 * Two inputs the regex answered and the tree declines, both pathological and both landing
	 * on the generic binder rather than on a wrong one: a first argument that is not nominal
	 * (`Array<Foo->Bar>` scanned as `Foo`) and an `Array<T>` nested inside an anon annotation
	 * (`var x:{a:Array<Foo>}`, where the regex found the INNER `:` and the node it is asked
	 * about is the anon).
	 */
	private static function elementTypeName(decl: Null<QueryNode>): Null<String> {
		if (decl == null) return null;
		final annotation: Null<QueryNode> = decl.type;
		if (annotation == null || !ELEMENT_TYPE_HEADS.contains(annotation.name) || annotation.children.length == 0) return null;
		final qualified: Null<String> = annotation.children[0].name;
		if (qualified == null) return null;
		final simple: String = qualified.substring(qualified.lastIndexOf('.') + 1);
		return simple.length == 0 || UNINFORMATIVE_TYPES.contains(simple)
			? null
			: simple.substring(0, 1).toLowerCase() + simple.substring(1);
	}

	/**
	 * The wider match that also drops the iterator's declaration, when `prev` IS that declaration
	 * and no other occurrence of the name exists in the file; null when the arm does not apply,
	 * which leaves the caller's plain rewrite standing.
	 */
	private static function inlineDeclaration(
		prev: Null<QueryNode>, scope: QueryNode, loopSpan: Span, iterator: String, binder: String, interior: String, ctx: Ctx
	): Null<Match> {
		final s: Seams = ctx.seams;
		if (prev == null || !s.localDeclKinds.contains(prev.kind)) return null;
		if (prev.name != iterator || prev.children.length != SOLE_CHILD_COUNT) return null;
		final declSpan: Null<Span> = prev.span;
		final initSpan: Null<Span> = prev.children[0].span;
		if (declSpan == null || initSpan == null) return null;
		if (CheckScan.hasCommentMarker(ctx.source, declSpan.to, loopSpan.from)) return null;
		if (occurrences(scope, iterator, s) != PROTOCOL_OCCURRENCES) return null;
		final iterable: String = ctx.source.substring(initSpan.from, initSpan.to).rtrim();
		return RefactorSupport.textHasCommentMarker(iterable.substring(iterable.lastIndexOf('\n') + 1)) ? null : {
			span: new Span(declSpan.from, loopSpan.to),
			text: 'for ($binder in $iterable) $interior'
		};
	}

	/**
	 * The bare-identifier receiver of `<ident>.<method>()` with no arguments, or null when `node`
	 * is not exactly that call. A qualified receiver (`this.it.hasNext()`) has a field access where
	 * the identifier must be, and misses.
	 */
	private static function protocolReceiver(node: QueryNode, method: String, s: Seams): Null<String> {
		if (node.kind != s.callKind || node.children.length != SOLE_CHILD_COUNT) return null;
		final callee: QueryNode = node.children[0];
		if (callee.kind != s.fieldAccessKind || callee.name != method || callee.children.length != SOLE_CHILD_COUNT) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind == s.identKind ? receiver.name : null;
	}

	/**
	 * How many identifiers in `node`'s subtree carry `name` — a `$name` string interpolation counts,
	 * since it reads the iterator exactly as a bare identifier would. A reification subtree answers
	 * with a count past the protocol's, since nothing about its contents can be proven.
	 */
	private static function occurrences(node: QueryNode, name: String, s: Seams): Int {
		if (s.opaqueKinds.contains(node.kind)) return PROTOCOL_OCCURRENCES + 1;
		var found: Int = node.name == name && (node.kind == s.identKind || node.kind == s.interpIdentKind) ? 1 : 0;
		for (c in node.children) found += occurrences(c, name, s);
		return found;
	}

}

/** The `RefShape` kinds `PreferForIn` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var whileStmtKind: String;
	var whileExprKind: Null<String>;
	var blockStmtKind: String;
	var callKind: String;
	var fieldAccessKind: String;
	var identKind: String;
	var localDeclKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var interpIdentKind: Null<String>;
	var scopeKinds: Array<String>;
}

/** A flagged loop: the full replacement span and the `for` text that takes its place. */
private typedef Match = {
	var span: Span;
	var text: String;
}

/** Per-file inputs the walkers share: the source and the resolved seams. */
private typedef Ctx = {
	var source: String;
	var seams: Seams;
}
