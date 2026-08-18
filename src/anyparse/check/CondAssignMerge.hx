package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

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
 * The EXIT arms take a region whose every branch is a value `return` (or a `throw`), where the
 * text kept once is the keyword itself: `#if release return true; #else return ok(); #end` ->
 * `return #if release true #else ok() #end;`. A value-less `return;` is a different node kind, so
 * a branch holding one refuses the region — the merged form has no value to carry the directives.
 * The merged statement can spell only ONE keyword, which the prefix agreement below enforces:
 * a `return` branch beside a `throw` branch is refused.
 *
 * ## The implicit else
 *
 * The exit arms — and ONLY they — also take a region with NO `#else` when the statement
 * IMMEDIATELY after it is an unconditional exit of the same keyword:
 *
 * ```haxe
 * #if windows
 * return '\r\n';
 * #end
 * return '\n';
 * // ->
 * return #if windows '\r\n' #else '\n' #end;
 * ```
 *
 * Inside the region's conditions that follower is dead code (the branch exits before reaching
 * it), so it IS the else branch, and the merge consumes it — the finding's span covers both
 * statements and a note on the message says so. An `#elseif` chain that never reaches `#else`
 * closes the same way.
 *
 * This shape is UNSOUND for the assignment and declaration arms and stays refused there: both
 * statements execute, so the follower would win rather than the branch. It needs a follower at
 * all, so a region that is the LAST statement of its list is refused, as is one separated from
 * the following exit by any other statement. A region that DOES reach `#else` never consumes
 * its follower, whatever that follower is.
 *
 * ## What is flagged
 *
 * A region that is a DIRECT CHILD of a statement list (`ControlFlowSupport.blockKinds`) —
 * statement position, never a member run, a case group or an expression slot, where the
 * merged form would not be a statement. That gate is also what keeps the implicit else in ONE
 * statement list: a region under a brace-less `if` / loop / `try` body is a child of that host,
 * not of the enclosing block, so the exit after `#end` is never mistaken for its else branch.
 * Beyond the position, ALL of:
 *
 *  - every branch is present, `#else` INCLUDED, or the implicit-else shape above supplies it.
 *    Without either, the statement stays conditional and merging would make it unconditional,
 *    which is a behaviour change, so a bare `#if … #end` (and an `#elseif` chain that never
 *    reaches `#else`) is refused. `#elseif` chains WITH a final `#else` merge, each clause
 *    keeping its own condition;
 *  - every branch holds EXACTLY ONE statement — no empty branch (whose target would silently
 *    gain a value), none with a second statement;
 *  - that statement is a BARE assignment (`RefShape.assignKind`, a plain `=` — a compound
 *    `+=` is a different kind and never matches) whose r-value is not itself an assignment
 *    (`a = b = c` would leave the inner one inside the merged r-value), or a single-declarator
 *    local declaration WITH an initializer, or a value return / throw
 *    (`RefShape.returnStatementKind` / `throwKinds`);
 *  - every branch agrees on SHAPE and on the text before the value — the l-value for the
 *    assignment shape, the `<keyword> <name>[:<type>] =` prefix for the declaration one, the
 *    exit keyword for the return / throw one. Every prefix is a verbatim source slice (only the
 *    assignment shape's `=` is re-spelled, since the l-value slice stops short of it), so a
 *    branch spelling its target differently — down to the whitespace inside it — is a safe miss
 *    rather than a guess about which spelling to keep. The shape is compared on its own rather
 *    than inferred from the prefix: which arm produced a branch is what the merged statement's
 *    soundness turns on, and it must not rest on prefix spellings never colliding;
 *  - no branch statement contains a `#`. That rejects the r-value that already carries
 *    directives (`a = #if air 1 #else 2 #end;`, which the merge would nest) and, with it,
 *    every string literal whose text could have been mistaken for a branch marker by the
 *    directive scan below;
 *  - every branch VALUE is single-line. A value broken across lines would splice its
 *    continuation between two directives, where it reads as belonging to a branch it does not —
 *    the same reason a multi-line condition is refused below, measured on the other half of the
 *    clause;
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
 * A COMMENT anywhere in the merged span leaves the finding REPORT-ONLY (with a note appended to
 * the message): a comment is trivia, not a child, so the rebuilt statement would drop it. For an
 * implicit-else merge that span reaches past `#end` to the consumed follower.
 *
 * ## Grammar-agnostic
 *
 * The region is recognised by its span TEXT opening with the `#if` keyword
 * (`RefShape.conditionalIfKeyword`) — the same uniform, scope-independent test `if-false`
 * uses, since conditional nodes project no condition child in any scope. The statement shapes
 * come from `RefShape.exprStatementKind` / `assignKind` / `localDeclKinds` /
 * `returnStatementKind` / `throwKinds`, and the position gate from
 * `GrammarPlugin.controlFlowSupport`. Any of the first three unset makes the check a no-op,
 * report and fix alike; either exit kind unset only drops that arm — and with it the
 * implicit-else shape, which no other arm may take.
 *
 * The branch and terminator spellings (`#elseif` / `#else` / `#end`) are NOT read from a seam
 * and are the Haxe ones. `RefShape.conditionalElseKeywords` carries the first two as an
 * unordered set, which is not enough here: the scan must know WHICH keyword ends the chain
 * (only a final `#else`, or an implicit one, makes the merge sound) and must try `#elseif`
 * before its `#else` prefix, and there is no `#end` field at all. A grammar spelling them
 * differently needs those seams introduced before this check can follow it.
 *
 * ## Autofix
 *
 * `fix` emits ONE edit per finding: the whole flagged span replaced by the merged statement,
 * assembled from verbatim source slices (the shared prefix, each branch header, each branch
 * value) plus the closing `#end;`. Exactly one branch is live on any given define set — that is
 * what a mandatory `#else`, explicit or implicit, buys — so the merged statement yields the same
 * value the region did, on every target. The caller re-emits through the canonical writer
 * (`RefactorSupport.canonicalize`), which re-indents the merged line.
 */
@:nullSafety(Strict)
final class CondAssignMerge implements Check implements DefaultOff {

	/** ASCII-only note appended when a comment inside the merged span withholds the autofix. */
	private static inline final COMMENT_NOTE: String = ' (comment in the merged span - merge by hand)';

	private static inline final MESSAGE: String =
		'every branch of this conditional-compilation region assigns the same target - merge it into one assignment with a conditional r-value';

	/** The EXIT arms' message: the merged statement keeps one `return` / `throw` keyword. */
	private static inline final EXIT_MESSAGE: String =
		'every branch of this conditional-compilation region exits with the same keyword - merge it into one statement with a conditional value';

	/** ASCII-only note appended when the statement AFTER the region is merged in as the implicit else. */
	private static inline final FOLLOWER_NOTE: String = ' (the statement after the region is the implicit else and is merged in)';

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
		return
			'a `#if … #else … #end` region whose every branch assigns the same target, or returns / throws — mergeable into one conditional value; an `#else`-less region of exits also absorbs the exit that follows it';
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
				message: message(m)
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

		return RefactorSupport.dropContainedEdits(CheckScan.collectSpanEdits(violations, byKey, (m, _) -> {
			final text: Null<String> = m.text;
			return text == null ? null : { span: m.span, text: text };
		}));
	}

	/**
	 * The finding's message: which arm matched, plus a note per gate the match had to relax —
	 * a consumed follower, and a comment that leaves the merge to the reader.
	 */
	private static function message(m: Match): String {
		final base: String = (m.exit ? EXIT_MESSAGE : MESSAGE) + (m.implicitElse ? FOLLOWER_NOTE : '');
		return m.text == null ? base + COMMENT_NOTE : base;
	}

	/**
	 * Bundle the required kinds, or null when a required one is unset (the check is then a no-op).
	 * The EXIT kinds are not required: either unset simply drops that arm (and with it the
	 * implicit-else shape, which no other arm may take).
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return if (ifKeyword == null || exprStmtKind == null || assignKind == null || support == null)
			null
		else if (localDeclKinds == null || localDeclKinds.length == 0)
			null
		else
			{
				ifKeyword: ifKeyword,
				exprStmtKind: exprStmtKind,
				assignKind: assignKind,
				localDeclKinds: localDeclKinds,
				returnKind: shape.returnStatementKind,
				throwKinds: shape.throwKinds ?? [],
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
		if (seams.blockKinds.contains(node.kind)) for (i in 0...node.children.length) {
			final next: Null<QueryNode> = i + 1 < node.children.length ? node.children[i + 1] : null;
			final m: Null<Match> = matchRegion(node.children[i], next, source, comments, seams);
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
		node: QueryNode, next: Null<QueryNode>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, seams: Seams
	): Null<Match> {
		final span: Null<Span> = node.span;
		if (span == null || !sliceStartsWith(source, span.from, seams.ifKeyword)) return null;
		final region: Null<Region> = splitArms(source, span, node.children, seams);
		if (region == null) return null;
		// A region that never reaches `#else` merges only by consuming the statement AFTER it as
		// the implicit else — and only when its branches EXIT, which is what makes that statement
		// dead inside them. Without a follower there is no else branch to merge at all.
		final follower: Null<Arm> = region.hasElse ? null : followerArm(next, span);
		if (!region.hasElse && follower == null) return null;
		final all: Array<Arm> = follower == null ? region.arms : region.arms.concat([follower]);
		final parts: Null<Array<Parts>> = agreedParts(source, all, seams);
		if (parts == null || (follower != null && !parts[0].exit)) return null;
		// Every SHAPE gate, the headers included, runs BEFORE the comment gate: a region the
		// headers refuse is not reportable at all, and reporting it would advise a hand-merge
		// of something the rule itself cannot express.
		final headers: Null<Array<String>> = branchHeaders(source, comments, region.arms);
		if (headers == null) return null;
		if (follower != null) headers.push(ELSE_KEYWORD);
		final merged: Span = follower == null ? span : new Span(span.from, follower.stmtSpan.to);
		return {
			span: merged,
			exit: parts[0].exit,
			implicitElse: follower != null,
			text: hasComment(comments, merged) ? null : assemble(headers, parts)
		};
	}

	/**
	 * The statement after the region as an extra arm — the implicit else — or null when there is
	 * none. Its header offset is the region's own end, which `branchHeaders` never reads (the
	 * caller passes it the region's own arms): the merged form spells this branch `#else`, since
	 * the region carries no directive for it. Were it ever read, the slice from `#end` to the
	 * follower is whitespace and trims to `''`, which `branchHeaders` refuses — the misuse fails
	 * closed.
	 */
	private static function followerArm(next: Null<QueryNode>, region: Span): Null<Arm> {
		if (next == null) return null;
		final nextSpan: Null<Span> = next.span;
		if (nextSpan == null || nextSpan.from < region.to) return null;
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final armSpan: Span = nextSpan;
		return { headerFrom: region.to, stmt: next, stmtSpan: armSpan };
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
	private static function splitArms(source: String, region: Span, children: Array<QueryNode>, seams: Seams): Null<Region> {
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
		if (endAt == -1) return null;
		if (source.substring(endAt, region.to).trim() != END_KEYWORD) return null;
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
		return { arms: arms, hasElse: chainEndsWithElse };
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
			if (parts == null) return null;
			if (out.length > 0 && (parts.prefix != out[0].prefix || parts.exit != out[0].exit)) return null;
			out.push(parts);
		}
		return out;
	}

	/**
	 * Whether `text` spans more than one line — the verdict the branch HEADERS get.
	 *
	 * A condition broken across lines cannot be emitted verbatim inside a one-statement merge: its
	 * continuation would land between two directives and read as belonging to a branch it does not.
	 * The VALUES used to share this refusal and no longer do — the writer's `conditionalExprFit` gives
	 * every branch of a merged region its own directive line, so a multi-line value keeps its own shape
	 * instead of being spliced into a neighbour. Headers have no such writer arm.
	 */
	private static function isMultiLine(text: String): Bool {
		return text.indexOf('\n') != -1 || text.indexOf('\r') != -1;
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
			final header: String = buf.toString().trim();
			if (header == '' || isMultiLine(header)) return null;
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
		return if (source.substring(arm.stmtSpan.from, arm.stmtSpan.to).indexOf('#') != -1)
			null
		else if (stmt.kind == seams.exprStmtKind)
			assignParts(source, stmt, seams)
		else if (stmt.kind == seams.returnKind || seams.throwKinds.contains(stmt.kind))
			exitParts(source, stmt, arm.stmtSpan)
		else if (seams.localDeclKinds.contains(stmt.kind))
			declParts(source, stmt, arm.stmtSpan, seams)
		else
			null;
	}

	/**
	 * The keyword / value split of a `return <expr>;` or `throw <expr>;` statement, or null when
	 * it carries no value. A value-less `return;` is a DIFFERENT kind, so it never reaches here
	 * and its branch refuses the whole region.
	 *
	 * The prefix is the exit keyword itself, which is what makes `agreedParts`' prefix equality
	 * reject a `return` arm beside a `throw` one: the merged statement can spell only one of them.
	 */
	private static function exitParts(source: String, stmt: QueryNode, stmtSpan: Span): Null<Parts> {
		if (stmt.children.length != 1) return null;
		final valueSpan: Null<Span> = stmt.children[0].span;
		if (valueSpan == null) return null;
		final prefix: String = source.substring(stmtSpan.from, valueSpan.from).trim();
		return prefix == '' ? null : { prefix: prefix, value: source.substring(valueSpan.from, valueSpan.to), exit: true };
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
			value: source.substring(rhsSpan.from, rhsSpan.to),
			exit: false
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
		final prefix: String = source.substring(stmtSpan.from, initSpan.from).trim();
		return prefix.endsWith('=') ? {
			prefix: prefix,
			value: source.substring(initSpan.from, initSpan.to),
			exit: false
		} : null;
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

	/** The value-returning `return` statement kind, or null when the grammar leaves it unset. */
	var returnKind: Null<String>;

	/** The `throw` kinds, empty when the grammar leaves them unset. */
	var throwKinds: Array<String>;

	var blockKinds: Array<String>;
}

/** One branch of a region: the offset of its own directive, and the single statement it holds. */
private typedef Arm = {
	var headerFrom: Int;
	var stmt: QueryNode;
	var stmtSpan: Span;
}

/** A split region: its branches in order, and whether the chain reaches a final `#else`. */
private typedef Region = {
	var arms: Array<Arm>;
	var hasElse: Bool;
}

/** A branch statement split into the text kept once and the r-value kept per branch. */
private typedef Parts = {
	var prefix: String;
	var value: String;

	/** Whether the statement EXITS (`return` / `throw`) — the only shape the implicit else is sound for. */
	var exit: Bool;
}

/** A mergeable region: its span (finding key) and the merged statement, or null text when a comment blocks the fix. */
private typedef Match = {
	var span: Span;

	/** Whether the arms are EXIT statements — picks the message, and gates the implicit else. */
	var exit: Bool;

	/** Whether the statement AFTER the region was consumed as the implicit else. */
	var implicitElse: Bool;

	var text: Null<String>;
}
