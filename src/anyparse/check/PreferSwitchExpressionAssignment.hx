package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.check.AssignmentTreeHoist.TreeSeams;
import anyparse.check.AssignmentTreeHoist.LvalueRef;
import anyparse.check.AssignmentTreeHoist.SwitchArms;

/**
 * Flags two shapes that collapse a statement-position `switch` assigning in every arm into a single
 * switch-expression assignment. Purely structural (no type information). `Info` -- the code is
 * correct, this is a readability simplification.
 *
 * ## The decl-pairing arm
 *
 * A local declaration whose value is set by an IMMEDIATELY following `switch` in every arm collapses
 * the pair to one assignment:
 *
 * ```haxe
 * var otherslash:String = '';
 * switch slash {
 *     case '/': otherslash = '\\';
 *     case '\\': otherslash = '/';
 * }
 * // ->
 * final otherslash:String = switch slash {
 *     case '/': '\\';
 *     case '\\': '/';
 *     case _: '';
 * };
 * ```
 *
 * The `switch` twin of `prefer-if-expression-assignment` (the `if`-chain rule) and the decl-pairing
 * sibling of `join-declaration-assignment`. Two CONSECUTIVE statements of one statement list
 * (`ControlFlowSupport.blockKinds`) where:
 *
 * - the first is a single-variable mutable local declaration (`mutableLocalDeclKinds`) named `x` -- a
 *   multi-declarator `var a, b;` is skipped; an initializer is optional;
 * - the second is a statement-position `switch` (`switchKinds`) whose subject does NOT reference `x`;
 * - every non-subject child of the switch is a `case` / `default` arm (a `#if`-guarded arm projects as
 *   a `Conditional`, which disqualifies the whole switch);
 * - every arm body is a single HOISTABLE UNIT (`AssignmentTreeHoist`) assigning `x` -- a plain
 *   `x = <expr>;` (bare or braced `{ x = e; }`), or (RECURSIVELY) a nested `switch` / `if`-chain whose
 *   every leaf assigns `x`, its value becoming the arm's. A compound (`+=`) / short-circuit (`??=`)
 *   assignment, a multi-statement body, a non-assignment body, or an l-value other than `x` disqualifies;
 * - `x` is read NOWHERE in the switch (`x = x + 1`, a nested `if (x > 0) …` -- a rejected self-reference
 *   after collapse);
 * - `x` is written ONLY by the arm leaves, so after the collapse `x` is genuinely `final`;
 * - no comment sits in a region the collapse drops.
 *
 * ### Exhaustiveness and the initializer
 *
 * A switch-expression must yield a value on every path, so the collapsed form needs a default: an
 * existing unguarded `case _:` / `default:` arm makes it exhaustive and DROPS the initializer;
 * otherwise, with an initializer, a synthetic `case _: <init>;` is appended; otherwise (a bare
 * `var x;` and a non-exhaustive switch) it is SKIPPED. Relocating the initializer changes WHEN it
 * evaluates, so an impure one (`RefactorSupport.isSideEffectFree`) also SKIPS the pair. A nested
 * `switch` arm needs its OWN source default (no initializer to synthesize one from); a nested
 * `if`-chain arm needs a final `else`.
 *
 * ## The l-value arm
 *
 * A standalone statement-position `switch` (no paired declaration) whose EVERY arm body is a single
 * hoistable unit assigning the SAME l-value -- a field-access path or a plain identifier not freshly
 * declared by an adjacent local -- hoists the l-value out of the arms. An arm may nest RECURSIVELY: a
 * `switch` / `if`-chain arm whose every leaf assigns that l-value becomes the arm's value:
 *
 * ```haxe
 * switch x {
 *     case A: controlsHolder.y = 1;
 *     case B: controlsHolder.y = 2;
 *     case _: controlsHolder.y = 0;
 * }
 * // ->
 * controlsHolder.y = switch x {
 *     case A: 1;
 *     case B: 2;
 *     case _: 0;
 * };
 * ```
 *
 * Gates:
 *
 * - the switch must have a source `case _:` / `default:` arm -- there is no initializer to synthesize
 *   one, so a non-exhaustive switch is SKIPPED;
 * - the l-value's RECEIVER path must be side-effect-free (`RefactorSupport.isSideEffectFree`): idents /
 *   `this` / plain field reads, but not a getter the machinery cannot prove pure. The terminal setter
 *   is exempt -- it ran once per taken arm before and after the collapse. A multi-segment receiver
 *   (`a.b.c`) carries an unprovable field read, so it is conservatively SKIPPED;
 * - the subject must not reference the l-value path (a shared reference is order-sensitive with the
 *   receiver after the collapse);
 * - guard-carrying arms are fine; a `#if`-guarded arm (`Conditional`), a compound / `??=` assignment,
 *   or arms disagreeing on the l-value all disqualify, as in the decl arm;
 * - when the l-value is a plain identifier declared by an immediately preceding mutable local, the
 *   decl-pairing arm keeps priority.
 *
 * ## Autofix
 *
 * `fix` replaces the matched region with `<lvalue> = switch subj { … };` (the decl arm swaps the `var`
 * keyword for `final` and preserves the declared `:type`). The subject and every arm's pattern / guard
 * are copied verbatim; each arm's value is the recursive hoist of its body (a plain r-value, or a
 * nested switch- / if-expression -- `AssignmentTreeHoist`). The compact output is re-emitted through
 * the canonical writer. Needs `switchKinds`, `caseBranchKind`, `defaultBranchKind`, `plainCasePatternKind`,
 * `wildcardPatternName`, `parenKind`, `exprStatementKind`, `blockStmtKind`, `assignKind`,
 * `mutableLocalDeclKinds` and `controlFlowSupport` (any unset makes the check a no-op); `fieldAccessKind`
 * is optional -- without it the l-value arm handles only plain-identifier l-values, and `ifStatementKinds`
 * is optional -- without it arms cannot nest an `if`-chain.
 */
