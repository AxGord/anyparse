package anyparse.check;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.Violation;
import anyparse.check.UsingScan.UsingHeader;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The shape engine behind the twin checks `prefer-exists` and `prefer-foreach`: a `for` loop
 * whose whole body is one `if` returning a boolean LITERAL, immediately followed by a `return`
 * of the OPPOSITE literal — the hand-written spelling of `Lambda.exists` / `Lambda.foreach`.
 *
 * ## The two directions, and why one engine
 *
 * - `for (x in xs) if (c) return true;` + `return false;` -> `xs.exists(x -> c)`
 * - `for (x in xs) if (c) return false;` + `return true;` -> `xs.foreach(x -> !(c))`
 *
 * They are the same shape read in opposite polarity, so one recovery pass parameterised by
 * `BoolLoopKind` serves both; the two `Check` faces differ only in their id, their method name
 * and how they treat the condition. The directions can never both claim one site: the loop's
 * literal decides, and it is `true` for exactly one of them.
 *
 * ## The guarded form (`exists` only)
 *
 * More than half the real sites measured over a ~800-file application put the loop under a
 * guard — `if (xs != null) for (x in xs) if (c) return true;` + `return false;` — which reads
 * as `return xs != null && xs.exists(x -> c);`. The guard is evaluated exactly once either way
 * and `&&` narrows from ANY position, so the merge is sound and is claimed.
 *
 * The mirror (`if (g) for … return false;` + `return true;`) is deliberately NOT claimed. It
 * needs `!g`, and a guard is typically a null test: `!(xs != null)` narrows nothing, and Haxe's
 * strict null-safety only narrows an `||` chain from its FIRST operand. Rather than gate on the
 * guard's shape for a form no measured site uses, the engine refuses the whole variant.
 *
 * ## Soundness gates
 *
 * - The loop body is a single `if` with NO `else`, whose then-branch is exactly
 *   `return <bool literal>` (bare, or a `{ … }` wrapping only that). The loop body itself may be
 *   a single-statement block, and so may a guard's body.
 * - The fallback is `return <the opposite bool literal>`. A non-literal fallback
 *   (`return xs.length == 0;`) or a REPEAT of the same literal is refused — neither is the
 *   `exists` / `foreach` identity.
 * - That fallback is usually the loop's immediate sibling, and then the rewrite subsumes it. It
 *   may also be reached by FALLING OUT of enclosing `if` branches — a third of the real sites put
 *   the loop at the tail of an `else` block whose function ends `return false;` — and then only
 *   the loop is replaced, because the other branches still run into that return. The successor is
 *   propagated by `scan` and is dropped at every construct where falling off the end does not
 *   continue after it (a loop body, a `switch`, a `try`, a conditional-compilation region).
 * - No key-value loop (`Lambda` iterates values, not pairs), no range `a...b` and no call
 *   iterable (`m.keys()` yields an `Iterator`, which is not `Iterable`) — the same three
 *   refusals `prefer-find` makes, for the same reasons.
 * - The binder cannot leak: the loop's entire body is the `if` and a literal return, so `x`
 *   occurs only inside the condition by construction. No separate gate is needed, and none is
 *   written — a gate that cannot fail is a gate nothing can test.
 * - The `foreach` inversion is a WRAP, `!(…)`, never De Morgan — pushing `!` through an `&&`
 *   chain reorders the operands a null narrowing depends on. The one exception costs nothing:
 *   a condition that is ALREADY a `!` drops it instead of gaining a second.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `returnStatementKind`, `blockStmtKind`, `boolLitKind`,
 * `ifStatementKinds` and `ControlFlowSupport.blockKinds` (any unset -> the check is a no-op),
 * with `opaqueKinds` skipping reification subtrees and `notKind` enabling the double-negation
 * relief. The boolean literal's VALUE is read from its source text (`true` / `false`); a
 * grammar spelling it otherwise yields neither value and the site is skipped rather than
 * misread.
 */
@:nullSafety(Strict)
final class BoolLoopScan {

	/** A `for` node has exactly [iterable, body] operands once the key-value binder is filtered out. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** Cap on an excerpt's length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	/** The module whose `exists` / `foreach` the rewrite calls — the `using` the fix inserts when the file lacks it. */
	private static inline final LAMBDA_MODULE: String = 'Lambda';

