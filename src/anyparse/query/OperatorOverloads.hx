package anyparse.query;

import anyparse.query.AbstractCasts.TypeEnd;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;

/**
 * The operator overload an abstract's `@:op` members select for a binary operator, and the type it yields
 * (`docs/typing-service.md`, step T4b; Haxe 4.3.7 `operators.ml`, `try_abstract_binop_overloads` and
 * `find_abstract_binop_overload`). The compiler asks the LEFT operand's abstract first and the right one's after it; in
 * each it walks the overloads of the operator in declaration order, and the first one taking the operands binds: on the
 * left, a first parameter of exactly the left operand's type (`type_eq EqStrict`) and a second the right operand casts to
 * (`cast_or_unify`), on the right the mirror of that, and for a `@:commutative` one the operands swapped too.
 *
 * A positive whitelist, like every answer of the typing service: an answer is a decided overload, the same return type in
 * every `#if` branch of the abstract (`AbstractCasts.branchMembers`). A step that is not decided — an operand the cast
 * graph does not model, a candidate with type parameters, an instance or a guarded
 * overload (an instance one takes one parameter), a build macro that may add
 * one, a fit `Unification.casts` cannot tell, branches that disagree — answers null, and so does the language's own
 * operator (no overload taken): its type is the caller's to give. No answer is remembered: the question is keyed by two
 * ends and an operator, and walks a few members of one declaration.
 */
@:nullSafety(Strict)
final class OperatorOverloads {

	/** The cast graph: the ends a parameter type resolves to, the members of each branch. */
	private final _casts: AbstractCasts;

	/** Whether an operand casts to a parameter (`Unification.casts`). */
	private final _unification: Unification;

	/** The grammar's abstract declaration kinds (`RefShape.underlyingThisTypeKinds`). */
	private final _abstractKinds: Array<String>;

	/** The annotation of an overload taking its operands in either order (`RefShape.commutativeOperatorMetaName`), or null. */
	private final _commutativeMeta: Null<String>;

	/** Built once by the owning `TypingService`. */
	public function new(casts: AbstractCasts, unification: Unification, shape: RefShape) {
		_casts = casts;
		_unification = unification;
		_abstractKinds = shape.underlyingThisTypeKinds ?? [];
		_commutativeMeta = shape.commutativeOperatorMetaName;
	}

	/**
	 * The type the binary operator of node kind `kind` yields over a left operand of type `left` and a right one of type
	 * `right` when an abstract's overload decides it: the overload's written return type, its end and the declaration
	 * writing it. Null for the language's own operator and for every answer not decided.
	 */
	public function binaryResult(kind: String, left: TypeEnd, right: TypeEnd): Null<OperatorResult> {
		// the right operand's abstract is asked only when the left one's takes no overload (`try_abstract_binop_overloads`)
		final picked: OverloadPick = switch selection(left, kind, left, right, true) {
			case NoneTaken: selection(right, kind, left, right, false);
			case other: other;
		};
		return switch picked {
			case Chosen(result): result;
			case _: null;
		};
	}

	/** Whether the overload `m` takes its operands in either order. */
	private inline function isCommutative(m: MemberInfo): Bool {
		return _commutativeMeta != null && m.metaNames.contains(_commutativeMeta);
	}

	/**
	 * The overload of `kind` the abstract `owner` selects for the operands `left` and `right`, asked as the left operand's
	 * abstract (`onLeft`) or as the right one's: every branch's selection, which must agree.
	 */
	private function selection(owner: TypeEnd, kind: String, left: TypeEnd, right: TypeEnd, onLeft: Bool): OverloadPick {
		switch owner {
			case Declared(decl) if (_abstractKinds.contains(decl.type.kind)):
				final branches: Null<Array<Array<MemberInfo>>> = _casts.branchMembers(decl);
				if (branches == null || decl.type.hasBuild || decl.type.hasAutoBuild) return Undecided;
				var agreed: Null<OverloadPick> = null;
				for (members in branches) {
					final one: OverloadPick = branchSelection(decl, members, kind, left, right, onLeft);
					if (one.match(Undecided) || agreed != null && !samePick(agreed, one)) return Undecided;
					agreed = one;
				}
				return agreed ?? Undecided;
			case Open, Param(_), Applied(_, _):
				return Undecided;
			case _:
				return NoneTaken;
		}
	}

