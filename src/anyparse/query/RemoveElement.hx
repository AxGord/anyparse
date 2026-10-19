package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ElementSpan.ElementHit;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.runtime.Span;

/**
 * Remove the sibling element a cursor points at — the GENERALIZED
 * list-delete op and the structural inverse of `AddElement`. It is the
 * missing DELETE verb of the mutation-op family, which had Create (the
 * `add-*` ops) and Update (`replace-node`) but no Delete. It removes a
 * statement from a block, a `case` from a switch, an element from a comma
 * list (array / object / call-arg / `new`-arg), or a class member —
 * whatever node the cursor's first token names.
 *
 * Targeting and finalize mirror `AddElement`: `line:col` points at the
 * FIRST TOKEN of the element to remove (the `apq refs` print-column
 * convention), and the whole file is re-emitted through the writer (which
 * fixes residual whitespace and re-parse-validates). The element node is
 * resolved with `RefactorSupport.elementAtFrom` + `parentOf`; the deletion
 * span (modifier / meta group and leading `/**` doc folded, one comma swallowed
 * for comma lists) and the writer finalize live in
 * `RefactorSupport.deleteNode`, shared with the by-name remove wrappers
 * (`RemoveImport` / `RemoveMember`).
 *
 * A bare MODIFIER keyword named by an explicit `--select` / `--match` is REFUSED rather than
 * served (`CliEdit.namedModifierKeyword`, in the command layer, where the address MODE is still
 * known). It resolves to the same offset a POSITION on that keyword does, and the cursor
 * convention reads that as the declaration's first token, so `--select 'Private'` deleted the
 * whole `private typedef Helper` declaration at rc 0. The position form keeps that reading, which
 * is why the guard is on the mode and not on the resolved kind; an annotation is unaffected,
 * being an element in its own right.
 */
@:nullSafety(Strict)
final class RemoveElement {

	/**
	 * Remove the sibling element whose first token the cursor at `line:col` falls
	 * within — a statement, `case`, comma-list element, or member (folded with its
	 * leading modifier / `@:meta` group AND its leading `/**` doc block — a plain
	 * block comment above it is left alone). `reformat` opts into a whole-file
	 * canonicalisation when the source is not writer-canonical; `withDoc = false`
	 * keeps the doc. Returns `Ok(rewritten)` or an `Err`; the
	 * source is never mutated.
	 */
	public static function removeElement(
		source: String, line: Int, col: Int, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true, ?optsJson: String
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final raw: Null<ElementHit> = RefactorSupport.elementAtFrom(tree, source, cursor);
		final hit: Null<ElementHit> = raw == null ? null : ElementSpan.liftedElement(tree, raw.node);
		if (raw == null || hit == null)
			return Err(
				'position $line:$col'
				+ ' is not on the first token of an element — point at the first token of a statement / case / list element / member'
			);
		final refusal: Null<String> = strandedLiteral(raw.node, hit, plugin);
		return refusal == null ? ElementSpan.deleteNode(source, hit.node, hit.parent, reformat, plugin, withDoc, optsJson) : Err(refusal);
	}

	/**
	 * The one line a removal owed its caller: what the cut at `line:col` takes, named and
	 * counted, for the op to print beside the file it wrote.
	 *
	 * Null when the address resolves to no element — `removeElement` re-resolves and
	 * reports the real error, and a description is not the place to fail. Pass the op's
	 * own CACHING plugin: the parse here is then the parse the edit makes.
	 */
	public static function describeRemoval(source: String, line: Int, col: Int, plugin: GrammarPlugin, withDoc: Bool = true): Null<String> {
		return describeHit(source, plugin, withDoc, tree -> ElementSpan.liftedElementAt(tree, source, Span.offsetOf(source, line, col)));
	}

	/**
	 * Remove EXACTLY the node `target` resolves to — the `--kind` form of the op. A position
	 * resolves the innermost node of the kind containing the cursor (`ByKindPosition`); a
	 * `--select` / `--match` node arrives already LIFTED to its innermost enclosing node of the
	 * kind (`CliEdit.resolveEditTarget`, the lift `replace-node` and `patch` share), so
	 * `--match 'trace($x)' --kind ExprStmt` removes the statement the call is, and
	 * `--match '$p.parseFile($s)' --kind FinalStmt` the declaration whose initializer it is —
	 * an address the first-token convention cannot express, since the match does not start the
	 * statement. The node is not re-derived from its first token: that reading picks the
	 * OUTERMOST element starting there, which is exactly what naming a kind overrides. A
	 * `final class`'s inner form is still lifted to its wrapper (`ElementSpan.liftedElement`).
	 */
	public static function removeTarget(
		source: String, target: ReplaceTarget, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true, ?optsJson: String
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};
		final node: QueryNode = switch ReplaceNode.resolveTarget(source, tree, target, plugin) {
			case Resolved(n): n;
			case Failed(message): return Err(message);
		};
		final hit: ElementHit = ElementSpan.liftedElement(tree, node);
		final refusal: Null<String> = strandedLiteral(node, hit, plugin);
		return refusal == null ? ElementSpan.deleteNode(source, hit.node, hit.parent, reformat, plugin, withDoc, optsJson) : Err(refusal);
	}

	/** `describeRemoval` for the node `target` resolves to — what `removeTarget` cuts. */
	public static function describeTarget(
		source: String, target: ReplaceTarget, plugin: GrammarPlugin, withDoc: Bool = true
	): Null<String> {
		return describeHit(
			source, plugin, withDoc, tree -> switch ReplaceNode.resolveTarget(source, tree, target, plugin) {
				case Resolved(n): ElementSpan.liftedElement(tree, n);
				case Failed(_): null;
			}
		);
	}

	/** The cut description for the element `find` picks out of the parsed source, or null. */
	private static function describeHit(
		source: String, plugin: GrammarPlugin, withDoc: Bool, find: QueryNode -> Null<ElementHit>
	): Null<String> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return null;
		final hit: Null<ElementHit> = find(tree);
		if (hit == null) return null;
		final nodeSpan: Null<Span> = hit.node.span;
		return nodeSpan == null ? null : ElementSpan.describeCut(source, hit.node, hit.parent, nodeSpan, withDoc, plugin);
	}

	/**
	 * The refusal for a string `Literal` that is NOT a whole element of a comma list, else null.
	 *
	 * An address on a literal resolves the text between its quotes. When the literal is itself the element
	 * (`ElementSpan.literalWrapperOf` lifted `hit` to its quoted expression, whose parent is a comma container)
	 * the removal is the one the position form makes. Anywhere else — an operand of `+`, a `return` value, an
	 * object field's value — there is no element to cut, and cutting the content would silently leave `''`.
	 */
	private static function strandedLiteral(node: QueryNode, hit: ElementHit, plugin: GrammarPlugin): Null<String> {
		if (node.kind != 'Literal' || hit.node == node) return null;
		final container: Null<QueryNode> = hit.parent;
		if (container != null && (plugin.refShape().commaContainerKinds ?? []).contains(container.kind)) return null;
		final where: String = container == null ? 'the file' : container.kind;
		return 'the literal is not a whole element of a list: it sits inside $where, so there is no element to remove — '
			+ 'address the enclosing node (`--select`/`--match` it with `--kind`) or edit it with `replace-node` / `patch`';
	}

}
