package anyparse.check;

import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Flags a switch-case branch whose body is EXACTLY one else-less `if` wrapping the
 * whole body, and rewrites it as a case GUARD: `case P: if (c) s;` becomes
 * `case P if (c): s;`. `Info` -- the code is correct, this is a readability
 * simplification that moves the branch's real condition up onto its label.
 *
 * ## Why the gates are correctness, not taste
 *
 * The two forms are NOT interchangeable. A guard that evaluates FALSE resumes
 * pattern matching at the next case, so a later matching arm (or a `default:`)
 * runs; `case P: if (c) ...` consumes the match and does nothing. And a guard on a
 * subject whose arms the compiler checks for exhaustiveness (an `enum` or an
 * `enum abstract`) makes the arm list non-exhaustive, which is a compile error.
 * Every gate below rules out one way that difference becomes observable, and each
 * bails the WHOLE switch rather than the single branch when the hazard is a
 * property of the arm list:
 *
 * 1. STATEMENT position. Only `RefShape.switchStatementKinds` are considered; an
 *    expression switch has to yield a value on every path, so no arm of one may
 *    stop matching.
 * 2. EVERY direct child after the subject is a case branch. That one test rejects a
 *    `default:` arm (which a false guard would newly reach) and equally a
 *    conditional-compilation region wrapping a case run, whose arms this check
 *    cannot enumerate.
 * 3. EVERY pattern of EVERY arm is CONVERTIBLE, in one of two classes: a LITERAL (a
 *    plain string, a numeric, or a negated numeric) or a DOTTED path that does not
 *    name an exhaustiveness-checked type. This is a WHITELIST, so everything else
 *    fails by construction and needs no separate gate: a `_` wildcard and a bare
 *    lowercase binder (both catch-alls a false guard would fall into), a bare
 *    capitalised enum constructor, a constructor-call / array / structure /
 *    or-pattern, and a `case var x:` capture are all outside it. Two exclusions are
 *    deliberate rather than incidental: booleans and `null` are NOT literals here
 *    (`switch (b) { case true: ... }` IS exhaustiveness-checked), and an
 *    INTERPOLATED string literal is not a constant at all, so it is refused --
 *    `StringFoldSupport.literalOf` is what tells the two apart, since a plain
 *    single-quoted literal also carries content children.
 * 4. The arm list does not MIX the two classes. `case "a":` and `case Cst.A:` in one
 *    switch may denote the same value while reading as different patterns, so a
 *    false guard on one could silently activate the other with nothing in the source
 *    showing the collision. A same-class collision stays visible to a reader, and is
 *    what gate 5 compares.
 * 5. No LATER sibling repeats one of this branch's patterns -- a false guard must
 *    have nothing to fall into. Compared on a KEY, not on raw source: a string
 *    literal keys on its raw content, so `case "a":` and `case 'a':` collide as they
 *    must; content carrying a backslash or a quote character is refused outright,
 *    since two such literals can spell one value differently per quoting and
 *    comparing raw forms would MISS the duplicate. Everything else keys on
 *    normalised pattern source, exact for the numeric and dotted shapes admitted.
 * 6. The branch's body is one `if`, and that `if` has no `else`.
 * 7. Nothing but the label's `:` sits between the last pattern and the `if`. This is
 *    the comment gate -- a comment there would have nowhere to go once the `if`
 *    becomes part of the label -- and it is ALSO what rejects an already-guarded
 *    branch, provably: a guard is written in exactly that span, so the span can
 *    never be a bare terminator. An AST-level "is it guarded" clause was removed
 *    rather than kept as an untestable belt.
 * 8. The moved body is not empty and is not an empty statement (`if (c);` would
 *    convert to a dead bare `;` under the label), and holds no
 *    conditional-compilation region.
 * 9. The resulting label fits the file's own `maxLineLength`.
 *
 * ## Resolution, and why this check is a `RiskyFix`
 *
 * Gate 3 resolves a dotted pattern's segments through the project resolution index
 * and rejects the branch when any segment names a type of
 * `RefShape.bareConstructorTypeKinds` (`EnumDecl` / `EnumAbstractDecl` for Haxe --
 * the same set, and for the same reason: those are the types whose values the
 * compiler tracks as a closed constructor list). A `typedef` is followed ONE hop
 * through `TypeDeclInfo.aliasTargetNominal`, which closes the alias hole: without it
 * `typedef Alias = SomeEnumAbstract;` resolves to a `TypedefDecl`, reads as an
 * ordinary constant holder, and the conversion fails to compile.
 *
 * A head declared OUTSIDE the lint scope -- a framework's `MouseEvent.MOUSE_DOWN`,
 * a constant class from a library -- resolves to nothing, and is ACCEPTED rather
 * than skipped. Skipping it would cost the rule its primary real-world shape, since
 * a constant class is exactly what these switches are written over. An alias CHAIN,
 * and an alias target the index could not read, land in the same bucket.
 *
 * That accepted-unresolvable set is precisely why the check implements `RiskyFix`:
 * when the head turns out to be an out-of-scope enum / enum abstract, the guard
 * makes the arm list non-exhaustive and the build fails with `Unmatched patterns`.
 * With a `compilerOracle` configured, `lint --fix` applies the conversion
 * speculatively, typechecks, and REVERTS the file that broke; with no oracle the
 * fix is left report-only and never applied unverified. A wrong-but-COMPILING result
 * is not reachable through this residual -- the exhaustiveness error is a hard
 * compile error, never a silent behaviour change.
 *
 * One narrower residual survives all of the above: gate 5 compares patterns
 * syntactically, so two same-class dotted constants that happen to hold the same
 * value (or `1` and `1.0` in a `Float` switch) read as distinct, and a false guard
 * could fall into that sibling. That one DOES compile, and proving it needs a
 * typechecker; gate 4 exists so the cross-class version of it cannot happen at all.
 *
 * ## Seams, and the one thing that is NOT grammar-agnostic
 *
 * Detection is entirely seam-driven: `switchStatementKinds`, `caseBranchKind`,
 * `plainCasePatternKind`, `parenKind` (the guard slot), `ifStatementKinds`,
 * `blockStmtKind`, `stringLiteralKinds` + `numericLiteralKinds`, `negationKind`,
 * `fieldAccessKind`, `identKind`, `bareConstructorTypeKinds`, `emptyStmtKind`,
 * `conditionalMemberKind`, and `GrammarPlugin.stringFoldSupport` for the plain-vs-
 * interpolated literal question. Any required one unset makes the check a no-op,
 * report and fix alike. The line budget comes from the file's own writer config
 * (`FormatConfigDiscovery` + `GrammarPlugin.layoutMetrics`), never a compiled
 * default.
 *
 * What is NOT parameterised is the SPELLING the fix emits -- ` if (<cond>):` after
 * the pattern list -- nor the label's `:` that gate 7 tests for. Declaring
 * `switchStatementKinds` is therefore the opt-in: a grammar that spells its case
 * guard or its label terminator differently must leave that slot unset, and the
 * check stays inert for it. Adding the two spellings as seams is the additive
 * change to make when a second grammar wants the rule.
 *
 * ## Autofix
 *
 * ONE edit per finding: the span from the last pattern's end through the `if`'s
 * end is replaced by `" if (<cond>): <body>"`. A block body is UNWRAPPED to its
 * trimmed interior, so its statements become the case body one indent level up;
 * taking the interior verbatim (rather than rebuilding it from the child spans) is
 * what preserves a comment inside it, a comment being trivia and never an AST
 * child. A comment trailing the `if` sits past the replaced span and is untouched.
 * Layout is not this edit's business: the caller re-emits through
 * `RefactorSupport.canonicalize`, and the writer owns where the case body lands and
 * whether siblings coordinate. A converted branch carries a guard, so gate 7
 * refuses it on the next pass -- the fix is idempotent by construction.
 */
