package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Flags an outer `case P(b):` whose body is EXACTLY one `switch b { … }` on that
 * binder, and rewrites it as DEEP PATTERN MATCHING: each inner `case Q_i: body_i`
 * is spliced back as an outer `case P(Q_i): body_i`, replacing the whole outer arm.
 * Only the switched binder's slot substitutes — every other slot of a multi-binder
 * pattern keeps its text verbatim. `Info` — the code is correct, this is a
 * readability simplification that flattens two match levels into one. DEFAULT OFF:
 * how deep a pattern should read is a project style call, so opt in with
 * `"collapse-nested-switch": { "enabled": true }`.
 *
 * ## Why the gates are correctness, not taste
 *
 * The ONE way this rewrite can change behaviour is a value that matched `P(...)`
 * but matched no inner arm. Before, it fell out of the nested switch and the outer
 * arm was CONSUMED; after, it resumes matching at the outer switch's LATER arms.
 * The coverage gate below closes that; the shape gates above it rule out the ways
 * the splice would not even be well-formed:
 *
 * 1. The arm is a `caseBranchKind` — a `defaultBranchKind` binds nothing.
 * 2. Its leading pattern run is EXACTLY ONE pattern, holding exactly one node.
 *    `case A(c), B(c):` offers two slots for one substitution.
 * 3. No guard. A guard sits between the pattern run and the body, in the very span
 *    the spliced label has to reuse. Stated as its own requirement, though the
 *    exactly-two-children shape of gates 4-5 refuses a guarded arm too — no fixture
 *    can separate the two.
 * 4. Exactly ONE body statement, and (5) that statement IS a switch. A block-wrapped
 *    `{ switch b { … } }` is REFUSED rather than unwrapped here: `unnecessary-block`
 *    owns that unwrap and the two compose across `--fix` passes.
 * 6. The nested switch has a subject and at least one arm.
 * 7. The subject is a bare identifier whose first character is NOT an uppercase
 *    ASCII letter. In Haxe — and in every ML-family pattern syntax — a capitalised
 *    bare identifier in a pattern position is a CONSTRUCTOR or constant reference,
 *    not a capture binder, and substituting a sub-pattern into a constant's slot
 *    would change what the arm matches. This is a family SPELLING assumption of
 *    exactly the kind `prefer-case-guard` already makes (it hardcodes the ` if (…):`
 *    guard spelling), and it is licensed by the same opt-in: a grammar that spells
 *    patterns differently leaves `plainCasePatternKind` / `wildcardPatternName`
 *    unset and the check stays inert.
 * 8. BINDER ISOLATION. The name is mentioned exactly TWICE in the whole arm: once
 *    inside the outer pattern, once as the nested switch's subject. A third mention
 *    is either a read the splice would STRAND (the deep pattern rebinds that slot
 *    per arm, so a body read of `b` no longer resolves) or a re-binding that changes
 *    what the name means. All three mention shapes count — an ordinary identifier, a
 *    string-interpolation identifier (a `'$b'` read is not an `identKind`), and a
 *    case-pattern binder (`case var b:`). A body use of the binder is deliberate future
 *    work; the `=`-capture form (`case P(b = …)`) is refused outright by gate 9.
 * 9. NO `=`-CAPTURE anywhere in the outer pattern. `case b = P(x):` and `case P(b = Q):`
 *    both put the binder's name where only a NAME may stand, so splicing a pattern into
 *    that slot would emit `case Q = P(x)` / `case P(R = Q)` — text the compiler rejects.
 *    Gate 8 cannot see this on its own: a capture's left side IS an ordinary identifier,
 *    so it counts as exactly the one in-pattern mention that gate demands.
 * 10. No conditional-compilation region anywhere in the arm — an `#if` wrapping
 *     arms holds a run this scan cannot enumerate.
 * 11. No opaque (reification) node anywhere in the arm, AND the arm is not itself
 *     inside one (`walk` never descends into an opaque subtree). A splice in either
 *     position may reference bindings this scan cannot see — gate 8 counts the
 *     mentions it can read, and a `$expr` built at macro time is not one of them.
 *     The enclosing direction is not decoration: both of anyparse's OWN matches for
 *     this rule were arms written inside a `macro { … }`.
 * 12. EVERY child of the nested switch after its subject is a case branch. That one
 *     test refuses an inner `default:` (which carries no pattern to splice) and an
 *     inner `#if`-wrapped arm run alike.
 * 13. BINDER FRESHNESS. No inner pattern binds a name the outer pattern already binds in
 *     ANOTHER slot. Nested, the inner binding merely SHADOWED the outer one; spliced, the
 *     two land in a SINGLE pattern, and Haxe rejects `case P(a, Q(a))` with `Variable a is
 *     bound multiple times`. Runs last: it reads the inner arm list gate 12 just validated.
 *
 * ## What the emission reproduces, and the comment gates that follow from it
 *
 * An emitted arm is `lead + prefix + pattern + suffix` per inner pattern (joined by
 * the inner separators), then the inner guard, the label terminator, and the inner
 * body. Every one of those fragments is READ OUT OF THE SOURCE — the `case` lead,
 * the terminator, the guard's ` if ` spelling — so no keyword is hardcoded and the
 * outer label's own text survives. Everything ELSE in the region is DISCARDED: the
 * `switch b {` header, the closing brace, the gaps between arms, and whatever
 * trails the nested switch inside the arm. A comment in any of those regions
 * refuses the collapse rather than being silently dropped, and a comment in the
 * outer pattern's prefix / suffix refuses because those are reproduced ONCE PER
 * SPLICED ARM — it would be DUPLICATED, not merely moved. (That also refuses the
 * rare pattern carrying a `//` inside a string literal: a documented conservative
 * miss.) A comment INSIDE an inner body is kept, the body being taken verbatim.
 *
 * ## The coverage gate
 *
 * Three shapes produce a value that falls out of the collapsed run: a nested switch
 * with no catch-all, a catch-all that is merged away, and a run of guarded arms that
 * all reject. One property closes all three.
 *
 * `fallThroughHarmless` holds when the OUTER switch is in statement position (an
 * expression switch's arms must each yield a value, so it has no empty arm to fall
 * into and this path is never sound for one), there is at least one later outer arm,
 * EVERY later arm is unguarded, EXTRACTOR-FREE, and EMPTY-bodied (so falling
 * into any of them does nothing — exactly what falling out of the nested switch did
 * — and neither a guard nor an extractor is newly evaluated: an extractor RUNS code
 * while MATCHING, so reaching one of those arms for the first time would run it),
 * and at least one of them is a catch-all (which is what keeps the arm list
 * exhaustive once coverage shrinks). Then:
 *
 * - MERGE — a trailing catch-all with an EMPTY body, under a harmless fall-through,
 *   is DROPPED from the emitted run: both wildcards do nothing, so one is redundant.
 *   A catch-all in a NON-final position is never eligible: merging it away would
 *   revive the arms it currently makes unreachable.
 * - COVERS — any other trailing catch-all is EMITTED, as `case P(_): <its body>`.
 *   The spliced run then matches everything the outer arm did, nothing falls
 *   through, and no outer gate is needed. This is also what makes inner GUARDS safe
 *   to carry over verbatim: a failing guard falls to the next spliced arm in the
 *   same order, and the emitted `case P(_)` backstops the whole run exactly as the
 *   inner catch-all did.
 * - Otherwise — no trailing catch-all at all — `fallThroughHarmless` is REQUIRED.
 *
 * An emitted run that would be EMPTY (a nested switch whose only arm is the merged
 * catch-all) is refused: that is dead-arm removal, not pattern deepening.
 *
 * ## Seams, autofix, idempotence
 *
 * Detection is seam-driven: `switchKinds`, `switchStatementKinds`, `caseBranchKind`,
 * `defaultBranchKind`, `plainCasePatternKind`, `wildcardPatternName`, `identKind`,
 * `parenKind`, `assignKind`, `stringInterpIdentKind`, `casePatternBinderKinds`,
 * `casePatternExtractorKinds`, `conditionalMemberKind` and `opaqueKinds`. A required
 * one unset makes the check a no-op, report and fix alike; an optional one unset only
 * closes the path that reads it (with `switchStatementKinds` unset the outer
 * fall-through path never opens, so only the COVERS shape collapses; with
 * `casePatternExtractorKinds` unset that path models a family whose patterns evaluate
 * nothing). No resolution index and no line budget are consulted — every gate is a
 * structurally-provable shape invariant, which is why this is NOT a `RiskyFix`: the edit is
 * applied unverified like every other builtin.
 *
 * ONE edit per finding replaces the whole outer arm with the joined run. Layout is
 * not this edit's business: the caller re-emits through
 * `RefactorSupport.canonicalize`, which owns indentation and arm wrapping. After the
 * fix each arm's body is the former inner body, so a second pass finds nothing —
 * unless that body is ITSELF a nested switch on its own binder, in which case the
 * next pass collapses one more level, converging.
 */
