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
 * Flags a dereference whose receiver is provably **null** by flow on every path
 * reaching it — a guaranteed null dereference that throws at runtime. The
 * headline bug-finder of the definite-null arc: the first check that reports an
 * actual defect rather than a redundancy.
 *
 * Four receiver forms are covered: a field / method access (`x.b` / `x.m()` —
 * one node kind, `fieldAccessKind`, covers both, since `x.m()` is a `Call`
 * whose callee is the same `FieldAccess`), a force-unwrap access (`x!.b`,
 * `forceFieldAccessKind` — forcing a known-null is exactly the crash the sigil
 * promises away), an index access (`x[i]`, `indexAccessKind`), and a bare call
 * (`x()`, `callKind` with a plain-identifier callee). The null-safe `x?.b` is a
 * distinct kind that short-circuits and is never flagged.
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
		return
			'a dereference (field / index / force-unwrap access or call) whose receiver is provably null on every path reaching it — a guaranteed null dereference';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return [];
		final ident: String = identKind;
		// Field-shaped receivers must be the node's sole child; index/call receivers
		// are the first of several (index expression / call arguments follow).
		final soleChildKinds: Array<String> = [for (k in [shape.fieldAccessKind, shape.forceFieldAccessKind]) if (k != null) k];
		final firstChildKinds: Array<String> = [for (k in [shape.indexAccessKind, shape.callKind]) if (k != null) k];
		if (soleChildKinds.length == 0 && firstChildKinds.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			NullFlow.analyze(tree, shape, entry.source, (node, facts) -> {
				final sole: Bool = soleChildKinds.contains(node.kind) && node.children.length == 1;
				final first: Bool = firstChildKinds.contains(node.kind) && node.children.length >= 1;
				if (!sole && !first) return;
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
