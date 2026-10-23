package anyparse.query;

import anyparse.query.TypeTerm.TypeEnd;

using Lambda;

/**
 * The variables of ONE inference — the type parameters of one call — and the type unification binds each to
 * (`docs/typing-service.md`, T7a; 4.3.7 `tUnification.ml`, `Monomorph`). A cell takes the type of the first unification
 * that meets it free and keeps it (`link`); a second binding to a type not known to be that one POISONS the cell, which
 * then answers nothing — the compiler would have failed there, or cast. A free cell answers nothing either. Instance state
 * of one inference: built for it and dropped with it, never shared (`docs/design-principles.md` § 2).
 */
@:nullSafety(Strict)
final class Monomorphs {

	/** Each cell's representative: a root is its own. */
	private final _parent: Array<Int> = [];

	/** The type each root is bound to; null while it is free. */
	private final _bound: Array<Null<TypeTerm>> = [];

	/** Whether each root is poisoned. */
	private final _poisoned: Array<Bool> = [];

	/** One inference's cells, none yet. */
	public function new() {}

	/** A new free cell. */
	public function fresh(): Int {
		final id: Int = _parent.length;
		_parent.push(id);
		_bound.push(null);
		_poisoned.push(false);
		return id;
	}

	/** The representative of the cell `id`, the path to it compressed. */
	public function find(id: Int): Int {
		var root: Int = id;
		while (_parent[root] != root) root = _parent[root];
		var at: Int = id;
		while (at != root) {
			final next: Int = _parent[at];
			_parent[at] = root;
			at = next;
		}
		return root;
	}

	/** The type the cell `id` is bound to; null for a free or a poisoned cell. */
	public function resolved(id: Int): Null<TypeTerm> {
		final root: Int = find(id);
		return _poisoned[root] ? null : _bound[root];
	}

	/** Poison the cell `id`: whatever binds it, it answers nothing. */
	public function poison(id: Int): Void {
		_poisoned[find(id)] = true;
	}

	/**
	 * Bind the cell `id` to `term`: a free cell takes it, a bound one keeps its type and is poisoned when `term` is not
	 * known to be that type (`same`), another cell is merged with it, and a term mentioning the cell itself poisons it
	 * (`link`'s occurs check).
	 */
	public function bind(id: Int, term: TypeTerm): Void {
		final root: Int = find(id);
		switch term {
			case Mono(other):
				merge(root, find(other));
			case _ if (mentions(term, root)):
				_poisoned[root] = true;
			case _:
				final held: Null<TypeTerm> = _bound[root];
				if (held == null)
					_bound[root] = term;
				else if (!same(held, term))
					_poisoned[root] = true;
		}
	}

	/**
	 * Unify the type a position wants with the type the value given there has, binding the cells `wanted` mentions
	 * (`unify`, the given type on the left): a cell takes the given type; a head applied to arguments meets the given type
	 * of the same head argument by argument (type arguments are invariant). A given type of another head is first read as
	 * one of the wanted head, its arguments in the wanted's order, by `reread` — the language's arcs: a supertype, a
	 * nullable wrapper, a structural type —; where it reads none, every cell `wanted` mentions is poisoned, since the given
	 * type may bind it some way not modelled.
	 */
	public function unify(wanted: TypeTerm, given: TypeTerm, reread: (wanted:TypeTerm, given:TypeTerm) -> Null<TypeTerm>): Void {
		switch wanted {
			case Mono(id):
				bind(id, given);
			case Of(_, _, _) if (cellsOf(wanted).length == 0):
			case Of(head, args, _):
				// what `reread` answers is the given type read as one of the wanted head, whatever end that head resolves to
				final read: Null<TypeTerm> = sameHead(head, args.length, given) ? given : reread(wanted, given);
				switch read {
					case Of(_, givenArgs, _) if (givenArgs.length == args.length):
						for (i => arg in args) unify(arg, givenArgs[i], reread);
					case _:
						for (m in cellsOf(wanted)) poison(m);
				}
			case Opaque(_, monos):
				for (m in monos) poison(m);
		}
	}

	/** Whether `a` and `b` are known to be one type: one head applied to such arguments, or one cell. */
	public function same(a: TypeTerm, b: TypeTerm): Bool {
		return switch [a, b] {
			case [Mono(x), Mono(y)]: find(x) == find(y);
			case [Of(x, xs, _), Of(y, ys, _)]:
				AbstractCasts.same(x, y) && xs.length == ys.length && [for (i in 0...xs.length) i].foreach(i -> same(xs[i], ys[i]));
			case _: false;
		};
	}

	/** Merge the roots `a` and `b` into one cell: poisoned if either is or their bindings are not one type. */
	private function merge(a: Int, b: Int): Void {
		if (a == b) return;
		final held: Null<TypeTerm> = _bound[a];
		final other: Null<TypeTerm> = _bound[b];
		_parent[b] = a;
		if (_poisoned[b] || held != null && other != null && !same(held, other))
			_poisoned[a] = true;
		else if (held == null)
			_bound[a] = other;
	}

	/** Whether `term` mentions the root `root`. */
	private function mentions(term: TypeTerm, root: Int): Bool {
		return cellsOf(term).exists(m -> find(m) == root);
	}

	/** The cells `term` mentions. */
	public static function cellsOf(term: TypeTerm): Array<Int> {
		return switch term {
			case Mono(id): [id];
			case Of(_, args, _): [for (a in args) for (m in cellsOf(a)) m];
			case Opaque(_, monos): monos.copy();
		};
	}

	/** Whether `term` is the head `head` applied to `arity` arguments. */
	private static function sameHead(head: TypeEnd, arity: Int, term: Null<TypeTerm>): Bool {
		return switch term {
			case Of(h, args, _):
				args.length == arity && AbstractCasts.same(head, h);
			case _: false;
		};
	}

}
