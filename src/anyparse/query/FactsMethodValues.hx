package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.check.FactsTypeTree.FactsType;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.TypeFact;

using Lambda;

/**
 * Where `this` is what its method's class says it is, read off the compiler's facts under the truth (`FactsView.truth`):
 * a dispatch on an instance of the class declaring a method, or of a subclass, binds `this` in its code — unless the
 * program obtains the method as a function value and hands it to a call that runs a function with a receiver of its own
 * (`REBINDING_CALLS`): `Reflect.callMethod(o, f, args)` runs `f` with `o` as its `this` (js `apply`, hxcpp `__SetThis`,
 * neko `$call`), whatever object `o` is. Where no function any build typed calls one, splices one in or reads one as a
 * value, every `this` is what a dispatch bound.
 *
 * A method's value is obtained, in the code of any function any build typed — a library's as much as the project's — by:
 * - a field read that is not a call (`FieldFact`) naming it: a closure (`FClosure`, a `bind` included), a read by name on
 *   a value of no class (`FDynamic`) or on a structure (`FAnon`), or an instance read of a field some build declares a
 *   method (a `dynamic` one's value, `super`'s);
 * - a reflective call (`ReflectionFact`) that may read a member's value by name — every `Reflect`/`Type` member not listed
 *   in `MEMBERLESS_REFLECTION` — naming it by a literal, or by a name computed at run time.
 * A read off an object that cannot be an instance of the method's class or of a subclass obtains another method: the
 * object is what the facts type it, a subtype of that unless it is an object of exactly its class, and an instance that
 * escaped the type system (`ValueEscapes`) — the method's own class does as soon as its `this` is handed to a reflective
 * call, so a read off an object of no class may then obtain any of its methods. A reflective body spliced in whose name is lost
 * (`reflection-inlined`) and a fact lost to a stale file may obtain any method, and rebind any: no `this` is answered then; so may a
 * reflective member or class read as a value, unless the project declares the classes whose methods a name computed at run time may
 * obtain (`reflectiveMethodHolders`, `declaredHolders`). Then a read by such a name, and a reflective member or class read as a value,
 * which whatever calls it later hands one, obtains a method only off an object of a declared class, each matched by its own qualified
 * name (a subclass of one is declared by its own name or not at all), or off a declared class as a
 * value for a static. The declaration bounds methods only — a variable is read whatever it says — and a
 * name a literal spells still names its one member; a reflective class read as a value may also rebind.
 *
 * Once a rebinding call exists, only an instance method's (`method`) code is answered: a constructor or an initializer
 * runs with `this` bound by a class value, which the program reads in more ways than a field read. The stated assumption,
 * after `FactsEscapes` and one for the project and the libraries alike: target-language code reaches a member by a computed
 * name, and runs a function with a receiver it is handed, only inside the reflection whose call sites the facts record.
 */
@:nullSafety(Strict)
final class FactsMethodValues {

	/** The node kind of an instance or static method's body (`FactNode.kind`). */
	private static inline final METHOD_NODE: String = 'method';

	/** The kind of a typed class (`TypeFact.kind`). */
	private static inline final CLASS_KIND: String = 'class';

	/** What separates a nested function's id from its parent's (`TypedFactsWalk`): `<parent id>@<offset>`. */
	private static inline final NESTED_ID: String = '@';

	/** What ends a field node's id before an overload index (`~n`) or a uniqueness suffix (`#n`). */
	private static final ID_SUFFIXES: Array<String> = ['~', '#'];

	/** The field accesses whose read yields no instance method's value: a static's, an enum constructor's. */
	private static final VALUELESS_ACCESSES: Array<String> = ['FStatic', 'FEnum'];

	/** The access of a field read off a value of no class (`FieldFact.access`): its value is typed by nothing. */
	private static inline final DYNAMIC_ACCESS: String = 'FDynamic';

	/** The access of an instance field read (`FieldFact.access`): a method's value only when the field is a method. */
	private static inline final INSTANCE_ACCESS: String = 'FInstance';

