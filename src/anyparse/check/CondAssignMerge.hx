package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a statement-scope conditional-compilation region whose EVERY branch is a single
 * assignment to the same target, and merges it into ONE statement whose r-value carries the
 * directives:
 *
 * ```haxe
 * #if mobile
 * hitAreaScale = 2;
 * #else
 * hitAreaScale = 1.2;
 * #end
 * // ->
 * hitAreaScale = #if mobile 2 #else 1.2 #end;
 * ```
 *
 * The five lines say one thing — the value differs per target — and spell the assignment
 * three times to say it. `Info`, and OPINIONATED: some projects prefer the branch-per-line
 * shape, so the rule is `DefaultOff` and a project opts in with
 * `"cond-assign-merge": { "enabled": true }`.
 *
 * The sibling DECLARATION shape merges the same way, keeping keyword, name and type:
 * `#if mobile var q:Int = 2; #else var q:Int = 3; #end` -> `var q:Int = #if mobile 2 #else 3 #end;`.
 * A conditional-compilation branch is textual, not a scope, so the declared local is visible
 * after `#end` either way — the merge does not move a binding.
 *
 * ## What is flagged
 *
 * A region that is a DIRECT CHILD of a statement list (`ControlFlowSupport.blockKinds`) —
 * statement position, never a member run, a case group or an expression slot, where the
 * merged form would not be a statement — and where ALL of:
 *
 *  - every branch is present, `#else` INCLUDED. A region without one leaves the assignment
 *    conditional; merging would make it unconditional, which is a behaviour change, so a
 *    bare `#if … #end` (and an `#elseif` chain that never reaches `#else`) is refused.
 *    `#elseif` chains WITH a final `#else` merge, each clause keeping its own condition;
 *  - every branch holds EXACTLY ONE statement — no empty branch (whose target would silently
 *    gain a value), none with a second statement;
 *  - that statement is a BARE assignment (`RefShape.assignKind`, a plain `=` — a compound
 *    `+=` is a different kind and never matches) whose r-value is not itself an assignment
 *    (`a = b = c` would leave the inner one inside the merged r-value), or a single-declarator
 *    local declaration WITH an initializer;
 *  - the text before the r-value is IDENTICAL in every branch — the l-value for the
 *    assignment shape, the `<keyword> <name>[:<type>] =` prefix for the declaration one. Both
 *    are verbatim source slices (only the assignment shape's `=` is re-spelled, since the
 *    l-value slice stops short of it), so a branch spelling its target differently — down to
 *    the whitespace inside it — is a safe miss rather than a guess about which spelling to keep;
 *  - no branch statement contains a `#`. That rejects the r-value that already carries
 *    directives (`a = #if air 1 #else 2 #end;`, which the merge would nest) and, with it,
 *    every string literal whose text could have been mistaken for a branch marker by the
 *    directive scan below;
 *  - each branch header (`#if <cond>` / `#elseif <cond>` / `#else`), read with its comments
 *    removed, is single-line — a condition broken across lines cannot go inline verbatim. The
 *    comment removal is what keeps this SHAPE verdict independent of the comment gate below:
 *    a commented branch is reported, not silently refused, and a multi-line condition is
 *    refused whether or not a comment shares its region.
 *
 * Branch boundaries come from the region's own DIRECTIVE LINES, not from the tree: a
 * conditional region projects its branches as FLAT children with no boundary node, so the
 * `#elseif` / `#else` offsets are scanned out of the source (nesting-aware, `#if` /`#end`
 * counted) and each child is required to fall inside its own branch. The region's `#end` must
 * be the one the scan reaches at depth 0, so a marker inside a string that unbalances the
 * scan fails the region closed.
 *
 * A COMMENT anywhere in the region leaves the finding REPORT-ONLY (with a note appended to
 * the message): a comment is trivia, not a child, so the rebuilt statement would drop it.
 *
 * ## Grammar-agnostic
 *
 * The region is recognised by its span TEXT opening with the `#if` keyword
 * (`RefShape.conditionalIfKeyword`) — the same uniform, scope-independent test `if-false`
 * uses, since conditional nodes project no condition child in any scope. The statement shapes
 * come from `RefShape.exprStatementKind` / `assignKind` / `localDeclKinds`, and the position
 * gate from `GrammarPlugin.controlFlowSupport`. Any of them unset makes the check a no-op,
 * report and fix alike.
 *
 * The branch and terminator spellings (`#elseif` / `#else` / `#end`) are NOT read from a seam
 * and are the Haxe ones. `RefShape.conditionalElseKeywords` carries the first two as an
 * unordered set, which is not enough here: the scan must know WHICH keyword ends the chain
 * (only a final `#else` makes the merge sound) and must try `#elseif` before its `#else`
 * prefix, and there is no `#end` field at all. A grammar spelling them differently needs those
 * seams introduced before this check can follow it.
 *
 * ## Autofix
 *
 * `fix` emits ONE edit per finding: the whole region span replaced by the merged statement,
 * assembled from verbatim source slices (the shared prefix, each branch header, each branch
 * r-value) plus the closing `#end;`. Exactly one branch is live on any given define set —
 * that is what `#else` being mandatory buys — so the merged statement assigns the same value
 * the region did, on every target. The caller re-emits through the canonical writer
 * (`RefactorSupport.canonicalize`), which re-indents the merged line.
 */
