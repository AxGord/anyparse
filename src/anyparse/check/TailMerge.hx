package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NormalizedSpan;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a branch of an `if` chain that ENDS with the very statements that follow the
 * chain — a duplicated tail. Control leaving the branch normally would run the shared
 * copy anyway, so the branch's own copy can be deleted and the branch left to fall
 * through onto it. Purely structural (no type information), so it holds without a
 * type-checker. `Info` — the code is correct, this is a de-duplication.
 *
 * ```haxe
 * if (cond1) {
 *     if (c2) {
 *         work();
 *         helper(v);   // ← duplicated tail
 *         return v;    // ←
 *     } else if (c3) {
 *         work2();
 *         helper(v);   // ← duplicated tail
 *         return v;    // ←
 *     }
 * }
 * helper(v);           // the shared fall-through run
 * return v;
 * ```
 *
 * ## The fall-through run
 *
 * The walk threads a `Fall` descriptor — the statements that execute once the construct
 * it is visiting completes. A block hands each of its statements the run that follows it
 * within the block, and its LAST statement the run it inherited from its own parent; an
 * `if` hands the same run to every branch, an `else if` chain included (all of them
 * complete into the same place). EVERY other node — a loop, a `switch`, a `try`, a
 * function declaration, an expression — resets the run to empty for its children, which
 * is what makes loop bodies, `switch` cases, `catch` bodies and lambdas fail CLOSED: a
 * `break`-less loop body does not complete into the code after the loop (it iterates),
 * and a `case` body's continuation is the `switch`'s, not its own. So those are silently
 * out of scope by construction rather than by a special case. A macro-reification subtree
 * (`RefShape.opaqueKinds`) is not walked at all — its statements may be spliced into a
 * scope this walk never sees, so the run it appears to complete into is not the run it
 * will complete into.
 *
 * ## Gates
 *
 * A branch's trailing run is flagged only when ALL hold:
 *
 *  - TERMINAL — the fall-through run ENDS in a `return` or a `throw`
 *    (`RefShape.valueReturnKinds` + `throwKinds` + `voidReturnKind`). `break` and
 *    `continue` are DELIBERATELY excluded (hence the explicit kind set rather than
 *    `controlExitKinds`): a loop-exit tail is not worth the extra reasoning, and leaving it
 *    out costs only a missed finding.
 *  - IDENTITY — the branch's trailing statements and the fall-through run are
 *    token-identical, by `sameStatement`: `RefactorSupport.structurallyEqual` AND
 *    whitespace-normalized source equality. Neither alone suffices — shape equality
 *    cannot see a comment sitting INSIDE a statement's span, and normalized source alone
 *    collapses whitespace inside string literals, equating `f("a  b")` with `f("a b")`.
 *    Together they are exactly token identity, refusing whatever they cannot prove.
 *  - FULL COVERAGE — the matched suffix covers the ENTIRE fall-through run, not a
 *    trailing part of it. A branch ending in `r(); return v;` where the shared run is
 *    `q(); r(); return v;` must keep its copy: falling through would additionally run
 *    `q()`.
 *  - NON-EMPTY REMAINDER — at least one statement survives in the branch. A branch whose
 *    whole body IS the tail would be emptied; the useful edit there is deleting the
 *    branch (and possibly inverting the condition), which this rule does not do.
 *  - NO CONDITIONAL COMPILATION — neither the removed region nor the kept run contains
 *    `#if` / `#elseif` / `#else` / `#end`. A plain text scan, so a directive-looking
 *    string literal also refuses — conservative in the safe direction.
 *  - NO SHADOWING — no name bound between the fall-through run's scope and the branch
 *    (the branch's own locals and local functions, plus any block scope entered on the
 *    way) is referenced in the removed tail. `var t = c(); helper(t); return t;` inside a
 *    branch is token-identical to an outer `helper(t); return t;` yet means something else
 *    — the branch's `t`, not the outer one; a local `function helper()`, `inline` or not,
 *    hides an outer `helper` the same way, and a declaration behind metadata
 *    (`@:meta var t = …`) binds exactly as one written bare. A declaration whose bound
 *    names the projection cannot enumerate — a multi-declarator `var a = 1, t = 2;`, of
 *    which only `a` is named — would make this gate blind, so its presence anywhere on the
 *    way refuses outright (`hasOpaqueDecl`). The tail's OWN declarations are exempt: the
 *    shared copy declares the same names, so falling through re-binds them identically.
 *    This is a HARD gate: no finding at all, since the duplication is only apparent.
 *
 * ## Autofix
 *
 * `fix` deletes the branch's trailing run together with the trivia before it
 * (`[prevStatement.to, lastTail.to)`), leaving the branch to fall through. Two extra
 * COMMENT gates apply to the fix only — the finding is still reported, it just yields no
 * edit: every comment in the removed region must also appear before the kept run (an
 * explanatory comment duplicated alongside the code is fine to drop; a unique one would
 * be lost), and no comment may sit between the last removed statement and the branch's
 * closing brace (a trailing `// …` there would be stranded). Nested findings are passed
 * through `RefactorSupport.dropContainedEdits` so no two deletions overlap.
 */
