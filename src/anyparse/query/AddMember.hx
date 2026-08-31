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
 * declaring a name the type already carries — in any conditional-
 * compilation branch that NAMES its members — is REFUSED: a duplicate
 * declaration is a SEMANTIC error, which the re-parse cannot see. A type
 * carrying a region the tree cannot name through (a member-scope `#if`
 * splice, a guarded function name) is refused OUTRIGHT: a collision
 * inside it can be neither proved nor ruled out. Works for class /
 * interface / abstract / enum / typedef-with-anon-body; a type with no
 * brace body (e.g. `typedef T = Int;`) is refused. The source is never
 * mutated; the caller decides whether to write the result.
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
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
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
		if (carriesOpaqueMemberRegion(matches[0].nameNode))
			return Err(
				'"$typeName" carries a conditional member region whose declarations the tree does not expose — a duplicate name would go '
				+ 'undetected; add the member by hand'
			);

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

		// The leading newline is the SEPARATOR the new member needs from the one above it. Under a
		// config that KEEPS the blank line before a closing brace — this project's and Pony's — a
		// canonical body already carries one, so emitting the separator unconditionally produced TWO:
		// `fmt --list` calls the result canonical (the writer re-emits a blank run verbatim), so
		// nothing reported it and the file silently drifted from the layout every other member in it
		// has. Emit only what is missing.
		// When one is already there the new member takes it as its OWN separator and re-emits one
		// below, so the body keeps the shape it had on BOTH sides: consuming it instead moved the
		// drift to the other end, leaving the closing brace with no blank above it under a config
		// that keeps but never emits one.
		final edit: { span: Span, text: String } = blankLinePrecedes(source, bodyClose)
			? { span: new Span(bodyClose, bodyClose), text: '$trimmed\n\n' }
			: { span: new Span(bodyClose, bodyClose), text: '\n$trimmed\n' };
		final refusal: Null<String> = spliceRefusal(source, edit, typeName, plugin);
		return refusal != null ? Err(refusal) : RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * Why `edit` may not be applied — or null when nothing objects. Two refusals share one walk of
	 * the SPLICED tree, because both ask the same question of the same nodes: a name declared twice,
	 * and a member the tree cannot name at all.
	 *
	 * A duplicate is a SEMANTIC error, so the re-parse `canonicalize` performs accepts it: without
	 * this gate the op reported success and wrote a file the compiler rejects with `Duplicate class
	 * field declaration`. The question is asked of the SPLICED source rather than of the member text
	 * alone, so the text is read by the grammar rule that owns THIS host — an enum constructor, a
	 * typedef field and a class method are each recognised exactly as they will be after the write,
	 * with no synthetic wrapper having to guess a host kind for a plugin-agnostic op. Members starting
	 * inside the inserted window are the new ones; the rest are what they must not collide with.
	 *
	 * Both sides walk every member HOST under the declaration (`eachMemberHost`) rather than its
	 * direct children — that is what reaches the fields of a `typedef` through its anon body, and the
	 * members of a `#if` region through the region. A guarded twin is still a duplicate: one the
	 * default build compiles clean and the define revealing it rejects, so a guarded name is refused
	 * unconditionally, exactly as `CrossRenameMember` refuses its destination name.
	 * `MemberBranchScan.declaresMemberNamed` is deliberately NOT reused here: widening its field-only,
	 * direct-children form to cover enum constructors and anon bodies would also hand the MOVE ops
	 * members they must not act on.
	 *
	 * The second refusal is the MIRROR of the host gate `carriesOpaqueMemberRegion`: an added member
	 * that is itself an opaque region (`RefactorSupport.isOpaqueMemberKind`) declares names this walk
	 * cannot read, so the addition can be neither cleared nor convicted and is refused. Checking it
	 * here rather than before the splice is what makes the member text answer to the host's own
	 * grammar rule, the same reason the name scan lives here.
	 *
	 * Text that does not parse in this position yields no answer at all: `canonicalize` then reports
	 * the parse failure with its own position and message, which beats a name error derived from a
	 * tree that could not be built.
	 */
	private static function spliceRefusal(
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
		var addedOpaqueRegion: Bool = false;
		RefactorSupport.eachMemberHost(decl.nameNode, host -> {
			for (child in host.children) if (RefactorSupport.isMemberDeclKind(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null) {
					final isAdded: Bool = span.from >= at && span.from < to;
					final name: Null<String> = child.name;
					if (RefactorSupport.isOpaqueMemberKind(child.kind)) {
						if (isAdded) addedOpaqueRegion = true;
					} else if (name != null)
						(isAdded ? added : existing).push(name);
				}
			}
		});
		if (addedOpaqueRegion)
			return 'the member text is a conditional member region whose declarations the tree does not expose — a duplicate name '
				+ 'would go undetected; add the member by hand';
		for (i => name in added) if (existing.contains(name) || added.indexOf(name) < i)
			return '"$typeName" already declares a member named "$name"';
		return null;
	}

	/**
	 * Whether the type body rooted at `typeBody` — the match's `nameNode`, which for a `final class`
	 * is the inner `ClassForm` rather than the declaration — carries a member form whose declared names
	 * the tree does not carry (`RefactorSupport.isOpaqueMemberKind`). Refusing on the NODE rather than
	 * on a name is the only answer available here: the projected region exposes no names to compare
	 * against, so a collision inside it can be neither proved nor ruled out, and `spliceRefusal`
	 * silently fail-opens there — on `pony/Tools.hx:490` the op reported success and produced a THIRD
	 * `sget`, which both define branches reject as a duplicate.
	 *
	 * The scan is TYPE-scoped — it walks this type body's member hosts only — so a sibling type in the
	 * same file that carries no region is still served.
	 */
	private static function carriesOpaqueMemberRegion(typeBody: QueryNode): Bool {
		var found: Bool = false;
		RefactorSupport.eachMemberHost(typeBody, host -> for (child in host.children) if (RefactorSupport.isOpaqueMemberKind(child.kind))
			found = true);
		return found;
	}

	/**
	 * Whether the whitespace immediately before `at` already spans a whole BLANK line — i.e. the
	 * insertion point is separated from the text above it by at least one empty line. Two newlines,
	 * because the first ends the line that text sits on and the second ends an empty one; anything
	 * between them must be indentation only.
	 *
	 * Whether a canonical body HAS that blank line is a config question, not a universal one, and so is
	 * whether the writer would put it back: measured, this project's own options re-emit it while
	 * `{"emptyLines": {"maxAnywhereInFile": 2, "beforeRightCurly": "keep"}}` alone only PRESERVES what
	 * it is given. So the op owes both sides — take the blank as the new member's separator and re-emit
	 * one below it — and neither the doubling this guards against nor the bare brace the first fix left
	 * behind was visible to any fixture in this suite until one passed options in.
	 */
	private static function blankLinePrecedes(source: String, at: Int): Bool {
		var newlines: Int = 0;
		var i: Int = at - 1;
		while (i >= 0) {
			final code: Int = source.fastCodeAt(i);
			if (code == '\n'.code) {
				newlines++;
				if (newlines >= 2) return true;
			} else if (!RefactorSupport.isSpace(code))
				return false;
			i--;
		}
		return false;
	}

}
