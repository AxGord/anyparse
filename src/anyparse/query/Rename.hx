package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
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
		source: String, line: Int, col: Int, newName: String, plugin: GrammarPlugin, shape: RefShape, qualifyShadowed: Bool = false,
		?file: String
	): RenameResult {
		if (!RefactorSupport.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final occurrences: Array<Span> = renameOccurrences(source, tree, cursor, shape);
		if (occurrences.length == 0) return Err('position $line:$col is not on a renameable identifier');

		// Two known resolution blind spots make a silent partial rename possible;
		// refuse outright rather than corrupt semantics (see sameNameBlindSpot).
		final oldName: String = source.substring(occurrences[0].from, occurrences[0].to);
		final blindSpot: Null<String> = sameNameBlindSpot(source, tree, cursor, occurrences, oldName, plugin, shape);
		if (blindSpot != null) return Err(blindSpot);

		final rewritten: String = spliceRename(source, occurrences, newName);
		if (rewritten == source) return Err('rename to "$newName" is a no-op');

		final newTree: QueryNode = try plugin.parseFile(rewritten) catch (exception: ParseError) return Err(
			'rewritten source does not parse: $exception'
		)
		catch (exception: Exception) return Err('rewritten source does not parse: ${exception.message}');

		final mismatch: Array<Capture> = captureMismatch(rewritten, newTree, occurrences, occurrences, newName, cursor, shape);
		if (mismatch.length == 0) return Ok(rewritten);

		if (qualifyShadowed) {
			final reachable: Bool = selfReachableBindingAt(source, tree, cursor, shape);
			final qualified: Null<Qualification> = qualifyCaptured(
				rewritten, newTree, mismatch, newName, shape, reachable, RefactorSupport.resolutionIndexOf(plugin), file
			);
			if (qualified != null) return verifyQualified(qualified, occurrences, occurrences, newName, cursor, plugin, shape);
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
	 * Is the binding the cursor resolves to reachable through `selfReferenceText` - can a captured
	 * occurrence of it be repaired by writing `this.<name>`? Three conditions, all language facts
	 * the grammar publishes:
	 *
	 *  - it must be a TYPE member (a field / method), not a local, a parameter or a loop variable;
	 *  - it must be an INSTANCE member - a `static` one is not a field of `this`, and qualifying it
	 *    yields "Cannot access static field f from a class instance" (verified);
	 *  - its enclosing type must be one where `this` denotes an instance. In a Haxe `abstract` /
	 *    `enum abstract` (`RefShape.underlyingThisTypeKinds`) `this` IS the underlying value, so
	 *    `this.<member>` looks the name up on THAT type and never finds the abstract's own -
	 *    "Int has no field f" (verified).
	 *
	 * The static test is on the BINDING, not on the function containing the capture; that separate
	 * fact (there is no `this` inside a static function at all) is gated where the capture site is
	 * known, in `qualifyCaptured`.
	 */
	public static function selfReachableBindingAt(source: String, tree: QueryNode, cursor: Int, shape: RefShape): Bool {
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return false;
		final targetName: Null<String> = node.name;
		if (targetName == null) return false;
		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(node, Refs.find(targetName, tree, shape));
		if (bindingFrom == null) return false;
		final from: Int = bindingFrom;
		final decl: Null<QueryNode> = fieldMemberAtFrom(tree, from);
		if (decl == null) return false;
		final staticKind: Null<String> = shape.staticModifierKind;
		if (staticKind != null && modifierPrecedes(tree, decl, staticKind, shape.modifierOrderKinds ?? [])) return false;
		final underlyingThis: Array<String> = shape.underlyingThisTypeKinds ?? [];
		return underlyingThis.length == 0 || innermostOfKinds(tree, from, underlyingThis) == null;
	}

	/**
	 * Is the node whose span starts at `from` a class-member declaration
	 * (a field / method)? Drives whether the occurrence set is augmented
	 * with `this.<name>` field accesses.
	 */
	private static inline function nodeAtFromIsFieldMember(tree: QueryNode, from: Int): Bool {
		return fieldMemberAtFrom(tree, from) != null;
	}

	/**
	 * A same-name RESOLUTION BLIND SPOT that would turn this rename into a silent semantic
	 * change, or null when none applies. Three cases:
	 *
	 *  - a `$oldName` string-interpolation read of THIS binding that the occurrence set does not
	 *    rewrite. An ordinary one is rewritten — `Refs` indexes it and `identTokenOffset` finds
	 *    its identifier token inside the `$name` span — so only an escape-spelled `$` or name
	 *    reaches here, where the decoded text the projection reads and the raw bytes the splice
	 *    writes disagree. Decided over the resolved hits, so a read bound to a SHADOWING binding
	 *    of the same name is correctly ignored;
	 *  - an escape-spelled `${ … }` hole, which the rescan synthesizes WITHOUT a parsed
	 *    expression: a read of the name inside it is invisible to every scan, so the rename would
	 *    part-apply. Scoped to the function that OWNS the binding, since the hole's contents cannot
	 *    be attributed to a binding at all;
	 *  - `oldName` declared MORE THAN ONCE in one block (Haxe-legal re-declaration, reached
	 *    through a metadata wrapper too) — the index mis-binds the references that follow the
	 *    second declaration. Same owning-function scope: a local cannot be referenced outside it, and
	 *    a CURSOR anchor would confine the sweep to a nested local function the read sits in.
	 *
	 * All three refusals are deliberately conservative: a false positive costs a manual rename, a
	 * false negative silently changes behaviour.
	 */
	private static function sameNameBlindSpot(
		source: String, tree: QueryNode, cursor: Int, occurrences: Array<Span>, oldName: String, plugin: GrammarPlugin, shape: RefShape
	): Null<String> {
		final cursorNode: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		final hits: Array<RefHit> = cursorNode == null ? [] : Refs.find(oldName, tree, shape);
		final binding: Null<Int> = cursorNode == null ? null : RefactorSupport.resolveBindingFrom(cursorNode, hits);
		final scope: QueryNode = RefactorSupport.bindingHostSubtree(tree, cursor, binding, shape);

		if (binding != null) {
			final stray: Null<Span> = RefactorSupport.unrewrittenInterpRead(hits, binding, occurrences);
			if (stray != null) {
				final at: Position = stray.lineCol(source);
				return 'rename of "$oldName" is unsafe: the string-interpolation read at ${at.line}:${at.col} has no locatable'
					+ ' identifier token in the raw source (its dollar or its name is escape-spelled), so the splice would leave'
					+ ' it bound to the old name - respell that read first';
			}
		}
		final blockKind: Null<String> = shape.stringInterpBlockKind;
		if (blockKind != null) {
			final opaque: Null<Span> = RefactorSupport.unreadableInterpBlock(scope, blockKind);
			if (opaque != null) {
				final at: Position = opaque.lineCol(source);
				return 'rename of "$oldName" is unsafe: the escape-spelled string interpolation at ${at.line}:${at.col} carries'
					+ ' no parsed expression, so a read of the name inside it is invisible - respell that interpolation first';
			}
		}
		final dup: Null<Span> = RefactorSupport.sameBlockRedeclaration(scope, oldName, plugin, shape);
		if (dup != null) {
			final at: Position = dup.lineCol(source);
			return 'rename of "$oldName" is unsafe: the name is declared more than once in the block at ${at.line}:${at.col},'
				+ ' where reference resolution mis-binds - split the scopes or rename the other declaration first';
		}
		// A LOCAL cannot be referenced outside the function that owns it, so a splice elsewhere in
		// the file says nothing about it. A MEMBER can be read from any method, and `scope` for one
		// is only the CURSOR's function - the whole tree is the honest reach there.
		final regionScope: QueryNode = binding != null && nodeAtFromIsFieldMember(tree, binding) ? tree : scope;
		return RefactorSupport.opaqueCondRegionDiagnostic(source, regionScope, oldName, shape, 'rename of "$oldName"');
	}

	/**
	 * The class-member declaration (a field / method) whose span starts at `from`, or null when
	 * the node there is not one. Scans the whole tree rather than stopping at the first node at
	 * that offset: a member's own span can co-start with an inner node's.
	 */
	private static function fieldMemberAtFrom(tree: QueryNode, from: Int): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && span.from == from && RefactorSupport.isFieldMemberKind(node.kind)) found = node;
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
					b?.from;
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
	 * rename must be refused instead.
	 *
	 * Every capture site must sit inside a function that is not `static` (a static body has no
	 * `this` at all); beyond that the repair has TWO mirror-image arms, picked by which side of the
	 * re-binding the occurrence is on.
	 *
	 * A capture the rename LOST (`extra == false`) is the param idiom: the renamed BINDING must be
	 * reachable through `this` (`selfReachable`, see `selfReachableBindingAt`) and the capturing
	 * binding must be a PARAMETER of the enclosing function, where param and member are the same
	 * concept and `this.x = x` is the idiomatic form. A capture by a local or a loop variable is a
	 * naming mistake and qualifying it would emit correct but confusing code (`return this.t + t`).
	 *
	 * A capture the rename GAINED (`extra == true`) is the mirror: a LOCAL renamed onto a name an
	 * instance member already holds now shadows that member's bare references. There the binding
	 * side proves nothing (a local is not reachable through `this`); the CAPTURED occurrence is
	 * what must be, so `capturedMemberQualifiable` decides.
	 */
	private static function qualifyCaptured(
		rewritten: String, newTree: QueryNode, mismatch: Array<Capture>, newName: String, shape: RefShape, selfReachable: Bool,
		index: Null<SymbolIndex>, file: Null<String>
	): Null<Qualification> {
		final self: Null<String> = shape.selfReferenceText;
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		if (self == null || fnKinds.length == 0) return null;
		final edits: Array<{ span: Span, text: String }> = [];
		for (capture in mismatch) {
			final fn: Null<QueryNode> = innermostOfKinds(newTree, capture.offset, fnKinds);
			// EVERY enclosing function must be non-static, not just the innermost: a named local
			// function nested in a `static` method has no `this` either, and testing only the
			// innermost let that shape through.
			if (fn == null || withinStaticFunction(newTree, capture.offset, shape)) return null;
			final repairable: Bool = capture.extra
				? capturedMemberQualifiable(rewritten, newTree, capture.offset, newName, shape, index, file)
				: selfReachable && declaresParam(fn, newName, shape.paramKinds ?? []);
			if (!repairable) return null;
			edits.push({ span: new Span(capture.offset, capture.offset), text: '$self.' });
		}
		if (edits.length == 0) return null;
		final offsets: Array<Int> = [for (edit in edits) edit.span.from];
		offsets.sort((a, b) -> a - b);
		return { source: RefactorSupport.applyEdits(rewritten, edits), insertions: offsets, prefixLength: '$self.'.length };
	}

	/**
	 * Is the occurrence at `offset` - one the rename ADDITIONALLY captured - a bare reference that
	 * WAS bound to an instance member and that `this.<name>` still names? Four facts, resolved in the
	 * language's own order:
	 *
	 *  - the occurrence must be a bare IDENTIFIER of that name (an already-qualified access binds to
	 *    nothing the rename could have captured, and a declaration is not a reference at all);
	 *  - its enclosing type must be one where `this` denotes an instance - inside a Haxe `abstract`
	 *    (`RefShape.underlyingThisTypeKinds`) `this` IS the underlying value, so `this.<name>` looks
	 *    the name up on THAT type;
	 *  - NO other non-member binding of the name may be in scope at the occurrence. That a member of
	 *    the name EXISTS does not mean this occurrence read it: a parameter or an outer local of the
	 *    same name would have shadowed it, and `this.<name>` would then silently re-bind a
	 *    param read to the field - valid, type-correct, and a different program. The rename's own
	 *    binding is excluded, since it is the one doing the capturing;
	 *  - the name must resolve to an INSTANCE member: the enclosing type's OWN declaration decides
	 *    when it has one (a `static` one refuses - there is no `this.` spelling for it), and only
	 *    when it declares none does the project index answer for the supertype closure. An
	 *    unresolvable member - no own declaration and no index, or an index that cannot reach the
	 *    supertype through unambiguous links - refuses, since qualifying it would be a guess.
	 */
	private static function capturedMemberQualifiable(
		rewritten: String, tree: QueryNode, offset: Int, name: String, shape: RefShape, index: Null<SymbolIndex>, file: Null<String>
	): Bool {
		final ident: Null<QueryNode> = innermostOfKinds(tree, offset, [shape.identKind]);
		if (ident == null || ident.name != name) return false;
		final underlyingThis: Array<String> = shape.underlyingThisTypeKinds ?? [];
		if (underlyingThis.length > 0 && innermostOfKinds(tree, offset, underlyingThis) != null) return false;
		final capturedBy: Null<Int> = occurrenceBinding(rewritten, tree, offset, name, shape);
		if (capturedBy == null) return false;
		final renamed: Int = capturedBy;
		if (shadowingBindingAt(tree, offset, name, renamed, shape)) return false;
		final host: Null<TypeDeclMatch> = enclosingTypeDecl(tree, offset);
		if (host == null) return false;
		final own: Null<Bool> = ownInstanceMember(tree, host.nameNode, name, renamed, shape);
		return own ?? (index != null && file != null && index.inheritsInstanceMember(file, host.name, name));
	}

	/**
	 * The declaration offset the read / write of `name` at `offset` binds to in `tree`, or null when
	 * the occurrence is not a resolved reference. On the REWRITTEN tree this is the binding that did
	 * the capturing - the one `shadowingBindingAt` and `ownInstanceMember` must not count against the
	 * repair.
	 */
	private static function occurrenceBinding(source: String, tree: QueryNode, offset: Int, name: String, shape: RefShape): Null<Int> {
		for (h in Refs.find(name, tree, shape)) if (
			h.kind != RefKind.Decl && RefactorSupport.identTokenOffset(source, h.span, name) == offset
		)
			return h.bindingSpan?.from;
		return null;
	}

	/**
	 * Is a binding of `name` OTHER than the one at `renamedFrom`, and other than a type MEMBER, in
	 * scope at `offset`? A member declaration is exactly what the repair is for; a parameter, local,
	 * catch variable or loop binder is what would have SHADOWED that member at the occurrence, so its
	 * presence means the occurrence never read the member and must not be qualified. Scope is the
	 * binder's innermost enclosing `scopeKinds` frame - a same-named binding in a sibling function
	 * does not reach `offset` and is correctly ignored. Deliberately conservative: a binding declared
	 * later in the same block is counted too, since counting it costs a manual rename and missing one
	 * silently changes behaviour.
	 */
	private static function shadowingBindingAt(tree: QueryNode, offset: Int, name: String, renamedFrom: Int, shape: RefShape): Bool {
		for (h in Refs.find(name, tree, shape)) if (h.kind == RefKind.Decl) {
			final from: Int = h.span.from;
			if (from == renamedFrom || fieldMemberAtFrom(tree, from) != null) continue;
			final scope: Null<Span> = innermostSpanOfKinds(tree, shape.scopeKinds, from);
			if (scope != null && offset >= scope.from && offset < scope.to) return true;
		}
		return false;
	}

	/** The tightest enclosing node span (whose kind is in `kinds`) containing `pos`, or null when none does. */
	private static function innermostSpanOfKinds(tree: QueryNode, kinds: Array<String>, pos: Int): Null<Span> {
		return innermostOfKinds(tree, pos, kinds)?.span;
	}

	/** Does ANY function enclosing `offset` carry the `static` modifier? A body nested in a static one has no `this` either. */
	private static function withinStaticFunction(tree: QueryNode, offset: Int, shape: RefShape): Bool {
		final staticKind: Null<String> = shape.staticModifierKind;
		if (staticKind == null) return false;
		final kind: String = staticKind;
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		final modifierKinds: Array<String> = shape.modifierOrderKinds ?? [];
		var found: Bool = false;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (
				span != null && offset >= span.from && offset < span.to && fnKinds.contains(node.kind)
				&& modifierPrecedes(tree, node, kind, modifierKinds)
			)
				found = true;
			for (child in node.children) walk(child);
		}
		walk(tree);
		return found;
	}

	/**
	 * The innermost type declaration whose span contains `offset`, normalised across the plain and
	 * `final`-wrapped shapes by `RefactorSupport.typeDeclOf` (a `final class` names itself on an
	 * inner node the outer wrapper does not carry), or null when `offset` sits outside every type.
	 */
	private static function enclosingTypeDecl(tree: QueryNode, offset: Int): Null<TypeDeclMatch> {
		var best: Null<TypeDeclMatch> = null;
		function walk(node: QueryNode): Void {
			final match: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (match != null && offset >= match.fullSpan.from && offset < match.fullSpan.to) best = match;
			for (child in node.children) walk(child);
		}
		walk(tree);
		return best;
	}

	/**
	 * Whether `host`'s OWN declaration of `name` is an instance member: true when it declares one
	 * non-statically, false when ANY declaration of that name carries the `static` modifier, and null
	 * when the type declares no member of that name - the caller then asks the project index about
	 * the supertype closure. The declaration at `renamedFrom` is skipped: when the rename itself
	 * moved a member onto this name, that member is not a pre-existing one the occurrence could have
	 * read.
	 *
	 * The scan descends `#if` regions. A guarded member is a child of the conditional rather than of
	 * the type body, and the SymbolIndex sees it - a scan that did not would disagree with the index
	 * in the unsafe direction, reading a guarded `static` as "no own declaration" and letting an
	 * inherited instance member of the same name answer in its place.
	 */
	private static function ownInstanceMember(
		tree: QueryNode, host: QueryNode, name: String, renamedFrom: Int, shape: RefShape
	): Null<Bool> {
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		// A grammar without a static modifier matches no sibling, so every member reads as an instance one.
		final staticKind: String = shape.staticModifierKind ?? '';
		final modifierKinds: Array<String> = shape.modifierOrderKinds ?? [];
		var instance: Bool = false;
		var isStatic: Bool = false;
		function scan(parent: QueryNode): Void {
			for (child in parent.children) if (RefactorSupport.isConditionalKind(child.kind))
				scan(child);
			else {
				final span: Null<Span> = child.span;
				if (memberKinds.contains(child.kind) && child.name == name && (span == null || span.from != renamedFrom)) {
					if (modifierPrecedes(tree, child, staticKind, modifierKinds))
						isStatic = true;
					else
						instance = true;
				}
			}
		}
		scan(host);
		return if (isStatic)
			false
		else if (instance)
			true
		else
			null;
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
		return fn.children.exists(child -> paramKinds.contains(child.kind) && child.name == name);
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
	 *
	 * `edits` is every span the rewrite replaced (it drives the offset arithmetic);
	 * `resolved` is the subset the reference resolver itself produced, which is what
	 * the re-resolution must reproduce. They differ when the caller rewrote more than
	 * the resolver bound - the `naming` autofix renames a distinctive comment mention
	 * along - and coincide for a plain `rename`.
	 */
	private static function verifyQualified(
		qualification: Qualification, edits: Array<Span>, resolved: Array<Span>, newName: String, cursor: Int, plugin: GrammarPlugin,
		shape: RefShape
	): RenameResult {
		final qualified: String = qualification.source;
		final tree: QueryNode = try plugin.parseFile(qualified) catch (exception: ParseError) return Err(
			'qualified rewrite does not parse: $exception'
		)
		catch (exception: Exception) return Err('qualified rewrite does not parse: ${exception.message}');

		// Where each rewritten occurrence landed: the rename's own length delta accumulated
		// over the edits that PRECEDE it (not `delta * i`, which is only right when every edit
		// is also a resolved occurrence), then one prefix length per insertion at or before it.
		final sorted: Array<Span> = edits.copy();
		sorted.sort((a, b) -> a.from - b.from);
		final delta: Int = newName.length - (sorted[0].to - sorted[0].from);
		final resolvedFrom: Array<Int> = [for (occ in resolved) occ.from];
		final expected: Array<Int> = [];
		var shift: Int = 0;
		var newCursor: Int = -1;
		for (occ in sorted) {
			final inRewrite: Int = occ.from + shift;
			var at: Int = inRewrite;
			for (insertion in qualification.insertions) if (insertion <= inRewrite) at += qualification.prefixLength;
			if (resolvedFrom.contains(occ.from)) expected.push(at);
			if (newCursor < 0 && cursor >= occ.from && cursor <= occ.to) newCursor = at;
			shift += delta;
		}
		if (newCursor < 0) newCursor = expected[0];

		final actual: Array<Int> = [for (occ in renameOccurrences(qualified, tree, newCursor, shape)) occ.from];
		actual.sort((a, b) -> a - b);
		return actual.length != expected.length || !actual.foreach(off -> expected.contains(off))
			? Err('rename to "$newName" is unsafe: qualifying the captured occurrences did not resolve the capture')
			: Ok(qualified);
	}

}