	/** The access of a call of a method the compiler spliced in (`CallFact.access`). */
	private static inline final INLINED: String = 'inlined';

	/** The field kinds that are methods (`FieldDeclFact.kinds`). */
	private static final METHOD_KINDS: Array<String> = ['method', 'inline', 'dynamic'];

	/** The reflective calls that run a function with a receiver they are handed as its `this`. */
	private static final REBINDING_CALLS: Array<String> = ['Reflect.callMethod'];

	/** The classes whose members are reflection (`TypedFactsProbe`). */
	private static final REFLECTION_CLASSES: Array<String> = ['Reflect', 'Type'];

	/**
	 * The reflective members whose result never holds a member's value read off an object: they test, write, list names,
	 * compare, call (a called function's result is its own code's, which the facts read), or make and describe class and
	 * enum values. Any other `Reflect`/`Type` member may read one.
	 */
	private static final MEMBERLESS_REFLECTION: Array<String> = [
		'Reflect.hasField',
		'Reflect.setField',
		'Reflect.setProperty',
		'Reflect.deleteField',
		'Reflect.fields',
		'Reflect.isFunction',
		'Reflect.isObject',
		'Reflect.isEnumValue',
		'Reflect.compare',
		'Reflect.compareMethods',
		'Reflect.callMethod',
		'Reflect.makeVarArgs',
		'Type.getClass',
		'Type.getEnum',
		'Type.getSuperClass',
		'Type.getClassName',
		'Type.getEnumName',
		'Type.resolveClass',
		'Type.resolveEnum',
		'Type.createInstance',
		'Type.createEmptyInstance',
		'Type.createEnum',
		'Type.createEnumIndex',
		'Type.getInstanceFields',
		'Type.getClassFields',
		'Type.getEnumConstructs',
		'Type.typeof',
		'Type.enumEq',
		'Type.enumConstructor',
		'Type.enumParameters',
		'Type.enumIndex',
		'Type.allEnums'
	];

	/** The type of an enum as a value: it holds no instance of a class. */
	private static inline final ENUM_VALUE: String = 'Enum';

	/** The type of a class as a value: it holds its statics, no instance. */
	private static inline final CLASS_VALUE: String = 'Class';

	/** The type of an abstract as a value: it holds its statics, no instance. */
	private static inline final ABSTRACT_VALUE: String = 'Abstract';

	/** The kind of a typed enum (`TypeFact.kind`): its values are no object of a class. */
	private static inline final ENUM_KIND: String = 'enum';

	/** How deep `mayHold` reads through wrappers and type parameters before it answers that a value may be anything. */
	private static inline final MAX_DEPTH: Int = 8;

	/** The typed kinds a value of which is an object of a class (`TypeFact.kind`). */
	private static final OBJECT_KINDS: Array<String> = ['class', 'interface'];

	/** The catch-all type: a value of it is of no class. */
	private static inline final CATCH_ALL: String = 'Dynamic';

	/** The type any value unifies with: a value of it is of no class. */
	private static inline final ANY: String = 'Any';

	/** The nullable wrapper: a value of it is what it wraps. */
	private static inline final NULLABLE: String = 'Null';

	/** The type of a string: a reflective call's recorded literal may be its first argument, the object, not the name. */
	private static inline final STRING_TYPE: String = 'String';


	/** The marker of a node a fact of which lies in a file whose text the table no longer has. */
	private static inline final STALE_FOREIGN: String = 'stale-foreign';

	/** The marker of a node a `Reflect`/`Type` body was spliced into: that call, its name and its arguments are gone. */
	private static inline final REFLECTION_INLINED: String = 'reflection-inlined';

	private final _view: FactsView;
	private final _table: CompilerFacts;


	/** The types whose instances may have escaped the type system by their typed ids, or null for any (`ValueEscapes`). */
	private final _escaped: () -> Null<Array<String>>;

	/** What every function the builds typed obtains (`scan`), read once. */
	private var _reads: Null<MethodValueReads> = null;

	/**
	 * The classes a read by a name computed at run time may obtain a method of (`ReachProject.reflectiveMethodHolders`), as
	 * the patterns their globs make (`Glob.qualifiedNames`); null for any.
	 */
	private final _holders: Null<Array<EReg>>;

