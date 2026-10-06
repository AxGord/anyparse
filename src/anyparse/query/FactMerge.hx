package anyparse.query;

import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FactSignature;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.TypeFact;
import haxe.Json;

using Lambda;

/** How `CompilerFacts` assembles its table: records made into facts, and a second configuration's facts joined to the first's. */
@:nullSafety(Strict)
final class FactMerge {

	/**
	 * `into` joined by `from`, another configuration's record of the same type: a configuration that typed more of it (a
	 * conditional member, a conditional `implements`, another typedef target) adds what the others lacked, and one
	 * recording another kind or extern flag makes it not `alike`.
	 */
	public static function type(into: TypeFact, from: TypeFact): Void {
		fields(into.fields, from.fields);
		for (m in from.meta) if (!into.meta.contains(m)) into.meta.push(m);
		absent(into.code, from.code);
		absent(into.interfaces, from.interfaces);
		absent(into.targets, from.targets);
		absent(into.underlying, from.underlying);
		for (c in from.constructors) if (!into.constructors.exists(k -> k.name == c.name && k.type == c.type)) into.constructors.push(c);
		if (into.kind != from.kind || into.isExtern != from.isExtern) into.alike = false;
	}

	/**
	 * `into` with every field of `from` it lacks, and every kind, type and overload count `from` gives a field it has that
	 * it does not hold yet.
	 */
	public static function fields(into: Array<FieldDeclFact>, from: Array<FieldDeclFact>): Void {
		for (f in from) {
			final known: Null<FieldDeclFact> = into.find(k -> k.name == f.name && k.isStatic == f.isStatic);
			if (known == null)
				into.push(f)
			else {
				for (k in f.kinds) if (!known.kinds.contains(k)) known.kinds.push(k);
				if (!known.types.contains(f.type)) known.types.push(f.type);
				for (n in f.overloads) if (!known.overloads.contains(n)) known.overloads.push(n);
				absent(known.code, f.code);
			}
		}
	}

	/** `into` with the signature `signature` and parameters `params`, unless an entry already holds both. */
	public static function variant(into: Array<FactSignature>, signature: String, params: Array<{ name: String, type: String }>): Void {
		final key: String = Json.stringify(params);
		if (!into.exists(v -> v.signature == signature && Json.stringify(v.params) == key))
			into.push({ signature: signature, params: params });
	}

	/** Every node `edges` reaches from `from`, directly or not, `from` itself excepted. */
	public static function closure(edges: Map<String, Array<String>>, from: String): Array<String> {
		final out: Array<String> = [];
		// beside `out`, whose order is the answer: an `out.contains` per edge was quadratic over openfl's display-list subtypes
		final reached: Map<String, Bool> = [];
		final work: Array<String> = [from];
		while (work.length > 0) {
			final next: String = work.pop() ?? '';
			for (to in edges[next] ?? []) if (to != from && !reached.exists(to)) {
				reached[to] = true;
				out.push(to);
				work.push(to);
			}
		}
		return out;
	}

	/** Every record of `records` whose position resolves and is `fresh`, made into a fact and appended to `into`. */
	public static function collect<R, F>(
		records: Null<Array<R>>, position: (R) -> Null<FactPos>, fresh: (Any, FactPos) -> Bool, make: (R, FactPos) -> F, into: Array<F>
	): Void {
		if (records == null) return;
		for (record in records) {
			final where: Null<FactPos> = position(record);
			if (where != null && fresh(record, where)) into.push(make(record, where));
		}
	}

	/** Add to `into` each of `from` it does not hold yet. */
	public static function absent<T>(into: Array<T>, from: Array<T>): Void {
		for (x in from) if (!into.contains(x)) into.push(x);
	}

}
