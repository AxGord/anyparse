package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an identifier assigned to itself — `x = x` (SonarLint S1656), typically a
 * typo for `this.x = x` or an edit leftover. Conservative: only a plain
 * `identifier = identifier` is flagged, never a field or array assignment
 * (`this.x = this.x` could legitimately invoke a property setter). Purely
 * structural; report-only.
 *
 * ## Grammar-agnostic
 *
 * The assignment kind comes from `RefShape.assignKind` (unset → no-op) and the
 * bare-identifier kind from `RefShape.identKind`.
 */
@:nullSafety(Strict)
final class SelfAssignment implements Check {

	public function new() {}

	public function id(): String {
		return 'self-assignment';
	}

	public function description(): String {
		return 'an identifier assigned to itself (x = x)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return [];
		final identKind: String = shape.identKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, assignKind, identKind);
		}
		return violations;
	}

	/** Self-assignment has no autofix in this slice — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging every `ident = sameIdent` assignment. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, assignKind: String, identKind: String
	): Void {
		final span: Null<Span> = node.span;
		if (
			span != null && node.kind == assignKind && node.children.length == 2 && node.children[0].kind == identKind
			&& node.children[1].kind == identKind && RefactorSupport.sameSource(node.children[0], node.children[1], source)
		) out.push({
			file: file,
			span: span,
			rule: 'self-assignment',
			severity: Severity.Warning,
			message: 'this variable is assigned to itself'
		});
		for (c in node.children) walk(out, file, source, c, assignKind, identKind);
	}

}
