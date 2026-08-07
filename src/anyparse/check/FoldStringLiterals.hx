package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.ConcatSegment;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin.LayoutMetrics;
import anyparse.query.GrammarPlugin.RefShape;
import haxe.Exception;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.runtime.Span;

/**
 * Canonicalises a string concatenation to the MINIMAL number of `+` segments that
 * fits the file's own `maxLineLength`: adjacent literals and expression operands
 * MERGE into one interpolated literal, and an already-merged literal that overflows
 * the line SPLITS back out at its seams — a `${ … }` interpolation, or an embedded
 * `\n` ESCAPE. That second seam is what makes a lone over-long string TOKEN
 * layout-fixable at all: the writer can wrap a `+` chain, but nothing can wrap one
 * literal, so a message whose own text names its line breaks has to become a chain
 * before layout can reach it.
 *
 * `Severity.Info` — a layout cleanup, not a defect — with an autofix, and ON by
 * default, as the narrower adjacent-literal fold it grew out of was (`"a" + "b"` ->
 * `"ab"` still folds, and still to a DOUBLE-quoted literal).
 *
 * Both directions are one decision over one representation, which is what makes the
 * rule idempotent: canonical input yields zero findings.
 *
 * ## The atom: a flat segment list
 *
 * A construct — the maximal left-associative `+` chain, or a standalone string
 * literal — is flattened into a list of `ConcatSegment`s. A literal operand
 * contributes its own fragments (text, cut at each `\n` escape / `$name` / `${expr}`),
 * a bare expression operand contributes one segment, and the operands BEFORE the first
 * literal collapse into a single segment covering their source verbatim. Re-decomposing
 * this rule's OWN output reproduces the identical list, so any deterministic
 * grouping over it is a fixed point by construction — the property every other
 * piece of the design is arranged to protect.
 *
 * Grouping is then the only decision: partition the list into consecutive groups,
 * render each as one literal (or, for a lone expression segment, as a bare operand)
 * and join with `+`. Reporting compares BOUNDARIES — segment indices — against the
 * partition the SOURCE already has, never rendered text against source text: a
 * multi-line chain's source carries the writer's line breaks and a text comparison
 * would flag it forever.
 *
 * ## Width
 *
 * The budget comes from the file's OWN `hxformat.json` (discovered by walking up
 * from the file, via `FormatConfigDiscovery`) through `GrammarPlugin.layoutMetrics`
 * — a rule that measured against compiled defaults would mis-plan every project
 * whose style differs. A greedy left-to-right fill proposes a partition, and the
 * proposal is then VERIFIED through the writer: the candidate is spliced in, the
 * spliced and the unchanged texts are both rendered, and the widest line among those
 * that differ is the construct's TRUE width. An overflow shrinks the budget and
 * re-plans, bounded to three passes.
 *
 * The fill measures from the CONTINUATION column, which is optimistic on purpose (a
 * construct the writer wraps onto its own line is laid out there). One case refutes
 * that optimism without ever reaching the writer: the fill reproduces the source's own
 * boundaries — so nothing changed and nothing is measured — while the source line is
 * over-long anyway, which proves the writer did not move the construct. `unwrapped`
 * re-fills such a construct at its OWN column, and whatever that proposes still goes
 * through the same verification.
 *
 * Layout policy belongs to the writer and this rule only asks it questions. Every
 * candidate that changes anything asks one, because the answer is what the
 * arithmetic cannot supply: the estimate models the construct's line as the
 * construct ALONE, while the writer keeps whatever else that line carries (a
 * trailing comment, an operand it will not break before) on it. What the
 * verification renders is the enclosing MEMBER wrapped in a synthetic one-member
 * type (`PlanContext.scopeFor`), not the whole file — the writer wraps per line, so
 * a member one indent deep lays out the same either way, and the round trip costs a
 * few dozen lines instead of a few thousand. That one change is most of this rule's
 * cost.
 *
 * ## Gates, and why each exists
 *
 * - No string-literal operand (`a + b`, `1 + 2`): not a string concatenation at
 *   all — merging it would turn arithmetic into text.
 * - NUMERIC HEAD: `+` is left-associative, so operands before the first literal are
 *   still arithmetic (`1 + 2 + ' items'` is `"3 items"`, not `"12 items"`). Two or
 *   more of them collapse into ONE segment, and on the split side no two BARE
 *   groups may precede the first group that renders as a string — the same trap
 *   read backwards (`'${1}${2} items'` must not become `1 + 2 + ' items'`).
 * - An interior COMMENT between operands: the merge would swallow it, and a check
 *   may never delete an author's comment silently.
 * - An expression segment carrying `$`, a newline, a BACKSLASH or an UNBALANCED
 *   brace cannot enter a `${ … }` block: the real compiler's block scanner neither
 *   processes escapes inside a nested same-quote string nor lexes strings while it
 *   counts braces, so both mis-lex there even though anyparse's own interp scanner
 *   accepts them. It does not reject the construct — it only forces that segment
 *   into a group of its own, rendered bare.
 * - A DOUBLE-quoted text segment whose escapes DECODE to a `$` may not be re-emitted
 *   into a SINGLE-quoted literal: Haxe decodes before it scans for `$`, so
 *   `"a\x24b" + 'c'` folded to `'a\x24bc'` would silently print the value of the
 *   local `bc`. The seam refuses the group, and the construct is left as it stands.
 *   Only the trigger is refused, not every `\x..` / `\u....`: `"a\x41b"` is an `A`
 *   and folds. The SINGLE-quoted spelling of the same escape is not a text hazard —
 *   `'a\x24b'` IS a read of `b`, which `HxInterpProjection` projects as such, so it
 *   folds through the ordinary ident path into `'a${b}c'`.
 * - A `+` chain INSIDE a `${ … }` block: the walk stops at string literals, so a
 *   nested chain is never folded into an interpolation inside an interpolation.
 * - ANNOTATION arguments (`MetaShape.metaKinds`) and reification
 *   (`RefShape.opaqueKinds`) are skipped wholesale: a metadata string argument is
 *   parsed as a normal Haxe expression, so a `$` moved into one changes what the
 *   annotation says, and a reified subtree's identifiers are spliced, not written.
 * - CONSTANT-REQUIRED positions (`skipsSubtree`): a `case` pattern and a parameter
 *   default, both of which reject a concatenation outright.
 * - CONSTANT-READ FIELDS (`walkChildren`): an enum-abstract value and an `inline`
 *   field. Both compile folded and then stop answering to their own `case` patterns,
 *   because the pattern reads the value's expression SHAPE.
 * - A CALL ARGUMENT the gate cannot clear (`MacroGate`) is REPORTED but not fixed: a
 *   macro reads its arguments as syntax, and one matching a string constant simply
 *   stops matching a concatenation — silently. Refused both for a name a `macro` member
 *   declares and for one NOTHING in the resolution scope declares, since that scope is
 *   bounded by the invocation and the narrow answer is the dangerous one. A project
 *   clears a target through the `concatFoldingMacros` option, which is a claim about
 *   that target's implementation.
 * - RE-SEGMENT ONLY WHEN OVER-LONG: only a STRICT merge — a plan with FEWER groups
 *   than the source has — runs unconditionally. A split, and equally a same-count
 *   RE-CUT at different boundaries, needs the construct's source lines to be
 *   genuinely over-long; a chain the writer already lays out within the limit keeps
 *   the author's own phrasing instead of being repacked by the greedy fill.
 * - A single segment wider than the budget forms its own group and is accepted as
 *   is — literal TEXT is never split at word boundaries, only at segment seams.
 *
 * Not proven for an abstract that overloads `@:op(A + B)`: such a `+` may not be
 * concatenation at all, and no structural check can see it. That is why the
 * severity is `Info` rather than a warning.
 *
 * ## Autofix contract
 *
 * One span replacement per construct, the whole thing re-planned in `fix` through
 * the SAME `plan` function `run` reported from (back-off included), so the reported
 * and the applied segmentation cannot drift. The caller batches the edits into one
 * re-parse-validated canonicalize per file, which re-wraps the result — the fix
 * emits a single logical line and lets the writer lay it out.
 *
 * ## Grammar-agnostic
 *
 * Everything language-specific sits behind `StringFold.StringFoldSupport`:
 * `concatKind` names the binary operator, `segmentsOf` / `expressionSegment`
 * decompose, and `renderGroup` / `renderBare` re-render. Kinds come
 * from `RefShape` (`stringLiteralKinds`, `opaqueKinds`, the `Std.string` call
 * shape) and `MetaShape`. A grammar with no string-concatenation concept, or whose
 * plugin declares no layout metrics, makes the check a no-op.
 */
@:nullSafety(Strict)
final class FoldStringLiterals implements Check implements ConfigAware {

