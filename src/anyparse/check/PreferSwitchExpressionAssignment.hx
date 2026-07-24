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
 * - every non-subject child of the switch is a `case` / `default` arm (a `#if`-guarded arm projects
 *   as a `Conditional`, which disqualifies the whole switch);
 * - every arm body is EXACTLY the single statement `x = <expr>;` -- a plain `=` (`assignKind`) whose
 *   l-value is the declared identifier, a bare `x = e;` or a braced `{ x = e; }`. A compound (`+=`) /
 *   short-circuit (`??=`) assignment, a multi-statement body, a non-assignment body, or an l-value
 *   other than `x` disqualifies;
 * - no arm value references `x` (`x = x + 1` becomes a rejected self-reference after collapse);
 * - `x` is written ONLY by the arm assignments, so after the collapse `x` is genuinely `final`;
 * - no comment sits in a region the collapse drops.
 *
 * ### Exhaustiveness and the initializer
 *
 * A switch-expression must yield a value on every path, so the collapsed form needs a default: an
 * existing unguarded `case _:` / `default:` arm makes it exhaustive and DROPS the initializer;
 * otherwise, with an initializer, a synthetic `case _: <init>;` is appended; otherwise (a bare
 * `var x;` and a non-exhaustive switch) it is SKIPPED. Relocating the initializer changes WHEN it
 * evaluates, so an impure one (`RefactorSupport.isSideEffectFree`) also SKIPS the pair.
 *
 * ## The l-value arm
 *
 * A standalone statement-position `switch` (no paired declaration) whose EVERY arm assigns the SAME
 * l-value -- a field-access path or a plain identifier that is NOT freshly declared by an adjacent
 * local -- hoists the l-value out of the arms:
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
 * `fix` replaces the matched region with `<lvalue> = switch subj { … };` (the decl arm swaps the
 * `var` keyword for `final` and preserves the declared `:type`). The subject and every arm's pattern /
 * guard / value are copied verbatim from their spans; the compact output is re-emitted through the
 * canonical writer. Needs `switchKinds`, `caseBranchKind`, `defaultBranchKind`, `plainCasePatternKind`,
 * `wildcardPatternName`, `parenKind`, `exprStatementKind`, `blockStmtKind`, `assignKind`,
 * `mutableLocalDeclKinds` and `controlFlowSupport` (any unset makes the check a no-op);
 * `fieldAccessKind` is optional -- without it the l-value arm handles only plain-identifier l-values.
 */
@:nullSafety(Strict)
final class PreferSwitchExpressionAssignment implements Check {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** The finding message for the decl-pairing arm (a `var` and its following switch). */
	private static inline final DECL_MESSAGE: String = 'this declaration and its following switch assignment can be a single switch-expression assignment';

