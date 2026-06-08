package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Outcome of a `Rename.rename` call. `Ok` carries the format-preserving
 * rewritten source; `Err` carries a human-readable diagnostic (cursor
 * not on a renameable identifier, no-op rename, post-rewrite re-parse
 * failure). Modelled as a sum type so the CLI maps it to stdout vs.
 * stderr + a non-zero exit without a sentinel-string convention.
 */
enum RenameResult {
	Ok(text:String);
	Err(message:String);
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

	private static final FIELD_MEMBER_KINDS:Array<String> = [
		'VarMember', 'FinalMember', 'FnMember',
		'VarField', 'FinalField', 'FnField',
	];

	/**
	 * Rename the binding of the symbol at `line:col` to `newName` in
	 * `source`. `plugin` / `shape` are the caller-owned grammar plugin and
	 * its `RefShape` (the same pair the `refs` CLI builds), so the
	 * resolver stays language-agnostic. Returns `Ok(rewritten)` or an
	 * `Err` describing why the rename could not be applied. The source is
	 * never mutated — the caller decides whether to write the result.
	 */
	public static function rename(source:String, line:Int, col:Int, newName:String, plugin:GrammarPlugin, shape:RefShape):RenameResult {
		if (!isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		final tree:QueryNode = try plugin.parseFile(source)
			catch (exception:ParseError) return Err('source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here so a
		// position copied from `refs` output maps back to the real offset.
		final cursor:Int = Span.offsetOf(source, line, col + 1);

		final node:Null<QueryNode> = resolveCursorNode(tree, cursor, source);
		if (node == null)
			return Err('position $line:$col is not on a renameable identifier');
		// `resolveCursorNode` only returns nodes whose name is a renameable
		// identifier (non-null); the guard re-narrows for strict null safety.
		final targetName:Null<String> = node.name;
		if (targetName == null)
			return Err('position $line:$col is not on a renameable identifier');

		final hits:Array<RefHit> = Refs.find(targetName, tree, shape);

		final bindingFrom:Null<Int> = resolveBindingFrom(node, hits);
		if (bindingFrom == null)
			return Err('could not resolve a binding for "$targetName" at $line:$col');
		final binding:Int = bindingFrom;

		final isFieldBinding:Bool = nodeAtFromIsFieldMember(tree, binding);
		final occurrences:Array<Span> = collectOccurrences(source, targetName, hits, binding, isFieldBinding, tree);
		if (occurrences.length == 0)
			return Err('no occurrences resolved for "$targetName" at $line:$col');

		final rewritten:String = spliceRename(source, occurrences, targetName, newName);
		if (rewritten == source)
			return Err('rename "$targetName" -> "$newName" is a no-op');

		try plugin.parseFile(rewritten)
			catch (exception:ParseError) return Err('rewritten source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('rewritten source does not parse: ${exception.message}');

		return Ok(rewritten);
	}

	/**
	 * Resolve the cursor to the named occurrence node it sits on, in two
	 * tiers (innermost-wins within each):
	 *
	 *  1. A named node whose IDENTIFIER TOKEN contains the cursor — the
	 *     precise case (reads / writes whose span is the bare identifier,
	 *     params whose span starts at the name, a cursor placed directly
	 *     on a decl's name).
	 *  2. Failing that, a decl-host-shaped named node whose `span.from`
	 *     EQUALS the cursor — the `apq refs --decls` convention, where the
	 *     printed column maps to the decl's span start (the `var` / `for`
	 *     keyword), not the identifier inside it.
	 *
	 * Returns null when neither tier matches — a cursor on whitespace, a
	 * delimiter, or any non-identifier byte.
	 */
	private static function resolveCursorNode(tree:QueryNode, cursor:Int, source:String):Null<QueryNode> {
		final tokenHit:Null<QueryNode> = innermostWhere(tree, cursor, node -> identTokenContains(node, cursor, source));
		if (tokenHit != null) return tokenHit;
		return innermostWhere(tree, cursor, node -> {
			final span:Null<Span> = node.span;
			return span != null && span.from == cursor && isRenameableName(node.name);
		});
	}

	/**
	 * Innermost (deepest, last-starting) named node satisfying `pred`
	 * whose span contains `cursor`. Descends the whole tree, keeping the
	 * last match in pre-order — a tighter enclosing node is visited after
	 * its ancestors, so the final assignment is the innermost. `module` /
	 * receiver `this` nodes are excluded via `isRenameableName`.
	 */
	private static function innermostWhere(tree:QueryNode, cursor:Int, pred:QueryNode -> Bool):Null<QueryNode> {
		var best:Null<QueryNode> = null;
		function walk(node:QueryNode):Void {
			final span:Null<Span> = node.span;
			if (span != null && cursor >= span.from && cursor < span.to && isRenameableName(node.name) && pred(node)) best = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Does the identifier token of `node` (the first word-boundary
	 * occurrence of its name within its span) contain `cursor`?
	 */
	private static function identTokenContains(node:QueryNode, cursor:Int, source:String):Bool {
		final span:Null<Span> = node.span;
		final name:Null<String> = node.name;
		if (span == null || name == null) return false;
		final identFrom:Int = identTokenOffset(source, span, name);
		if (identFrom < 0) return false;
		return cursor >= identFrom && cursor < identFrom + name.length;
	}

	/**
	 * Resolve which binding the cursor node belongs to, as the `from`
	 * offset of that binding's declaration:
	 *
	 *  - The cursor node sits on a Decl hit (`span.from` matches) → the
	 *    decl binds itself.
	 *  - It sits on a Read / Write hit → follow the hit's `bindingSpan`.
	 *  - It is a `this.<field>` field access (no matching ref hit) → the
	 *    member decl of the same name.
	 *
	 * Returns null when nothing resolves (e.g. an unbound cross-file
	 * read).
	 */
	private static function resolveBindingFrom(node:QueryNode, hits:Array<RefHit>):Null<Int> {
		final span:Null<Span> = node.span;
		if (span == null) return null;
		final nodeFrom:Int = span.from;

		final hit:Null<RefHit> = hits.find(h -> h.span.from == nodeFrom);
		if (hit != null) {
			if (hit.kind == RefKind.Decl) return hit.span.from;
			final boundTo:Null<Span> = hit.bindingSpan;
			return boundTo == null ? null : boundTo.from;
		}

		// Cursor is on a node that the resolver does not emit as a ref
		// hit — the `this.<field>` field-access case. Bind it to the sole
		// member decl of the same name.
		if (node.kind == 'FieldAccess') {
			final memberDecl:Null<RefHit> = hits.find(h -> h.kind == RefKind.Decl);
			return memberDecl == null ? null : memberDecl.span.from;
		}
		return null;
	}

	/**
	 * Is the node whose span starts at `from` a class-member declaration
	 * (a field / method)? Drives whether the occurrence set is augmented
	 * with `this.<name>` field accesses.
	 */
	private static function nodeAtFromIsFieldMember(tree:QueryNode, from:Int):Bool {
		var found:Bool = false;
		function walk(node:QueryNode):Void {
			final span:Null<Span> = node.span;
			if (span != null && span.from == from && FIELD_MEMBER_KINDS.contains(node.kind)) found = true;
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
	private static function collectOccurrences(source:String, targetName:String, hits:Array<RefHit>, binding:Int, isFieldBinding:Bool, tree:QueryNode):Array<Span> {
		final out:Array<Span> = [];
		final seen:Array<Int> = [];
		inline function add(identFrom:Int):Void {
			if (identFrom >= 0 && !seen.contains(identFrom)) {
				seen.push(identFrom);
				out.push(new Span(identFrom, identFrom + targetName.length));
			}
		}

		for (h in hits) {
			final boundFrom:Null<Int> = switch h.kind {
				case RefKind.Decl: h.span.from;
				case _:
					final b:Null<Span> = h.bindingSpan;
					b == null ? null : b.from;
			};
			if (boundFrom == binding) add(identTokenOffset(source, h.span, targetName));
		}

		if (isFieldBinding) {
			for (access in collectThisFieldAccesses(targetName, tree))
				add(identTokenOffset(source, access, targetName));
		}
		return out;
	}

	/**
	 * Collect every `this.<name>` field-access node: a `FieldAccess`
	 * whose own name is `targetName` and whose first child is the
	 * `this` receiver. Returns each node's span (covering `this.<name>`);
	 * the caller resolves the identifier token within it.
	 */
	private static function collectThisFieldAccesses(targetName:String, tree:QueryNode):Array<Span> {
		final out:Array<Span> = [];
		function walk(node:QueryNode):Void {
			if (node.kind == 'FieldAccess' && node.name == targetName) {
				final span:Null<Span> = node.span;
				final recv:Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
				if (span != null && recv != null && recv.kind == 'IdentExpr' && recv.name == 'this') out.push(span);
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * Apply the rename by splicing each occurrence's identifier token with
	 * `newName`. Occurrences are sorted descending by start offset and
	 * rewritten end-to-start so earlier offsets remain valid as later
	 * ones change length.
	 */
	private static function spliceRename(source:String, occurrences:Array<Span>, oldName:String, newName:String):String {
		final sorted:Array<Span> = occurrences.copy();
		sorted.sort((a, b) -> b.from - a.from);
		var result:String = source;
		for (occ in sorted)
			result = result.substring(0, occ.from) + newName + result.substring(occ.from + oldName.length);
		return result;
	}

	/**
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)`, or -1 when not found. A word boundary
	 * requires the characters immediately before and after the match to
	 * be non-identifier characters (or the span edge), so renaming `x`
	 * inside `var x = xs[0]` matches the binding `x`, not the `x` inside
	 * `xs`.
	 */
	private static function identTokenOffset(source:String, span:Span, name:String):Int {
		final from:Int = span.from < 0 ? 0 : span.from;
		final to:Int = span.to <= source.length ? span.to : source.length;
		var i:Int = from;
		while (i + name.length <= to) {
			final at:Int = source.indexOf(name, i);
			if (at < 0 || at + name.length > to) return -1;
			final beforeOk:Bool = at == 0 || !isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterIdx:Int = at + name.length;
			final afterOk:Bool = afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx));
			if (beforeOk && afterOk) return at;
			i = at + 1;
		}
		return -1;
	}

	/** A name is renameable when it is a valid identifier and not `this`. */
	private static inline function isRenameableName(name:Null<String>):Bool {
		return name != null && name != 'this' && isIdentifier(name);
	}

	/** Whole-string check: a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`). */
	private static function isIdentifier(s:String):Bool {
		if (s.length == 0) return false;
		final first:Int = StringTools.fastCodeAt(s, 0);
		if (!isIdentStartChar(first)) return false;
		for (i in 1...s.length) if (!isIdentChar(StringTools.fastCodeAt(s, i))) return false;
		return true;
	}

	private static inline function isIdentStartChar(c:Int):Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	private static inline function isIdentChar(c:Int):Bool {
		return isIdentStartChar(c) || (c >= '0'.code && c <= '9'.code);
	}
}
