package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a null-safe access (`a?.b`) whose receiver is already non-null **by flow**
 * on every path reaching it — the `?.` can never short-circuit, so a plain `.` is
 * equivalent. The flow-only counterpart of `unnecessary-safe-nav`.
 *
 * ## Flow-only — complements `unnecessary-safe-nav`, never duplicates it
 *
 * Non-null-ness comes purely from `NullFlow`: an earlier `!= null` guard narrowing
 * this path (then-arm), an `== null` guard's else-arm, or a syntactically non-null
 * assignment. It skips any receiver the declared prover
 * `TypeResolver.isProvablyNonNull` already proves non-null — those belong to
 * `unnecessary-safe-nav`. So a redundant `?.` is reported exactly once.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty collapses to
 * `Unknown`, so only a genuinely redundant `?.` is reported. `Severity.Info`;
 * `fix` rewrites `?.`→`.`, the same unambiguous rewrite `unnecessary-safe-nav` applies (sound whenever the proven flow facts hold).
 */
@:nullSafety(Strict)
final class DeadSafeNav implements Check {

	public function new() {}

	public function id(): String {
		return 'dead-safe-nav';
	}

	public function description(): String {
		return 'a null-safe access (?.) whose receiver is already non-null on every path reaching it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final safeNavKind: Null<String> = shape.nullSafeAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (safeNavKind == null || identKind == null) return [];
		final navKind: String = safeNavKind;
		final ident: String = identKind;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			NullFlow.analyze(root, shape, (node, query) -> {
				if (node.kind != navKind || node.children.length != 1) return;
				final receiver: QueryNode = node.children[0];
				final span: Null<Span> = node.span;
				if (receiver.kind != ident || span == null) return;
				final name: Null<String> = receiver.name;
				if (name == null) return;
				// Owned by `unnecessary-safe-nav` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(receiver, root, shape, declaredTypes)) return;
				if (query(name))
					violations.push({
						file: entry.file,
						span: span,
						rule: 'dead-safe-nav',
						severity: Severity.Info,
						message: 'null-safe access is redundant — receiver is already non-null on this path'
					});
			});
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final marker: String = '?.';
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final rel: Int = source.substring(span.from, span.to).indexOf(marker);
			if (rel < 0) continue;
			final at: Int = span.from + rel;
			edits.push({ span: new Span(at, at + marker.length), text: '.' });
		}
		return edits;
	}

}
