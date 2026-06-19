package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an `if` / `else if` chain that tests one expression against literal
 * values — `if (x == 'a') … else if (x == 'b') …` — which reads more clearly as
 * a `switch`. Purely structural (no type information), so it holds without a
 * type-checker; `Info` — the code is correct, this is a readability suggestion.
 * `--fix` rewrites the chain to a `switch`.
 *
 * ## What is flagged
 *
 * The HEAD of a chain of `ifStatementKinds` whose `else` (`children[2]`) is
 * itself an `if`, where EVERY rung's condition is an equality (`eqKind`)
 * comparing the SAME discriminant against a literal. A rung qualifies when
 * exactly one operand is a constant literal — a non-string literal kind
 * (`caseLiteralKinds`) or a plain, interpolation-free string
 * (`stringFoldSupport().literalOf`, so an interpolated `'$x'` is rejected) — and
 * the other (the discriminant) is identical across all rungs
 * (`RefactorSupport.sameSource`) and call-free: a `callKind` in the discriminant
 * means a `switch` would evaluate it once where the chain evaluates it per rung,
 * a behaviour change, so it is left alone. At least two rungs are required (a
 * lone `if`, or a single `if` / `else`, is not a chain). An inner else-if rung is
 * never re-reported: the walk skips an `if` reached as another `if`'s else-slot.
 * Only a statement-position `if` (`ifStatementKinds`) is matched — a value-position
 * `if` (`var y = if (…) …`) is a different kind and is never touched.
 *
 * ## Autofix
 *
 * `--fix` rebuilds the chain as `switch (D) { case L1: B1; …; case _: E }`: the
 * discriminant `D`, each rung's literal `L` and its then-branch body `B` taken
 * verbatim, and the trailing `else` body (if any) as `case _`. A chain with no
 * trailing `else` yields a switch with no `case _` (no-match does nothing, as
 * before). The generated source is re-parsed and reformatted by the canonical
 * pipeline; a chain whose pieces resist a clean rebuild is skipped. A chain
 * carrying a comment is also skipped (report-only): comments between rungs live in
 * the trivia the verbatim-body rebuild would drop, so converting it would lose
 * them — that conversion is left to the author.
 *
 * ## Grammar-agnostic
 *
 * Drives off `RefShape`: `ifStatementKinds` (unset → no-op), `eqKind` (the `==`
 * kind — a `!=` chain does not map to `case` patterns), `caseLiteralKinds` (the
 * non-string literal kinds; unset → no-op), and the always-present `callKind`,
 * plus `GrammarPlugin.stringFoldSupport` for interpolation-free string literals.
 * No language-specific kinds are named here.
 */