@:nullSafety(Strict)
final class CollapseNestedSwitch implements Check implements DefaultOff {

	/** All that may separate the outer pattern from the nested switch: the label's own terminator. */
	private static inline final LABEL_TERMINATOR: String = ':';

	/** A collapsible nested switch has a subject and at least one arm. */
	private static inline final MIN_INNER_CHILDREN: Int = 2;

	/** The binder is mentioned exactly twice: once inside the outer pattern, once as the nested switch's subject. */
	private static inline final BINDER_MENTION_COUNT: Int = 2;

	/** A collapsible outer arm has exactly [pattern, nested switch]. */
	private static inline final COLLAPSIBLE_ARM_CHILD_COUNT: Int = 2;

	private static final RULE_ID: String = 'collapse-nested-switch';
	private static final MESSAGE: String = 'this case body is a switch on its own binder; collapse it into a deep pattern';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a case whose only statement is a switch on its own binder, collapsible into a deep pattern';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (parsed == null) continue;
			final tree: QueryNode = parsed;
			for (candidate in collect({ tree: tree, source: entry.source, seams: resolved })) violations.push({
				file: entry.file,
				span: candidate.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: MESSAGE
			});
		}
		return violations;
	}

	/**
	 * Collapse each flagged arm. The candidate set is re-derived from the tree, so a
	 * reported span that no longer names a collapsible arm (a stale or foreign violation)
	 * produces no edit. Nested findings — a three-level nest reports the outer arm AND the
	 * middle one — are de-overlapped by `dropContainedEdits`, so one pass deepens one
	 * level and the next pass deepens the one below it.
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
		final tree: QueryNode = parsed;
		final byKey: Map<String, Candidate> = [];
		for (candidate in collect({ tree: tree, source: source, seams: resolved }))
			byKey['${candidate.span.from}:${candidate.span.to}'] = candidate;

		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			final candidate: Null<Candidate> = byKey['${span.from}:${span.to}'];
			if (candidate != null) edits.push({ span: candidate.span, text: candidate.text });
		}
		return CanonicalEdit.dropContainedEdits(edits);
	}

	/** Every collapsible arm in `scan`'s source, in document order. */
	private static function collect(scan: Scan): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(scan, scan.tree, out);
		return out;
	}

	/**
	 * Walk the whole tree so a switch nested in another switch's arm is reached too, but never
	 * DESCEND into an opaque (reification) subtree: a splice inside one may carry a read of the
	 * binder that no source scan can see, so an arm written inside `macro { … }` is out of reach
	 * by construction. The mirror direction — a reification nested INSIDE an otherwise ordinary
	 * arm — is the gate `candidateFor` applies.
	 */
	private static function walk(scan: Scan, node: QueryNode, out: Array<Candidate>): Void {
		if (scan.seams.opaqueKinds.contains(node.kind)) return;
		if (scan.seams.switchKinds.contains(node.kind)) for (at in 1...node.children.length) {
			final candidate: Null<Candidate> = candidateFor(scan, node, at);
			if (candidate != null) out.push(candidate);
		}
		for (child in node.children) walk(scan, child, out);
	}

	/**
	 * The collapse for `switchNode`'s arm at `at`, or null when any structural gate refuses
	 * it. The gates run in the order they are documented on the type, and that order is what
	 * each refusal test discriminates: a fixture aimed at the binder-isolation gate must pass
	 * every shape gate above it.
	 */
	private static function candidateFor(scan: Scan, switchNode: QueryNode, at: Int): Null<Candidate> {
		final seams: Seams = scan.seams;
		final arm: QueryNode = switchNode.children[at];
		if (arm.kind != seams.caseBranchKind) return null;
		final kids: Array<QueryNode> = arm.children;
		if (patternRunLength(seams, kids) != 1) return null;
		final plain: QueryNode = kids[0];
		if (plain.children.length != 1) return null;
		final pat: QueryNode = plain.children[0];
		if (kids.length > 1 && kids[1].kind == seams.parenKind) return null;
		if (kids.length != COLLAPSIBLE_ARM_CHILD_COUNT) return null;
		final inner: QueryNode = kids[1];
		if (!seams.switchKinds.contains(inner.kind) || inner.children.length < MIN_INNER_CHILDREN) return null;
		final subject: QueryNode = inner.children[0];
		if (subject.kind != seams.identKind) return null;
		final binder: Null<String> = subject.name;
		if (binder == null || CasePatternScan.startsUpper(binder)) return null;
		final resolvedBinder: Null<QueryNode> = isolatedBinder(seams, arm, pat, subject, binder);
		if (resolvedBinder == null) return null;
		final binderNode: QueryNode = resolvedBinder;
		if (CasePatternScan.containsAnyKind(pat, [seams.assignKind])) return null;
		final conditional: Null<String> = seams.conditionalKind;
		if (conditional != null && CasePatternScan.containsAnyKind(arm, [conditional])) return null;
		if (CasePatternScan.containsAnyKind(arm, seams.opaqueKinds)) return null;
		final innerArms: Array<QueryNode> = inner.children.slice(1);
		for (innerArm in innerArms) if (innerArm.kind != seams.caseBranchKind) return null;
		return bindersCollide(seams, pat, binderNode, innerArms)
			? null
			: emit(scan, {
				switchNode: switchNode,
				at: at,
				arm: arm,
				plain: plain,
				pat: pat,
				binderNode: binderNode,
				inner: inner,
				innerArms: innerArms
			});
	}

	/**
	 * The spliced arm run for `frame`, or null when a comment sits in a region the emission
	 * DISCARDS, when an inner arm cannot be decomposed, or when the coverage gate refuses.
	 * Every reproduced fragment is read out of the source here — the `case` lead, the slot
	 * around the binder, the label terminator — so no keyword spelling is hardcoded.
	 */
	private static function emit(scan: Scan, frame: Frame): Null<Candidate> {
		final source: String = scan.source;
		final armSpan: Null<Span> = frame.arm.span;
		final plainSpan: Null<Span> = frame.plain.span;
		final patSpan: Null<Span> = frame.pat.span;
		final binderSpan: Null<Span> = frame.binderNode.span;
		final innerSpan: Null<Span> = frame.inner.span;
		if (armSpan == null || plainSpan == null || patSpan == null || binderSpan == null || innerSpan == null) return null;
		if (CheckScan.hasCommentMarker(source, armSpan.from, plainSpan.from)) return null;
		if (CheckScan.hasCommentMarker(source, patSpan.from, binderSpan.from)) return null;
		if (CheckScan.hasCommentMarker(source, binderSpan.to, patSpan.to)) return null;
		final terminator: String = source.substring(patSpan.to, innerSpan.from).trim();
		if (terminator != LABEL_TERMINATOR || !innerGapsClean(scan, frame, innerSpan, armSpan)) return null;
		final label: Label = {
			lead: source.substring(armSpan.from, plainSpan.from),
			prefix: source.substring(patSpan.from, binderSpan.from),
			suffix: source.substring(binderSpan.to, patSpan.to),
			terminator: terminator
		};
		final parts: Array<InnerArm> = [];
		for (innerArm in frame.innerArms) {
			final part: Null<InnerArm> = splitInnerArm(scan, innerArm, terminator);
			if (part == null) return null;
			parts.push(part);
		}
		final trailing: InnerArm = parts[parts.length - 1];
		final harmless: Bool = fallThroughHarmless(scan, frame.switchNode, frame.at);
		final merge: Bool = trailing.catchAll && trailing.body == '' && harmless;
		if (!trailing.catchAll && !harmless) return null;
		final kept: Array<InnerArm> = merge ? parts.slice(0, parts.length - 1) : parts;
		return kept.length == 0 ? null : { span: armSpan, text: [for (part in kept) render(label, part)].join('\n') };
	}

	/**
	 * Whether every region of the nested switch the emission DROPS — the `switch b {` header,
	 * the closing brace, the gaps between arms, and whatever trails the switch inside the arm
	 * — is free of a comment. Each is text that has nowhere to go once the switch is gone.
	 */
	private static function innerGapsClean(scan: Scan, frame: Frame, innerSpan: Span, armSpan: Span): Bool {
		final source: String = scan.source;
		final arms: Array<QueryNode> = frame.innerArms;
		final first: Null<Span> = arms[0].span;
		final last: Null<Span> = arms[arms.length - 1].span;
		if (first == null || last == null) return false;
		if (CheckScan.hasCommentMarker(source, innerSpan.from, first.from)) return false;
		if (CheckScan.hasCommentMarker(source, last.to, innerSpan.to)) return false;
		if (source.substring(innerSpan.to, armSpan.to).trim() != '') return false;
		for (i in 1...arms.length) {
			final prev: Null<Span> = arms[i - 1].span;
			final next: Null<Span> = arms[i].span;
			if (prev == null || next == null) return false;
			if (source.substring(prev.to, next.from).trim() != '') return false;
		}
		return true;
	}

	/**
	 * One inner arm cut into the fragments the splice reproduces: each pattern's text, the
	 * separators between them, the guard verbatim (the ` if (...)` spelling included), and the
	 * body after the label terminator. Null when the arm opens with something other than a
	 * spanned pattern (a `case var x:` capture projects as its own kind), when a pattern
	 * wrapper holds more than one child, or when a comment sits in a separator / before the
	 * guard — a region reproduced once per spliced arm, so a comment there would be DUPLICATED.
	 */
	private static function splitInnerArm(scan: Scan, arm: QueryNode, terminator: String): Null<InnerArm> {
		final seams: Seams = scan.seams;
		final source: String = scan.source;
		final kids: Array<QueryNode> = arm.children;
		final run: Int = patternRunLength(seams, kids);
		final armSpan: Null<Span> = arm.span;
		if (run == 0 || armSpan == null) return null;
		final nodes: Array<QueryNode> = [];
		final spans: Array<Span> = [];
		for (i in 0...run) {
			final plain: QueryNode = kids[i];
			if (plain.children.length != 1) return null;
			final node: QueryNode = plain.children[0];
			final span: Null<Span> = node.span;
			if (span == null) return null;
			nodes.push(node);
			spans.push(span);
		}
		final separators: Array<String> = [];
		for (i in 1...spans.length) {
			if (CheckScan.hasCommentMarker(source, spans[i - 1].to, spans[i].from)) return null;
			separators.push(source.substring(spans[i - 1].to, spans[i].from));
		}
		final headStart: Int = spans[spans.length - 1].to;
		final guardNode: Null<QueryNode> = run < kids.length && kids[run].kind == seams.parenKind ? kids[run] : null;
		var guard: String = '';
		var headEnd: Int = headStart;
		if (guardNode != null) {
			final guardSpan: Null<Span> = guardNode.span;
			if (guardSpan == null || CheckScan.hasCommentMarker(source, headStart, guardSpan.from)) return null;
			guard = source.substring(headStart, guardSpan.to);
			headEnd = guardSpan.to;
		}
		final rest: String = source.substring(headEnd, armSpan.to);
		final at: Int = firstNonSpace(rest);
		if (at == -1 || rest.substr(at, terminator.length) != terminator) return null;
		final wildcard: Bool = spans.length == 1 && guardNode == null && nodes[0].kind == seams.identKind
			&& nodes[0].name == seams.wildcardPatternName;
		return {
			patterns: [for (span in spans) source.substring(span.from, span.to)],
			separators: separators,
			guard: guard,
			body: rest.substring(at + terminator.length).trim(),
			catchAll: wildcard
		};
	}

	/**
	 * Whether falling OUT of the collapsed run is indistinguishable from falling out of the
	 * nested switch — the property that lets an arm collapse with no inner catch-all, and lets
	 * an EMPTY inner catch-all merge into the outer one. All five clauses are load-bearing: an
	 * expression switch's arms must each yield a value (so it has no empty arm to fall into and
	 * this path is never sound for one); there must be a later arm at all; every later arm must
	 * be unguarded and EXTRACTOR-FREE (nothing new is EVALUATED — an extractor runs code
	 * while matching) and EMPTY (nothing new RUNS); and one of them must
	 * be a catch-all, which is what keeps the arm list exhaustive once coverage shrinks.
	 */
	private static function fallThroughHarmless(scan: Scan, switchNode: QueryNode, at: Int): Bool {
		final seams: Seams = scan.seams;
		if (!seams.switchStatementKinds.contains(switchNode.kind)) return false;
		final arms: Array<QueryNode> = switchNode.children;
		if (at + 1 >= arms.length) return false;
		final defaultKind: Null<String> = seams.defaultBranchKind;
		var catchAll: Bool = false;
		for (i in at + 1...arms.length) {
			final later: QueryNode = arms[i];
			if (CasePatternScan.containsAnyKind(later, seams.extractorKinds)) return false;
			if (defaultKind != null && later.kind == defaultKind) {
				if (later.children.length != 0) return false;
				catchAll = true;
			} else {
				if (later.kind != seams.caseBranchKind) return false;
				final kids: Array<QueryNode> = later.children;
				final run: Int = patternRunLength(seams, kids);
				if (run == 0 || kids.length != run) return false;
				if (
					run == 1 && kids[0].children.length == 1 && kids[0].children[0].kind == seams.identKind
					&& kids[0].children[0].name == seams.wildcardPatternName
				)
					catchAll = true;
			}
		}
		return catchAll;
	}

	/**
	 * One spliced arm: the outer label with each inner pattern dropped into the binder's slot,
	 * the inner guard and label terminator verbatim, and the inner body. An empty body emits
	 * nothing after the terminator, so an empty arm stays empty.
	 */
	private static function render(label: Label, part: InnerArm): String {
		final buf: StringBuf = new StringBuf();
		buf.add(label.lead);
		for (i in 0...part.patterns.length) {
			if (i > 0) buf.add(part.separators[i - 1]);
			buf.add(label.prefix);
			buf.add(part.patterns[i]);
			buf.add(label.suffix);
		}
		buf.add(part.guard);
		buf.add(label.terminator);
		if (part.body != '') buf.add(' ${part.body}');
		return buf.toString();
	}

	/**
	 * The binder's occurrence inside the outer pattern, or null when the name is NOT isolated to
	 * exactly two mentions: that one and the nested switch's subject. A third mention is a read
	 * the splice would strand (the deep pattern rebinds the slot per arm) or a re-binding that
	 * changes what the name means. Three node shapes count as a mention: an ordinary identifier,
	 * a string-interpolation identifier (a `'$b'` read is NOT an `identKind`, and missing it
	 * would leave a dangling read behind the fix), and a case-pattern binder (`case var b:`).
	 * A body use of the binder is deliberate future work; the `=`-capture
	 * form (`case P(b = ...)`) is refused by its OWN gate: a capture spells its bound name with
	 * an ordinary identifier, so it satisfies this one.
	 */
	private static function isolatedBinder(
		seams: Seams, arm: QueryNode, pat: QueryNode, subject: QueryNode, binder: String
	): Null<QueryNode> {
		final all: Array<QueryNode> = [];
		mentions(seams, arm, binder, all);
		if (all.length != BINDER_MENTION_COUNT || !all.contains(subject)) return null;
		final inPattern: Array<QueryNode> = [];
		mentions(seams, pat, binder, inPattern);
		if (inPattern.length != 1) return null;
		final node: QueryNode = inPattern[0];
		return node == subject ? null : node;
	}

	/** Every node in `node`'s subtree that MENTIONS `binder` — see `isolatedBinder` for the three shapes. */
	private static function mentions(seams: Seams, node: QueryNode, binder: String, out: Array<QueryNode>): Void {
		if (
			node.name == binder
			&& (node.kind == seams.identKind || node.kind == seams.stringInterpIdentKind || seams.binderKinds.contains(node.kind))
		)
			out.push(node);
		for (child in node.children) mentions(seams, child, binder, out);
	}

	/**
	 * Whether an inner pattern binds a name the OUTER pattern already binds in ANOTHER slot. The
	 * splice lands both in one pattern — `case P(a, b):` over an inner `case Q(a):` emits
	 * `case P(a, Q(a))`, which Haxe rejects with `Variable a is bound multiple times`, while the
	 * nested form merely shadowed. Only the binder's OWN slot is exempt: that is the slot being
	 * replaced, and the isolation gate already proved its name occurs nowhere else in the arm.
	 */
	private static function bindersCollide(seams: Seams, pat: QueryNode, binderNode: QueryNode, innerArms: Array<QueryNode>): Bool {
		final outer: Array<String> = [];
		boundNames(seams, pat, binderNode, outer);
		if (outer.length == 0) return false;
		for (innerArm in innerArms) for (kid in innerArm.children) if (kid.kind == seams.plainCasePatternKind) {
			final inner: Array<String> = [];
			boundNames(seams, kid, binderNode, inner);
			for (name in inner) if (outer.contains(name)) return true;
		}
		return false;
	}

	/**
	 * Every name a pattern subtree BINDS: an identifier or a case-pattern binder whose name is
	 * neither the wildcard nor a capitalised constructor reference, `skip`'s own node aside.
	 * A conservative over-read (a structure pattern's field label reads as a name) can only
	 * REFUSE a collapse, never admit one.
	 */
	private static function boundNames(seams: Seams, node: QueryNode, skip: QueryNode, out: Array<String>): Void {
		final name: Null<String> = node.name;
		if (
			node != skip && name != null && name != seams.wildcardPatternName && !CasePatternScan.startsUpper(name)
			&& (node.kind == seams.identKind || seams.binderKinds.contains(node.kind))
		)
			out.push(name);
		for (child in node.children) boundNames(seams, child, skip, out);
	}

	/** The length of `kids`' LEADING run of case-pattern wrappers. */
	private static function patternRunLength(seams: Seams, kids: Array<QueryNode>): Int {
		var run: Int = 0;
		while (run < kids.length && kids[run].kind == seams.plainCasePatternKind) run++;
		return run;
	}

	/** The index of `text`'s first non-whitespace character, or -1 when it has none. */
	private static function firstNonSpace(text: String): Int {
		for (i in 0...text.length) {
			final code: Int = text.fastCodeAt(i);
			if (code != ' '.code && code != '\t'.code && code != '\n'.code && code != '\r'.code) return i;
		}
		return -1;
	}

	/** The seam kinds both passes read, or null when the grammar leaves a required one unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final switchKinds: Array<String> = shape.switchKinds ?? [];
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		final plainKind: Null<String> = shape.plainCasePatternKind;
		final wildcard: Null<String> = shape.wildcardPatternName;
		final parenKind: Null<String> = shape.parenKind;
		final assignKind: Null<String> = shape.assignKind;
		return switchKinds.length == 0 || caseBranchKind == null || plainKind == null || wildcard == null || parenKind == null
			|| assignKind == null
			? null
			: {
				switchKinds: switchKinds,
				switchStatementKinds: shape.switchStatementKinds ?? [],
				caseBranchKind: caseBranchKind,
				defaultBranchKind: shape.defaultBranchKind,
				plainCasePatternKind: plainKind,
				wildcardPatternName: wildcard,
				identKind: shape.identKind,
				parenKind: parenKind,
				assignKind: assignKind,
				stringInterpIdentKind: shape.stringInterpIdentKind,
				binderKinds: shape.casePatternBinderKinds ?? [],
				extractorKinds: shape.casePatternExtractorKinds ?? [],
				conditionalKind: shape.conditionalMemberKind,
				opaqueKinds: shape.opaqueKinds ?? []
			};
	}

}

/** One collapsible arm: the span replaced, and the spliced arm run that replaces it. */
private typedef Candidate = {
	final span: Span;
	final text: String;
};