@:nullSafety(Strict)
final class PreferSwitchExpressionAssignment implements Check {

	/** The finding message for the decl-pairing arm (a `var` and its following switch). */
	private static inline final DECL_MESSAGE: String =
		'this declaration and its following switch assignment can be a single switch-expression assignment';

	/** The finding message for the l-value arm (a standalone switch assigning one l-value in every arm). */
	private static inline final LVALUE_MESSAGE: String =
		'this switch that assigns the same l-value in every arm can be a single switch-expression assignment';

	public function new() {}

	public function id(): String {
		return 'prefer-switch-expression-assignment';
	}

	public function description(): String {
		return
			'a switch that assigns the same target in every arm (optionally paired with its preceding local declaration), collapsible to a single switch-expression assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			final matches: Array<Match> = [];
			collectMatches(tree, tree, entry.source, comments, seams, matches);
			for (m in matches) violations.push({
				file: entry.file,
				span: m.declSpan,
				rule: 'prefer-switch-expression-assignment',
				severity: Severity.Info,
				message: m.message
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
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final matches: Array<Match> = [];
		collectMatches(tree, tree, source, comments, seams, matches);
		final byKey: Map<String, Match> = [];
		for (m in matches) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.editSpan, text: m.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<TreeSeams> = AssignmentTreeHoist.readTreeSeams(shape);
		if (tree == null) return null;
		final switchKinds: Null<Array<String>> = tree.switchKinds;
		if (switchKinds == null || switchKinds.length == 0) return null;
		final mutableKinds: Null<Array<String>> = shape.mutableLocalDeclKinds;
		if (mutableKinds == null || mutableKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			tree: tree,
			switchKinds: switchKinds,
			mutableKinds: mutableKinds,
			identKind: shape.identKind,
			stringInterpKind: shape.stringInterpIdentKind,
			fieldAccessKind: shape.fieldAccessKind,
			blockKinds: support.blockKinds(),
			shape: shape
		};
	}

	/** Collect every collapsible (declaration, switch) pair reachable under `node`. */
	private static function collectMatches(
		node: QueryNode, root: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		out: Array<Match>
	): Void {
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				if (i + 1 < kids.length) {
					final m: Null<Match> = matchPair(kids[i], kids[i + 1], root, source, comments, s);
					if (m != null) out.push(m);
				}
				if (s.switchKinds.contains(kids[i].kind)) {
					final lm: Null<Match> = matchLvalueSwitch(kids[i], i > 0 ? kids[i - 1] : null, source, comments, s);
					if (lm != null) out.push(lm);
				}
			}
		}
		for (c in node.children) collectMatches(c, root, source, comments, s, out);
	}