	/** The rule id, spelled once — `run`, `fix` and the registry all quote it. */
	private static inline final RULE_ID: String = 'fold-adjacent-string-literals';

	/** The `apqlint.json` option naming the macros PROVEN to fold a `+` chain of string constants. */
	private static inline final MACRO_WHITELIST_OPTION: String = 'concatFoldingMacros';

	/** What a finding adds when the macro gate turned it report-only — the reason, and the key that lifts it. */
	private static inline final MACRO_REFUSAL: String = ', but it is an argument of a call this rule cannot prove folds a '
		+ 'concatenation, and rewriting one a macro pattern-matches breaks it silently — list the target in the '
		+ '`$MACRO_WHITELIST_OPTION` option to allow it';

	/**
	 * Writer-verification passes per candidate. Each pass costs one `writeRoundTrip`
	 * — of the enclosing MEMBER normally, of the whole file when the member cannot be
	 * scoped — so the loop is bounded rather than run to a fixpoint; the greedy fill
	 * settles in one or two passes on real code, and the loop also stops the moment a
	 * narrower budget stops making the RESULT narrower.
	 */
	private static inline final MAX_BACKOFF_PASSES: Int = 3;

	/** The glue between two rendered groups. */
	private static inline final GROUP_JOIN: String = ' + ';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a string concatenation whose segmentation does not match the line width';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null || files.length == 0) return [];
		final macros: MacroIndex = new MacroIndex(plugin, files);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final ctx: Null<PlanContext> = contextFor(plugin, seams, entry.source, FormatConfigDiscovery.discover(entry.file));
			if (ctx == null) continue;
			// The whitelist is resolved PER FILE: `apqlint.json` is discovered by walking up
			// from each file, so one run can span several configs, and reading the first
			// file's would apply one project's claim about its macros to another's.
			final whitelist: Null<Array<String>> = LintConfig.resolveWith(_resolveConfig, entry.file)
				.stringListOption(RULE_ID, MACRO_WHITELIST_OPTION);
			final gate: MacroGate = new MacroGate(macros, whitelist ?? [], entry.file);
			for (planned in collectPlans(ctx, gate, tree)) violations.push({
				file: entry.file,
				span: planned.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: planned.message
			});
		}
		return violations;
	}

	/**
	 * Re-plan each flagged construct and emit its canonical text as ONE span
	 * replacement. The plan is recomputed rather than carried over from `run`
	 * (checks may not hold state between the two passes) through the SAME `plan`
	 * function, back-off included, so the reported and the applied segmentation
	 * cannot drift. The layout config comes from the violation's own file path —
	 * `fix` is handed one file's violations, and every one of them carries it.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$RULE_ID: fix() takes ONE file\'s violations, got $file and ${violation.file}');
		final ctx: Null<PlanContext> = contextFor(plugin, seams, source, FormatConfigDiscovery.discover(file));
		if (ctx == null) return [];
		final planContext: PlanContext = ctx;
		// The macro-argument refusal is a property of a construct's ANCESTRY and of a
		// cross-file symbol index, neither of which `fix` is handed — `applyBySpan` finds
		// a node by its span alone, and `source` is one file. `run` already decided it, so
		// the FINDING carries the decision here rather than the resolution being redone.
		final fixable: Array<Violation> = violations.filter(v -> v.message.indexOf(MACRO_REFUSAL) == -1);
		return CheckScan.applyBySpan(plugin, source, fixable, seams.candidateKinds, (node, span) -> {
			final planned: Null<PlannedFold> = plan(planContext, node);
			return planned == null ? null : { span: span, text: planned.text };
		});
	}

	/**
	 * Whether this rule CLAIMS the `+` chain rooted at `node` — the question
	 * `prefer-interpolation` asks before it defers a `Std.string(x)` operand here
	 * rather than reporting it itself. The two must ask the SAME question: a chain
	 * this rule never reports (`Std.string(a) + Std.string(b)` carries no string
	 * literal, so it is arithmetic as far as this rule is concerned) is one the other
	 * rule has to report, and a hand-off decided on the parent's KIND alone left it
	 * flagged by nobody.
	 *
	 * The claim is NECESSARY, not sufficient — two known gaps, both report-coverage
	 * only (neither can produce wrong output):
	 *
	 *  - the gates DOWNSTREAM of the claim (`renderGroup` refusing a text carrying a
	 *    numeric escape, or an operand with unbalanced `${ … }` braces) can still make
	 *    `plan` return nothing, and such a chain is then reported by neither rule.
	 *    Closing it means running the arithmetic fill here too.
	 *  - the hand-off does not know whether `fold-adjacent-string-literals` is
	 *    ENABLED, so a `--rule prefer-interpolation` run on its own stays silent on a
	 *    claimed chain. The active-rule set is known at the CLI seam, not here.
	 */
	public static function ownsChain(node: QueryNode, source: String, concatKind: String, stringLiteralKinds: Array<String>): Bool {
		return claim(node, source, concatKind, stringLiteralKinds) != null;
	}

	/** Every plan `tree` yields, in source order — the ONE traversal `run` reports from and `fix` is filtered against. */
	private static function collectPlans(ctx: PlanContext, gate: MacroGate, tree: QueryNode): Array<PlannedFold> {
		final out: Array<PlannedFold> = [];
		walk(out, ctx, gate, [], tree, false);
		return out;
	}

	/**
	 * Walk `node`, planning the OUTERMOST candidate on each path. A concatenation
	 * is planned as a whole and not descended into (its operands are already part
	 * of the plan); a string literal is planned for the SPLIT direction and never
	 * descended into either — its children are interpolation fragments, and a `+`
	 * chain nested inside a `${ … }` block must not fold, since the result would
	 * nest an interpolated string inside an interpolation block (fragile in the
	 * real compiler's interp scanner).
	 *
	 * Out-of-bounds subtrees are skipped outright (`skipsSubtree`, plus the constant-read
	 * fields `walkChildren` decides), and `calls` carries the simple names of the
	 * enclosing calls so the macro gate can refuse a plan sitting inside one — a plan
	 * that is still REPORTED, carrying the reason, since the construct genuinely does not
	 * fit. `constantMembers` says whether THIS node's field children are read as
	 * compile-time constants; `walkChildren` owns how it is derived.
	 */
	private static function walk(
		out: Array<PlannedFold>, ctx: PlanContext, gate: MacroGate, calls: Array<CallRef>, node: QueryNode, constantMembers: Bool
	): Void {
		final seams: Seams = ctx.seams;
		if (skipsSubtree(seams, node)) return;
		final literal: Bool = seams.stringLiteralKinds.contains(node.kind);
		if (literal || node.kind == seams.concatKind) {
			final planned: Null<PlannedFold> = plan(ctx, node);
			if (planned != null) out.push(gate.blocks(calls, planned.groups) ? {
				span: planned.span,
				text: planned.text,
				groups: planned.groups,
				message: planned.message + MACRO_REFUSAL
			} : planned);
			// A literal is never descended into; a chain only when it did not plan as
			// a whole, so an inner chain still gets its own chance.
			if (literal || planned != null) return;
		}
		final callee: Null<CallRef> = calleeNameOf(seams, node);
		if (callee != null) calls.push(callee);
		walkChildren(out, ctx, gate, calls, node, constantMembers);
		if (callee != null) calls.pop();
	}

	/**
	 * `node`'s children walked, with the two decisions only a PARENT can make.
	 *
	 * CONSTANT-READ FIELDS. An enum-abstract value and an `inline` field are both read as
	 * compile-time constants by a `case` pattern, and folding either costs it that:
	 * `var A = 'a' + 'b'` / `static inline final S = 'a' + 'b'` turn `case A:` / `case S:`
	 * into an "Unknown identifier" on Haxe 4.3.7 while still compiling everywhere else.
	 * Neither fact is visible from the field node — the modifier is a preceding SIBLING,
	 * and the enum-abstract-ness belongs to the declaration — so the running modifier
	 * state is kept here, exactly as `SymbolIndexBuilder.collectMembers` keeps its own.
	 *
	 * The run ends at every child that is neither a modifier nor an annotation — not only
	 * at a MEMBER, which is what a first attempt did and what let `@:enum abstract E {…}`
	 * mark every LATER declaration in the module as an enum abstract, a type declaration
	 * being no member kind. `runInline` likewise does not ask whether what follows is a
	 * member: a module-level `inline final S = …` is a top-level declaration whose value
	 * a `case` pattern reads exactly the same way.
	 *
	 * WHICH DECLARATIONS OPEN A VALUE REGION. The dedicated `enumAbstractDeclKind`, and
	 * also whatever declaration an `enumAbstractMetaName` annotation precedes — Haxe's
	 * DEPRECATED `@:enum abstract` spelling projects as a plain abstract with the
	 * annotation as a sibling, so a kind test alone reads it as an ordinary abstract and
	 * folds its values. A conditional-compilation region INHERITS the region it sits in:
	 * a `#if`-guarded value is the declaration's child one level down, and a gate that
	 * asked only about the immediate parent was blind to it. Both verified by compiling
	 * the folded output.
	 */
	private static function walkChildren(
		out: Array<PlannedFold>, ctx: PlanContext, gate: MacroGate, calls: Array<CallRef>, node: QueryNode, constantMembers: Bool
	): Void {
		final seams: Seams = ctx.seams;
		final metaName: Null<String> = seams.enumAbstractMetaName;
		var runInline: Bool = false;
		var runEnumMeta: Bool = false;
		for (c in node.children) {
			if (seams.modifierKinds.contains(c.kind)) {
				if (c.kind == seams.inlineKind) runInline = true;
				continue;
			}
			if (seams.metaKinds.contains(c.kind)) {
				if (metaName != null && c.name == metaName) runEnumMeta = true;
				continue;
			}
			// EVERY other child ends the run — a member, a nested type, a statement. Ending it
			// only at a MEMBER left `@:enum abstract E {…}` marking every LATER declaration in
			// the module as an enum abstract, since a type declaration is not a member kind.
			final fn: Bool = seams.functionKinds.contains(c.kind);
			final value: Bool = constantMembers && !fn && RefactorSupport.isMemberDeclKind(c.kind);
			// `runInline` is not asked whether the declaration is a MEMBER: a module-level
			// `inline final S = …` projects as a top-level declaration, and its value is the
			// same compile-time constant a `case` pattern reads the shape of.
			if (!(value || (runInline && !fn)))
				walk(
					out, ctx, gate, calls, c,
					c.kind == seams.enumAbstractDeclKind || runEnumMeta || (constantMembers && c.kind == seams.conditionalKind)
				);
			runInline = false;
			runEnumMeta = false;
		}
	}

	/**
	 * Whether the whole subtree at `node` is out of bounds — a position where a
	 * concatenation either cannot be written or is not read as a value:
	 *
	 *  - REIFICATION (`RefShape.opaqueKinds`), whose contents are spliced rather than
	 *    executed, and ANNOTATION arguments (`MetaShape.metaKinds`), parsed as normal
	 *    Haxe expressions so a `$` moved into one changes what the annotation says —
	 *    and which reject a concatenation outright (`@:native('a' + 'b')` is
	 *    "String expected");
	 *  - a `case` PATTERN: `case 'a\n' + 'b':` is "Unrecognized pattern";
	 *  - a PARAMETER, whose default value must be constant ("Default argument value
	 *    should be constant") — the whole parameter subtree goes, since the only
	 *    literal it can hold outside its metadata IS that default.
	 *
	 * The CONSTANT-READ FIELDS — an enum-abstract value, an `inline` field — are decided
	 * by their declaration and their modifier run instead (see `walkChildren`), neither
	 * of which a kind test can see. Both positions above verified against Haxe 4.3.7.
	 */
	private static function skipsSubtree(seams: Seams, node: QueryNode): Bool {
		return seams.opaqueKinds.contains(node.kind) || seams.metaKinds.contains(node.kind) || node.kind == seams.patternKind
			|| seams.paramKinds.contains(node.kind);
	}

	/**
	 * `node`'s call target as the macro gate reads it — the member's simple name plus the
	 * RECEIVER's, when the call is written qualified. Null when `node` is not a call, or
	 * when its callee is an expression rather than a name (the gate has nothing to ask
	 * about a computed target, and such a call cannot be a macro invocation).
	 *
	 * The receiver is carried because the two spellings of the same import bind DIFFERENT
	 * names: `import pkg.Lang.t` binds `t`, `import pkg.Lang` binds `Lang`, and the gate's
	 * unresolved-target refusal asks whether the caller's own imports could route the call
	 * somewhere the index cannot see.
	 */
	private static function calleeNameOf(seams: Seams, node: QueryNode): Null<CallRef> {
		if (node.kind != seams.callKind || node.children.length == 0) return null;
		final callee: QueryNode = node.children[0];
		final name: Null<String> = callee.name;
		if (name == null) return null;
		if (callee.kind == seams.identKind) return { name: name, receiver: null, qualified: false };
		if (callee.kind != seams.fieldAccessKind || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind == seams.identKind || receiver.kind == seams.fieldAccessKind
			? {
				name: name,
				receiver: receiver.name,
				qualified: receiver.kind == seams.fieldAccessKind
			}
			: {
				name: name,
				receiver: null,
				qualified: false
			};
	}

	/**
	 * The canonical segmentation of `node`, or null when it is not a candidate, is
	 * already canonical, or cannot be improved.
	 *
	 * Arithmetic first — a greedy left-to-right fill against `lineWidth` minus the
	 * construct's start column — and then VERIFIED through the writer (`settle`), which
	 * is what decides whether the plan actually fits.
	 *
	 * Two refusals close the loop. A plan with AS MANY groups as the source, or more, is
	 * refused unless the source is genuinely over-long — only a strict MERGE runs
	 * unconditionally; and a plan that still overflows while being no narrower than the
	 * source it replaces is refused outright — the model's assumption (a group boundary
	 * is a place the writer may break) does not hold there, so the re-segmentation buys
	 * nothing and would be proposed again against its own output forever.
	 *
	 * A writer that throws (`ParseError`, `CommentLossException`) or declines leaves the
	 * arithmetic plan standing rather than dropping the finding: the arithmetic is the
	 * same measurement the writer would make for a construct that stays on one line.
	 *
	 * Reporting compares BOUNDARIES (segment indices) against the partition the SOURCE
	 * already has, never rendered text against source text — a multi-line chain's source
	 * carries the writer's line breaks and a text comparison would flag it forever.
	 */
	private static function plan(ctx: PlanContext, node: QueryNode): Null<PlannedFold> {
		final found: Null<Decomposition> = decompose(ctx, node);
		if (found == null) return null;
		final decomposition: Decomposition = found;
		final current: Int = decomposition.current.length;
		final budget: Int = ctx.metrics.lineWidth - budgetBase(ctx, decomposition.span) - GROUP_JOIN.length + 1;
		final first: Null<Array<Int>> = fill(ctx, decomposition.segments, budget, decomposition.startsBare);
		if (first == null) return null;
		final planned: Null<Plan> = unwrapped(ctx, decomposition, first, budget);
		if (planned == null) return null;
		final filled: Array<Int> = planned.groups;
		// The back-off below only ever ADDS groups, so a plan that does not strictly
		// MERGE can be refused here without paying for a single writer render.
		if (filled.length >= current && !overLong(ctx, decomposition.span)) return null;
		if (sameBoundaries(filled, decomposition.current)) return null;
		final result: Null<Settled> = settle(ctx, decomposition, filled, planned.budget);
		if (result == null) return null;
		final settled: Settled = result;
		if (sameBoundaries(settled.groups, decomposition.current)) return null;
		final groups: Int = settled.groups.length;
		if (groups >= current && !overLong(ctx, decomposition.span)) return null;
		final width: Null<Int> = settled.width;
		if (width != null && width > ctx.metrics.lineWidth && width >= sourceMaxWidth(ctx, decomposition.span)) return null;
		return {
			span: decomposition.span,
			text: settled.text,
			groups: groups,
			message: messageFor(groups, current)
		};
	}

	/**
	 * `filled` re-planned against the construct's OWN start column when the optimistic
	 * budget said it fits and the SOURCE says it does not.
	 *
	 * `budgetBase` measures from the continuation column on purpose — a construct the
	 * writer wraps onto its own line is laid out there, and pricing it at its source
	 * column would shred it. But when the fill reproduces the source's own boundaries and
	 * the source line is over-long anyway, that optimism has been REFUTED: the writer did
	 * not move this construct, because there was nothing to move it away from. The retry
	 * prices it where it actually sits, and whatever it proposes still goes through the
	 * writer verification below.
	 *
	 * Without it a construct that fits at the continuation column and overflows at its
	 * own is never re-segmented and never even measured — `settle` only runs for a plan
	 * that changes something, so the arithmetic's own optimism is what closes the case.
	 */
	private static function unwrapped(ctx: PlanContext, decomposition: Decomposition, filled: Array<Int>, budget: Int): Null<Plan> {
		if (!sameBoundaries(filled, decomposition.current) || !overLong(ctx, decomposition.span)) return { groups: filled, budget: budget };
		final own: Int = ctx.metrics.lineWidth
			- columnWidth(ctx, lineStartOf(ctx.source, decomposition.span.from), decomposition.span.from) - GROUP_JOIN.length + 1;
		if (own >= budget) return { groups: filled, budget: budget };
		final refilled: Null<Array<Int>> = fill(ctx, decomposition.segments, own, decomposition.startsBare);
		return refilled == null ? null : { groups: refilled, budget: own };
	}

	/**
	 * `filled` verified through the writer and, while it still overflows, re-filled
	 * against a narrower budget — bounded to `MAX_BACKOFF_PASSES` and abandoned as soon
	 * as a narrower budget stops making the RESULT narrower, which means the overflowing
	 * line is one the writer will not break and shrinking further only shreds the
	 * construct.
	 *
	 * A null `width` means the writer DECLINED, not that it was never asked: the
	 * arithmetic estimate is never trusted on its own. It cannot be — it models the
	 * construct's line as the construct alone, while the writer keeps whatever else the
	 * line carries (a trailing comment, a following operand it will not break before) on
	 * it, and an estimate that ignores those was measured making a real TM site's line
	 * 190 columns wide while predicting 115.
	 */
	private static function settle(ctx: PlanContext, decomposition: Decomposition, filled: Array<Int>, startBudget: Int): Null<Settled> {
		final first: Null<Rendered> = joinGroups(ctx, decomposition.segments, filled);
		if (first == null) return null;
		final span: Span = decomposition.span;
		var budget: Int = startBudget;
		var groups: Array<Int> = filled;
		var rendered: Rendered = first;
		var width: Null<Int> = renderedWidth(ctx, span, rendered.text);
		var pass: Int = 0;
		while (pass < MAX_BACKOFF_PASSES && width != null && width > ctx.metrics.lineWidth) {
			final reduced: Int = Std.int(Math.min(budget - (width - ctx.metrics.lineWidth), rendered.widest - 1));
			if (reduced <= 0) break;
			final next: Null<Array<Int>> = fill(ctx, decomposition.segments, reduced, decomposition.startsBare);
			if (next == null || sameBoundaries(next, groups)) break;
			final nextRendered: Null<Rendered> = joinGroups(ctx, decomposition.segments, next);
			if (nextRendered == null) break;
			final nextWidth: Null<Int> = renderedWidth(ctx, span, nextRendered.text);
			if (nextWidth == null || nextWidth >= width) break;
			budget = reduced;
			groups = next;
			rendered = nextRendered;
			width = nextWidth;
			pass++;
		}
		return { groups: groups, text: rendered.text, width: width };
	}

	/** The flat segment list plus the SOURCE's own group boundaries, or null when `node` is not a candidate. */
	private static function decompose(ctx: PlanContext, node: QueryNode): Null<Decomposition> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		return node.kind == ctx.seams.concatKind ? chainDecomposition(ctx, node, span) : literalDecomposition(ctx, node, span);
	}

	/**
	 * A standalone string literal decomposes into its own fragments as ONE current
	 * group — the SPLIT arm's input. A literal with a single fragment can only ever
	 * plan back to itself, so it is rejected up front (that is the majority of every
	 * literal in a tree, and it keeps the walk cheap).
	 */
	private static function literalDecomposition(ctx: PlanContext, node: QueryNode, span: Span): Null<Decomposition> {
		if (!ctx.seams.stringLiteralKinds.contains(node.kind)) return null;
		final segments: Null<Array<ConcatSegment>> = ctx.seams.support.segmentsOf(node, ctx.source);
		if (segments == null || segments.length < 2) return null;
		return {
			segments: segments,
			current: [segments.length],
			span: span,
			startsBare: false
		};
	}

	/**
	 * A `+` chain this rule CLAIMS (`claim`) decomposes operand by operand, each
	 * operand contributing one current group. Three gates live here rather than in the
	 * claim, because all three are about DECOMPOSING an already-claimed chain: an
	 * interior operand with no source span, an operand the seam cannot classify as an
	 * expression, and a literal-kind operand the seam cannot decompose — treating that
	 * last one as an expression would nest a whole literal inside a `${ … }` block.
	 *
	 * The NUMERIC HEAD is the load-bearing part: `+` is left-associative, so the
	 * operands BEFORE the first literal are still arithmetic (`1 + 2 + ' items'` is
	 * `"3 items"`, not `"12 items"`). Two or more of them collapse into ONE segment
	 * spanning their source verbatim, which both preserves the arithmetic and makes
	 * the leading region unsplittable by construction.
	 */
	private static function chainDecomposition(ctx: PlanContext, node: QueryNode, span: Span): Null<Decomposition> {
		final claimed: Null<Chain> = claim(node, ctx.source, ctx.seams.concatKind, ctx.seams.stringLiteralKinds);
		if (claimed == null) return null;
		final operands: Array<QueryNode> = claimed.operands;
		final firstLitIdx: Int = claimed.firstLiteral;
		final segments: Array<ConcatSegment> = [];
		final current: Array<Int> = [];
		if (firstLitIdx == 1) {
			final head: Null<ConcatSegment> = expressionSegmentOf(ctx, operands[0]);
			if (head == null) return null;
			segments.push(head);
			current.push(segments.length);
		} else if (firstLitIdx > 1) {
			final headEnd: Null<Span> = operands[firstLitIdx - 1].span;
			if (headEnd == null) return null;
			segments.push(SegExpr(ctx.source.substring(claimed.from, headEnd.to), false));
			current.push(segments.length);
		}
		for (i in firstLitIdx ... operands.length) {
			final operand: QueryNode = operands[i];
			if (ctx.seams.stringLiteralKinds.contains(operand.kind)) {
				final segs: Null<Array<ConcatSegment>> = ctx.seams.support.segmentsOf(operand, ctx.source);
				if (segs == null) return null;
				for (s in segs) segments.push(s);
			} else {
				final seg: Null<ConcatSegment> = expressionSegmentOf(ctx, operand);
				if (seg == null) return null;
				segments.push(seg);
			}
			current.push(segments.length);
		}
		// A head segment was emitted exactly when a bare operand precedes the first
		// literal — the fact `plan` cannot recover from the segment list alone.
		return {
			segments: segments,
			current: current,
			span: span,
			startsBare: firstLitIdx >= 1
		};
	}

	/**
	 * The chain rooted at `node` when this rule claims it, else null — the ONE place
	 * the claim is decided, asked by `chainDecomposition` for its own work and by
	 * `ownsChain` for `prefer-interpolation`'s hand-off (whose doc records what the
	 * claim does NOT cover).
	 *
	 * Each refusal has its own reason:
	 *
	 *  - fewer than two operands, or the FIRST or LAST operand carrying no source
	 *    span: not a chain this rule can re-render.
	 *  - NO string-literal operand (`a + b`, `1 + 2`, `Std.string(a) + Std.string(b)`)
	 *    — the chain is not a string concatenation at all and merging it would change
	 *    arithmetic into text.
	 *  - An interior COMMENT between operands — the merge would swallow it, and a
	 *    check may never delete an author's comment silently.
	 */
	private static function claim(node: QueryNode, source: String, concatKind: String, stringLiteralKinds: Array<String>): Null<Chain> {
		final operands: Array<QueryNode> = flatten(node, concatKind);
		if (operands.length < 2) return null;
		final firstSpan: Null<Span> = operands[0].span;
		final lastSpan: Null<Span> = operands[operands.length - 1].span;
		if (firstSpan == null || lastSpan == null) return null;
		var firstLiteral: Int = -1;
		for (i in 0...operands.length) if (stringLiteralKinds.contains(operands[i].kind)) {
			firstLiteral = i;
			break;
		}
		return firstLiteral == -1 || chainHasComment(source, firstSpan.from, lastSpan.to) ? null : {
			operands: operands,
			from: firstSpan.from,
			firstLiteral: firstLiteral
		};
	}

	/** The operands of the maximal left-associative `concatKind` chain rooted at `node`, in source order. */
	private static function flatten(node: QueryNode, concatKind: String): Array<QueryNode> {
		final operands: Array<QueryNode> = [];
		var cur: QueryNode = node;
		while (cur.kind == concatKind && cur.children.length == 2) {
			operands.unshift(cur.children[1]);
			cur = cur.children[0];
		}
		operands.unshift(cur);
		return operands;
	}

	/** One expression operand as a segment, with a `Std.string(x)` wrapper peeled off first (interpolation already converts). */
	private static function expressionSegmentOf(ctx: PlanContext, node: QueryNode): Null<ConcatSegment> {
		return ctx.seams.support.expressionSegment(unwrapStdString(ctx, node), ctx.source);
	}

	/** `Std.string(arg)`'s argument, or `node` unchanged — purely structural, matched on the receiver / member NAMES. */
	private static function unwrapStdString(ctx: PlanContext, node: QueryNode): QueryNode {
		final callKind: Null<String> = ctx.seams.callKind;
		final fieldAccessKind: Null<String> = ctx.seams.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null) return node;
		if (node.kind != callKind || node.children.length != 2) return node;
		final callee: QueryNode = node.children[0];
		if (callee.kind != fieldAccessKind || callee.name != 'string' || callee.children.length != 1) return node;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind != ctx.seams.identKind || receiver.name != 'Std' ? node : node.children[1];
	}

	/**
	 * Greedy left-to-right fill: each group takes as many further segments as it can
	 * render within `budget`. A single segment wider than the budget forms its own
	 * group and is accepted as-is — literal TEXT is never split at word boundaries,
	 * only at segment seams. A segment that cannot sit inside a `${ … }` block (see
	 * `ConcatSegment.SegExpr`) ends the group it would have joined, so it lands in a
	 * group of its own and renders bare.
	 */
	private static function fill(ctx: PlanContext, segments: Array<ConcatSegment>, budget: Int, sourceStartsBare: Bool): Null<Array<Int>> {
		final ends: Array<Int> = [];
		var i: Int = 0;
		while (i < segments.length) {
			var best: Int = i + 1;
			var j: Int = i + 1;
			while (j < segments.length) {
				final candidate: Null<String> = renderRange(ctx, segments, i, j + 1);
				if (candidate == null || candidate.length > budget) break;
				best = j + 1;
				j++;
			}
			if (renderRange(ctx, segments, i, best) == null) return null;
			ends.push(best);
			i = best;
		}
		return mergeLeadingBares(ctx, segments, ends, sourceStartsBare);
	}

	/**
	 * The HARD gate on the FIRST group. A lone expression group is emitted BARE,
	 * and a bare leading operand is only ever admissible when the SOURCE already
	 * opened with one:
	 *
	 *  - semantically, `+` is left-associative, so two bare operands in front of
	 *    anything that renders as a string are still arithmetic — splitting
	 *    `'${1}${2} items'` into `1 + 2 + ' items'` yields `"3 items"`;
	 *  - and in readability terms, pulling the leading `${ … }` out of a literal
	 *    (`'${a + b}: …'` into `(a + b) + ': …'`) trades the construct's obvious
	 *    string-ness for a parenthesised head, which real code reads worse.
	 *
	 * Only the LEADING pair can offend — the first group that renders as a string
	 * makes every later `+` a concatenation — so at most one merge is ever needed,
	 * and a merge the seam cannot render abandons the plan rather than emitting
	 * the unsafe split.
	 */
	private static function mergeLeadingBares(
		ctx: PlanContext, segments: Array<ConcatSegment>, ends: Array<Int>, sourceStartsBare: Bool
	): Null<Array<Int>> {
		if (ends.length < 2 || !isBareGroup(segments, 0, ends[0])) return ends;
		if (sourceStartsBare && !isBareGroup(segments, ends[0], ends[1])) return ends;
		final merged: Array<Int> = ends.copy();
		merged.splice(0, 1);
		return renderRange(ctx, segments, 0, merged[0]) == null ? null : merged;
	}

	/** Whether the group `[from, to)` is a lone expression segment — the one shape emitted without quotes. */
	private static function isBareGroup(segments: Array<ConcatSegment>, from: Int, to: Int): Bool {
		return to - from == 1 && !segments[from].match(SegText(_, _));
	}

	/** One group's text: a lone expression segment renders bare, everything else renders as one literal. */
	private static function renderRange(ctx: PlanContext, segments: Array<ConcatSegment>, from: Int, to: Int): Null<String> {
		if (to - from == 1) {
			final bare: Null<String> = ctx.seams.support.renderBare(segments[from]);
			if (bare != null) return bare;
		}
		return ctx.seams.support.renderGroup(segments.slice(from, to));
	}

	/**
	 * The whole construct — every group rendered and joined with `+` — plus the widest
	 * single group, the number the back-off shrinks against. Null when a group cannot
	 * be rendered.
	 */
	private static function joinGroups(ctx: PlanContext, segments: Array<ConcatSegment>, ends: Array<Int>): Null<Rendered> {
		final parts: Array<String> = [];
		var widest: Int = 0;
		var from: Int = 0;
		for (end in ends) {
			final part: Null<String> = renderRange(ctx, segments, from, end);
			if (part == null) return null;
			if (part.length > widest) widest = part.length;
			parts.push(part);
			from = end;
		}
		return { text: parts.join(GROUP_JOIN), widest: widest };
	}

	/** Whether two group partitions cut the segment list at the same places. */
	private static function sameBoundaries(a: Array<Int>, b: Array<Int>): Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	/**
	 * The column the arithmetic pass assumes a group starts at: the SMALLER of
	 * where the construct itself starts and one indent step past its line's own
	 * indent — the column a wrapped continuation operand lands at. Taking the
	 * smaller keeps the estimate OPTIMISTIC on purpose: a construct that starts
	 * deep into a line (`final r: String = 'a' + b`) is laid out by the writer at
	 * the continuation indent, not at its source column, and an estimate built on
	 * the source column would cut such a chain into far more segments than the
	 * writer needs. Over-optimism is corrected by measurement (`renderedWidth`);
	 * over-pessimism would not be, since the back-off only ever narrows.
	 */
	private static function budgetBase(ctx: PlanContext, span: Span): Int {
		final lineStart: Int = lineStartOf(ctx.source, span.from);
		var indent: Int = lineStart;
		while (indent < ctx.source.length && isBlank(StringTools.fastCodeAt(ctx.source, indent))) indent++;
		final continuation: Int = columnWidth(ctx, lineStart, indent) + ctx.metrics.indentWidth;
		final own: Int = columnWidth(ctx, lineStart, span.from);
		return own < continuation ? own : continuation;
	}

	/**
	 * Whether any SOURCE line the construct sits on already exceeds `lineWidth` —
	 * the precondition on the SPLIT direction. A construct whose lines all fit is
	 * left alone no matter what the arithmetic says: re-cutting a chain the writer
	 * already lays out within the limit trades a readable two-operand
	 * concatenation for four, which is strictly worse.
	 */
	private static function overLong(ctx: PlanContext, span: Span): Bool {
		return sourceMaxWidth(ctx, span) > ctx.metrics.lineWidth;
	}

	/**
	 * The widest SOURCE line the construct sits on — the layout it must beat. The
	 * SOURCE is the right baseline because a writer-canonical file already IS the
	 * writer's own layout for that construct.
	 */
	private static function sourceMaxWidth(ctx: PlanContext, span: Span): Int {
		final source: String = ctx.source;
		var lineStart: Int = lineStartOf(source, span.from);
		var widest: Int = 0;
		while (lineStart <= source.length) {
			final lineEnd: Int = lineEndOf(source, lineStart);
			final width: Int = displayWidth(source.substring(lineStart, lineEnd), ctx.metrics.indentWidth);
			if (width > widest) widest = width;
			if (lineEnd >= source.length || lineEnd >= span.to) return widest;
			lineStart = lineEnd + 1;
		}
		return widest;
	}

	/** The offset just after the line break preceding `pos` (0 when `pos` is on the first line). */
	private static function lineStartOf(source: String, pos: Int): Int {
		return pos == 0 ? 0 : source.lastIndexOf('\n', pos - 1) + 1;
	}

	/** The offset of the line break that ends `pos`'s line, or the source length when none follows. */
	private static function lineEndOf(source: String, pos: Int): Int {
		final nextBreak: Int = source.indexOf('\n', pos);
		return nextBreak == -1 ? source.length : nextBreak;
	}

	/** The column width of `source[from...to)`, counting a tab as `indentWidth` columns. */
	private static inline function columnWidth(ctx: PlanContext, from: Int, to: Int): Int {
		return CheckScan.displayColumn(ctx.source, from, to, ctx.metrics.indentWidth);
	}

	/** Whether `code` is a space or a tab. */
	private static inline function isBlank(code: Int): Bool {
		return code == ' '.code || code == '\t'.code;
	}

	/**
	 * The TRUE rendered width of `candidate` spliced in at `span`: render both the
	 * spliced and the unchanged text through the writer, drop the leading and trailing
	 * lines the two share, and take the widest of what is left. Null when either render
	 * is unavailable — layout policy belongs to the writer, so an unmeasurable candidate
	 * falls back to arithmetic rather than to a guess.
	 *
	 * What gets rendered is the enclosing MEMBER wrapped in a synthetic one-member class
	 * (`PlanContext.scopeFor`) whenever that reproduces the member's real indent depth —
	 * the writer's wrapping is a per-line decision, so a member laid out one indent deep
	 * inside `class C { … }` lays out exactly as it does inside its own type, and the
	 * round trip costs a few dozen lines instead of the whole file. That is this rule's
	 * dominant cost: without it a 2000-line file pays a full parse-and-write per
	 * candidate. A member the scope cannot reproduce falls back to splicing the whole
	 * file, which is always correct and always slower.
	 */
	private static function renderedWidth(ctx: PlanContext, span: Span, candidate: String): Null<Int> {
		final scope: Null<MemberScope> = ctx.scopeFor(span);

		if (scope != null) {
			final source: String = ctx.source;
			final spliced: String = scope.head + source.substring(scope.from, span.from) + candidate + source.substring(span.to, scope.to)
				+ scope.tail;
			return widestDiffering(scope.baseline, ctx.write(spliced), ctx.metrics.indentWidth);
		}
		final original: Null<Array<String>> = ctx.originalLines();
		if (original == null) return null;
		return widestDiffering(
			original, ctx.write(ctx.source.substring(0, span.from) + candidate + ctx.source.substring(span.to)), ctx.metrics.indentWidth
		);
	}

	/**
	 * The widest line of `written` once the leading and trailing lines it SHARES with
	 * `original` are dropped — the region the splice actually changed. Null when the
	 * writer declined to render the candidate.
	 */
	private static function widestDiffering(original: Array<String>, written: Null<String>, indentWidth: Int): Null<Int> {
		if (written == null) return null;
		final lines: Array<String> = written.split('\n');
		var prefix: Int = 0;
		while (prefix < lines.length && prefix < original.length && lines[prefix] == original[prefix]) prefix++;
		var suffix: Int = 0;
		while (
			suffix < lines.length - prefix && suffix < original.length - prefix
			&& lines[lines.length - 1 - suffix] == original[original.length - 1 - suffix]
		)
			suffix++;
		var widest: Int = 0;
		for (i in prefix ... lines.length - suffix) {
			final width: Int = displayWidth(lines[i], indentWidth);
			if (width > widest) widest = width;
		}
		return widest;
	}

	/** `line`'s width in columns, counting a tab as `indentWidth`. */
	private static inline function displayWidth(line: String, indentWidth: Int): Int {
		return CheckScan.displayColumn(line, 0, line.length, indentWidth);
	}

	/** The finding text, naming the direction the segmentation moves in. */
	private static function messageFor(planned: Int, current: Int): String {
		if (planned < current) return 'these string concatenation segments can be merged';
		return planned > current
			? 'this string literal can be split at its seams to fit the line width'
			: 'these string concatenation segments can be re-cut to fit the line width';
	}

	/**
	 * Whether the source range `[from, to)` carries a `//` or `/*` comment OUTSIDE
	 * any string literal — a comment between chain operands would be lost by the
	 * merge, so such a chain is left alone. String bodies are skipped (respecting
	 * `\` escapes) so a `'http://x'` literal does not read as a comment.
	 */
	private static function chainHasComment(source: String, from: Int, to: Int): Bool {
		var i: Int = from;
		while (i < to) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == "'".code || c == '"'.code) {
				i++;
				while (i < to) {
					final d: Int = StringTools.fastCodeAt(source, i);
					if (d == '\\'.code) {
						i += 2;
					} else if (d == c) {
						i++;
						break;
					} else {
						i++;
					}
				}
			} else if (c == '/'.code && i + 1 < to) {
				final n: Int = StringTools.fastCodeAt(source, i + 1);
				if (n == '/'.code || n == '*'.code) return true;
				i++;
			} else {
				i++;
			}
		}
		return false;
	}

	/** The per-file planning context, or null when the grammar's writer declares no layout metrics. */
	private static function contextFor(plugin: GrammarPlugin, seams: Seams, source: String, optsJson: Null<String>): Null<PlanContext> {
		final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(optsJson);
		return metrics == null ? null : new PlanContext(plugin, seams, source, optsJson, metrics);
	}

	/** The seam kinds both passes read, or null when the grammar declares no string-concatenation / literal shape. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return null;
		final shape: RefShape = plugin.refShape();
		final stringLiteralKinds: Array<String> = shape.stringLiteralKinds ?? [];
		if (stringLiteralKinds.length == 0) return null;
		final concatKind: String = support.concatKind();
		return {
			support: support,
			concatKind: concatKind,
			stringLiteralKinds: stringLiteralKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			metaKinds: plugin.metaShape().metaKinds,
			callKind: shape.callKind,
			fieldAccessKind: shape.fieldAccessKind,
			identKind: shape.identKind,
			patternKind: shape.plainCasePatternKind,
			paramKinds: shape.paramKinds ?? [],
			enumAbstractDeclKind: shape.enumAbstractDeclKind,
			enumAbstractMetaName: shape.enumAbstractMetaName,
			conditionalKind: shape.conditionalMemberKind,
			inlineKind: shape.inlineModifierKind,
			modifierKinds: CheckScan.modifierKinds(shape),
			functionKinds: shape.functionKinds ?? [],
			candidateKinds: [concatKind].concat(stringLiteralKinds)
		};
	}

}

/**
 * Which enclosing calls forbid re-segmenting their arguments. A `macro` function
 * receives its arguments as unevaluated SYNTAX, and one that pattern-matches a string
 * constant (`EConst(CString)`) sees a concatenation as a different expression
 * altogether — silently, since the match simply stops firing. No structural check can
 * tell whether a given macro folds one, so the default is to refuse the fix and report
 * the construct with the reason.
 *
 * A call target is named in `apqlint.json`'s `concatFoldingMacros` by its QUALIFIED path
 * (`pkg.Type.member`), by any dotted SUFFIX of it (`Type.member`, `member`), and listing
 * it is a claim about that target's implementation — that it folds an `OpAdd` chain of
 * constants before it reads the string. The list comes from the CALLER's own config, so
 * a run spanning several projects honours each one's claim rather than the first file's.
 *
 * TWO refusals, and the second is the one that keeps the gate honest:
 *
 *  - a name some `macro` member declares, unless EVERY such declaration is listed.
 *    Matching is by SIMPLE NAME on purpose: resolving a call target exactly needs the
 *    whole import / static-extension picture, and every gap in that resolution would
 *    open the fix on a macro argument. A same-named ordinary function is refused along
 *    with the macro — a false NEGATIVE, which costs a fix nobody was promised.
 *  - a call whose TARGET TYPE the index does not carry. The index covers the resolution
 *    scope, and that scope is bounded by the INVOCATION: linting one FILE of a project
 *    cannot see a macro declared in another, so reading "no macro declares this name" as
 *    "not a macro" made `--fix` answer differently depending on how the linter was
 *    called — and the narrow answer is the dangerous one.
 *
 *    The question is asked at TYPE granularity, never by member name. A name test cannot
 *    answer it: the std alone declares thirteen members called `t` (anonymous-structure
 *    fields in `haxe.macro.Type` among them), so "something declares this name" was true
 *    for the very call the refusal exists for, and the hole stayed open in every real CLI
 *    run. What the caller's source DOES say is which type it means — through the import
 *    that binds the call (`import pkg.Lang.t`, `import pkg.Lang`, a wildcard, a `using`)
 *    or through a written qualified receiver — and whether the index carries that type is
 *    a question with one answer. A call the file imports nothing for and writes no
 *    receiver on is local, inherited or global, and no import can make it a macro.
 *
 *    One consequence is worth stating: a WILDCARD or a `using` whose own target the index
 *    cannot see binds every name in the file, so every unresolved call in it is refused.
 *    That is the honest answer — such an import genuinely can route any call into the
 *    package it names — and it costs nothing on a whole-project run, where the package is
 *    in scope. Measured: zero refusals over this repository's own 654 files, four over a
 *    802-file application tree, all four the real macro.
 */
