package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a bare local declaration whose every occurrence sits inside ONE nested block, and sinks
 * the declaration into that block:
 *
 * ```haxe
 * var midPoint:Int;
 * while (upper - lower > 2) {
 * 	midPoint = (lower + upper) >> 1;
 * 	if (f(midPoint)) upper = midPoint else lower = midPoint;
 * }
 * // ->
 * while (upper - lower > 2) {
 * 	var midPoint:Int;
 * 	midPoint = (lower + upper) >> 1;
 * 	…
 * }
 * ```
 *
 * `Info` -- the code is correct, this is a scope-narrowing readability fix. The rule does ONE
 * job, moving the declaration; `join-declaration-assignment` then joins it with the assignment
 * it now precedes and `prefer-final` upgrades the keyword, so a full `--fix` converges on
 * `final midPoint:Int = (lower + upper) >> 1;` inside the loop.
 *
 * ## Why this shape exists
 *
 * It is what `dead-store` leaves behind. A placeholder initializer (`var midPoint:Int = 0;`)
 * written only to satisfy a reader is dropped by that rule, and the bare declaration then sits a
 * scope wider than anything reads it -- typically because the loop it feeds was once a
 * `while (true)` whose `break` carried a value out.
 *
 * ## Costs nothing at runtime
 *
 * Verified on the hxcpp backend: a declaration is transliterated 1:1 into the C++ scope it was
 * written in, so `int midPoint;` inside the loop body is the same stack slot the hoisted form
 * got -- no allocation, no constructor, no per-iteration work. The same holds for a reference
 * type: heap traffic comes from the INITIALIZER, which ran inside the loop in both spellings.
 *
 * ## What is flagged
 *
 * A direct child of a statement list that is BOTH a `blockKinds` and a `scopeKinds` node (so a
 * `CondBranch` of the branch-aware projection can never host a candidate) where:
 *
 * - the statement is a local declaration (`localDeclKinds`) with NO initializer (`children`
 *   empty) declaring exactly ONE variable -- a multi-declarator `var a, b;` is skipped, and an
 *   initialized declaration would have its evaluation moved, which is a different rewrite;
 * - it has at least one occurrence after itself (none at all is `unused-local`'s finding);
 * - EVERY occurrence lies inside ONE later sibling statement, and inside the innermost
 *   block-scope within it (`B`);
 * - the FIRST occurrence is the l-value of a plain `name = rhs;` (`assignKind`) that is a DIRECT
 *   statement of `B`, and no other occurrence sits in that statement.
 *
 * That last gate is what makes the sink SOUND when `B` is a loop body. Sinking gives every
 * iteration its own binding, so a value carried ACROSS iterations would be lost -- but a write
 * that is a direct statement of `B` cannot be skipped by anything that lets a later occurrence
 * run: the only way past it is a jump that leaves the iteration entirely (`continue` / `break` /
 * `return` / `throw`), and then nothing below it executes either. Every read the new binding sees
 * is therefore written in its own iteration, which is exactly the old behaviour. It also rules
 * out reading the name before it is written, which the compiler rejects outright once the
 * declaration is inside the loop.
 *
 * ## What is refused
 *
 * - A FUNCTION of any kind (`functionKinds` / `localFunctionKinds` / `inlineFunctionKinds` /
 *   `lambdaKinds`) between the statement list and `B`, or holding an occurrence: a closure
 *   captures ONE binding today and a fresh per-iteration binding after the sink, and a
 *   declaration moved inside a function body is re-created per call.
 * - A conditional-compilation region (`RefactorSupport.isConditionalKind`) on the same path: the
 *   declaration would exist only in the configurations that region compiles.
 * - A `Decl` occurrence -- `B` (or something in it) already binds the name, so the sink would
 *   redeclare it. A `for` iterator and a `catch` exception are `Decl`s too, which is what makes
 *   this one test cover all three.
 * - A textual occurrence of the name anywhere between the declaration and the end of its scope
 *   other than inside `B` (`RefactorSupport.referencedInRange`). `Refs` indexes ordinary
 *   identifier references and braceless `$name` interpolation; a macro-reification `$name`
 *   splice and anything inside `opaqueKinds` it does not, so the scan is the completeness net --
 *   it also counts comments and strings, which only ever costs a finding.
 * - A declaration that does not own its physical line, carries a leading comment block, or whose
 *   line holds a comment: the fix deletes that line whole.
 * - A target statement that does not start its own line: the fix inserts a line above it.
 *
 * ## No overlap with the siblings
 *
 * `join-declaration-assignment` needs the assignment to be the declaration's IMMEDIATE sibling in
 * the SAME statement list, which this rule's "every occurrence is inside a nested block" gate
 * refuses by construction; the two are disjoint and compose across fixed-point passes.
 * `prefer-local-function` claims the other bare-declaration shape (`var f; f = function …`) but
 * only when the assignment is reached without crossing a `scopeKinds` node -- `B` is one, so a
 * candidate here is never one there.
 *
 * ## Autofix
 *
 * `fix` emits two edits per finding: the declaration's whole line is deleted, and the declaration
 * text (keyword and `:type` verbatim) is re-inserted on its own line above the first-occurrence
 * statement, at that statement's indentation. Needs `localDeclKinds`, `exprStatementKind`,
 * `assignKind` and `controlFlowSupport` (any unset makes the check a no-op).
 */
@:nullSafety(Strict)
final class NarrowLocalScope implements Check {

	/** The rule id, reported on every finding and accepted by `--rule`. */
	private static inline final RULE_ID: String = 'narrow-local-scope';

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a bare local declaration whose every occurrence sits inside one nested block, sinkable into that block';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, resolved)) violations.push({
				file: entry.file,
				span: m.declSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'local \'${m.name}\' is used only inside a nested block; move its declaration there'
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
		final byKey: Map<String, Match> = [];
		for (m in collectMatches(tree, source, seams)) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<Match> = byKey['${span.from}:${span.to}'];
			if (m == null) continue;
			edits.push({ span: m.removeSpan, text: '' });
			edits.push({ span: new Span(m.insertAt, m.insertAt), text: '${m.indent}${m.declText};\n' });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		if (exprStmtKind == null || assignKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final scopeKinds: Array<String> = shape.scopeKinds;
		return {
			shape: shape,
			localDeclKinds: localDeclKinds,
			localDeclContinuationKinds: shape.localDeclContinuationKinds ?? [],
			exprStmtKind: exprStmtKind,
			assignKind: assignKind,
			identKind: shape.identKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			functionKinds: (
				shape.functionKinds ?? []
			).concat(shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []).concat(shape.lambdaKinds ?? []),
			// A candidate's host and its sink target must both be a REAL lexical scope, which is
			// what excludes the branch-aware projection's `CondBranch` -- a statement list that
			// binds nothing of its own.
			blockScopeKinds: support.blockKinds().filter(k -> scopeKinds.contains(k))
		};
	}

	/** Collect every sinkable declaration reachable under `node`, memoizing one `Refs` walk per distinct name. */
	private static function collectMatches(tree: QueryNode, source: String, s: Seams): Array<Match> {
		final out: Array<Match> = [];
		final hitsByName: Map<String, Array<RefHit>> = [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		walk(tree, tree, source, comments, s, hitsByName, out);
		return out;
	}

	/** Visit every statement list that is a real scope and consider each of its direct children. */
	private static function walk(
		node: QueryNode, tree: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		hitsByName: Map<String, Array<RefHit>>, out: Array<Match>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.blockScopeKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final m: Null<Match> = consider(node, kids, i, tree, source, comments, s, hitsByName);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) walk(c, tree, source, comments, s, hitsByName, out);
	}

	/**
	 * The sink match for `kids[i]` inside the statement list `host`, or null when any gate of the
	 * class doc closes on it.
	 */
	private static function consider(
		host: QueryNode, kids: Array<QueryNode>, i: Int, tree: QueryNode, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, hitsByName: Map<String, Array<RefHit>>
	): Null<Match> {
		final decl: QueryNode = kids[i];
		final declSpan: Null<Span> = bareSingleDeclaration(decl, source, s);
		final name: Null<String> = decl.name;
		final hostSpan: Null<Span> = host.span;
		if (declSpan == null || name == null || hostSpan == null) return null;

		if (!hitsByName.exists(name)) hitsByName[name] = Refs.find(name, tree, s.shape);
		final occurrences: Array<RefHit> = occurrencesAfter(hitsByName[name] ?? [], declSpan, hostSpan);
		// No occurrence at all is `unused-local`'s finding; a `Decl` among them means the target
		// block (or a construct in it) already binds the name, and the sink would redeclare it.
		if (occurrences.length == 0 || occurrences.exists(h -> h.kind == RefKind.Decl)) return null;

		final spans: Array<Span> = [for (h in occurrences) h.span];
		final carrier: Null<QueryNode> = laterSiblingHolding(kids, i, spans);
		if (carrier == null) return null;
		final block: Null<QueryNode> = innermostBlockScope(carrier, spans, s);
		if (block == null || occurrenceInNestedFunction(block, spans, s)) return null;
		final blockSpan: Null<Span> = block.span;
		final target: Null<QueryNode> = firstWriteStatement(block, name, spans[0], s);
		final targetSpan: Null<Span> = target?.span;
		if (blockSpan == null || targetSpan == null) return null;

		// A second occurrence in the first-write statement is the r-value reading the name it is
		// about to bind -- `join-declaration-assignment` refuses the joined form, so sinking buys
		// nothing, and the read is of an uninitialized local once the declaration is inside.
		if (spans.exists(sp -> sp.from > spans[0].from && sp.from < targetSpan.to)) return null;
		if (RefactorSupport.referencedInRange(source, name, declSpan.to, hostSpan.to, [blockSpan])) return null;
		if (!RefactorSupport.startsItsLine(source, targetSpan.from)) return null;
		final removeSpan: Null<Span> = deletableLine(source, declSpan, comments);
		return removeSpan == null ? null : {
			name: name,
			declSpan: declSpan,
			removeSpan: removeSpan,
			declText: source.substring(declSpan.from, declSpan.to - 1).rtrim(),
			insertAt: RefactorSupport.startOfLine(source, targetSpan.from),
			indent: RefactorSupport.lineIndentAt(source, targetSpan.from)
		};
	}

	/**
	 * The hits that can bind to this declaration: everything past its own span and inside its
	 * enclosing statement list. A Haxe local is position-scoped, so an earlier occurrence of the
	 * name belongs to some outer binding and stays bound to it after the sink.
	 *
	 * Attribution is by POSITION, not by the resolver's `bindingSpan` -- the same choice
	 * `prefer-final` records: a `case`-branch body opens no scope, so several same-named locals in
	 * sibling branches share one frame and the resolver can bind an occurrence to the wrong one.
	 * A position test over-collects instead, which can only widen the block a sink targets or
	 * refuse outright.
	 */
	private static function occurrencesAfter(hits: Array<RefHit>, declSpan: Span, hostSpan: Span): Array<RefHit> {
		return hits.filter(h -> h.span.from >= declSpan.to && h.span.from < hostSpan.to);
	}

	/** The one sibling AFTER `kids[i]` whose span holds every span in `spans`, or null when they straddle several. */
	private static function laterSiblingHolding(kids: Array<QueryNode>, i: Int, spans: Array<Span>): Null<QueryNode> {
		for (j in i + 1...kids.length) {
			final span: Null<Span> = kids[j].span;
			if (span != null && containsAll(span, spans)) return kids[j];
		}
		return null;
	}

	/**
	 * The innermost real block scope under `root` (inclusive) whose span holds every span in
	 * `spans`, or null when the descent crosses a function or a conditional-compilation region, or
	 * reaches no block at all (the occurrences sit in a construct's header, or in an unbraced body).
	 */
	private static function innermostBlockScope(root: QueryNode, spans: Array<Span>, s: Seams): Null<QueryNode> {
		var node: QueryNode = root;
		var best: Null<QueryNode> = null;
		while (true) {
			if (s.functionKinds.contains(node.kind) || RefactorSupport.isConditionalKind(node.kind)) return null;
			if (s.blockScopeKinds.contains(node.kind)) best = node;
			var next: Null<QueryNode> = null;
			for (c in node.children) {
				final span: Null<Span> = c.span;
				if (span == null || !containsAll(span, spans)) continue;
				next = c;
				break;
			}
			if (next == null) return best;
			node = next;
		}
	}

	/**
	 * The direct statement of `block` that spells `first` as the l-value of a plain `=` to `name`,
	 * or null when the first occurrence is anything else -- the gate that keeps the sink sound
	 * inside a loop (see the class doc).
	 */
	private static function firstWriteStatement(block: QueryNode, name: String, first: Span, s: Seams): Null<QueryNode> {
		for (stmt in block.children) {
			final span: Null<Span> = stmt.span;
			if (span == null || first.from < span.from || first.to > span.to) continue;
			if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
			final binary: QueryNode = stmt.children[0];
			if (binary.kind != s.assignKind || binary.children.length != ASSIGN_CHILD_COUNT) return null;
			final lhs: QueryNode = binary.children[0];
			final lhsSpan: Null<Span> = lhs.span;
			return if (lhs.kind != s.identKind || lhs.name != name || lhsSpan == null)
				null
			else if (lhsSpan.from == first.from && lhsSpan.to == first.to)
				stmt
			else
				null;
		}
		return null;
	}

	/** Whether `span` holds every span in `spans`. */
	private static function containsAll(span: Span, spans: Array<Span>): Bool {
		return spans.foreach(sp -> sp.from >= span.from && sp.to <= span.to);
	}


	/**
	 * Whether any span in `spans` sits inside a function nested under `node`.
	 *
	 * The descent gate in `innermostBlockScope` only sees functions on the path to the block, and a
	 * closure that holds SOME of the occurrences is never on it -- the block above it is the innermost
	 * node containing them all. Today that closure captures one binding; after the sink it captures a
	 * fresh one per iteration, so it has to be refused here.
	 */
	private static function occurrenceInNestedFunction(node: QueryNode, spans: Array<Span>, s: Seams): Bool {
		for (c in node.children) {
			final span: Null<Span> = c.span;
			if (s.functionKinds.contains(c.kind) && span != null && spans.exists(sp -> sp.from >= span.from && sp.to <= span.to))
				return true;
			if (occurrenceInNestedFunction(c, spans, s)) return true;
		}
		return false;
	}


	/**
	 * `decl`'s span when it is a BARE single-variable local declaration, else null.
	 *
	 * An initializer would have its evaluation moved by the sink, which is a different rewrite; a
	 * multi-declarator `var a, b;` projects as one node and must never be moved as a whole. The
	 * trailing-`;` test is what the fix's `declText` slice relies on.
	 */
	private static function bareSingleDeclaration(decl: QueryNode, source: String, s: Seams): Null<Span> {
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != 0 || decl.name == null) return null;
		final span: Null<Span> = decl.span;
		return if (span == null || span.to <= span.from || source.charAt(span.to - 1) != ';')
			null
		else if (RefactorSupport.isMultiDeclarator(decl, s.localDeclContinuationKinds))
			null
		else
			span;
	}


	/**
	 * The whole physical line the fix deletes, or null when the declaration does not own one.
	 *
	 * The move takes the declaration's line out entirely, so a statement sharing that line would go
	 * with it, a comment on it would be lost, and a leading comment block would be left behind
	 * documenting whatever follows.
	 */
	private static function deletableLine(
		source: String, declSpan: Span, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Null<Span> {
		final line: Span = RefactorSupport.lineExtendedSpan(source, declSpan);
		return if (line.from == declSpan.from && line.to == declSpan.to)
			null
		else if (RefactorSupport.leadingCommentBlockStart(source, comments, declSpan.from) != line.from)
			null
		else if (comments.exists(t -> t.from < line.to && t.to > line.from))
			null
		else
			line;
	}

}

/** The kinds `NarrowLocalScope` reads, plus the `RefShape` the `Refs` walk needs. */
private typedef Seams = {
	var shape: RefShape;
	var localDeclKinds: Array<String>;
	var localDeclContinuationKinds: Array<String>;
	var exprStmtKind: String;
	var assignKind: String;
	var identKind: String;
	var opaqueKinds: Array<String>;
	var functionKinds: Array<String>;
	var blockScopeKinds: Array<String>;
}

/** A sinkable declaration: the finding key, the line the fix deletes, and where its text lands. */
private typedef Match = {
	var name: String;
	var declSpan: Span;
	var removeSpan: Span;
	var declText: String;
	var insertAt: Int;
	var indent: String;
}