@:nullSafety(Strict)
final class CondAssignMerge implements Check implements DefaultOff {

	/** ASCII-only note appended when a comment inside the region withholds the autofix. */
	private static inline final COMMENT_NOTE: String = ' (comment in the region - merge by hand)';

	private static inline final MESSAGE: String =
		'every branch of this conditional-compilation region assigns the same target - merge it into one assignment with a conditional r-value';

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	private static inline final END_KEYWORD: String = '#end';
	private static inline final ELSEIF_KEYWORD: String = '#elseif';
	private static inline final ELSE_KEYWORD: String = '#else';

	public function new() {}

	public function id(): String {
		return 'cond-assign-merge';
	}

	public function description(): String {
		return 'a `#if … #else … #end` region whose every branch assigns the same target — mergeable into one conditional r-value';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'cond-assign-merge',
				severity: Severity.Info,
				message: m.text == null ? MESSAGE + COMMENT_NOTE : MESSAGE
			});
		}
		return violations;
	}

	/**
	 * Replace each flagged region with its merged statement. The candidate set is re-derived
	 * from the tree, so a reported span that no longer names a mergeable region (a stale or
	 * foreign violation) produces no edit; a region the comment gate left report-only carries
	 * no merged text and is skipped here too.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in collectMatches(tree, source, seams)) byKey['${m.span.from}:${m.span.to}'] = m;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m == null) continue;
			final text: Null<String> = m.text;
			if (text != null) edits.push({ span: m.span, text: text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (ifKeyword == null || exprStmtKind == null || assignKind == null || support == null) return null;
		return localDeclKinds == null || localDeclKinds.length == 0 ? null : {
			ifKeyword: ifKeyword,
			exprStmtKind: exprStmtKind,
			assignKind: assignKind,
			localDeclKinds: localDeclKinds,
			blockKinds: support.blockKinds()
		};
	}

	/** Every mergeable region reachable under `root`, in document order — the candidate set `run` and `fix` share. */
	private static function collectMatches(root: QueryNode, source: String, seams: Seams): Array<Match> {
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final out: Array<Match> = [];
		walk(root, source, comments, seams, out);
		return out;
	}

	/** Walk `node`, matching each region that is a DIRECT child of a statement list. */
	private static function walk(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, seams: Seams, out: Array<Match>
	): Void {
		if (seams.blockKinds.contains(node.kind)) for (child in node.children) {
			final m: Null<Match> = matchRegion(child, source, comments, seams);
			if (m != null) out.push(m);
		}
		for (child in node.children) walk(child, source, comments, seams, out);
	}

	/**
	 * The merge match for `node` when it is a conditional-compilation region every branch of
	 * which assigns the same target, or null. `text` is null when a comment inside the region
	 * makes the merge lossy — the finding is still reported, report-only.
	 */
	private static function matchRegion(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, seams: Seams
	): Null<Match> {
		final span: Null<Span> = node.span;
		if (span == null || !sliceStartsWith(source, span.from, seams.ifKeyword)) return null;
		final arms: Null<Array<Arm>> = splitArms(source, span, node.children, seams);
		if (arms == null) return null;
		final parts: Null<Array<Parts>> = agreedParts(source, arms, seams);
		if (parts == null) return null;
		// Every SHAPE gate, the headers included, runs BEFORE the comment gate: a region the
		// headers refuse is not reportable at all, and reporting it would advise a hand-merge
		// of something the rule itself cannot express.
		final headers: Null<Array<String>> = branchHeaders(source, comments, arms);
		if (headers == null) return null;
		return { span: span, text: hasComment(comments, span) ? null : assemble(headers, parts) };
	}

	/**
	 * Split `region` into its branches, each a header offset (the branch's own directive) plus
	 * the ONE statement it holds — or null when the region is not a complete `#if … #else …
	 * #end` with exactly one statement per branch.
	 *
	 * The branches are recovered from the DIRECTIVE LINES because the tree projects them flat:
	 * `children[i]` must be the statement of branch `i`, which is what pins one statement per
	 * branch (a branch with two, or with none, shifts a child out of its own range). The scan
	 * is nesting-aware and must reach the region's own `#end` at depth 0 with nothing but that
	 * keyword left, so an unbalanced marker inside a string literal fails the region closed.
	 */
	private static function splitArms(source: String, region: Span, children: Array<QueryNode>, seams: Seams): Null<Array<Arm>> {
		final markers: Array<Int> = [];
		var chainEndsWithElse: Bool = false;
		var depth: Int = 0;
		var endAt: Int = -1;
		var i: Int = region.from + seams.ifKeyword.length;
		while (i < region.to) {
			if (source.charCodeAt(i) != '#'.code) {
				i++;
			} else if (sliceStartsWith(source, i, seams.ifKeyword)) {
				depth++;
				i += seams.ifKeyword.length;
			} else if (sliceStartsWith(source, i, END_KEYWORD)) {
				if (depth == 0) {
					endAt = i;
					break;
				}
				depth--;
				i += END_KEYWORD.length;
			} else if (depth == 0 && sliceStartsWith(source, i, ELSEIF_KEYWORD)) {
				markers.push(i);
				chainEndsWithElse = false;
				i += ELSEIF_KEYWORD.length;
			} else if (depth == 0 && sliceStartsWith(source, i, ELSE_KEYWORD)) {
				markers.push(i);
				chainEndsWithElse = true;
				i += ELSE_KEYWORD.length;
			} else {
				i++;
			}
		}
		if (!chainEndsWithElse || endAt == -1) return null;
		if (StringTools.trim(source.substring(endAt, region.to)) != END_KEYWORD) return null;
		if (children.length != markers.length + 1) return null;

		final bounds: Array<Int> = [region.from].concat(markers);
		bounds.push(endAt);
		final arms: Array<Arm> = [];
		for (a in 0...children.length) {
			final stmt: QueryNode = children[a];
			final stmtSpan: Null<Span> = stmt.span;
			if (stmtSpan == null || stmtSpan.from < bounds[a] || stmtSpan.to > bounds[a + 1]) return null;
			// Re-bind to a non-null local: narrowing does not reach the struct literal below.
			final armSpan: Span = stmtSpan;
			arms.push({ headerFrom: bounds[a], stmt: stmt, stmtSpan: armSpan });
		}
		return arms;
	}

	/**
	 * Each branch's prefix / r-value split, or null when a branch statement is not a bare
	 * assignment / initialized declaration, or the branches do not AGREE on their prefix —
	 * the SHAPE gate, independent of how the text is later assembled.
	 */
	private static function agreedParts(source: String, arms: Array<Arm>, seams: Seams): Null<Array<Parts>> {
		final out: Array<Parts> = [];
		for (arm in arms) {
			final parts: Null<Parts> = armParts(source, arm, seams);
			if (parts == null || (out.length > 0 && parts.prefix != out[0].prefix)) return null;
			out.push(parts);
		}
		return out;
	}

	/**
	 * Each branch's own directive text (`#if <cond>` / `#elseif <cond>` / `#else`), or null when
	 * one of them cannot go inline — the second SHAPE gate.
	 *
	 * A header is the slice from its directive to its statement with the COMMENT tokens removed:
	 * a comment between the two is trivia the merge drops anyway (the comment gate reports that
	 * separately), and leaving it in would make every commented branch look multi-line. What is
	 * left must be single-line — a condition broken across lines cannot be emitted verbatim
	 * inside a one-statement merge, and that verdict must not depend on whether a comment
	 * happens to sit in the same region.
	 */
	private static function branchHeaders(
		source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, arms: Array<Arm>
	): Null<Array<String>> {
		final out: Array<String> = [];
		for (arm in arms) {
			final buf: StringBuf = new StringBuf();
			var at: Int = arm.headerFrom;
			for (token in comments) if (token.from >= at && token.to <= arm.stmtSpan.from) {
				buf.add(source.substring(at, token.from));
				at = token.to;
			}
			buf.add(source.substring(at, arm.stmtSpan.from));
			final header: String = StringTools.trim(buf.toString());
			if (header == '' || header.indexOf('\n') != -1 || header.indexOf('\r') != -1) return null;
			out.push(header);
		}
		return out;
	}

	/** The merged statement: the shared prefix, then each branch's header and r-value, then `#end;`. */
	private static function assemble(headers: Array<String>, parts: Array<Parts>): String {
		final buf: StringBuf = new StringBuf();
		buf.add(parts[0].prefix);
		for (a in 0...headers.length) buf.add(' ${headers[a]} ${parts[a].value}');
		buf.add(' $END_KEYWORD;');
		return buf.toString();
	}

	/**
	 * A branch statement split into the text the merge keeps ONCE (everything up to and
	 * including the `=`) and the r-value it keeps per branch, or null when the statement is
	 * neither a bare assignment nor an initialized single-declarator declaration.
	 *
	 * A statement holding a `#` is refused outright: it is either an r-value that already
	 * carries directives (which the merge would nest) or text the branch scan could have
	 * mistaken for a marker.
	 */
	private static function armParts(source: String, arm: Arm, seams: Seams): Null<Parts> {
		final stmt: QueryNode = arm.stmt;
		if (source.substring(arm.stmtSpan.from, arm.stmtSpan.to).indexOf('#') != -1) return null;
		if (stmt.kind == seams.exprStmtKind) return assignParts(source, stmt, seams);
		return seams.localDeclKinds.contains(stmt.kind) ? declParts(source, stmt, arm.stmtSpan, seams) : null;
	}

	/** The prefix / r-value split of a bare `<l-value> = <r-value>;` statement, or null when it is not one. */
	private static function assignParts(source: String, stmt: QueryNode, seams: Seams): Null<Parts> {
		if (stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != seams.assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
		final rhs: QueryNode = assign.children[1];
		if (rhs.kind == seams.assignKind) return null; // `a = b = c` — the inner assignment cannot go inline
		final lhsSpan: Null<Span> = assign.children[0].span;
		final rhsSpan: Null<Span> = rhs.span;
		return lhsSpan == null || rhsSpan == null ? null : {
			prefix: '${source.substring(lhsSpan.from, lhsSpan.to)} =',
			value: source.substring(rhsSpan.from, rhsSpan.to)
		};
	}

	/**
	 * The prefix / initializer split of a `<keyword> <name>[:<type>] = <init>;` declaration, or
	 * null when it has no initializer or declares a second variable — a continuation projects
	 * as a further declaration-kind child, so a single-declarator initialized declaration is
	 * exactly the one-child case whose child is not itself a declaration.
	 */
	private static function declParts(source: String, stmt: QueryNode, stmtSpan: Span, seams: Seams): Null<Parts> {
		if (stmt.children.length != 1) return null;
		final init: QueryNode = stmt.children[0];
		if (seams.localDeclKinds.contains(init.kind)) return null;
		final initSpan: Null<Span> = init.span;
		if (initSpan == null) return null;
		final prefix: String = StringTools.trim(source.substring(stmtSpan.from, initSpan.from));
		return StringTools.endsWith(prefix, '=') ? { prefix: prefix, value: source.substring(initSpan.from, initSpan.to) } : null;
	}

	/** Whether a comment token overlaps `region` — the merge rebuilds the statement, so any comment in it would be lost. */
	private static function hasComment(comments: Array<{ from: Int, to: Int, isLine: Bool }>, region: Span): Bool {
		for (token in comments) if (token.from < region.to && token.to > region.from) return true;
		return false;
	}

	private static function sliceStartsWith(s: String, at: Int, what: String): Bool {
		return at + what.length <= s.length && s.substr(at, what.length) == what;
	}

}

/** The kinds `CondAssignMerge` reads. */
private typedef Seams = {
	var ifKeyword: String;
	var exprStmtKind: String;
	var assignKind: String;
	var localDeclKinds: Array<String>;
	var blockKinds: Array<String>;
}

/** One branch of a region: the offset of its own directive, and the single statement it holds. */
private typedef Arm = {
	var headerFrom: Int;
	var stmt: QueryNode;
	var stmtSpan: Span;
}

/** A branch statement split into the text kept once and the r-value kept per branch. */
private typedef Parts = {
	var prefix: String;
	var value: String;
}

/** A mergeable region: its span (finding key) and the merged statement, or null text when a comment blocks the fix. */
private typedef Match = {
	var span: Span;
	var text: Null<String>;
}