@:nullSafety(Strict)
private class MacroGate {

	private final _macros: MacroIndex;
	private final _whitelist: Array<String>;
	private final _file: String;

	public function new(macros: MacroIndex, whitelist: Array<String>, file: String) {
		_macros = macros;
		_whitelist = whitelist;
		_file = file;
	}

	/**
	 * Whether a plan of `groups` groups sitting inside the call stack `calls` must stay
	 * report-only. A plan that renders as ONE group is never refused: it is a lone
	 * literal, the very shape a constant-matching macro expects, and reaching it can only
	 * remove `+` operators the argument already had.
	 */
	public function blocks(calls: Array<CallRef>, groups: Int): Bool {
		if (groups < 2) return false;
		for (call in calls) if (blocksCall(call)) return true;
		return false;
	}

	/**
	 * Whether `call` refuses the rewrite — the two refusals in the type doc, in order.
	 *
	 * The whitelist is consulted against every spelling of the target the call site can
	 * supply, because which one exists depends on what the index could resolve: the bare
	 * name, the resolved macro path, the written `Receiver.member`, and the binding
	 * import's path with the member appended.
	 */
	private function blocksCall(call: CallRef): Bool {
		if (whitelisted(call.name)) return false;
		final declarations: Null<Array<String>> = _macros.macroPathsOf(call.name);
		if (declarations != null) {
			for (path in declarations) if (!whitelisted(path)) return true;
			return false;
		}
		final receiver: Null<String> = call.receiver;
		if (receiver != null && (_macros.declaresType(receiver) || whitelisted('$receiver.${call.name}'))) return false;
		final binding: Null<String> = _macros.unresolvedBinding(_file, receiver ?? call.name);
		if (binding != null) return !whitelisted('$binding.${call.name}');
		// A WRITTEN qualified receiver names a type path directly, so it refuses on its own
		// evidence: `pkg.Lang.t(…)` needs no import at all, and nothing else in the file
		// says where `Lang` lives.
		return call.qualified;
	}

