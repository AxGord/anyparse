package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.check.FactsTypeTree.FactsField;
import anyparse.check.FactsTypeTree.FactsType;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.ReflectionFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.FactsNativeReach.NativeHand;
import anyparse.query.GrammarPlugin.RefShape;

using Lambda;
using StringTools;

/**
 * `ValueEscapes` read off the compiler's facts when they are the truth (`FactsView.truth`): the types whose instances may
 * reach code with no static type to say what they are, from every function and initializer the builds typed — the
 * libraries' and the standard library's as much as the project's, so a value handed to library code escapes only where
 * that code lets it go.
 *
 * A value ESCAPES where the facts show it leave the type system:
 * - it flows (`FlowFact`) into a place whose type keeps no nominal type of what it holds (`keepsNominal`) — a catch-all, a
 *   type parameter, a structure, an abstract, a function type, an unknown; a thrown value flows into `Dynamic` — or
 *   through an unchecked cast, whatever the two types;
 * - it is handed to a field of an extern class (`HandFact`) at a parameter its type parameters do not type: target code,
 *   which no fact describes, may keep it and give it back untyped;
 * - it is the receiver of a method read as a value, which the bound function carries, or of a field reached by name
 *   (untyped code), which may be any of its fields;
 * - target-language code names it (`FactsNativeReach`, the stated assumption below);
 * - it is an instance of a class a class-value producer names (`producer`, `Type.resolveClass`): a literal name names one
 *   class, a computed name — or the producer read as a value — any, or one the project declares (`anyClass`);
 * - it is an instance of a class extending an extern class, whose target code runs with it as its own `this`.
 *
 * What an escaped value holds escapes with it (`escapeType`): its type arguments, which an extern container's target code
 * keeps; each subtype of its class, which it may be; every variable each declares, static and instance, at the type
 * arguments the value is written with; an abstract's underlying value, a typedef's target, an enum value's constructor
 * arguments, a structure's fields, the instances a reflective call makes of a class or an enum as a value, the statics of
 * an abstract as a value (its implementation class's). A value of a type parameter is of a type some instantiation binds
 * it to (`instances`): a type written with arguments, or the instantiation the compiler chose for a generic method. A
 * function value holds no object a name reaches.
 *
 * A value typed by nothing (`?`) came through untyped code: a field reached by name on a receiver, which escapes then, or
 * target code, which gives back only what it was handed. Null — any instance may be anywhere — when a fact needed is lost
 * (a node no text places, `stale-foreign`), a reflective body was spliced in that may produce a class value
 * (`reflection-inlined`, which loses the call and the name it was handed), target-language code has a text computed at run
 * time, or an escaping value's type says nothing of what it holds: a type no build typed, a type string that does not
 * read, a type parameter an instantiation leaves unknown.
 *
 * The stated assumption, one for the project and the libraries alike: target-language code — a `__cpp__`/`__js__` call,
 * a `*.Syntax.code` call, the code a `@:functionCode`/`@:cppFileCode`/`@:headerClassCode`/… metadata pastes, a native
 * identifier — reaches only the values handed to it, and makes an instance of a program class only through the
 * producers its callers name. Handed are what a call of it hands it (`NativeFact.handed`: its arguments, its `{0}`
 * placeholders among them, a call's through a chain of names untyped code leaves to the target included) and what its
 * text names, that chain's names among it (`FactsNativeReach`): a local or parameter by its name; the object its method
 * runs on by a spelling of `this` or by the name of a member of it, which hxcpp reaches unqualified; a static variable
 * by its name beside its class's, or alone in the code of its class or of one extending it.
 */
@:nullSafety(Strict)
final class FactsEscapes {

	/** The access of a method read as a value (`FieldFact.access`, `CallFact.access`). */
	private static inline final CLOSURE: String = 'FClosure';

	/** The access of a field reached by name on a value of any type: untyped code (`FieldFact.access`, `CallFact.access`). */
	private static inline final DYNAMIC_ACCESS: String = 'FDynamic';

	/** The access of a call of a method the compiler spliced in (`CallFact.access`). */
	private static inline final INLINED: String = 'inlined';