	/**
	 * `holders` are the globs the project declares every class whose methods a read by a computed name may obtain as values
	 * to match (`ReachProject.reflectiveMethodHolders`), null for any class.
	 */
	public function new(view: FactsView, escaped: () -> Null<Array<String>>, ?holders: Array<String>) {
		_view = view;
		_table = view.table;
		_escaped = escaped;
		_holders = holders?.map(Glob.qualifiedNames);
	}

	/**
	 * Whether `this` in the code of the facts node `holder` — a nested function's being its outermost enclosing field's,
	 * which it captures — is an object of the class declaring that field or of a subclass: the field is an instance method
	 * of a class the builds declare alike, and no function any of them typed may obtain it as a value (see the type doc).
	 */
	public function selfBound(holder: String): Bool {
		final reads: MethodValueReads = scan();
		if (reads.unknown != null) return false;
		// no call hands a function a receiver of its own: every `this` is what a dispatch bound
		if (!reads.rebinds) return true;
		final nested: Int = holder.indexOf(NESTED_ID);
		final root: String = nested < 0 ? holder : holder.substr(0, nested);
		final node: Null<FactNode> = _table.node(root);
		if (node == null || node.kind != METHOD_NODE || node.isStatic) return false;
		final owner: Null<TypeFact> = _table.type(node.owner);
		if (owner == null || owner.kind != CLASS_KIND || !owner.alike || owner.isExtern) return false;
		var name: String = root.substr(node.owner.length + 1);
		for (s in ID_SUFFIXES) {
			final cut: Int = name.indexOf(s);
			if (cut >= 0) name = name.substr(0, cut);
		}
		final hierarchy: Array<String> = [owner.id].concat(_table.subtypesOf(owner.id));
		final held: Array<String> = declaredHolders(hierarchy);
		return !(reads.named[name] ?? []).exists(r -> mayBeOf(r, hierarchy))
			&& (held.length == 0 || !reads.computed.exists(r -> mayBeOf(r, held)));
	}

	/**
	 * Whether a function any build typed may obtain the method `name` of an object of a class `hierarchy` names as a value
	 * of no type the program declares — a read of it off a value of no class (`FDynamic`), or a reflective read naming it or
	 * computing the name, on an object that may be one (`mayHold`) — or any read may obtain any method (`unknownReason`).
	 * Such a value may then reach a call of a value of any type. A `statics` method is read off its class as a value, any
	 * other off an instance. `escaped` and `bound` are `mayHold`'s.
	 */
	public function obtainedUntyped(
		name: String, hierarchy: Array<String>, escaped: Null<Array<String>>, bound: (path:String) -> Null<Array<FactsType>>, statics: Bool
	): Bool {
		final reads: MethodValueReads = scan();
		if (reads.unknown != null) return true;
		function may(r: MethodValueRead, of: Array<String>): Bool {
			final receiver: Null<String> = r.receiver;
			final read: Null<FactsType> = receiver == null ? null : FactsTypeTree.read(receiver);
			return r.typeless && (read == null || mayHold(read, r.exact, of, escaped, bound, statics, 0));
		}
		final held: Array<String> = declaredHolders(hierarchy);
		return (reads.named[name] ?? []).exists(r -> may(r, hierarchy)) || (held.length > 0 && reads.computed.exists(r -> may(r, held)));
	}

	/**
	 * The classes of `hierarchy` a read by a name computed at run time may obtain a method of: those the project declares
	 * (`_holders`), each by its own qualified name — a subclass of a declared class is declared by its own name or not at all
	 * — or all of them when it declares none.
	 */
	private function declaredHolders(hierarchy: Array<String>): Array<String> {
		final holders: Null<Array<EReg>> = _holders;
		return holders == null ? hierarchy : [for (id in hierarchy) if (holders.exists(p -> p.match(id))) id];
	}