	/** The finding message for the l-value arm (a standalone switch assigning one l-value in every arm). */
	private static inline final LVALUE_MESSAGE: String = 'this switch that assigns the same l-value in every arm can be a single switch-expression assignment';

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
		final switchKinds: Null<Array<String>> = shape.switchKinds;
		if (switchKinds == null || switchKinds.length == 0) return null;
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		if (caseBranchKind == null) return null;
		final defaultBranchKind: Null<String> = shape.defaultBranchKind;
		if (defaultBranchKind == null) return null;
		final plainCasePatternKind: Null<String> = shape.plainCasePatternKind;
		if (plainCasePatternKind == null) return null;
		final wildcardPatternName: Null<String> = shape.wildcardPatternName;
		if (wildcardPatternName == null) return null;
		final parenKind: Null<String> = shape.parenKind;
		if (parenKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final mutableKinds: Null<Array<String>> = shape.mutableLocalDeclKinds;
		if (mutableKinds == null || mutableKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			switchKinds: switchKinds,
			caseBranchKind: caseBranchKind,
			defaultBranchKind: defaultBranchKind,
			plainCasePatternKind: plainCasePatternKind,
			wildcardPatternName: wildcardPatternName,
			parenKind: parenKind,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			assignKind: assignKind,
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

		final collected: Null<{ arms: Array<{ arm: QueryNode, value: QueryNode }>, hasDefault: Bool }> = collectArms(switchStmt, name, s);
		if (collected == null) return null;
		// No source default arm and no initializer to synthesize one from — cannot make it exhaustive.
		if (!collected.hasDefault && init == null) return null;
		return writtenOnlyByArms(name, root, switchSpan, collected.arms.length, s)
			? buildMatch(decl, declSpan, switchSpan, init, subject, collected.arms, collected.hasDefault, source, comments, s)
			: null;
	}

	/**
	 * Collect each arm's (branch, assigned value) pair and whether the switch has an exhaustive
	 * default arm, or null when a child is not a `case` / `default` arm (a `#if`-guarded
	 * `Conditional` run), an arm body is not exactly `x = <expr>;`, or an arm value references `x`.
	 */
	private static function collectArms(
		switchStmt: QueryNode, name: String, s: Seams
	): Null<{ arms: Array<{ arm: QueryNode, value: QueryNode }>, hasDefault: Bool }> {
		final arms: Array<{ arm: QueryNode, value: QueryNode }> = [];
		var hasDefault: Bool = false;
		for (i in 1...switchStmt.children.length) {
			final branch: QueryNode = switchStmt.children[i];
			if (branch.kind != s.caseBranchKind && branch.kind != s.defaultBranchKind) return null;
			final assign: Null<QueryNode> = armAssignment(branch, name, s);
			if (assign == null) return null;
			final value: QueryNode = assign.children[1];
			if (referencesName(value, name, s)) return null;
			arms.push({ arm: branch, value: value });
			if (isDefaultArm(branch, s)) hasDefault = true;
		}
		return { arms: arms, hasDefault: hasDefault };
	}

	/** Whether every reassignment of `name` in `root` is one of the `armCount` arm-body writes inside `switchSpan`. */
	private static function writtenOnlyByArms(name: String, root: QueryNode, switchSpan: Span, armCount: Int, s: Seams): Bool {
		final writes: Array<Span> = writeSpans(name, root, s.shape);
		if (writes.length != armCount) return false;
		for (w in writes) if (w.from < switchSpan.from || w.from >= switchSpan.to) return false;
		return true;
	}

	/**
	 * Assemble the replacement text and the dropped-comment guard from the matched parts. Returns
	 * null when any span is missing or a comment sits in a region the collapse would drop.
	 */
	private static function buildMatch(
		decl: QueryNode, declSpan: Span, switchSpan: Span, init: Null<QueryNode>, subject: QueryNode,
		arms: Array<{ arm: QueryNode, value: QueryNode }>, hasDefault: Bool, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final prefix: Null<{ text: String, keptTo: Int }> = finalDeclPrefix(decl, declSpan, init, source);
		final subjectSrc: Null<String> = slice(source, subject);
		final subjectSpan: Null<Span> = subject.span;
		if (prefix == null || subjectSrc == null || subjectSpan == null) return null;

		final kept: Array<Span> = [new Span(declSpan.from, prefix.keptTo), subjectSpan];
		final buf: StringBuf = new StringBuf();
		buf.add(prefix.text);
		buf.add(' = switch ');
		buf.add(subjectSrc);
		buf.add(' {');
		if (!emitArms(buf, arms, kept, source, s)) return null;
		if (!hasDefault) {
			// A source default arm is exhaustive, so the initializer is dropped; otherwise it moves here.
			final initNode: Null<QueryNode> = init;
			final initSrc: Null<String> = initNode == null ? null : slice(source, initNode);
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
	 * The single `x = <expr>` assignment an arm body holds — a bare `x = e;` or a braced
	 * `{ x = e; }` wrapping one, with the l-value the declared identifier `name`. Null when the
	 * arm body is not exactly one such plain assignment (a compound / `??=` operator, a
	 * multi-statement body, a non-assignment, or an l-value other than `name` all disqualify).
	 */
	private static function armAssignment(branch: QueryNode, name: String, s: Seams): Null<QueryNode> {
		final assign: Null<QueryNode> = armPlainAssign(branch, s);
		if (assign == null) return null;
		final lhs: QueryNode = assign.children[0];
		return lhs.kind == s.identKind && lhs.name == name ? assign : null;
	}

	/**
	 * The one body statement of a case / default arm — the arm's children minus its pattern
	 * wrapper(s) (`plainCasePatternKind`, one per comma alternative) and its optional guard
	 * (`caseGuard`). Null when the arm holds zero or several body statements (a deliberately
	 * multi-statement body is never collapsed).
	 */
	private static function armBody(branch: QueryNode, s: Seams): Null<QueryNode> {
		final guard: Null<QueryNode> = caseGuard(branch, s);
		var body: Null<QueryNode> = null;
		for (c in branch.children) if (c.kind != s.plainCasePatternKind && c != guard) {
			if (body != null) return null; // more than one body statement
			body = c;
		}
		return body;
	}

	/**
	 * The guard expression of a case branch (`case p if (c):` — a bare parenthesized expression
	 * sibling after the pattern alternatives), or null when unguarded. Scans past the leading
	 * pattern children so a comma-alternative form (`case _, 4 if (c):`) is caught too. Mirrors
	 * `NullFlow.caseGuard`; a statement-switch arm body is a statement, never a bare paren, so
	 * this never confuses a body with a guard.
	 */
	private static function caseGuard(branch: QueryNode, s: Seams): Null<QueryNode> {
		for (i in 1...branch.children.length) if (branch.children[i].kind == s.parenKind) return branch.children[i];
		return null;
	}

	/**
	 * Whether `branch` is an exhaustive default arm — a `default:` (`defaultBranchKind`) or an
	 * unguarded wildcard `case _:` (its pattern is the plain wrapper holding just the wildcard
	 * identifier). A guarded wildcard can still fail to match, so it never counts.
	 */
	private static function isDefaultArm(branch: QueryNode, s: Seams): Bool {
		if (branch.kind == s.defaultBranchKind) return true;
		if (branch.kind != s.caseBranchKind || branch.children.length == 0 || caseGuard(branch, s) != null) return false;
		final pattern: QueryNode = branch.children[0];
		if (pattern.kind != s.plainCasePatternKind || pattern.children.length != 1) return false;
		final ident: QueryNode = pattern.children[0];
		return ident.kind == s.identKind && ident.name == s.wildcardPatternName;
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

	/** The `case <pattern> [if <guard>]` header source of an arm (`default` for a default arm), or null. */
	private static function armHeader(branch: QueryNode, source: String, s: Seams): Null<String> {
		if (branch.kind == s.defaultBranchKind) return 'default';
		final hs: Null<Span> = headerKeptSpan(branch, s);
		return hs == null ? null : source.substring(hs.from, hs.to);
	}

	/** The `[case … pattern/guard]` span copied verbatim into the header — null for a `default` arm (its keyword carries no comment). */
	private static function headerKeptSpan(branch: QueryNode, s: Seams): Null<Span> {
		final span: Null<Span> = branch.span;
		if (span == null || branch.kind == s.defaultBranchKind) return null;
		final guard: Null<QueryNode> = caseGuard(branch, s);
		final endNode: Null<QueryNode> = guard ?? lastPattern(branch, s);
		if (endNode == null) return null;
		final endSpan: Null<Span> = endNode.span;
		return endSpan == null ? null : new Span(span.from, endSpan.to);
	}

	/** The last pattern wrapper child of a case branch (the tail of a comma-alternative list). */
	private static function lastPattern(branch: QueryNode, s: Seams): Null<QueryNode> {
		var last: Null<QueryNode> = null;
		for (c in branch.children) if (c.kind == s.plainCasePatternKind) last = c;
		return last;
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

	/** The source text of `node`'s span, or null when it has none. */
	private static function slice(source: String, node: QueryNode): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/**
	 * The single plain `=` assignment (`assignKind`) an arm body holds — a bare `lvalue = e;` or a
	 * braced `{ lvalue = e; }` wrapping one, with ANY l-value. Null when the arm body is not exactly
	 * one such plain assignment (a compound / `??=` operator, a multi-statement body, or a
	 * non-assignment all disqualify). The l-value validation is left to the caller.
	 */
	private static function armPlainAssign(branch: QueryNode, s: Seams): Null<QueryNode> {
		final body: Null<QueryNode> = armBody(branch, s);
		if (body == null) return null;
		final stmt: QueryNode = body.kind == s.blockStmtKind ? (body.children.length == 1 ? body.children[0] : body) : body;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == s.assignKind && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/**
	 * Append `case <header>: <value>;` for every arm to `buf` and record each header / value span in
	 * `kept` (the comment-drop guard's surviving regions). False when an arm's header or value source
	 * is missing.
	 */
	private static function emitArms(
		buf: StringBuf, arms: Array<{ arm: QueryNode, value: QueryNode }>, kept: Array<Span>, source: String, s: Seams
	): Bool {
		for (a in arms) {
			final header: Null<String> = armHeader(a.arm, source, s);
			final value: Null<String> = slice(source, a.value);
			if (header == null || value == null) return false;
			buf.add(' ');
			buf.add(header);
			buf.add(': ');
			buf.add(value);
			buf.add(';');
			final hs: Null<Span> = headerKeptSpan(a.arm, s);
			if (hs != null) kept.push(hs);
			if (a.value.span != null) kept.push((a.value.span: Span));
		}
		return true;
	}

	/** Whether two l-value nodes are structurally identical (same kind, name, and children). */
	private static function sameLvalue(a: QueryNode, b: QueryNode): Bool {
		if (a.kind != b.kind || a.name != b.name || a.children.length != b.children.length) return false;
		for (i in 0...a.children.length) if (!sameLvalue(a.children[i], b.children[i])) return false;
		return true;
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
	 * Collect each arm's (branch, assigned value) pair, the common l-value assigned in every arm, and
	 * whether the switch has an exhaustive default arm. Null when a child is not a `case` / `default`
	 * arm (a `#if`-guarded `Conditional` run), an arm body is not exactly a plain `<lvalue> = <expr>;`,
	 * the l-value is neither a bare identifier nor a field-access path, or the arms do not all assign
	 * the SAME l-value.
	 */
	private static function collectLvalueArms(
		switchStmt: QueryNode, s: Seams
	): Null<{ arms: Array<{ arm: QueryNode, value: QueryNode }>, lvalue: QueryNode, hasDefault: Bool }> {
		final arms: Array<{ arm: QueryNode, value: QueryNode }> = [];
		var lvalue: Null<QueryNode> = null;
		var hasDefault: Bool = false;
		for (i in 1...switchStmt.children.length) {
			final branch: QueryNode = switchStmt.children[i];
			if (branch.kind != s.caseBranchKind && branch.kind != s.defaultBranchKind) return null;
			final assign: Null<QueryNode> = armPlainAssign(branch, s);
			if (assign == null) return null;
			final lhs: QueryNode = assign.children[0];
			final isField: Bool = s.fieldAccessKind != null && lhs.kind == s.fieldAccessKind;
			if (lhs.kind != s.identKind && !isField) return null;
			if (lvalue == null)
				lvalue = lhs;
			else if (!sameLvalue(lvalue, lhs))
				return null;
			arms.push({ arm: branch, value: assign.children[1] });
			if (isDefaultArm(branch, s)) hasDefault = true;
		}
		return lvalue == null ? null : { arms: arms, lvalue: lvalue, hasDefault: hasDefault };
	}

	/**
	 * Assemble the `<lvalue> = switch subj { … };` replacement over the switch span, or null when a
	 * span is missing or a comment sits in a region the collapse would drop.
	 */
	private static function buildLvalueMatch(
		switchSpan: Span, lvalue: QueryNode, subject: QueryNode, arms: Array<{ arm: QueryNode, value: QueryNode }>, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final lvalueSrc: Null<String> = slice(source, lvalue);
		final subjectSrc: Null<String> = slice(source, subject);
		final lvalueSpan: Null<Span> = lvalue.span;
		final subjectSpan: Null<Span> = subject.span;
		if (lvalueSrc == null || subjectSrc == null || lvalueSpan == null || subjectSpan == null) return null;

		final kept: Array<Span> = [lvalueSpan, subjectSpan];
		final buf: StringBuf = new StringBuf();
		buf.add(lvalueSrc);
		buf.add(' = switch ');
		buf.add(subjectSrc);
		buf.add(' {');
		if (!emitArms(buf, arms, kept, source, s)) return null;
		buf.add(' };');

		return IfExpressionChain.droppedComment(switchSpan, kept, comments) ? null : {
			declSpan: switchSpan,
			editSpan: switchSpan,
			text: buf.toString(),
			message: LVALUE_MESSAGE
		};
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

		final collected: Null<{ arms: Array<{ arm: QueryNode, value: QueryNode }>, lvalue: QueryNode, hasDefault: Bool }> =
			collectLvalueArms(switchStmt, s);
		if (collected == null) return null;
		// No source default arm and no initializer to synthesize one from — cannot make it exhaustive.
		if (!collected.hasDefault) return null;
		final lvalue: QueryNode = collected.lvalue;

		// The decl arm keeps priority: an identifier l-value declared by the immediately preceding
		// mutable local is a `matchPair` case, collapsed to `final x = switch …` instead.
		if (lvalue.kind == s.identKind && prev != null && s.mutableKinds.contains(prev.kind) && prev.name == lvalue.name) return null;

		// The l-value receiver path must be side-effect-free (a field read could be a getter, which the
		// purity machinery cannot prove pure); the terminal setter ran once per taken arm before and
		// after, so it is exempt.
		if (s.fieldAccessKind != null && lvalue.kind == s.fieldAccessKind) {
			final receiver: Null<QueryNode> = lvalue.children.length > 0 ? lvalue.children[0] : null;
			if (receiver == null || !RefactorSupport.isSideEffectFree(receiver)) return null;
		}

		// A subject reading the l-value path becomes order-sensitive with the receiver after the collapse.
		return subjectTouchesLvalue(subject, lvalue, s)
			? null
			: buildLvalueMatch(switchSpan, lvalue, subject, collected.arms, source, comments, s);
	}

}

/** The kinds `PreferSwitchExpressionAssignment` reads. */
private typedef Seams = {
	var switchKinds: Array<String>;
	var caseBranchKind: String;
	var defaultBranchKind: String;
	var plainCasePatternKind: String;
	var wildcardPatternName: String;
	var parenKind: String;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var assignKind: String;
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