	/** The atomic group binding an INSERTED `using Lambda;` to every call that needs it (see `edits`). */
	private static inline final USING_GROUP: Int = 0;

	/** The boolean literal's source text for `true` — the engine reads the VALUE off the span. */
	private static inline final TRUE_LITERAL: String = 'true';

	/** The boolean literal's source text for `false`; any other text makes the literal unreadable and the site skipped. */
	private static inline final FALSE_LITERAL: String = 'false';

	/** The extension method `kind` rewrites to — the name a second `using` must be proven not to supply. */
	public static inline function method(kind: BoolLoopKind): String {
		return kind == BoolLoopKind.Exists ? 'exists' : 'foreach';
	}

	/** Every bool-returning loop of `kind` in `files`, as `Severity.Info` findings carrying `ruleId`. */
	public static function findings(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, kind: BoolLoopKind, ruleId: String
	): Array<Violation> {
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final source: String = entry.source;
			final file: String = entry.file;
			scan(tree, null, source, s, kind, cand -> {
				final v: Null<Violation> = buildViolation(cand, source, s, kind, ruleId, file);
				if (v != null) out.push(v);
			});
		}
		return out;
	}

	/**
	 * The span edits rewriting each recovered loop in `source` to `xs.exists(…)` / `xs.foreach(…)`,
	 * plus a `using Lambda;` when the file lacks one and anything was rewritten — the whole set
	 * atomic in that case, independently revertible otherwise (see the grouping note below).
	 *
	 * The emitted call must reach `Lambda`'s member: Haxe resolves static extensions in REVERSE
	 * declaration order and an inserted `using` goes ABOVE any existing run, so a second `using`
	 * that could also supply the name would win the new call — the whole file is refused rather
	 * than silently retargeted. A loop whose replaced region holds a comment outside the three
	 * re-spliced sub-expressions stays a report-only finding: that comment has nowhere to go.
	 */
	public static function edits(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, index: Null<SymbolIndex>, kind: BoolLoopKind
	): Array<GroupedEdit> {
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final symbols: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final header: UsingHeader = UsingScan.headerOf(tree, source, plugin);
		if (UsingScan.conflictingUsing(UsingScan.usingModules(header), LAMBDA_MODULE, method(kind), plugin, () -> symbols, [])) return [];
		final byKey: Map<String, Cand> = [];
		scan(tree, null, source, s, kind, cand -> {
			final span: Null<Span> = cand.anchor.span;
			if (span != null) byKey['${span.from}:${span.to}'] = cand;
		});
		final rewrites: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final cand: Null<Cand> = byKey['${span.from}:${span.to}'];
			if (cand == null) continue;
			final edit: Null<{ span: Span, text: String }> = buildEdit(cand, source, s, kind);
			if (edit == null || RefactorSupport.editsOverlapAny([edit], rewrites)) continue;
			rewrites.push(edit);
		}
		if (rewrites.length == 0) return [];
		if (UsingScan.hasUsingModule(header, LAMBDA_MODULE)) return [for (e in rewrites) { span: e.span, text: e.text, group: null }];
		final usingEdit: { span: Span, text: String } = UsingScan.usingInsertEdit(header, LAMBDA_MODULE);
		if (RefactorSupport.editsOverlapAny([usingEdit], rewrites))
			return [for (e in rewrites) { span: e.span, text: e.text, group: null }];
		// The inserted `using` and the calls that need it are ONE atomic group: a verifier that
		// reverted every rewrite while keeping the `using` would leave a file that still compiles,
		// so nothing downstream could tell that subset was wrong — the orphan-import class
		// `GroupedFix` exists for. Grouping only bites in a file that needed a new `using`; a file
		// that already had one keeps per-edit granularity, which is the common case.
		final grouped: Array<GroupedEdit> = [for (e in rewrites) { span: e.span, text: e.text, group: USING_GROUP }];
		grouped.push({ span: usingEdit.span, text: usingEdit.text, group: USING_GROUP });
		return grouped;
	}

	/** Bundle the `RefShape` kinds the engine reads, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final forStmtKind: Null<String> = shape.forStmtKind;
		final returnKind: Null<String> = shape.returnStatementKind;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (forStmtKind == null || returnKind == null || blockStmtKind == null || boolLitKind == null) return null;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		// Every form pairs adjacent statement-list siblings, so without the statement-list kinds the
		// engine has nothing to walk — a no-op stated up front rather than one that emerges.
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		return ifKinds.length == 0 || blockKinds.length == 0 ? null : {
			forStmtKind: forStmtKind,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind,
			boolLitKind: boolLitKind,
			ifKinds: ifKinds,
			blockKinds: blockKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			andLowerPrecedenceKinds: shape.andLowerPrecedenceKinds ?? [],
			identKind: shape.identKind,
			notKind: shape.notKind,
			intervalKind: shape.intervalKind,
			callKind: shape.callKind,
			newExprKind: shape.newExprKind,
			fieldAccessKind: shape.fieldAccessKind,
			nullSafeAccessKind: shape.nullSafeAccessKind,
			forceFieldAccessKind: shape.forceFieldAccessKind,
			indexAccessKind: shape.indexAccessKind,
			parenKind: shape.parenKind
		};
	}

	/**
	 * Descend `node`, handing every recovered loop to `emit`; skip reification subtrees.
	 *
	 * `succ` is the statement control reaches when `node` completes NORMALLY, or null when that is
	 * unknown — the one piece of flow the shape needs, because the loop's fallback return is not
	 * always its immediate sibling. Three rules propagate it, and everything else drops it:
	 *
	 * - a statement list gives child `i` the sibling `i + 1`, and its LAST child the list's own
	 *   `succ` — a loop at the tail of a block falls out of that block;
	 * - an `if` STATEMENT gives each branch body its own `succ` (leaving a branch continues after
	 *   the `if`) and gives the condition none;
	 * - every other node gives its children null. That is what keeps the walk sound: falling off
	 *   the end of a LOOP body starts the next iteration rather than continuing after it, and a
	 *   conditional-compilation region's flattened branches are not a statement list at all.
	 */
	private static function scan(
		node: QueryNode, succ: Null<QueryNode>, source: String, s: Seams, kind: BoolLoopKind, emit: (Cand) -> Void
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		final isList: Bool = s.blockKinds.contains(node.kind);
		// A branch body inherits the `if`'s own successor; a condition, and every other node's
		// children, inherit nothing.
		final branchSucc: Null<QueryNode> = s.ifKinds.contains(node.kind) ? succ : null;
		for (i in 0...kids.length) {
			final childSucc: Null<QueryNode> = if (isList)
				(i < kids.length - 1 ? kids[i + 1] : succ);
			else if (branchSucc != null && i > 0)
				branchSucc;
			else
				null;
			// A CLAIMED statement's subtree loses the successor. `if (g) { for … }` followed by the
			// fallback is one site, and both readings of it match: the guarded merge at the `if`,
			// and the bare fall-through at the loop inside the braces. They describe the same code
			// and their edits overlap, so the merged form — reported here first — takes it.
			var inner: Null<QueryNode> = childSucc;
			if (isList) {
				final cand: Null<Cand> = candidateAt(kids[i], childSucc, i < kids.length - 1, source, s, kind);
				if (cand != null) {
					emit(cand);
					inner = null;
				}
			}
			scan(kids[i], inner, source, s, kind, emit);
		}
	}

	/**
	 * The bool-returning loop `a` / `b` form, or null when they are not it: `a` is the loop (bare)
	 * or the guard holding it, `b` the `return <opposite literal>` control reaches after it.
	 *
	 * `adjacent` says whether `b` is `a`'s immediate sibling. When it is, the rewrite SUBSUMES it —
	 * the collapsed `return` says everything the pair said, and leaving the old one behind would be
	 * dead code. When it is not, `b` is reached by falling out of one or more enclosing `if`
	 * branches and other paths still run into it, so only the loop is replaced.
	 */
	private static function candidateAt(
		a: QueryNode, b: Null<QueryNode>, adjacent: Bool, source: String, s: Seams, kind: BoolLoopKind
	): Null<Cand> {
		if (b == null) return null;
		final trailing: Null<QueryNode> = boolReturnLiteral(b, s);
		if (trailing == null) return null;
		final trailingValue: Null<Bool> = literalValue(trailing, source);
		// The loop returns `true` for the `exists` direction, `false` for `foreach`; the trailing
		// return must carry the OPPOSITE literal, which is what makes the collapse an identity.
		final loopValue: Bool = kind == BoolLoopKind.Exists;
		if (trailingValue == null || trailingValue == loopValue) return null;
		final bare: Null<Head> = forIfHead(a, source, s);
		if (bare != null && bare.value == loopValue) return {
			anchor: a,
			forNode: a,
			trailing: b,
			guard: null,
			head: bare,
			subsumesTrailing: adjacent
		};
		// The guarded form merges the guard with `&&`, which only reads as the original for the
		// `exists` direction — see the type doc for why the `foreach` mirror is refused outright.
		if (kind != BoolLoopKind.Exists || !s.ifKinds.contains(a.kind) || a.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final loop: QueryNode = unwrapSole(a.children[1], s);
		final guarded: Null<Head> = forIfHead(loop, source, s);
		return guarded == null || guarded.value != loopValue ? null : {
			anchor: a,
			forNode: loop,
			trailing: b,
			guard: a.children[0],
			head: guarded,
			subsumesTrailing: adjacent
		};
	}

	/**
	 * The `for (v in xs) if (cond) return <bool>;` destructure — loop variable, iterable, condition
	 * and the literal's value — or null when `forNode` is not that shape (wrong kind/arity, a
	 * key-value / range / call iterable, an `else`-bearing or non-literal-returning body).
	 *
	 * The key-value refusal is an explicit MODEL test, and the operand count after it is taken with
	 * the VALUE binder filtered OUT. Read together those look redundant — and that is the point:
	 * were the refusal dropped, a key-value loop would reach `FOR_CHILD_COUNT` exactly like a
	 * single-binder one and be rewritten, so the refusal is the sole gate and a test can prove it.
	 */
	private static function forIfHead(forNode: QueryNode, source: String, s: Seams): Null<Head> {
		if (forNode.kind != s.forStmtKind || NominalTypes.hasIterationValueBinder(forNode, s.valueBinderKinds)) return null;
		final operands: Array<QueryNode> = RefactorSupport.loopOperands(forNode, s.valueBinderKinds);
		final loopVar: Null<String> = forNode.name;
		if (loopVar == null || operands.length != FOR_CHILD_COUNT) return null;
		final iterable: QueryNode = operands[0];
		if (iterable.kind == s.intervalKind || iterable.kind == s.callKind) return null;
		final body: QueryNode = unwrapSole(operands[1], s);
		if (!s.ifKinds.contains(body.kind) || body.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final lit: Null<QueryNode> = boolReturnLiteral(unwrapSole(body.children[1], s), s);
		if (lit == null) return null;
		final value: Null<Bool> = literalValue(lit, source);
		return value == null ? null : {
			loopVar: loopVar,
			iterable: iterable,
			cond: body.children[0],
			value: value
		};
	}

	/** The boolean literal of a `return <bool literal>;` statement, or null for any other statement. */
	private static function boolReturnLiteral(node: QueryNode, s: Seams): Null<QueryNode> {
		return node.kind == s.returnKind && node.children.length == 1 && node.children[0].kind == s.boolLitKind ? node.children[0] : null;
	}

	/** A boolean literal's VALUE, read off its source text; null when the span is missing or the text is neither spelling. */
	private static function literalValue(lit: QueryNode, source: String): Null<Bool> {
		final span: Null<Span> = lit.span;
		if (span == null) return null;
		final text: String = source.substring(span.from, span.to);
		return text == TRUE_LITERAL ? true : (text == FALSE_LITERAL ? false : null);
	}

	/** Unwrap a single-statement `{ … }` block to its sole child; every other node passes through unchanged. */
	private static function unwrapSole(node: QueryNode, s: Seams): QueryNode {
		return node.kind == s.blockStmtKind && node.children.length == 1 ? node.children[0] : node;
	}

	/** Assemble the `Info` finding anchored at the loop (or its guard), with the suggested call in the message. */
	private static function buildViolation(
		cand: Cand, source: String, s: Seams, kind: BoolLoopKind, ruleId: String, file: String
	): Null<Violation> {
		final anchorSpan: Null<Span> = cand.anchor.span;
		final parts: Null<Parts> = callParts(cand, source, s, kind);
		if (anchorSpan == null || parts == null) return null;
		final core: String = '${excerpt(parts.iterable)}.${method(kind)}(${cand.head.loopVar} -> ${excerpt(parts.predicate)})';
		final guard: Null<String> = parts.guard;
		final suggestion: String = guard == null ? core : '${excerpt(guard)} && $core';
		return {
			file: file,
			span: anchorSpan,
			rule: ruleId,
			severity: Severity.Info,
			message: kind == BoolLoopKind.Exists
				? 'this manual any-match loop can be $suggestion'
				: 'this manual all-match loop can be $suggestion'
		};
	}

	/** The one edit replacing `cand`'s loop (and its trailing return) with the call, or null when a gate refuses it. */
	private static function buildEdit(cand: Cand, source: String, s: Seams, kind: BoolLoopKind): Null<{ span: Span, text: String }> {
		final anchorSpan: Null<Span> = cand.anchor.span;
		final trailingSpan: Null<Span> = cand.trailing.span;
		final parts: Null<Parts> = callParts(cand, source, s, kind);
		if (anchorSpan == null || trailingSpan == null || parts == null) return null;
		// A subsumed trailing return is swallowed by the replacement; a fall-through one is reached
		// by other paths and must survive, so the region stops at the loop.
		final region: Span = cand.subsumesTrailing ? new Span(anchorSpan.from, trailingSpan.to) : anchorSpan;
		if (droppedRegionHasComment(source, region, parts.kept)) return null;
		final core: String = '${parts.iterable}.${method(kind)}(${cand.head.loopVar} -> ${parts.predicate})';
		final guard: Null<String> = parts.guard;
		return { span: region, text: guard == null ? 'return $core;' : 'return $guard && $core;' };
	}

	/**
	 * The three re-spliced texts — guard (null when unguarded), receiver and predicate, each already
	 * parenthesised where precedence needs it — plus the spans they came from, in source order, so
	 * the comment gate can test the gaps between them. Null when any span is unavailable.
	 */
	private static function callParts(cand: Cand, source: String, s: Seams, kind: BoolLoopKind): Null<Parts> {
		final iterSpan: Null<Span> = cand.head.iterable.span;
		final condSpan: Null<Span> = cand.head.cond.span;
		if (iterSpan == null || condSpan == null) return null;
		// A `foreach` predicate is the loop condition INVERTED, and an already-negated condition
		// inverts by DROPPING its `!` — which means splicing the operand's span instead of the
		// condition's. That substitution is the one thing distinguishing the two predicate forms.
		final stripped: Null<Span> = kind == BoolLoopKind.Exists ? null : negatedSpan(cand.head.cond, s);
		final predSpan: Span = stripped ?? condSpan;
		final predText: String = source.substring(predSpan.from, predSpan.to);
		final kept: Array<Span> = [iterSpan, predSpan];
		var guardText: Null<String> = null;
		final guard: Null<QueryNode> = cand.guard;
		if (guard != null) {
			final guardSpan: Null<Span> = guard.span;
			if (guardSpan == null) return null;
			guardText = parenthesizeUnless(source.substring(guardSpan.from, guardSpan.to), !s.andLowerPrecedenceKinds.contains(guard.kind));
			kept.unshift(guardSpan);
		}
		return {
			guard: guardText,
			iterable: parenthesizeUnless(source.substring(iterSpan.from, iterSpan.to), postfixSafe(cand.head.iterable.kind, s)),
			// The inversion is a WRAP, never De Morgan: distributing `!` through a chain reorders
			// the operands a null narrowing depends on. `!!c` and `c` agree, so a condition that
			// was already a `!` arrives here as its stripped operand and needs no wrap.
			predicate: kind == BoolLoopKind.Exists || stripped != null ? predText : '!($predText)',
			kept: kept
		};
	}

	/** The operand span of a `!` condition — the span that REPLACES it when `foreach` inverts — or null when the condition is not a negation. */
	private static function negatedSpan(cond: QueryNode, s: Seams): Null<Span> {
		final notKind: Null<String> = s.notKind;
		return notKind != null && cond.kind == notKind && cond.children.length == 1 ? cond.children[0].span : null;
	}

	/**
	 * Whether a comment sits anywhere in the replaced `region` but the `kept` sub-expression spans —
	 * the loop header, the `) if (` glue, the literal return and the gap before the trailing return.
	 * The whole region is replaced by one call, so such a comment is silently dropped; refusing here
	 * leaves the loop a report-only finding. `kept` is in ascending source order and disjoint.
	 */
	private static function droppedRegionHasComment(source: String, region: Span, kept: Array<Span>): Bool {
		var cursor: Int = region.from;
		for (span in kept) {
			if (CheckScan.hasCommentMarker(source, cursor, span.from)) return true;
			cursor = span.to;
		}
		return CheckScan.hasCommentMarker(source, cursor, region.to);
	}

	/** `src` verbatim when `safe`, else wrapped in parentheses — keeps a spliced sub-expression's precedence intact. */
	private static function parenthesizeUnless(src: String, safe: Bool): String {
		return safe ? src : '($src)';
	}

	/** Whether `kind` is a postfix / primary expression that `.exists(…)` binds directly onto; a looser iterable is wrapped. */
	private static function postfixSafe(kind: String, s: Seams): Bool {
		return kind == s.identKind || kind == s.fieldAccessKind || kind == s.nullSafeAccessKind || kind == s.forceFieldAccessKind
			|| kind == s.indexAccessKind || kind == s.parenKind || kind == s.callKind || kind == s.newExprKind;
	}

	/** The text with whitespace runs collapsed and truncated past the excerpt cap, so a multi-line expression fits one message line. */
	private static function excerpt(text: String): String {
		final buf: StringBuf = new StringBuf();
		var prevSpace: Bool = false;
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			final isSpace: Bool = c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
			if (isSpace) {
				if (!prevSpace) buf.addChar(' '.code);
				prevSpace = true;
			} else {
				buf.addChar(c);
				prevSpace = false;
			}
		}
		final flat: String = buf.toString().trim();
		return flat.length > EXCERPT_MAX ? '${flat.substring(0, EXCERPT_MAX)}…' : flat;
	}

}

