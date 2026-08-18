package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

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

	public function new() {}

	public function id(): String {
		return 'prefer-for-in';
	}

	public function description(): String {
		return 'a hand-rolled iterator loop (while (it.hasNext()) { final x = it.next(); … }) replaceable with for (x in it)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
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
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final textBySpan: Map<String, String> = [];
		for (m in collectMatches(tree, source, seams)) textBySpan['${m.span.from}:${m.span.to}'] = m.text;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final text: Null<String> = textBySpan['${span.from}:${span.to}'];
			if (text != null) edits.push({ span: span, text: text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the `RefShape` kinds this check reads, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
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
			blockStmtKind: blockStmtKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			localDeclKinds: localDeclKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			interpIdentKind: shape.stringInterpIdentKind
		};
	}

	/** Walk `tree` and return every qualifying loop, each with its replacement span and text. */
	private static function collectMatches(tree: QueryNode, source: String, s: Seams): Array<Match> {
		final ctx: Ctx = { source: source, seams: s, root: tree };
		final out: Array<Match> = [];
		walk(tree, ctx, out);
		return out;
	}

	/**
	 * Descend `node`, testing each child as a candidate loop with its preceding sibling as the
	 * inlining arm's declaration. A reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length) {
			final m: Null<Match> = tryMatch(kids[i], i == 0 ? null : kids[i - 1], ctx);
			if (m != null) out.push(m);
		}
		for (c in kids) walk(c, ctx, out);
	}

	/**
	 * Whether `loop` is the hand-rolled protocol; returns the replacement span and text when so,
	 * else null. `prev` is the loop's preceding sibling, the inlining arm's only candidate.
	 */
	private static function tryMatch(loop: QueryNode, prev: Null<QueryNode>, ctx: Ctx): Null<Match> {
		final s: Seams = ctx.seams;
		if (loop.kind != s.whileStmtKind || loop.children.length != WHILE_CHILD_COUNT) return null;
		final body: QueryNode = loop.children[1];
		final iterator: Null<String> = protocolReceiver(loop.children[0], HAS_NEXT_METHOD, s);
		if (iterator == null || body.kind != s.blockStmtKind || body.children.length < MIN_BODY_STATEMENTS) return null;
		final binding: QueryNode = body.children[0];
		final binder: Null<String> = binding.name;
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
			+ StringTools.rtrim(source.substring(bodySpan.from + 1, bindSpan.from)) + source.substring(bindSpan.to, bodySpan.to);
		final inlined: Null<Match> = inlineDeclaration(prev, loopSpan, iterator, binder, interior, ctx);
		return inlined ?? { span: loopSpan, text: 'for ($binder in $iterator) $interior' };
	}

	/**
	 * The wider match that also drops the iterator's declaration, when `prev` IS that declaration
	 * and no other occurrence of the name exists in the file; null when the arm does not apply,
	 * which leaves the caller's plain rewrite standing.
	 */
	private static function inlineDeclaration(
		prev: Null<QueryNode>, loopSpan: Span, iterator: String, binder: String, interior: String, ctx: Ctx
	): Null<Match> {
		final s: Seams = ctx.seams;
		if (prev == null || !s.localDeclKinds.contains(prev.kind)) return null;
		if (prev.name != iterator || prev.children.length != SOLE_CHILD_COUNT) return null;
		final declSpan: Null<Span> = prev.span;
		final initSpan: Null<Span> = prev.children[0].span;
		if (declSpan == null || initSpan == null) return null;
		if (CheckScan.hasCommentMarker(ctx.source, declSpan.to, loopSpan.from)) return null;
		if (occurrences(ctx.root, iterator, s) != PROTOCOL_OCCURRENCES) return null;
		final iterable: String = StringTools.rtrim(ctx.source.substring(initSpan.from, initSpan.to));
		if (RefactorSupport.textHasCommentMarker(iterable.substring(iterable.lastIndexOf('\n') + 1))) return null;
		return { span: new Span(declSpan.from, loopSpan.to), text: 'for ($binder in $iterable) $interior' };
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
	var blockStmtKind: String;
	var callKind: String;
	var fieldAccessKind: String;
	var identKind: String;
	var localDeclKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var interpIdentKind: Null<String>;
}

/** A flagged loop: the full replacement span and the `for` text that takes its place. */
private typedef Match = {
	var span: Span;
	var text: String;
}

/** Per-file inputs the walkers share: the source, the resolved seams and the file's root node. */
private typedef Ctx = {
	var source: String;
	var seams: Seams;
	var root: QueryNode;
}
