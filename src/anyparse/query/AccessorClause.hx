package anyparse.query;

/**
 * The two accessor identifiers of a property's `(read, write)` clause, as written, and what they say about the
 * property's storage — the one answer to "what do a property's read and write accessors say". A grammar's span walk
 * reads the pair off the declaration node (`TypeInfoProvider.accessorClauses`), never off the source text.
 *
 * The predicates speak Haxe's accessor vocabulary (`default` / `null` / `get` / `set` / `never` / `dynamic`), the one
 * grammar whose declarations carry such a clause today.
 */
@:nullSafety(Strict)
final class AccessorClause {

	/** The accessor that admits no access at all. */
	private static final NEVER_ACCESSOR: String = 'never';

	/** The write accessor that routes a write through the property's set accessor. */
	private static final SET_ACCESSOR: String = 'set';

	/**
	 * The accessor identifiers that give a property no storage of its own: a call through `get_` / `set_`, or no access at
	 * all. Haxe makes a property physical when either accessor is `default` / `null` or it carries `@:isVar` (4.3.7: a
	 * `(get, never)` getter reading its own name is "not a real variable"), so a clause whose two slots both come from this
	 * list has storage only when `@:isVar` grants it. A positive list: `dynamic`, and any spelling not here, is not
	 * proven storage-less.
	 */
	private static final STORAGELESS_ACCESSORS: Array<String> = ['get', 'set', 'never'];

	/** The read accessors under which a plain read returns the physical field itself. */
	private static final FIELD_READS: Array<String> = ['default', 'null'];

	/** The read accessor identifier, as written. */
	public final read: String;

	/** The write accessor identifier, as written. */
	public final write: String;

	public function new(read: String, write: String) {
		this.read = read;
		this.write = write;
	}

	/** Whether the write accessor is `never` - no write from anywhere, the declaring type included. */
	public inline function writesNever(): Bool {
		return write == NEVER_ACCESSOR;
	}

	/**
	 * Whether a plain read returns the property's physical field (`default` / `null`) while a write runs its set
	 * accessor — the shape whose field holds only what that accessor, or a direct access, stores.
	 */
	public function readsFieldWritesThroughSetter(): Bool {
		return FIELD_READS.contains(read) && write == SET_ACCESSOR;
	}

	/**
	 * Whether neither slot names a storage slot (see `STORAGELESS_ACCESSORS`). The `@:isVar` half of the question is the
	 * caller's: the annotation sits in the member's modifier run, not in the clause.
	 */
	public function storageless(): Bool {
		return STORAGELESS_ACCESSORS.contains(read) && STORAGELESS_ACCESSORS.contains(write);
	}

}
