package anyparse.check.common.expressions;

import anyparse.check.facts.FactsTypeOracle;
import anyparse.check.facts.FactsTypeText;
import anyparse.check.facts.FactsTypeTree;
import anyparse.query.CompilerFacts;

using StringTools;

/**
 * Whether the compiler's facts (`CompilerFacts`) prove that a static call `Module.method(recv, …)` may be written as the
 * extension call `recv.method(…)`: the receiver's type, every configuration agreeing on it where the facts place the
 * receiver (`FactsTypeOracle.factsTypeAt`), declares no member of that name anywhere in its hierarchy, carries no
 * `@:using` of its own, and is handed to the static function's first parameter with no implicit conversion.
 *
 * Each proof rests on the union the table keeps: a member any configuration declares is a member, a supertype no
 * configuration typed leaves the hierarchy unproven, and a receiver the configurations type differently has no one
 * type. Only a class or an interface hosts the members the proof reads — an abstract's live on its implementation
 * class, behind `@:forward` and conversions, and a basic type is an abstract. The table is the one the rule's oracle
 * reads (`FactsTypeOracle.forFix`), which holds every configuration.
 */
@:nullSafety(Strict)
final class StaticExtensionFacts {

	/** A type's own static extensions: `x.method()` resolves through them BEFORE any `using` of the file. */
	private static inline final USING_META: String = ':using';


	/** The static access the facts record for `Module.method(…)`. */
	private static inline final STATIC_ACCESS: String = 'FStatic';

	/** The access the facts record for a call the compiler spliced in (`inline`). */
	private static inline final INLINED_ACCESS: String = 'inlined';

	/** A typedef's kind in the facts. */
	private static inline final TYPEDEF_KIND: String = 'typedef';

	/** A bound on a typedef chain, which a structure-typed alias never ends. */
	private static inline final MAX_ALIAS_HOPS: Int = 16;

	/** The annotation that keeps a static out of `using` (`TypedFactsProbe` writes metadata without its `@`). */
	private static inline final NO_USING_META: String = ':noUsing';

	/** The one type that dispatches nothing statically. */
	private static inline final DYNAMIC: String = 'Dynamic';

	/** The type kinds whose declared fields are the members an instance access resolves against (`TypedFactsProbe`). */
	private static final MEMBER_HOSTS: Array<String> = ['class', 'interface'];

	/** A type path with no arguments: a nominal type the table can hold. */
	private static final NOMINAL: EReg = ~/^[A-Za-z_][A-Za-z0-9_.]*$/;

	/**
	 * The verdict of the facts `oracle` reads (`FactsTypeOracle.forFix`) on the call at `call` of `file` whose receiver lies
	 * at `recv`, calling `method` of the configured `module`.
	 */
	public static function judge(
		oracle: FactsTypeOracle, file: String, call: Span, recv: Span, module: String, method: String, usings: Array<String>
	): ExtensionFactsVerdict {
		// the table is asked by range below, so only a text the compile read places anything
		if (!oracle.readsAsCompiled(file)) return Unproven;
		final facts: CompilerFacts = oracle.facts;
		final typed: Null<String> = oracle.factsTypeAt(file, recv);
		if (typed == null) return Unproven;
		final receiver: String = FactsTypeText.unwrapNull(typed);
		if (receiver == DYNAMIC) return DynamicReceiver;
		if (!NOMINAL.match(CompilerFacts.baseId(receiver))) return Unproven;
		final base: String = CompilerFacts.baseId(receiver);
		final chain: Array<String> = [base].concat(facts.supertypesOf(base));
		// a member any configuration declares on any type of the chain wins over the extension: proven, whatever else is unknown
		for (id in chain) if (facts.type(id)?.fields.exists(f -> f.name == method) == true) return Shadowed;
		for (id in chain) {
			final t: Null<TypeFact> = facts.type(id);
			if (t == null || !MEMBER_HOSTS.contains(t.kind) || t.meta.contains(USING_META)) return Unproven;
		}
		final owner: Null<String> = staticOwner(facts, file, call, module, method);
		if (owner == null) return Unproven;
		// `module`'s own `using`, present or inserted by the rewrite, brings the other types of its module as well
		switch usingsSupply(facts, usings.contains(module) ? usings : usings.concat([module]), owner, method) {
			case Supplied:
				return Shadowed;
			case Unread:
				return Unproven;
			case None:
		}
		final param: Null<String> = owner == null ? null : firstParam(facts, owner, method);
		return param != null && accepts(facts, param, base, chain) ? Proven : Unproven;
	}

