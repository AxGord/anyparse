package anyparse.check.common.expressions;

import anyparse.check.Check.QuotationAware;
import anyparse.check.scan.RegionTerminator;
import anyparse.query.ElementSpan;
import anyparse.query.SymbolIndex;

using StringTools;

/**
 * Flags a stray empty statement — a lone `;` with no expression (SonarLint
 * S1116), usually an editing leftover or a misplaced terminator. Three positions:
 * a statement-scope `;` (inside a body, e.g. the trailing `;` of `g();;`), a
 * member-scope `;` (after a class member, e.g. `function f():Void {};`), and the
 * one the parser ABSORBS into a block-terminated statement (`for (…) { … };`,
 * `if (…) { … }; else`), which no node marks — see `absorbedSemicolons`. Purely
 * structural. `Warning`; `fix` deletes the `;` — the whole physical line when the
 * `;` sits alone on it (so no blank residue is left), otherwise only the `;` itself.
 * The formatter writes every such `;` back, so this rule is what removes them.
 *
 * ## Inside a `macro` quotation (`QuotationAware`)
 *
 * The rule declines the central reification drop: a stray `;` after a block or a
 * member is not represented in the AST a quotation builds (`macro class X { function
 * f() {}; }` reifies the same fields as without it, as does `if (c) { … }; else` and
 * `{ … };`), so deleting it hands the macro identical data.
 *
 * ## Grammar-agnostic
 *
 * The node kinds come from `RefShape.emptyStmtKind` (statement scope) and
 * `RefShape.emptyMemberKind` (member scope); the absorbed position needs
 * `RefShape.blockStmtKind` / `catchClauseKind`. With none of them set the check is
 * a no-op.
 */
@:nullSafety(Strict)
final class EmptyStatement extends RuleBase implements QuotationAware {

	public function new() {
		super('empty-statement', 'a stray empty statement (a lone ;)', RuleCategory.Expressions);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final stmtKind: Null<String> = shape.emptyStmtKind;
		final memberKind: Null<String> = shape.emptyMemberKind;
		final emptyKinds: Array<String> = [];
		if (stmtKind != null) emptyKinds.push(stmtKind);
		if (memberKind != null) emptyKinds.push(memberKind);
		final blockKinds: Array<String> = [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final catchClauseKind: Null<String> = shape.catchClauseKind;
		if (blockStmtKind != null) blockKinds.push(blockStmtKind);
		if (catchClauseKind != null) blockKinds.push(catchClauseKind);
		return emptyKinds.length == 0 && blockKinds.length == 0
			? []
			: RunScan.collect(
				files, plugin,
				(entry, tree, violations) -> walk(violations, entry.file, entry.source, tree, null, emptyKinds, blockKinds, shape)
			);
	}

	/** Delete each flagged empty statement. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: deletionSpan(source, span), text: '' });
		}
		return edits;
	}

	/**
	 * Walk `node` (whose previous sibling is `prev`), flagging every empty statement reached. One
	 * that closes the conditional-compilation region right before it is that region's terminator,
	 * not a stray (`RegionTerminator`).
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, prev: Null<QueryNode>, emptyKinds: Array<String>,
		blockKinds: Array<String>, shape: RefShape
	): Void {
		if (emptyKinds.contains(node.kind) && !RegionTerminator.terminatesRegion(prev, node, source, shape)) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'empty-statement',
				severity: Severity.Warning,
				message: 'empty statement'
			});
		}
		for (absorbed in absorbedSemicolons(source, node, blockKinds)) out.push({
			file: file,
			span: absorbed,
			rule: 'empty-statement',
			severity: Severity.Warning,
			message: 'stray ; after a block that already terminates the statement'
		});
		var before: Null<QueryNode> = null;
		for (c in node.children) {
			walk(out, file, source, c, before, emptyKinds, blockKinds, shape);
			before = c;
		}
	}

	/**
	 * The span to delete for the `;` at `span`. When the `;` is alone on its line
	 * (only whitespace around it), the whole physical line is removed so the
	 * batched re-emit leaves no blank line; otherwise only the `;` itself.
	 */
	private static function deletionSpan(source: String, span: Span): Span {
		var lineStart: Int = span.from;
		while (lineStart > 0 && source.fastCodeAt(lineStart - 1) != '\n'.code) lineStart--;
		var lineEnd: Int = span.to;
		while (lineEnd < source.length && source.fastCodeAt(lineEnd) != '\n'.code) lineEnd++;
		final alone: Bool = source.substring(lineStart, span.from).trim() == '' && source.substring(span.to, lineEnd).trim() == '';
		return alone ? ElementSpan.lineExtendedSpan(source, span) : span;
	}


	/**
	 * The span of every `;` the parser ABSORBED into `node` rather than projecting as an
	 * empty-statement node. A block-terminated statement (`for (…) { … };`, `if (…) { … } else { … };`,
	 * `try … catch (…) { … };`) needs no terminator, so the `;` is stray - but it lands INSIDE the
	 * statement's own span, right after a BLOCK child (`blockStmtKind` / `catchClauseKind`), where no
	 * node marks it: past the last child, or between a block and the next child (`if (…) { … }; else`).
	 * Requiring the block is what separates this from every `;` that is mandatory: a value-position
	 * block is a different kind (`BlockExpr` / `IfExpr` / `TryExpr` / `FnExpr` / `ObjectLit`), and
	 * `do { … } while (c);` / `if (c) g();` end in a condition or an inner statement.
	 */
	private static function absorbedSemicolons(source: String, node: QueryNode, blockKinds: Array<String>): Array<Span> {
		final out: Array<Span> = [];
		final span: Null<Span> = node.span;
		if (span == null || blockKinds.length == 0) return out;
		final spans: Array<Span> = [];
		final kinds: Array<String> = [];
		for (child in node.children) {
			final childSpan: Null<Span> = child.span;
			if (childSpan == null) continue;
			spans.push(childSpan);
			kinds.push(child.kind);
		}
		for (i => childSpan in spans) if (blockKinds.contains(kinds[i])) {
			final last: Bool = i == spans.length - 1;
			final at: Int = semicolonAfterBlock(source, childSpan.to, last ? span.to : spans[i + 1].from, last);
			if (at >= 0) out.push(new Span(at, at + 1));
		}
		return out;
	}

	/**
	 * The offset of a `;` that directly follows (whitespace only between) a `}` ending at `from` and
	 * lies before `limit`, or -1. Past the LAST child nothing but whitespace may follow it. A
	 * CatchClause with a SINGLE-STATEMENT body (`catch (e) log(x);`) also ends before a `;`, but there
	 * the terminator is mandatory - the char before it is `)`, not `}`.
	 */
	private static function semicolonAfterBlock(source: String, from: Int, limit: Int, last: Bool): Int {
		if (from >= limit) return -1;
		final gap: String = source.substring(from, limit);
		final trimmed: String = gap.trim();
		if (!trimmed.startsWith(';') || (last && trimmed != ';')) return -1;
		final at: Int = from + gap.indexOf(';');
		var before: Int = at - 1;
		while (before >= 0 && source.isSpace(before)) before--;
		return before >= 0 && source.charAt(before) == '}' ? at : -1;
	}

}