	/** The classes whose members are reflection (`TypedFactsProbe`). */
	private static final REFLECTION_CLASSES: Array<String> = ['Reflect', 'Type'];

	/** The flow of an unchecked cast (`FlowFact.via`). */
	private static inline final CAST: String = 'cast';

	/** The marker of a node a fact of which lies in a file whose text the table no longer has. */
	private static inline final STALE_FOREIGN: String = 'stale-foreign';

	/** The marker of a node a `Reflect`/`Type` body was spliced into: that call, its name and its arguments are gone. */
	private static inline final REFLECTION_INLINED: String = 'reflection-inlined';

	/** The catch-all type: what it holds escaped already. */
	private static inline final CATCH_ALL: String = 'Dynamic';

	/** The nullable wrapper: it holds what its argument does. */
	private static inline final NULLABLE: String = 'Null';

	/** The type of an enum as a value: its statics, and the values a reflective call makes of them. */
	private static inline final ENUM_VALUE: String = 'Enum';

	/** The type of a class as a value: its statics, and the instances a reflective call makes of it. */
	private static inline final CLASS_VALUE: String = 'Class';

	/** The type of an abstract as a value: its statics, which its implementation class holds. */
	private static inline final ABSTRACT_VALUE: String = 'Abstract';

	/** The kinds of a typed type a place keeps the nominal type of what it holds by (`TypeFact.kind`). */
	private static final NOMINAL_KINDS: Array<String> = ['class', 'interface', 'enum'];

	/** The kinds of a typed type a class value may be of (`TypeFact.kind`): an abstract's implementation class holds its statics. */
	private static final CLASS_KINDS: Array<String> = ['class', 'interface', 'impl'];

	/** Why the escapes are not known, once something says so (`compute`). */
	public var failure(default, null): Null<String> = null;

	private final _view: FactsView;
	private final _table: CompilerFacts;
	private final _scope: ReachProject;

	/** The escaped types, by the graph's name (`FactsView.graphType`). */
	private final _out: Array<String> = [];

	/** The escaped types, by their typed id (`pack.Name`): which of the types sharing a graph name escaped. */
	private final _typed: Array<String> = [];

	/** The closed types already escaped (`escapeType`), by their structure. */
	private final _done: Map<String, Bool> = [];

	/** The type strings already escaped (`escape`). */
	private final _escaped: Map<String, Bool> = [];

	/** The primitive types' ids: a value of one is no object. */
	private final _inert: Array<String>;

	/** What target-language code reaches (the stated assumption, see the type doc). */
	private final _native: FactsNativeReach;

	/** What target-language code reaches escapes (`escape`, `escapeType`). */
	private final _hand: NativeHand;

	/**
	 * Whether every class the project declares a class value made from an unreadable name may be of (`declaredClasses`)
	 * has escaped already: null until first asked, then the answer.
	 */
	private var _declaredEscaped: Null<Bool> = null;

	/**
	 * Type parameter (`pack.Type.T`, `method.T`) -> the types a value bound to it may have, by their text (`instances`); built on
	 * first need.
	 */
	private var _instances: Null<Map<String, Map<String, FactsType>>> = null;

	/** Whether a type string the facts hold did not read: an instantiation may then be missing from `_instances`. */
	private var _unread: Bool = false;

	/**
	 * The type parameters a generic method's declared type holds where the type the compiler instantiated it at has no part
	 * that matches (`instances`): what they stand for there is not known.
	 */
	private final _unresolved: Map<String, Bool> = [];

	public function new(view: FactsView, scope: ReachProject) {
		_view = view;
		_table = view.table;
		_scope = scope;
		_inert = inertIds(scope.shape);
		_native = new FactsNativeReach(_table);
		_hand = { escape: escape, escapeType: escapeType, refuse: refuse };
	}

	/** The escaped types (see the type doc), by the graph's name, or null for any; `failure` then says why. */
	public function compute(): Null<Array<String>> {
		for (id in _table.nodeIds()) if (!escapesOf(id)) return null;
		for (id in _table.typeIds()) {
			// a class extending an extern runs the extern's target code with its instance as `this`
			if (extendsExtern(id) && !escapeType(Named(id, []))) return null;
			if (!_native.metadataEscapes(id, _hand)) return null;
		}
		return _out;
	}

