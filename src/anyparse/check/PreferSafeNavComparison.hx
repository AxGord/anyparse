package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a null-check conjunction that a safe-navigation comparison replaces —
 * `x != null && x.b != null` collapses to `x?.b != null`, and its `||` dual
 * `x == null || x.b == null` to `x?.b == null`. `Severity.Info` (a modernization
 * cleanup), with an autofix.
 *
 * A RUN of any length collapses in one step (`x != null && x.b != null && x.b.c != null`
 * becomes `x?.b?.c != null`), and a step may span several accesses — the multi-access
 * extension `x != null && x.b.c != null` becomes `x?.b.c != null`, equivalent because
 * both forms dereference `x.b` only once `x` is known non-null. Conjuncts around a run
 * are kept verbatim (`ok && x != null && x.b != null` becomes `ok && x?.b != null`), and
 * one chain may hold several disjoint runs, each rewritten on its own.
 *
 * ## Soundness — evaluation count, a plain-`.` junction, and narrowing
 *
 * Every operand except the LAST conjunct's is evaluated twice before the rewrite and
 * once after, so an operand whose subtree mutates a binding — a call (`callKind`), a
 * construction (`newExprKind`) or an assignment / increment (`writeParentKinds`) — ends
 * the run there: `x.b() != null && x.b().c != null` is left alone. The last conjunct's
 * operand is untouched by the rewrite (its text survives verbatim), so a call in ITS
 * tail is fine — `x != null && x.b() != null` becomes `x?.b() != null`, one call either
 * way.
 *
 * That gate is SYNTACTIC, and deliberately so: it sees an explicit call or `new`, not an
 * implicit accessor. A FIELD receiver — bare, `this.`-qualified or on any object — is
 * flaggable, and if it is backed by a property getter (or an `@:arrayAccess` forward)
 * the rewrite drops one of its two invocations. A getter with an observable side effect
 * or a non-idempotent result would therefore change behaviour. This is the same policy
 * `prefer-null-coalescing` ships (its guarded value is collapsed 2 to 1 under the
 * identical syntactic gate, shared as `CheckScan.mutationKinds`); the motivating
 * real-world sites are plain `final` fields, where the double read is provably free. A
 * local / param-only receiver gate — what `prefer-safe-nav` uses — is intentionally NOT
 * applied here, since it would miss every field-guard site the rule exists for.
 *
 * The junction between two conjuncts must be a plain field access (`fieldAccessKind`):
 * safe navigation has no index or call form, so `x != null && x[0] != null` and a
 * junction that is already `?.` (`nullSafeAccessKind`) are not flagged. A conjunct pair
 * whose later operand does not carry the earlier one as a receiver prefix (`x != null &&
 * y.b != null`) links nothing, and an AND chain accepts only `!=` conjuncts while an OR
 * chain accepts only `==` ones — a mixed pair is not the same predicate. Linking is
 * purely textual, so a chain that switches qualification style mid-way
 * (`this.fld != null && fld.b != null`) simply does not match — a safe miss.
 *
 * A conjunction NARROWS its operand under `@:nullSafety(Strict)`, and the rewrite gives
 * that up: `if (a == null || a.b == null) return; a.b.c();` must NOT become
 * `if (a?.b == null) return; a.b.c();`, whose trailing statement no longer typechecks.
 * So a run is dropped when the FIRST operand is mentioned anywhere AFTER it within the
 * scan scope `scanRoots` resolves: the enclosing statement's whole subtree, plus the
 * following siblings at EVERY enclosing statement block, up to the nearest narrowing
 * BOUNDARY (a function body, a function, a lambda). Plain blocks are ascended through at
 * any depth, since an early exit inside one narrows what follows the block. That covers
 * every conjunct after the run, the guarded branch, and the statements an early exit
 * protects. Only forward mentions matter: narrowing flows forward, so a mention that
 * lexically precedes the run cannot rely on it (which is also why a lambda's own
 * parameter, projected as a plain identifier ahead of its body, is not a mention).
 * Scanning the FIRST operand suffices — it is a receiver prefix of every other operand,
 * so any later use of those contains it — and the comparison normalises the
 * self-qualifier (`selfReferenceText`), so `this.fld` and a bare `fld` match each other
 * in BOTH directions.
 *
 * That scan is bounded by the enclosing function — which is exactly why an `inline`
 * function must be excluded wholesale. Its body is spliced into every CALL SITE, so a
 * boolean guard written in the `&&` form narrows the CALLER's binding:
 *
 *     inline function check(item: Null<D>): Bool return item != null && item.id != null;
 *     if (!check(item)) return;
 *     use(item.id);            // typechecks ONLY because check() inlined the && form
 *
 * Rewriting that body to `item?.id != null` removes the narrowing at every call site,
 * and those callers are unreachable from any single-function scan. So a run whose
 * enclosing function carries `inline` (`inlineModifierKind` on a `functionKinds` host,
 * or an `inlineFunctionKinds` node — Haxe's local `inline function`) is dropped. The
 * gate is BLANKET rather than parameter-only: an inlined body guarding a FIELD chain
 * narrows the caller's view of that chain just the same. Lambdas are exempt — one cannot
 * be `inline` in Haxe, and a lambda body is a closure VALUE, never a predicate in the
 * enclosing function's callers, so a run inside a lambda nested in an `inline` function
 * still fires.
 *
 * One blind spot is benign: a simple `'$x'` string interpolation projects as
 * `stringInterpIdentKind`, not `identKind`, so the scan does not see it. Plain
 * interpolation only stringifies and never needs narrowing; a block interpolation
 * (`${x.b.c}`) parses into a real expression tree and IS seen.
 *
 * Finally, the text between the first conjunct and the last is DROPPED by the fix, so a
 * line- or block-comment opener in it leaves the run unflagged; a comment INSIDE the
 * last conjunct survives (that conjunct's text is reused verbatim).
 *
 * ## Autofix
 *
 * The whole run is replaced by the LAST conjunct's source text with a `?` inserted before
 * each junction dot — `x != null && x.b != null && x.b.c != null` keeps only
 * `x.b.c != null` and turns both dots into `?.`. `!=` / `==` bind tighter than `&&` / `||`,
 * so the replacement never needs parentheses. Each junction dot is located as the first
 * `.` after its receiver's span, which two shapes can defeat: interior whitespace between
 * the conjuncts can put that dot outside the last conjunct, and a comment sitting between
 * a receiver and its dot would swallow the inserted `?`. Either one skips the whole edit —
 * a sound no-op rather than a mangled rewrite — leaving the run reported but unfixed.
 *
 * A run covers its conjuncts, so a chain nested inside one is not descended into; it is
 * caught on the next `--fix` pass (which iterates to a fixed point), the same
 * outermost-first policy `prefer-null-coalescing` uses. A run REJECTED by a gate covers
 * nothing, and the scan resumes one conjunct later, so a shorter sub-run inside it still
 * gets its chance.
 *
 * ## Grammar-agnostic
 *
 * Driven by `logicalAndKind`, `logicalOrKind`, `eqKind`, `notEqKind`, `nullLiteralKind`,
 * `fieldAccessKind` and `blockStmtKind` (any unset → no-op), plus the always-present
 * `identKind` / `writeParentKinds`, the optional `blockBodyKind` (a function body is a
 * statement block AND a narrowing boundary), `functionKinds` / `lambdaKinds` /
 * `inlineFunctionKinds` (the other narrowing boundaries, and the inline-splice gate),
 * `inlineModifierKind` with `modifierOrderKinds` / `visibilityModifierKinds` (reading a
 * function's modifier run), `callKind` / `newExprKind` (the mutation guard, via
 * `CheckScan.mutationKinds`), `selfReferenceText` (self-qualifier normalisation on the
 * narrowing scan), `parenKind` (unwrapping a parenthesized conjunct) and `opaqueKinds`
 * (reification subtrees, skipped on the walk and treated as a possible mention on the
 * narrowing scan).
 */
@:nullSafety(Strict)
final class PreferSafeNavComparison implements Check {

	/** A binary node — a comparison or a logical operator — has exactly [left, right] children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** A run needs at least two conjuncts — one null-check alone is not a chain. */
	private static inline final MIN_RUN_LENGTH: Int = 2;

	/** This check's `id()`, also stamped on every violation and read back by `fix` to select its own findings. */
	private static inline final RULE_ID: String = 'prefer-safe-nav-comparison';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a null-check conjunction (x != null && x.f != null) replaceable with a safe-navigation comparison (x?.f != null)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final s: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (r in collectRuns(tree, entry.source, s)) violations.push({
				file: entry.file,
				span: new Span(r.from, r.to),
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this null-check chain can be safe navigation (?.)'
			});
		}
		return violations;
	}

	/** Replace each flagged run with the last conjunct's text, its junction dots turned into `?.`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final s: Seams = seams;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null && v.rule == RULE_ID) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (r in collectRuns(tree, source, s)) if (wanted.contains('${r.from}:${r.to}')) {
			final edit: Null<{ span: Span, text: String }> = rewrite(r, source);
			if (edit != null) edits.push(edit);
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final andKind: Null<String> = shape.logicalAndKind;
		if (andKind == null) return null;
		final orKind: Null<String> = shape.logicalOrKind;
		if (orKind == null) return null;
		final eqKind: Null<String> = shape.eqKind;
		if (eqKind == null) return null;
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return null;
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final blockKinds: Array<String> = [blockStmtKind];
		final blockBodyKind: Null<String> = shape.blockBodyKind;
		if (blockBodyKind != null) blockKinds.push(blockBodyKind);
		return {
			andKind: andKind,
			orKind: orKind,
			eqKind: eqKind,
			notEqKind: notEqKind,
			nullKind: nullKind,
			identKind: shape.identKind,
			fieldAccessKind: fieldAccessKind,
			blockKinds: blockKinds,
			boundaryKinds: boundaryKinds(shape),
			functionKinds: shape.functionKinds ?? [],
			lambdaKinds: shape.lambdaKinds ?? [],
			inlineFnKinds: shape.inlineFunctionKinds ?? [],
			modifierKinds: (shape.modifierOrderKinds ?? []).concat(shape.visibilityModifierKinds ?? []),
			inlineKind: shape.inlineModifierKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			unsafeKinds: CheckScan.mutationKinds(shape),
			selfText: shape.selfReferenceText,
			parenKind: shape.parenKind
		};
	}

	/** Every collapsible run in `tree`, in document order — the ONE matcher `run` and `fix` share. */
	private static function collectRuns(tree: QueryNode, source: String, s: Seams): Array<NullRun> {
		final out: Array<NullRun> = [];
		walk(tree, [], null, source, s, out);
		return out;
	}

	/**
	 * Walk `node` with `stack` holding its ancestors, emitting the runs of every chain
	 * HEAD — an `&&` / `||` node whose walk-parent is not the same operator, so the whole
	 * left-associative spine is flattened once. Conjuncts a run covers are NOT descended
	 * into (a nested chain there is caught on the next `--fix` pass); every other child is.
	 * A reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(
		node: QueryNode, stack: Array<QueryNode>, parentKind: Null<String>, source: String, s: Seams, out: Array<NullRun>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if ((node.kind == s.andKind || node.kind == s.orKind) && parentKind != node.kind) {
			final conjuncts: Array<QueryNode> = flatten(node);
			if (conjuncts.length >= MIN_RUN_LENGTH) {
				final covered: Array<Bool> = emitRuns(conjuncts, node.kind, stack, source, s, out);
				stack.push(node);
				for (i => c in conjuncts) if (!covered[i]) walk(c, stack, node.kind, source, s, out);
				stack.pop();
				return;
			}
		}
		stack.push(node);
		for (c in node.children) walk(c, stack, node.kind, source, s, out);
		stack.pop();
	}

	/**
	 * The conjuncts of the left-associative binary chain rooted at `node`, in SOURCE
	 * order: each level's right child, plus the leftmost non-chain leaf. A parenthesized
	 * sub-chain is a `parenKind` node here and stays one conjunct — the walk reaches its
	 * own head separately.
	 */
	private static function flatten(node: QueryNode): Array<QueryNode> {
		final conjuncts: Array<QueryNode> = [];
		var n: QueryNode = node;
		while (n.kind == node.kind && n.children.length == BINARY_CHILD_COUNT) {
			conjuncts.push(n.children[1]);
			n = n.children[0];
		}
		conjuncts.push(n);
		conjuncts.reverse();
		return conjuncts;
	}

	/**
	 * Scan `conjuncts` left to right for maximal runs of linked null checks, pushing each
	 * one that passes the comment and narrowing gates, and return the per-conjunct flags
	 * telling which ones a pushed run covers. A failed pair ends the current run; the next
	 * run starts after it.
	 */
	private static function emitRuns(
		conjuncts: Array<QueryNode>, chainKind: String, stack: Array<QueryNode>, source: String, s: Seams, out: Array<NullRun>
	): Array<Bool> {
		final covered: Array<Bool> = [for (i in 0...conjuncts.length) false];
		if (inInlineFunction(stack, s)) return covered;
		final compKind: String = chainKind == s.andKind ? s.notEqKind : s.eqKind;
		final operands: Array<Null<QueryNode>> = [for (c in conjuncts) nullCompOperand(c, compKind, s)];
		var i: Int = 0;
		while (i < conjuncts.length - 1) {
			var k: Int = i;
			while (k + 1 < conjuncts.length && links(operands[k], operands[k + 1], source, s)) k++;
			if (k == i) {
				i++;
				continue;
			}
			final r: Null<NullRun> = build(conjuncts, operands, i, k, stack, source, s);
			if (r == null) {
				// A gate rejected the greedy run, so nothing is covered — resume at the NEXT
				// conjunct rather than past the run: a shorter sub-run inside it may still pass.
				i++;
				continue;
			}
			out.push(r);
			for (j in i ... k + 1) covered[j] = true;
			i = k + 1;
		}
		return covered;
	}

	/**
	 * The non-null operand of a `E <op> null` / `null <op> E` conjunct (`op` being the
	 * chain's own comparison — `!=` for `&&`, `==` for `||`), or null when `conjunct` is
	 * any other shape. Parentheses around the comparison are unwrapped.
	 */
	private static function nullCompOperand(conjunct: QueryNode, compKind: String, s: Seams): Null<QueryNode> {
		final c: QueryNode = RefactorSupport.unwrapParens(conjunct, s.parenKind);
		if (c.kind != compKind || c.children.length != BINARY_CHILD_COUNT) return null;
		final a: QueryNode = c.children[0];
		final b: QueryNode = c.children[1];
		return if (a.kind == s.nullKind && b.kind != s.nullKind)
			b;
		else if (b.kind == s.nullKind && a.kind != s.nullKind)
			a;
		else
			null;
	}

	/**
	 * Whether `later` continues `earlier`'s null check: both are real operands, `earlier`
	 * mutates nothing (it loses one of its two evaluations), and `later` reaches it through
	 * a plain-`.` junction.
	 */
	private static function links(earlier: Null<QueryNode>, later: Null<QueryNode>, source: String, s: Seams): Bool {
		if (earlier == null || later == null) return false;
		final e: QueryNode = earlier;
		if (s.unsafeKinds.exists(k -> RefactorSupport.subtreeContainsKind(e, k))) return false;
		final j: Null<QueryNode> = junction(later, e, source);
		return j != null && j.kind == s.fieldAccessKind;
	}

	/** The node in `later`'s receiver-descent chain that holds a receiver with `earlier`'s source, or null when there is none. */
	private static function junction(later: QueryNode, earlier: QueryNode, source: String): Null<QueryNode> {
		var n: QueryNode = later;
		while (n.children.length > 0) {
			final recv: QueryNode = n.children[0];
			if (RefactorSupport.sameSource(recv, earlier, source)) return n;
			n = recv;
		}
		return null;
	}

	/** The run over `conjuncts[i...k]`, or null when the dropped text holds a comment or the narrowing scan finds a later mention. */
	private static function build(
		conjuncts: Array<QueryNode>, operands: Array<Null<QueryNode>>, i: Int, k: Int, stack: Array<QueryNode>, source: String, s: Seams
	): Null<NullRun> {
		final firstSpan: Null<Span> = conjuncts[i].span;
		final lastSpan: Null<Span> = conjuncts[k].span;
		if (firstSpan == null || lastSpan == null) return null;
		if (CheckScan.hasCommentMarker(source, firstSpan.from, lastSpan.from)) return null;
		final ops: Array<QueryNode> = [];
		for (j in i ... k + 1) {
			final o: Null<QueryNode> = operands[j];
			if (o == null) return null;
			ops.push(o);
		}
		return mentionedAfter(stack, ops[0], lastSpan.to, source, s) ? null : {
			from: firstSpan.from,
			to: lastSpan.to,
			lastFrom: lastSpan.from,
			operands: ops
		};
	}


	/** Whether `first` is referenced anywhere at or after `runTo` inside the narrowing scan scope (see the type doc). */
	private static function mentionedAfter(stack: Array<QueryNode>, first: QueryNode, runTo: Int, source: String, s: Seams): Bool {
		return scanRoots(stack, s).exists(r -> mentions(r, runTo, first, source, s));
	}

	/**
	 * The subtrees the narrowing scan covers. The ancestor stack is walked outward; at every
	 * enclosing statement-block boundary (`blockKinds`) the enclosing statement AND its
	 * following siblings in that block are collected, and the walk stops only at a narrowing
	 * BOUNDARY (`boundaryKinds` — the function body, a function or a lambda). A plain block
	 * never stops it: `{ { if (x == null || x.b == null) return; } }` narrows the statements
	 * after the outermost block, at any nesting depth. A statement's own subtree already
	 * covers everything lexically inside it after the run (a block EXPRESSION included), so
	 * the sibling collection only has to reach BEYOND the statement. When the walk reaches a
	 * boundary having collected nothing, that boundary's subtree is the sole root; when it
	 * runs off the top (no boundary at all — a field initializer, or a grammar exposing no
	 * function seams), the whole file is scanned.
	 */
	private static function scanRoots(stack: Array<QueryNode>, s: Seams): Array<QueryNode> {
		final roots: Array<QueryNode> = [];
		var i: Int = stack.length - 1;
		while (i >= 0) {
			final a: QueryNode = stack[i];
			if (i > 0 && s.blockKinds.contains(stack[i - 1].kind)) {
				final block: QueryNode = stack[i - 1];
				final at: Int = block.children.indexOf(a);
				for (r in (at < 0 ? [block] : block.children.slice(at))) roots.push(r);
			}
			if (s.boundaryKinds.contains(a.kind)) {
				if (roots.length == 0) roots.push(a);
				return roots;
			}
			i--;
		}
		if (roots.length == 0 && stack.length > 0) roots.push(stack[0]);
		return roots;
	}

	/**
	 * Whether `node`'s subtree holds a reference to `first` starting at or after `runTo`.
	 * A plain identifier is matched by name, any other operand (a field access such as
	 * `this.fld`) by source text. A subtree that ends before `runTo` is pruned; an opaque
	 * reification subtree counts as a possible mention.
	 */
	private static function mentions(node: QueryNode, runTo: Int, first: QueryNode, source: String, s: Seams): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.to <= runTo) return false;
		if (s.opaqueKinds.contains(node.kind)) return true;
		if (span != null && span.from >= runTo && references(node, first, source, s)) return true;
		return node.children.exists(c -> mentions(c, runTo, first, source, s));
	}

	/** Whether `node` refers to the run's first operand, compared through the self-qualifier-normalised key. */
	private static function references(node: QueryNode, first: QueryNode, source: String, s: Seams): Bool {
		final a: Null<String> = referenceKey(node, source, s);
		final b: Null<String> = referenceKey(first, source, s);
		return a != null && b != null && a == b;
	}

	/**
	 * `node`'s comparable reference text: a plain identifier's name, else its source with
	 * a leading self-qualifier (`this.`) stripped — so `this.fld` and a bare `fld` compare
	 * equal in both directions, which the narrowing scan needs (the two styles denote the
	 * same member, and a mention in either one relies on the same narrowing).
	 */
	private static function referenceKey(node: QueryNode, source: String, s: Seams): Null<String> {
		if (node.kind == s.identKind) return node.name;
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final text: String = StringTools.trim(source.substring(span.from, span.to));
		final self: Null<String> = s.selfText;
		if (self == null) return text;
		final prefix: String = '$self.';
		return StringTools.startsWith(text, prefix) ? StringTools.trim(text.substr(prefix.length)) : text;
	}

	/**
	 * The edit collapsing `r`: the last conjunct's source text with a `?` inserted before
	 * every junction dot, replacing the whole run. Null when a junction dot cannot be
	 * located inside the last conjunct (whitespace drift between the conjuncts) — the run
	 * is then reported but not fixed.
	 */
	private static function rewrite(r: NullRun, source: String): Null<{ span: Span, text: String }> {
		final chain: Array<QueryNode> = descentChain(r.operands[r.operands.length - 1]);
		final dots: Array<Int> = [];
		for (j in 0...r.operands.length - 1) {
			final target: QueryNode = r.operands[j];
			final recv: Null<QueryNode> = chain.find(n -> RefactorSupport.sameSource(n, target, source));
			if (recv == null) return null;
			final recvSpan: Null<Span> = recv.span;
			if (recvSpan == null) return null;
			final dot: Int = source.indexOf('.', recvSpan.to);
			if (dot < r.lastFrom || dot >= r.to) return null;
			// A comment between the receiver and its dot would swallow the inserted `?`.
			if (CheckScan.hasCommentMarker(source, recvSpan.to, dot)) return null;
			dots.push(dot);
		}
		dots.sort((a, b) -> b - a);
		var text: String = source.substring(r.lastFrom, r.to);
		for (d in dots) text = '${text.substring(0, d - r.lastFrom)}?${text.substring(d - r.lastFrom)}';
		return { span: new Span(r.from, r.to), text: text };
	}

	/** `node` followed by its receiver descent — `children[0]` repeatedly, the slot every field access / call / index carries its receiver in. */
	private static function descentChain(node: QueryNode): Array<QueryNode> {
		final chain: Array<QueryNode> = [node];
		var n: QueryNode = node;
		while (n.children.length > 0) {
			n = n.children[0];
			chain.push(n);
		}
		return chain;
	}


	/**
	 * The kinds that BOUND null-safety narrowing, ending the scan-scope ascent: the
	 * function-body kind plus every function and lambda node. Deliberately NOT every
	 * `scopeKinds` entry — a plain block (and a block EXPRESSION) opens a lexical scope
	 * but does not stop flow, so an early exit inside one narrows the statements that
	 * FOLLOW the block and the ascent has to reach them. Anything else (a loop, a catch
	 * clause, a type declaration) is simply ascended through: the resulting scan is wider
	 * than strictly needed, which can only cost a safe miss. Unset seams leave the set
	 * empty, so the ascent runs to the root and the whole-file fallback applies.
	 */
	private static function boundaryKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final blockBodyKind: Null<String> = shape.blockBodyKind;
		if (blockBodyKind != null) kinds.push(blockBodyKind);
		return kinds;
	}

	/**
	 * Whether the run sits in the body of an `inline` function, whose text is spliced into
	 * every CALL SITE — where a boolean `&&` / `||` null-check becomes a narrowing
	 * predicate the callers rely on (see the type doc). The ancestor walk stops at the
	 * first lambda: a lambda body is a closure VALUE, never a predicate in the enclosing
	 * function's callers, so a run inside one is unaffected by an outer `inline`.
	 */
	private static function inInlineFunction(stack: Array<QueryNode>, s: Seams): Bool {
		var i: Int = stack.length - 1;
		while (i >= 0) {
			final a: QueryNode = stack[i];
			if (s.lambdaKinds.contains(a.kind)) return false;
			if (s.inlineFnKinds.contains(a.kind)) return true;
			if (s.functionKinds.contains(a.kind) && hasInlineModifier(a, i > 0 ? stack[i - 1] : null, s)) return true;
			i--;
		}
		return false;
	}

	/**
	 * Whether `fn`'s modifier run carries the `inline` keyword. Modifiers project as
	 * SIBLING nodes preceding the function host, so the scan walks `parent`'s children
	 * backwards from `fn` for as long as they are modifiers.
	 */
	private static function hasInlineModifier(fn: QueryNode, parent: Null<QueryNode>, s: Seams): Bool {
		final inlineKind: Null<String> = s.inlineKind;
		if (inlineKind == null || parent == null) return false;
		var i: Int = parent.children.indexOf(fn) - 1;
		while (i >= 0 && s.modifierKinds.contains(parent.children[i].kind)) {
			if (parent.children[i].kind == inlineKind) return true;
			i--;
		}
		return false;
	}

}

/** The `RefShape` kinds `PreferSafeNavComparison` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	final andKind: String;
	final orKind: String;
	final eqKind: String;
	final notEqKind: String;
	final nullKind: String;
	final identKind: String;
	final fieldAccessKind: String;
	final blockKinds: Array<String>;
	final boundaryKinds: Array<String>;
	final functionKinds: Array<String>;
	final lambdaKinds: Array<String>;
	final inlineFnKinds: Array<String>;
	final modifierKinds: Array<String>;
	final inlineKind: Null<String>;
	final opaqueKinds: Array<String>;
	final unsafeKinds: Array<String>;
	final selfText: Null<String>;
	final parenKind: Null<String>;
};

/**
 * One collapsible run: the source range it spans (`from` … `to`), where its LAST conjunct
 * starts (`lastFrom` — the only text the fix keeps), and the null-checked operands in
 * source order, the first of which drives the narrowing scan.
 */
private typedef NullRun = {
	final from: Int;
	final to: Int;
	final lastFrom: Int;
	final operands: Array<QueryNode>;
};