	/**
	 * The collapse match for a `decl` immediately followed by `switchStmt`, or null when they
	 * are not a single mutable local and a following switch assigning that local in every arm
	 * (see the class doc for every gate).
	 */
	private static function matchPair(
		decl: QueryNode, switchStmt: QueryNode, root: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams
	): Null<Match> {
		if (!s.mutableKinds.contains(decl.kind) || decl.children.length > 1) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		if (hasTopLevelComma(source.substring(declSpan.from, declSpan.to))) return null; // `var a, b;`
		final init: Null<QueryNode> = decl.children.length == 1 ? decl.children[0] : null;
		if (init != null && !RefactorSupport.isSideEffectFree(init)) return null; // impure init cannot move to a default path

		if (!s.switchKinds.contains(switchStmt.kind) || switchStmt.children.length < 2) return null;
		final switchSpan: Null<Span> = switchStmt.span;
		if (switchSpan == null) return null;
		final subject: QueryNode = switchStmt.children[0];
		if (referencesName(subject, name, s)) return null;

		final ref: LvalueRef = { lvalue: null };
		final sa: Null<SwitchArms> = AssignmentTreeHoist.switchArms(switchStmt, ref, source, s.tree);
		if (sa == null) return null;
		final lvalue: Null<QueryNode> = ref.lvalue;
		if (lvalue == null || !assignsFinalLocal(name, lvalue, root, switchStmt, switchSpan, sa.leafCount, s)) return null;
		// No source default arm and no initializer to synthesize one from — cannot make it exhaustive.
		if (!sa.hasDefault && init == null) return null;
		return buildDeclMatch(decl, declSpan, switchSpan, init, subject, sa, source, comments, s);
	}


	/** Whether every reassignment of `name` in `root` is one of the `leafCount` leaf-assignment writes inside `switchSpan`. */
	private static function writtenOnlyByArms(name: String, root: QueryNode, switchSpan: Span, leafCount: Int, s: Seams): Bool {
		final writes: Array<Span> = writeSpans(name, root, s.shape);
		if (writes.length != leafCount) return false;
		for (w in writes) if (w.from < switchSpan.from || w.from >= switchSpan.to) return false;
		return true;
	}

	/**
	 * Whether `name` is READ anywhere in `node` — any `Refs` occurrence that is not a `Write`. A read
	 * inside the switch (a subject / condition / r-value reference) would become a self-reference in
	 * `x`'s own initializer after the decl-pairing collapse, so it disqualifies the pair.
	 */
	private static function readsName(name: String, node: QueryNode, s: Seams): Bool {
		for (h in Refs.find(name, node, s.shape)) if (h.kind != RefKind.Write) return true;
		return false;
	}

	/**
	 * Whether the switch's arm leaves assign exactly the declared identifier `name` and nothing else:
	 * the common l-value is that identifier, every write of `name` is one of the `leafCount` arm-leaf
	 * writes inside the switch, and `name` is read NOWHERE in the switch — the conditions under which
	 * the decl collapses to a genuinely `final` local.
	 */
	private static function assignsFinalLocal(
		name: String, lvalue: QueryNode, root: QueryNode, switchStmt: QueryNode, switchSpan: Span, leafCount: Int, s: Seams
	): Bool {
		return lvalue.kind == s.identKind && lvalue.name == name && writtenOnlyByArms(name, root, switchSpan, leafCount, s)
			&& !readsName(name, switchStmt, s);
	}

