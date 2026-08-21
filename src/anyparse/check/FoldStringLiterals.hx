package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.OperatorSelection.OperatorVerdict;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.ConcatSegment;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * Canonicalises a string concatenation to the MINIMAL number of `+` segments that
 * fits the file's own `maxLineLength`: adjacent literals and expression operands
 * MERGE into one interpolated literal, and an already-merged literal that overflows
 * the line SPLITS back out at its seams — a `${ … }` interpolation, an embedded `\n`
 * ESCAPE, or, lowest of the tiers, a SEPARATOR inside the literal's own TEXT (a space
 * run, a comma, an opening bracket). Those text cuts are what make a lone over-long
 * string TOKEN layout-fixable at all: the writer can wrap a `+` chain, but nothing can
 * wrap one literal, so a message that outruns its line has to become a chain before
 * layout can reach it.
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
 * contributes its own fragments (text, cut at each `\n` escape and at each separator
 * boundary / `$name` / `${expr}`), a bare expression operand contributes one segment,
 * and the operands BEFORE the first literal collapse into a single segment covering
 * their source verbatim. Re-decomposing this rule's OWN output reproduces the identical
 * list — except that a bracket cut can lose its seam when a group boundary strands its
 * space/comma introducer in the previous piece; the list only ever gets COARSER, never
 * different, so any deterministic grouping over it is still a fixed point by
 * construction — the property every other piece of the design is arranged to protect.
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
 * - A COMMENT between two operands does not refuse the chain — it LOCKS that boundary.
 *   No group may merge across it, and the gap's source (the comment, the line break, the
 *   indent and the `+`) is re-emitted verbatim, so a chain whose every line ends in a
 *   comment still folds the adjacent pairs INSIDE each line. What the check may never do
 *   is delete an author's comment; keeping the gap byte for byte is how it doesn't.
 * - A comment inside an OPERAND's own span still refuses the construct: that source is
 *   copied verbatim into a group or a bare operand, where a `//` would comment out
 *   whatever the render puts after it.
 * - The replaced span is the OPERAND extent, not the chain node's: a `+` node absorbs the
 *   trivia trailing its last operand, and replacing that would delete a `// …` ending the
 *   construct's line.
 * - An expression segment carrying a bare `$` outside a nested string
 *   literal, a newline, a BACKSLASH or an UNBALANCED brace or quote cannot enter a `${ … }` block: the real compiler's block scanner neither processes escapes
 *   inside a nested same-quote string nor lexes strings while it counts braces,
 *   so both mis-lex there even though anyparse's own interp scanner accepts
 *   them; a `$` INSIDE a nested string is fine — the block's re-parse reads it
 *   exactly as the bare operand did. A segment carrying the interpolation's OWN
 *   quote is refused too, and that one is LEGIBILITY, not lexing: `'a${f('b')}'` compiles and
 *   is value-identical to `'a' + f('b')`, and still puts a `'` two levels inside a
 *   `'`-delimited literal. Neither refusal rejects the construct — each only forces that
 *   segment into a group of its own, rendered bare.
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
 *   that target's implementation. A TARGET INTRINSIC is refused by the same gate and by NO
 *   option: it is spelled with `__` at BOTH ends and declared NOWHERE, so both refusals above —
 *   each a question about resolution — read it as an ordinary local call. Measured, 4.3.7:
 *   `untyped __lua__("{x=" + "1}")` compiles with no diagnostic and emits a call to a function no
 *   runtime declares. Its exemption is a plan that renders as a CONSTANT, narrower than the macro
 *   gate's one-group test — `'a$k'` is a `+` chain the parser desugared, not a constant.
 * - RE-SEGMENT ONLY WHEN OVER-LONG: only a STRICT merge — a plan with FEWER groups
 *   than the source has — runs unconditionally. A split, and equally a same-count
 *   RE-CUT at different boundaries, needs the construct's source lines to be
 *   genuinely over-long; a chain the writer already lays out within the limit keeps
 *   the author's own phrasing instead of being repacked by the greedy fill.
 * - SEPARATOR CUTS ARE A TIE-BREAK, NEVER A LICENCE. The group count stays the PRIMARY
 *   criterion — MINIMAL as the greedy fill reaches it, which is not the same as PROVEN
 *   minimal (the scan stops at the first extension that does not fit, and a rendered
 *   width is not monotone in the segment count: a differently-quoted segment can flip a
 *   group's render mode and shrink it). It is this rule's contract, and also what keeps
 *   the result a fixed point: two adjacent groups that could re-merge inside the budget
 *   would mean the count was not the one the fill reaches, and the next run would flag
 *   the rule's own output. Among the ends that keep that count the boundary is picked
 *   by CLASS — a seam the decomposition already had (an operand edge, a `${ … }`
 *   fragment, a `\n` escape) first; then an opening bracket a space introduced, or a
 *   space run a closing bracket ended; then those same two with a comma in place of the
 *   space; then a plain space run; and last a plain comma. An opening bracket with NEITHER
 *   of those before it is no cut point at all — a regex spells its groups and classes that
 *   way, and breaking one there splits a token for no gain. Read FORWARDS, the same reading
 *   demotes a bracket to LAST: one whose matching close arrives before any space or comma
 *   opened a WORD rather than a list (`(PS3)`, an empty `[]`). So does a boundary with a
 *   line-break escape on EACH side, which cuts a blank line in half. Both are legal cuts the
 *   fill takes only when nothing else keeps the group count. Equal class keeps the WIDEST
 *   end, which is the greedy answer this rule gave before there were text cuts at all.
 * - A single segment wider than the budget still forms its own group and is accepted as
 *   is. That is what a text carrying NO separator — a URL, a base64 blob — still does:
 *   no legal cut exists in it, so nothing is reported and the over-wide line stands.
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
		// Resolved once per run and demanded only by a construct that actually planned: on a tree
		// where nothing overloads the concatenation operator the gate never builds an index and
		// never resolves an operand type, which is what keeps it free for most projects.
		final selection: Null<OperatorSelection> = OperatorSelection.of(plugin, files);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final operators: OperatorGate = new OperatorGate(selection, seams, entry.file, entry.source, tree);
			final ctx: Null<PlanContext> = contextFor(plugin, seams, entry.source, FormatConfigDiscovery.discover(entry.file), operators);
			if (ctx == null) continue;
			// The whitelist is resolved PER FILE: `apqlint.json` is discovered by walking up
			// from each file, so one run can span several configs, and reading the first
			// file's would apply one project's claim about its macros to another's.
			final whitelist: Null<Array<String>> = LintConfig.resolveWith(_resolveConfig, entry.file)
				.stringListOption(RULE_ID, MACRO_WHITELIST_OPTION);
			final gate: MacroGate = new MacroGate(macros, whitelist ?? [], entry.file, seams.support);
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
		final fixable: Array<Violation> = violations.filter(
			v ->
				v.message.indexOf(MACRO_REFUSAL) == -1 && v.message.indexOf(MacroGate.INTRINSIC_REFUSAL) == -1
				&& v.message.indexOf(OperatorGate.REFUSAL) == -1
		);
		return CheckScan.applyBySpan(plugin, source, fixable, seams.candidateKinds, (node, span) -> {
			final planned: Null<PlannedFold> = plan(planContext, node);
			// The violation's span is the NODE's — `applyBySpan` keys on it — but the edit is the
			// narrower OPERAND extent, so trivia the node's span absorbs past its last operand
			// (a trailing `// …`, the line break) is left where the author put it.
			return planned == null ? null : { span: planned.editSpan, text: planned.text };
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

	/** The column width of `source[from...to)`, counting a tab as `indentWidth` columns. */
	private static inline function columnWidth(ctx: PlanContext, from: Int, to: Int): Int {
		return CheckScan.displayColumn(ctx.source, from, to, ctx.metrics.indentWidth);
	}

	/** Whether `code` is a space or a tab. */
	private static inline function isBlank(code: Int): Bool {
		return code == ' '.code || code == '\t'.code;
	}

	/** `line`'s width in columns, counting a tab as `indentWidth`. */
	private static inline function displayWidth(line: String, indentWidth: Int): Int {
		return CheckScan.displayColumn(line, 0, line.length, indentWidth);
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
		final condRun: Bool = seams.condOperandRunKinds.contains(node.kind);
		if (literal || condRun || node.kind == seams.concatKind) {
			final proposed: Null<PlannedFold> = plan(ctx, node);
			// An OVERLOADED operator is not a weaker finding, it is a DIFFERENT construct: the `+`
			// joins its operands by a rule the type declares, so "these segments can be merged" is
			// simply false there and the plan is discarded rather than downgraded — which also lets
			// the walk descend, so a chain of plain literals nested inside one still folds. An
			// UNPROVEN operand keeps the finding and drops the fix, exactly as the macro gate does.
			final operators: Null<OperatorGate> = ctx.operators;
			final verdict: OperatorVerdict = proposed == null || operators == null ? Builtin : operators.verdictFor(node, literal);
			final planned: Null<PlannedFold> = verdict.match(Overloaded(_)) ? null : proposed;
			if (planned != null) {
				final gated: String = (gate.blocks(calls, planned.groups) ? MACRO_REFUSAL : "")
					+ (verdict.match(Unproven) ? OperatorGate.REFUSAL : "");
				final refused: String = gate.intrinsic(calls, planned.constant) ? MacroGate.INTRINSIC_REFUSAL + gated : gated;
				out.push(refused == "" ? planned : {
					span: planned.span,
					editSpan: planned.editSpan,
					text: planned.text,
					groups: planned.groups,
					constant: planned.constant,
					message: planned.message + refused
				});
			}
			// A literal is never descended into; a chain only when it did not plan as
			// a whole, so an inner chain still gets its own chance. A conditional
			// operand run that DID plan keeps its post-directive tail in play — the
			// plan covers the branch's operands and stops at the directive, so the
			// tail is still a construct of its own, and it is the only child the fold
			// did not consume.
			if (literal || (planned != null && !condRun)) return;
			if (planned != null) {
				walk(out, ctx, gate, calls, node.children[node.children.length - 1], constantMembers);
				return;
			}
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
		final budget: Int = ctx.metrics.lineWidth - budgetBase(ctx, decomposition.editSpan) - GROUP_JOIN.length + 1;
		final first: Null<Array<Int>> = fill(ctx, decomposition, budget);
		if (first == null) return null;
		final planned: Null<Plan> = unwrapped(ctx, decomposition, first, budget);
		if (planned == null) return null;
		final filled: Array<Int> = planned.groups;
		// The back-off below only ever ADDS groups, so a plan that does not strictly
		// MERGE can be refused here without paying for a single writer render.
		if (filled.length >= current && !overLong(ctx, decomposition.editSpan)) return null;
		if (sameBoundaries(filled, decomposition.current)) return null;
		final result: Null<Settled> = settle(ctx, decomposition, filled, planned.budget);
		if (result == null) return null;
		final settled: Settled = result;
		if (sameBoundaries(settled.groups, decomposition.current)) return null;
		final groups: Int = settled.groups.length;
		if (groups >= current && !overLong(ctx, decomposition.editSpan)) return null;
		final width: Null<WidthPair> = settled.width;
		// ONE group of nothing but TEXT is the only plan that renders as a compile-time constant —
		// a lone group holding an expression renders INTERPOLATED, which is a `+` chain the parser
		// desugared. `MacroGate.intrinsic` is the one gate that can tell those apart.
		final constant: Bool = settled.groups.length == 1 && decomposition.segments.foreach(segment -> segment.match(SegText(_, _)));
		// Strict LOCAL monotonicity — the fixpoint guard. Comparing against the whole
		// edit region's max width is vacuous when the region carries an IRREDUCIBLE
		// over-wide segment (no seam to split at): every candidate measures under that
		// ceiling, the split and merge preferences disagree, and `--fix` ping-pongs
		// A<->B until the pass cap. Comparing the widths the candidate ADDED against the
		// widths it REMOVED admits only plans that strictly improve the lines they
		// TOUCH, so plan(fix(x)) can never propose the reverse edit: the reverse puts
		// exactly those two sets the other way round. A line the splice left alone is
		// on neither side (`widestDiffering` differences the window by content), so an
		// irreducible over-wide segment sitting BETWEEN two changed lines neither
		// refuses a plan that improves them nor licenses one that does not. Dropping
		// it cannot flip the FIRST clause toward refusal either, since a line on both
		// sides contributed its width to both of the old maxima: what this clause
		// refuses is a strict subset of what the region-wide maxima refused. `width ==
		// null` (the writer declined to render) falls through to ACCEPT — the old
		// gate's fail-open shape, kept deliberately: the arithmetic planner is then
		// the only measure, and refusing would silence the merge direction wholesale.
		// Second clause: a SPLIT (or re-cut) is licensed by the LINES IT TOUCHES being
		// over-wide — not by `overLong(region)`, which an untouchable irreducible segment
		// keeps permanently true. Without it the split and merge preferences flip-flop
		// (budgetBase shifts with the edit span between the two states): from the merged
		// state fill proposes a split of a line that already fits, from the split state
		// it proposes the merge back — both "legal", cycling forever.
		return width != null
			&& ((width.written > ctx.metrics.lineWidth && width.written >= width.original)
				|| (groups >= current && width.original <= ctx.metrics.lineWidth))
			? null
			: {
				span: decomposition.span,
				editSpan: decomposition.editSpan,
				text: settled.text,
				groups: groups,
				constant: constant,
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
		final span: Span = decomposition.editSpan;
		if (!sameBoundaries(filled, decomposition.current) || !overLong(ctx, span)) return { groups: filled, budget: budget };
		final own: Int = ctx.metrics.lineWidth - columnWidth(ctx, lineStartOf(ctx.source, span.from), span.from) - GROUP_JOIN.length + 1;
		if (own >= budget) return { groups: filled, budget: budget };
		final refilled: Null<Array<Int>> = fill(ctx, decomposition, own);
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
		final first: Null<Rendered> = joinGroups(ctx, decomposition, filled);
		if (first == null) return null;
		final span: Span = decomposition.editSpan;
		var budget: Int = startBudget;
		var groups: Array<Int> = filled;
		var rendered: Rendered = first;
		var width: Null<WidthPair> = renderedWidth(ctx, span, rendered.text);
		var pass: Int = 0;
		while (pass < MAX_BACKOFF_PASSES && width != null && width.written > ctx.metrics.lineWidth) {
			final reduced: Int = Std.int(Math.min(budget - (width.written - ctx.metrics.lineWidth), rendered.widest - 1));
			if (reduced <= 0) break;
			final next: Null<Array<Int>> = fill(ctx, decomposition, reduced);
			if (next == null || sameBoundaries(next, groups)) break;
			final nextRendered: Null<Rendered> = joinGroups(ctx, decomposition, next);
			if (nextRendered == null) break;
			final nextWidth: Null<WidthPair> = renderedWidth(ctx, span, nextRendered.text);
			if (nextWidth == null || nextWidth.written >= width.written) break;
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
		return if (span == null)
			null
		else if (node.kind == ctx.seams.concatKind)
			chainDecomposition(ctx, node, span)
		else if (ctx.seams.condOperandRunKinds.contains(node.kind))
			condRunDecomposition(ctx, node, span)
		else
			literalDecomposition(ctx, node, span);
	}

	/**
	 * An operand-run conditional-compilation splice (`RefShape.condOperandRunKinds`)
	 * decomposes over the operands INSIDE its branch and nothing else.
	 *
	 * The region is a TOKEN splice, not a precedence tree: `A + #if c B + C + #end D`
	 * is `A + B + C + D` with `c` on and `A + D` with it off, because the `+` before
	 * `#if` lives outside the region and the one before `#end` lives inside it. Its
	 * children project as the in-branch operands followed by ONE post-directive TAIL,
	 * and the operators between them project as no node at all. So this arm reads the
	 * two facts the projection does not carry straight out of the source, and refuses
	 * whatever it cannot read:
	 *
	 *  - the LAST child is dropped. Merging it into the run would move its text inside
	 *    the branch, and the build that does not define the condition would silently
	 *    lose it. The corpus cannot catch that — it compiles with one flag state.
	 *  - every GAP between two kept operands must be exactly the concatenation
	 *    operator. `HxCondSpliceOpLit`-style regions also spell `&&`, `||`, `?` and
	 *    `:`, and the same production carries a ternary; a comment in a gap fails the
	 *    same test, which is why no separate comment gate is needed for the gaps.
	 *  - the run is entered at its first string LITERAL and the operands before it are
	 *    left alone — where `chainDecomposition` collapses them into one verbatim
	 *    `${ … }` head, this arm cannot, because `+` is left-associative and the
	 *    ARITHMETIC they belong to starts on the other side of the `#if`. Measured:
	 *    `1 + #if c 2 + 'x' + #end 3` prints `3x3`, and folding the run's own head
	 *    gives `1 + '${2}x' + 3` — `12x3`. From the first literal ON there is no such
	 *    question: string concatenation is associative and an `Int` head to its left
	 *    stringifies the same either way, whatever sits before the directive.
	 *
	 * The edit therefore spans first-literal-operand to last-kept-operand — strictly
	 * inside the branch, never touching `#if`, the condition, `#end` or the tail. A run
	 * left with ONE operand is no longer a candidate, so the fold is a fixed point.
	 */
	private static function condRunDecomposition(ctx: PlanContext, node: QueryNode, span: Span): Null<Decomposition> {
		final children: Array<QueryNode> = node.children;
		// Two in-branch operands plus the tail: fewer is nothing to merge.
		if (children.length < 3) return null;
		final kept: Array<QueryNode> = children.slice(0, children.length - 1);
		var firstLiteral: Int = -1;
		for (i in 0...kept.length) if (ctx.seams.stringLiteralKinds.contains(kept[i].kind)) {
			firstLiteral = i;
			break;
		}
		if (firstLiteral == -1) return null;
		final operands: Array<QueryNode> = kept.slice(firstLiteral, kept.length);
		if (operands.length < 2) return null;
		final spans: Array<Span> = [];
		for (operand in operands) {
			final own: Null<Span> = operand.span;
			if (own == null || chainHasComment(ctx.source, own.from, own.to)) return null;
			spans.push(own);
		}
		// Against `GROUP_JOIN` on purpose: the render puts exactly that operator back between
		// the groups it emits, so an operator it would not re-emit is one this arm must not
		// consume. A comment in a gap fails the same test, its bytes not being the operator.
		for (i in 0...spans.length - 1) if (ctx.source.substring(spans[i].to, spans[i + 1].from).trim() != GROUP_JOIN.trim()) return null;
		final segments: Array<ConcatSegment> = [];
		final current: Array<Int> = [];
		for (operand in operands) {
			if (!appendOperandSegments(ctx, operand, segments)) return null;
			current.push(segments.length);
		}
		return {
			segments: segments,
			current: current,
			span: span,
			editSpan: new Span(spans[0].from, spans[spans.length - 1].to),
			locked: [],
			glue: [],
			startsBare: false
		};
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
		return segments == null || segments.length < 2 ? null : {
			segments: segments,
			current: [segments.length],
			span: span,
			editSpan: span,
			locked: [],
			glue: [],
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
		// An operand carrying a comment INSIDE its own span is refused outright: its source
		// is copied verbatim into a group or a bare operand, so a `//` there would comment
		// out whatever the render puts after it. Only the GAPS between operands are modelled.
		for (operand in operands) {
			final own: Null<Span> = operand.span;
			if (own == null || chainHasComment(ctx.source, own.from, own.to)) return null;
		}
		final segments: Array<ConcatSegment> = [];
		final current: Array<Int> = [];
		final locked: Array<Int> = [];
		final glue: Map<Int, String> = [];
		if (firstLitIdx == 1) {
			// Index 0 is not a literal (that is what `firstLitIdx == 1` says), so this takes
			// the helper's expression path — the head is ONE segment either way.
			if (!appendOperandSegments(ctx, operands[0], segments)) return null;
			current.push(segments.length);
		} else if (firstLitIdx > 1) {
			final headEnd: Null<Span> = operands[firstLitIdx - 1].span;
			if (headEnd == null) return null;
			// The head is ONE verbatim segment spanning several operands, so a comment in a gap
			// it swallows would ride into the render — refuse rather than model it.
			if (chainHasComment(ctx.source, claimed.from, headEnd.to)) return null;
			segments.push(SegExpr(ctx.source.substring(claimed.from, headEnd.to), false));
			current.push(segments.length);
		}
		if (firstLitIdx >= 1) lockGapAfter(ctx.source, operands, firstLitIdx - 1, segments.length, locked, glue);
		for (i in firstLitIdx ... operands.length) {
			if (!appendOperandSegments(ctx, operands[i], segments)) return null;
			current.push(segments.length);
			lockGapAfter(ctx.source, operands, i, segments.length, locked, glue);
		}
		// A head segment was emitted exactly when a bare operand precedes the first
		// literal — the fact `plan` cannot recover from the segment list alone.
		return {
			segments: segments,
			current: current,
			span: span,
			editSpan: new Span(claimed.from, claimed.to),
			locked: locked,
			glue: glue,
			startsBare: firstLitIdx >= 1
		};
	}

	/**
	 * Records the gap after operand `i` as UNMERGEABLE when a comment sits in it: the group
	 * boundary at segment index `end` is locked, and the gap's source — the comment, the line
	 * break, the indent and the `+` itself — is kept verbatim as the glue `joinGroups` puts
	 * back between the two groups.
	 *
	 * This is what makes a per-LINE fold possible on a chain whose every line ends in a
	 * comment: the pairs inside each line still merge, and nothing an author wrote moves.
	 */
	private static function lockGapAfter(
		source: String, operands: Array<QueryNode>, i: Int, end: Int, locked: Array<Int>, glue: Map<Int, String>
	): Void {
		if (i < 0 || i + 1 >= operands.length) return;
		final left: Null<Span> = operands[i].span;
		final right: Null<Span> = operands[i + 1].span;
		if (left == null || right == null) return;
		if (!chainHasComment(source, left.to, right.from)) return;
		locked.push(end);
		glue[end] = source.substring(left.to, right.from);
	}

	/**
	 * The chain rooted at `node` when this rule claims it, else null — the ONE place
	 * the claim is decided, asked by `chainDecomposition` for its own work and by
	 * `ownsChain` for `prefer-interpolation`'s hand-off (whose doc records what the
	 * claim does NOT cover).
	 *
	 * Each refusal has its own reason:
	 *
	 *  - fewer than two operands, or the NODE itself or its FIRST or LAST operand
	 *    carrying no source span: not a chain this rule can re-render.
	 *  - NO string-literal operand (`a + b`, `1 + 2`, `Std.string(a) + Std.string(b)`)
	 *    — the chain is not a string concatenation at all and merging it would change
	 *    arithmetic into text.
	 * A comment is NOT a refusal here — `chainDecomposition` turns each commented gap into
	 * a locked group boundary. Only a comment inside an OPERAND's own span refuses, and it
	 * does so there rather than here.
	 */
	private static function claim(node: QueryNode, source: String, concatKind: String, stringLiteralKinds: Array<String>): Null<Chain> {
		if (node.span == null) return null;
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
		return firstLiteral == -1 ? null : {
			operands: operands,
			from: firstSpan.from,
			to: lastSpan.to,
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

	/**
	 * `node`'s segments appended to `segments`, or `false` when the seam refuses it —
	 * the one place an operand becomes segments, shared by the `+` chain and the
	 * conditional operand run so the two cannot drift apart.
	 *
	 * A LITERAL operand contributes its own fragments; anything else contributes ONE
	 * expression segment, with a `Std.string(x)` wrapper peeled off first — interpolation
	 * already converts, so the wrapper is noise inside a group. The peel is purely
	 * STRUCTURAL, matched on the receiver / member NAMES: resolving the call target
	 * exactly needs the whole import / static-extension picture, and a same-named member
	 * of some other type renders identically inside `${ … }` anyway.
	 */
	private static function appendOperandSegments(ctx: PlanContext, node: QueryNode, segments: Array<ConcatSegment>): Bool {
		if (ctx.seams.stringLiteralKinds.contains(node.kind)) {
			final segs: Null<Array<ConcatSegment>> = ctx.seams.support.segmentsOf(node, ctx.source);
			if (segs == null) return false;
			for (seg in segs) segments.push(seg);
			return true;
		}
		final callKind: Null<String> = ctx.seams.callKind;
		final fieldAccessKind: Null<String> = ctx.seams.fieldAccessKind;
		var operand: QueryNode = node;
		if (callKind != null && fieldAccessKind != null && node.kind == callKind && node.children.length == 2) {
			final callee: QueryNode = node.children[0];
			if (callee.kind == fieldAccessKind && callee.name == 'string' && callee.children.length == 1) {
				final receiver: QueryNode = callee.children[0];
				if (receiver.kind == ctx.seams.identKind && receiver.name == 'Std') operand = node.children[1];
			}
		}
		final seg: Null<ConcatSegment> = ctx.seams.support.expressionSegment(operand, ctx.source);
		if (seg == null) return false;
		segments.push(seg);
		return true;
	}

	/**
	 * Left-to-right fill in two passes. The BACKWARD one prices, for every start, the widest
	 * group that fits (`lastFit`) and the fewest groups the tail can then be cut into
	 * (`minCount`). The FORWARD one walks the starts and picks, among the ends that keep that
	 * minimum, the best-CLASSED boundary (`BoundaryRank`) — the widest one of equal class,
	 * which is the plain greedy answer this used to give.
	 *
	 * A single segment wider than the budget still forms its own group and is accepted as-is,
	 * which is what a text carrying no separator at all does. A segment that cannot sit inside
	 * a `${ … }` block (see `ConcatSegment.SegExpr`) ends the group it would have joined, so it
	 * lands in a group of its own and renders bare.
	 */
	private static function fill(ctx: PlanContext, decomposition: Decomposition, budget: Int): Null<Array<Int>> {
		final segments: Array<ConcatSegment> = decomposition.segments;
		final locked: Array<Int> = decomposition.locked;
		final count: Int = segments.length;
		// Backward pass. `lastFit[i]` is the greedy answer — the widest group starting at `i`
		// that fits, or `i + 1` when not even the pair does — and `minCount[i]` the fewest
		// groups `i…` takes when every group is grown that way. GREEDY-minimal rather than
		// proven minimal: the scan stops at the first extension that does not fit, and a
		// rendered width is not monotone in the segment count (a differently-quoted segment
		// can flip a group's render mode and SHRINK it). Both passes need one consistent
		// target to preserve, which this is.
		final lastFit: Array<Int> = [for (_ in 0...count + 1) 0];
		final minCount: Array<Int> = [for (_ in 0...count + 1) 0];
		var i: Int = count - 1;
		while (i >= 0) {
			var last: Int = i + 1;
			var j: Int = i + 1;
			// A locked boundary at `j` means segment `j` may not join what precedes it: taking
			// it in would swallow the comment sitting in that gap.
			while (j < count && !locked.contains(j)) {
				final candidate: Null<String> = renderRange(ctx, segments, i, j + 1);
				if (candidate == null || candidate.length > budget) break;
				last = j + 1;
				j++;
			}
			lastFit[i] = last;
			minCount[i] = 1 + minCount[last];
			i--;
		}
		// Forward pass. Every end in `from + 1 … lastFit[from]` is feasible — the scan above
		// rendered each of those prefixes — so the choice is free among the ones that keep the
		// group count at that target, and there the best-CLASSED boundary wins, the widest of
		// equal class. `lastFit[from]` is always one of them and is taken whatever `steerable`
		// says: it is the answer the plain greedy fill gave, and when it is the only end that
		// fits there is nothing to steer to.
		final ends: Array<Int> = [];
		var from: Int = 0;
		while (from < count) {
			var end: Int = lastFit[from];
			var rank: BoundaryClass = BoundaryRank.of(segments, end);
			var candidate: Int = lastFit[from] - 1;
			while (candidate > from) {
				if (1 + minCount[candidate] == minCount[from] && steerable(decomposition, from, candidate)) {
					final other: BoundaryClass = BoundaryRank.of(segments, candidate);
					if (other < rank) {
						rank = other;
						end = candidate;
					}
				}
				candidate--;
			}
			ends.push(end);
			from = end;
		}
		return mergeLeadingBares(ctx, decomposition, ends);
	}

	/**
	 * Whether `fill` may STEER to `end` for the group starting at `from`. The one refusal is a
	 * partition `mergeLeadingBares` would rewrite: it folds a BARE first group into the next
	 * one without pricing the result, so choosing that end hands it a merge it cannot refuse
	 * and the merged first line lands over budget — permanently, since re-planning the fixed
	 * text reproduces the same choice and nothing ever recovers it. The boundary after a bare
	 * head reads as a `Seam` (no text left of it at all), which is the best class there is, so
	 * without this it wins outright whenever it preserves the group count.
	 *
	 * Only the ALTERNATIVES are filtered, never `lastFit[from]`: when the bare head is the
	 * only end that fits there is no other partition to reach, and the merge is then exactly
	 * what has to happen — a source that opens with a bare operand may not become two leading
	 * bare operands.
	 */
	private static function steerable(decomposition: Decomposition, from: Int, end: Int): Bool {
		return
			from > 0 || decomposition.startsBare || decomposition.locked.contains(end) || !isBareGroup(decomposition.segments, from, end);
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
	private static function mergeLeadingBares(ctx: PlanContext, decomposition: Decomposition, ends: Array<Int>): Null<Array<Int>> {
		final segments: Array<ConcatSegment> = decomposition.segments;
		if (ends.length < 2 || !isBareGroup(segments, 0, ends[0])) return ends;
		// A locked first boundary carries a comment the merge would swallow — the bare head
		// stays its own group, which is the safe side of this gate anyway.
		if (decomposition.locked.contains(ends[0])) return ends;
		if (decomposition.startsBare && !isBareGroup(segments, ends[0], ends[1])) return ends;
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
	private static function joinGroups(ctx: PlanContext, decomposition: Decomposition, ends: Array<Int>): Null<Rendered> {
		final segments: Array<ConcatSegment> = decomposition.segments;
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
		final text: StringBuf = new StringBuf();
		for (k in 0...parts.length) {
			// A locked boundary is re-emitted from the SOURCE, so the comment, the line break and
			// the `+` an author wrote come back byte for byte; every other boundary is plain glue.
			if (k > 0) text.add(decomposition.glue[ends[k - 1]] ?? GROUP_JOIN);
			text.add(parts[k]);
		}
		return { text: text.toString(), widest: widest };
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
		while (indent < ctx.source.length && isBlank(ctx.source.fastCodeAt(indent))) indent++;
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
	private static function renderedWidth(ctx: PlanContext, span: Span, candidate: String): Null<WidthPair> {
		final scope: Null<MemberScope> = ctx.scopeFor(span);

		if (scope != null) {
			final source: String = ctx.source;
			final spliced: String = scope.head + source.substring(scope.from, span.from) + candidate + source.substring(span.to, scope.to)
				+ scope.tail;
			return widestDiffering(scope.baseline, ctx.write(spliced), ctx.metrics.indentWidth);
		}
		final original: Null<Array<String>> = ctx.originalLines();
		return original == null
			? null
			: widestDiffering(
				original, ctx.write(ctx.source.substring(0, span.from) + candidate + ctx.source.substring(span.to)),
				ctx.metrics.indentWidth
			);
	}

	/**
	 * The widest line the candidate's render ADDED, paired with the widest line it
	 * REMOVED — the numbers the plan gate's strict-improvement (fixpoint) test compares.
	 * The leading and trailing lines `written` SHARES with `original` are dropped first,
	 * and inside what is left the two sides are differenced BY CONTENT: a line present on
	 * both sides is untouched by the splice and enters NEITHER maximum, however wide it
	 * is. Taking the whole window's max instead let one irreducible over-wide line
	 * BETWEEN two changed lines pin `written` and `original` equal, which reads to the
	 * gate as "no improvement" and refused a plan that improved every line it touched.
	 * Null when the writer declined to render the candidate.
	 */
	private static function widestDiffering(original: Array<String>, written: Null<String>, indentWidth: Int): Null<WidthPair> {
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
		final surplus: Map<String, Int> = [];
		for (i in prefix ... lines.length - suffix) surplus[lines[i]] = (surplus[lines[i]] ?? 0) + 1;
		for (i in prefix ... original.length - suffix) surplus[original[i]] = (surplus[original[i]] ?? 0) - 1;
		var widest: Int = 0;
		var originalWidest: Int = 0;
		for (line => count in surplus) if (count != 0) {
			final width: Int = displayWidth(line, indentWidth);
			if (count > 0 && width > widest)
				widest = width;
			else if (count < 0 && width > originalWidest)
				originalWidest = width;
		}
		return { written: widest, original: originalWidest };
	}

	/** The finding text, naming the direction the segmentation moves in. */
	private static function messageFor(planned: Int, current: Int): String {
		return if (planned < current)
			'these string concatenation segments can be merged'
		else if (planned > current)
			'this string literal can be split at its seams to fit the line width'
		else
			'these string concatenation segments can be re-cut to fit the line width';
	}

	/**
	 * Whether the source range `[from, to)` carries a `//` or `/*` comment OUTSIDE any
	 * string literal — asked of the GAP between two operands (which locks that group
	 * boundary) and of an operand's own span (which refuses the construct). String bodies
	 * are skipped (respecting `\` escapes) so a `'http://x'` literal does not read as a
	 * comment.
	 */
	private static function chainHasComment(source: String, from: Int, to: Int): Bool {
		var i: Int = from;
		while (i < to) {
			final c: Int = source.fastCodeAt(i);
			if (c == "'".code || c == '"'.code) {
				i++;
				while (i < to) {
					final d: Int = source.fastCodeAt(i);
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
				final n: Int = source.fastCodeAt(i + 1);
				if (n == '/'.code || n == '*'.code) return true;
				i++;
			} else {
				i++;
			}
		}
		return false;
	}

	/** The per-file planning context, or null when the grammar's writer declares no layout metrics. */
	private static function contextFor(
		plugin: GrammarPlugin, seams: Seams, source: String, optsJson: Null<String>, ?operators: OperatorGate
	): Null<PlanContext> {
		final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(optsJson);
		return metrics == null ? null : new PlanContext(plugin, seams, source, optsJson, metrics, operators);
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
			condOperandRunKinds: shape.condOperandRunKinds ?? [],
			stringLiteralKinds: stringLiteralKinds,
			stringInterpBlockKind: shape.stringInterpBlockKind,
			stringInterpIdentKind: shape.stringInterpIdentKind,
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
			candidateKinds: [concatKind].concat(stringLiteralKinds).concat(shape.condOperandRunKinds ?? [])
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

	/**
	 * What a finding adds when the callee is a TARGET INTRINSIC — a refusal
	 * `concatFoldingMacros` deliberately does NOT lift, because listing one would be a claim
	 * about the COMPILER's implementation rather than about a target this project owns, and the
	 * claim is false: measured on 4.3.7, `untyped __lua__("{x=" + "1}")` compiles with no
	 * diagnostic at all and emits `__lua__(Std.string("{x=") .. Std.string("1}"))`.
	 *
	 * It lives here rather than beside `MACRO_REFUSAL` for the reason `OperatorGate.REFUSAL`
	 * does: the gate that DECIDES a refusal owns the sentence that explains it.
	 */
	public static inline final INTRINSIC_REFUSAL: String = ', but it is an argument of a compiler intrinsic, which matches a '
		+ 'string CONSTANT and stops matching a concatenation — the generator then emits a call to a function no runtime '
		+ 'declares, or rejects the argument outright';

	private final _macros: MacroIndex;
	private final _whitelist: Array<String>;
	private final _file: String;

	/** The grammar's own reading of which bare call NAMES take their arguments as syntax. */
	private final _support: StringFoldSupport;

	public function new(macros: MacroIndex, whitelist: Array<String>, file: String, support: StringFoldSupport) {
		_macros = macros;
		_whitelist = whitelist;
		_file = file;
		_support = support;
	}

	/**
	 * Whether a plan that is not a compile-time `constant` sits inside a call to a TARGET
	 * INTRINSIC — the hole the two refusals below cannot see, because both are questions about
	 * RESOLUTION and an intrinsic
	 * resolves to nothing anywhere: no `macro` member declares it, no import binds it, and the
	 * last line's fall-through then reads "local, inherited or global, and no import can make it
	 * a macro" — true, and beside the point. A gate that passes on an unresolvable callee is
	 * fail-OPEN, and this family never resolves BY CONSTRUCTION.
	 *
	 * Only the BARE spelling is asked about. A written receiver already refuses on its own
	 * evidence (`js.Syntax.code(…)` is `call.qualified`), and requiring the bare form keeps an
	 * ordinary member that happens to carry the affix — a `python`/`lua` magic method called as
	 * `x.__next__(…)` — out of it.
	 *
	 * A plan that is a compile-time CONSTANT is exempt, and the exemption is worth stating exactly
	 * because the sibling `blocks` states a WIDER one: reaching a single PLAIN literal only removes
	 * `+` operators the argument already had, and is the very shape the target wants — but a single
	 * INTERPOLATED literal is no such thing. Haxe desugars `'a$k'` back into a `+` chain before
	 * anything reads the argument as syntax, so `__lua__('local q = $k;')` and
	 * `__lua__("local q = " + k + ";")` emit the identical broken code (measured, 4.3.7). Hence
	 * `constant`, which is `PlannedFold`'s answer to that, and not the group COUNT.
	 */
	public function intrinsic(calls: Array<CallRef>, constant: Bool): Bool {
		return !constant && calls.exists(call -> call.receiver == null && !call.qualified && _support.readsArgumentsAsSyntax(call.name));
	}

	/**
	 * Whether a plan of `groups` groups sitting inside the call stack `calls` must stay
	 * report-only. A plan that renders as ONE group is never refused: it is a lone
	 * literal, the very shape a constant-matching macro expects, and reaching it can only
	 * remove `+` operators the argument already had.
	 */
	public function blocks(calls: Array<CallRef>, groups: Int): Bool {
		return groups >= 2 && calls.exists(call -> blocksCall(call));
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
			return declarations.exists(path -> !whitelisted(path));
		}
		final receiver: Null<String> = call.receiver;
		if (receiver != null && (_macros.declaresType(receiver) || whitelisted('$receiver.${call.name}'))) return false;
		final binding: Null<String> = _macros.unresolvedBinding(_file, receiver ?? call.name);
		// A WRITTEN qualified receiver names a type path directly, so it refuses on its own
		// evidence: `pkg.Lang.t(…)` needs no import at all, and nothing else in the file
		// says where `Lang` lives.
		return binding != null ? !whitelisted('$binding.${call.name}') : call.qualified;
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
		return _whitelist.exists(entry -> entry == path || entry.endsWith('.$path') || path.endsWith('.$entry'));
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

	/** The operand-run conditional-splice kinds (`RefShape.condOperandRunKinds`). */
	final condOperandRunKinds: Array<String>;

	final stringLiteralKinds: Array<String>;

	/**
	 * The interpolation-BLOCK kind, or null when the grammar has no interpolation. The SPLIT
	 * direction can turn an expression that sits inside such a block into a bare `+` operand, so
	 * this is where the operator gate finds the operands a split would create.
	 */
	final stringInterpBlockKind: Null<String>;

	/** The `$name` interpolation-FRAGMENT kind — the other operand a split can lift out of a literal. */
	final stringInterpIdentKind: Null<String>;
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

	/** The construct NODE's span — what a violation is anchored at, so `fix` can re-find it. */
	final span: Span;

	/**
	 * The span the fix REPLACES: the first operand's start to the last one's end. Narrower
	 * than `span`, because a `+` node's span absorbs the trivia trailing its last operand —
	 * replacing that would delete a comment ending the construct's line.
	 */
	final editSpan: Span;

	/**
	 * Segment boundaries no group may cross: a comment sits in the gap between the two
	 * operands they separate. `glue` holds that gap's source verbatim.
	 */
	final locked: Array<Int>;

	/** Locked boundary -> the source between its operands (comment, line break, indent, `+`). */
	final glue: Map<Int, String>;

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

	/** The construct NODE's span — the violation's anchor. */
	final span: Span;

	/** The narrower span the fix replaces — see `Decomposition.editSpan`. */
	final editSpan: Span;

	final text: String;

	/** How many `+` operands the plan renders as. */
	final groups: Int;

	/**
	 * Whether the plan renders as a COMPILE-TIME CONSTANT — one group, every segment TEXT.
	 * That is a strictly narrower question than `groups == 1`, and the difference is the whole
	 * reason this field exists: a lone group holding an expression renders as an INTERPOLATED
	 * literal, which Haxe desugars back into a `+` chain before anything reads it as syntax.
	 * Measured on 4.3.7, `untyped __lua__('local q = $k;')` and `untyped __lua__("local q = " + k
	 * + ";")` emit the SAME broken `__lua__(Std.string(…) .. Std.string(…))`, and `js.Syntax.code`
	 * rejects both with "must be a string constant".
	 */
	final constant: Bool;
	final message: String;
};

/**
 * A `+` chain `claim` accepted: its operands in source order, the offset its source
 * starts at, and the index of the first operand that is a string literal.
 */
private typedef Chain = {
	final operands: Array<QueryNode>;
	final from: Int;

	/** The offset the LAST operand ends at — the far end of the span the fix replaces. */
	final to: Int;
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
 * The widest line a candidate's render ADDED, paired with the widest line it
 * REMOVED — the two numbers the plan gate's strict-improvement test compares. They
 * are maxima over disjoint sets and need not describe the same line; a line the
 * render left untouched is in neither, so an over-wide line the edit never reaches
 * cannot pin both sides equal.
 */
private typedef WidthPair = {
	final written: Int;
	final original: Int;
};

/**
 * What the back-off settled on: the final boundaries, their rendered text, and the
 * measured width. A null `width` means the writer DECLINED to render the candidate,
 * not that it was never asked — every candidate that changes anything is measured.
 */
private typedef Settled = {
	final groups: Array<Int>;
	final text: String;
	final width: Null<WidthPair>;
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

	/**
	 * The OPERATOR gate for this file, or null in `fix` — where the decision is not retaken: a
	 * report-only finding carries it in its own message, exactly as the macro gate does.
	 */
	public final operators: Null<OperatorGate>;

	/**
	 * Member region ("<from>:<to>") -> its scope, or null when it cannot be scoped.
	 * `Map.exists` distinguishes "not built yet" from "built, unusable". The key
	 * carries BOTH ends because regions share a start: a declaration and each of the
	 * modifier nodes on its line all open at the same offset.
	 */
	private final _scopes: Map<String, Null<MemberScope>> = [];

	private var _originalLines: Null<Array<String>> = null;
	private var _originalFailed: Bool = false;
	private var _memberSpans: Null<Array<Span>> = null;

	public function new(
		plugin: GrammarPlugin, seams: Seams, source: String, optsJson: Null<String>, metrics: LayoutMetrics, operators: Null<OperatorGate>
	) {
		this.plugin = plugin;
		this.seams = seams;
		this.source = source;
		this.optsJson = optsJson;
		this.metrics = metrics;
		this.operators = operators;
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
		while (indent < source.length && FoldStringLiterals.isBlank(source.fastCodeAt(indent))) indent++;
		return FoldStringLiterals.columnWidth(this, lineStart, indent) == metrics.indentWidth ? indent : -1;
	}

}

/**
 * The boundary CLASSES the ladder ranks, best first — `BoundaryRank.of`'s answer, and
 * the tie-break `FoldStringLiterals.fill` picks a group end with, among the ends that
 * keep the group count it settled on.
 */
private enum abstract BoundaryClass(Int) {

	/**
	 * Not a text cut — the construct's end, or a boundary this side of the ladder cannot
	 * attribute to a separator. See `BoundaryRank.of` on why that is a RECONSTRUCTION and not
	 * a fact the segment list carries.
	 */
	final Seam = 0;

	/** An opening bracket a space introduced, or a space run a closing bracket ended. */
	final BracketBySpace = 1;

	/** Those same two boundaries with a comma where the space was. */
	final BracketByComma = 2;

	/** A plain space run. */
	final PlainSpace = 3;

	/** A plain comma. */
	final PlainComma = 4;

	/**
	 * WORST, and the only class that is not a preference but a REFUSAL to read the boundary as
	 * a cut at all: the two shapes a reader never breaks at, because breaking there splits one
	 * TOKEN rather than separating two pieces of text.
	 *
	 * One is a bracket that opens a token: `(PS3)` in a gamepad mapping, an EMPTY `[]` or `{}`
	 * in a serialized structure. The ladder ranks a bracket a space or comma introduced ABOVE a
	 * plain space or comma precisely because a bracket usually opens a LIST — but when its
	 * matching close arrives before any space or comma does, it opened a word instead, and the
	 * cut lands inside it. The existing "an opening bracket with NEITHER of those before it is
	 * no cut point at all" reads the character BEFORE the bracket; this reads what follows it.
	 *
	 * The other is a boundary with a line-break escape on EACH side of it — a cut INSIDE a blank
	 * line. The blank line belongs to the paragraph it terminates, so the reader's cut is after
	 * the run, not in the middle of it; the split `'…\t}\n' + '\n}\n'` is what the middle looks
	 * like.
	 *
	 * It is a demotion rather than a veto because `fill` still needs SOME end when nothing else
	 * keeps the group count: a cut that reads as noise is worse than one that does not, and
	 * better than a line the writer cannot wrap at all.
	 */
	final TokenSplit = 5;

	/** Ordered comparison, which an `enum abstract` does not forward on its own. */
	@:op(A < B) private static function lt(a: BoundaryClass, b: BoundaryClass): Bool;

}

/**
 * How good the cut before segment `j` reads. It is ONLY ever a tie-break among the ends that
 * keep the group count minimal — never a licence to add a group.
 *
 * The class is RECONSTRUCTED from at most two characters of the text left of the boundary, not
 * read off the segment list, which records no reason for the cut it holds. So `Seam` means
 * "no separator explains this boundary": the construct's end, a right side that is not text,
 * a left side that is not text — and, structurally, every operand edge, `${ … }` fragment
 * boundary and `\n` escape whose left text does not happen to end in a separator. The
 * heuristic is conservative in one direction only: an operand edge whose left literal DOES
 * end in one (`'abc ' + 'def'`) reads as the text cut it looks like, `PlainSpace` rather
 * than `Seam`. That costs a preference, never a wrong cut — the boundary exists either way.
 *
 * Everything else ranks a bracket-adjacent cut above a bare one, because a bracket belongs
 * with whatever introduced it.
 *
 * The characters are read RAW, so an escape-spelled one simply does not match and the
 * boundary reads as a plain one. That is conservative rather than wrong: whether the cut is
 * LEGAL was already decided in the grammar, which reads the same raw text.
 */
@:nullSafety(Strict)
private class BoundaryRank {

	/** The class of the boundary before `segments[j]`; `j == segments.length` is the construct's end. */
	public static function of(segments: Array<ConcatSegment>, j: Int): BoundaryClass {
		if (j == segments.length || !segments[j].match(SegText(_, _))) return Seam;
		final left: String = leftText(segments, j);
		final tail: Int = left.length - 1;
		if (tail < 0) return Seam;
		final last: Int = left.fastCodeAt(tail);
		if (splitsBlankLine(left, segments, j)) return TokenSplit;
		if (isOpen(last)) {
			final bracket: BoundaryClass = bracketClass(charBefore(left, tail));
			return bracket != Seam && opensAToken(segments, j, last) ? TokenSplit : bracket;
		}
		if (last == ','.code) return isClose(charBefore(left, tail)) ? BracketByComma : PlainComma;
		if (last != ' '.code) return Seam;
		var run: Int = tail;
		while (run > 0 && left.fastCodeAt(run - 1) == ' '.code) run--;
		return isClose(charBefore(left, run)) ? BracketBySpace : PlainSpace;
	}

	/** The bracket that closes `open`; `open` is one of the three `isOpen` answers. */
	private static inline function closerFor(open: Int): Int {
		return if (open == '('.code)
			')'.code
		else if (open == '['.code)
			']'.code
		else
			'}'.code;
	}

	/**
	 * An opening bracket's class, decided by the character that INTRODUCED it. Neither means the
	 * grammar never cut here — a bracket with no space and no comma before it is not a separator
	 * boundary at all — so the only boundaries that reach this reading are seams.
	 */
	private static inline function bracketClass(before: Int): BoundaryClass {
		return if (before == ' '.code)
			BracketBySpace
		else if (before == ','.code)
			BracketByComma
		else
			Seam;
	}

	/** The character code just left of `at` in `s`, or -1 when `at` is already its start. */
	private static inline function charBefore(s: String, at: Int): Int {
		return at <= 0 ? -1 : s.fastCodeAt(at - 1);
	}

	/** Whether `c` OPENS a bracket pair — the character a separator cut keeps with what introduced it. */
	private static inline function isOpen(c: Int): Bool {
		return c == '('.code || c == '['.code || c == '{'.code;
	}

	/** Whether `c` CLOSES a bracket pair — what makes the separator after it a structural boundary. */
	private static inline function isClose(c: Int): Bool {
		return c == ')'.code || c == ']'.code || c == '}'.code;
	}

	/**
	 * Whether the bracket the boundary sits behind opens a TOKEN rather than a list: its matching
	 * close arrives before any space or comma does. `(PS3)` in a gamepad mapping and an empty
	 * `[]` in a serialized structure both answer yes, and a cut there splits a word for no gain;
	 * `[{ name : …` and `(typeof x === …` both answer no.
	 *
	 * Only the piece the boundary OPENS is scanned. That is deliberate rather than a bound: the
	 * grammar cuts a piece at every space, comma and line break, so a bracket whose close is not
	 * in that one piece has a separator between the two, which is the answer either way. The scan
	 * does count nesting, though — `if (` in `if (text.trim()\n` would otherwise read the inner
	 * call's `)` as its own and call a whole condition a token.
	 */
	private static function opensAToken(segments: Array<ConcatSegment>, j: Int, open: Int): Bool {
		final close: Int = closerFor(open);
		switch segments[j] {
			case SegText(_, raw):
				var depth: Int = 0;
				var i: Int = 0;
				while (i < raw.length) {
					final c: Int = raw.fastCodeAt(i);
					if (c == ' '.code || c == ','.code) return false;
					if (isOpen(c)) {
						depth++;
					} else if (isClose(c)) {
						if (depth == 0) return c == close;
						depth--;
					}
					i++;
				}
				return false;
			case _:
				return false;
		}
	}

	/**
	 * Whether the boundary falls INSIDE a blank line: a line-break escape on each side of it, so
	 * the group it opens would begin with the newline that terminates the empty line the group
	 * before it just started.
	 *
	 * This is the one reading that spells an ESCAPE rather than a plain character, and it spells
	 * the C-family `\n` the same way `HaxeStringFoldSupport` cuts at. A grammar whose line break
	 * is spelled otherwise simply never matches and keeps the old ranking, which is the
	 * conservative direction: the boundary is legal either way, only the preference is lost.
	 */
	private static function splitsBlankLine(left: String, segments: Array<ConcatSegment>, j: Int): Bool {
		final tail: Int = left.length - 1;
		if (tail < 1 || left.fastCodeAt(tail) != 'n'.code || left.fastCodeAt(tail - 1) != '\\'.code) return false;
		return switch segments[j] {
			case SegText(_, raw):
				raw.length >= 2 && raw.fastCodeAt(0) == '\\'.code && raw.fastCodeAt(1) == 'n'.code;
			case _: false;
		}
	}

	/**
	 * The text immediately left of the boundary at `j`: the run of TEXT segments ending
	 * there, joined, and only as far back as the ranking can still read.
	 *
	 * It reads past `j - 1` at all because the grammar's cut set isolates a lone bracket —
	 * and, after a `\n` cut, a lone run of spaces — into a piece of its own, so the character
	 * that INTRODUCED the separator is then the previous piece's last one. A rank that looked
	 * only at `j - 1` would read the ladder's best class (a bracket a space introduced) as its
	 * worst. Two characters are always enough to stop: a piece holding its own separator plus
	 * one more character answers on its own, and an all-space piece long enough to survive
	 * the bound can only follow a comma or an opening bracket, which rank the same as no
	 * character at all.
	 */
	private static function leftText(segments: Array<ConcatSegment>, j: Int): String {
		var text: String = '';
		var k: Int = j - 1;
		while (k >= 0 && text.length < 2) switch segments[k] {
			case SegText(_, raw):
				text = raw + text;
				k--;
			case _:
				break;
		}
		return text;
	}

}

/**
 * The OPERATOR gate for ONE file: whether the `+` a planned construct re-segments is the
 * language string concatenation, or an operator one of its operand types declares for itself.
 *
 * Per file for the same reason `MacroGate` is. The expensive half — the resolution index and the
 * overload table over it — is shared across the whole run inside `OperatorSelection`, while the
 * type resolver is per source; and that resolver is built on FIRST DEMAND, so a file whose
 * constructs never plan, and every file in a tree where nothing overloads the operator, never
 * pays for it.
 *
 * A null `selection` — a grammar declaring no operator-overload annotation — answers `Builtin`
 * for everything, which is exactly what this rule assumed before the gate existed.
 */
@:nullSafety(Strict)
private class OperatorGate {

	/**
	 * What a finding adds when this gate turned it report-only — the reason, spelled as the
	 * missing proof rather than as a defect, because the site is usually a perfectly ordinary
	 * concatenation whose operand the rule simply could not type. It lives on the gate so the
	 * rule's own member count stays under the decomposition threshold.
	 */
	public static inline final REFUSAL: String = ', but a type in scope overloads the concatenation operator and an '
		+ 'operand of this construct cannot be typed, so nothing rules out the merge changing what the operator does';

	private final _selection: Null<OperatorSelection>;
	private final _seams: Seams;
	private final _file: String;
	private final _source: String;
	private final _tree: QueryNode;

	public function new(selection: Null<OperatorSelection>, seams: Seams, file: String, source: String, tree: QueryNode) {
		_selection = selection;
		_seams = seams;
		_file = file;
		_source = source;
		_tree = tree;
	}

	/**
	 * The verdict for the construct rooted at `node`.
	 *
	 * `literal` marks the SPLIT direction, whose operands are not the children of a `+` at all: a
	 * lone string literal has none, and the operands a split would CREATE are the interpolation
	 * fragments it holds. Asking the merge question there would answer `Builtin` for every split
	 * and leave the MIRROR of the same defect open — `${dir}pages` split back out into
	 * `dir + pages` is the path join reappearing, with the value changing the other way.
	 */
	public function verdictFor(node: QueryNode, literal: Bool): OperatorVerdict {
		final selection: Null<OperatorSelection> = _selection;
		if (selection == null) return Builtin;
		final kinds: Array<String> = [_seams.concatKind];
		if (!selection.declared(kinds)) return Builtin;
		final types: Null<(QueryNode) -> Null<String>> = selection.typesFor(_file, _source, _tree);
		return literal ? selection.verdictOfOperands(interpolated(node), kinds, types) : selection.verdictFor(node, kinds, types);
	}

	/**
	 * The interpolation fragments of a string LITERAL — the operands a split would lift out as
	 * bare `+` operands. A `${ … }` block contributes the one expression it owns, or itself when
	 * it owns none (a rescanned escape-spelled block is childless — see
	 * `RefShape.stringInterpBlockKind`); a `$name` fragment contributes itself. Neither an
	 * empty-handed block nor a `$name` fragment resolves to a type through the shared resolver,
	 * so both answer `Unproven` and leave such a split reported without a fix — the conservative
	 * direction, and the one place this gate is knowingly coarser than it could be.
	 */
	private function interpolated(literal: QueryNode): Array<QueryNode> {
		final blockKind: Null<String> = _seams.stringInterpBlockKind;
		final identKind: Null<String> = _seams.stringInterpIdentKind;
		final out: Array<QueryNode> = [];
		for (child in literal.children) if (blockKind != null && child.kind == blockKind)
			out.push(child.children.length == 1 ? child.children[0] : child)
		else if (identKind != null && child.kind == identKind)
			out.push(child);
		return out;
	}

}