@:nullSafety(Strict)
final class TailMerge implements Check {

	private static inline final RULE_ID: String = 'tail-merge';

	/** An if node carries at least [cond, then]. */
	private static inline final IF_CHILD_COUNT: Int = 2;

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The conditional-compilation markers that refuse a candidate wherever they appear in its regions. */
	private static final CONDITIONAL_DIRECTIVES: Array<String> = ['#if', '#elseif', '#else', '#end'];

	/**
	 * No fall-through at all — what every non-block, non-if node hands its children. Shared
	 * across every `run` / `fix` on every thread, so its arrays are READ-ONLY: a `Fall` is
	 * only ever widened by `concat` into a fresh array, never mutated in place.
	 */
	private static final EMPTY_FALL: Fall = {
		stmts: [],
		prevEnd: 0,
		shadow: [],
		opaqueDecl: false
	};

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a conditional branch ending with the same statements that follow the if — removable, control falls through to them';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) for (c in scan(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: c.tailSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: message(c.count)
			});
		}
		return violations;
	}

	/**
	 * Delete each flagged — and comment-clean — duplicated tail. Re-runs the SAME walk as
	 * `run` (checks parse independently in `run` and `fix`) and keeps the candidates whose
	 * reported span is among `violations`. `dropContainedEdits` keeps the batch
	 * non-overlapping when one flagged branch sits inside another's removed region.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [
			for (c in scan(tree, source, seams)) if (c.fixable && flagged.contains('${c.tailSpan.from}:${c.tailSpan.to}'))
				{ span: c.removeSpan, text: '' }
		];
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Every duplicated-tail candidate in `tree`, in document order — the one walk `run` and `fix` share. */
	private static function scan(tree: QueryNode, source: String, seams: Seams): Array<Candidate> {
		final out: Array<Candidate> = [];
		visit(tree, EMPTY_FALL, source, seams, out);
		return out;
	}

	/**
	 * Walk `node` carrying the run that executes after it completes. Blocks and `if`s
	 * propagate that run (`visitBlock` / `visitIf`); every other node resets it to
	 * `EMPTY_FALL` for its children — the structural reason loop bodies, `switch` cases,
	 * `try` / `catch` bodies and nested functions are out of scope. A macro-reification
	 * subtree (`RefShape.opaqueKinds`) is not descended into at all: its statements may be
	 * spliced into a scope this walk never sees, so the run it appears to complete into is
	 * not the run it will complete into.
	 */
	private static function visit(node: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (seams.blockKinds.contains(node.kind))
			visitBlock(node, fall, source, seams, out);
		else if (seams.ifKinds.contains(node.kind))
			visitIf(node, fall, source, seams, out);
		else
			for (c in node.children) visit(c, EMPTY_FALL, source, seams, out);
	}

	/**
	 * Walk a statement list: each statement's fall-through is what follows it in this
	 * block, the last one's is the block's own inherited fall — widened by the names this
	 * block binds, which now stand between that fall's scope and anything nested deeper.
	 */
	private static function visitBlock(block: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		final kids: Array<QueryNode> = block.children;
		final inherited: Fall = {
			stmts: fall.stmts,
			prevEnd: fall.prevEnd,
			shadow: fall.shadow.concat(localDeclNames(kids, seams)),
			opaqueDecl: fall.opaqueDecl || hasOpaqueDecl(kids, source, seams)
		};
		for (i in 0...kids.length) visit(kids[i], restFall(kids, i, inherited), source, seams, out);
	}

	/**
	 * The fall-through for `kids[i]`: the block's remaining statements when any follow
	 * (nothing is bound between them and `kids[i]`, so neither shadowing nor an
	 * unenumerable declaration accrues), `inherited` for the last statement, and no fall at
	 * all when the preceding statement carries no span — a deletion has nothing to anchor
	 * to there.
	 */
	private static function restFall(kids: Array<QueryNode>, i: Int, inherited: Fall): Fall {
		if (i + 1 >= kids.length) return inherited;
		final prev: Null<Span> = kids[i].span;
		return prev == null ? EMPTY_FALL : {
			stmts: kids.slice(i + 1),
			prevEnd: prev.to,
			shadow: [],
			opaqueDecl: false
		};
	}

	/**
	 * Walk an `if`: the condition sees no fall (it may hold lambdas), each braced branch is
	 * a flag candidate, and an `else if` inherits the same fall — every arm of the chain
	 * completes into the same place.
	 */
	private static function visitIf(ifNode: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		final kids: Array<QueryNode> = ifNode.children;
		if (kids.length < IF_CHILD_COUNT) return;
		visit(kids[0], EMPTY_FALL, source, seams, out);
		branch(kids[1], fall, source, seams, out);
		if (kids.length < IF_WITH_ELSE_CHILD_COUNT) return;
		final elseNode: QueryNode = kids[2];
		if (seams.ifKinds.contains(elseNode.kind))
			visit(elseNode, fall, source, seams, out);
		else
			branch(elseNode, fall, source, seams, out);
	}

	/**
	 * One branch of an `if`. A braced branch is tested for a duplicated tail before being
	 * walked; a brace-less one is only walked (a bare `if` there forwards `fall` correctly,
	 * a bare statement has no trailing run to drop).
	 */
	private static function branch(node: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		if (seams.blockKinds.contains(node.kind)) {
			final candidate: Null<Candidate> = tryFlag(node, fall, source, seams);
			if (candidate != null) out.push(candidate);
		}
		visit(node, fall, source, seams, out);
	}

	/**
	 * The candidate for `branchBlock` against its fall-through run, or null when any gate
	 * refuses (see the class doc). A null span anywhere refuses too — every offset the
	 * report and the edit need must be known.
	 */
	private static function tryFlag(branchBlock: QueryNode, fall: Fall, source: String, seams: Seams): Null<Candidate> {
		final fallStmts: Array<QueryNode> = fall.stmts;
		if (fallStmts.length == 0) return null;
		final fallLastStmt: QueryNode = fallStmts[fallStmts.length - 1];
		if (!seams.terminalKinds.contains(fallLastStmt.kind)) return null;

		final stmts: Array<QueryNode> = branchBlock.children;
		final count: Int = commonSuffix(stmts, fallStmts, source);
		if (count < 1 || count != fallStmts.length || stmts.length - count < 1) return null;

		final tail: Array<QueryNode> = stmts.slice(stmts.length - count);
		final kept: Array<QueryNode> = stmts.slice(0, stmts.length - count);
		final prevSpan: Null<Span> = kept[kept.length - 1].span;
		final tailFirst: Null<Span> = tail[0].span;
		final tailLast: Null<Span> = tail[tail.length - 1].span;
		final fallLast: Null<Span> = fallLastStmt.span;
		final blockSpan: Null<Span> = branchBlock.span;
		return if (prevSpan == null || tailFirst == null || tailLast == null || fallLast == null || blockSpan == null)
			null
		else if (hasConditionalCompilation(source, prevSpan.to, tailLast.to))
			null
		else if (hasConditionalCompilation(source, fall.prevEnd, fallLast.to))
			null
		else if (fall.opaqueDecl || hasOpaqueDecl(kept, source, seams))
			null
		else if (referencesAny(tail, fall.shadow.concat(localDeclNames(kept, seams)), seams.identKinds))
			null
		else
			{
				tailSpan: new Span(tailFirst.from, tailLast.to),
				removeSpan: new Span(prevSpan.to, tailLast.to),
				count: count,
				fixable: commentsAllowFix(source, tail, fallStmts, prevSpan.to, fall.prevEnd, blockSpan.to)
			};
	}

	/** The reported wording; `count` is at least 1. */
	private static inline function message(count: Int): String {
		return count == 1
			? 'this statement repeats the tail that follows the if — drop it and fall through'
			: 'these $count statements repeat the tail that follows the if — drop them and fall through';
	}

	/** Length of the longest common suffix of `stmts` and `fallStmts` under `sameStatement`. */
	private static function commonSuffix(stmts: Array<QueryNode>, fallStmts: Array<QueryNode>, source: String): Int {
		var k: Int = 0;
		while (
			k < stmts.length && k < fallStmts.length
			&& sameStatement(stmts[stmts.length - 1 - k], fallStmts[fallStmts.length - 1 - k], source)
		)
			k++;
		return k;
	}

	/**
	 * Whether `a` and `b` are the SAME statement, token for token. Both halves are needed:
	 * `structurallyEqual` compares the projected tree, which is blind to a comment inside a
	 * statement's span, while the normalized-source comparison collapses whitespace INSIDE
	 * string literals and would equate `f("a  b")` with `f("a b")`. Requiring both leaves
	 * exactly token identity, so anything the pair cannot prove identical is refused.
	 */
	private static function sameStatement(a: QueryNode, b: QueryNode, source: String): Bool {
		if (!RefactorSupport.structurallyEqual(a, b)) return false;
		final sa: Null<Span> = a.span;
		final sb: Null<Span> = b.span;
		if (sa == null || sb == null) return false;
		final na: NormalizedSpan = CheckScan.normalizeSpan(source, sa.from, sa.to);
		final nb: NormalizedSpan = CheckScan.normalizeSpan(source, sb.from, sb.to);
		return na.norm == nb.norm;
	}

	/**
	 * The names `stmts` bind directly — what a tail nested under them could be reading
	 * instead of the outer binding of the same spelling. A statement declares when
	 * `RefactorSupport.topLevelDeclaredNode` reaches a declaration through its metadata
	 * wrappers (`@:meta var t = …` is an expression statement around a `VarExpr`, not a
	 * `VarStmt`), which covers local variables in both statement and expression form; local
	 * FUNCTIONS, plain and `inline`, bind a shadowing name the same way and are matched by
	 * kind.
	 */
	private static function localDeclNames(stmts: Array<QueryNode>, seams: Seams): Array<String> {
		final names: Array<String> = [];
		for (c in stmts) {
			var decl: Null<QueryNode> = declaredNode(c, seams);
			// Walk the CONTINUATION chain: `var a = 1, b = 2;` binds `b` as well, on a node nested
			// right-recursively inside the head declaration. Reading the head's name alone left the
			// shadowing gate blind to every binding after the first.
			while (decl != null) {
				final node: QueryNode = decl;
				final nm: Null<String> = node.name;
				if (nm != null) names.push(nm);
				decl = node.children.find(k -> seams.localDeclContinuationKinds.contains(k.kind));
			}
		}
		return names;
	}

	/**
	 * The declaration `stmt` is, unwrapped from any metadata: a local variable (statement or
	 * expression form) via `RefactorSupport.topLevelDeclaredNode`, or a local function
	 * (`localFunctionKinds` / `inlineFunctionKinds`) by kind. Null when `stmt` binds nothing.
	 */
	private static function declaredNode(stmt: QueryNode, seams: Seams): Null<QueryNode> {
		return seams.fnDeclKinds.contains(stmt.kind)
			? stmt
			: RefactorSupport.topLevelDeclaredNode(stmt, seams.localDeclKinds, seams.localDeclExprKinds, seams.metaKinds);
	}

	/**
	 * Whether `stmts` holds a variable declaration whose bound names `localDeclNames` cannot fully enumerate. Such a statement makes the shadowing gate blind, so its mere presence refuses the candidate.
	 *
	 * A MULTI-DECLARATOR (`var a = 1, t = 2;`) is no longer one of them: every binding after the first surfaces as its own continuation node (`RefShape.localDeclContinuationKinds`) and `localDeclNames` walks the chain, so the precise shadowing gate decides it. The arms below stay as the fail-closed net for a declaration whose span or head initializer the projection does not resolve — and the comma scan still catches a form no continuation node covers.
	 *
	 * The projection children are the INITIALIZERS, one per initialized declarator (a type annotation is NOT a child). The remaining shapes declare without initializing and are found as a declarator-separating comma in the text outside the initializers — at bracket depth 0, so a generic type parameter list (`var m:Map<String, Int> = …`) does not count. That text holds no expression, which is what makes counting `<` / `>` as brackets safe there.
	 */
	private static function hasOpaqueDecl(stmts: Array<QueryNode>, source: String, seams: Seams): Bool {
		for (c in stmts) {
			final decl: Null<QueryNode> = declaredNode(c, seams);
			if (decl == null || seams.fnDeclKinds.contains(decl.kind)) continue;
			if (decl.children.length > 1) return true;
			final span: Null<Span> = decl.span;
			if (span == null) return true;
			final first: Null<Span> = decl.children.length == 1 ? decl.children[0].span : null;
			if (decl.children.length == 1 && first == null) return true;
			final headTo: Int = first == null ? span.to : first.from;
			if (hasTopLevelComma(source, span.from, headTo)) return true;
			if (first != null && hasTopLevelComma(source, first.to, span.to)) return true;
		}
		return false;
	}

	/**
	 * Whether `[from, to)` holds a `,` outside every bracket pair and string literal.
	 * `(` `[` `{` `<` open and `)` `]` `}` `>` close, the depth clamped at zero so a stray
	 * closer (the `>` of an `Int -> Int` function type) cannot push a later comma below the
	 * top level and hide it.
	 */
	private static function hasTopLevelComma(source: String, from: Int, to: Int): Bool {
		var depth: Int = 0;
		var i: Int = from;
		while (i < to) {
			final c: Int = source.fastCodeAt(i);
			if (c == '"'.code || c == "'".code)
				i = stringLiteralEnd(source, i, to)
			else {
				if (c == ','.code && depth == 0) return true;
				if (c == '('.code || c == '['.code || c == '{'.code || c == '<'.code)
					depth++
				else if ((c == ')'.code || c == ']'.code || c == '}'.code || c == '>'.code) && depth > 0)
					depth--;
				i++;
			}
		}
		return false;
	}

	/** The offset just past the string literal opening at `start`, or `to` when it is unterminated. */
	private static function stringLiteralEnd(source: String, start: Int, to: Int): Int {
		final quote: Int = source.fastCodeAt(start);
		var i: Int = start + 1;
		while (i < to) {
			final c: Int = source.fastCodeAt(i);
			if (c == '\\'.code)
				i += 2
			else if (c == quote)
				return i + 1
			else
				i++;
		}
		return to;
	}

	/** Whether any of `names` is read as an identifier anywhere in the `tail` subtrees. */
	private static function referencesAny(tail: Array<QueryNode>, names: Array<String>, identKinds: Array<String>): Bool {
		if (names.length == 0) return false;
		for (s in tail) if (mentionsName(s, names, identKinds)) return true;
		return false;
	}

	/** Whether `node`'s subtree holds an identifier (or string-interpolation identifier) named in `names`. */
	private static function mentionsName(node: QueryNode, names: Array<String>, identKinds: Array<String>): Bool {
		final nm: Null<String> = node.name;
		if (nm != null && identKinds.contains(node.kind) && names.contains(nm)) return true;
		for (c in node.children) if (mentionsName(c, names, identKinds)) return true;
		return false;
	}

	/**
	 * Whether `[from, to)` holds a conditional-compilation directive. A plain text scan, so
	 * a directive spelled inside a string literal refuses too — the safe direction, and the
	 * same string-blind conservatism as `CheckScan.hasCommentMarker`.
	 */
	private static function hasConditionalCompilation(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final s: String = source.substring(from, to);
		for (d in CONDITIONAL_DIRECTIVES) if (s.indexOf(d) != -1) return true;
		return false;
	}

	/**
	 * Whether the comments let the deletion proceed: every comment in the removed region
	 * must also stand before the kept run (a duplicated explanation goes with its
	 * duplicated code; a unique one would be LOST), and nothing may comment the space
	 * between the last removed statement and the branch's closing brace (a trailing `// …`
	 * there would be stranded on an empty line).
	 */
	private static function commentsAllowFix(
		source: String, tail: Array<QueryNode>, fallStmts: Array<QueryNode>, tailPrevEnd: Int, fallPrevEnd: Int, blockEnd: Int
	): Bool {
		final removedComments: Array<String> = runComments(source, tail, tailPrevEnd);
		final fallComments: Array<String> = runComments(source, fallStmts, fallPrevEnd);
		for (c in removedComments) if (!fallComments.contains(c)) return false;
		final lastTail: Null<Span> = tail[tail.length - 1].span;
		return lastTail != null && !CheckScan.hasCommentMarker(source, lastTail.to, blockEnd);
	}

	/**
	 * The comments in the trivia gaps of a statement run: before its first statement (from
	 * `prevEnd`) and between consecutive ones. Every scanned range is pure trivia, so there
	 * is no string-literal to mistake a marker for.
	 */
	private static function runComments(source: String, stmts: Array<QueryNode>, prevEnd: Int): Array<String> {
		final out: Array<String> = [];
		var from: Int = prevEnd;
		for (s in stmts) {
			final span: Null<Span> = s.span;
			if (span == null) return out;
			collectComments(source, from, span.from, out);
			from = span.to;
		}
		return out;
	}

	/** Append every line comment (`//` to end of line) and block comment in `[from, to)` to `out`, trimmed. */
	private static function collectComments(source: String, from: Int, to: Int, out: Array<String>): Void {
		var i: Int = from;
		while (i < to - 1) switch source.substr(i, 2) {
			case '//':
				var end: Int = i + 2;
				while (end < to && source.fastCodeAt(end) != '\n'.code) end++;
				out.push(source.substring(i, end).trim());
				i = end;
			case '/*':
				final close: Int = source.indexOf('*/', i + 2);
				final end: Int = close == -1 || close + 2 > to ? to : close + 2;
				out.push(source.substring(i, end).trim());
				i = end;
			case _:
				i++;
		}
	}

	/**
	 * Resolve the `if` / block / terminal / identifier / declaration seams, or null when a
	 * required one is unset. The terminal set is built from `valueReturnKinds`, `throwKinds`
	 * and `voidReturnKind` rather than `controlExitKinds` precisely to LEAVE OUT `break` /
	 * `continue` (see the class doc). `localDeclKinds` is REQUIRED even though the rule
	 * never reports on a declaration: it is what the shadowing gate proves absence against,
	 * so an unset seam would silently turn that gate — and the deletion's soundness — off.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final localDeclContinuationKinds: Array<String> = shape.localDeclContinuationKinds ?? [];
		if (ifKinds.length == 0 || localDeclKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final terminalKinds: Array<String> = (shape.valueReturnKinds ?? []).concat(shape.throwKinds ?? []);
		final voidReturnKind: Null<String> = shape.voidReturnKind;
		if (voidReturnKind != null) terminalKinds.push(voidReturnKind);
		if (terminalKinds.length == 0) return null;
		final identKinds: Array<String> = [shape.identKind];
		final interpIdentKind: Null<String> = shape.stringInterpIdentKind;
		if (interpIdentKind != null) identKinds.push(interpIdentKind);
		return {
			ifKinds: ifKinds,
			blockKinds: support.blockKinds(),
			opaqueKinds: shape.opaqueKinds ?? [],
			terminalKinds: terminalKinds,
			identKinds: identKinds,
			localDeclKinds: localDeclKinds,
			localDeclContinuationKinds: localDeclContinuationKinds,
			localDeclExprKinds: shape.localDeclExprKinds ?? [],
			fnDeclKinds: (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []),
			metaKinds: plugin.metaShape().metaKinds
		};
	}

}

/**
 * The run of statements that executes after the construct being visited completes:
 * `stmts` themselves, `prevEnd` the offset just past the statement preceding them (0 when
 * `stmts` is empty), `shadow` the local names bound BETWEEN that run's scope and the
 * current position (the names a duplicated tail must not reference), and `opaqueDecl`
 * whether some declaration on the way binds names `shadow` could not enumerate, which
 * refuses every candidate below it.
 */