	/**
	 * Assemble the `final x:T = switch subj { … };` replacement from the collected arms. A source
	 * default arm is exhaustive (the initializer is dropped); otherwise a `case _: <init>;` is
	 * synthesized from the initializer. Null when a span is missing or a comment sits in a dropped
	 * region.
	 */
	private static function buildDeclMatch(
		decl: QueryNode, declSpan: Span, switchSpan: Span, init: Null<QueryNode>, subject: QueryNode, sa: SwitchArms, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final prefix: Null<{ text: String, keptTo: Int }> = finalDeclPrefix(decl, declSpan, init, source);
		final subjectSrc: Null<String> = AssignmentTreeHoist.slice(source, subject);
		final subjectSpan: Null<Span> = subject.span;
		if (prefix == null || subjectSrc == null || subjectSpan == null) return null;

		final kept: Array<Span> = sa.kept.copy();
		kept.push(new Span(declSpan.from, prefix.keptTo));
		kept.push(subjectSpan);
		final buf: StringBuf = new StringBuf();
		buf.add(prefix.text);
		buf.add(' = switch ');
		buf.add(subjectSrc);
		buf.add(' {');
		buf.add(sa.armsText);
		if (!sa.hasDefault) {
			// A source default arm is exhaustive, so the initializer is dropped; otherwise it moves here.
			final initNode: Null<QueryNode> = init;
			final initSrc: Null<String> = initNode == null ? null : AssignmentTreeHoist.slice(source, initNode);
			if (initNode == null || initSrc == null) return null;
			buf.add(' case _: ');
			buf.add(initSrc);
			buf.add(';');
			if (initNode.span != null) kept.push((initNode.span: Span));
		}
		buf.add(' };');

		final region: Span = new Span(declSpan.from, switchSpan.to);
		return IfExpressionChain.droppedComment(region, kept, comments) ? null : {
			declSpan: declSpan,
			editSpan: region,
			text: buf.toString(),
			message: DECL_MESSAGE
		};
	}


	/**
	 * Whether any descendant of `node` references the local `name` — a plain `identKind`
	 * reference or a `stringInterpKind` one (a braceless `$name` inside a single-quoted string,
	 * a distinct kind). Mirrors `JoinDeclarationAssignment.referencesName`.
	 */
	private static function referencesName(node: QueryNode, name: String, s: Seams): Bool {
		if ((node.kind == s.identKind || node.kind == s.stringInterpKind) && node.name == name) return true;
		for (c in node.children) if (referencesName(c, name, s)) return true;
		return false;
	}

	/** The reassignment positions of `name` in `tree` — a `Write` hit's own span, the exact scan `prefer-final` uses. */
	private static function writeSpans(name: String, tree: QueryNode, shape: RefShape): Array<Span> {
		return [for (h in Refs.find(name, tree, shape)) if (h.kind == RefKind.Write) h.span];
	}

	/**
	 * The `final x:T` prefix (keyword swapped, declared type preserved) plus the offset up to
	 * which the declaration source is copied verbatim (the kept region for the comment guard):
	 * before the `=` for an initialized decl, before the trailing `;` for a bare one. Null on a
	 * missing span or malformed declaration.
	 */
	private static function finalDeclPrefix(
		decl: QueryNode, declSpan: Span, init: Null<QueryNode>, source: String
	): Null<{ text: String, keptTo: Int }> {
		final prefixEnd: Int = if (init != null) {
			final initSpan: Null<Span> = init.span;
			if (initSpan == null) return null;
			final eq: Int = source.lastIndexOf('=', initSpan.from);
			if (eq < declSpan.from) return null;
			eq;
		} else {
			if (declSpan.to <= declSpan.from || source.charAt(declSpan.to - 1) != ';') return null;
			declSpan.to - 1;
		}
		final raw: String = StringTools.rtrim(source.substring(declSpan.from, prefixEnd));
		return { text: (~/^var\b/).replace(raw, 'final'), keptTo: prefixEnd };
	}


	/**
	 * Whether `s` contains a comma outside any `()`/`[]`/`{}`/`<>` nesting and outside a string
	 * literal — the multi-declaration separator of `var a = 1, b = 2`. `->` is skipped so a
	 * function-type arrow does not close a `<…>`. Mirrors `JoinDeclarationAssignment.hasTopLevelComma`.
	 */
	private static function hasTopLevelComma(text: String): Bool {
		var depth: Int = 0;
		var i: Int = 0;
		while (i < text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			switch c {
				case '('.code | '['.code | '{'.code | '<'.code:
					depth++;
				case '>'.code if (i > 0 && StringTools.fastCodeAt(text, i - 1) == '-'.code):
					// the `>` of `->` is not a bracket close
				case ')'.code | ']'.code | '}'.code | '>'.code:
					if (depth > 0) depth--;
				case ','.code if (depth == 0):
					return true;
				case _:
			}
			i++;
		}
		return false;
	}


