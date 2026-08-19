package anyparse.check;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.Violation;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.check.PurityScan.PurityCtx;
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
 * whose whole body is one `if` writing a boolean LITERAL to a SINK, paired with the OPPOSITE
 * literal at the same sink — the hand-written spelling of `Lambda.exists` / `Lambda.foreach`.
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
 * ## The two SINKS, and why the flag form needs a gate the return form does not
 *
 * The literal can be RETURNED, or it can be written to a boolean FLAG declared just above:
 *
 * ```
 * var f:Bool = false;
 * for (x in xs) if (c) f = true;      ->  final f:Bool = xs.exists(x -> c);
 * ```
 *
 * Stating the contract as the return form made the flag form invisible, and it is the form the
 * measured application actually writes — eleven sites against the return form's own count. The
 * `var` becomes `final`: after the fold the binding is written exactly once, at its declaration.
 *
 * The two sinks are NOT interchangeable, and the difference is the whole reason this arm carries
 * a purity gate. A `return` LEAVES the loop at the first match, so folding it onto a
 * short-circuiting `Lambda.exists` changes nothing at all. A flag assignment does not: the loop
 * runs to the end and evaluates the condition once per element, where `exists` stops at the first
 * `true` (and `foreach` at the first `false`). Everything the condition DOES for the remaining
 * elements would silently stop happening.
 *
 * That is not hypothetical. Of the eleven flag-form sites measured over a ~800-file application,
 * FIVE have a condition that is a call doing the work the loop exists for — `addItem(item, false)`,
 * `itemData.removeLocks(removeList)`, `locks.remove(rm)`, `addSessionToLock(…)`,
 * `removeSessionFromLock(…)`. Each records whether ANY call succeeded while calling on every
 * element. Without the gate the rule corrupts all five; with it, one site converts.
 *
 * Purity is `PurityScan.isPure` — the project's standing answer, shared with
 * `extract-repeated-expression`, `unnecessary-switch` and `join-array-pushes`: safe skeleton
 * kinds, a field or index READ whose resolvable first hop is not a property getter, and a
 * provably-pure stdlib static. Every other call is impure. `RefactorSupport.isSideEffectFree`
 * would have been the cheaper reach — and the wrong question: it refuses a field access outright,
 * which is exactly what the one CONVERTIBLE site's condition is (`child.nodeType == CData`), so
 * it would have refused all eleven and shipped nothing. When purity cannot be answered at all
 * (no symbol index, or a grammar carrying no type information) the arm refuses, which is the
 * report-only degradation the whole rule family defaults to.
 *
 * The GUARDED flag form (`var f = false; if (g) for … f = true;`) is not claimed: the statement
 * after the declaration must BE the loop. Every guarded flag site measured fails the purity gate
 * as well, so claiming it would buy nothing and would owe the `&&`/`||` merge reasoning a second
 * time. Neither is a GAP between the declaration and the loop, which `prefer-comprehension` needs
 * and this arm does not — both convertible sites are strictly adjacent, and the two non-adjacent
 * ones are effectful.
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
 * - No key-value loop (`Lambda` iterates values, not pairs) and no range `a...b` — two of the
 *   three refusals `prefer-find` makes, for the same reasons.
 * - A CALL iterable is refused unless its type RESOLVES to one of `ITERABLE_TYPE_NAMES`.
 *   `prefer-find` still refuses every call outright, on the grounds that one may yield an
 *   `Iterator`, which is not `Iterable`. That is true of `m.keys()` and false of
 *   `text.split(' ')`, so the blanket refusal is a stand-in for a type the project can
 *   already answer: `CheckScan.typeNominalResolver` reads the file's declared types and the
 *   run's `SymbolIndex`, and an unresolved call keeps the refusal.
 * - The binder cannot leak: the loop's entire body is the `if` and a literal return, so `x`
 *   occurs only inside the condition by construction. No separate gate is needed, and none is
 *   written — a gate that cannot fail is a gate nothing can test.
 * - The `foreach` inversion is a WRAP, `!(…)`, never De Morgan — pushing `!` through an `&&`
 *   chain reorders the operands a null narrowing depends on. The one exception costs nothing:
 *   a condition that is ALREADY a `!` drops it instead of gaining a second.
 *
 * ## Soundness gates the FLAG form adds
 *
 * - The condition is PURE (`PurityScan.isPure`) — see above; this is the one that matters.
 * - The declaration is a single-variable MUTABLE local (`mutableLocalDeclKinds`, so a `final` is
 *   not one) whose initializer is a boolean literal, and that literal is the OPPOSITE of the one
 *   the loop assigns. A matching pair is not this shape (the loop could never change the value),
 *   and a non-literal initializer is a different program.
 * - The loop is the declaration's IMMEDIATE next sibling in the same statement list, so nothing
 *   can read or write the flag in between and the two-statement region the edit replaces is
 *   contiguous.
 * - The loop body's `if` then-branch is exactly `<the flag> = <literal>;`. That is what makes the
 *   `break` / `continue` / `return` refusal structural rather than a written gate: a single
 *   assignment statement cannot be one, and a body holding anything more fails the shape.
 * - The loop's assignment is the flag's ONLY write anywhere in the enclosing statement list
 *   (`LoopScan.countWrites`). The fold emits `final`, which a later write would not compile
 *   against — and a flag written again is not the shape this fold describes either.
 * - The declaration's written annotation is carried over verbatim, and an absent one stays absent.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `returnStatementKind`, `blockStmtKind`, `boolLitKind`,
 * `ifStatementKinds` and `ControlFlowSupport.blockKinds` (any unset -> the check is a no-op),
 * with `opaqueKinds` skipping reification subtrees and `notKind` enabling the double-negation
 * relief. The boolean literal's VALUE is read from its source text (`true` / `false`); a
 * grammar spelling it otherwise yields neither value and the site is skipped rather than
 * misread.
 *
 * The FLAG arm needs three more — `assignKind`, `exprStatementKind`, `mutableLocalDeclKinds` —
 * plus `LoopScan.seamsOf`, whose scans it reuses rather than restating. Any of them unset turns
 * that arm off while the RETURN arm keeps working: an unset seam costs REACH, never soundness.
 */