	/**
	 * The first parameter of the facts function type `signature` — `(Iterable<$f.A>,Int)->Bool` yields `Iterable<$f.A>` —
	 * as the facts spell it, read by the one reader of their type grammar (`FactsTypeTree`); null for a function of no
	 * parameter or an optional first one, and for any other shape.
	 */
	public static function firstParamOf(signature: String): Null<String> {
		return switch FactsTypeTree.read(signature) {
			case Function(args, _) if (args.length > 0 && !args[0].optional): FactsTypeTree.text(args[0].type);
			case _: null;
		};
	}

	/**
	 * The typed id of the configured `module` when the facts name its static `method` as what the call at `call` runs:
	 * every call fact at that range names it, or — an inlined call leaves none there — a function holding the call records
	 * a splice of it. Null when a fact names anything else, none names it, or the table holds no such type. Which function the
	 * written name denotes is proven by the caller (`PreferStaticExtension.channelsOf`); this only refuses a site whose
	 * facts contradict it or say nothing.
	 */
	private static function staticOwner(facts: CompilerFacts, file: String, call: Span, module: String, method: String): Null<String> {
		final configured: Null<String> = typeIdOf(facts, module);
		if (configured == null) return null;
		final target: String = '$configured.$method';
		final sites: Array<CallFact> = facts.callsAt(file, call);
		for (c in sites) if (c.target != target || c.access != STATIC_ACCESS) return null;
		if (sites.length > 0) return configured;
		// an inlined call leaves no fact at its own range: the facts of the code holding it must name the splice of `target`
		for (n in facts.nodesAround(file, call)) if (n.calls.exists(c -> c.access == INLINED_ACCESS && c.target == target))
			return configured;
		return null;
	}

	/**
	 * Whether a `using` of `usings` other than the one of `owner` may supply a static `method` in the facts: a module path
	 * brings every type its main type's file declares, a sub-type path (`pkg.Mod.Sub`) that type alone. `Unread` when a
	 * path names no typed type.
	 */
	private static function usingsSupply(facts: CompilerFacts, usings: Array<String>, owner: String, method: String): UsingSupply {
		for (path in usings) {
			final id: Null<String> = typeIdOf(facts, path);
			if (id == null) return Unread;

			final home: Null<String> = facts.typePosition(id)?.file;
			final main: Bool = facts.type(path) != null;
			final ids: Array<String> = [id];
			if (main && home != null)
				for (other in facts.typeIds())
					if (other != id && facts.typePosition(other)?.file == home) ids.push(other);
			for (t in ids) if (t != owner) {
				final host: Null<TypeFact> = aliasedFact(facts, t);
				if (host == null) return Unread;
				if (host.id != owner && host.fields.exists(f -> f.name == method && f.isStatic && !f.meta.contains(NO_USING_META)))
					return Supplied;
			}
		}
		return None;
	}