	/**
	 * Whether `path` is listed. Matching is by dotted SUFFIX in BOTH directions, because
	 * the two sides name the same target at different lengths and neither side chooses:
	 * a project writes the fully qualified `pkg.Lang.t`, while what the gate holds is
	 * whatever the CALL SITE said — the resolved `pkg.Lang.t` for a macro the index
	 * carries, the import's `m.Lang`, or a written `Lang.t`. Comparing one direction only
	 * meant the entry that worked depended on the invocation's scope.
	 */
	private function whitelisted(path: String): Bool {
		for (entry in _whitelist) if (entry == path || StringTools.endsWith(entry, '.$path') || StringTools.endsWith(path, '.$entry'))
			return true;
		return false;
	}

}

/**
 * The run's macro knowledge, built ONCE and lazily: the qualified paths of every `macro`
 * member by simple name, plus the index itself for the TYPE questions the second refusal
 * asks. Shared across the run's per-file gates, since the index is the expensive part and
 * the whitelist is not, and demanded only once a construct has actually planned, which on
 * a tree with no findings is never.
 */
@:nullSafety(Strict)
private class MacroIndex {

	private final _plugin: GrammarPlugin;
	private final _files: Array<{ file: String, source: String }>;

	private var _index: Null<SymbolIndex> = null;
	private var _macros: Null<Map<String, Array<String>>> = null;