	/**
	 * Whether a value of the type `t` may be an object of a class `hierarchy` names — of exactly the class it names, when
	 * `exact` — or, for `statics`, that class itself as a value. A class or an interface, an extern's included, holds an
	 * instance of it or of a subtype, and one that escaped (`escaped`, the escaped types by typed id, null for any), which may
	 * be in a place of any type; a class as a value (`Class<T>`, an abstract's `Abstract<T>`) holds that class; a place no
	 * class types — `Dynamic`, `Any`, a structure — holds an object, or a class as a value, that escaped (an escaped class
	 * value escapes its class, `FactsEscapes`): one no flow let leave the type system is in none. A type parameter holds what
	 * an instantiation binds it to (`bound`, null when that is not known); an enum value, an enum as a value and a function
	 * hold none. Any other type — an abstract, one the facts do not type — may hold either.
	 */
	private function mayHold(
		t: FactsType, exact: Bool, hierarchy: Array<String>, escaped: Null<Array<String>>, bound: (path:String) -> Null<Array<FactsType>>,
		statics: Bool, depth: Int
	): Bool {
		final left: Bool = escaped == null || escaped.exists(e -> hierarchy.contains(e));
		if (depth > MAX_DEPTH) return true;
		return switch t {
			case Named(NULLABLE, [inner]): mayHold(inner, exact, hierarchy, escaped, bound, statics, depth + 1);
			case Named(CLASS_VALUE | ABSTRACT_VALUE, [Named(id, _)]):
				statics && hierarchy.contains(id);
			case Named(CLASS_VALUE | ABSTRACT_VALUE, _): statics;
			case Named(ENUM_VALUE, _) | Function(_, _): false;
			case Named(CATCH_ALL | ANY, _) | Structure(_): left;
			case Named(id, _):
				final declared: Null<TypeFact> = _table.type(id);
				if (declared == null || !declared.alike)
					true
				else if (OBJECT_KINDS.contains(declared.kind))
					!statics && (hierarchy.contains(id) || (!exact && (left || _table.subtypesOf(id).exists(s -> hierarchy.contains(s)))))
				else
					declared.kind != ENUM_KIND;
			case Parameter(path):
				final types: Null<Array<FactsType>> = bound(path);
				types == null || types.exists(b -> mayHold(b, false, hierarchy, escaped, bound, statics, depth + 1));
			case Unknown: true;
		};
	}

	/** Why any method's value may be obtained (see the type doc), or null. */
	public function unknownReason(): Null<String> {
		return scan().unknown;
	}

	/**
	 * Whether the receiver of `read` may be an object of one of the classes `hierarchy` names: it is of no class the facts
	 * type, of one of them or of a type one of them extends, or — unless it is an object of exactly its class — of a type
	 * whose instances escaped (`_escaped`), which may then be in a place of any type.
	 */
	private function mayBeOf(read: MethodValueRead, hierarchy: Array<String>): Bool {
		final receiver: Null<String> = read.receiver;
		final id: Null<String> = receiver == null ? null : _view.objectClass(receiver);
		if (id == null) return true;
		if (read.exact) return hierarchy.contains(id);
		if (hierarchy.contains(id) || _table.subtypesOf(id).exists(s -> hierarchy.contains(s))) return true;
		final escaped: Null<Array<String>> = _escaped();
		return escaped == null || escaped.exists(e -> hierarchy.contains(e));
	}