/** Which of the two bool-returning loop directions a scan claims — the loop's own literal decides, so the two are disjoint. */
enum abstract BoolLoopKind(Int) {

	/** `for (x in xs) if (c) return true;` + `return false;` -> `xs.exists(x -> c)`. */
	final Exists = 0;

	/** `for (x in xs) if (c) return false;` + `return true;` -> `xs.foreach(x -> !(c))`. */
	final Foreach = 1;

}

/** The `RefShape` kinds `BoolLoopScan` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var forStmtKind: String;
	var returnKind: String;
	var blockStmtKind: String;
	var boolLitKind: String;
	var ifKinds: Array<String>;

	/**
	 * The STATEMENT-LIST kinds (`ControlFlowSupport.blockKinds`) whose direct children may be
	 * paired. A conditional-compilation region is deliberately absent: its branches project as
	 * FLATTENED siblings, so pairing under it would join a loop in one `#if` branch to a return
	 * in another and rewrite across the boundary.
	 */
	var blockKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var valueBinderKinds: Array<String>;
	var andLowerPrecedenceKinds: Array<String>;
	var identKind: Null<String>;
	var notKind: Null<String>;
	var intervalKind: Null<String>;
	var callKind: Null<String>;
	var newExprKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var nullSafeAccessKind: Null<String>;
	var forceFieldAccessKind: Null<String>;
	var indexAccessKind: Null<String>;
	var parenKind: Null<String>;
}

/** The `for (v in xs) if (cond) return <bool>;` destructure — the head both forms start from. */
private typedef Head = {
	var loopVar: String;
	var iterable: QueryNode;
	var cond: QueryNode;

	/** The value the loop's own `return` carries — `true` for the `exists` direction. */
	var value: Bool;
}

/** A recovered bool-returning loop: the node the finding anchors on, the loop, its trailing return, an optional guard and the head. */
private typedef Cand = {
	/** The loop, or the guard `if` holding it — the node the finding's span covers and the fix's region starts at. */
	var anchor: QueryNode;
	var forNode: QueryNode;
	var trailing: QueryNode;
	var guard: Null<QueryNode>;
	var head: Head;

	/** Whether `trailing` is the anchor's immediate sibling, so the rewrite replaces both rather than the loop alone. */
	var subsumesTrailing: Bool;
}

/** The re-spliced texts of one rewrite plus the source spans they came from, in ascending order, for the comment gate. */
private typedef Parts = {
	var guard: Null<String>;
	var iterable: String;
	var predicate: String;
	var kept: Array<Span>;
}