	/** The typed type `id` stands for: itself, or what a `typedef` aliases in every configuration. Null when that is not one type. */
	private static function aliasedFact(facts: CompilerFacts, id: String): Null<TypeFact> {
		var cur: Null<TypeFact> = facts.type(id);
		var hops: Int = 0;
		while (cur != null && cur.kind == TYPEDEF_KIND) {
			// a structure or a function type has no statics: the alias brings nothing
			if (cur.targets.length > 0 && cur.targets.foreach(t -> t.startsWith('{') || t.startsWith('('))) return cur;
			if (cur.targets.length != 1 || ++hops > MAX_ALIAS_HOPS) return null;
			cur = facts.type(CompilerFacts.baseId(cur.targets[0]));
		}
		return cur;
	}

	/**
	 * The typed id of the type a configured `module` entry names: the path itself, or — for a sub-type written
	 * `pack.Module.Sub` — `pack.Sub`, which is how the compiler names a type that is not its module's main one.
	 */
	private static function typeIdOf(facts: CompilerFacts, module: String): Null<String> {
		if (facts.type(module) != null) return module;
		final parts: Array<String> = module.split('.');
		// only a module segment — capitalised, as every Haxe module is — may be dropped: a package segment names another type
		if (parts.length < 2 || parts[parts.length - 2].charAt(0).toUpperCase() != parts[parts.length - 2].charAt(0)) return null;
		parts.splice(parts.length - 2, 1);
		final sub: String = parts.join('.');
		return facts.type(sub) == null ? null : sub;
	}

	/**
	 * The first parameter's type of the static `method` of `owner`, when it is one plain, required parameter every
	 * configuration typed alike, of a function that is neither a macro (whose extension form is handed the receiver's
	 * expression, not its value) nor overloaded; null otherwise.
	 */
	private static function firstParam(facts: CompilerFacts, owner: String, method: String): Null<String> {
		final declared: Array<FieldDeclFact> = (facts.type(owner)?.fields ?? []).filter(f -> f.name == method);
		if (declared.length != 1) return null;
		final field: FieldDeclFact = declared[0];
		return !field.isStatic || field.kinds.contains(CompilerFacts.MACRO_FIELD_KIND) || field.meta.contains(NO_USING_META)
			|| field.overloads.exists(n -> n > 0) || field.types.length != 1
			? null
			: firstParamOf(field.type);
	}

	/**
	 * Whether the parameter type `param` takes a receiver of the type `base` (with supertypes `chain`) the way the
	 * extension form does — by unification, with no `@:from` or other implicit conversion running. A function's own type
	 * parameter, a structure and a function type convert nothing; a class or an interface takes the receiver when it is
	 * the receiver's type or one of its supertypes; a typedef counts when every configuration aliased it to a structure.
	 * An abstract parameter is refused, `Null` aside.
	 */
	private static function accepts(facts: CompilerFacts, param: String, base: String, chain: Array<String>): Bool {
		final type: String = FactsTypeText.unwrapNull(param);
		if (type.startsWith('$') || type.startsWith('{') || type.startsWith('(')) return true;
		final id: String = CompilerFacts.baseId(type);
		final declared: Null<TypeFact> = facts.type(id);
		if (declared == null) return false;
		return switch declared.kind {
			case 'class', 'interface':
				id == base || chain.contains(id);
			case 'typedef':
				declared.targets.length > 0 && declared.targets.foreach(t -> t.startsWith('{'));
			case _: false;
		};
	}

}

/** What the facts prove about one static call's extension form. */
enum ExtensionFactsVerdict {

	/** The extension form calls the same function with the same receiver. */
	Proven;

	/** A type of the receiver's hierarchy declares a member of the name, which the extension form would call instead. */
	Shadowed;

	/** The receiver is `Dynamic`: the extension form compiles and dispatches at run time. */
	DynamicReceiver;

	/** The facts prove neither. */
	Unproven;

}

/** What the facts say about the `using`s a site is reached by (`StaticExtensionFacts.usingsSupply`). */
private enum UsingSupply {

	/** No other `using` supplies the method. */
	None;

	/** Another `using` supplies it. */
	Supplied;

	/** A `using` names a type the facts do not hold. */
	Unread;

}