	public function new(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>) {
		_plugin = plugin;
		_files = files;
	}

	/** The qualified paths of the `macro` members named `name`, or null when none is. */
	public function macroPathsOf(name: String): Null<Array<String>> {
		build();
		final macros: Null<Map<String, Array<String>>> = _macros;
		if (macros == null) throw new Exception('fold-adjacent-string-literals: the macro index was read before it was built');
		return macros[name];
	}

	/** Whether the index carries a TYPE declaration named `name`. */
	public function declaresType(name: String): Bool {
		build();
		return index().declaringFiles(name).length > 0;
	}

	/**
	 * The raw path of the first import of `file` that BINDS `name` and whose own target
	 * type the index does NOT carry, or null when nothing binds it or what does is in
	 * scope. That is the question "could this file's imports route this call to a
	 * declaration the resolution scope cannot see".
	 *
	 * Binding is per import KIND, and the two wildcard forms are why the kind has to be
	 * read rather than the path: a plain import binds its last segment, an alias binds the
	 * alias, and a WILDCARD or a `using` binds everything — the first because it pulls a
	 * package's types or a type's statics in under their own names, the second because a
	 * static extension routes by receiver TYPE and can answer any method call in the file.
	 */
	public function unresolvedBinding(file: String, name: String): Null<String> {
		build();
		final info: Null<FileInfo> = index().fileInfo(file);
		if (info == null) return null;
		// The wildcard's own `*` is dropped from the answer: the caller appends the member
		// name to it to probe the whitelist, and `m.Lang.*.t` names nothing.
		for (imported in info.imports) if (binds(imported, name) && !carriesTarget(imported.raw))
			return StringTools.endsWith(imported.raw, '.*') ? imported.raw.substr(0, imported.raw.length - 2) : imported.raw;
		return null;
	}

