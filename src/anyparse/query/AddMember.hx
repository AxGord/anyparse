package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Add a member declaration to a type body — a structural INSERT
 * operation built on the query engine.
 *
 * Given a type name and the source of a new member, the operation
 * resolves the type declaration of that name (final-class-aware via
 * `RefactorSupport.typeDeclOf`), splices the raw member just before the
 * body's closing `}`, and finalizes through
 * `RefactorSupport.canonicalize` — so the member is WRITER-FORMATTED
 * (indented and laid out by the grammar's rules, not by this op) together
 * with the whole file, and re-parse-validated. The source is canonical-
 * gated unless `reformat` is set.
 *
 * Positioning is APPEND-ONLY (before the closing brace); member ordering
 * is the formatting layer's concern, not this op's. A member text
 * declaring a name the type already carries — in ANY conditional-
 * compilation branch — is REFUSED: a duplicate declaration is a SEMANTIC
 * error, which the re-parse cannot see. Works for class / interface /
 * abstract / enum / typedef-with-anon-body; a type with no brace body
 * (e.g. `typedef T = Int;`) is refused. The source is never mutated; the
 * caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class AddMember {

	/**
	 * Add `memberText` as a new trailing member of the type named
	 * `typeName` in `source`. `reformat` opts into a whole-file
	 * canonicalisation when the source is not already writer-canonical.
	 * Returns `Ok(rewritten)` or an `Err` describing why the member could
	 * not be added.
	 */
	public static function addMember(
		source: String, typeName: String, memberText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final trimmed: String = memberText.trim();
		if (trimmed.length == 0) return Err('add-member requires a non-empty member text');

		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) matches.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		if (matches.length == 0) return Err('no type named "$typeName"');
		if (matches.length > 1) return Err('ambiguous: ${matches.length} types named "$typeName"');

		// The body's closing `}` is found by scanning back over trailing
		// whitespace from the end of the body-bearing node — `nameNode`: the
		// inner `ClassForm` for a `final class`, the decl itself otherwise.
		// NOT the matched `fullSpan`: the outer `FinalDecl` span of a final
		// class swallows trailing trivia past the `}` (a following decl's
		// doc-comment, when the final class is not the last decl), so
		// `fullSpan` would land in that trivia and miss the brace.
		// `nameNode.span` ends right at the `}`, and equals `fullSpan` for
		// every non-final shape.
		final bodySpan: Span = matches[0].nameNode.span ?? matches[0].fullSpan;
		var bodyClose: Int = bodySpan.to - 1;
		if (bodyClose >= source.length) bodyClose = source.length - 1;
		while (bodyClose >= bodySpan.from && RefactorSupport.isSpace(source.fastCodeAt(bodyClose))) bodyClose--;
		if (bodyClose < bodySpan.from || source.fastCodeAt(bodyClose) != '}'.code)
			return Err('"$typeName" has no brace body to add a member to');

		final edit: { span: Span, text: String } = { span: new Span(bodyClose, bodyClose), text: '\n$trimmed\n' };
		final collision: Null<String> = collidingMemberName(source, edit, typeName, plugin);
		return collision != null
			? Err('"$typeName" already declares a member named "$collision"')
			: RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * The name `edit` would declare a second time in `typeName` — one the type already declares,
	 * or one the member text repeats within itself — or null when it collides with nothing. A
	 * duplicate is a SEMANTIC error, so the re-parse `canonicalize` performs accepts it: without
	 * this gate the op reported success and wrote a file the compiler rejects with `Duplicate
	 * class field declaration`.
	 *
	 * The question is asked of the SPLICED source rather than of the member text alone, so the
	 * text is read by the grammar rule that owns THIS host — an enum constructor, a typedef field
	 * and a class method are each recognised exactly as they will be after the write, with no
	 * synthetic wrapper having to guess a host kind for a plugin-agnostic op. Members starting
	 * inside the inserted window are the new ones; the rest are what they must not collide with.
	 *
	 * Both sides walk every member HOST under the declaration (`eachMemberHost`) rather than its
	 * direct children — that is what reaches the fields of a `typedef` through its anon body, and
	 * the members of a `#if` region through the region. A guarded twin is still a duplicate: one
	 * the default build compiles clean and the define revealing it rejects, so a guarded name is
	 * refused unconditionally, exactly as `CrossRenameMember` refuses its destination name.
	 * `MemberBranchScan.declaresMemberNamed` is deliberately NOT reused here: widening its
	 * field-only, direct-children form to cover enum constructors and anon bodies would also hand
	 * the MOVE ops members they must not act on.
	 *
	 * Text that does not parse in this position yields no answer at all: `canonicalize` then
	 * reports the parse failure with its own position and message, which beats a name error
	 * derived from a tree that could not be built.
	 */
	private static function collidingMemberName(
		source: String, edit: { span: Span, text: String }, typeName: String, plugin: GrammarPlugin
	): Null<String> {
		final at: Int = edit.span.from;
		final spliced: String = source.substring(0, at) + edit.text + source.substring(edit.span.to);
		final tree: QueryNode = try plugin.parseFile(spliced) catch (exception: Exception) return null;
		final decl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(tree, typeName);
		if (decl == null) return null;

		final to: Int = at + edit.text.length;
		final existing: Array<String> = [];
		final added: Array<String> = [];
		RefactorSupport.eachMemberHost(decl.nameNode, host -> {
			for (child in host.children) if (RefactorSupport.isMemberDeclKind(child.kind)) {
				final span: Null<Span> = child.span;
				final name: Null<String> = child.name;
				if (span != null && name != null) (span.from >= at && span.from < to ? added : existing).push(name);
			}
		});
		for (i => name in added) if (existing.contains(name) || added.indexOf(name) < i) return name;
		return null;
	}

}
