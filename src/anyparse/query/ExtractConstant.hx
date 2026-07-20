package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * `extract-constant` — replace every occurrence of a plain single-quoted
 * string literal inside one type with a reference to a fresh
 * `private static final` constant, so a repeated key / tag lives in one
 * named place (a typo in one of many occurrences becomes impossible).
 *
 *     if (k == 'base.ref') …          // ×N across the type
 *
 * becomes
 *
 *     private static final BASE_REF:String = 'base.ref';
 *     …
 *     if (k == BASE_REF) …            // every occurrence
 *
 * ## Boundary
 *
 * Only PLAIN single-quoted literals match — an interpolated `'$x'`
 * (which is not a constant value) and a double-quoted `"…"` are left
 * untouched; the caller supplies the exact literal CONTENT (the text
 * between the quotes). The constant reuses the first occurrence's verbatim
 * source token, so its escaping is preserved exactly. Refuses a name that
 * is not a valid identifier, a name that collides with an existing member,
 * a non-unique / missing type, or a literal that does not occur. Semantic
 * sameness is the caller's judgement — the op couples only the occurrences
 * it is told to. Writer-emitted and canonical-gated like the other
 * structural-insert ops.
 */
@:nullSafety(Strict)
final class ExtractConstant {

	/**
	 * Extract the single-quoted literal `literal` in `typeName` into a
	 * `private static final` named `name`. `reformat` canonicalises a drifted
	 * file. Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function extractConstant(
		source: String, typeName: String, name: String, literal: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (!RefactorSupport.isIdentifier(name)) return Err('"$name" is not a valid identifier for a constant name');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = uniqueType(tree, typeName);
		if (decl == null) return Err('no unique type "$typeName" in the source');
		final declNN: TypeDeclMatch = decl;
		if (memberNamed(declNN, name)) return Err('type "$typeName" already has a member named "$name"');

		final occurrences: Array<Span> = collectOccurrences(declNN.nameNode, literal);
		if (occurrences.length == 0) return Err('no single-quoted literal \'$literal\' occurs in type "$typeName"');

		final insertAt: Int = firstMemberStart(source, declNN);
		if (insertAt < 0) return Err('type "$typeName" has no member to anchor the constant before');

		final firstOcc: Span = occurrences[0];
		final token: String = source.substring(firstOcc.from, firstOcc.to);
		final edits: Array<{ span: Span, text: String }> = [
			{ span: new Span(insertAt, insertAt), text: 'private static final $name:String = $token;\n' }
		];
		for (occ in occurrences) edits.push({ span: occ, text: name });

		return RefactorSupport.canonicalize(source, edits, reformat, plugin, optsJson);
	}

	/** The sole type declaration named `typeName`, or null. Final-aware. */
	private static function uniqueType(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) matches.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
	}

	/** Does `decl` declare a member named `name` (any field / method)? */
	private static function memberNamed(decl: TypeDeclMatch, name: String): Bool {
		for (child in decl.nameNode.children) if (
			(RefactorSupport.isFieldMemberKind(child.kind) || RefactorSupport.FN_DECL_KINDS.contains(child.kind)) && child.name == name
		)
			return true;
		return false;
	}

	/**
	 * Spans of every PLAIN single-quoted string literal equal to `literal`
	 * anywhere under `typeNode`. A plain literal is a `SingleStringExpr` with
	 * exactly one `Literal` child (an interpolated string carries extra
	 * children); its content is that child's name.
	 */
	private static function collectOccurrences(typeNode: QueryNode, literal: String): Array<Span> {
		final spans: Array<Span> = [];
		function walk(node: QueryNode): Void {
			// A literal inside `@:meta('x')` must stay a literal — metadata needs a
			// constant string, not an identifier reference.
			if (RefactorSupport.META_KINDS.contains(node.kind)) return;
			if (node.kind == 'SingleStringExpr' && node.children.length == 1) {
				final only: QueryNode = node.children[0];
				final span: Null<Span> = node.span;
				if (only.kind == 'Literal' && only.name == literal && span != null) spans.push(span);
			}
			for (c in node.children) walk(c);
		}
		walk(typeNode);
		return spans;
	}

	/**
	 * Source offset just before the first member, with its leading `/**` doc comment and modifier run included (via `docExtendedSpan`) — where the constant is spliced so it becomes the types first member while the original first member keeps its own doc. -1 when the type has no member.
	 */
	private static function firstMemberStart(source: String, decl: TypeDeclMatch): Int {
		for (child in decl.nameNode.children) if (
			RefactorSupport.isFieldMemberKind(child.kind) || RefactorSupport.FN_DECL_KINDS.contains(child.kind)
		) {
			final span: Null<Span> = child.span;
			if (span == null) continue;
			final group: Span = RefactorSupport.declGroupSpan(child, decl.nameNode, span);
			return RefactorSupport.docExtendedSpan(source, group).from;
		}
		return -1;
	}

}
