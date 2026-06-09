package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * is the formatting layer's concern, not this op's. Works for class /
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
	public static function addMember(source:String, typeName:String, memberText:String, reformat:Bool, plugin:GrammarPlugin):EditResult {
		final tree:QueryNode = try plugin.parseFile(source)
			catch (exception:ParseError) return Err('source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('source does not parse: ${exception.message}');

		final trimmed:String = StringTools.trim(memberText);
		if (trimmed.length == 0)
			return Err('add-member requires a non-empty member text');

		final matches:Array<TypeDeclMatch> = [];
		function walk(node:QueryNode):Void {
			final m:Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) matches.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		if (matches.length == 0)
			return Err('no type named "$typeName"');
		if (matches.length > 1)
			return Err('ambiguous: ${matches.length} types named "$typeName"');

		// The body's closing `}` is the last `}` within the decl span,
		// skipping trailing whitespace: some decl-span shapes swallow
		// trailing trivia past the `}` (the outer `FinalDecl` of a `final
		// class`, and a `TypedefDecl` with an anon body — both can include a
		// trailing newline at EOF), so `fullSpan.to - 1` is not reliably the
		// brace. Scanning back over whitespace lands on the `}` for every
		// shape (class / interface / abstract / enum / typedef-anon / final).
		final fullSpan:Span = matches[0].fullSpan;
		var bodyClose:Int = fullSpan.to - 1;
		if (bodyClose >= source.length) bodyClose = source.length - 1;
		while (bodyClose >= fullSpan.from && RefactorSupport.isSpace(StringTools.fastCodeAt(source, bodyClose))) bodyClose--;
		if (bodyClose < fullSpan.from || StringTools.fastCodeAt(source, bodyClose) != '}'.code)
			return Err('"$typeName" has no brace body to add a member to');

		final edit:{span:Span, text:String} = {span: new Span(bodyClose, bodyClose), text: '\n' + trimmed + '\n'};
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin);
	}
}
