package anyparse.query;

import anyparse.query.SymbolIndex.TypeDeclInfo;

/**
 * What the modifiers and metadata of each indexed type declaration say about how code reaches its members:
 * `extern` (its code belongs to the target), a build macro (it may gain members no declaration shows), a
 * construction from a literal (`@:structInit`), and `@:forward` (members routed to the underlying type).
 * Simple names; a later declaration of a name adds to the earlier.
 */
@:nullSafety(Strict)
final class TypeMetaFacts {

	/** The types declared `extern`. */
	private final _externs: Map<String, Bool> = [];

	/** The types carrying a build macro (`@:build`, or `@:autoBuild` for their descendants). */
	private final _built: Map<String, Bool> = [];

	/** The types the language constructs from a literal (`TypeDeclInfo.constructsFromLiteral`). */
	private final _constructedFromLiteral: Map<String, Bool> = [];

	/** `@:forward` abstract name -> the simple name of the underlying type its calls are routed to. */
	private final _forwards: Map<String, String> = [];

	/** `@:forward(a, b)` abstract name -> the only members it forwards. */
	private final _forwardedOnly: Map<String, Array<String>> = [];

	public function new() {}

	/** Whether an indexed declaration of `typeName` is `extern` — a body-less member of it runs target code. */
	public inline function isExtern(typeName: String): Bool {
		return _externs.exists(typeName);
	}

	/** Whether an indexed declaration of `typeName` carries a build macro. */
	public inline function isBuilt(typeName: String): Bool {
		return _built.exists(typeName);
	}

	/** Whether a declaration of `typeName` is one the language constructs from a literal. */
	public inline function constructsFromLiteral(typeName: String): Bool {
		return _constructedFromLiteral.exists(typeName);
	}

	/**
	 * The underlying type a `@:forward` abstract `typeName` routes `member` to — a member it does not declare
	 * itself, and one its `@:forward(...)` names when it names any — or null.
	 */
	public function forwardedTo(typeName: String, member: String): Null<String> {
		final only: Null<Array<String>> = _forwardedOnly[typeName];
		return only != null && !only.contains(member) ? null : _forwards[typeName];
	}

	/** Fold the modifiers and metadata of one declaration. */
	public function record(t: TypeDeclInfo): Void {
		if (t.isExtern) _externs[t.name] = true;
		if (t.hasBuild || t.hasAutoBuild) _built[t.name] = true;
		if (t.constructsFromLiteral) _constructedFromLiteral[t.name] = true;
		final forward: Null<String> = t.abstractForwardUnderlying;
		if (forward != null && forward != t.name) _forwards[t.name] = forward;
		final only: Null<Array<String>> = t.forwardedMembers;
		if (only != null) _forwardedOnly[t.name] = only;
	}

}