@:nullSafety(Strict)
final class PreferCaseGuard implements Check implements RiskyFix {

	/** An `if` with no `else` has exactly [cond, then]. */
	private static inline final IF_WITHOUT_ELSE_CHILD_COUNT: Int = 2;

	/** All that may separate the last pattern from the `if`: the label's own colon. */
	private static inline final LABEL_TERMINATOR: String = ':';

	private static final RULE_ID: String = 'prefer-case-guard';
	private static final MESSAGE: String = 'this case body is a single if; write it as a case guard';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a case whose only statement is an else-less if, convertible to a case guard';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (parsed == null) continue;
			final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(FormatConfigDiscovery.discover(entry.file));
			if (metrics == null) continue;
			final tree: QueryNode = parsed;
			final layout: LayoutMetrics = metrics;
			for (candidate in collect({
				tree: tree,
				source: entry.source,
				seams: resolved,
				metrics: layout,
				index: index
			})) violations.push({
				file: entry.file,
				span: candidate.branch,
				rule: RULE_ID,
				severity: Severity.Info,
				message: MESSAGE
			});
		}
		return violations;
	}

	/**
	 * Convert each flagged branch to a guarded one. The candidate set is re-derived
	 * from the tree, so a reported span that no longer names a convertible branch (a
	 * stale or foreign violation) produces no edit. Resolution is whatever the caller
	 * supplies: with no index every dotted head reads as unresolvable, which only ever
	 * WIDENS the candidate set relative to `run` and so can never fabricate an edit for
	 * a branch `run` did not report.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final resolved: Seams = seams;
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$RULE_ID: fix() takes ONE file\'s violations, got $file and ${violation.file}');
		final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (parsed == null) return [];
		final metrics: Null<LayoutMetrics> = plugin.layoutMetrics(FormatConfigDiscovery.discover(file));
		if (metrics == null) return [];
		final tree: QueryNode = parsed;
		final layout: LayoutMetrics = metrics;
		final given: Null<SymbolIndex> = index;
		final byKey: Map<String, Candidate> = [];
		for (candidate in collect({
			tree: tree,
			source: source,
			seams: resolved,
			metrics: layout,
			index: () -> given
		})) byKey['${candidate.branch.from}:${candidate.branch.to}'] = candidate;

		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			final candidate: Null<Candidate> = byKey['${span.from}:${span.to}'];
			if (candidate != null) edits.push({ span: candidate.edit, text: candidate.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	private static inline function numericLiteral(scan: Scan, node: QueryNode): Bool {
		return scan.seams.numericKinds.contains(node.kind) && node.children.length == 0;
	}

	/** Every convertible branch in `scan`'s source, in document order. */
	private static function collect(scan: Scan): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(scan, scan.tree, out);
		return out;
	}

	/** Walk the whole tree so a switch nested in another switch's case body is reached too. */
	private static function walk(scan: Scan, node: QueryNode, out: Array<Candidate>): Void {
		if (scan.seams.switchKinds.contains(node.kind)) collectSwitch(scan, node, out);
		for (child in node.children) walk(scan, child, out);
	}

	/**
	 * Collect `node`'s convertible branches, or none at all when the arm list carries a
	 * hazard that belongs to the SWITCH: a child that is not a case branch (a `default:`
	 * arm, a conditional-compilation region wrapping a case run), a branch whose pattern
	 * run this check cannot read, or any pattern outside the convertible whitelist.
	 */
	private static function collectSwitch(scan: Scan, node: QueryNode, out: Array<Candidate>): Void {
		final branches: Array<QueryNode> = node.children.slice(1);
		final parts: Array<BranchParts> = [];
		for (branch in branches) {
			if (branch.kind != scan.seams.caseBranchKind) return;
			final split: Null<BranchParts> = splitBranch(scan, branch);
			if (split == null) return;
			parts.push(split);
		}
		var literals: Bool = false;
		var dotted: Bool = false;
		for (part in parts) for (pattern in part.patterns) switch patternClass(scan, pattern) {
			case Refused:
				return;
			case LiteralPattern:
				literals = true;
			case DottedPattern:
				dotted = true;
		}
		if (literals && dotted) return;
		final keys: Null<Array<Array<String>>> = patternKeys(scan, parts);
		if (keys == null) return;
		final duplicateKeys: Array<Array<String>> = keys;
		for (i in 0...parts.length) {
			final candidate: Null<Candidate> = candidateFor(scan, branches[i], parts, duplicateKeys, i);
			if (candidate != null) out.push(candidate);
		}
	}

	/**
	 * Split a case branch into its leading pattern run, its optional guard, and the body
	 * statements after them, normalising each pattern's source once for the duplicate scan.
	 * Null when the branch opens with something other than a spanned pattern -- a binder
	 * capture (`case var x:`) projects as its own kind, and a branch whose patterns cannot be
	 * enumerated cannot be gated.
	 */
	private static function splitBranch(scan: Scan, branch: QueryNode): Null<BranchParts> {
		final kids: Array<QueryNode> = branch.children;
		final patterns: Array<QueryNode> = [];
		var at: Int = 0;
		while (at < kids.length && kids[at].kind == scan.seams.plainCasePatternKind) {
			patterns.push(kids[at]);
			at++;
		}
		if (patterns.length == 0) return null;
		// An existing guard is skipped so `body` is the statements alone. REJECTING an
		// already-guarded branch is the label gate's job, and provably so: the guard is
		// written between the last pattern and the label's terminator, which is exactly the
		// span that gate requires to hold nothing but the terminator.
		if (at < kids.length && kids[at].kind == scan.seams.parenKind) at++;
		return { patterns: patterns, body: kids.slice(at) };
	}

	/**
	 * Whether `pattern` is one this check can reason about: a whole string / numeric
	 * literal, a negated numeric literal, or a dotted path proven not to name an
	 * exhaustiveness-checked type. A literal carrying children is an interpolation and
	 * is not a constant, so it is out.
	 */
	private static function patternClass(scan: Scan, pattern: QueryNode): PatternClass {
		if (pattern.children.length != 1) return Refused;
		final node: QueryNode = pattern.children[0];
		return if (scan.seams.stringLiteralKinds.contains(node.kind))
			scan.seams.stringFold.literalOf(node, scan.source) == null ? Refused : LiteralPattern
		else if (numericLiteral(scan, node))
			LiteralPattern
		else if (node.kind == scan.seams.negationKind && node.children.length == 1 && numericLiteral(scan, node.children[0]))
			LiteralPattern
		else if (node.kind == scan.seams.fieldAccessKind && !mayNameExhaustiveType(scan, node))
			DottedPattern
		else
			Refused;
	}

	/**
	 * The duplicate-scan key of every pattern of every arm, or null when one of them cannot
	 * be keyed soundly -- which refuses the whole switch, since an unkeyable pattern is one
	 * the later-duplicate gate could not compare.
	 */
	private static function patternKeys(scan: Scan, parts: Array<BranchParts>): Null<Array<Array<String>>> {
		final out: Array<Array<String>> = [];
		for (part in parts) {
			final row: Array<String> = [];
			for (pattern in part.patterns) {
				final key: Null<String> = patternKey(scan, pattern);
				if (key == null) return null;
				row.push(key);
			}
			out.push(row);
		}
		return out;
	}

	/**
	 * A pattern's identity for the later-duplicate scan. A string literal keys on its raw
	 * CONTENT, so `case "a":` and `case 'a':` -- the same value in two quotings -- collide as
	 * they must. Content carrying a backslash or either quote character is REFUSED (null):
	 * two such literals can spell one value differently per quoting, and comparing their raw
	 * forms would miss the duplicate, which is the unsound direction. Everything else keys on
	 * normalised pattern source, exact for the numeric and dotted-path shapes admitted.
	 */
	private static function patternKey(scan: Scan, pattern: QueryNode): Null<String> {
		final span: Null<Span> = pattern.span;
		if (span == null) return null;
		final node: QueryNode = pattern.children[0];
		final literal: Null<StringLiteral> = scan.seams.stringLiteralKinds.contains(node.kind)
			? scan.seams.stringFold.literalOf(node, scan.source)
			: null;
		if (literal == null) return CheckScan.normalizeSpan(scan.source, span.from, span.to).norm;
		final content: String = literal.content;
		return content.indexOf('\\') != -1 || content.indexOf('"') != -1 || content.indexOf("'") != -1 ? null : 'text:$content';
	}

	/**
	 * Whether any segment of the dotted path `access` names a type whose values the
	 * compiler tracks as a closed constructor list (`bareConstructorTypeKinds`) -- the
	 * types a guard would make the arm list non-exhaustive for. EVERY segment is
	 * checked, not just the head: in `pkg.Enum.VALUE` the type sits in the middle.
	 * A path this check cannot read answers true (refuse); a path whose segments the
	 * index does not know answers false (accept) -- see the type doc for why that
	 * direction is the deliberate one.
	 */
	private static function mayNameExhaustiveType(scan: Scan, access: QueryNode): Bool {
		final segments: Array<String> = [];
		var node: QueryNode = access;
		while (node.kind == scan.seams.fieldAccessKind) {
			final name: Null<String> = node.name;
			if (name == null || node.children.length != 1) return true;
			segments.push(name);
			node = node.children[0];
		}
		if (node.kind != scan.seams.identKind) return true;
		final head: Null<String> = node.name;
		if (head == null) return true;
		segments.push(head);
		final index: Null<SymbolIndex> = scan.index();
		if (index == null) return false;
		final resolved: SymbolIndex = index;
		for (segment in segments) {
			if (declaresExhaustive(scan, resolved, segment)) return true;
			for (alias in aliasTargetsOf(resolved, segment)) if (declaresExhaustive(scan, resolved, alias)) return true;
		}
		return false;
	}

	/** Whether `name` resolves, in `index`, to a declaration of an exhaustiveness-checked kind. */
	private static function declaresExhaustive(scan: Scan, index: SymbolIndex, name: String): Bool {
		for (file in index.declaringFiles(name)) for (type in file.types) if (
			type.name == name && scan.seams.exhaustiveDeclKinds.contains(type.kind)
		)
			return true;
		return false;
	}

	/**
	 * The simple names a `typedef <name> = <Target>;` in scope re-points at -- ONE hop, which
	 * is what closes the alias hole (`typedef Alias = SomeEnumAbstract;` otherwise resolves to
	 * a `TypedefDecl` and reads as convertible). An alias CHAIN, or an alias target the index
	 * could not read as a nominal path, is not followed further: that leaves the same residual
	 * as an out-of-scope head, which the `RiskyFix` oracle catches as `Unmatched patterns`.
	 */
	private static function aliasTargetsOf(index: SymbolIndex, name: String): Array<String> {
		final out: Array<String> = [];
		for (file in index.declaringFiles(name)) for (type in file.types) if (type.name == name) {
			final alias: Null<String> = type.aliasTargetNominal;
			if (alias != null) out.push(alias);
		}
		return out;
	}

	/**
	 * The conversion for the branch at `at`, or null when one of the per-BRANCH gates
	 * refuses it (the per-switch gates having already passed in `collectSwitch`).
	 */
	private static function candidateFor(
		scan: Scan, branch: QueryNode, parts: Array<BranchParts>, keys: Array<Array<String>>, at: Int
	): Null<Candidate> {
		final source: String = scan.source;
		final own: BranchParts = parts[at];
		if (own.body.length != 1) return null;
		final ifNode: QueryNode = own.body[0];
		if (!scan.seams.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_WITHOUT_ELSE_CHILD_COUNT) return null;
		final branchSpan: Null<Span> = branch.span;
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = ifNode.children[0].span;
		final patternSpan: Null<Span> = own.patterns[own.patterns.length - 1].span;
		if (branchSpan == null || ifSpan == null || condSpan == null || patternSpan == null) return null;
		if (repeatedLater(keys, at)) return null;
		if (source.substring(patternSpan.to, ifSpan.from).trim() != LABEL_TERMINATOR) return null;
		final body: Null<String> = bodyText(scan, ifNode.children[1]);
		if (body == null) return null;
		final guard: String = ' if (${source.substring(condSpan.from, condSpan.to)}):';
		final label: String = source.substring(branchSpan.from, patternSpan.to) + guard;
		return columnOf(scan, branchSpan.from) + collapsedWidth(label) > scan.metrics.lineWidth
			? null
			: { branch: branchSpan, edit: new Span(patternSpan.to, ifSpan.to), text: '$guard $body' };
	}

	/**
	 * The text the moved `if` body becomes: a block's trimmed INTERIOR (braces stripped,
	 * everything between them verbatim so an interior comment survives), or a bare
	 * statement's own source. Null when the body is empty, or holds a
	 * conditional-compilation region -- moving one across an indent level is not
	 * something this edit is prepared to prove safe.
	 */
	private static function bodyText(scan: Scan, then: QueryNode): Null<String> {
		final span: Null<Span> = then.span;
		if (span == null || then.kind == scan.seams.emptyStmtKind || containsConditional(then, scan.seams)) return null;
		if (then.kind != scan.seams.blockStmtKind) return StringTools.trim(scan.source.substring(span.from, span.to));
		if (then.children.length == 0) return null;
		final interior: String = StringTools.trim(scan.source.substring(span.from + 1, span.to - 1));
		return interior == '' ? null : interior;
	}

	private static function containsConditional(node: QueryNode, seams: Seams): Bool {
		final kind: Null<String> = seams.conditionalKind;
		if (kind == null) return false;
		if (node.kind == kind) return true;
		for (child in node.children) if (containsConditional(child, seams)) return true;
		return false;
	}

	/**
	 * Whether a LATER sibling arm repeats any pattern of the arm at `at` -- what a false guard
	 * would newly fall into. Compared as normalised pattern SOURCE (`splitBranch` computes it
	 * once per branch), which is exact for the literal / dotted-path shapes the pattern
	 * whitelist admits.
	 */
	private static function repeatedLater(keys: Array<Array<String>>, at: Int): Bool {
		final own: Array<String> = keys[at];
		for (i in at + 1...keys.length) for (key in keys[i]) if (own.contains(key)) return true;
		return false;
	}

	/** The display column `at` sits at on its own line, tabs counted as the writer's indent width. */
	private static function columnOf(scan: Scan, at: Int): Int {
		final start: Int = at == 0 ? 0 : scan.source.lastIndexOf('\n', at - 1) + 1;
		return CheckScan.displayColumn(scan.source, start, at, scan.metrics.indentWidth);
	}

	/** `text`'s width once every whitespace run collapses to one column -- the label the writer would emit. */
	private static function collapsedWidth(text: String): Int {
		var cols: Int = 0;
		var pending: Bool = false;
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				pending = cols > 0;
			} else {
				if (pending) cols++;
				pending = false;
				cols++;
			}
		}
		return cols;
	}

	/** The seam kinds both passes read, or null when the grammar leaves a required one unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final switchKinds: Array<String> = shape.switchStatementKinds ?? [];
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final numericKinds: Array<String> = shape.numericLiteralKinds ?? [];
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		final exhaustiveKinds: Array<String> = shape.bareConstructorTypeKinds ?? [];
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		final plainKind: Null<String> = shape.plainCasePatternKind;
		final parenKind: Null<String> = shape.parenKind;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		return switchKinds.length == 0 || ifKinds.length == 0 || numericKinds.length + stringKinds.length == 0
			|| exhaustiveKinds.length == 0 || caseBranchKind == null || plainKind == null || parenKind == null || blockStmtKind == null
			|| fieldAccessKind == null || stringFold == null
			? null
			: {
				switchKinds: switchKinds,
				caseBranchKind: caseBranchKind,
				plainCasePatternKind: plainKind,
				parenKind: parenKind,
				ifKinds: ifKinds,
				blockStmtKind: blockStmtKind,
				stringLiteralKinds: stringKinds,
				numericKinds: numericKinds,
				stringFold: stringFold,
				negationKind: shape.negationKind,
				fieldAccessKind: fieldAccessKind,
				identKind: shape.identKind,
				exhaustiveDeclKinds: exhaustiveKinds,
				conditionalKind: shape.conditionalMemberKind,
				emptyStmtKind: shape.emptyStmtKind
			};
	}

}

/** One convertible branch: the span reported, the span replaced, and the replacement text. */
private typedef Candidate = {
	final branch: Span;
	final edit: Span;
	final text: String;
};
/**
 * How a case pattern classifies for the convertibility whitelist: `Refused` is outside it
 * (and refuses the whole switch), while `LiteralPattern` and `DottedPattern` are the two
 * admitted classes. They are kept apart because a switch MIXING them is refused: a literal
 * and a dotted constant can denote the same value while reading as distinct patterns, so
 * a false guard could silently fall into the other one. Same-class collisions stay visible
 * to a reader and are what the duplicate scan compares.
 */