	/** The escaped types `compute` found, by their typed id rather than the graph's name. */
	public inline function typedIds(): Array<String> {
		return _typed;
	}

	/**
	 * Hand every value the node `id` lets escape to `escape`; false when one says nothing of what it holds, when a fact of
	 * the node is lost, and when it holds target-language code whose text is computed.
	 */
	private function escapesOf(id: String): Bool {
		final made: Null<FactNode> = _table.node(id);
		if (made == null) return refuse('the facts of `$id` lie in a file whose text the table no longer has');
		final n: FactNode = made;
		if (n.incomplete.contains(STALE_FOREIGN)) return refuse('a fact of `$id` lies in a file whose text the table no longer has');
		if (n.incomplete.contains(REFLECTION_INLINED) && !harmlessReflection(n))
			return refuse('a reflective body spliced into `$id` lost the name it was handed');
		if (!_native.nodeEscapes(id, n, _hand)) return false;
		for (f in n.flows) if ((f.via == CAST || !keepsNominal(f.to)) && !escape(f.from)) return false;
		for (h in n.handed) if (!typeParameter(h.to) && !escape(h.from)) return false;
		for (f in n.fields) if (byName(f.access) && !escape(f.receiver)) return false;
		for (c in n.calls) {
			final receiver: Null<String> = c.receiver;
			if (byName(c.access) && receiver != null && !escape(receiver)) return false;
		}
		for (r in n.reflection) if (!produced(r)) return false;
		return true;
	}

	/**
	 * Whether a field access `access` (`FieldFact.access`, `CallFact.access`) lets its receiver go: a method read as a value,
	 * which the bound function carries, and a field reached by name on it (untyped code), which may be any of its fields.
	 */
	private static inline function byName(access: String): Bool {
		return access == CLOSURE || access == DYNAMIC_ACCESS;
	}

	/**
	 * Whether every reflective body spliced into `n` (`reflection-inlined`) is one its `inlined` calls name, and none of them
	 * produces a class value (`producer`): what the others are handed flows into their parameters, which the facts record.
	 * A producer's lost the name it was handed, which may have been a literal naming a class the project declares nowhere:
	 * the declaration (`anyClass`) bounds only the names no literal hands a producer directly.
	 */
	private function harmlessReflection(n: FactNode): Bool {
		var named: Bool = false;
		for (c in n.calls) {
			final target: Null<String> = c.target;
			if (c.access != INLINED || target == null) continue;
			final dot: Int = target.lastIndexOf('.');
			if (dot < 0 || !REFLECTION_CLASSES.contains(target.substr(0, dot))) continue;
			named = true;
			final field: Null<FieldDeclFact> = declaredField(target);
			if (field != null && producer(field)) return false;
		}
		return named;
	}

	/**
	 * Hand every class a class value made from a name the facts cannot read may be of to `escapeType`: each class the
	 * project declares (`ReachProject.reflectiveClasses`, `declaredClasses`), as an instance of exactly it — a subtype is a
	 * class it declares by its own name or none. Without a declaration such a name names any class: false, `reason` why.
	 */
	private function anyClass(reason: String): Bool {
		final held: Null<Bool> = _declaredEscaped;
		if (held != null) return held;
		final globs: Null<Array<String>> = _scope.reflectiveClasses;
		if (globs == null) return refuse(reason);
		_declaredEscaped = true;
		for (id in declaredClasses(_table, globs)) {
			final fact: Null<TypeFact> = _table.type(id);
			if (fact != null && !escapeInstance(id, fact, [])) {
				_declaredEscaped = false;
				return false;
			}
		}
		return true;
	}

	/** The typed classes of `table` (`CLASS_KINDS`) whose qualified name one of `globs` matches (`Glob.qualifiedNames`). */
	private static function declaredClasses(table: CompilerFacts, globs: Array<String>): Array<String> {
		final patterns: Array<EReg> = globs.map(Glob.qualifiedNames);
		return [
			for (id in table.typeIds()) {
				final fact: Null<TypeFact> = table.type(id);
				if (fact != null && CLASS_KINDS.contains(fact.kind) && patterns.exists(p -> p.match(id))) id;
			}
		];
	}

