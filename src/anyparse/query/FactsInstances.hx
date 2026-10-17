package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.InstantiationFact;
import anyparse.query.CompilerFacts.TypeFact;

using Lambda;

/**
 * The types each type parameter is bound to, read off the compiler's facts once: by every type written with arguments
 * — a value of a type parameter of a class lives in an instance of it, which some code types — and by every
 * instantiation the compiler chose for a generic method (`InstantiationFact`), its declared type matched against the
 * applied one.
 *
 * Its own module rather than more of `FactsEscapes` because it is a separate analysis with its own state: it reads
 * every type text of the table, while the escape walk asks it only what a value of one parameter may be (`boundTo`),
 * and whether the answer can be trusted (`unread`, `unresolved`).
 */
@:nullSafety(Strict)
final class FactsInstances {

	/**
	 * Whether a type string the facts hold did not read: an instantiation may then be missing from what `boundTo`
	 * answers. Settled by the first `boundTo`.
	 */
	public var unread(default, null): Bool = false;

	private final _table: CompilerFacts;

	/** Type parameter (`pack.Type.T`, `method.T`) -> the types a value bound to it may have, by their text; built on first need. */
	private var _instances: Null<Map<String, Map<String, FactsType>>> = null;

	/**
	 * The type parameters a generic method's declared type holds where the type the compiler instantiated it at has no part
	 * that matches: what they stand for there is not known.
	 */
	private final _unresolved: Map<String, Bool> = [];

	public function new(table: CompilerFacts) {
		_table = table;
	}

	/** The types a value of the type parameter `path` may have, by their text; null when no instantiation binds it. */
	public function boundTo(path: String): Null<Map<String, FactsType>> {
		return instances()[path];
	}

	/** Whether an instantiation leaves `path` unknown (`_unresolved`); settled by the first `boundTo`. */
	public inline function unresolved(path: String): Bool {
		return _unresolved.exists(path);
	}

	/**
	 * Every type parameter the facts bind, with the types it is bound to: by each type written with arguments — a value
	 * of a type parameter of a class lives in an instance of it, which some code types — and by each instantiation the
	 * compiler chose for a generic method (`InstantiationFact`), its declared type matched against the applied one. A
	 * parameter a declared type holds where the applied one has no part that matches is unresolved (`_unresolved`).
	 */
	private function instances(): Map<String, Map<String, FactsType>> {
		final held: Null<Map<String, Map<String, FactsType>>> = _instances;
		if (held != null) return held;
		final out: Map<String, Map<String, FactsType>> = [];
		final scanned: Map<String, Bool> = [];
		for (id in _table.nodeIds()) {
			final n: Null<FactNode> = _table.node(id);
			if (n == null) continue;
			for (type in nodeTypeTexts(n)) readInstances(out, scanned, type);
			for (g in n.instantiations) unifyInstantiation(out, g);
		}
		for (id in _table.typeIds()) {
			final fact: Null<TypeFact> = _table.type(id);
			if (fact != null) for (type in typeFactTexts(fact)) readInstances(out, scanned, type);
		}
		_instances = out;
		return out;
	}

	/** Every type text `n`'s facts spell, in the order `instances` reads them. */
	private static function nodeTypeTexts(n: FactNode): Array<Null<String>> {
		final texts: Array<Null<String>> = [n.signature];
		for (p in n.params) texts.push(p.type);
		for (v in n.variants) {
			texts.push(v.signature);
			for (p in v.params) texts.push(p.type);
		}
		for (c in n.calls) {
			texts.push(c.receiver);
			texts.push(c.result);
			texts.push(c.signature);
		}
		for (x in n.news) texts.push(x.instance);
		for (f in n.fields) {
			texts.push(f.receiver);
			texts.push(f.type);
		}
		for (e in n.elementWrites) texts.push(e.receiver);
		for (f in n.flows) {
			texts.push(f.from);
			texts.push(f.to);
		}
		for (h in n.handed) {
			texts.push(h.from);
			texts.push(h.to);
		}
		for (s in n.strings) texts.push(s.operand);
		for (i in n.iterations) {
			texts.push(i.binder);
			texts.push(i.iterated);
		}
		for (v in n.vars) texts.push(v.type);
		for (r in n.reads) texts.push(r.type);
		return texts;
	}