	/** Whether `imported` puts `name` in scope — see the kind-by-kind reasoning on `unresolvedBinding`. */
	private function binds(imported: ImportInfo, name: String): Bool {
		return switch imported.kind {
			case ImportKind.Alias: imported.alias == name;
			case ImportKind.Wild, ImportKind.Using: true;
			case _: lastSegment(imported.raw) == name;
		}
	}

	/**
	 * Whether the index carries the TYPE an import path names. WHICH segment that is
	 * cannot be known from the path alone — `pkg.Lang.t` is a member of `Lang`, `pkg.a.Lang`
	 * is a type in `pkg.a` — so both trailing segments are tried, a wildcard's `*` dropped
	 * first. Trying too many is the safe direction: it can only conclude the target IS in
	 * scope, which is the answer that allows a fix the caller was going to get anyway.
	 */
	private function carriesTarget(raw: String): Bool {
		final segments: Array<String> = raw.split('.');
		if (segments[segments.length - 1] == '*') segments.pop();
		for (i in 0...segments.length) {
			if (i >= 2) break;
			if (declaresType(segments[segments.length - 1 - i])) return true;
		}
		return false;
	}

	/** The resolved index, valid after `build`. */
	private function index(): SymbolIndex {
		final built: Null<SymbolIndex> = _index;
		if (built == null) throw new Exception('fold-adjacent-string-literals: the macro index was read before it was built');
		return built;
	}