	/**
	 * The globs of `globs` (`LintConfig.reflectiveClasses`) that match no class `table` holds (`declaredClasses`): a
	 * declaration naming nothing the builds typed, a misspelling or a class long gone.
	 */
	public static function unmatchedGlobs(table: CompilerFacts, globs: Array<String>): Array<String> {
		return [for (g in globs) if (declaredClasses(table, [g]).length == 0) g];
	}

	/**
	 * Hand the classes the reflective call `r` may make an instance of to `escapeType`: none unless it is a class-value
	 * producer (`producer`) — the one class a literal name names, which may be none — and for a computed name, for a
	 * producer read as a value and for a class declaring one read as a value, any or those the project declares (`anyClass`).
	 */
	private function produced(r: ReflectionFact): Bool {
		final target: String = r.target;
		final declaring: Null<TypeFact> = _table.type(target);
		// the reflective class itself read as a value: whatever later calls a member of it may call a producer
		if (declaring != null)
			return !declaring.fields.exists(producer) || anyClass('`$target`, which declares a class-value producer, is read as a value');
		final field: Null<FieldDeclFact> = declaredField(target);
		if (field == null || !producer(field)) return true;
		final name: Null<String> = r.name;
		if (r.isValue || name == null) return anyClass('`$target` makes a class value of a name computed at run time in `${r.holder}`');
		return _table.type(name) == null || escapeType(Named(name, []));
	}

	/** The field `target` (`pack.Type.field`) names, as its type declares it; null when no build typed one. */
	private function declaredField(target: String): Null<FieldDeclFact> {
		final dot: Int = target.lastIndexOf('.');
		return dot < 0 ? null : _table.type(target.substr(0, dot))?.fields.find(f -> f.name == target.substr(dot + 1));
	}

	/**
	 * Whether the declared field `f` produces a class value from a name: a function, in some build, taking a string and
	 * returning the class-value type (`ExecutionShape.classValueTypeName`).
	 */
	private function producer(f: FieldDeclFact): Bool {
		final classValue: Null<String> = _scope.shape.execution?.classValueTypeName;
		final string: Null<String> = (_scope.shape.literalTypeNames ?? [])[(_scope.shape.stringLiteralKinds ?? [])[0] ?? ''];
		if (classValue == null || string == null) return false;
		return f.types.exists(t -> switch FactsTypeTree.read(t) {
			case Function(args, Named(result, _)):
				result == classValue && args.exists(a -> switch a.type {
					case Named(name, []): name == string;
					case _: false;
				});
			case _: false;
		});
	}

	/** Whether the typed class `id` extends an extern class, directly or not, being none itself. */
	private function extendsExtern(id: String): Bool {
		final fact: Null<TypeFact> = _table.type(id);
		if (fact == null || fact.kind != 'class' || fact.isExtern) return false;
		var up: Null<String> = fact.superClass;
		final seen: Array<String> = [];
		while (up != null) {
			final sup: String = CompilerFacts.baseId(up);
			if (seen.contains(sup)) return false;
			seen.push(sup);
			final declared: Null<TypeFact> = _table.type(sup);
			if (declared == null) return false;
			if (declared.isExtern) return true;
			up = declared.superClass;
		}
		return false;
	}

	/**
	 * Whether a place of the type `text` keeps the nominal type of what it holds: a primitive, or a class, an interface or
	 * an enum every build typed as one, at arguments that keep theirs too, or a typedef of one; `Null<T>` keeps what `T` keeps.
	 */
	private function keepsNominal(text: String): Bool {
		final read: Null<FactsType> = FactsTypeTree.read(text);
		return read != null && placeKeeps(read);
	}