@:nullSafety(Strict)
final class PreferSwitch implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-switch';
	}

	public function description(): String {
		return 'an if/else-if chain testing one expression against literals — clearer as a switch';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final eqKind: Null<String> = shape.eqKind;
		final litKinds: Array<String> = shape.caseLiteralKinds ?? [];
		if (ifKinds.length == 0 || eqKind == null || litKinds.length == 0) return [];
		final callKind: Null<String> = shape.callKind;
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, false, ifKinds, eqKind, litKinds, callKind, stringFold);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged chain head to a `switch`. Re-parses `source`, re-finds
	 * the chain heads, and emits a replace edit over a head whose span matches a
	 * passed violation; `buildSwitch` returning null (a piece without a coordinate,
	 * or a comment in the chain) skips that one.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final eqKind: Null<String> = shape.eqKind;
		final litKinds: Array<String> = shape.caseLiteralKinds ?? [];
		if (ifKinds.length == 0 || eqKind == null || litKinds.length == 0) return [];
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(edits, source, tree, false, ifKinds, eqKind, litKinds, stringFold, flagged);
		return edits;
	}

	/**
	 * Walk `node`, flagging each chain head. `inElseSlot` is true when `node` is
	 * reached as another `if`'s `else` branch (`children[2]`), so an else-if rung is
	 * not re-evaluated as its own head.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, inElseSlot: Bool, ifKinds: Array<String>, eqKind: String,
		litKinds: Array<String>, callKind: Null<String>, stringFold: Null<StringFoldSupport>
	): Void {
		if (ifKinds.contains(node.kind) && !inElseSlot) flagChain(out, file, source, node, ifKinds, eqKind, litKinds, callKind, stringFold);
		final elseSlot: Int = ifKinds.contains(node.kind) ? 2 : -1;
		for (i in 0...node.children.length)
			walk(out, file, source, node.children[i], i == elseSlot, ifKinds, eqKind, litKinds, callKind, stringFold);
	}

	/**
	 * Emit one `Info` on `head` when it heads a chain of at least two equality rungs
	 * all testing the same call-free discriminant against literals.
	 */
	private static function flagChain(
		out: Array<Violation>, file: String, source: String, head: QueryNode, ifKinds: Array<String>, eqKind: String,
		litKinds: Array<String>, callKind: Null<String>, stringFold: Null<StringFoldSupport>
	): Void {
		var discriminant: Null<QueryNode> = null;
		var rungs: Int = 0;
		var cur: QueryNode = head;
		while (ifKinds.contains(cur.kind) && cur.children.length >= 2) {
			final d: Null<QueryNode> = eqDiscriminant(cur.children[0], eqKind, litKinds, stringFold, source);
			if (d == null) return;
			if (callKind != null && RefactorSupport.subtreeContainsKind(d, callKind)) return;
			if (discriminant == null)
				discriminant = d;
			else if (!RefactorSupport.sameSource(discriminant, d, source)) return;
			rungs++;
			if (cur.children.length >= 3 && ifKinds.contains(cur.children[2].kind))
				cur = cur.children[2];
			else
				break;
		}
		final disc: Null<QueryNode> = discriminant;
		if (rungs < 2 || disc == null) return;
		final span: Null<Span> = head.span;
		final dSpan: Null<Span> = disc.span;
		if (span == null || dSpan == null) return;
		final discText: String = StringTools.trim(source.substring(dSpan.from, dSpan.to));
		out.push({
			file: file,
			span: span,
			rule: 'prefer-switch',
			severity: Severity.Info,
			message: 'if/else-if chain testing `$discText` against literals — clearer as a switch'
		});
	}

	/** Walk `node` like `walk`, emitting a switch-rewrite edit for each flagged chain head. */
	private static function fixWalk(
		edits: Array<{ span: Span, text: String }>, source: String, node: QueryNode, inElseSlot: Bool, ifKinds: Array<String>,
		eqKind: String, litKinds: Array<String>, stringFold: Null<StringFoldSupport>, flagged: Array<Int>
	): Void {
		if (ifKinds.contains(node.kind) && !inElseSlot) {
			final span: Null<Span> = node.span;
			if (span != null && flagged.contains(span.from)) {
				final sw: Null<String> = buildSwitch(source, node, ifKinds, eqKind, litKinds, stringFold);
				if (sw != null) edits.push({ span: span, text: sw });
			}
		}
		final elseSlot: Int = ifKinds.contains(node.kind) ? 2 : -1;
		for (i in 0...node.children.length)
			fixWalk(edits, source, node.children[i], i == elseSlot, ifKinds, eqKind, litKinds, stringFold, flagged);
	}

	/**
	 * Build the `switch` source for the chain at `head`, or null if any piece lacks
	 * a coordinate or the chain carries a comment (whose trivia the verbatim rebuild
	 * would drop). Each rung contributes `case <literal>: <then-body verbatim>`; the
	 * trailing `else` body (a non-`if` `children[2]`) becomes `case _`. Indented with
	 * tabs and newlines — the canonical pipeline reformats it.
	 */
	private static function buildSwitch(
		source: String, head: QueryNode, ifKinds: Array<String>, eqKind: String, litKinds: Array<String>,
		stringFold: Null<StringFoldSupport>
	): Null<String> {
		final headSpan: Null<Span> = head.span;
		if (headSpan == null || containsComment(source, headSpan.from, headSpan.to)) return null;
		var discText: Null<String> = null;
		final cases: Array<String> = [];
		var elseBody: Null<String> = null;
		var cur: QueryNode = head;
		var rungs: Int = 0;
		while (ifKinds.contains(cur.kind) && cur.children.length >= 2) {
			final cond: QueryNode = cur.children[0];
			if (cond.kind != eqKind || cond.children.length != 2) return null;
			final a: QueryNode = cond.children[0];
			final b: QueryNode = cond.children[1];
			final aLit: Bool = isConstLiteral(a, litKinds, stringFold, source);
			final bLit: Bool = isConstLiteral(b, litKinds, stringFold, source);
			if (aLit == bLit) return null;
			final lit: QueryNode = aLit ? a : b;
			final disc: QueryNode = aLit ? b : a;
			final litSpan: Null<Span> = lit.span;
			final dSpan: Null<Span> = disc.span;
			final thenSpan: Null<Span> = cur.children[1].span;
			if (litSpan == null || dSpan == null || thenSpan == null) return null;
			if (discText == null) discText = StringTools.trim(source.substring(dSpan.from, dSpan.to));
			final litText: String = StringTools.trim(source.substring(litSpan.from, litSpan.to));
			final body: String = StringTools.trim(source.substring(thenSpan.from, thenSpan.to));
			cases.push('case $litText: $body');
			rungs++;
			if (cur.children.length >= 3) {
				final elseChild: QueryNode = cur.children[2];
				if (ifKinds.contains(elseChild.kind)) {
					cur = elseChild;
					continue;
				}
				final eSpan: Null<Span> = elseChild.span;
				if (eSpan == null) return null;
				elseBody = StringTools.trim(source.substring(eSpan.from, eSpan.to));
			}
			break;
		}
		if (rungs < 2 || discText == null) return null;
		final lines: Array<String> = ['switch ($discText) {'];
		for (c in cases) lines.push('\t$c');
		if (elseBody != null) lines.push('\tcase _: $elseBody');
		lines.push('}');
		return lines.join('\n');
	}

	/**
	 * The discriminant operand of an equality condition `D == lit` (either order):
	 * the non-literal operand when exactly one operand is a constant literal, else
	 * null.
	 */
	private static function eqDiscriminant(
		cond: QueryNode, eqKind: String, litKinds: Array<String>, stringFold: Null<StringFoldSupport>, source: String
	): Null<QueryNode> {
		if (cond.kind != eqKind || cond.children.length != 2) return null;
		final a: QueryNode = cond.children[0];
		final b: QueryNode = cond.children[1];
		final aLit: Bool = isConstLiteral(a, litKinds, stringFold, source);
		final bLit: Bool = isConstLiteral(b, litKinds, stringFold, source);
		return aLit == bLit ? null : aLit ? b : a;
	}

	/**
	 * Whether `node` is a constant literal usable verbatim as a switch `case`: a
	 * plain interpolation-free string (via `stringFoldSupport`, which yields null
	 * for an interpolated `'$x'`) or one of the non-string literal kinds.
	 */
	private static function isConstLiteral(
		node: QueryNode, litKinds: Array<String>, stringFold: Null<StringFoldSupport>, source: String
	): Bool {
		if (stringFold != null && stringFold.literalOf(node, source) != null) return true; // noqa: prefer-ternary-return
		return litKinds.contains(node.kind);
	}

	/**
	 * Whether `source[from...to]` contains a `//` or block-comment opener outside a
	 * string literal — a conservative gate that keeps the comment-dropping rebuild
	 * away from any commented chain (a `//` inside a string only over-bails).
	 */
	/**
	 * Whether any comment token starts within `source[from...to]`, via the shared
	 * string-aware scanner `RefactorSupport.collectCommentTokens` — a comment inside
	 * a string literal is correctly not counted. A commented chain bails to
	 * report-only so the verbatim-body rebuild never drops a comment.
	 */
	private static function containsComment(source: String, from: Int, to: Int): Bool {
		for (token in RefactorSupport.collectCommentTokens(source)) if (token.from >= from && token.from < to) return true;
		return false;
	}

}
