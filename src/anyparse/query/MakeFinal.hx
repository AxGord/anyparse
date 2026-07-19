package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** One scope file parsed once. */
private typedef Parsed = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

/**
 * `make-final` — turn a mutable `var` field into `final` when it is never
 * reassigned after its single initialisation. Directly unblocks the
 * `move-member` instance path, whose sibling-fields contract accepts only
 * FINAL fields: `make-final` first, then the instance member moves.
 *
 * A field qualifies when every write to it (bare `field = …`, `this.field
 * = …`, `field++`, cross-file `obj.field = …`, and the compound-assign
 * forms) lands INSIDE the declaring type's constructor — that write is the
 * final's one initialisation — and it has a declaration initialiser xor a
 * constructor write (so the result is neither uninitialised nor
 * double-initialised). Any write outside the constructor refuses the
 * change, listed by file. Conservative: a `.field` write on an unrelated
 * type of the same field name also refuses (a false refusal, never a
 * wrong rewrite).
 *
 * The rewrite is a single `var` → `final` keyword splice, re-parsed before
 * it is returned; formatting is otherwise untouched.
 */
@:nullSafety(Strict)
final class MakeFinal {

	/** Assignment / increment operator kinds whose first child is the write target. */
	private static final INCR_KINDS: Array<String> = ['PreIncr', 'PostIncr', 'PreDecr', 'PostDecr'];

	/** The mutable field keyword this op replaces with `final`. */
	private static final VAR: String = 'var';

	/**
	 * Make the `var` field `fieldName` of `typeName` (declared in `srcFile`)
	 * `final` when no reassignment survives under `scopeFiles`. Returns
	 * `Ok(newSource)` for `srcFile` or an `Err`. PURE.
	 */
	public static function makeFinal(
		srcFile: String, typeName: String, fieldName: String, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): EditResult {
		final parsed: Array<Parsed> = [];
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: Exception) null;
			if (tree == null) return Err('cannot check writes: ${entry.file} does not parse');
			final treeNN: QueryNode = tree;
			parsed.push({ file: entry.file, source: entry.source, tree: treeNN });
		}

		final srcEntry: Null<Parsed> = parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Err('source file $srcFile is not in the scope file set');
		final src: Parsed = srcEntry;

		final fieldNode: Null<QueryNode> = resolveVarField(src.tree, typeName, fieldName);
		if (fieldNode == null) return Err('no mutable var field "$fieldName" on a unique type "$typeName" in $srcFile');
		final fNode: QueryNode = fieldNode;
		final fieldSpan: Null<Span> = fNode.span;
		if (fieldSpan == null) return Err('field "$fieldName" carries no span');
		final fieldSpanNN: Span = fieldSpan;

		final ctorSpan: Null<Span> = constructorSpan(src.tree, typeName);
		final hasInit: Bool = fNode.children.length > 0;
		final writes: { ctorWrites: Int, outside: Array<String> } = classifyWrites(parsed, srcFile, fieldName, ctorSpan);
		if (writes.outside.length > 0)
			return Err('"$fieldName" is reassigned outside the constructor — cannot make it final: ${writes.outside.join(', ')}');
		if (!hasInit && writes.ctorWrites == 0) return Err('"$fieldName" is never assigned — cannot make it final');
		if (hasInit && writes.ctorWrites > 0)
			return Err('"$fieldName" is assigned both at its declaration and in the constructor — cannot make it final');

		if (keywordAt(src.source, fieldSpanNN.from) != VAR)
			return Err('field "$fieldName" does not start with the `var` keyword — cannot make it final');
		final rewritten: String = '${src.source.substring(0, fieldSpanNN.from)}final${src.source.substring(fieldSpanNN.from + VAR.length)}';

		try
			plugin.parseFile(rewritten)
		catch (exception: Exception)
			return Err('rewritten $srcFile does not parse: ${exception.message}');
		return Ok(rewritten);
	}

	/**
	 * Partition every write to `fieldName` across the scope into a count of
	 * constructor-local writes and the list of files with a write elsewhere.
	 */
	private static function classifyWrites(
		parsed: Array<Parsed>, srcFile: String, fieldName: String, ctorSpan: Null<Span>
	): { ctorWrites: Int, outside: Array<String> } {
		var ctorWrites: Int = 0;
		final outside: Array<String> = [];
		for (entry in parsed) for (w in writeOffsets(entry.tree, fieldName, entry.file == srcFile)) {
			final inCtor: Bool = entry.file == srcFile && ctorSpan != null && w >= ctorSpan.from && w < ctorSpan.to;
			if (inCtor)
				ctorWrites++
			else if (!outside.contains(entry.file))
				outside.push(entry.file);
		}
		return { ctorWrites: ctorWrites, outside: outside };
	}

	/**
	 * Resolve the plain `var` field `fieldName` of the sole type `typeName`
	 * (final-aware). Null when the type or a mutable field of that name is
	 * absent / ambiguous (a `final` field is already done and not matched).
	 */
	private static function resolveVarField(tree: QueryNode, typeName: String, fieldName: String): Null<QueryNode> {
		final decl: Null<TypeDeclMatch> = findSoleTypeDecl(tree, typeName);
		if (decl == null) return null;
		for (child in decl.nameNode.children) {
			final kind: String = child.kind;
			if ((kind == 'VarMember' || kind == 'VarField') && child.name == fieldName) return child;
		}
		return null;
	}

	/** The span of the `new` constructor of the sole type `typeName`, or null. */
	private static function constructorSpan(tree: QueryNode, typeName: String): Null<Span> {
		final decl: Null<TypeDeclMatch> = findSoleTypeDecl(tree, typeName);
		if (decl == null) return null;
		for (child in decl.nameNode.children) if (child.kind == 'FnMember' && child.name == 'new') return child.span;
		return null;
	}

	/**
	 * The offsets of every write to `fieldName` in `tree`: an assignment /
	 * increment whose first child is a `FieldAccess` named `fieldName`
	 * (`this.field` / `obj.field`), plus — in the declaring file only — a
	 * bare `IdentExpr` target (`field = …`). A bare write in another file is
	 * a different binding and is ignored.
	 */
	private static function writeOffsets(tree: QueryNode, fieldName: String, inSrc: Bool): Array<Int> {
		final out: Array<Int> = [];
		function walk(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			if ((StringTools.endsWith(node.kind, 'Assign') || INCR_KINDS.contains(node.kind)) && children.length > 0) {
				final target: QueryNode = children[0];
				final span: Null<Span> = target.span;
				final isWrite: Bool = target.name == fieldName && (target.kind == 'FieldAccess' || (inSrc && target.kind == 'IdentExpr'));
				if (isWrite && span != null) out.push(span.from);
			}
			for (c in children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** The `var`-keyword-length source slice at `from` (for the keyword check). */
	private static function keywordAt(source: String, from: Int): String {
		return from >= 0 && from + VAR.length <= source.length ? source.substr(from, VAR.length) : '';
	}


	/** The sole type declaration named `typeName` (final-aware), or null when absent / ambiguous. */
	private static function findSoleTypeDecl(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final decls: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) decls.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return decls.length == 1 ? decls[0] : null;
	}

}