	private function placeKeeps(t: FactsType): Bool {
		return switch t {
			case Named(NULLABLE, [inner]): placeKeeps(inner);
			case Named(id, args):
				final fact: Null<TypeFact> = _table.type(id);
				if (inert(id))
					true
				else if (fact == null || !fact.alike)
					false
				else if (fact.kind == 'typedef')
					fact.targets.length > 0 && fact.targets.foreach(target -> {
						final read: Null<FactsType> = FactsTypeTree.read(target);
						read != null && placeKeeps(substitute(read, bindings(id, fact, args)));
					})
				else
					NOMINAL_KINDS.contains(fact.kind) && args.length == fact.params.length && args.foreach(placeKeeps);
			case _: false;
		};
	}

	/** Whether the type `text` is a type parameter, nullable or not: an extern handed a value there gives it back as one. */
	private static function typeParameter(text: String): Bool {
		return switch FactsTypeTree.read(text) {
			case Parameter(_) | Named(NULLABLE, [Parameter(_)]): true;
			case _: false;
		};
	}

	/** `escapeType` of the type string `text`, read once. */
	private function escape(text: String): Bool {
		if (_escaped.exists(text)) return true;
		_escaped[text] = true;
		final read: Null<FactsType> = FactsTypeTree.read(text);
		return read == null ? refuse('the type `$text` does not read') : escapeType(read);
	}

	/**
	 * Record the closed type `t` and everything a value of it holds as escaped (see the type doc): false when what it holds
	 * is not known.
	 */
	private function escapeType(t: FactsType): Bool {
		switch t {
			case Unknown:
				// a value typed by nothing came through untyped code: a field read by name on a receiver that escaped then, or
				// target code, which hands back only what it was handed and makes no program object (see the type doc)
				return true;
			case Parameter(path):
				final key: String = Std.string(t);
				if (_done.exists(key)) return true;
				_done[key] = true;
				// a value of a type parameter has a type some instantiation binds it to
				final bound: Null<Map<String, FactsType>> = instances()[path];
				if (_unread) return refuse('a value of the type parameter `$path` escapes, and a type the facts hold does not read');
				if (_unresolved.exists(path))
					return refuse('a value of the type parameter `$path` escapes, which an instantiation leaves unknown');
				if (bound != null) for (x in bound) if (!escapeType(x)) return false;
				return true;
			case Function(_, _) | Named(CATCH_ALL, _):
				return true;
			case Structure(fields):
				return fields.foreach(f -> escapeType(f.type));
			case Named(NULLABLE | ENUM_VALUE | CLASS_VALUE, [inner]):
				return escapeType(inner);
			case Named(ABSTRACT_VALUE, [Named(id, _)]):
				final fact: Null<TypeFact> = _table.type(id);
				if (fact == null) return refuse('the statics of `$id` escape, which no build typed');
				final impl: Null<String> = fact.implementation;
				return impl == null || escapeType(Named(impl, []));
			case Named(id, args):
				if (inert(id)) return true;
				final key: String = Std.string(t);
				if (_done.exists(key)) return true;
				_done[key] = true;
				final fact: Null<TypeFact> = _table.type(id);
				if (fact == null) return refuse('a value of `$id` escapes, which no build typed');
				// what a container holds an extern's target code keeps, which no variable declares
				if (!args.foreach(escapeType)) return false;
				final bound: Map<String, FactsType> = bindings(id, fact, args);
				return switch fact.kind {
					case 'class' | 'interface' | 'impl': escapeClass(id, fact, bound);
					case 'enum': fact.constructors.foreach(c -> constructorEscapes(id, c.name, c.type, bound));
					case 'abstract': within(fact.underlying, bound);
					case 'typedef': within(fact.targets, bound);
					case kind: refuse('a value of `$id` escapes, a $kind');
				};
		}
	}

