package anyparse.query;

import anyparse.query.CompilerFacts.ArgumentFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.ParamUse;
import anyparse.query.CompilerFacts.TypeFact;

using Lambda;

/**
 * What the code a value is handed to as an argument does with it, read off the compiler facts (`FactNode.paramUses`):
 * every use the reads of the parameter make, in every method the call may run, and — where such a read hands the value
 * on as an argument in turn — the uses the method it is handed to makes, to a fixpoint (a recursion meets a parameter it
 * already answered for, which adds nothing). The uses are of the parameter's own vocabulary (`FieldFact.use`), so the
 * caller reads them as it reads its own accesses of the value: a parameter that is only iterated, indexed, compared or
 * called with the value's own readers keeps nothing of it, and one stored, returned, captured by a nested function or
 * handed to a call the facts do not follow lets it escape.
 *
 * A POSITIVE list of the methods answered for: one a class or an abstract's implementation class declares with a body
 * (`method` or `inline`, no overload, no target code pasted around it, in a type every configuration types alike and
 * none as an extern), whose node the facts hold whole — no marker but a splice's, no target-language code in it or in
 * a function nested in it (which may name the parameter in a text no read records), one parameter list in every
 * configuration, and the parameter's uses recorded by each. A call on an instance may run the method of any subclass
 * of the declaring type that declares it, and of each class a subtype inherits it from (a class implementing an
 * interface may take the method from a superclass outside it): each must be answered for, and no subtype
 * may be an extern, whose target code may override what it does not declare. Anything else answers null.
 * Settled once per argument and kept for the table's life (`FactsView.argumentUses`).
 */
@:nullSafety(Strict)
final class ArgumentUses {

	/** The access of a call of a static field (`CallFact.access`): the declared body is the one that runs. */
	private static inline final STATIC_ACCESS: String = 'FStatic';

	/** The access of a call of an instance method (`CallFact.access`): an override may run instead. */
	private static inline final INSTANCE_ACCESS: String = 'FInstance';

	/** The field kinds a method that runs its declared body has (`TypedFactsProbe`). */
	private static final BODIED_KINDS: Array<String> = ['method', 'inline'];

	/** The type kinds whose methods have bodies (`TypeFact.kind`): a class, an abstract's implementation class. */
	private static final BODIED_TYPES: Array<String> = ['class', 'impl'];

	/** The kind of an interface, which declares a method and runs none (`TypeFact.kind`). */
	private static inline final INTERFACE_KIND: String = 'interface';

	private final _table: CompilerFacts;

	/** Argument key -> the uses the value meets, or null when the facts do not answer; settled once. */
	private final _settled: Map<String, Null<Array<ParamUse>>> = [];

	public function new(table: CompilerFacts) {
		_table = table;
	}

	/**
	 * Every use the value handed as `argument` meets in the code it is handed to, none of them a hand-off; null when some
	 * method it may reach is none the facts answer for (see the type doc).
	 */
	public function uses(argument: ArgumentFact): Null<Array<ParamUse>> {
		final asked: String = key(argument);
		if (_settled.exists(asked)) return _settled[asked];
		final met: Null<Array<ParamUse>> = followed(argument);
		_settled[asked] = met;
		return met;
	}

	/** `uses`, unsettled: the parameters `argument` reaches, walked once each. */
	private function followed(argument: ArgumentFact): Null<Array<ParamUse>> {
		final out: Array<ParamUse> = [];
		final seen: Array<String> = [];
		final work: Array<ArgumentFact> = [argument];
		while (work.length > 0) {
			final next: Null<ArgumentFact> = work.pop();
			if (next == null) return null;
			final at: String = key(next);
			if (seen.contains(at)) continue;
			seen.push(at);
			final bodies: Null<Array<FactNode>> = runs(next);
			if (bodies == null) return null;
			for (n in bodies) {
				final uses: Null<Array<Array<ParamUse>>> = n.paramUses;
				if (uses == null || next.index >= uses.length) return null;
				for (u in uses[next.index]) {
					final onward: Null<ArgumentFact> = u.argument;
					if (onward != null)
						work.push(onward)
					else if (!out.exists(o -> o.use == u.use && o.method == u.method))
						out.push(u);
				}
			}
		}
		return out;
	}