@:nullSafety(Strict)
final class BoolLoopScan {

	/** A `for` node has exactly [iterable, body] operands once the key-value binder is filtered out. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** An assignment node has exactly [target, value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** The flag's ONE write: the loop's own assignment, and nothing else in the enclosing statement list. */
	private static inline final FLAG_WRITES: Int = 1;

	/** The keyword the folded declaration is emitted with — after the fold the binding is written once. */
	private static inline final FINAL_KEYWORD: String = 'final';

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

	/**
	 * The nominal types a CALL iterable may resolve to for the rewrite to compile — `Lambda`'s
	 * first parameter is an `Iterable<A>`, and these are the names that unify with it. Compiled
	 * on 4.3.7 with `using Lambda;`, one probe per name:
	 *
	 * - `Array`, `List`, `Iterable` — both `exists` and `foreach` resolve and type-check.
	 * - `Iterator` — `Iterator<Int> has no field exists` / `no field foreach`. This is the case
	 *   the blanket call refusal existed for (`m.keys()`), and it is now refused BY TYPE.
	 * - `haxe.ds.Vector` — `has no field exists`: it declares no `iterator()`, so it never
	 *   unifies with `Iterable`, however iterable a `for` loop makes it look.
	 * - `Map` — absent for a REASON the type alone does not state: `Lambda.foreach` accepts it,
	 *   but `m.exists(f)` binds to `Map`'s OWN `exists(key:K)` member and the static extension
	 *   never applies, so the `exists` direction would silently retarget. One name, two
	 *   directions, and only a whole-name refusal keeps them from disagreeing.
	 *
	 * Kept as an ACCEPT list, not a refuse list: an unrecognised container fails by construction,
	 * which is the same report-only degradation an unresolved type gets.
	 */
	private static final ITERABLE_TYPE_NAMES: Array<String> = ['Array', 'List', 'Iterable'];

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
		// Lazy: the resolution scope reads the std and the configured libraries, and only a CALL
		// iterable demands it — the one shape whose type has to be proved.
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final source: String = entry.source;
			final file: String = entry.file;
			scan(tree, null, source, s, kind, lazyProbes(source, plugin, tree, file, index, method(kind)), cand -> {
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
		// The same file the violations name, so the CALL-iterable proof resolves imports from
		// where the loop is written — the report pass proved it against exactly that context.
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final probe: Probes = lazyProbes(
			source, plugin, tree, file, RefactorSupport.lazySymbolIndex([{ file: file, source: source }], plugin, index), method(kind)
		);
		final byKey: Map<String, Cand> = [];
		scan(tree, null, source, s, kind, probe, cand -> {
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
			// The FLAG arm's own seams. An absent one turns that arm off and leaves the RETURN arm
			// intact, which is why they are read here rather than joining the null check above.
			mutableDeclKinds: shape.mutableLocalDeclKinds ?? [],
			loopSeams: LoopScan.seamsOf(shape),
			assignKind: shape.assignKind,
			exprStmtKind: shape.exprStatementKind,
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
		node: QueryNode, succ: Null<QueryNode>, source: String, s: Seams, kind: BoolLoopKind, probe: Probes, emit: (Cand) -> Void
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
				final cand: Null<Cand> = candidateAt(kids[i], childSucc, i < kids.length - 1, source, s, kind, probe);
				if (cand != null) {
					emit(cand);
					inner = null;
				} else if (i < kids.length - 1) {
					// The FLAG pairing reads the same two slots in the OPPOSITE roles — declaration
					// then loop, where the return form has loop then return — so the two can never
					// claim one pair: a node is either a declaration or a loop. Trying it only where
					// the return form declined keeps that true by construction rather than by a
					// disjointness argument nothing tests.
					final flagged: Null<Cand> = flagCandidateAt(kids[i], kids[i + 1], node, source, s, kind, probe);
					if (flagged != null) emit(flagged);
				}
			}
			scan(kids[i], inner, source, s, kind, probe, emit);
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
		a: QueryNode, b: Null<QueryNode>, adjacent: Bool, source: String, s: Seams, kind: BoolLoopKind, probe: Probes
	): Null<Cand> {
		if (b == null) return null;
		final trailing: Null<QueryNode> = boolReturnLiteral(b, s);
		if (trailing == null) return null;
		final trailingValue: Null<Bool> = literalValue(trailing, source);
		// The loop returns `true` for the `exists` direction, `false` for `foreach`; the trailing
		// return must carry the OPPOSITE literal, which is what makes the collapse an identity.
		final loopValue: Bool = kind == BoolLoopKind.Exists;
		if (trailingValue == null || trailingValue == loopValue) return null;
		final bare: Null<Head> = forIfHead(a, source, s, probe);
		if (bare != null && bare.value == loopValue) return {
			anchor: a,
			trailing: b,
			guard: null,
			head: bare,
			subsumesTrailing: adjacent,
			flag: null
		};
		// The guarded form merges the guard with `&&`, which only reads as the original for the
		// `exists` direction — see the type doc for why the `foreach` mirror is refused outright.
		if (kind != BoolLoopKind.Exists || !s.ifKinds.contains(a.kind) || a.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final loop: QueryNode = unwrapSole(a.children[1], s);
		final guarded: Null<Head> = forIfHead(loop, source, s, probe);
		return guarded == null || guarded.value != loopValue ? null : {
			anchor: a,
			trailing: b,
			guard: a.children[0],
			head: guarded,
			subsumesTrailing: adjacent,
			flag: null
		};
	}

	/**
	 * The FLAG-form pair `decl` / `loop` inside `scope`, or null when they are not it: a
	 * single-variable MUTABLE local opening at a boolean literal, immediately followed by a loop
	 * whose whole body writes the OPPOSITE literal to that same name.
	 *
	 * The gates in order, cheapest first, and each one a fixture:
	 *
	 * - the declaration is a `mutableDeclKinds` single declarator (a `final` cannot be the loop's
	 *   target at all, and a multi-declarator `var a = false, b = 0;` is not one statement to fold);
	 * - its initializer is a boolean literal OPPOSITE to the one this direction's loop writes —
	 *   `false` before `f = true` for `exists`, `true` before `f = false` for `foreach`;
	 * - the loop destructures with the FLAG sink, which also proves the assignment targets this
	 *   name and is the body's only statement;
	 * - the condition is PURE. The loop visits every element and the emitted call does not, so
	 *   anything the condition DOES would stop happening for the tail of the collection — the
	 *   measured application has five such sites and this is what refuses them;
	 * - the loop's assignment is the flag's only write in `scope`, which is what licenses `final`.
	 *
	 * `scope` is the statement list holding the pair, i.e. exactly the region a block-scoped local
	 * is visible in — so a write anywhere it could reach is a write this counts.
	 */
	private static function flagCandidateAt(
		decl: QueryNode, loop: QueryNode, scope: QueryNode, source: String, s: Seams, kind: BoolLoopKind, probe: Probes
	): Null<Cand> {
		final loopSeams: Null<LoopSeams> = s.loopSeams;
		final exprStmtKind: Null<String> = s.exprStmtKind;
		final assignKind: Null<String> = s.assignKind;
		if (loopSeams == null || exprStmtKind == null || assignKind == null) return null;
		final name: Null<String> = LoopScan.singleLocalDeclName(decl, s.mutableDeclKinds, loopSeams);
		if (name == null) return null;
		final init: QueryNode = decl.children[0];
		final initValue: Null<Bool> = init.kind != s.boolLitKind ? null : literalValue(init, source);
		// The loop writes `true` for the `exists` direction and `false` for `foreach`; the
		// declaration must open at the OPPOSITE, which is what makes the fold an identity.
		final loopValue: Bool = kind == BoolLoopKind.Exists;
		if (initValue == null || initValue == loopValue) return null;
		final head: Null<Head> = forIfHead(loop, source, s, probe, {
			name: name,
			exprStmtKind: exprStmtKind,
			assignKind: assignKind
		});
		if (head == null || head.value != loopValue) return null;
		if (!conditionIsPure(head.cond, probe)) return null;
		if (LoopScan.countWrites(scope, name, loopSeams) != FLAG_WRITES) return null;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = init.span;
		return declSpan == null || initSpan == null ? null : {
			anchor: decl,
			trailing: loop,
			guard: null,
			head: head,
			subsumesTrailing: true,
			flag: {
				name: name,
				// `declaredTypeAnnotation` answers null for a head it cannot attribute to `name` as
				// well as for one writing no annotation, and this shape cannot produce the first: the
				// two conditions behind it are a head with no `=` and a name absent from it, and a
				// single declarator with a literal initializer has both. The two answers are also
				// worth the same here — a dropped annotation still compiles, since the call's own
				// type is the `Bool` it would have restated — so no branch separates them.
				annotation: RefactorSupport.declaredTypeAnnotation(source, declSpan, initSpan, name)
			}
		};
	}

	/**
	 * Whether the loop condition can be evaluated FEWER times without changing what the program
	 * does — `PurityScan.isPure`, the project's standing answer, asked here because the emitted
	 * call short-circuits where the flag loop does not.
	 *
	 * A null context (no reachable symbol index, or a grammar carrying no type information) refuses
	 * every site. That is the direction the whole rule family fails in, and the only safe one: the
	 * question is whether dropping work is observable, and "unknown" cannot mean "no".
	 */
	private static function conditionIsPure(cond: QueryNode, probe: Probes): Bool {
		final ctx: Null<PurityCtx> = probe.purity();
		return ctx != null && PurityScan.isPure(cond, ctx);
	}

	/**
	 * The boolean literal of a `<flag> = <bool literal>;` statement, or null for any other
	 * statement — the FLAG sink's counterpart to `boolReturnLiteral`.
	 *
	 * Requiring the whole then-branch to BE this statement is what makes the `break` / `continue`
	 * / `return` refusal structural: a single assignment cannot be one, and a branch holding
	 * anything besides fails here rather than at a gate that would have to enumerate jump kinds.
	 */
	private static function flagAssignLiteral(stmt: QueryNode, sink: FlagSink, s: Seams): Null<QueryNode> {
		if (stmt.kind != sink.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != sink.assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
		final target: QueryNode = assign.children[0];
		final value: QueryNode = assign.children[1];
		return target.kind == s.identKind && target.name == sink.name && value.kind == s.boolLitKind ? value : null;
	}

	/**
	 * The `for (v in xs) if (cond) return <bool>;` destructure — loop variable, iterable, condition
	 * and the literal's value — or null when `forNode` is not that shape (wrong kind/arity, a
	 * key-value / range iterable, a call iterable whose type is not a proven `Iterable`, an
	 * `else`-bearing or non-literal-returning body).
	 *
	 * The key-value refusal is an explicit MODEL test, and the operand count after it is taken with
	 * the VALUE binder filtered OUT. Read together those look redundant — and that is the point:
	 * were the refusal dropped, a key-value loop would reach `FOR_CHILD_COUNT` exactly like a
	 * single-binder one and be rewritten, so the refusal is the sole gate and a test can prove it.
	 */
	private static function forIfHead(forNode: QueryNode, source: String, s: Seams, probe: Probes, ?sink: FlagSink): Null<Head> {
		if (forNode.kind != s.forStmtKind || NominalTypes.hasIterationValueBinder(forNode, s.valueBinderKinds)) return null;
		final operands: Array<QueryNode> = RefactorSupport.loopOperands(forNode, s.valueBinderKinds);
		final loopVar: Null<String> = forNode.name;
		if (loopVar == null || operands.length != FOR_CHILD_COUNT) return null;
		final iterable: QueryNode = operands[0];
		if (iterable.kind == s.intervalKind) return null;
		if (iterable.kind == s.callKind && !callIterableIsIterable(iterable, probe)) return null;
		if (receiverDeclaresMethod(iterable, probe)) return null;
		final body: QueryNode = unwrapSole(operands[1], s);
		if (!s.ifKinds.contains(body.kind) || body.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final then: QueryNode = unwrapSole(body.children[1], s);
		final lit: Null<QueryNode> = sink == null ? boolReturnLiteral(then, s) : flagAssignLiteral(then, sink, s);
		if (lit == null) return null;
		final value: Null<Bool> = literalValue(lit, source);
		return value == null ? null : {
			loopVar: loopVar,
			iterable: iterable,
			cond: body.children[0],
			value: value
		};
	}

	/**
	 * Whether a CALL iterable is PROVABLY one of `ITERABLE_TYPE_NAMES` — the gate that replaced a
	 * blanket refusal of every call.
	 *
	 * The proof is `CheckScan.typeNominalResolver`, the resolver seven shipped checks already
	 * consume: `TypeInfoProvider` answers the declared types written in this file, and the run's
	 * `SymbolIndex` — the std plus the configured libraries plus the report files — answers a
	 * member's written return type across files. Nothing else is consulted; there is no second
	 * mechanism beside the one the project already has.
	 *
	 * Those seven read it as a licence to RELAX a conservative wrap; this one ACTS on it, which
	 * its deep mode documents as needing a gate that rejects a name resolving to no unique
	 * declaration — the one leak being a verbatim type-PARAMETER name from the package-blind
	 * fallback. A three-name accept list is that gate: `T` is not one of them.
	 *
	 * An untabled / unannotated / cross-scope call resolves to null and is REFUSED, which is the
	 * report-only degradation the whole rule family defaults to. That null is an ANSWER about
	 * this run's evidence, not a gap: widening it would mean guessing at a container the rewrite
	 * has to unify with `Iterable<A>`.
	 */
	private static function callIterableIsIterable(iterable: QueryNode, probe: Probes): Bool {
		final resolve: Null<(QueryNode) -> Null<String>> = probe.nominal();
		if (resolve == null) return false;
		final nominal: Null<String> = resolve(iterable);
		return nominal != null && ITERABLE_TYPE_NAMES.contains(nominal);
	}

	/**
	 * Whether the iterable's own type provably DECLARES the method this direction rewrites to —
	 * the gate that keeps a `Map` receiver out of the `exists` direction.
	 *
	 * Haxe binds a real member before any `using` static extension, so `m.exists(x -> …)` on a
	 * `Map` resolves to `Map.exists(key:K)` and puts the lambda where a key belongs: a rewrite
	 * that cannot compile, which the oracle reverts on every run rather than once. The question is
	 * `SymbolIndex.memberShadowsExtension`, the same one `prefer-static-extension` has always asked.
	 *
	 * It applies to EVERY iterable shape, not just the CALL one the `Iterable` proof above gates —
	 * the two ask about different things (what the receiver IS versus what it DECLARES) and a
	 * plain identifier is exactly where the measured `Map` sites live. Both fail closed on an
	 * unresolved receiver, in opposite directions and correctly: an unproven `Iterable` refuses the
	 * rewrite, an unproven member does not force one.
	 */
	private static function receiverDeclaresMethod(iterable: QueryNode, probe: Probes): Bool {
		// The RECEIVER-position resolver, not the value one: the measured
		// `baseData:Null<Map<Int, ObjectFrameData>>` site names `Null` as a value and `Map` as a
		// member host, and it is the member host the rewrite binds against. The `Iterable` proof
		// above keeps the value question — peeling a `Null<Array<T>>` there would claim a shape the
		// loop's own iterable does not have.
		final resolve: Null<(QueryNode) -> Null<String>> = probe.receiver();
		final nominal: Null<String> = resolve == null ? null : resolve(iterable);
		if (nominal == null) return false;
		final index: Null<SymbolIndex> = probe.index();
		return index != null && index.memberShadowsExtension(nominal, probe.method);
	}

	/**
	 * The per-file type probe, memoised and built on FIRST demand: a scan that meets no call
	 * iterable never forces the index, and one that meets several pays for it once. `index` is
	 * itself the run's lazy resolver, so a project with a declared scope reuses that index rather
	 * than building a second one. Null from `typeNominalResolver` (a grammar carrying no type
	 * information) makes every call iterable unprovable, i.e. exactly the old refusal.
	 */
	private static function lazyProbes(
		source: String, plugin: GrammarPlugin, tree: QueryNode, file: String, index: () -> Null<SymbolIndex>, method: String
	): Probes {
		var value: Null<(QueryNode) -> Null<String>> = null;
		var valueBuilt: Bool = false;
		var recv: Null<(QueryNode) -> Null<String>> = null;
		var recvBuilt: Bool = false;
		var purity: Null<PurityCtx> = null;
		var purityBuilt: Bool = false;
		return {
			nominal: () -> {
				if (!valueBuilt) {
					valueBuilt = true;
					value = CheckScan.typeNominalResolver(source, plugin, tree, file, index());
				}
				return value;
			},
			receiver: () -> {
				if (!recvBuilt) {
					recvBuilt = true;
					recv = CheckScan.typeNominalResolver(source, plugin, tree, file, index(), true);
				}
				return recv;
			},
			purity: () -> {
				if (!purityBuilt) {
					purityBuilt = true;
					final symbols: Null<SymbolIndex> = index();
					purity = symbols == null ? null : PurityScan.contextOf(plugin, source, tree, symbols);
				}
				return purity;
			},
			index: index,
			method: method
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
		return if (text == TRUE_LITERAL)
			true
		else if (text == FALSE_LITERAL)
			false
		else
			null;
	}

	/** Unwrap a single-statement `{ … }` block to its sole child; every other node passes through unchanged. */
	private static function unwrapSole(node: QueryNode, s: Seams): QueryNode {
		return node.kind == s.blockStmtKind && node.children.length == 1 ? node.children[0] : node;
	}

	/** Assemble the `Info` finding anchored at the loop (or its guard, or the flag's declaration), with the suggested call in the message. */
	private static function buildViolation(
		cand: Cand, source: String, s: Seams, kind: BoolLoopKind, ruleId: String, file: String
	): Null<Violation> {
		final anchorSpan: Null<Span> = cand.anchor.span;
		final parts: Null<Parts> = callParts(cand, source, s, kind);
		if (anchorSpan == null || parts == null) return null;
		final core: String = '${excerpt(parts.iterable)}.${method(kind)}(${cand.head.loopVar} -> ${excerpt(parts.predicate)})';
		final guard: Null<String> = parts.guard;
		final flag: Null<Flag> = cand.flag;
		// The message shows the SINK the fold writes to, so a reader can tell the two arms apart
		// without opening the file. The annotation is left out of it — it is carried verbatim by the
		// edit and would only make the one-line suggestion wider than the excerpt cap allows.
		final suggestion: String = if (flag != null)
			'$FINAL_KEYWORD ${flag.name} = $core'
		else if (guard == null)
			core
		else
			'${excerpt(guard)} && $core';
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
		final flag: Null<Flag> = cand.flag;
		if (flag == null) return { span: region, text: guard == null ? 'return $core;' : 'return $guard && $core;' };
		// `final`, not the original `var`: the fold leaves the binding written exactly once, at its
		// declaration, and the single-write gate is what proved that. The annotation rides along
		// verbatim — it can be what TYPES the initializer, and the call's own type is not it.
		final annotation: Null<String> = flag.annotation;
		final head: String = annotation == null ? flag.name : '${flag.name}:$annotation';
		return { span: region, text: '$FINAL_KEYWORD $head = $core;' };
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

	/**
	 * The FLAG arm's seams: the MUTABLE local declaration kinds the flag may be declared with, the
	 * loop scans it borrows (`LoopScan.countWrites`), and the two kinds its sink is spelled from.
	 * Null / empty here turns that arm off and leaves the RETURN arm working.
	 */
	var mutableDeclKinds: Array<String>;
	var loopSeams: Null<LoopSeams>;
	var assignKind: Null<String>;
	var exprStmtKind: Null<String>;
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

/** A recovered bool-returning loop: the node the finding anchors on, its trailing return, an optional guard and the destructured head. */
private typedef Cand = {
	/** The loop, or the guard `if` holding it — the node the finding's span covers and the fix's region starts at. */
	var anchor: QueryNode;
	var trailing: QueryNode;
	var guard: Null<QueryNode>;
	var head: Head;

	/** Whether `trailing` is the anchor's immediate sibling, so the rewrite replaces both rather than the loop alone. */
	var subsumesTrailing: Bool;

	/**
	 * The FLAG sink, or null for the RETURN one. When set, `anchor` is the DECLARATION and
	 * `trailing` the loop that follows it, so the region covers both and the emitted text is a
	 * declaration rather than a `return`.
	 */
	var flag: Null<Flag>;
}

/** The declaration a FLAG-form fold re-emits: the bound name and its written annotation, if any. */
private typedef Flag = {
	var name: String;
	var annotation: Null<String>;
}

/** The FLAG sink's spelling, threaded into `forIfHead` so one destructure serves both sinks. */
private typedef FlagSink = {
	var name: String;
	var exprStmtKind: String;
	var assignKind: String;
}

/** The re-spliced texts of one rewrite plus the source spans they came from, in ascending order, for the comment gate. */
private typedef Parts = {
	var guard: Null<String>;
	var iterable: String;
	var predicate: String;
	var kept: Array<Span>;
}

/**
 * Everything the gates need, deferred: the memoised nominal-type resolvers a receiver is proved
 * against (null when the grammar carries no type information, and never built by a scan that meets
 * no gate), the purity context the FLAG arm's condition is proved against, the run's equally lazy
 * resolution index, and the ONE method name this direction rewrites to — bound once at
 * construction, since a scan runs for a single `BoolLoopKind`.
 */
private typedef Probes = {
	/** The VALUE resolver, behind the `Iterable`-shape proof a CALL iterable must clear. */
	var nominal: () -> Null<(QueryNode) -> Null<String>>;

	/** The MEMBER-LOOKUP resolver, behind the receiver-shadow gate — a `Null<T>` receiver answers `T`. */
	var receiver: () -> Null<(QueryNode) -> Null<String>>;

	/**
	 * The purity context behind the FLAG arm's condition gate. Null when no symbol index is
	 * reachable or the grammar carries no type information, and the arm then refuses every site —
	 * the report-only degradation, not an optimistic guess.
	 */
	var purity: () -> Null<PurityCtx>;
	var index: () -> Null<SymbolIndex>;
	var method: String;
}