	/** `escapeType` of each argument the constructor `name` of the enum `id`, of the type `type`, takes, bound by `bound`. */
	private function constructorEscapes(id: String, name: String, type: String, bound: Map<String, FactsType>): Bool {
		final read: Null<FactsType> = FactsTypeTree.read(type);
		if (read == null) return refuse('the constructor `$id.$name` has a type that does not read');
		return switch read {
			case Function(held, _): held.foreach(a -> escapeType(substitute(a.type, bound)));
			case _: true;
		};
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
		function bind(path: String, t: FactsType): Void {
			final types: Map<String, FactsType> = out[path] ?? [];
			out[path] = types;
			types[Std.string(t)] = t;
		}
		function scan(t: FactsType): Void {
			switch t {
				case Named(id, args):
					final fact: Null<TypeFact> = _table.type(id);
					if (fact != null && fact.params.length == args.length) for (i => name in fact.params) bind('$id.$name', args[i]);
					for (a in args) scan(a);
				case Function(args, result):
					for (a in args) scan(a.type);
					scan(result);
				case Structure(fields):
					for (f in fields) scan(f.type);
				case Parameter(_) | Unknown:
			}
		}
		function text(type: Null<String>): Void {
			if (type == null || scanned.exists(type)) return;
			scanned[type] = true;
			final read: Null<FactsType> = FactsTypeTree.read(type);
			if (read == null)
				_unread = true
			else
				scan(read);
		}
		function unknownIn(declared: FactsType): Void {
			switch declared {
				case Parameter(path):
					_unresolved[path] = true;
				case Named(_, args):
					for (a in args) unknownIn(a);
				case Function(args, result):
					for (a in args) unknownIn(a.type);
					unknownIn(result);
				case Structure(fields):
					for (f in fields) unknownIn(f.type);
				case Unknown:
			}
		}
		function unify(declared: FactsType, applied: FactsType): Void {
			switch [declared, applied] {
				case [Parameter(path), _]:
					bind(path, applied);
				case [Named(a, xs), Named(b, ys)] if (a == b && xs.length == ys.length):
					for (i in 0...xs.length) unify(xs[i], ys[i]);
				case [Function(xs, x), Function(ys, y)] if (xs.length == ys.length):
					for (i in 0...xs.length) unify(xs[i].type, ys[i].type);
					unify(x, y);
				case [Structure(xs), Structure(ys)]:
					for (f in xs) {
						final other: Null<FactsField> = ys.find(g -> g.name == f.name);
						if (other == null)
							unknownIn(f.type)
						else
							unify(f.type, other.type);
					}
				case _:
					unknownIn(declared);
			}
		}
		for (id in _table.nodeIds()) {
			final n: Null<FactNode> = _table.node(id);
			if (n == null) continue;
			text(n.signature);
			for (p in n.params) text(p.type);
			for (v in n.variants) {
				text(v.signature);
				for (p in v.params) text(p.type);
			}
			for (c in n.calls) {
				text(c.receiver);
				text(c.result);
				text(c.signature);
			}
			for (x in n.news) text(x.instance);
			for (f in n.fields) {
				text(f.receiver);
				text(f.type);
			}
			for (e in n.elementWrites) text(e.receiver);
			for (f in n.flows) {
				text(f.from);
				text(f.to);
			}
			for (h in n.handed) {
				text(h.from);
				text(h.to);
			}
			for (s in n.strings) text(s.operand);
			for (i in n.iterations) {
				text(i.binder);
				text(i.iterated);
			}
			for (v in n.vars) text(v.type);
			for (r in n.reads) text(r.type);
			for (g in n.instantiations) {
				final declared: Null<FactsType> = FactsTypeTree.read(g.declared);
				final applied: Null<FactsType> = FactsTypeTree.read(g.applied);
				if (declared == null || applied == null)
					_unread = true
				else
					unify(declared, applied);
			}
		}
		for (id in _table.typeIds()) {
			final fact: Null<TypeFact> = _table.type(id);
			if (fact == null) continue;
			for (f in fact.fields) for (t in f.types) text(t);
			text(fact.superClass);
			for (i in fact.interfaces) text(i);
			for (t in fact.targets) text(t);
			for (t in fact.underlying) text(t);
			for (c in fact.constructors) text(c.type);
			text(fact.genericOf);
		}
		_instances = out;
		return out;
	}

	/** `escapeType` of every type string of `types`, its type parameters bound by `bound`. */
	private function within(types: Array<String>, bound: Map<String, FactsType>): Bool {
		return types.foreach(text -> {
			final read: Null<FactsType> = FactsTypeTree.read(text);
			read == null ? refuse('the type `$text` does not read') : escapeType(substitute(read, bound));
		});
	}

