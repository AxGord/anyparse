package anyparse.check;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.Violation;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.check.UsingScan.UsingHeader;
import anyparse.check.UsingScan.UsingScope;
import anyparse.query.BinderScan;
import anyparse.query.CanonicalEdit;
import anyparse.query.CtorFieldFold;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NodeShape;
import anyparse.query.NominalTypes;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The shape engine behind `prefer-exists`, `prefer-foreach` and `prefer-count`: a `for` loop whose
 * body writes one SINK, folded into the `Lambda` call it spells by hand. One recovery pass,
 * parameterised by `LambdaLoopKind`; the directions are disjoint by the sink (a boolean literal,
 * `true` for `exists` and `false` for `foreach`, or a counter's increment for `count`).
 *
 * - RETURN sink: `for (x in xs) if (c) return true;` + `return false;` -> `return xs.exists(x -> c);`
 *   (`foreach` mirrored, as the WRAP `!(c)`, never De Morgan). Only `exists` also claims the
 *   GUARDED `if (g) for …` as `g && xs.exists(…)`.
 * - FLAG sink: `var f = false;` immediately followed by `for (x in xs) if (c) f = true;` ->
 *   `final f = xs.exists(x -> c);`. For `count`, `var n = 0;` + `for (x in xs) if (c) n++;` (the
 *   `if` optional) -> `final n = xs.count(x -> c);`, or `xs.length` over a std `Array` / `List`.
 *
 * ## Purity: the bool flag forms need it, `count` does not
 *
 * A `return` leaves at the first match, so the short-circuit of `exists` / `foreach` is invisible.
 * A flag loop runs to the end, so an effectful condition would stop running for the tail: the two
 * bool flag forms require `PurityScan.isPure`, and refuse when it cannot be answered.
 * `Lambda.count` walks the WHOLE collection and calls `pred` once per element, in order, with no
 * short-circuit — the loop and the call are the same program, so `count` carries no purity gate.
 *
 * The shape gates are documented where they are written: `forIfHead` (loop, body, iterable type,
 * `super`), `flagCandidateAt` (the FLAG pairing), `provenIterator`, `spellingOf`, `buildEdit`.
 * Rationale for what is deliberately NOT claimed lives in `docs/decisions.md`.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `returnStatementKind`, `blockStmtKind`, `boolLitKind`,
 * `ifStatementKinds` and `ControlFlowSupport.blockKinds` (any unset -> a no-op). The FLAG arm adds
 * `assignKind`, `exprStatementKind`, `mutableLocalDeclKinds` and `LoopScan.seamsOf`; `count` adds
 * `postIncrKind` / `preIncrKind` / `addAssignKind`. An unset seam costs REACH, never soundness.
 */
@:nullSafety(Strict)
final class LambdaLoopScan {

	/** A `for` node has exactly [iterable, body] operands once the key-value binder is filtered out. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** The flag's ONE write: the loop's own assignment, and nothing else in the enclosing statement list. */
	private static inline final FLAG_WRITES: Int = 1;

	/** The keyword the folded declaration is emitted with — after the fold the binding is written once. */
	private static inline final FINAL_KEYWORD: String = 'final';

	/** Cap on an excerpt's length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	/** The module whose `exists` / `foreach` / `count` the rewrite calls — the `using` the fix inserts when the file lacks it. */
	private static inline final LAMBDA_MODULE: String = 'Lambda';

	/** The atomic group binding an INSERTED `using Lambda;` to every call that needs it (see `edits`). */
	private static inline final USING_GROUP: Int = 0;

	/** The boolean literal's source text for `true` — the engine reads the VALUE off the span. */
	private static inline final TRUE_LITERAL: String = 'true';

	/** The boolean literal's source text for `false`; any other text makes the literal unreadable and the site skipped. */
	private static inline final FALSE_LITERAL: String = 'false';

	/**
	 * The nominal a loop may iterate and no `Lambda` call accepts: `for` takes an `Iterator`, the
	 * `Iterable<A>` parameter does not (`Iterator<Int> has no field count`). Refused BY TYPE for every
	 * iterable shape and every direction — the CALL shape is refused by the accept list below already.
	 */
	private static inline final ITERATOR_TYPE_NAME: String = 'Iterator';

	/** The only annotation a counter may carry: the fold's value is `Lambda.count`'s `Int`. */
	private static inline final COUNTER_TYPE_NAME: String = 'Int';

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
	 * - The `count` direction widens the list by `DeadBinderCounterLoop.COUNT_TYPES` — `Map` and
	 *   the concrete `haxe.ds` maps. `m.count()` and `m.count(v -> …)` both compile for each of them
	 *   (no map declares `count`, so the extension applies) and count the VALUES `for (v in m)`
	 *   visits; `haxe.ds.HashMap` and `haxe.ds.Vector` still answer `has no field count`.
	 *
	 * Kept as an ACCEPT list, not a refuse list: an unrecognised container fails by construction,
	 * which is the same report-only degradation an unresolved type gets.
	 */
	private static final ITERABLE_TYPE_NAMES: Array<String> = ['Array', 'List', 'Iterable'];

	/** The extension method `kind` rewrites to — the name a second `using` must be proven not to supply. */
	public static function method(kind: LambdaLoopKind): String {
		return switch kind {
			case LambdaLoopKind.Exists: 'exists';
			case LambdaLoopKind.Foreach: 'foreach';
			case LambdaLoopKind.Count: 'count';
		};
	}

	/** Every loop `kind` folds in `files` — both sinks — as `Severity.Info` findings carrying `ruleId`. */
	public static function findings(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, kind: LambdaLoopKind, ruleId: String
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
			scan(tree, null, source, s, kind, lazyProbes(source, plugin, tree, file, index, kind, s.loopSeams), cand -> {
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
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, index: Null<SymbolIndex>, kind: LambdaLoopKind
	): Array<GroupedEdit> {
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final symbols: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final header: UsingHeader = UsingScan.headerOf(tree, source, plugin);
		final conflicted: Bool = UsingScan.conflictingUsing(
			UsingScan.usingModules(header), LAMBDA_MODULE, method(kind), plugin, () -> symbols, []
		);
		// The same file the violations name, so the CALL-iterable proof resolves imports from
		// where the loop is written — the report pass proved it against exactly that context.
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final probe: Probes = lazyProbes(
			source, plugin, tree, file, RefactorSupport.lazySymbolIndex([{ file: file, source: source }], plugin, index), kind, s.loopSeams
		);
		final byKey: Map<String, Cand> = [];
		scan(tree, null, source, s, kind, probe, cand -> {
			final span: Null<Span> = cand.anchor.span;
			if (span != null) byKey['${span.from}:${span.to}'] = cand;
		});
		final rewrites: Array<{ span: Span, text: String }> = [];
		// Parallel to `rewrites`: whether each took the EXTENSION spelling, which is what decides
		// the `using` insert and its group. A QUALIFIED rewrite names `Lambda` outright, and a
		// `length` one does not call it at all.
		final extensionForm: Array<Bool> = [];
		// Parallel too: the finding each rewrite came from, and the ONLY ones a refusal below may name.
		// A `byKey` miss got no edit for its own reason, which the `using` gate did not decide.
		final accepted: Array<Violation> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final cand: Null<Cand> = byKey['${span.from}:${span.to}'];
			if (cand == null) continue;
			final edit: Null<{ span: Span, text: String }> = buildEdit(cand, source, s, kind);
			if (edit == null || CanonicalEdit.editsOverlapAny([edit], rewrites)) continue;
			rewrites.push(edit);
			extensionForm.push(cand.head.spelling == CallSpelling.Extension);
			accepted.push(v);
		}
		// Decided from the header BEFORE the loop and answered AFTER it, so the refusal can name the
		// findings whose rewrites it takes down. Answering at the decision point returned an empty set
		// and wrote nothing at all — a rule that withheld an edit without saying why, to the ledger.
		if (!conflicted) return rewrites.length == 0 ? [] : withUsingInsert(rewrites, extensionForm, header, accepted);
		UsingScan.noteDeclineWhereUnset(accepted, UsingScan.conflictingUsingDecline(LAMBDA_MODULE, method(kind)));
		return [];
	}

	/**
	 * The boolean literal `kind`'s loop returns or writes — `true` for `exists`, `false` for
	 * `foreach` — or null for `count`, whose loop steps a counter and carries no literal at all.
	 */
	private static function loopLiteral(kind: LambdaLoopKind): Null<Bool> {
		return switch kind {
			case LambdaLoopKind.Exists: true;
			case LambdaLoopKind.Foreach: false;
			case LambdaLoopKind.Count: null;
		};
	}

	/** The nominals a CALL iterable must resolve to under `kind` — see `ITERABLE_TYPE_NAMES`. */
	private static function iterableTypes(kind: LambdaLoopKind): Array<String> {
		return kind == LambdaLoopKind.Count ? ITERABLE_TYPE_NAMES.concat(DeadBinderCounterLoop.COUNT_TYPES) : ITERABLE_TYPE_NAMES;
	}

	/**
	 * The rewrites as `GroupedEdit`s, plus the `using Lambda;` the EXTENSION-form ones need — atomic
	 * with exactly those, and absent when none of them is present. An EMPTY result is the refusal: the
	 * guard leaves a call out, or the insert byte is already covered by a rewrite. Both refusals take
	 * the QUALIFIED rewrites down with them even though those need no import — the carve-out below
	 * keeps them out of the atomic GROUP, not out of a whole-file veto, and erring toward emitting
	 * nothing is the only direction that cannot ship a call binding nothing.
	 *
	 * The inserted `using` and the calls that need it are ONE group: a verifier that reverted every
	 * rewrite while keeping the `using` would leave a file that still compiles, so nothing
	 * downstream could tell that subset was wrong — the orphan-import class `GroupedFix` exists for.
	 * Grouping only bites in a file that needed a new `using`; a file that already had one keeps
	 * per-edit granularity, which is the common case. A QUALIFIED rewrite stays OUTSIDE the group —
	 * it does not depend on the import, so binding it there would make an unrelated revert take it
	 * down too, and a file whose every claimed site is shadowed gets the calls and no import at all.
	 */
	private static function withUsingInsert(
		rewrites: Array<{ span: Span, text: String }>, extensionForm: Array<Bool>, header: UsingHeader, violations: Array<Violation>
	): Array<GroupedEdit> {
		final flat: Array<GroupedEdit> = [for (e in rewrites) { span: e.span, text: e.text, group: null }];
		if (!extensionForm.contains(true)) return flat;
		// Only the EXTENSION-form sites depend on the module, so only their offsets decide: a
		// qualified rewrite outside the guard is no reason to refuse. `Guarded` is a refusal of the
		// whole file — the file declares `using Lambda;` inside a `#if` region that leaves one of
		// those calls out, and neither the extension call nor a second, unguarded declaration
		// resolves the way the author's guard says it should.
		final scope: UsingScope = UsingScan.usingScopeAt(
			header, LAMBDA_MODULE, [for (i in 0...rewrites.length) if (extensionForm[i]) rewrites[i].span.from]
		);
		if (scope == UsingScope.Guarded) {
			for (violation in violations)
				violation.declineReason = UsingScan.guardedUsingDecline(LAMBDA_MODULE, UsingScan.FILE_WIDE_SUBJECT);
			return [];
		}
		if (scope == UsingScope.InScope) return flat;
		// Returning `flat` on a covered anchor shipped exactly the output the `Guarded` branch above
		// refuses: every extension-form rewrite, and no `using Lambda;` to bind it. An insert that
		// cannot be spliced is a refusal of the whole set, not a reason to emit the calls without it.
		final usingEdit: Null<{ span: Span, text: String }> = UsingScan.insertUnlessCovered(header, LAMBDA_MODULE, rewrites, violations);
		if (usingEdit == null) return [];
		final grouped: Array<GroupedEdit> = [
			for (i in 0...rewrites.length)
				{
					span: rewrites[i].span,
					text: rewrites[i].text,
					group: extensionForm[i] ? USING_GROUP : null
				}
		];
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
			parenKind: shape.parenKind,
			// The COUNT sink's step spellings; with none set that direction matches nothing.
			incrementKinds: [
				for (k in [(shape.postIncrKind: Null<String>), shape.preIncrKind]) if (k != null) k
			],
			addAssignKind: shape.addAssignKind,
			superText: shape.superReferenceText,
			typeSyntax: plugin.typeSyntax
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
		node: QueryNode, succ: Null<QueryNode>, source: String, s: Seams, kind: LambdaLoopKind, probe: Probes, emit: (Cand) -> Void
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
		a: QueryNode, b: Null<QueryNode>, adjacent: Bool, source: String, s: Seams, kind: LambdaLoopKind, probe: Probes
	): Null<Cand> {
		// The loop returns `true` for the `exists` direction, `false` for `foreach`; the trailing
		// return must carry the OPPOSITE literal, which is what makes the collapse an identity. The
		// `count` direction has no return sink at all.
		final loopValue: Null<Bool> = loopLiteral(kind);
		if (b == null || loopValue == null) return null;
		final trailing: Null<QueryNode> = boolReturnLiteral(b, s);
		if (trailing == null) return null;
		final trailingValue: Null<Bool> = literalValue(trailing, source);
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
		if (kind != LambdaLoopKind.Exists || !s.ifKinds.contains(a.kind) || a.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
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
	 * single-variable MUTABLE local opening at the fold's identity, immediately followed by a loop
	 * whose whole body writes that same name — the OPPOSITE boolean literal for `exists` / `foreach`,
	 * an increment for `count`.
	 *
	 * The gates in order, cheapest first, and each one a fixture:
	 *
	 * - the declaration is a `mutableDeclKinds` single declarator (a `final` cannot be the loop's
	 *   target at all, and a multi-declarator `var a = false, b = 0;` is not one statement to fold);
	 * - its initializer is the identity `opensAtIdentity` names — `false` before `f = true` for
	 *   `exists`, `true` before `f = false` for `foreach`, `0` (unannotated or `Int`) for `count`;
	 * - the loop destructures with the FLAG sink, which also proves the write targets this name and
	 *   is the body's only statement;
	 * - the loop binder is not that name (it would shadow it), and neither the iterable nor the
	 *   condition reads it (`mentionsName`): the fold moves both into the name's own initializer;
	 * - for the two bool directions, the condition is PURE. The loop visits every element and the
	 *   emitted call does not, so anything the condition DOES would stop happening for the tail of
	 *   the collection — real code has such sites and this is what refuses them. `count` visits
	 *   every element too, so it skips this gate;
	 * - the loop's write is the name's only write in `scope`, which is what licenses `final`.
	 *
	 * `scope` is the statement list holding the pair, i.e. exactly the region a block-scoped local
	 * is visible in — so a write anywhere it could reach is a write this counts.
	 */
	private static function flagCandidateAt(
		decl: QueryNode, loop: QueryNode, scope: QueryNode, source: String, s: Seams, kind: LambdaLoopKind, probe: Probes
	): Null<Cand> {
		final loopSeams: Null<LoopSeams> = s.loopSeams;
		final exprStmtKind: Null<String> = s.exprStmtKind;
		final assignKind: Null<String> = s.assignKind;
		if (loopSeams == null || exprStmtKind == null || assignKind == null) return null;
		final name: Null<String> = LoopScan.singleLocalDeclName(decl, s.mutableDeclKinds, loopSeams);
		if (name == null) return null;
		final init: QueryNode = decl.children[0];
		// `declaredTypeAnnotation` answers null for a head it cannot attribute to `name` as well as for
		// one writing no annotation, and this shape cannot produce the first: the two conditions behind
		// it are a head with no `=` and a name absent from it, and a single declarator with a literal
		// initializer has both. The two answers are also worth the same here — a dropped annotation
		// still compiles, since the call's own type is the `Bool` / `Int` it would have restated — so no
		// branch separates them.
		final annotation: Null<String> = CtorFieldFold.declaredTypeAnnotation(source, decl);
		final loopValue: Null<Bool> = loopLiteral(kind);
		if (!opensAtIdentity(init, annotation, loopValue, source, s, loopSeams)) return null;
		final head: Null<Head> = forIfHead(loop, source, s, probe, {
			name: name,
			exprStmtKind: exprStmtKind,
			assignKind: assignKind,
			counts: loopValue == null,
			loopSeams: loopSeams
		});
		// A loop binder of the SAME name shadows the declaration, so the loop writes its own binder
		// and never the value the fold would compute.
		if (head == null || head.value != loopValue || head.loopVar == name) return null;
		final cond: Null<QueryNode> = head.cond;
		// The fold moves the iterable AND the condition INTO the sink's own initializer, where that
		// name is not bound yet — `rows[n]` would silently read an outer `n`.
		if (mentionsName(source, name, [head.iterable, cond], probe)) return null;
		// Only the SHORT-CIRCUITING directions owe a pure condition; `Lambda.count` walks everything.
		if (loopValue != null && (cond == null || !conditionIsPure(cond, probe))) return null;
		if (LoopScan.countWrites(scope, name, loopSeams) != FLAG_WRITES) return null;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = init.span;
		return declSpan == null || initSpan == null ? null : {
			anchor: decl,
			trailing: loop,
			guard: null,
			head: head,
			subsumesTrailing: true,
			flag: { name: name, annotation: annotation }
		};
	}

	/**
	 * Whether any of `nodes` reads `name` as a SIMPLE name. A TEXT scan, as `dead-binder-counter-loop`
	 * proves its binder dead — a `'$n'` interpolation or a reification splice is a read the tree does
	 * not index — restricted to what can bind: the member tail of a dotted access (`item.found`), a
	 * comment and an inert literal (`'found'`) are not reads of a local `found`.
	 */
	private static function mentionsName(source: String, name: String, nodes: Array<Null<QueryNode>>, probe: Probes): Bool {
		final masks: Masks = probe.masks();
		for (node in nodes) {
			final span: Null<Span> = node?.span;
			if (
				span != null
				&& OccurrenceScan.referencedUnqualifiedInRange(source, name, span.from, span.to, [], masks.comments, masks.inert)
			)
				return true;
		}
		return false;
	}

	/**
	 * Whether the declaration opens at the fold's IDENTITY. A bool direction needs the literal OPPOSITE
	 * to the one its loop writes — a matching pair could never change the value, and a non-literal is
	 * a different program. The `count` direction needs the literal `0` under no annotation or an `Int`
	 * one: the fold's value is `Lambda.count`'s `Int`, which a `Float` / `UInt` / `Null<Int>` counter
	 * would be re-typed by.
	 */
	private static function opensAtIdentity(
		init: QueryNode, annotation: Null<String>, loopValue: Null<Bool>, source: String, s: Seams, loopSeams: LoopSeams
	): Bool {
		if (loopValue == null)
			return LoopScan.isZeroLiteral(init, source, loopSeams)
				&& (annotation == null || NominalTypes.outerNominalOf(annotation, s.typeSyntax) == COUNTER_TYPE_NAME);
		final initValue: Null<Bool> = init.kind != s.boolLitKind ? null : literalValue(init, source);
		return initValue != null && initValue != loopValue;
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
		final assign: Null<QueryNode> = NodeShape.assignmentOf(stmt, sink.exprStmtKind, sink.assignKind);
		if (assign == null) return null;
		final target: QueryNode = assign.children[0];
		final value: QueryNode = assign.children[1];
		return target.kind == s.identKind && target.name == sink.name && value.kind == s.boolLitKind ? value : null;
	}

	/**
	 * The `for (v in xs) if (cond) <sink>;` destructure — loop variable, iterable, condition, the
	 * sink's literal and the call spelling — or null when `forNode` is not that shape (wrong
	 * kind/arity, a key-value / range iterable, a call iterable whose type is not a proven
	 * `Iterable`, a receiver `provenIterator` refuses, an `else`-bearing body, a then-branch that
	 * is not the sink, or a condition naming `super`, which cannot be reached from the lambda it
	 * becomes). The COUNT sink alone may drop the `if`: a bare increment counts every element,
	 * and its head carries no condition and no literal.
	 *
	 * The key-value refusal is an explicit MODEL test, and the operand count after it is taken with
	 * the VALUE binder filtered OUT. Read together those look redundant — and that is the point:
	 * were the refusal dropped, a key-value loop would reach `FOR_CHILD_COUNT` exactly like a
	 * single-binder one and be rewritten, so the refusal is the sole gate and a test can prove it.
	 */
	private static function forIfHead(forNode: QueryNode, source: String, s: Seams, probe: Probes, ?sink: FlagSink): Null<Head> {
		if (forNode.kind != s.forStmtKind || NominalTypes.hasIterationValueBinder(forNode, s.valueBinderKinds)) return null;
		final operands: Array<QueryNode> = BinderScan.loopOperands(forNode, s.valueBinderKinds);
		final loopVar: Null<String> = forNode.name;
		if (loopVar == null || operands.length != FOR_CHILD_COUNT) return null;
		final iterable: QueryNode = operands[0];
		if (iterable.kind == s.intervalKind) return null;
		if (iterable.kind == s.callKind && !resolvesToOneOf(iterable, probe.iterableTypes, probe)) return null;
		final shape: Null<BodyShape> = bodyShape(unwrapSole(operands[1], s), source, s, sink);
		final receiverType: Null<String> = receiverNominal(iterable, probe, s);
		if (shape == null || provenIterator(receiverType, probe)) return null;
		final spelling: Null<CallSpelling> = spellingOf(iterable, receiverType, shape.cond == null, probe, s);
		return spelling == null ? null : {
			loopVar: loopVar,
			iterable: iterable,
			cond: shape.cond,
			value: shape.value,
			spelling: spelling
		};
	}

	/**
	 * The loop BODY read as `if (cond) <sink>` — or, for the COUNT sink alone, as the bare step with no
	 * condition — with the sink's literal (null for `count`), or null when it is neither. A bool sink
	 * is an `if`'s then-branch carrying a readable literal; an `if` WITH an `else` is no shape at all.
	 * A condition naming `super` is refused here too: it becomes a LAMBDA body, and `super` cannot be
	 * reached from a local function.
	 */
	private static function bodyShape(body: QueryNode, source: String, s: Seams, ?sink: FlagSink): Null<BodyShape> {
		final filtered: Bool = s.ifKinds.contains(body.kind) && body.children.length == IF_NO_ELSE_CHILD_COUNT;
		final cond: Null<QueryNode> = filtered ? body.children[0] : null;
		if (cond != null && mentionsSuper(cond, s)) return null;
		final step: QueryNode = filtered ? unwrapSole(body.children[1], s) : body;
		if (sink != null && sink.counts)
			return LoopScan.isUnitIncrementOf(step, sink.name, sink.exprStmtKind, s.incrementKinds, s.addAssignKind, source, sink.loopSeams)
				? { cond: cond, value: null }
				: null;
		final lit: Null<QueryNode> = sink == null ? boolReturnLiteral(step, s) : flagAssignLiteral(step, sink, s);
		final value: Null<Bool> = lit == null ? null : literalValue(lit, source);
		return cond == null || value == null ? null : { cond: cond, value: value };
	}

	/** Whether `node`'s subtree names the base object (`superReferenceText`); false when the grammar declares none. */
	private static function mentionsSuper(node: QueryNode, s: Seams): Bool {
		final superText: Null<String> = s.superText;
		return superText != null
			&& (node.kind == s.identKind && node.name == superText || node.children.exists(child -> mentionsSuper(child, s)));
	}

	/**
	 * Whether the receiver type `nominal` is PROVABLY an iterator and not an iterable — structurally,
	 * by its members (`StructuralTypes.satisfiesIterator` / `satisfiesIterable`), so `ArrayIterator`,
	 * `IntIterator` or a project class with `hasNext` / `next` is refused as surely as `Iterator`.
	 * `for` iterates one and no `Lambda` call accepts it. An unresolved type is not refused, and with
	 * no index only the name `Iterator` itself is proof.
	 */
	private static function provenIterator(nominal: Null<String>, probe: Probes): Bool {
		if (nominal == null) return false;
		final index: Null<SymbolIndex> = probe.index();
		return index == null
			? nominal == ITERATOR_TYPE_NAME
			: index.structural.satisfiesIterator(nominal, probe.file) && !index.structural.satisfiesIterable(nominal, probe.file);
	}

	/**
	 * Whether `iterable` PROVABLY resolves to one of `names` — for a CALL iterable the direction's `iterableTypes`, the
	 * gate that replaced a blanket refusal of every call; for the `length` spelling `DeadBinderCounterLoop.LENGTH_TYPES`.
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
	 * fallback. An accept list of container names is that gate: `T` is not one of them.
	 *
	 * An untabled / unannotated / cross-scope call resolves to null and is REFUSED, which is the
	 * report-only degradation the whole rule family defaults to. That null is an ANSWER about
	 * this run's evidence, not a gap: widening it would mean guessing at a container the rewrite
	 * has to unify with `Iterable<A>`.
	 */
	private static function resolvesToOneOf(iterable: QueryNode, names: Array<String>, probe: Probes): Bool {
		final resolve: Null<(QueryNode) -> Null<String>> = probe.nominal();
		if (resolve == null) return false;
		final nominal: Null<String> = resolve(iterable);
		return nominal != null && names.contains(nominal);
	}

	/**
	 * The iterable's nominal in RECEIVER position — what both the `Iterator` refusal and the
	 * member-shadow gate read — or null when it does not resolve.
	 *
	 * The RECEIVER-position resolver, not the value one: the measured
	 * `baseData:Null<Map<Int, ObjectFrameData>>` site names `Null` as a value and `Map` as a member
	 * host, and it is the member host the rewrite binds against — and a `Null<Iterator<T>>` is as
	 * much an `Iterator` to `Lambda` as a bare one. The `Iterable` proof keeps the value question:
	 * peeling a `Null<Array<T>>` there would claim a shape the loop's own iterable does not have.
	 */
	private static function receiverNominal(iterable: QueryNode, probe: Probes, s: Seams): Null<String> {
		// A construction WRITES its type at the site, which the expression resolver does not read.
		final constructed: Null<String> = iterable.kind == s.newExprKind ? iterable.name : null;
		if (constructed != null) return SourceText.lastSegment(constructed);
		final resolve: Null<(QueryNode) -> Null<String>> = probe.receiver();
		return resolve == null ? null : resolve(iterable);
	}

	/**
	 * Whether the receiver type `nominal` (`receiverNominal`) provably DECLARES the method this
	 * direction rewrites to — the gate that keeps a `Map` receiver out of the `exists` direction.
	 *
	 * Haxe binds a real member before any `using` static extension, so `m.exists(x -> …)` on a
	 * `Map` resolves to `Map.exists(key:K)` and puts the lambda where a key belongs: a rewrite
	 * that cannot compile, which the oracle reverts on every run rather than once. The question is
	 * `MemberLookup.memberShadowsExtension`, the same one `prefer-static-extension` has always asked.
	 *
	 * A hit no longer REFUSES the site: it selects the QUALIFIED spelling `Lambda.exists(m, x -> …)`,
	 * which names the module outright and never consults the receiver's members. The two forms carry
	 * the SAME type requirement — `Lambda`'s first parameter is an `Iterable<A>` either way — so the
	 * fallback changes which call is written and nothing about whether the fold is sound. The refusal
	 * survives only where `UsingScan.qualifiedCallReaches` says the bare name `Lambda` does not reach
	 * the module from this file.
	 *
	 * It applies to EVERY iterable shape, not just the CALL one the `Iterable` proof above gates —
	 * the two ask about different things (what the receiver IS versus what it DECLARES) and a
	 * plain identifier is exactly where the measured `Map` sites live. Both fail closed on an
	 * unresolved receiver, in opposite directions and correctly: an unproven `Iterable` refuses the
	 * rewrite, an unproven member does not force one.
	 */
	private static function receiverDeclaresMethod(nominal: String, probe: Probes): Bool {
		final index: Null<SymbolIndex> = probe.index();
		return index != null && index.members.memberShadowsExtension(nominal, probe.method);
	}

	/**
	 * Which call the fold writes for `iterable`, or null when the only one that would bind is out of
	 * reach. An UNFILTERED count over a proven `Array` / `List` reads the container's own `length`
	 * and calls nothing — same answer, no walk, no import. A receiver whose type declares the method
	 * takes the QUALIFIED spelling, which needs the bare name `Lambda` to reach the module here.
	 * Everything else, an UNRESOLVED receiver included, is the extension call.
	 */
	private static function spellingOf(
		iterable: QueryNode, receiverType: Null<String>, unfiltered: Bool, probe: Probes, s: Seams
	): Null<CallSpelling> {
		return if (unfiltered && isLengthContainer(iterable, probe, s))
			CallSpelling.Length
		else if (receiverType == null || !receiverDeclaresMethod(receiverType, probe))
			CallSpelling.Extension
		else if (probe.qualified())
			CallSpelling.Qualified
		else
			null;
	}

	/**
	 * Whether `iterable` is a bare identifier whose WRITTEN type is a std `Array` / `List` — the one
	 * proof the `length` spelling takes, through the spelling gate `dead-binder-counter-loop` trusts the
	 * same list behind (`DeadBinderCounterLoop.stdContainerNominal`). A resolved simple name is not
	 * enough: a project `List` whose `length` is not its element count would compile, and the oracle
	 * could not tell. Anything else falls back to `count()`, which is right for every `Iterable`.
	 */
	private static function isLengthContainer(iterable: QueryNode, probe: Probes, s: Seams): Bool {
		final nominal: Null<String> = DeadBinderCounterLoop.stdContainerNominal(probe.writtenType(iterable), s.typeSyntax);
		return nominal != null && DeadBinderCounterLoop.LENGTH_TYPES.contains(nominal);
	}

	/**
	 * The per-file type probe, memoised and built on FIRST demand: a scan that meets no call
	 * iterable never forces the index, and one that meets several pays for it once. `index` is
	 * itself the run's lazy resolver, so a project with a declared scope reuses that index rather
	 * than building a second one. Null from `typeNominalResolver` (a grammar carrying no type
	 * information) makes every call iterable unprovable, i.e. exactly the old refusal.
	 */
	private static function lazyProbes(
		source: String, plugin: GrammarPlugin, tree: QueryNode, file: String, index: () -> Null<SymbolIndex>, kind: LambdaLoopKind,
		loopSeams: Null<LoopSeams>
	): Probes {
		final methodName: String = method(kind);
		var value: Null<(QueryNode) -> Null<String>> = null;
		var valueBuilt: Bool = false;
		var recv: Null<(QueryNode) -> Null<String>> = null;
		var recvBuilt: Bool = false;
		var purity: Null<PurityCtx> = null;
		var purityBuilt: Bool = false;
		var reaches: Bool = false;
		var reachesBuilt: Bool = false;
		var masks: Null<Masks> = null;
		var types: Null<Map<Int, String>> = null;
		var typesBuilt: Bool = false;
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
			qualified: () -> {
				if (!reachesBuilt) {
					reachesBuilt = true;
					reaches = UsingScan.qualifiedCallReaches(UsingScan.headerOf(tree, source, plugin), LAMBDA_MODULE, methodName, index);
				}
				return reaches;
			},
			masks: () -> {
				final known: Null<Masks> = masks;
				if (known != null) return known;
				final regions: Array<LexRegion> = plugin.lexicalRegions(source);
				final built: Masks = {
					comments: SourceComments.collectCommentRegions(regions),
					inert: OccurrenceScan.inertRegions(source, regions)
				};
				masks = built;
				return built;
			},
			writtenType: iterable -> {
				if (!typesBuilt) {
					typesBuilt = true;
					types = RunScan.typeInfoOf(plugin)?.declaredTypeSources(source);
				}
				final seams: Null<LoopSeams> = loopSeams;
				return seams == null || LoopScan.bareIdentName(iterable, seams) == null
					? null
					: LoopScan.identTypeSource(iterable, tree, types, seams);
			},
			index: index,
			file: file,
			method: methodName,
			iterableTypes: iterableTypes(kind)
		};
	}

	/** The boolean literal of a `return <bool literal>;` statement, or null for any other statement. */
	private static function boolReturnLiteral(node: QueryNode, s: Seams): Null<QueryNode> {
		return node.kind == s.returnKind && node.children.length == 1 && node.children[0].kind == s.boolLitKind ? node.children[0] : null;
	}

	/** A boolean literal's VALUE, read off its source text; null when the span is missing or the text is neither spelling. */
	private static function literalValue(lit: QueryNode, source: String): Null<Bool> {
		return switch (SourceText.nodeText(lit, source)) {
			case TRUE_LITERAL: true;
			case FALSE_LITERAL: false;
			case _: null;
		};
	}

	/** Unwrap a single-statement `{ … }` block to its sole child; every other node passes through unchanged. */
	private static function unwrapSole(node: QueryNode, s: Seams): QueryNode {
		return node.kind == s.blockStmtKind && node.children.length == 1 ? node.children[0] : node;
	}

	/**
	 * Assemble the `Info` finding anchored at the loop (or its guard, or
	 * the flag's declaration), with the suggested call in the message.
	 */
	private static function buildViolation(
		cand: Cand, source: String, s: Seams, kind: LambdaLoopKind, ruleId: String, file: String
	): Null<Violation> {
		final anchorSpan: Null<Span> = cand.anchor.span;
		final parts: Null<Parts> = callParts(cand, source, s, kind);
		if (anchorSpan == null || parts == null) return null;
		final predicate: Null<String> = parts.predicate;
		final core: String = callText(cand.head, excerpt(parts.iterable), predicate == null ? null : excerpt(predicate), kind);
		final guard: Null<String> = parts.guard;
		final flag: Null<Flag> = cand.flag;
		// The message shows the SINK the fold writes to, so a reader can tell the two sinks apart
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
			message: switch kind {
				case LambdaLoopKind.Exists: 'this manual any-match loop can be $suggestion';
				case LambdaLoopKind.Foreach: 'this manual all-match loop can be $suggestion';
				case LambdaLoopKind.Count: 'this manual counting loop can be $suggestion';
			}
		};
	}

	/** The one edit replacing `cand`'s loop (and its trailing return) with the call, or null when a gate refuses it. */
	private static function buildEdit(cand: Cand, source: String, s: Seams, kind: LambdaLoopKind): Null<{ span: Span, text: String }> {
		final anchorSpan: Null<Span> = cand.anchor.span;
		final trailingSpan: Null<Span> = cand.trailing.span;
		final parts: Null<Parts> = callParts(cand, source, s, kind);
		if (anchorSpan == null || trailingSpan == null || parts == null) return null;
		// A subsumed trailing return is swallowed by the replacement; a fall-through one is reached
		// by other paths and must survive, so the region stops at the loop.
		final region: Span = cand.subsumesTrailing ? new Span(anchorSpan.from, trailingSpan.to) : anchorSpan;
		if (droppedRegionHasComment(source, region, parts.kept)) return null;
		final core: String = callText(cand.head, parts.iterable, parts.predicate, kind);
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
	 * The fold's call, in the spelling `head` selected: the extension `xs.exists(v -> c)`, or — when
	 * a receiver member shadows it — the QUALIFIED `Lambda.exists(xs, v -> c)`, which routes around
	 * that member and needs no `using Lambda;` at all.
	 */
	private static function callText(head: Head, iterable: String, predicate: Null<String>, kind: LambdaLoopKind): String {
		final lambda: Null<String> = predicate == null ? null : '${head.loopVar} -> $predicate';
		return switch head.spelling {
			case CallSpelling.Length: '$iterable.${DeadBinderCounterLoop.LENGTH_MEMBER}';
			case CallSpelling.Qualified: '$LAMBDA_MODULE.${method(kind)}($iterable${lambda == null ? '' : ', $lambda'})';
			case CallSpelling.Extension: '$iterable.${method(kind)}(${lambda ?? ''})';
		};
	}

	/**
	 * The three re-spliced texts — guard (null when unguarded), receiver and predicate, each already
	 * parenthesised where precedence needs it — plus the spans they came from, in source order, so
	 * the comment gate can test the gaps between them. Null when any span is unavailable.
	 */
	private static function callParts(cand: Cand, source: String, s: Seams, kind: LambdaLoopKind): Null<Parts> {
		final iterSpan: Null<Span> = cand.head.iterable.span;
		if (iterSpan == null) return null;
		final kept: Array<Span> = [iterSpan];
		// Null for an UNFILTERED count, the one head with no condition: its call takes no lambda.
		var predicate: Null<String> = null;
		final cond: Null<QueryNode> = cand.head.cond;
		if (cond != null) {
			final condSpan: Null<Span> = cond.span;
			if (condSpan == null) return null;
			// A `foreach` predicate is the loop condition INVERTED, and an already-negated condition
			// inverts by DROPPING its `!` — which means splicing the operand's span instead of the
			// condition's. That substitution is the one thing distinguishing the predicate forms.
			final stripped: Null<Span> = kind == LambdaLoopKind.Foreach ? negatedSpan(cond, s) : null;
			final predSpan: Span = stripped ?? condSpan;
			final predText: String = source.substring(predSpan.from, predSpan.to);
			// The inversion is a WRAP, never De Morgan: distributing `!` through a chain reorders
			// the operands a null narrowing depends on. `!!c` and `c` agree, so a condition that
			// was already a `!` arrives here as its stripped operand and needs no wrap.
			predicate = kind != LambdaLoopKind.Foreach || stripped != null ? predText : '!($predText)';
			kept.push(predSpan);
		}
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
			// The QUALIFIED spelling puts the receiver in an ARGUMENT slot, where no expression needs
			// parenthesising; the extension and `length` forms bind a postfix `.` onto it.
			iterable: parenthesizeUnless(
				source.substring(iterSpan.from, iterSpan.to),
				cand.head.spelling == CallSpelling.Qualified || postfixSafe(cand.head.iterable.kind, s)
			),
			predicate: predicate,
			kept: kept
		};
	}

	/**
	 * The operand span of a `!` condition — the span that REPLACES it when
	 * `foreach` inverts — or null when the condition is not a negation.
	 */
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

/**
 * Which of the three loop directions a scan claims — disjoint by the sink: the
 * loop's own literal for `exists` / `foreach`, a counter's increment for `count`.
 */
enum abstract LambdaLoopKind(Int) {

	/** `for (x in xs) if (c) return true;` + `return false;` -> `xs.exists(x -> c)`. */
	final Exists = 0;

	/** `for (x in xs) if (c) return false;` + `return true;` -> `xs.foreach(x -> !(c))`. */
	final Foreach = 1;

	/** `var n = 0;` + `for (x in xs) if (c) n++;` -> `final n = xs.count(x -> c)` — no literal, no short-circuit. */
	final Count = 2;

}

/** Which call a fold is written as — chosen once per site, by `spellingOf`. */
private enum abstract CallSpelling(Int) {

	/** The extension call `xs.<m>(v -> c)`, bound by a `using Lambda;`. */
	final Extension = 0;

	/** `Lambda.<m>(xs, v -> c)`: the receiver's own member would capture the extension call. */
	final Qualified = 1;

	/** `xs.length` — an unfiltered count over a proven `Array` / `List`: no call, no walk, no `using`. */
	final Length = 2;

}

/** The `RefShape` kinds `LambdaLoopScan` reads, bundled once so the walkers take one argument. */
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

	/**
	 * The COUNT sink's spellings of a counter's step: the unary increments (`n++` / `++n`) and the
	 * compound add (`n += 1`), plus the reader the counter's written annotation is proved `Int` with.
	 */
	var incrementKinds: Array<String>;
	var addAssignKind: Null<String>;

	/** The base-object identifier (`super`), which a condition moved into a lambda must not name. */
	var superText: Null<String>;
	var typeSyntax: TypeSyntaxReader;
}

/** The `for (v in xs) if (cond) <sink>;` destructure — the head every direction and both sinks start from. */
private typedef Head = {
	var loopVar: String;
	var iterable: QueryNode;

	/** The `if` condition — null only for an UNFILTERED count, whose loop steps on every element. */
	var cond: Null<QueryNode>;

	/** The literal the loop returns or writes — `true` for the `exists` direction, null for `count`. */
	var value: Null<Bool>;

	/**
	 * Which call this site is written as. It changes only WHICH call is written: a qualified or
	 * `length` site needs no `using Lambda;` and clears every other gate the same way.
	 */
	var spelling: CallSpelling;
}

/** A loop body's condition (null for an unfiltered count) and its sink's literal (null for `count`). */
private typedef BodyShape = {
	var cond: Null<QueryNode>;
	var value: Null<Bool>;
}

/**
 * A recovered loop of any direction: the node the finding anchors on, its
 * trailing return or loop, an optional guard and the destructured head.
 */
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

	/** Whether the sink is the COUNT one — the name's increment — rather than a bool assignment. */
	var counts: Bool;
	var loopSeams: LoopSeams;
}

/** The re-spliced texts of one rewrite plus the source spans they came from, in ascending order, for the comment gate. */
private typedef Parts = {
	var guard: Null<String>;
	var iterable: String;
	var predicate: Null<String>;
	var kept: Array<Span>;
}

/**
 * Everything the gates need, deferred: the memoised nominal-type resolvers a receiver is proved
 * against (null when the grammar carries no type information, and never built by a scan that meets
 * no gate), the purity context the FLAG arm's condition is proved against, the run's equally lazy
 * resolution index, and the ONE method name this direction rewrites to — bound once at
 * construction, since a scan runs for a single `LambdaLoopKind`.
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

	/**
	 * Whether the QUALIFIED `Lambda.<method>(…)` spelling reaches the module from this file
	 * (`UsingScan.qualifiedCallReaches`) — the fallback a receiver-shadowed site takes. Memoised
	 * and built on FIRST demand, so a file holding no shadowed site never reads its header.
	 */
	var qualified: () -> Bool;

	/** The file's comment spans and inert-literal mask (`OccurrenceScan.inertRegions`), lexed on first demand. */
	var masks: () -> Masks;

	/** The WRITTEN type of a bare-identifier iterable's binding, or null for any other shape or an unannotated one. */
	var writtenType: (QueryNode) -> Null<String>;
	var index: () -> Null<SymbolIndex>;

	/** The file the scan reads, which `StructuralTypes` resolves an unqualified type name from. */
	var file: String;
	var method: String;

	/** The nominals a CALL iterable must resolve to for this direction's call to compile (`iterableTypes`). */
	var iterableTypes: Array<String>;
}

/** What a name-mention scan masks: comment spans (for the qualifier test) and every byte that can neither bind nor read a name. */
private typedef Masks = {
	var comments: Array<Span>;
	var inert: Array<Span>;
}