	/** Resolve the index on first demand and project both maps out of it. */
	private function build(): Void {
		if (_macros != null) return;
		final index: SymbolIndex = RefactorSupport.resolutionIndexOf(_plugin) ?? SymbolIndex.build(_files, _plugin);
		_index = index;
		final macros: Map<String, Array<String>> = [];
		for (info in index.allFiles()) for (type in info.types) for (member in type.members) if (member.isMacro) {
			final scoped: String = '${type.name}.${member.name}';
			final paths: Array<String> = macros[member.name] ?? [];
			paths.push(info.pkg == '' ? scoped : '${info.pkg}.$scoped');
			macros[member.name] = paths;
		}
		_macros = macros;
	}

	/** `path`'s last dot-separated segment. */
	private static function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot == -1 ? path : path.substr(dot + 1);
	}

}

/**
 * One enclosing call as the macro gate reads it: the target member's simple name, plus
 * the immediate RECEIVER's when the call is written qualified — the last segment of a
 * dotted path (`pkg.Lang.t(…)` gives `Lang`), null for a bare `f(…)`.
 *
 * The receiver is carried because it is the caller's own statement of which TYPE it
 * means, and the gate's second refusal asks whether the index carries that type.
 */
private typedef CallRef = {
	final name: String;
	final receiver: Null<String>;
	final qualified: Bool;
};

/** The seam kinds `FoldStringLiterals` resolves once per run and reads in both passes. */
private typedef Seams = {
	final support: StringFoldSupport;
	final concatKind: String;
	final stringLiteralKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final metaKinds: Array<String>;
	final callKind: Null<String>;
	final fieldAccessKind: Null<String>;
	final identKind: String;

	/** The `case` PATTERN host kind — a position where a concatenation is not legal syntax. */
	final patternKind: Null<String>;

	/** The parameter kinds, whose default value must be a compile-time constant. */
	final paramKinds: Array<String>;

	/** The enum-abstract declaration kind, whose VALUE members are read by their expression shape. */
	final enumAbstractDeclKind: Null<String>;

	/** The annotation NAME that makes an ordinary abstract an enum abstract — the deprecated spelling a kind test cannot see. */
	final enumAbstractMetaName: Null<String>;

	/** The conditional-compilation member host, which INHERITS the value region it sits in. */
	final conditionalKind: Null<String>;

	/** The `inline` modifier sibling — an inlined field's value is a compile-time constant at every use site. */
	final inlineKind: Null<String>;

	/** Every kind that projects as a leading MODIFIER — what a declaration's modifier RUN is made of. */
	final modifierKinds: Array<String>;

	/** The function-member kinds — what an enum-abstract declares that IS ordinary code. */
	final functionKinds: Array<String>;

	/** `concatKind` plus the literal kinds — the node kinds `fix` re-finds a violation's span among. */
	final candidateKinds: Array<String>;
};

/** One construct flattened for planning: its segments, the SOURCE's own group boundaries, and the span to replace. */
private typedef Decomposition = {
	final segments: Array<ConcatSegment>;
	final current: Array<Int>;
	final span: Span;

	/**
	 * Whether the SOURCE opens with a BARE expression operand — the one shape whose
	 * plan may keep a bare first group (see `mergeLeadingBares`). Carried from the
	 * decomposition, which knows it as a fact (`chainDecomposition` emitted a head
	 * segment), because re-deriving it from the segment list cannot tell a bare
	 * operand from a single-fragment interpolated literal (`'$x' + …`).
	 */
	final startsBare: Bool;
};