private enum abstract PatternClass(Int) {
	final Refused = 0;
	final LiteralPattern = 1;
	final DottedPattern = 2;
}

/** A case branch cut into its pattern run, its guard presence, and its body statements. */
private typedef BranchParts = {
	final patterns: Array<QueryNode>;
	final body: Array<QueryNode>;
};

/** The per-file scan context: the source, the resolved seams, the line budget, and lazy type resolution. */
private typedef Scan = {
	final tree: QueryNode;
	final source: String;
	final seams: Seams;
	final metrics: LayoutMetrics;
	final index: () -> Null<SymbolIndex>;
};

/** The seam kinds `PreferCaseGuard` resolves once per run. */
private typedef Seams = {
	final switchKinds: Array<String>;
	final caseBranchKind: String;
	final plainCasePatternKind: String;
	final parenKind: String;
	final ifKinds: Array<String>;
	final blockStmtKind: String;
	final stringLiteralKinds: Array<String>;
	final numericKinds: Array<String>;

	/** Tells a PLAIN string literal from an interpolated one, and yields its raw content for the duplicate key. */
	final stringFold: StringFoldSupport;
	final negationKind: Null<String>;
	final fieldAccessKind: String;
	final identKind: String;
	final exhaustiveDeclKinds: Array<String>;
	final conditionalKind: Null<String>;
	final emptyStmtKind: Null<String>;
};
