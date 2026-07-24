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
 * Flags a local declaration whose value is set by an IMMEDIATELY following statement-position
 * `switch` in every arm, collapsing the pair to one assignment of a switch-expression:
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
 * The `switch` twin of `prefer-if-expression-assignment` (the `if`-chain rule) and the
 * decl-pairing sibling of `join-declaration-assignment`. Purely structural (no type
 * information). `Info` -- the code is correct, this is a readability simplification.
 *
 * ## What is flagged
 *
 * Two CONSECUTIVE statements of one statement list (`ControlFlowSupport.blockKinds`) where:
 *
 * - the first is a single-variable mutable local declaration (`mutableLocalDeclKinds`) named
 *   `x` -- a multi-declarator `var a, b;` (detected by a top-level comma in the declaration
 *   text) is skipped; an initializer is optional;
 * - the second is a statement-position `switch` (`switchKinds`) whose subject does NOT
 *   reference `x` (a subject reading `x` becomes a self-reference in `x`'s own initializer
 *   after the collapse);
 * - every non-subject child of the switch is a `case` / `default` arm (`caseBranchKind` /
 *   `defaultBranchKind`) -- a `#if`-guarded arm run projects as a `Conditional` node, which
 *   disqualifies the whole switch (a conditional-compilation arm can never be safely lifted);
 * - every arm body is EXACTLY the single statement `x = <expr>;` -- a plain `=` (`assignKind`)
 *   whose l-value is the declared identifier (`identKind`, same name), a bare `x = e;` or a
 *   braced `{ x = e; }` wrapping one. A compound (`+=`) / short-circuit (`??=`) assignment, a
 *   multi-statement body, a non-assignment body, or an l-value other than `x` (`x.f = …`)
 *   disqualifies -- mirroring the plain-`=`-only rule of the `if` twin;
 * - no arm value references `x` (`x = x + 1` becomes a rejected self-reference after collapse);
 * - `x` is written ONLY by the arm assignments: every reassignment of `x` anywhere
 *   (`prefer-final`'s complete write scan) falls inside the switch and their count equals the
 *   arm count, so after the collapse `x` is genuinely `final` (no external write, no
 *   assignment hidden in a guard);
 * - no comment sits in a region the collapse drops (the `var`/`= init` glue, an arm's `x = `
 *   prefix, the switch keywords).
 *
 * ## Exhaustiveness and the initializer
 *
 * A switch-expression must yield a value on every path, so the collapsed form needs a default:
 *
 * - the switch already has an unguarded `case _:` / `default:` arm (also assigning `x`): it is
 *   exhaustive, so the declaration's initializer is DROPPED and the existing default's value
 *   is used;
 * - otherwise, with an initializer: a synthetic `case _: <init>;` is appended, moving the
 *   initializer onto the default path;
 * - otherwise (a bare `var x;` and a non-exhaustive switch): SKIPPED. Exhaustiveness over enum
 *   constructors is a type-checker judgement this structural rule does not attempt -- with no
 *   default arm in the source it requires an initializer to synthesize one.
 *
 * ## Initializer purity
 *
 * Relocating the initializer into the default arm (or dropping it under an existing default)
 * changes WHEN it evaluates -- from unconditionally-before-the-switch to only on the default
 * path. That is observationally free only for a side-effect-free initializer, so an impure one
 * (`RefactorSupport.isSideEffectFree`) SKIPS the pair. This is the switch analogue of the
 * plain-`=`-only guard the `if` twin uses to keep every branch's evaluation faithful.
 *
 * ## Autofix
 *
 * `fix` replaces both statements with `final x:T = switch subj { … };` -- the `var` keyword
 * swapped for `final` (after the collapse `x` is never reassigned), the declared `:type`
 * preserved (explicit-type preference), the subject and every arm's pattern / guard / value
 * copied verbatim from their spans, arm bodies emitted as value expressions. The compact
 * output is re-emitted through the canonical writer, which lays the switch-expression out in
 * canonical form. Needs `switchKinds`, `caseBranchKind`, `defaultBranchKind`,
 * `plainCasePatternKind`, `wildcardPatternName`, `parenKind`, `exprStatementKind`,
 * `blockStmtKind`, `assignKind`, `mutableLocalDeclKinds` and `controlFlowSupport` (any unset
 * makes the check a no-op).
 */
@:nullSafety(Strict)
final class PreferSwitchExpressionAssignment implements Check {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-switch-expression-assignment';
	}

	public function description(): String {
		return
			'a local declaration whose value is set by a following switch in every arm, collapsible to a single switch-expression assignment';
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
				message: 'this declaration and its following switch assignment can be a single switch-expression assignment'
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
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = matchPair(kids[i], kids[i + 1], root, source, comments, s);
				if (m != null) out.push(m);
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
		for (a in arms) {
			final header: Null<String> = armHeader(a.arm, source, s);
			final value: Null<String> = slice(source, a.value);
			if (header == null || value == null) return null;
			buf.add(' ');
			buf.add(header);
			buf.add(': ');
			buf.add(value);
			buf.add(';');
			final hs: Null<Span> = headerKeptSpan(a.arm, s);
			if (hs != null) kept.push(hs);
			if (a.value.span != null) kept.push((a.value.span: Span));
		}
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
			text: buf.toString()
		};
	}

	/**
	 * The single `x = <expr>` assignment an arm body holds — a bare `x = e;` or a braced
	 * `{ x = e; }` wrapping one, with the l-value the declared identifier `name`. Null when the
	 * arm body is not exactly one such plain assignment (a compound / `??=` operator, a
	 * multi-statement body, a non-assignment, or an l-value other than `name` all disqualify).
	 */
	private static function armAssignment(branch: QueryNode, name: String, s: Seams): Null<QueryNode> {
		final body: Null<QueryNode> = armBody(branch, s);
		if (body == null) return null;
		final stmt: QueryNode = body.kind == s.blockStmtKind ? (body.children.length == 1 ? body.children[0] : body) : body;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != s.assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
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
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** A collapsible pair: the declaration span (finding key), the replaced span, and the built replacement text. */
private typedef Match = {
	var declSpan: Span;
	var editSpan: Span;
	var text: String;
}
