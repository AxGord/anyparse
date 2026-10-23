package anyparse.query;

import anyparse.query.CallSelection.CallCandidate;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.StructuralTypes.IteratorElement;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeShape;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.TypeTerm.TypeEnd;

using Lambda;

/**
 * Haxe 4.3.7's reading of an inference (`InferencePolicy`; `tUnification.ml`, `callUnification.ml`). A call's cells are
 * the type parameters its signature declares (`attempt_call`, `spawn_constrained_monos`); a written type reads as the
 * cast-graph end its head resolves to where it is written (`AbstractCasts.endIn`) applied to its arguments; and a given
 * type of another head reads as one of the wanted head through the nullable wrapper, which is transparent (`Null<T>`
 * meets what `T` meets; a cell takes it whole), the builtin `Iterable` (the element a std container iterates,
 * `StructuralTypes.iterableElementIndex`) and a supertype (what the chain of a type with no type parameter passes to an
 * ancestor's, `AncestorTable.argumentsTo`). Every other pair reads as none.
 */
@:nullSafety(Strict)
final class HaxeInferencePolicy implements InferencePolicy {

	/** The cast graph: the end a written head resolves to. */
	private final _casts: AbstractCasts;

	/** The name -> declaration layer a head the cast graph does not model is resolved through. */
	private final _refs: TypeRefIndex;

	/** What a chain passes to an ancestor's type parameters. */
	private final _ancestors: AncestorTable;

	/** Which element a container binds the builtin `Iterable`'s to. */
	private final _structural: StructuralTypes;

	/** `GrammarPlugin.typeSyntax`. */
	private final _typeSyntax: TypeSyntaxReader;

	/** The nullable wrapper (`RefShape.optionalValueTypeName`), or null. */
	private final _nullable: Null<String>;

	/** `RefShape.iterationElementTypeParams`: the argument a container's iteration yields. */
	private final _elementParams: Map<String, Int>;

	/** The grammar's abstract declaration kinds (`RefShape.underlyingThisTypeKinds`). */
	private final _abstractKinds: Array<String>;

	/** Built once by the owning `TypingService`. */
	public function new(
		casts: AbstractCasts, refs: TypeRefIndex, ancestors: AncestorTable, structural: StructuralTypes, typeSyntax: TypeSyntaxReader,
		shape: RefShape
	) {
		_casts = casts;
		_refs = refs;
		_ancestors = ancestors;
		_structural = structural;
		_typeSyntax = typeSyntax;
		_nullable = shape.optionalValueTypeName;
		_elementParams = shape.iterationElementTypeParams ?? [];
		_abstractKinds = shape.underlyingThisTypeKinds ?? [];
	}

	/** One cell per type parameter the signature of `k` declares. */
	public function callCells(k: CallCandidate, monos: Monomorphs): Map<String, Int> {
		return [for (name in k.signature.typeParamNames) name => monos.fresh()];
	}

	/**
	 * `text` as a term: a name `cells` maps its cell, a named type its head's end applied to its arguments' terms, anything
	 * else (a function type, a structure) opaque.
	 */
	public function termOf(text: String, file: FileInfo, at: Int, cells: Map<String, Int>): TypeTerm {
		final written: String = text.trim();
		final shape: Null<TypeShape> = _typeSyntax(written)?.shape;
		final cell: Null<Int> = switch shape {
			case Nominal(path, args) if (args.length == 0): cells[path];
			case _: null;
		};
		if (cell != null) return Mono(cell);
		return switch shape {
			case Nominal(path, args): Of(headOf(path, file, at), [for (a in args) termOf(a.text, file, at, cells)], written);
			case _: Opaque(written, [
				for (name => id in cells) if (CallGraphNames.mentionsTypeName(written, [name], _typeSyntax)) id
			]);
		};
	}

	/**
	 * `given` read as a type of `wanted`'s head: through the nullable wrapper on either side, as the element of the builtin
	 * `Iterable` it iterates, or as the ancestor `wanted` names — a type written elsewhere only where it reads alike in
	 * `reading`.
	 */
	public function reread(wanted: TypeTerm, given: TypeTerm, reading: FileInfo): Null<TypeTerm> {
		final inner: Null<TypeTerm> = nullableInner(given);
		return switch wanted {
			case Of(head, _, text) if (nullableInner(wanted) != null): Of(head, [inner ?? given], text);
			case Of(head, args, _) if (inner != null): sameHead(head, args.length, inner) ? inner : reread(wanted, inner, reading);
			case Of(head, args, text): iterableElement(wanted, given, reading) ?? ancestorArguments(head, args.length, text, given, reading);
			case _: null;
		};
	}

