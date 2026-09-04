package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ElementSpan;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a stray empty statement — a lone `;` with no expression (SonarLint
 * S1116), usually an editing leftover or a misplaced terminator. Three positions:
 * a statement-scope `;` (inside a body, e.g. the trailing `;` of `g();;`), a
 * member-scope `;` (after a class member, e.g. `function f():Void {};`), and the
 * one the parser ABSORBS into a block-terminated statement (`for (…) { … };`),
 * which no node marks — see `absorbedSemicolon`. Purely structural. `Warning`;
 * `fix` deletes the `;` — the whole physical line when the `;` sits alone on it
 * (so no blank residue is left), otherwise only the `;` itself.
 *
 * ## Grammar-agnostic
 *
 * The node kinds come from `RefShape.emptyStmtKind` (statement scope) and
 * `RefShape.emptyMemberKind` (member scope); the absorbed position needs
 * `RefShape.blockStmtKind` / `catchClauseKind`. With none of them set the check is
 * a no-op.
 */
@:nullSafety(Strict)
final class EmptyStatement implements Check {

	public function new() {}

	public function id(): String {
		return 'empty-statement';
	}

	public function description(): String {
		return 'a stray empty statement (a lone ;)';
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
		if (emptyKinds.length == 0 && blockKinds.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, emptyKinds, blockKinds);
		}
		return violations;
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

	/** Walk `node`, flagging every empty statement reached. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, emptyKinds: Array<String>, blockKinds: Array<String>
	): Void {
		if (emptyKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'empty-statement',
				severity: Severity.Warning,
				message: 'empty statement'
			});
		}
		final absorbed: Null<Span> = absorbedSemicolon(source, node, blockKinds);
		if (absorbed != null) out.push({
			file: file,
			span: absorbed,
			rule: 'empty-statement',
			severity: Severity.Warning,
			message: 'stray ; after a block that already terminates the statement'
		});
		for (c in node.children) walk(out, file, source, c, emptyKinds, blockKinds);
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
	 * The span of a `;` the parser ABSORBED into `node` rather than projecting as an
	 * empty-statement node, or null when there is none. A block-terminated statement
	 * (`for (…) { … };`, `if (…) { … } else { … };`, `try … catch (…) { … };`) needs no
	 * terminator, so the `;` is stray - but it lands INSIDE the statement's own span,
	 * past its last child, where no node marks it. Requiring that last child to be a
	 * BLOCK (`blockStmtKind` / `catchClauseKind`) is what separates this from every
	 * `;` that is mandatory: a value-position block is a different kind
	 * (`BlockExpr` / `IfExpr` / `TryExpr` / `FnExpr` / `ObjectLit`), and
	 * `do { … } while (c);` / `if (c) g();` end in a condition or an inner statement.
	 */
	private static function absorbedSemicolon(source: String, node: QueryNode, blockKinds: Array<String>): Null<Span> {
		final span: Null<Span> = node.span;
		if (span == null || blockKinds.length == 0) return null;
		var lastSpan: Null<Span> = null;
		var lastKind: String = '';
		for (child in node.children) if (child.span != null) {
			lastSpan = child.span;
			lastKind = child.kind;
		}
		if (lastSpan == null || !blockKinds.contains(lastKind)) return null;
		final childEnd: Int = lastSpan.to;
		if (childEnd >= span.to) return null;
		final tail: String = source.substring(childEnd, span.to);
		if (tail.trim() != ';') return null;
		final at: Int = childEnd + tail.indexOf(';');
		// A `}` must be what already terminated the statement. A CatchClause with a
		// SINGLE-STATEMENT body (`catch (e) log(x);`) also ends before the `;`, but there
		// the terminator is mandatory - the char before it is `)`, not `}`.
		var before: Int = at - 1;
		while (before >= 0 && source.isSpace(before)) before--;
		return before >= 0 && source.charAt(before) == '}' ? new Span(at, at + 1) : null;
	}

}