private typedef Fall = {
	final stmts: Array<QueryNode>;
	final prevEnd: Int;
	final shadow: Array<String>;
	final opaqueDecl: Bool;
};

/**
 * One duplicated tail: `tailSpan` is what the finding reports (the duplicated statements),
 * `removeSpan` what the fix deletes (the same run plus the trivia before it), `count` how
 * many statements it holds, and `fixable` whether the comment gates let the fix run.
 */
private typedef Candidate = {
	final tailSpan: Span;
	final removeSpan: Span;
	final count: Int;
	final fixable: Bool;
};

/**
 * The grammar seams `TailMerge` resolves once per `run` / `fix`. The declaration trio feeds
 * the shadowing gate: `localDeclKinds` / `localDeclExprKinds` are the local VARIABLE forms
 * `RefactorSupport.topLevelDeclaredNode` unwraps `metaKinds` down to — and the only ones
 * whose projection can under-report a multi-declarator's names (`hasOpaqueDecl`) —
 * while `fnDeclKinds` are the local FUNCTION declarations, plain and `inline`, which bind a
 * shadowing name too but never come in multiples.
 */
private typedef Seams = {
	final ifKinds: Array<String>;
	final blockKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final terminalKinds: Array<String>;
	final identKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final localDeclContinuationKinds: Array<String>;
	final localDeclExprKinds: Array<String>;
	final fnDeclKinds: Array<String>;
	final metaKinds: Array<String>;
};