	/** The overload of `kind` one branch of `decl`, declaring `members`, selects: the first candidate taking the operands. */
	private function branchSelection(
		decl: ResolvedType, members: Array<MemberInfo>, kind: String, left: TypeEnd, right: TypeEnd, onLeft: Bool
	): OverloadPick {
		for (m in members) if (m.operatorOverloads.contains(kind)) {
			final params: Null<Array<TypeEnd>> = candidateParams(decl, m);
			final written: Null<String> = m.returnSource;
			if (params == null || written == null) return Undecided;
			final returned: String = written;
			var taken: ArgumentFit = onLeft ? takes(left, params[0], right, params[1]) : takes(right, params[1], left, params[0]);
			// a `@:commutative` overload is tried with the operands swapped, the right one in the first parameter
			if (taken == Misfits && isCommutative(m)) taken = takes(right, params[0], left, params[1]);
			// with no commutativity annotation to read, a misfit may still be taken swapped
			if (taken == MayFit || taken == Misfits && _commutativeMeta == null) return Undecided;
			if (taken == Fits) {
				final end: TypeEnd = _casts.writtenEnd(returned, decl, m.declFrom, []);
				return end.match(Open) ? Undecided : Chosen({ end: end, text: returned, host: decl });
			}
		}
		return NoneTaken;
	}

	/**
	 * The ends of the two parameters of the overload `m` of `decl`: null for one the walk does not model — one under `#if`,
	 * with type parameters, a signature overload, one with a parameter type the cast graph does not model, and one not
	 * taking exactly two parameters: an instance overload takes one, its `this` the left operand.
	 */
	private function candidateParams(decl: ResolvedType, m: MemberInfo): Null<Array<TypeEnd>> {
		if (m.guarded || m.typeParamNames.length > 0 || m.isOverload || m.hasOverloadMeta) return null;
		if (m.paramTypeSources.length != 2) return null;
		final ends: Array<TypeEnd> = [];
		for (p in m.paramTypeSources) {
			if (p == null) return null;
			final end: TypeEnd = _casts.writtenEnd(p, decl, m.declFrom, []);
			if (end.match(Open)) return null;
			ends.push(end);
		}
		return ends;
	}

	/**
	 * Whether a candidate takes the operand `exact` for a parameter of type `exactParam` it must equal (`type_eq EqStrict`),
	 * and the operand `converted` for one of type `convertedParam` it is cast to.
	 */
	private function takes(exact: TypeEnd, exactParam: TypeEnd, converted: TypeEnd, convertedParam: TypeEnd): ArgumentFit {
		if (exact.match(Open)) return MayFit;
		return AbstractCasts.same(exact, exactParam) ? _unification.casts(converted, convertedParam) : Misfits;
	}

	/** Whether two branches pick alike: both take none, or both an overload returning one end. */
	private static function samePick(a: OverloadPick, b: OverloadPick): Bool {
		return switch [a, b] {
			case [NoneTaken, NoneTaken]: true;
			case [Chosen(x), Chosen(y)]: AbstractCasts.same(x.end, y.end);
			case _: false;
		};
	}

}

/** The type an operator overload yields (`OperatorOverloads.binaryResult`). */
typedef OperatorResult = {

	/** The type the overload's declaration returns, resolved where it is written. */
	final end: TypeEnd;

	/** The return type as the overload writes it. */
	final text: String;

	/** The abstract declaring the overload, in whose file `text` is written. */
	final host: ResolvedType;

}

/** What one abstract's overloads pick for an operator: an overload, none (the language's own operator), or no answer. */
private enum OverloadPick {

	/** An overload binds the operands; what it yields. */
	Chosen(result: OperatorResult);

	/** No overload binds them: the language's operator, or the other operand's abstract, is asked next. */
	NoneTaken;

	/** Whether one binds is not decided. */
	Undecided;

}