	/** The type `term` wraps when it is the nullable wrapper applied to one; null otherwise. */
	private function nullableInner(term: TypeTerm): Null<TypeTerm> {
		return switch term {
			case Of(_, [inner], text) if (_nullable != null && NominalTypes.outerNominalOf(text, _typeSyntax) == _nullable): inner;
			case _: null;
		};
	}

	/**
	 * The end the head `path`, written in `file` at `at`, resolves to (`AbstractCasts.endIn`); where the cast graph models
	 * none, the one declaration it names (`TypeRefIndex.oneDeclaration`: a generic `typedef`, a std type each target's `_std`
	 * copy re-declares), so that every reading of one module meets one end. `Open` for anything else.
	 */
	private function headOf(path: String, file: FileInfo, at: Int): TypeEnd {
		final end: TypeEnd = _casts.endIn(path, file, at, []);
		final one: Null<ResolvedType> = end.match(Open) ? TypeRefIndex.oneDeclaration(_refs.resolveTypeRefAll(path, file, at)) : null;
		return one == null ? end : Declared(one);
	}

	/**
	 * `given` read as the builtin `Iterable` `wanted` is: the element a std container iterates
	 * (`StructuralTypes.iterableElementIndex`), else the one its declaration's own `iterator()` yields (`iteratedElement`);
	 * null for any other pair.
	 */
	private function iterableElement(wanted: TypeTerm, given: TypeTerm, reading: FileInfo): Null<TypeTerm> {
		return switch [wanted, given] {
			case [Of(head, [_], text), Of(givenHead, args, givenText)] if (_structural.isBuiltinIterable(text)):
				final decl: Null<ResolvedType> = switch givenHead {
					case Declared(r): r;
					case _: null;
				};
				final at: Null<Int> = _structural.iterableElementIndex(text, givenText, decl, _elementParams);
				final element: Null<TypeTerm> = if (at != null)
					args[at]
				else if (decl == null)
					null
				else
					iteratedElement(decl, args, reading);
				element == null ? null : Of(head, [element], text);
			case _: null;
		};
	}

	/**
	 * The element a value of the declaration `r`, applied to the arguments `args`, iterates through its own `iterator()`
	 * (`StructuralTypes.iteratorElement`), the declaring type's parameters bound through `r`'s chain and `args`; null for none,
	 * and where the element, or what `r`'s chain passes to the declaring type, does not read alike in `reading`.
	 */
	private function iteratedElement(r: ResolvedType, args: Array<TypeTerm>, reading: FileInfo): Null<TypeTerm> {
		final found: Null<IteratorElement> = _structural.iteratorElement(r, _abstractKinds);
		final texts: Array<String> = [];
		for (a in args) switch a {
			case Of(_, _, text), Opaque(text, []):
				texts.push(text);
			case _:
				return null;
		}
		if (found == null) return null;
		final host: ResolvedType = found.host;
		final scope: Array<String> = host.type.typeParamNames.concat(found.member.typeParamNames);
		final passed: Array<String> = AncestorTable.same(r, host) ? [] : _ancestors.argumentsTo(r, host) ?? [];
		final alike: Bool = _refs.readsAlike(found.text, host.file, reading, scope, _typeSyntax)
			&& passed.foreach(p -> _refs.readsAlike(p, r.file, reading, r.type.typeParamNames, _typeSyntax));
		final bound: Null<String> = alike
			? _ancestors.boundType(r, host, texts, found.text, found.member.declFrom, found.member.typeParamNames)
			: null;
		return bound == null ? null : termOf(bound, host.file, found.member.declFrom, []);
	}

	/**
	 * `given`, a declaration with no type parameter, read as its ancestor `head` (`arity` arguments, written `text`): what
	 * its chain passes to the ancestor's type parameters, read where the chain writes them; null for any other pair, and
	 * where one of them does not read alike in `reading`.
	 */
	private function ancestorArguments(head: TypeEnd, arity: Int, text: String, given: TypeTerm, reading: FileInfo): Null<TypeTerm> {
		return switch [head, given] {
			case [Declared(ancestor), Of(Declared(start), [], _)] if (start.type.typeParamArity == 0):
				final passed: Null<Array<String>> = _ancestors.argumentsTo(start, ancestor);
				passed == null || passed.length != arity || !passed.foreach(p -> _refs.readsAlike(p, start.file, reading, [], _typeSyntax))
					? null
					: Of(head, [for (p in passed) termOf(p, start.file, start.type.span.from, [])], text);
			case _: null;
		};
	}

	/** Whether `term` is the head `head` applied to `arity` arguments. */
	private static function sameHead(head: TypeEnd, arity: Int, term: TypeTerm): Bool {
		return switch term {
			case Of(h, args, _):
				args.length == arity && AbstractCasts.same(head, h);
			case _: false;
		};
	}

}