	/** Every read of a method value in the functions the builds typed (see the type doc), read once. */
	private function scan(): MethodValueReads {
		final held: Null<MethodValueReads> = _reads;
		if (held != null) return held;
		final out: MethodValueReads = {
			named: [],
			computed: [],
			unknown: null,
			rebinds: false
		};
		_reads = out;

		function named(name: String, read: MethodValueRead): Void {
			final list: Array<MethodValueRead> = out.named[name] ?? [];
			list.push(read);
			out.named[name] = list;
		}
		for (id in _table.nodeIds()) {
			final made: Null<FactNode> = _table.node(id);
			if (made == null) {
				out.unknown = 'the facts of `$id` lie in a file whose text the table no longer has';
				return out;
			}
			final n: FactNode = made;
			final lost: Null<String> = if (n.incomplete.contains(STALE_FOREIGN))
				'a fact of `$id` lies in a file whose text the table no longer has'
			else if (n.incomplete.contains(REFLECTION_INLINED) && !namedReflection(n))
				'a reflective body spliced into `$id` lost the name it was handed'
			else
				null;
			if (lost != null) {
				out.unknown = lost;
				return out;
			}
			for (f in n.fields) if (!f.write && methodRead(f.access, f.owner, f.field))
				named(f.field, { receiver: f.receiver, exact: false, typeless: f.access == DYNAMIC_ACCESS });
			for (c in n.calls) if (c.access == INLINED && REBINDING_CALLS.contains(c.target ?? '')) out.rebinds = true;
			for (r in n.reflection) {
				final target: String = r.target;
				if (REBINDING_CALLS.contains(target)) out.rebinds = true;
				if (MEMBERLESS_REFLECTION.contains(target)) continue;
				if (r.isValue || REFLECTION_CLASSES.contains(target)) {
					// whatever calls it later hands it a name computed there, and any object: the project's declaration bounds
					// what that obtains (`declaredHolders`); a reflective class as a value may also rebind
					if (_holders == null) {
						out.unknown = '`$target` is read as a value in `$id`';
						return out;
					}
					if (REFLECTION_CLASSES.contains(target)) out.rebinds = true;
					out.computed.push({ receiver: null, exact: false, typeless: true });
					continue;
				}
				final read: MethodValueRead = { receiver: r.receiver, exact: r.receiverExact, typeless: true };
				final literal: Null<String> = r.name;
				// the literal recorded is the first of any argument: the object's own, when that is a string
				if (literal == null || CompilerFacts.baseId(r.receiver ?? STRING_TYPE) == STRING_TYPE)
					out.computed.push(read)
				else
					named(literal, read);
			}
		}
		return out;
	}

	/**
	 * Whether every reflective body spliced into `n` (`reflection-inlined`) is one its `inlined` calls name, each of a member
	 * that reads no member's value (`MEMBERLESS_REFLECTION`): what the others read is lost with their name.
	 */
	private static function namedReflection(n: FactNode): Bool {
		var named: Bool = false;
		for (c in n.calls) {
			final target: Null<String> = c.target;
			if (c.access != INLINED || target == null) continue;
			final dot: Int = target.lastIndexOf('.');
			if (dot < 0 || !REFLECTION_CLASSES.contains(target.substr(0, dot))) continue;
			if (!MEMBERLESS_REFLECTION.contains(target)) return false;
			named = true;
		}
		return named;
	}

	/**
	 * Whether a field read through `access` of the field `field` of `owner` may yield an instance method's value: any read
	 * but a static's or an enum constructor's, an instance read only of a field some build declares a method.
	 */
	private function methodRead(access: String, owner: Null<String>, field: String): Bool {
		if (VALUELESS_ACCESSES.contains(access)) return false;
		if (access != INSTANCE_ACCESS) return true;
		final declaring: Null<TypeFact> = owner == null ? null : _table.type(owner);
		final declared: Null<FieldDeclFact> = declaring?.fields.find(f -> f.name == field);
		return declared == null || declared.kinds.exists(k -> METHOD_KINDS.contains(k));
	}

}

/** A read that may obtain a method's value: the type of the object it reads off, and whether that is exactly its class. */
typedef MethodValueRead = {
	final receiver: Null<String>;
	final exact: Bool;

	/** Whether the value read is of no type the program declares: a read off a value of no class (`FDynamic`), or reflection. */
	final typeless: Bool;
}

/**
 * What the functions the builds typed obtain (`FactsMethodValues.scan`): the reads by the member name they name, those by
 * a name computed at run time, and why some read may obtain any method, or null.
 */
typedef MethodValueReads = {
	final named: Map<String, Array<MethodValueRead>>;
	final computed: Array<MethodValueRead>;
	var unknown: Null<String>;

	/** Whether some function hands a function a receiver of its own to run with (`REBINDING_CALLS`). */
	var rebinds: Bool;
}
