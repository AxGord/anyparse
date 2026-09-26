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
	 * conditional member, a conditional `implements`) adds what the others lacked, and one recording another kind or extern
	 * flag makes it not `alike`.
	 */
	public static function type(into: TypeFact, from: TypeFact): Void {
		fields(into.fields, from.fields);
		for (m in from.meta) if (!into.meta.contains(m)) into.meta.push(m);
		for (i in from.interfaces) if (!into.interfaces.contains(i)) into.interfaces.push(i);
		if (into.kind != from.kind || into.isExtern != from.isExtern) into.alike = false;
	}

	/** `into` with every field of `from` it lacks, and every type `from` gives a field it has that it does not hold yet. */
	public static function fields(into: Array<FieldDeclFact>, from: Array<FieldDeclFact>): Void {
		for (f in from) {
			final known: Null<FieldDeclFact> = into.find(k -> k.name == f.name && k.isStatic == f.isStatic);
			if (known == null)
				into.push(f)
			else if (!known.types.contains(f.type))
				known.types.push(f.type);
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
		final work: Array<String> = [from];
		while (work.length > 0) {
			final next: String = work.pop() ?? '';
			for (to in edges[next] ?? []) if (to != from && !out.contains(to)) {
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

}