	/**
	 * Record the class `id` (`fact`) as escaped at the arguments `bound` gives its type parameters: it, what its variables
	 * hold, and each typed subtype of it, a value of `id` may be — whose own type parameters nothing here binds.
	 */
	private function escapeClass(id: String, fact: TypeFact, bound: Map<String, FactsType>): Bool {
		if (!escapeInstance(id, fact, bound)) return false;
		for (sub in _table.subtypesOf(CompilerFacts.baseId(id))) {
			final declared: Null<TypeFact> = _table.type(sub);
			if (declared == null) return refuse('a subtype of `$id`, `$sub`, has no type the builds typed');
			if (!escapeInstance(sub, declared, [])) return false;
		}
		return true;
	}

	/**
	 * Record an instance of the class `id` (`fact`) as escaped: its graph name, and what every variable it and the classes it
	 * extends declare holds — their type parameters bound by `bound`, and by the arguments each class extends the next at.
	 */
	private function escapeInstance(id: String, fact: TypeFact, bound: Map<String, FactsType>): Bool {
		var currentId: String = id;
		var currentFact: TypeFact = fact;
		var currentBound: Map<String, FactsType> = bound;
		final seen: Array<String> = [];
		while (!seen.contains(currentId)) {
			seen.push(currentId);
			final name: String = _view.graphType(currentId);
			if (!_out.contains(name)) _out.push(name);
			if (!_typed.contains(currentId)) _typed.push(currentId);
			for (f in currentFact.fields) if (f.kinds.exists(k -> k.startsWith('var(')) && !within(f.types, currentBound)) return false;
			final sup: Null<String> = currentFact.superClass;
			if (sup == null) break;
			final read: Null<FactsType> = FactsTypeTree.read(sup);
			if (read == null) return refuse('`$currentId` extends `$sup`, which does not read');
			switch substitute(read, currentBound) {
				case Named(supId, supArgs):
					final declared: Null<TypeFact> = _table.type(supId);
					if (declared == null) return refuse('`$currentId` extends `$supId`, which no build typed');
					currentBound = bindings(supId, declared, supArgs);
					currentId = supId;
					currentFact = declared;
				case _:
					return refuse('`$currentId` extends `$sup`, which is no class');
			}
		}
		return true;
	}

	/** The arguments `args` of the typed type `id` (`fact`), by the path a type parameter of it is spelled with (`$id.T`). */
	public static function bindings(id: String, fact: TypeFact, args: Array<FactsType>): Map<String, FactsType> {
		final out: Map<String, FactsType> = [];
		if (args.length == fact.params.length) for (i => name in fact.params) out['$id.$name'] = args[i];
		return out;
	}

	/** `t` with each type parameter `bound` binds replaced by what it binds. */
	public static function substitute(t: FactsType, bound: Map<String, FactsType>): FactsType {
		return switch t {
			case Parameter(path): bound[path] ?? t;
			case Named(name, args): Named(name, [for (a in args) substitute(a, bound)]);
			case Function(args, result):
				Function([for (a in args) { optional: a.optional, type: substitute(a.type, bound) }], substitute(result, bound));
			case Structure(fields):
				Structure([
					for (f in fields) { optional: f.optional, name: f.name, type: substitute(f.type, bound) }
				]);
			case Unknown: Unknown;
		};
	}

	/**
	 * The ids of the primitive types `shape` declares — its literals', its non-nullable ones and its no-value type: no value of
	 * one is an object.
	 */
	public static function inertIds(shape: RefShape): Array<String> {
		final out: Array<String> = [for (t in (shape.literalTypeNames ?? []).iterator()) t].concat(shape.nonNullableTypeNames ?? []);
		out.push(shape.voidTypeName ?? 'Void');
		return out;
	}

	/** Whether the typed type `id` is a primitive: a value of it is no object. */
	private function inert(id: String): Bool {
		return id.indexOf('.') < 0 && _inert.contains(id);
	}

	/** Record why the escapes are not known: false, for the caller to answer. */
	private function refuse(reason: String): Bool {
		if (failure == null) failure = reason;
		return false;
	}

}
