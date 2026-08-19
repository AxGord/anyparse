package anyparse.check;

import anyparse.check.CasePatternScan.CaseSeams;
import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The seam kinds the check resolves once per run: `scan` is the case-pattern kind set both
 * case-arm rules share (`CasePatternScan`), and `orPatternKind` — the node a `case A | B:` label
 * projects its alternation as — is the one this rule adds on top.
 */
private typedef SeparatorSeams = {
	final scan: CaseSeams;
	final orPatternKind: String;
}

/**
 * Flags a switch case label whose TOP-LEVEL pattern separator is not the project's configured
 * one. Haxe spells the same label two ways — `case A, B:` (several patterns) and `case A | B:`
 * (one or-pattern) — and a codebase mixing them reads as though the two meant different things.
 * `Info`, with a `--fix` that rewrites the separator character and nothing else; the spacing
 * around it is the writer's call, so the caller's canonicalisation finishes the edit.
 *
 * ## The two styles
 *
 *  - `comma` — the DEFAULT, and the reading of any unrecognised `style` value. A case pattern
 *    whose DIRECT child is an or-pattern is the finding; the fix turns every `|` of that chain
 *    into a `,`.
 *  - `pipe` — a branch carrying two or more leading patterns is the finding; the fix turns every
 *    separating `,` into a `|`. Note the layout cost on a LONG label: a comma-separated one that
 *    overflows the line width FILLS its continuation lines, while the joined form is an expression
 *    chain the writer breaks ONE OPERAND PER LINE. Measured over this repository, the comma
 *    direction takes 149 lines out and the pipe direction puts 11 back, nearly all of them in a
 *    single file of wide constant labels.
 *
 * Only the TOP level of a label is ever touched. A NESTED or-pattern (`case Some(E | F):`) has no
 * comma spelling at all, and it is not the direct child of the pattern wrapper, so neither
 * direction reaches it.
 * Neither is anything inside a REIFICATION subtree (`RefShape.opaqueKinds` — a `macro …`
 * quotation): there the source IS the AST a macro builds, and the two spellings do not build the
 * same one — measured, `macro switch x { case A | B: … }` reifies its label as ONE
 * `EBinop(OpOr, …)` value while `case A, B:` reifies as TWO, so respelling the separator silently
 * changes what a macro reading `Case.values` sees, with nothing rejecting the result.
 *
 * ## Why the pipe direction gates and the comma direction does not
 *
 * SPLITTING an or-pattern into several patterns is always sound. Measured on Haxe 4.3:
 * `case A(n) | B(n):` and `case A(n), B(n):` bind and match identically, with or without a guard,
 * and `case 1 | 2:` is an alternation rather than the bitwise `3` the same tokens would mean in
 * an expression. So the comma direction flags on shape alone.
 *
 * JOINING is not always sound, because an `=`-capture binds LOOSER than `|` and TIGHTER than `,`:
 * `case v = A | B:` captures the whole alternation and compiles, while `case v = A, B:` is
 * rejected outright (`Variable v must appear exactly once in each sub-pattern`). Every pattern
 * that BINDS carries the same trap in miniature — `case a, b:` joined into `case a | b:` stops
 * compiling.
 *
 * So the pipe direction gates on a positive WHITELIST and skips the WHOLE branch unless every one
 * of its patterns passes: a bare identifier spelled as a constructor or constant (upper-case
 * initial), a dotted constant path, a constructor call over whitelisted arguments, a string /
 * numeric / boolean / null literal, a negated numeric, and an or-pattern over the same. A partial
 * join does not typecheck, which is why one refused pattern withdraws the whole finding rather
 * than part of the fix. Everything else is refused, including shapes the whitelist has never been
 * shown — a `var x` capture, an `=`-capture, an extractor, an array or structure pattern, and the
 * bare WILDCARD, which keeps the ubiquitous `case null, _:` idiom exactly as written. That one is
 * a style call rather than a correctness one: `case null | _:` compiles and behaves identically
 * (measured), but the comma spelling is what the idiom is read by.
 *
 * ## Default OFF
 *
 * Which separator a project writes is a house style, not a defect — and this rule PICKS A SIDE, so
 * running it unasked would rewrite whichever side a codebase had already settled on (309 findings
 * over this repository, every one of them the same way). It ships opt-in (`DefaultOff`): enable it
 * with `"case-pattern-separator": { "enabled": true }`, then set `style` if the comma default is
 * not the house style. An explicit `--rule case-pattern-separator` bypasses enablement, as for any
 * rule.
 *
 * ## Grammar-agnostic
 *
 * Every kind arrives through `CasePatternScan.seamsOf` plus `RefShape.orPatternKind`; a grammar
 * leaving any of them unset makes the check a no-op. `opaqueKinds` is the exception: unset there
 * means the grammar has no reification construct, so there is nothing to skip and the check runs
 * everywhere.
 */