	/** Every type text a type's own facts spell: its fields, supertypes, targets, underlying types, constructors. */
	private static function typeFactTexts(fact: TypeFact): Array<Null<String>> {
		final texts: Array<Null<String>> = [for (f in fact.fields) for (t in f.types) t];
		texts.push(fact.superClass);
		for (i in fact.interfaces) texts.push(i);
		for (t in fact.targets) texts.push(t);
		for (t in fact.underlying) texts.push(t);
		for (c in fact.constructors) texts.push(c.type);
		texts.push(fact.genericOf);
		return texts;
	}

	/** Read one type text once, binding every type argument it applies; a text that does not read marks the table unread. */
	private function readInstances(out: Map<String, Map<String, FactsType>>, scanned: Map<String, Bool>, type: Null<String>): Void {
		if (type == null || scanned.exists(type)) return;
		scanned[type] = true;
		final read: Null<FactsType> = FactsTypeTree.read(type);
		if (read == null)
			unread = true
		else
			scanInstances(out, read);
	}

	/** Bind each argument a `Named` type applies to its declaring type's parameter, through every nested type. */
	private function scanInstances(out: Map<String, Map<String, FactsType>>, t: FactsType): Void {
		switch t {
			case Named(id, args):
				final fact: Null<TypeFact> = _table.type(id);
				if (fact != null && fact.params.length == args.length) for (i => name in fact.params)
					bindInstance(out, '$id.$name', args[i]);
				for (a in args) scanInstances(out, a);
			case Function(args, result):
				for (a in args) scanInstances(out, a.type);
				scanInstances(out, result);
			case Structure(fields):
				for (f in fields) scanInstances(out, f.type);
			case Parameter(_), Unknown:
		}
	}

	/** Record `t` as one instance of the type parameter `path`. */
	private static function bindInstance(out: Map<String, Map<String, FactsType>>, path: String, t: FactsType): Void {
		final types: Map<String, FactsType> = out[path] ?? [];
		out[path] = types;
		types['$t'] = t;
	}

	/** Unify a generic instantiation's declared type with the applied one; either text failing to read marks the table unread. */
	private function unifyInstantiation(out: Map<String, Map<String, FactsType>>, g: InstantiationFact): Void {
		final declared: Null<FactsType> = FactsTypeTree.read(g.declared);
		final applied: Null<FactsType> = FactsTypeTree.read(g.applied);
		if (declared == null || applied == null)
			unread = true
		else
			unifyInstance(out, declared, applied);
	}

	/**
	 * Bind each type parameter of `declared` to the part of `applied` in its place; a shape that does not line up
	 * leaves its parameters unresolved.
	 */
	private function unifyInstance(out: Map<String, Map<String, FactsType>>, declared: FactsType, applied: FactsType): Void {
		switch [declared, applied] {
			case [Parameter(path), _]:
				bindInstance(out, path, applied);
			case [Named(a, xs), Named(b, ys)] if (a == b && xs.length == ys.length):
				for (i in 0...xs.length) unifyInstance(out, xs[i], ys[i]);
			case [Function(xs, x), Function(ys, y)] if (xs.length == ys.length):
				for (i in 0...xs.length) unifyInstance(out, xs[i].type, ys[i].type);
				unifyInstance(out, x, y);
			case [Structure(xs), Structure(ys)]:
				for (f in xs) {
					final other: Null<FactsField> = ys.find(g -> g.name == f.name);
					if (other == null)
						unresolveParameters(f.type)
					else
						unifyInstance(out, f.type, other.type);
				}
			case _:
				unresolveParameters(declared);
		}
	}

	/** Mark every type parameter `declared` mentions as unresolved. */
	private function unresolveParameters(declared: FactsType): Void {
		switch declared {
			case Parameter(path):
				_unresolved[path] = true;
			case Named(_, args):
				for (a in args) unresolveParameters(a);
			case Function(args, result):
				for (a in args) unresolveParameters(a.type);
				unresolveParameters(result);
			case Structure(fields):
				for (f in fields) unresolveParameters(f.type);
			case Unknown:
		}
	}

}
