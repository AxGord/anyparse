package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.runtime.Span.Position;

using Lambda;

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
 * One occurrence a rewrite re-bound. `extra` marks an identifier the new name
 * additionally captures (it was not in the rewrite); `extra == false` marks one
 * of the rewritten occurrences a shadowing binding took over.
 */
typedef Capture = {
	var offset: Int;
	var extra: Bool;
}

/**
 * A `this.`-qualified rewrite: the source, the offsets (in the pre-qualification
 * rewrite's coordinates) a prefix was inserted at, and that prefix's length -
 * enough for the caller to predict where every occurrence ended up.
 */
typedef Qualification = {
	var source: String;
	var insertions: Array<Int>;
	var prefixLength: Int;
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
 *  5. RE-RESOLVES the rewritten tree and requires the binding's occurrence
 *     set to be unchanged - a new name another binding already holds in an
 *     overlapping scope yields code that parses and typechecks but means
 *     something else (`x = x` when a field takes its ctor param's name), so
 *     step 4 alone is not enough (see `captureDiagnostic`).
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (1-based), so a position
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
		source: String, line: Int, col: Int, newName: String, plugin: GrammarPlugin, shape: RefShape, qualifyShadowed: Bool = false
	): RenameResult {
		if (!RefactorSupport.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final occurrences: Array<Span> = renameOccurrences(source, tree, cursor, shape);
		if (occurrences.length == 0) return Err('position $line:$col is not on a renameable identifier');

		final rewritten: String = spliceRename(source, occurrences, newName);
		if (rewritten == source) return Err('rename to "$newName" is a no-op');

		final newTree: QueryNode = try plugin.parseFile(rewritten) catch (exception: ParseError) return Err(
			'rewritten source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('rewritten source does not parse: ${exception.message}');

		final mismatch: Array<Capture> = captureMismatch(rewritten, newTree, occurrences, occurrences, newName, cursor, shape);
		if (mismatch.length == 0) return Ok(rewritten);

		if (qualifyShadowed) {
			final member: Bool = isMemberBindingAt(source, tree, cursor, shape);
			final qualified: Null<Qualification> = qualifyCaptured(rewritten, newTree, mismatch, newName, shape, member);
			if (qualified != null) return verifyQualified(qualified, occurrences, newName, cursor, plugin, shape);
		}

		final first: Capture = mismatch[0];
		final what: String = first.extra ? 'is also captured by the rename' : 'is captured by a binding that shadows it';
		return Err(unsafeAt(rewritten, first.offset, newName, what));
	}

	/**
	 * The identifier-token spans of every occurrence of the binding at `cursor`
	 * in the already-parsed `tree` — the decl plus every read / write (and each
	 * `this.<name>` field access for a field binding) the scope resolver binds to
	 * it. Empty when the cursor is not on a renameable binding or nothing
	 * resolves. This is the occurrence set `rename` splices; a caller wanting the
	 * rename as edits (e.g. the `naming` autofix) maps each span to a
	 * `{span, newName}` replacement and batches them.
	 */
	public static function renameOccurrences(source: String, tree: QueryNode, cursor: Int, shape: RefShape): Array<Span> {
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return [];
		final targetName: Null<String> = node.name;
		if (targetName == null) return [];

		final hits: Array<RefHit> = Refs.find(targetName, tree, shape);
		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(node, hits);
		if (bindingFrom == null) return [];

		final isFieldBinding: Bool = nodeAtFromIsFieldMember(tree, bindingFrom);
		return collectOccurrences(source, targetName, hits, bindingFrom, isFieldBinding, tree);
	}

	/**
	 * The diagnostic for a rewrite that RE-BINDS an occurrence, or null when the
	 * rename is clean. A rename that moves a binding onto a name another binding
	 * already holds in an overlapping scope produces valid, silently WRONG code -
	 * `x = x` when a field takes its ctor param's name, or a field read that now
	 * resolves to a method local - so neither the re-parse nor a typecheck rejects
	 * it. Verified by RE-RESOLUTION rather than a textual scan: the occurrence set
	 * of the same binding, re-resolved on the rewritten tree, must be exactly the
	 * `resolved` subset of `edits` (offsets shifted by the length delta - `edits`
	 * carries every rewritten span, so the shift stays right when the caller also
	 * rewrote qualified accesses the resolver does not bind). A captured identifier
	 * ADDS an element, an occurrence lost to a shadowing binding REMOVES one; either
	 * inequality refuses. Being resolver-based, a same-named binding in a scope that
	 * never touches the renamed one is correctly allowed - the false-positive class a
	 * whole-file scan for the new name cannot avoid.
	 */
	public static function captureDiagnostic(
		rewritten: String, newTree: QueryNode, edits: Array<Span>, resolved: Array<Span>, newName: String, cursor: Int, shape: RefShape
	): Null<String> {
		final mismatch: Array<Capture> = captureMismatch(rewritten, newTree, edits, resolved, newName, cursor, shape);
		if (mismatch.length == 0) return null;
		final first: Capture = mismatch[0];
		final what: String = first.extra ? 'is also captured by the rename' : 'is captured by a binding that shadows it';
		return unsafeAt(rewritten, first.offset, newName, what);
	}

	/**
	 * The occurrences the rewrite RE-BOUND: `extra` ones the new name additionally
	 * captures, plus the ones a shadowing binding took over (`extra == false`).
	 * Empty when the rename is clean. See `captureDiagnostic` for why this is
	 * decided by re-resolution rather than by a textual scan.
	 */
	public static function captureMismatch(
		rewritten: String, newTree: QueryNode, edits: Array<Span>, resolved: Array<Span>, newName: String, cursor: Int, shape: RefShape
	): Array<Capture> {
		if (resolved.length == 0) return [];
		final sorted: Array<Span> = edits.copy();
		sorted.sort((a, b) -> a.from - b.from);
		final delta: Int = newName.length - (sorted[0].to - sorted[0].from);
		final resolvedFrom: Array<Int> = [for (occ in resolved) occ.from];
		final expected: Array<Int> = [];
		var shift: Int = 0;
		var newCursor: Int = -1;
		for (occ in sorted) {
			final from: Int = occ.from + shift;
			if (resolvedFrom.contains(occ.from)) expected.push(from);
			if (newCursor < 0 && cursor >= occ.from && cursor <= occ.to) newCursor = from;
			shift += delta;
		}
		if (newCursor < 0) newCursor = expected[0];
		final actual: Array<Int> = [for (occ in renameOccurrences(rewritten, newTree, newCursor, shape)) occ.from];
		actual.sort((a, b) -> a - b);
		if (actual.length == expected.length && actual.foreach(off -> expected.contains(off))) return [];
		final out: Array<Capture> = [for (off in actual) if (!expected.contains(off)) { offset: off, extra: true }];
		for (off in expected) if (!actual.contains(off)) out.push({ offset: off, extra: false });
		return out;
	}

	/**
	 * Does the binding the cursor resolves to belong to a TYPE (a field / method),
	 * as opposed to a local, a parameter or a loop variable? Decides whether a lost
	 * occurrence may be repaired by a `this.` qualification.
	 */
	public static function isMemberBindingAt(source: String, tree: QueryNode, cursor: Int, shape: RefShape): Bool {
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return false;
		final targetName: Null<String> = node.name;
		if (targetName == null) return false;
		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(node, Refs.find(targetName, tree, shape));
		return bindingFrom == null ? false : nodeAtFromIsFieldMember(tree, bindingFrom);
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

	/** The `captureDiagnostic` message for the occurrence at `offset`, with its 1-based position. */
	private static function unsafeAt(source: String, offset: Int, newName: String, what: String): String {
		final at: Position = new Span(offset, offset).lineCol(source);
		return 'rename to "$newName" is unsafe: the occurrence at ${at.line}:${at.col} $what'
			+ ' - qualify the member access or pick another name';
	}

	/**
	 * The source with `this.` (the grammar's `selfReferenceText`) inserted before
	 * every re-bound occurrence, or null when qualification does not apply and the
	 * rename must be refused instead. It applies ONLY to the param idiom - a
	 * capture by a PARAMETER of the enclosing function, in a non-static function -
	 * because there the param and the member are the same concept and `this.x = x`
	 * is the idiomatic form. A capture by a local or a loop variable is a naming
	 * mistake, not an idiom: qualifying it would emit correct but confusing code
	 * (`return this.t + t`), so it stays a refusal. A lost occurrence can only be
	 * qualified when the renamed binding is a member (`fieldBinding`).
	 */
	private static function qualifyCaptured(
		rewritten: String, newTree: QueryNode, mismatch: Array<Capture>, newName: String, shape: RefShape, fieldBinding: Bool
	): Null<Qualification> {
		final self: Null<String> = shape.selfReferenceText;
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		final staticKind: Null<String> = shape.staticModifierKind;
		if (self == null || paramKinds.length == 0 || fnKinds.length == 0) return null;
		final edits: Array<{ span: Span, text: String }> = [];
		for (capture in mismatch) {
			if (!capture.extra && !fieldBinding) return null;
			final fn: Null<QueryNode> = innermostOfKinds(newTree, capture.offset, fnKinds);
			if (fn == null || !declaresParam(fn, newName, paramKinds)) return null;
			final modifierKinds: Array<String> = shape.modifierOrderKinds ?? [];
			if (staticKind != null && modifierPrecedes(newTree, fn, staticKind, modifierKinds)) return null;
			edits.push({ span: new Span(capture.offset, capture.offset), text: '$self.' });
		}
		if (edits.length == 0) return null;
		final offsets: Array<Int> = [for (edit in edits) edit.span.from];
		offsets.sort((a, b) -> a - b);
		return { source: RefactorSupport.applyEdits(rewritten, edits), insertions: offsets, prefixLength: '$self.'.length };
	}

	/** The innermost node of one of `kinds` whose span contains `offset`, or null. */
	private static function innermostOfKinds(tree: QueryNode, offset: Int, kinds: Array<String>): Null<QueryNode> {
		// No pruning on a non-containing node: an ancestor's span can be narrower
		// than its subtree's (a decl whose span covers only its header), so cutting
		// the walk there would never reach the enclosing function.
		var best: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && offset >= span.from && offset < span.to && kinds.contains(node.kind)) best = node;
			for (child in node.children) walk(child);
		}
		walk(tree);
		return best;
	}

	/** Does `fn` declare a parameter named `name`? */
	private static function declaresParam(fn: QueryNode, name: String, paramKinds: Array<String>): Bool {
		for (child in fn.children) if (paramKinds.contains(child.kind) && child.name == name) return true;
		return false;
	}

	/**
	 * Does `node`'s CONTIGUOUS run of preceding modifier siblings include `kind`?
	 * Only the run counts - an earlier member's modifiers live in the same parent, so
	 * scanning every preceding sibling would attribute them to `node`.
	 */
	private static function modifierPrecedes(tree: QueryNode, node: QueryNode, kind: String, modifierKinds: Array<String>): Bool {
		var found: Bool = false;
		function walk(parent: QueryNode): Void {
			var i: Int = parent.children.indexOf(node) - 1;
			while (i >= 0 && modifierKinds.contains(parent.children[i].kind)) {
				if (parent.children[i].kind == kind) found = true;
				i--;
			}
			for (child in parent.children) walk(child);
		}
		walk(tree);
		return found;
	}

	/**
	 * The qualified rewrite, accepted only when it parses AND re-resolves clean -
	 * the qualification must have removed every capture, not merely moved it.
	 */
	private static function verifyQualified(
		qualification: Qualification, occurrences: Array<Span>, newName: String, cursor: Int, plugin: GrammarPlugin, shape: RefShape
	): RenameResult {
		final qualified: String = qualification.source;
		final tree: QueryNode = try plugin.parseFile(qualified) catch (exception: ParseError) return Err(
			'qualified rewrite does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('qualified rewrite does not parse: ${exception.message}');

		// Where each rewritten occurrence landed: the rename's own length delta, then
		// one prefix length per insertion at or before it.
		final sorted: Array<Span> = occurrences.copy();
		sorted.sort((a, b) -> a.from - b.from);
		final delta: Int = newName.length - (sorted[0].to - sorted[0].from);
		final expected: Array<Int> = [];
		var newCursor: Int = -1;
		for (i in 0...sorted.length) {
			final inRewrite: Int = sorted[i].from + delta * i;
			var at: Int = inRewrite;
			for (insertion in qualification.insertions) if (insertion <= inRewrite) at += qualification.prefixLength;
			expected.push(at);
			if (newCursor < 0 && cursor >= sorted[i].from && cursor <= sorted[i].to) newCursor = at;
		}
		if (newCursor < 0) newCursor = expected[0];

		final actual: Array<Int> = [for (occ in renameOccurrences(qualified, tree, newCursor, shape)) occ.from];
		actual.sort((a, b) -> a - b);
		return actual.length != expected.length || !actual.foreach(off -> expected.contains(off))
			? Err('rename to "$newName" is unsafe: qualifying the captured occurrences did not resolve the capture')
			: Ok(qualified);
	}

}