	/** The nodes a call of `argument`'s method may run, every one answered for; null when one is not. */
	private function runs(argument: ArgumentFact): Null<Array<FactNode>> {
		final dot: Int = argument.target.lastIndexOf('.');
		if (dot <= 0) return null;
		final owner: String = argument.target.substr(0, dot);
		final field: String = argument.target.substr(dot + 1);
		final onInstance: Bool = argument.access == INSTANCE_ACCESS;
		if (!onInstance && argument.access != STATIC_ACCESS) return null;
		final out: Array<FactNode> = [];
		final classes: Array<String> = [owner].concat(onInstance ? _table.subtypesOf(owner) : []);
		for (c in classes) {
			final type: Null<TypeFact> = _table.type(c);
			// target code may override what an extern subclass does not declare, and a type the builds disagree on is none
			if (type == null || type.isExtern || !type.alike) return null;
			// an interface declares the method and runs none: each class implementing it is among the subtypes
			if (type.kind == INTERFACE_KIND && onInstance) continue;
			final declaring: Null<String> = onInstance ? declarer(c, field) : c;
			if (declaring == null) return null;
			final node: Null<FactNode> = answered(declaring, field, !onInstance);
			if (node == null) return null;
			if (!out.contains(node)) out.push(node);
		}
		return out;
	}

	/** The class whose instance method `field` an object of the class `c` runs: `c` or the nearest superclass declaring it. */
	private function declarer(c: String, field: String): Null<String> {
		var at: Null<String> = c;
		final seen: Array<String> = [];
		while (at != null && !seen.contains(at)) {
			seen.push(at);
			final type: Null<TypeFact> = _table.type(at);
			if (type == null) return null;
			if (type.fields.exists(f -> f.name == field && !f.isStatic)) return at;
			final up: Null<String> = type.superClass;
			at = up == null ? null : CompilerFacts.baseId(up);
		}
		return null;
	}

	/** The node of the method `field` of the type `owner` declares, static or not, when the facts answer for it; null otherwise. */
	private function answered(owner: String, field: String, isStatic: Bool): Null<FactNode> {
		final type: Null<TypeFact> = _table.type(owner);
		if (type == null || !type.alike || type.isExtern || !BODIED_TYPES.contains(type.kind) || type.code.length > 0) return null;
		final declared: Null<FieldDeclFact> = type.fields.find(f -> f.name == field && f.isStatic == isStatic);
		if (
			declared == null || !declared.kinds.foreach(k -> BODIED_KINDS.contains(k)) || declared.overloads.exists(o -> o != 0)
			|| declared.code.length > 0
		)
			return null;
		final node: Null<FactNode> = _table.node('$owner.$field');
		return node == null || node.variants.length > 1 || node.paramUses == null || !whole(node, []) ? null : node;
	}

	/**
	 * Whether `node` and every function nested in it carry no marker but a splice's and no target-language code: what
	 * such code does with a parameter, named in its text, no read records.
	 */
	private function whole(node: FactNode, seen: Array<String>): Bool {
		if (seen.contains(node.id)) return true;
		seen.push(node.id);
		if (node.natives.length > 0 || FactMarkers.carries(node, m -> !m.match(InlineSite))) return false;
		for (child in node.fns) {
			final nested: Null<FactNode> = _table.node(child);
			if (nested == null || !whole(nested, seen)) return false;
		}
		return true;
	}

	private static inline function key(argument: ArgumentFact): String {
		return '${argument.target}|${argument.access}|${argument.index}';
	}

}