/** The nodes one collapse is built from, resolved once by `candidateFor` for `emit` to read. */
private typedef Frame = {
	final switchNode: QueryNode;
	final at: Int;
	final arm: QueryNode;
	final plain: QueryNode;
	final pat: QueryNode;

	/** The binder's occurrence INSIDE the outer pattern — the slot each inner pattern is spliced into. */
	final binderNode: QueryNode;
	final inner: QueryNode;
	final innerArms: Array<QueryNode>;
};

/** The outer label text every spliced arm reproduces: the `case` lead, the slot around the binder, the terminator. */
private typedef Label = {
	final lead: String;
	final prefix: String;
	final suffix: String;
	final terminator: String;
};

/** One inner arm cut into the fragments the splice reproduces. */
private typedef InnerArm = {
	final patterns: Array<String>;

	/** The text between consecutive patterns, one per pattern after the first. */
	final separators: Array<String>;

	/** The guard verbatim, its ` if ` spelling included; empty when the arm has none. */
	final guard: String;
	final body: String;

	/** Whether the arm matches every subject: one wildcard pattern, no guard. */
	final catchAll: Bool;
};

/** The per-file scan context: the parsed tree, its source, and the resolved seams. */
private typedef Scan = {
	final tree: QueryNode;
	final source: String;
	final seams: Seams;
};

/** The seam kinds `CollapseNestedSwitch` resolves once per run. */
private typedef Seams = {
	final switchKinds: Array<String>;

	/** The statement-position subset — empty leaves the outer fall-through path permanently closed. */
	final switchStatementKinds: Array<String>;
	final caseBranchKind: String;
	final defaultBranchKind: Null<String>;
	final plainCasePatternKind: String;
	final wildcardPatternName: String;
	final identKind: String;
	final parenKind: String;

	/** The assignment kind — inside a pattern it is the `=`-CAPTURE form, whose left slot holds a NAME, not a pattern. */
	final assignKind: String;

	/** A `'$b'` read projects as this, never as `identKind` — the binder-isolation gate counts both. */
	final stringInterpIdentKind: Null<String>;
	final binderKinds: Array<String>;

	/** Pattern kinds that RUN code while matching — empty models a family whose patterns evaluate nothing. */
	final extractorKinds: Array<String>;
	final conditionalKind: Null<String>;
	final opaqueKinds: Array<String>;
};
