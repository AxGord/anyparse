package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CondDirectives;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a local declaration that binds several variables in one statement and rebuilds it as
 * one declaration per statement:
 *
 * ```haxe
 * var uid:StringBuf = new StringBuf(), a:Int = 8;
 * // ->
 * var uid:StringBuf = new StringBuf();
 * var a:Int = 8;
 * ```
 *
 * `Info` -- the code is correct, this is a readability split. It is also SEMANTICS-NEUTRAL:
 * the declarators of one statement already evaluate left to right, and a later declarator may
 * read an earlier one (`var a = 1, b = a + 1;`) -- both still hold once each binding is its own
 * statement, because the split preserves the order and every earlier name is in scope by the
 * time the next statement runs.
 *
 * ## Composition
 *
 * This rule does ONE job -- splitting. Two checks that skip a multi-declarator wholesale become
 * reachable on its output, and `lint --fix` loops to a fixed point, so a single invocation gets
 * all the way there:
 *
 * - `prefer-final` only ever considers a single-var-with-initializer declaration (see its
 *   `## Single-var-with-initializer only` section), so `uid` above is invisible to it until the
 *   split; afterwards it upgrades the never-reassigned binding and leaves the reassigned one
 *   alone -- `final uid:StringBuf = new StringBuf(); var a:Int = 8;`.
 * - `unused-local` reports every binding of a multi-declarator but REFUSES to cut one: its
 *   autofix deletes the whole LINE, which would take the live siblings with it (commit
 *   `3760a8de`). That refusal stops applying once each binding is its own statement.
 *
 * ## What is flagged
 *
 * A DIRECT child of a statement list (`ControlFlowSupport.blockKinds`, which includes the
 * branch-aware `CondBranch` -- the tree is read through `CheckScan.parseBranchAwareOrNull`, so
 * a declaration inside a `#if` region is visited) that:
 *
 * - is a local declaration (`localDeclKinds`) and is not itself a continuation node. A
 *   continuation IS a `localDeclKind`, and in the Haxe grammar it is only ever reached as a
 *   CHILD of its head -- the exclusion is grammar-agnostic insurance for a grammar that lists a
 *   flat continuation as a statement, not a live case here;
 * - carries a continuation child (`RefactorSupport.isMultiDeclarator`). The AST is the only
 *   authority here: a comma inside a generic type (`var m:Map<Int, String> = null;`) is not a
 *   declarator separator, and a text scan for a top-level comma got that wrong.
 *
 * The continuation chain is RIGHT-RECURSIVE -- in `var a = 1, b = 2, c = 3;` the node for `c`
 * is a CHILD of the node for `b`, not a sibling -- so the rebuild walks the nesting to the end
 * and reconstructs EVERY declarator. Reading only the first continuation is the data-loss bug
 * class this projection has already produced once.
 *
 * ## Autofix
 *
 * `fix` replaces the whole statement (the reported span) with the declarators as separate
 * statements: the head verbatim from `[stmt.from, <first continuation>.from)`, then, for each
 * continuation, the declaration keyword plus that continuation's own slice (its span starts at
 * the leading `,` and ends before the statement's `;`). Every piece is copied from the source,
 * so `:type` annotations, initializers and bare declarators survive as written; the writer
 * normalises the emitted indentation on re-emit.
 *
 * A candidate is refused when a comment or a conditional-compilation directive OVERLAPS the
 * statement. Nothing is ever DROPPED by the rebuild -- the slices cover every byte of the
 * statement but the separating commas and the `;` -- so an interior comment would survive, but a
 * DANGLING LINE comment breaks the result: in
 *
 * ```haxe
 * var a = 1 // note
 *     , b = 2;
 * ```
 *
 * the head slice trims to `var a = 1 // note` and the appended `;` lands INSIDE the comment,
 * leaving the first declaration unterminated. Measured with the veto removed: the writer's
 * comment-loss detector catches it, but the price is `lint --fix` refusing EVERY fix in that
 * file with `this file cannot be rewritten without losing the comment`. That one shape is what
 * the comment veto is load-bearing for; it stays blunt (any overlap) rather than narrowed to the
 * dangling case, because the narrow test is the subtle one and the miss costs only a finding
 * (`join-declaration-assignment` takes the same stance). The `#if` veto is
 * precautionary in the same spirit: every directive shape that would genuinely break the slice
 * arithmetic is already rejected by the parser. A comment AFTER the terminating `;` is outside
 * the span, untouched by the edit, and therefore stays on the line of the LAST emitted
 * declaration. An unexpected head shape -- no trailing `;` (`{ var a = 1, b = 2 }` as a block
 * expression's value), a chain whose spans are not strictly increasing inside the statement or
 * whose leading `,` is missing, an empty declarator slice, a leading word that is not a
 * lowercase keyword followed by whitespace -- declines rather than emitting garbage.
 *
 * ## Reification is opaque
 *
 * A declaration inside a metaprogramming-reification subtree (`opaqueKinds`) is skipped, matching
 * `prefer-final` and `unused-local` -- the two checks this rule exists to unblock. Splitting
 * there would be pure churn (neither of them looks inside a reification, so no upgrade or
 * deletion ever follows) and it is not even inert: the reified `EVars([a, b])` becomes two
 * separate `EVars` nodes, which a macro that pattern-matches on the tree it builds can observe.
 *
 * ## Deliberate conservative miss
 *
 * A multi-declarator that is the BARE body of an `if` / `while` (`if (c) var a = 1, b = 2;`) or
 * a statement of a `case` branch is not a direct child of a statement list: their parent is an
 * `IfStmt` / `WhileStmt` / `CaseBranch`, none of which is a `blockKinds` node, so all three are
 * refused by construction rather than by a special case. For `if` / `while` that is the only
 * correct answer -- splitting would move the second declaration outside the branch. For a `case`
 * branch, which holds a statement RUN, a split would be safe; it is simply not reached, and
 * widening `blockKinds` is a grammar-level decision this check does not take unilaterally.
 *
 * The local-metadata form (`@:foo var a = 1, b = 2;`) IS a direct child of the statement list;
 * what refuses it is the `localDeclKinds` gate, since it projects as an expression statement
 * wrapping a `localDeclExprKinds` node rather than as a declaration statement.
 */
@:nullSafety(Strict)
final class SplitVarDeclaration implements Check {

	/** The characters a declaration keyword may be built from -- lowercase ASCII only. */
	private static inline final KEYWORD_LETTERS: String = 'abcdefghijklmnopqrstuvwxyz';

	public function new() {}

	public function id(): String {
		return 'split-var-declaration';
	}

	public function description(): String {
		return 'a local declaration binding several variables in one statement, splittable into one declaration per statement';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, entry.source);
			if (tree == null) continue;
			final matches: Array<Match> = [];
			collectMatches(tree, entry.source, blockedRegions(entry.source, seams), seams, matches);
			for (m in matches) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'split-var-declaration',
				severity: Severity.Info,
				message: 'this declaration binds ${m.count} variables; split it into one declaration per statement'
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];
		final matches: Array<Match> = [];
		collectMatches(tree, source, blockedRegions(source, seams), seams, matches);
		final byKey: Map<String, Match> = [];
		for (m in matches) byKey['${m.span.from}:${m.span.to}'] = m;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.span, text: m.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		final continuationKinds: Null<Array<String>> = shape.localDeclContinuationKinds;
		if (continuationKinds == null || continuationKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			shape: shape,
			localDeclKinds: localDeclKinds,
			continuationKinds: continuationKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			blockKinds: support.blockKinds()
		};
	}

	/**
	 * The regions no candidate may overlap: every comment token and every conditional-compilation
	 * directive. Scanned ONCE per file -- both scans walk the whole source.
	 */
	private static function blockedRegions(source: String, s: Seams): Array<Span> {
		final out: Array<Span> = [
			for (tok in RefactorSupport.collectCommentTokens(source)) new Span(tok.from, tok.to)
		];
		for (directive in CondDirectives.scan(source, s.shape)) out.push(directive.span);
		return out;
	}

	/**
	 * Collect every splittable declaration reachable under `node`. A reification subtree
	 * (`opaqueKinds`) is skipped wholesale -- its interior IS a real statement list
	 * (`MacroExpr > BlockExpr`), so the walk would otherwise descend into it.
	 */
	private static function collectMatches(node: QueryNode, source: String, blocked: Array<Span>, s: Seams, out: Array<Match>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.blockKinds.contains(node.kind)) for (stmt in node.children) if (isMultiDeclaratorHead(stmt, s)) {
			final m: Null<Match> = matchDeclaration(stmt, source, blocked, s);
			if (m != null) out.push(m);
		}
		for (c in node.children) collectMatches(c, source, blocked, s, out);
	}

	/**
	 * Whether `stmt` is a statement-position local declaration carrying a continuation. A
	 * continuation node is itself a `localDeclKind`, so it must be excluded explicitly -- it is
	 * reached as a CHILD of the head, never as a statement of the list.
	 */
	private static function isMultiDeclaratorHead(stmt: QueryNode, s: Seams): Bool {
		if (!s.localDeclKinds.contains(stmt.kind) || s.continuationKinds.contains(stmt.kind)) return false;
		return RefactorSupport.isMultiDeclarator(stmt, s.continuationKinds);
	}

	/**
	 * The split for `stmt`, or null when any gate declines (see the class doc). The emitted text
	 * is the head declarator followed by one `<keyword> <declarator>;` line per continuation.
	 */
	private static function matchDeclaration(stmt: QueryNode, source: String, blocked: Array<Span>, s: Seams): Null<Match> {
		final stmtSpan: Null<Span> = stmt.span;
		if (stmtSpan == null || stmtSpan.to <= stmtSpan.from || source.charAt(stmtSpan.to - 1) != ';') return null;
		for (region in blocked) if (region.from < stmtSpan.to && region.to > stmtSpan.from) return null;
		final chain: Null<Array<Span>> = continuationSpans(stmt, source, stmtSpan, s);
		if (chain == null) return null;
		final keyword: Null<String> = leadingKeyword(source, stmtSpan.from);
		if (keyword == null) return null;
		final declarators: Null<Array<String>> = declaratorSlices(source, stmtSpan, chain);
		if (declarators == null) return null;

		final indent: String = indentOf(source, stmtSpan.from);
		final statements: Array<String> = [
			for (i in 0...declarators.length) i == 0 ? declarators[i] : '$keyword ${declarators[i]}'
		];
		return { span: stmtSpan, count: declarators.length, text: '${statements.join(';\n$indent')};' };
	}

	/**
	 * The span of every continuation of `stmt`, in source order, walked down the RIGHT-RECURSIVE
	 * chain (each continuation holds the next as a child). Null when the chain forks, when a span
	 * is missing, when it does not start on its leading `,`, or when it is not strictly after the
	 * previous one and inside the statement's terminator -- shapes the slice arithmetic below
	 * cannot model, and which must be refused rather than approximated.
	 */
	private static function continuationSpans(stmt: QueryNode, source: String, stmtSpan: Span, s: Seams): Null<Array<Span>> {
		final out: Array<Span> = [];
		var node: QueryNode = stmt;
		var previous: Int = stmtSpan.from;
		while (true) {
			final more: Array<QueryNode> = [for (c in node.children) if (s.continuationKinds.contains(c.kind)) c];
			if (more.length == 0) break;
			if (more.length > 1) return null;
			final span: Null<Span> = more[0].span;
			if (span == null || span.from <= previous || span.to > stmtSpan.to - 1) return null;
			if (source.charAt(span.from) != ',') return null;
			out.push(span);
			previous = span.from;
			node = more[0];
		}
		return out.length == 0 ? null : out;
	}

	/**
	 * The trimmed source slice of each declarator: the head runs from the statement start to the
	 * first continuation, and continuation `i` from just past its leading `,` to the next
	 * continuation (or to the statement's `;`). Null when any slice trims to nothing.
	 */
	private static function declaratorSlices(source: String, stmtSpan: Span, chain: Array<Span>): Null<Array<String>> {
		final out: Array<String> = [StringTools.trim(source.substring(stmtSpan.from, chain[0].from))];
		for (i in 0...chain.length)
			out.push(StringTools.trim(source.substring(chain[i].from + 1, i + 1 < chain.length ? chain[i + 1].from : stmtSpan.to - 1)));
		for (slice in out) if (slice == '') return null;
		return out;
	}

	/**
	 * The declaration keyword at `from` -- the leading run of lowercase ASCII letters, accepted
	 * only when it is non-empty and immediately followed by whitespace. Grammar-agnostic by
	 * design: any other head shape declines instead of being copied onto the emitted statements.
	 */
	private static function leadingKeyword(source: String, from: Int): Null<String> {
		var i: Int = from;
		while (i < source.length && KEYWORD_LETTERS.indexOf(source.charAt(i)) != -1) i++;
		return i == from || i >= source.length || !StringTools.isSpace(source, i) ? null : source.substring(from, i);
	}

	/**
	 * The whitespace prefix of the line `from` sits on, or `''` when anything else precedes the
	 * statement on that line. The writer re-indents the whole file anyway; this only keeps the
	 * spliced text readable for the round trip that reads it.
	 */
	private static function indentOf(source: String, from: Int): String {
		final prefix: String = source.substring(source.lastIndexOf('\n', from) + 1, from);
		return StringTools.trim(prefix) == '' ? prefix : '';
	}

}

/** The kinds `SplitVarDeclaration` reads. */
private typedef Seams = {
	var shape: RefShape;
	var localDeclKinds: Array<String>;
	var continuationKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var blockKinds: Array<String>;
}

/** A splittable declaration: the statement span (finding key and replaced range), its binding count, and the rebuilt text. */
private typedef Match = {
	var span: Span;
	var count: Int;
	var text: String;
}
