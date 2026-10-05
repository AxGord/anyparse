package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.MemberReach;
import anyparse.query.MemberTouchScan;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Whether a key-value loop may drop its key and iterate the values alone — the one question `redundant-map-iter-key`
 * and `unused-loop-binder` ask before either drops a key.
 *
 * Two kinds of container qualify. An `Array` or a `List` (`NominalTypes.valueIterationProvable`) walks one index or
 * node chain in both iterators, so the two agree whatever the body does: `Provable`. A map
 * (`NominalTypes.keyedIterationContainer`) re-reads each value BY KEY in its key-value iterator, so the two agree —
 * measured on `--interp`, js and hxcpp, docs/decisions.md — only while nothing changes the map: an entry the body
 * removes reads `null` through the key, its stale value through `iterator()`, and a value the body replaces reads new
 * through one and old through the other. Such a loop is `Keyed`, and its fix asks `MemberReach` whether the body can
 * change the map (`keyedDecline`); the report never does, since that question builds a call graph.
 */
@:nullSafety(Strict)
final class ValueIterationProof {

	/** The head of the decline note of a key drop refused because the body may change the map. */
	public static inline final KEYED_DECLINE: String =
		'the body may change the map, whose keyValueIterator() re-reads each value by key while iterator() does not';

	/** What the loop over `iterable` is, as far as its type and the file's text can tell. */
	public static function kindOf(
		iterable: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String,
		importMap: Map<String, String>
	): ValueIteration {
		return if (NominalTypes.valueIterationProvable(iterable, root, shape, declaredTypes, index, file, importMap))
			Provable
		else if (NominalTypes.keyedIterationContainer(iterable, root, shape, declaredTypes, index, file, importMap))
			Keyed
		else
			Unprovable;
	}

	/**
	 * Why the key of a `Keyed` loop over `iterable` must stay, or null when `reach` proves that nothing `body` runs
	 * changes the map: no `set` / `remove` / `clear` / indexed write on it, by its name or through any alias, in the body
	 * or in anything it calls (`MemberReach.mayMutateNamed`). A local map is asked as one holding a map
	 * (`MemberTouchScan.mapMethods`). An iterable that is not a bare name is not one the question can follow.
	 */
	public static function keyedDecline(reach: MemberReach, file: String, iterable: QueryNode, body: Span, shape: RefShape): Null<String> {
		final name: Null<String> = iterable.name;
		final at: Null<Span> = iterable.span;
		if (iterable.kind != shape.identKind || name == null || at == null)
			return '$KEYED_DECLINE: the map is not named by a bare identifier';
		final result: ReachResult = reach.mayMutateNamed(file, name, at, body, MemberTouchScan.mapMethods(shape));
		return switch result {
			case Proven: null;
			case _: '$KEYED_DECLINE: ${reach.explain(result)}';
		};
	}

}

/** What a key-value loop's iterable lets its key drop rest on (`ValueIterationProof.kindOf`). */
enum ValueIteration {

	/** Both iterators walk one chain: the key may go. */
	Provable;

	/** A map: the key may go when nothing the body runs changes it (`ValueIterationProof.keyedDecline`). */
	Keyed;

	/** Neither is proved: the key stays. */
	Unprovable;

}
