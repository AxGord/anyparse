package anyparse.query;

import anyparse.query.ComposedValues.Expectation;
import anyparse.query.NominalTypes.IndexTyping;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

/**
 * The index host's arc for a lambda's parameter written with no type (`TypingHost.parameter`; 4.3.7 `typer.ml`
 * `type_local_function`, `maybe_unify_arg`): the parameter at its position of the function type the lambda is expected
 * to be (`ExpectedTypes.lambdaParamTypes`), as the index host reads what a position expects (`ComposedValues`) — a
 * declaration's or a structure field's written type, an array's element, the parameter a call binds the lambda to with
 * its receiver's and its earlier arguments' types bound in (`CallReturns.selectedParameter`, `extensionParameter`).
 */
@:nullSafety(Strict)
@:access(anyparse.query.ComposedValues)
final class LambdaParameters {

	/**
	 * The type the lambda parameter declared at `from` and read at `use`, written with no type, takes from the function
	 * type the lambda is expected to be, in the index host's written-source currency (`parameterType`). Null where the
	 * lambda's expected type is not read or is no function type of its arity, and for a parameter written optional or with
	 * a default value.
	 */
	public static function indexParameter(from: Int, use: QueryNode, c: IndexTyping): Null<String> {
		final index: Null<SymbolIndex> = c.index;
		final name: Null<String> = use.name;
		final at: Null<Span> = use.span;
		final param: Null<QueryNode> = name == null || at == null ? null : TypeResolver.bindingNodeFrom(name, at, c.root, c.shape);
		final path: Array<QueryNode> = param == null || param.span?.from != from ? [] : TreePath.pathAround(c.root, param) ?? [];
		if (index == null || param == null || path.length < 2) return null;
		final lambda: QueryNode = path[path.length - 2];
		// a parameter written `?x` or with a default value is of the nullable type around the expected one
		if (!index.typing.expectations.isLambda(lambda) || param.kind == c.shape.optionalParamKind || param.children.length > 0)
			return null;
		final lineage: Array<QueryNode> = path.slice(0, path.length - 2);
		final indices: Array<Int> = [for (i in 0...lineage.length) lineage[i].children.indexOf(path[i + 1])];
		final kinds: Array<String> = c.shape.paramKinds ?? [];
		final position: Int = lambda.children.filter(p -> kinds.contains(p.kind)).indexOf(param);
		final types: Null<Array<Expectation>> = index.typing.expectations.lambdaParamTypes(
			lambda, lineage, indices, ComposedValues.expectationHost(), c
		);
		return types == null || position < 0 ? null : parameterType(types[position], c);
	}

	/**
	 * The type a lambda parameter takes from `expected`, its place in the function type the lambda is expected to be: the
	 * type written there, read in the file the lambda is written in (`Expectation.file`). Null for none, one read in another
	 * file, one that is no one type, one naming a type parameter of a call no argument before the
	 * lambda binds, and the dynamic type, written so or through an alias — a monomorph does not bind to it (`link`), the
	 * parameter is typed by its uses in the lambda's body instead.
	 */
	private static function parameterType(expected: Null<Expectation>, c: IndexTyping): Null<String> {
		final syntax: TypeSyntaxReader = c.chain.typeSyntax;
		if (expected == null || expected.free || !NominalTypes.answerableType(expected.text, syntax)) return null;
		final peeled: String = NominalTypes.memberLookupReceiverSource(
			expected.text, c.shape.memberTransparentWrapperTypeNames ?? [], syntax
		);
		final file: Null<FileInfo> = expected.file;
		// a type read in another file is no type of this one: a namesake here would take its place
		if (file == null || file.file != c.file) return null;
		final isDynamic: Bool = NominalTypes.outerNominalOf(peeled, syntax) == c.shape.rawDynamicTypeName
			|| c.index?.typing.casts.endIn(peeled, file, 0, []).match(Dyn) == true;
		return isDynamic || CallGraphNames.mentionsTypeName(expected.text, expected.unbound, syntax) ? null : expected.text.trim();
	}

}
