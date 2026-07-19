package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.RefactorSupport.TypeDeclMatch;

/**
 * Add or replace the doc-comment of the declaration at a cursor — the
 * member-doc counterpart of the writer-emit ops. `replace-node --with-doc`
 * rewrites a declaration AND its doc together (the whole declaration has to be
 * retyped); this edits ONLY the doc region, leaving the declaration untouched.
 *
 * The doc region is `[docExtendedSpan.from, declGroupSpan.from)`: the leading
 * block comment if one exists (replaced), else empty (the new doc is inserted
 * before the declaration). `text` is formatted into a doc-comment block by
 * `RefactorSupport.docComment` and the whole file is re-emitted +
 * re-parse-validated via `RefactorSupport.canonicalize` (canonical-gated unless
 * `reformat`) — so the spliced comment is re-indented and attached to the
 * declaration by the writer's own trivia rules.
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class SetDoc {

	/**
	 * Set the doc-comment of the node at `line:col` (the `apq refs` column
	 * convention) to `docText`. The cursor node is lifted through single-child
	 * wrapper decls that start earlier (`final class` = FinalDecl around its
	 * ClassForm), so the doc lands before the whole declaration instead of being
	 * spliced into its interior and dropped by the writer. Returns `Ok(rewritten)`,
	 * or an `Err` when the doc could not be set — including a byte-identical
	 * result (the doc already matches, or the position cannot carry a doc).
	 */
	public static function setDoc(
		source: String, line: Int, col: Int, docText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final cursor: Int = Span.offsetOf(source, line, col);
		final resolved: Null<QueryNode> = Engine.at(tree, cursor);
		if (resolved == null) return Err('position $line:$col is not on a node');
		final resolvedSpan: Null<Span> = resolved.span;
		if (resolvedSpan == null) return Err('the resolved ${resolved.kind} node has no source span');

		// A DECL WRAPPER whose identity is carried by the cursor node itself (a
		// `final class`'s FinalDecl around its ClassForm — `typeDeclOf(wrapper)`
		// names the inner node) owns the doc slot: a splice at the inner node's
		// start would fall INSIDE the wrapper (between `final` and `class`),
		// where the writer's canonical re-emit silently drops comment trivia.
		// Lift to the outermost such wrapper before computing the doc region.
		// The identity condition keeps every non-wrapper parent (a class over
		// its sole member, `Not` over its operand) un-lifted.
		var node: QueryNode = resolved;
		var span: Span = resolvedSpan;
		while (true) {
			final wrapper: Null<QueryNode> = RefactorSupport.parentOf(tree, node);
			if (wrapper == null) break;
			final wrapperSpan: Null<Span> = wrapper.span;
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(wrapper);
			if (wrapperSpan == null || decl == null || decl.nameNode != node || wrapperSpan.from >= span.from) break;
			node = wrapper;
			span = wrapperSpan;
		}

		// Fold modifiers / `@:meta` into the declaration unit, then extend back
		// over any existing leading doc — the region between is exactly the
		// declaration's documentation slot (empty when it has none → insert).
		final groupSpan: Span = RefactorSupport.declGroupSpan(node, RefactorSupport.parentOf(tree, node), span);
		final docExtended: Span = RefactorSupport.docExtendedSpan(source, groupSpan);
		final docRegion: Span = new Span(docExtended.from, groupSpan.from);
		final edit: { span: Span, text: String } = { span: docRegion, text: '${RefactorSupport.docComment(docText)}\n' };
		final result: EditResult = RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
		// A result byte-identical to the NO-EDIT baseline is a silent no-op —
		// either the doc already matches verbatim or the splice position cannot
		// carry a doc (the writer dropped it). Under `reformat` the baseline is
		// the reformatted source, so unrelated reflow noise cannot mask a drop.
		// Surface the no-op instead of reporting a successful write.
		return switch result {
			case Ok(text) if (text == source || (reformat && text == reformatBaseline(source, plugin, optsJson))):
				Err('the edit produced no change — the doc already matches, or this position cannot carry a doc');
			case _: result;
		}
	}

	/**
	 * The writer-canonical form of `source` with NO edit applied — the comparison
	 * baseline the no-op guard uses under `reformat`, where the edited result
	 * differs from the raw source by reflow noise alone even when the doc itself
	 * was dropped. An unparseable / un-canonicalizable source falls back to the
	 * raw source (the guard then degrades to plain byte-equality).
	 */
	private static function reformatBaseline(source: String, plugin: GrammarPlugin, ?optsJson: String): String {
		return switch RefactorSupport.canonicalize(source, [], true, plugin, optsJson) {
			case Ok(text): text;
			case Err(_): source;
		}
	}

}
