package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a field / method access (`a.b` / `a.m()`) whose receiver is provably
 * **null** by flow on every path reaching it — a guaranteed null dereference
 * that throws at runtime. The headline bug-finder of the definite-null arc: the
 * first check that reports an actual defect rather than a redundancy.
 *
 * One node kind (`fieldAccessKind`) covers both forms: `x.field` is a
 * `FieldAccess` on `x`, and `x.method()` is a `Call` whose callee is the same
 * `FieldAccess` on `x`. The null-safe `x?.b` is a distinct kind that
 * short-circuits and is never flagged.
 *
 * Null-ness comes purely from `NullFlow`'s flow events — an earlier `x = null` /
 * `var x = null`, or the `== null` arm of a guard narrowing this path — and only
 * a function unit's own names (parameters / locals) are narrowed, so a static
 * access (`SomeClass.staticFn()`), `this`, or an enum is never reported.
 * Conservative throughout (see `NullFlow`): every uncertainty collapses to
 * `Unknown`, so only a genuine guaranteed dereference is reported.
 *
 * `Severity.Warning` — a real bug, not a style issue. Report-only: a null
 * dereference has no mechanical fix (the surrounding logic is wrong).
 */
@:nullSafety(Strict)
final class NullDereference implements Check {

	public function new() {}

	public function id(): String {
		return 'null-dereference';
	}

	public function description(): String {
		return 'a field / method access whose receiver is provably null on every path reaching it — a guaranteed null dereference';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (fieldAccessKind == null || identKind == null) return [];
		final faKind: String = fieldAccessKind;
		final ident: String = identKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			NullFlow.analyze(tree, shape, (node, facts) -> {
				if (node.kind != faKind || node.children.length != 1) return;
				final receiver: QueryNode = node.children[0];
				final span: Null<Span> = node.span;
				if (receiver.kind != ident || span == null) return;
				final name: Null<String> = receiver.name;
				if (name == null) return;
				if (facts.isNull(name))
					violations.push({
						file: entry.file,
						span: span,
						rule: 'null-dereference',
						severity: Severity.Warning,
						message: 'null dereference — receiver is null on every path reaching it; this access throws at runtime'
					});
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}
