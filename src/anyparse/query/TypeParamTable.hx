package anyparse.query;

import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;

/**
 * The type parameters every indexed type declares, and the type arguments its `extends` / `implements`
 * clauses pass to its supertypes' parameters — what a `CallGraph` needs to see a member declared with a
 * parameter as the type a particular value holds.
 */
@:nullSafety(Strict)
final class TypeParamTable {

	/** Type name -> the type parameters its declarations declare. */
	private final _typeParams: Map<String, Array<String>> = [];

	/** Type name -> its `extends` / `implements` targets as written, type arguments included, each with the file writing it. */
	private final _supersWritten: Map<String, Array<{ written: String, file: String }>> = [];

	public function new() {}

	/** Whether `typeName` declares the type parameter `name`. */
	public inline function declaresTypeParam(typeName: String, name: String): Bool {
		return (_typeParams[typeName] ?? []).contains(name);
	}

	/** The type parameters `typeName` declares, in order. */
	public inline function typeParamsOf(typeName: String): Array<String> {
		return _typeParams[typeName] ?? [];
	}

	/**
	 * The type arguments `viewType`'s `extends` / `implements` chain passes to `owner`'s parameters, written in
	 * `viewType`'s own terms (`class D extends B<W>` passes `W`, `class M<X> extends B<X>` passes `X`), or null
	 * when `owner` is not on the chain or a link writes no arguments. With `keyIn` handed, each argument a link writes is
	 * first read through it with the file that wrote it and the type writing the link (`CallGraphKeys.keyedIn`): a name means
	 * what that file's imports bind it to, unless a type parameter of that type shadows it.
	 */
	public function argumentsFor(
		owner: String, viewType: String, typeSyntax: TypeSyntaxReader, ?keyIn: (String, String, String) -> String
	): Null<Array<String>> {
		return argumentsVia(owner, viewType, [], typeSyntax, keyIn);
	}

	/**
	 * Fold the parameters and the written supertypes of one declaration, of the file keyed `file` — a later one of the same
	 * name unions.
	 */
	public function record(t: TypeDeclInfo, file: String): Void {
		CallGraphTypes.unionInto(_typeParams, t.name, t.typeParamNames);
		final supers: Array<{ written: String, file: String }> = _supersWritten[t.name] ?? [];
		for (s in t.supertypesWritten) if (!supers.exists(w -> w.written == s && w.file == file)) supers.push({ written: s, file: file });
		_supersWritten[t.name] = supers;
	}

	private function argumentsVia(
		owner: String, typeName: String, seen: Array<String>, typeSyntax: TypeSyntaxReader, keyIn: Null<(String, String, String) -> String>
	): Null<Array<String>> {
		if (seen.contains(typeName)) return null;
		seen.push(typeName);
		for (link in _supersWritten[typeName] ?? []) {
			final written: String = link.written;
			final outer: Null<String> = NominalTypes.outerNominalOf(written, typeSyntax);
			final args: Array<String> = [
				for (a in NominalTypes.typeArgumentSourcesOf(written, typeSyntax) ?? []) keyIn == null ? a : keyIn(link.file, a, typeName)
			];
			if (outer == owner) return args;
			final up: Null<Array<String>> = outer == null ? null : argumentsVia(owner, outer, seen, typeSyntax, keyIn);
			final params: Array<String> = outer == null ? [] : typeParamsOf(outer);
			if (up != null && args.length >= params.length)
				return [for (a in up) CallGraphNames.substituteTypeParams(a, params, args, typeSyntax)];
		}
		return null;
	}

	/**
	 * The type parameters in scope at the offset `at` of `tree`, read off `declared` (`TypeInfoProvider.typeParamNames`): those
	 * of every type declaration around it (keyed by its name node, `RefactorSupport.typeDeclOf`) and of every function around
	 * it (a node of `functionKinds`, keyed by its own start). A name among them means the parameter there, never a type an
	 * import or the package binds it to.
	 */
	public static function inScopeAt(
		tree: QueryNode, at: Int, declared: Map<Int, Array<String>>, functionKinds: Array<String>
	): Array<String> {
		final out: Array<String> = [];
		function add(key: Int): Void {
			for (name in declared[key] ?? []) if (!out.contains(name)) out.push(name);
		}
		function visit(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && (at < span.from || at >= span.to)) return;
			final decl: Null<RefactorSupport.TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (decl != null) add((decl.nameNode.span ?? decl.fullSpan).from);
			if (span != null && functionKinds.contains(node.kind)) add(span.from);
			for (c in node.children) visit(c);
		}
		visit(tree);
		return out;
	}

}
