package anyparse.grammar.haxe;

import anyparse.query.MemberKinds;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.PropertyClause;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The neutral modifiers a Haxe PROPERTY earns from its storage, for the naming projection (`HaxeNamingSupport`) - the
 * A6 policy (a user decision, 2026-10-18): a property with no storage of its own is a method in disguise, and the
 * private-field `_` marks STORAGE, so the built-in policy names it by a rule of its own; a `public static` one that
 * also admits no write reads as a constant and takes the static-final format.
 *
 * Both modifiers are CONFERRED, never spelled, like `HaxeNamingSupport.INTERFACE_MOD`: a policy loaded from a
 * `checkstyle.json` selects on neither, so its member rules govern a property exactly as before.
 */
@:nullSafety(Strict)
final class HaxePropertyStorage {

	/**
	 * The modifier a property with no storage of its own carries: its clause names no storage slot
	 * (`PropertyClause.storageless`) and its leading run proves no `@:isVar` grants one.
	 */
	public static inline final STORAGELESS_MOD: String = 'storageless';

	/** The modifier a storage-less property ALSO carries when its write accessor is `never`. */
	public static inline final READ_ONLY_MOD: String = 'readOnly';

	/** The annotation that grants a property physical storage whatever its accessors say. */
	private static inline final IS_VAR_META: String = '@:isVar';

	/** The node kind of a conditional-compilation region (`#if` … `#end`). */
	private static inline final CONDITIONAL_KIND: String = 'Conditional';

	/**
	 * The storage modifiers of the declaration `node` of `category`. Only a FIELD earns any, and only as the `head` of
	 * its binding list: a `VarMore` after the comma inherits the head's modifier run, while a clause belongs to one
	 * binding. `properties` are the caller's facts and `run` the declaration's leading run (`HaxeNamingSupport.leadingRun`,
	 * asked only when the clause is storage-less).
	 *
	 * Empty without facts, for a plain field, for a property with storage, and whenever the run carries an `@:isVar` or
	 * crosses a conditional region, where an `@:isVar` some build sees may sit: an unproven property keeps the reading
	 * it had.
	 */
	public static function modsOf(
		node: QueryNode, category: NamingCategory, head: Bool, properties: Null<() -> Map<Int, PropertyClause>>,
		run: () -> Array<QueryNode>
	): Array<String> {
		final span: Null<Span> = node.span;
		if (category != NamingCategory.Field || !head || properties == null || span == null) return [];
		final clause: Null<PropertyClause> = properties()[span.from];
		return if (clause == null || !clause.storageless || run().exists(grantsStorage))
			[]
		else if (clause.readOnly)
			[STORAGELESS_MOD, READ_ONLY_MOD]
		else
			[STORAGELESS_MOD];
	}

	/** Whether the run sibling `node` may grant storage: an `@:isVar`, or a region one of whose builds may hold one. */
	private static function grantsStorage(node: QueryNode): Bool {
		return node.kind == CONDITIONAL_KIND || MemberKinds.META_KINDS.contains(node.kind) && node.name == IS_VAR_META;
	}

}