@:nullSafety(Strict)
final class CasePatternSeparator implements Check implements DefaultOff implements ConfigAware {

	private static inline final RULE_ID: String = 'case-pattern-separator';

	/** The option naming the separator a case label must carry. */
	private static inline final OPTION_STYLE: String = 'style';

	/** The `style` value asking for `case A | B:`; every other value — and no value — is the comma default. */
	private static inline final STYLE_PIPE: String = 'pipe';

	/** A case-pattern wrapper holds exactly its one pattern. */
	private static inline final PATTERN_CHILD_COUNT: Int = 1;

	/** A label needs at least this many top-level patterns before a `|` join has anything to join. */
	private static inline final MIN_ALTERNATIVE_COUNT: Int = 2;

	private static inline final PIPE: Int = '|'.code;
	private static inline final COMMA: Int = ','.code;

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
		return 'a switch case whose pattern separator does not match the configured style (comma or pipe)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<SeparatorSeams> = seamsOf(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final pipe: Bool = pipeStyle(LintConfig.resolveWith(_resolveConfig, entry.file));
			walk(violations, entry.file, tree, seams, pipe);
		}
		return violations;
	}

	/**
	 * `fix` rewrites ONE character per seam — an or-pattern's `|` into a `,`, or the `,` between
	 * two patterns into a `|`. Nothing around it is reflowed: the caller batches these into a
	 * single `RefactorSupport.canonicalize`, and it is the WRITER that restores the spacing,
	 * exactly as `duplicate-case`'s deletion relies on.
	 *
	 * That last part holds only where the writer actually re-emits the region. In a VERBATIM one
	 * — inside a `@formatter:off` block, or inside a string-interpolation literal, both of which
	 * the writer copies through — the bare character edit survives as written, so `case A | B:`
	 * becomes `case A , B:`. Measured, and harmless: the result parses, means the same thing, and
	 * re-canonicalises to nothing (the file still counts as canonical, so no gate reports it). The
	 * edit span stays one character all the same — widening it to swallow the preceding whitespace
	 * would rejoin lines inside exactly the regions whose layout a user pinned on purpose.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final seams: Null<SeparatorSeams> = seamsOf(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, [seams.scan.caseBranchKind], byKey);
		final pipe: Bool = pipeStyle(LintConfig.resolveWith(_resolveConfig, violations[0].file));
		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			final branch: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (branch == null) continue;
			final produced: Array<{ span: Span, text: String }> = pipe
				? pipeEdits(seams, source, branch)
				: commaEdits(seams, source, branch);
			for (edit in produced) edits.push(edit);
		}
		return edits;
	}

	/**
	 * The seam kinds both halves of the check read, or null when the grammar leaves the case-pattern
	 * set or the OR-PATTERN kind unset — which is what makes the whole check a no-op for that
	 * language.
	 */
	private static function seamsOf(plugin: GrammarPlugin): Null<SeparatorSeams> {
		final resolved: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		final orKind: Null<String> = plugin.refShape().orPatternKind;
		if (resolved == null || orKind == null) return null;
		final scan: CaseSeams = resolved;
		final orPatternKind: String = orKind;
		return { scan: scan, orPatternKind: orPatternKind };
	}

	/** Whether the file's config asks for the `pipe` style; every other value reads as the comma default. */
	private static function pipeStyle(config: LintConfig): Bool {
		return config.stringOption(RULE_ID, OPTION_STYLE) == STYLE_PIPE;
	}

	/**
	 * Walk `node`, flagging every case branch whose separator differs from the configured style.
	 * The whole tree is walked so a switch nested in a case BODY is reached too — except a MACRO
	 * REIFICATION subtree, which is skipped whole: what is written there is the AST a macro builds,
	 * and the two spellings do not build the same one (see the type doc).
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, seams: SeparatorSeams, pipe: Bool): Void {
		if (seams.scan.opaqueKinds.contains(node.kind)) return;
		if (node.kind == seams.scan.caseBranchKind) {
			final span: Null<Span> = node.span;
			final flagged: Bool = pipe ? joinableRun(seams, node) : hasOrPattern(seams, node);
			if (span != null && flagged) out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: pipe
					? 'comma-separated case patterns; the configured separator style is \'|\''
					: 'an or-pattern \'|\' in a case label; the configured separator style is \',\''
			});
		}
		for (child in node.children) walk(out, file, child, seams, pipe);
	}

	/** Whether `branch` carries a TOP-LEVEL or-pattern — the comma style's finding. */
	private static function hasOrPattern(seams: SeparatorSeams, branch: QueryNode): Bool {
		for (pattern in CasePatternScan.patternRun(seams.scan, branch)) if (orRootOf(seams, pattern) != null) return true;
		return false;
	}

	/** The or-pattern `pattern` wraps DIRECTLY, or null when it wraps anything else. */
	private static function orRootOf(seams: SeparatorSeams, pattern: QueryNode): Null<QueryNode> {
		if (pattern.kind != seams.scan.plainCasePatternKind || pattern.children.length != PATTERN_CHILD_COUNT) return null;
		final root: QueryNode = pattern.children[0];
		return root.kind == seams.orPatternKind ? root : null;
	}

	/**
	 * Whether `branch`'s patterns may be JOINED by `|` — two or more of them, every one a plain
	 * wrapper over a whitelisted pattern (see the type doc). The gate covers the WHOLE branch: one
	 * refused pattern leaves it unreported, since a join of only the others does not typecheck.
	 */
	private static function joinableRun(seams: SeparatorSeams, branch: QueryNode): Bool {
		final run: Array<QueryNode> = CasePatternScan.patternRun(seams.scan, branch);
		if (run.length < MIN_ALTERNATIVE_COUNT) return false;
		for (pattern in run) {
			if (pattern.kind != seams.scan.plainCasePatternKind || pattern.children.length != PATTERN_CHILD_COUNT) return false;
			if (!joinable(seams, pattern.children[0], true)) return false;
		}
		return true;
	}

	/**
	 * Whether `node` is a pattern a `|` join may carry — the positive whitelist of the type doc.
	 * `whole` marks a node that IS one of the label's top-level alternatives, where the bare
	 * wildcard is refused so the `case null, _:` idiom keeps its comma; nested inside a
	 * constructor's arguments the same wildcard binds nothing and is accepted.
	 */
	private static function joinable(seams: SeparatorSeams, node: QueryNode, whole: Bool): Bool {
		final kind: String = node.kind;
		return if (kind == seams.orPatternKind)
			joinableOperands(seams, node, whole)
		else if (kind == seams.scan.identKind)
			joinableIdent(seams, node, whole)
		else if (kind == seams.scan.callKind)
			joinableCall(seams, node)
		// A leading minus reaches only a numeric literal in practice — Haxe rejects `case -c:` for
		// any constant `c` — so this arm exists to carry `case -1, -2:` back, not to admit a family.
		else if (kind == seams.scan.negationKind)
			node.children.length == 1 && joinable(seams, node.children[0], false)
		else
			seams.scan.constantLeafKinds.contains(kind);
	}

	/** Whether every operand of the or-pattern `node` is joinable; its operands sit at the same level `node` does. */
	private static function joinableOperands(seams: SeparatorSeams, node: QueryNode, whole: Bool): Bool {
		return node.children.foreach(child -> joinable(seams, child, whole));
	}

	/**
	 * Whether the bare identifier `node` is joinable: a constructor / constant spelling binds
	 * nothing, and so does the wildcard — but the wildcard only BELOW the top level, since as a
	 * whole alternative it is the `case null, _:` idiom this rule leaves written as it is.
	 */
	private static function joinableIdent(seams: SeparatorSeams, node: QueryNode, whole: Bool): Bool {
		final name: Null<String> = CasePatternScan.patternName(node);
		return name != null && ((!whole && name == seams.scan.wildcardPatternName) || CasePatternScan.startsUpper(name));
	}

	/** Whether the extraction pattern `node` is joinable: a named callee over joinable arguments. */
	private static function joinableCall(seams: SeparatorSeams, node: QueryNode): Bool {
		if (!CasePatternScan.isNamedCallee(seams.scan, node)) return false;
		for (i in 1...node.children.length) if (!joinable(seams, node.children[i], false)) return false;
		return true;
	}

	/**
	 * The `|` to `,` edits for `branch` — one per seam of every top-level or-pattern it carries,
	 * the chain flattened so a left-nested `A | B | C` yields both. Empty when ANY seam cannot be
	 * pinned: the branch then stays report-only rather than half-rewritten.
	 */
	private static function commaEdits(seams: SeparatorSeams, source: String, branch: QueryNode): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (pattern in CasePatternScan.patternRun(seams.scan, branch)) {
			final root: Null<QueryNode> = orRootOf(seams, pattern);
			if (root == null) continue;
			final leaves: Array<QueryNode> = [];
			flattenOperands(seams.orPatternKind, root, leaves);
			final produced: Null<Array<{ span: Span, text: String }>> = seamEdits(source, leaves, PIPE, ',');
			if (produced == null) return [];
			for (edit in produced) edits.push(edit);
		}
		return edits;
	}

	/**
	 * The `,` to `|` edits for `branch` — one per gap between consecutive top-level patterns.
	 * Empty when any gap cannot be pinned, on the same all-or-nothing terms as `commaEdits`.
	 */
	private static function pipeEdits(seams: SeparatorSeams, source: String, branch: QueryNode): Array<{ span: Span, text: String }> {
		return seamEdits(source, CasePatternScan.patternRun(seams.scan, branch), COMMA, '|') ?? [];
	}

	/**
	 * The one-character edits replacing the `separator` between each consecutive pair of `nodes`
	 * with `text`, or NULL when ANY gap cannot be pinned. Null rather than an empty array because
	 * a caller must be able to tell "nothing to do here" from "this label refused a rewrite" — a
	 * half-respelled label is worse than an unfixed one.
	 */
	private static function seamEdits(
		source: String, nodes: Array<QueryNode>, separator: Int, text: String
	): Null<Array<{ span: Span, text: String }>> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (i in 1...nodes.length) {
			final at: Null<Int> = seamOf(source, nodes[i - 1], nodes[i], separator);
			if (at == null) return null;
			edits.push({ span: new Span(at, at + 1), text: text });
		}
		return edits;
	}

	/** `root`'s or-pattern chain flattened into its operand leaves, left to right. */
	private static function flattenOperands(orPatternKind: String, root: QueryNode, out: Array<QueryNode>): Void {
		if (root.kind != orPatternKind) {
			out.push(root);
			return;
		}
		for (child in root.children) flattenOperands(orPatternKind, child, out);
	}

	/** The offset of the one `separator` between `left` and `right`, or null when either lacks a span. */
	private static function seamOf(source: String, left: QueryNode, right: QueryNode, separator: Int): Null<Int> {
		final leftSpan: Null<Span> = left.span;
		final rightSpan: Null<Span> = right.span;
		return leftSpan == null || rightSpan == null ? null : soleSeparator(source, leftSpan.to, rightSpan.from, separator);
	}

	/**
	 * The offset of the ONE occurrence of `separator` in `[from, to)`, or null when the range holds
	 * none or several — the demand that refuses a gap this rewrite would have to guess at.
	 *
	 * A plain scan is enough because the gap cannot hold a COMMENT: the writer drops any comment
	 * written inside a case label (measured, for both separators and both comment forms), so such a
	 * file never round-trips and `RefactorSupport.canonicalize` refuses it before — and again after
	 * — this fix runs. Re-deriving that by hand-parsing comments here would only add a second,
	 * worse lexer to disagree with the one the tree already came from.
	 */
	private static function soleSeparator(source: String, from: Int, to: Int, separator: Int): Null<Int> {
		var found: Int = -1;
		for (at in from ... to) if (source.fastCodeAt(at) == separator) {
			if (found >= 0) return null;
			found = at;
		}
		return found < 0 ? null : found;
	}

}