/** A construct's canonical form: the span to replace, its replacement text, and the finding message. */
private typedef PlannedFold = {
	final span: Span;
	final text: String;

	/** How many `+` operands the plan renders as — 1 means a single literal, the shape no gate refuses. */
	final groups: Int;
	final message: String;
};

/**
 * A `+` chain `claim` accepted: its operands in source order, the offset its source
 * starts at, and the index of the first operand that is a string literal.
 */
private typedef Chain = {
	final operands: Array<QueryNode>;
	final from: Int;
	final firstLiteral: Int;
};

/** A proposed partition and the budget it was filled against — what the writer verification re-fills from. */
private typedef Plan = {
	final groups: Array<Int>;
	final budget: Int;
};

/**
 * One grouping rendered: the joined construct text and the width of its widest single group.
 */
private typedef Rendered = {
	final text: String;
	final widest: Int;
};

/**
 * What the back-off settled on: the final boundaries, their rendered text, and the
 * measured width. A null `width` means the writer DECLINED to render the candidate,
 * not that it was never asked — every candidate that changes anything is measured.
 */
private typedef Settled = {
	final groups: Array<Int>;
	final text: String;
	final width: Null<Int>;
};

/**
 * A candidate's measuring context: the enclosing member wrapped in a synthetic
 * one-member type, plus that wrapper's own writer rendering as the baseline to diff
 * against. `head` / `tail` bracket the member, `from` / `to` are its span in the
 * FILE, so a candidate is spliced by taking the member's source either side of it.
 */
private typedef MemberScope = {
	final head: String;
	final tail: String;
	final from: Int;
	final to: Int;
	final baseline: Array<String>;
};

/**
 * One file's planning context. Owns the two things a candidate is measured against:
 * the synthetic one-member scope its enclosing MEMBER renders inside (`scopeFor`),
 * and — as the FALLBACK for a member no scope reproduces — the memoised writer
 * rendering of the UNCHANGED file, computed on first demand so a file whose every
 * candidate scopes never pays for it. Per-call, never shared: a `Check` may hold no
 * state across `run` / `fix`.
 */
@:nullSafety(Strict)
@:access(anyparse.check.FoldStringLiterals)
private class PlanContext {

	/** The synthetic wrapper a member is measured inside — a one-member type at the depth its own type puts it at. */
	private static inline final SCOPE_HEAD: String = 'class Scope {\n\t';

	/** The closing half of `SCOPE_HEAD`. */
	private static inline final SCOPE_TAIL: String = '\n}\n';

	public final plugin: GrammarPlugin;
	public final seams: Seams;
	public final source: String;
	public final optsJson: Null<String>;
	public final metrics: LayoutMetrics;

	// Member region ("<from>:<to>") -> its scope, or null when it cannot be scoped.
	// `Map.exists` distinguishes "not built yet" from "built, unusable". The key
	// carries BOTH ends because regions share a start: a declaration and each of the
	// modifier nodes on its line all open at the same offset.
	private final _scopes: Map<String, Null<MemberScope>> = [];

	private var _originalLines: Null<Array<String>> = null;
	private var _originalFailed: Bool = false;
	private var _memberSpans: Null<Array<Span>> = null;

	public function new(plugin: GrammarPlugin, seams: Seams, source: String, optsJson: Null<String>, metrics: LayoutMetrics) {
		this.plugin = plugin;
		this.seams = seams;
		this.source = source;
		this.optsJson = optsJson;
		this.metrics = metrics;
	}

	/** The writer's rendering of the unchanged file, split into lines; null when the writer declines, remembered so it is asked once. */
	public function originalLines(): Null<Array<String>> {
		final cached: Null<Array<String>> = _originalLines;
		if (cached != null || _originalFailed) return cached;
		final written: Null<String> = write(source);
		if (written == null) {
			_originalFailed = true;
			return null;
		}
		final lines: Array<String> = written.split('\n');
		_originalLines = lines;
		return lines;
	}

	/** `writeRoundTrip` with its documented throwing failure modes folded into null. */
	public function write(text: String): Null<String> {
		return try plugin.writeRoundTrip(text, optsJson) catch (exception: Exception) null;
	}

	/**
	 * The synthetic one-member module a candidate at `span` may be measured inside,
	 * or null when nothing reproduces its real context and the caller must splice the
	 * whole file instead.
	 *
	 * The writer decides wrapping per LINE, so a member rendered one indent deep
	 * inside `class Scope { … }` wraps exactly as it does inside its own type — and
	 * the round trip costs the member's few dozen lines instead of the file's
	 * thousands. Two conditions guard that equivalence: the member must be one
	 * indent deep in the SOURCE too (else the wrapper would re-indent it and every
	 * width would be off by the difference), and the wrapper must round-trip at all.
	 * Both answers are memoised per member, since a member usually holds several
	 * candidates.
	 */
	public function scopeFor(span: Span): Null<MemberScope> {
		final member: Null<Span> = memberSpanOf(span);
		if (member == null) return null;
		final key: String = '${member.from}:${member.to}';
		if (_scopes.exists(key)) return _scopes[key];
		final scope: Null<MemberScope> = buildScope(member);
		_scopes[key] = scope;
		return scope;
	}

	/**
	 * `member` wrapped and rendered, or null when the writer declines the wrapper.
	 */
	private function buildScope(member: Span): Null<MemberScope> {
		final written: Null<String> = write(SCOPE_HEAD + source.substring(member.from, member.to) + SCOPE_TAIL);
		return written == null ? null : {
			head: SCOPE_HEAD,
			tail: SCOPE_TAIL,
			from: member.from,
			to: member.to,
			baseline: written.split('\n')
		};
	}

	/** The SMALLEST member region containing `span`, or null when it sits outside every member. */
	private function memberSpanOf(span: Span): Null<Span> {
		var best: Null<Span> = null;
		for (member in memberSpans()) if (
			member.from <= span.from && span.to <= member.to && (best == null || member.to - member.from < best.to - best.from)
		)
			best = member;
		return best;
	}

	/**
	 * Every type member's REGION, built once: from the first NON-BLANK character of
	 * the line its declaration opens on — the synthetic wrapper supplies its own
	 * indent, and the modifiers the grammar keeps as separate sibling nodes come with
	 * it — to the END OF THE LINE its declaration closes on.
	 *
	 * BOTH ends are line boundaries, and the trailing one is the load-bearing half:
	 * the region is measured as LINES, so whatever the writer keeps on the member's
	 * last line has to be inside it. A trailing `// …` sits past the declaration's
	 * span, and a region cut there measures a merged candidate as fitting while the
	 * real line runs forty columns past the limit. When the rest of that line holds
	 * another declaration, it is measured along with this one — which is what the
	 * writer does to them anyway.
	 *
	 * A member is found by INDENT, not by node kind or tree depth — neither is
	 * portable. A grammar may wrap a declaration in any number of nodes
	 * (`FinalDecl > ClassForm > …`), so the anchor is the source itself: the children
	 * of a node that starts at column 0 are members when their own line starts exactly
	 * one indent deep. That is also precisely the condition `buildScope`'s wrapper
	 * reproduces.
	 */
	private function memberSpans(): Array<Span> {
		final cached: Null<Array<Span>> = _memberSpans;
		if (cached != null) return cached;
		final spans: Array<Span> = [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree != null) collectMembers(tree, spans);

		_memberSpans = spans;
		return spans;
	}

	/**
	 * Push the region of every OUTERMOST node that OPENS one indent deep and stop
	 * there — everything inside it is deeper still. Modifier siblings yield their own
	 * short regions alongside the declaration's; `memberSpanOf` picks by containment,
	 * so they never win.
	 */
	private function collectMembers(node: QueryNode, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (span != null) {
			final start: Int = memberLineStart(span.from);
			if (start != -1) {
				final end: Int = FoldStringLiterals.lineEndOf(source, span.to);
				if (end > start) out.push(new Span(start, end));
				return;
			}
		}
		for (child in node.children) collectMembers(child, out);
	}

	/** The first non-blank offset on `pos`'s line when that line opens exactly one indent deep, else -1. */
	private function memberLineStart(pos: Int): Int {
		final lineStart: Int = FoldStringLiterals.lineStartOf(source, pos);
		var indent: Int = lineStart;
		while (indent < source.length && FoldStringLiterals.isBlank(StringTools.fastCodeAt(source, indent))) indent++;
		return FoldStringLiterals.columnWidth(this, lineStart, indent) == metrics.indentWidth ? indent : -1;
	}

}
