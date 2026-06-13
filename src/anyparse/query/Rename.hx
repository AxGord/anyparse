package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of a `Rename.rename` call. `Ok` carries the format-preserving
 * rewritten source; `Err` carries a human-readable diagnostic (cursor
 * not on a renameable identifier, no-op rename, post-rewrite re-parse
 * failure). Modelled as a sum type so the CLI maps it to stdout vs.
 * stderr + a non-zero exit without a sentinel-string convention.
 */
enum RenameResult {

	Ok(text: String);
	Err(message: String);

}

/**
 * Scope-correct, format-preserving rename-symbol — the first real
 * refactoring operation built on the query engine.
 *
 * The design deliberately REUSES the scope-aware resolver (`Refs.find`
 * + `ScopeStack`) instead of a by-name transform hook: a transform that
 * fired on every identifier matching the target name would be
 * scope-blind and rename unrelated bindings. Given a cursor POSITION
 * identifying one binding, the rename:
 *
 *  1. Resolves the binding at `line:col` (the decl it points to, or
 *     itself when the cursor sits on the decl).
 *  2. Collects every occurrence — the decl plus every read / write —
 *     that the resolver binds to THAT binding.
 *  3. Span-rewrites the source: at each occurrence it replaces only the
 *     identifier token, splicing end-to-start so earlier offsets stay
 *     valid. Everything else is verbatim — only the renamed token bytes
 *     change.
 *  4. Re-parses the result; a rewrite that fails to parse is rejected
 *     rather than emitted.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), so a position
 * copied from `apq refs --decls` output lands on the intended binding.
 *
 * Field bindings (`this.field`): the resolver classifies a bare
 * identifier read but NOT a `FieldAccess` (`this.count`), so for a
 * class-member binding the occurrence set is augmented with every
 * `this.<name>` field access in the file. This is a structural match
 * (`this.<name>` unambiguously names the enclosing class field
 * regardless of local shadowing), not a scope walk — it does not
 * re-implement scope analysis. Cross-type `this.<name>` inside a nested
 * type that redeclares the same field name is out of scope (the
 * resolver itself does not model nested-type field scopes).
 */
@:nullSafety(Strict)
final class Rename {

	/**
	 * Rename the binding of the symbol at `line:col` to `newName` in
	 * `source`. `plugin` / `shape` are the caller-owned grammar plugin and
	 * its `RefShape` (the same pair the `refs` CLI builds), so the
	 * resolver stays language-agnostic. Returns `Ok(rewritten)` or an
	 * `Err` describing why the rename could not be applied. The source is
	 * never mutated — the caller decides whether to write the result.
	 */
	public static function rename(
		source: String, line: Int, col: Int, newName: String, plugin: GrammarPlugin, shape: RefShape
	): RenameResult {
		if (!RefactorSupport.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return Err('position $line:$col is not on a renameable identifier');
		// `resolveCursorNode` only returns nodes whose name is a renameable
		// identifier (non-null); the guard re-narrows for strict null safety.
		final targetName: Null<String> = node.name;
		if (targetName == null) return Err('position $line:$col is not on a renameable identifier');

		final hits: Array<RefHit> = Refs.find(targetName, tree, shape);

		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(node, hits);
		if (bindingFrom == null) return Err('could not resolve a binding for "$targetName" at $line:$col');
		final binding: Int = bindingFrom;

		final isFieldBinding: Bool = nodeAtFromIsFieldMember(tree, binding);
		final occurrences: Array<Span> = collectOccurrences(source, targetName, hits, binding, isFieldBinding, tree);
		if (occurrences.length == 0) return Err('no occurrences resolved for "$targetName" at $line:$col');

		final rewritten: String = spliceRename(source, occurrences, newName);
		if (rewritten == source) return Err('rename "$targetName" -> "$newName" is a no-op');

		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');

		return Ok(rewritten);
	}

	/**
	 * Is the node whose span starts at `from` a class-member declaration
	 * (a field / method)? Drives whether the occurrence set is augmented
	 * with `this.<name>` field accesses.
	 */
	private static function nodeAtFromIsFieldMember(tree: QueryNode, from: Int): Bool {
		var found: Bool = false;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && span.from == from && RefactorSupport.isFieldMemberKind(node.kind)) found = true;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/**
	 * Gather the identifier-token span of every occurrence that resolves
	 * to `binding`:
	 *
	 *  - The decl whose `span.from == binding`.
	 *  - Every read / write whose `bindingSpan.from == binding`.
	 *  - When the binding is a class field, every `this.<name>` field
	 *    access (the resolver does not classify these as reads).
	 *
	 * Each returned `Span` is the identifier token itself, not the full
	 * node span, so the splice replaces exactly the name bytes.
	 */
	private static function collectOccurrences(
		source: String, targetName: String, hits: Array<RefHit>, binding: Int, isFieldBinding: Bool, tree: QueryNode
	): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		inline function add(identFrom: Int): Void RefactorSupport.pushUniqueSpan(out, seen, identFrom, targetName.length);

		for (h in hits) {
			final boundFrom: Null<Int> = switch h.kind {
				case RefKind.Decl: h.span.from;
				case _:
					final b: Null<Span> = h.bindingSpan;
					b == null ? null : b.from;
			};
			if (boundFrom == binding) add(RefactorSupport.identTokenOffset(source, h.span, targetName));
		}

		if (isFieldBinding) {
			for (access in collectThisFieldAccesses(targetName, tree)) add(RefactorSupport.identTokenOffset(source, access, targetName));
		}
		return out;
	}

	/**
	 * Collect every `this.<name>` field-access node: a `FieldAccess`
	 * whose own name is `targetName` and whose first child is the
	 * `this` receiver. Returns each node's span (covering `this.<name>`);
	 * the caller resolves the identifier token within it.
	 */
	private static function collectThisFieldAccesses(targetName: String, tree: QueryNode): Array<Span> {
		final out: Array<Span> = [];
		function walk(node: QueryNode): Void {
			if (node.kind == 'FieldAccess' && node.name == targetName) {
				final span: Null<Span> = node.span;
				final recv: Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
				if (span != null && recv != null && recv.kind == 'IdentExpr' && recv.name == 'this') out.push(span);
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * Apply the rename by replacing each occurrence's identifier-token span
	 * with `newName`. Each occurrence span already covers exactly the name
	 * bytes; `RefactorSupport.applyEdits` sorts the edits descending and
	 * splices end-to-start so earlier offsets remain valid as later ones
	 * change length.
	 */
	private static function spliceRename(source: String, occurrences: Array<Span>, newName: String): String {
		final edits: Array<{ span: Span, text: String }> = [for (occ in occurrences) { span: occ, text: newName }];
		return RefactorSupport.applyEdits(source, edits);
	}

}