	/**
	 * Whether the hoisted l-value is acceptable for the l-value arm: a bare identifier or a
	 * single-segment field-access path with a side-effect-free receiver, NOT an identifier freshly
	 * declared by `prev` (the decl arm keeps priority), and NOT referenced by the switch `subject`
	 * (a shared reference is order-sensitive with the receiver after the collapse).
	 */
	private static function lvalueAccepted(lvalue: QueryNode, subject: QueryNode, prev: Null<QueryNode>, s: Seams): Bool {
		final isField: Bool = s.fieldAccessKind != null && lvalue.kind == s.fieldAccessKind;
		if (lvalue.kind != s.identKind && !isField) return false;
		if (lvalue.kind == s.identKind && prev != null && s.mutableKinds.contains(prev.kind) && prev.name == lvalue.name) return false;
		if (isField) {
			final receiver: Null<QueryNode> = lvalue.children.length > 0 ? lvalue.children[0] : null;
			if (receiver == null || !RefactorSupport.isSideEffectFree(receiver)) return false;
		}
		return !subjectTouchesLvalue(subject, lvalue, s);
	}

	/**
	 * Whether the switch subject references any identifier that appears in the l-value path. The
	 * field name of a `FieldAccess` is the node's own `name` (not a child), so only receiver idents
	 * count: a shared reference makes the receiver / subject evaluation order-sensitive after the
	 * collapse, disqualifying the switch.
	 */
	private static function subjectTouchesLvalue(subject: QueryNode, lvalue: QueryNode, s: Seams): Bool {
		final name: Null<String> = lvalue.name;
		if ((lvalue.kind == s.identKind || lvalue.kind == s.stringInterpKind) && name != null && referencesName(subject, name, s))
			return true;
		for (c in lvalue.children) if (subjectTouchesLvalue(subject, c, s)) return true;
		return false;
	}


	/**
	 * The collapse match for a statement-position `switchStmt` whose every arm assigns the SAME
	 * l-value (a field-access path or a plain identifier), or null when a gate fails. `prev` is the
	 * switch's preceding sibling in the statement list: the decl-pairing arm keeps priority, so a
	 * switch whose l-value is a plain identifier declared by an immediately preceding mutable local is
	 * left to `matchPair`.
	 */
	private static function matchLvalueSwitch(
		switchStmt: QueryNode, prev: Null<QueryNode>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (!s.switchKinds.contains(switchStmt.kind) || switchStmt.children.length < 2) return null;
		final switchSpan: Null<Span> = switchStmt.span;
		if (switchSpan == null) return null;
		final subject: QueryNode = switchStmt.children[0];

		final ref: LvalueRef = { lvalue: null };
		final sa: Null<SwitchArms> = AssignmentTreeHoist.switchArms(switchStmt, ref, source, s.tree);
		// No source default arm and no initializer to synthesize one from — cannot make it exhaustive.
		if (sa == null || !sa.hasDefault) return null;
		final lvalue: Null<QueryNode> = ref.lvalue;
		if (lvalue == null || !lvalueAccepted(lvalue, subject, prev, s)) return null;

		final lvalueSrc: Null<String> = AssignmentTreeHoist.slice(source, lvalue);
		final subjectSrc: Null<String> = AssignmentTreeHoist.slice(source, subject);
		final lvalueSpan: Null<Span> = lvalue.span;
		final subjectSpan: Null<Span> = subject.span;
		if (lvalueSrc == null || subjectSrc == null || lvalueSpan == null || subjectSpan == null) return null;

		final kept: Array<Span> = sa.kept.copy();
		kept.push(lvalueSpan);
		kept.push(subjectSpan);
		return IfExpressionChain.droppedComment(switchSpan, kept, comments) ? null : {
			declSpan: switchSpan,
			editSpan: switchSpan,
			text: '$lvalueSrc = switch $subjectSrc {${sa.armsText} };',
			message: LVALUE_MESSAGE
		};
	}

}

/** The kinds `PreferSwitchExpressionAssignment` reads. */
private typedef Seams = {
	var tree: TreeSeams;
	var switchKinds: Array<String>;
	var mutableKinds: Array<String>;
	var identKind: String;
	var stringInterpKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** A collapsible pair: the declaration span (finding key), the replaced span, and the built replacement text. */
private typedef Match = {
	var declSpan: Span;
	var editSpan: Span;
	var text: String;
	var message: String;
}
