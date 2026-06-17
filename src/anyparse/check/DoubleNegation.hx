package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a double logical negation `!!x` — a not-node directly wrapping another. In Haxe
 * `!` already yields `Bool`, so the pair is redundant. `Severity.Info`, report-only:
 * removing it could change behaviour if the operand drives a property getter, so the
 * cleanup is left to a human.
 *
 * ## Grammar-agnostic
 *
 * The logical-not kind comes from `RefShape.notKind` (unset → no-op). The OUTERMOST not of
 * a chain is flagged once; the check does not descend into it.
 */
@:nullSafety(Strict)
final class DoubleNegation implements Check {

	public function new() {}

	public function id(): String {
		return 'double-negation';
	}

	public function description(): String {
		return 'a redundant double logical negation (!!x)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final notKind: Null<String> = plugin.refShape().notKind;
		if (notKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, notKind);
		}
		return violations;
	}

	/** Double-negation has no autofix — `!!x` may force a property getter; removal could change behaviour. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`; flag a not directly wrapping another not, then STOP descending into it. */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, notKind: String): Void {
		if (node.kind == notKind && node.children.length == 1 && node.children[0].kind == notKind) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'double-negation',
					severity: Severity.Info,
					message: 'redundant double negation'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, c, notKind);
	}

}
