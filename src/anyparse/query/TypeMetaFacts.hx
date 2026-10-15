package anyparse.query;

import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;

/**
 * What the modifiers and metadata of each indexed type declaration say about how code reaches its members:
 * `extern` (its code belongs to the target), a build macro (it may gain members no declaration shows), a
 * construction from a literal (`@:structInit`), and `@:forward` (members
 * routed to the underlying type); and which declarations are classes.
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

	/** The types that bring static extensions in (`TypeDeclInfo.bringsExtensions`). */
	private final _extended: Map<String, Bool> = [];

	/** `@:forward` abstract name -> the simple name of the underlying type its calls are routed to. */
	private final _forwards: Map<String, String> = [];

	/** `@:forward` abstract name -> the head path each declaration of it writes as its underlying type, with the file writing it. */
	private final _forwardsWritten: Map<String, Array<{ path: String, file: String }>> = [];

	/** `@:forward(a, b)` abstract name -> the only members it forwards. */
	private final _forwardedOnly: Map<String, Array<String>> = [];

	/** The types some declaration of which is a class. */
	private final _classes: Map<String, Bool> = [];

	/** The grammar's class declaration kinds (`RefShape.classDeclKinds`). */
	private final _classKinds: Array<String>;

	/** The types some declaration of which is an enum (`RefShape.runtimeTaggedTypeKinds`). */
	private final _enums: Map<String, Bool> = [];

	/** The types some declaration of which is of any other kind. */
	private final _nonEnums: Map<String, Bool> = [];

	/** The grammar's enum declaration kinds (`RefShape.runtimeTaggedTypeKinds`). */
	private final _enumKinds: Array<String>;

	public function new(classKinds: Array<String>, ?enumKinds: Array<String>) {
		_classKinds = classKinds;
		_enumKinds = enumKinds ?? [];
	}

	/** Whether an indexed declaration of `typeName` is `extern` — a body-less member of it runs target code. */
	public inline function isExtern(typeName: String): Bool {
		return _externs.exists(typeName);
	}

	/**
	 * Whether every indexed declaration of `typeName` is an enum (`RefShape.runtimeTaggedTypeKinds`): a value of it is an
	 * instance of one of its constructors, never an object of a class. A typedef of a structure is not one — any object with
	 * the fields is a value of it — and neither is an abstract.
	 */
	public inline function isEnum(typeName: String): Bool {
		return _enums.exists(typeName) && !_nonEnums.exists(typeName);
	}

	/** Whether an indexed declaration of `typeName` is a class (`RefShape.classDeclKinds`). */
	public inline function isClass(typeName: String): Bool {
		return _classes.exists(typeName);
	}

	/** Whether an indexed declaration of `typeName` carries a build macro. */
	public inline function isBuilt(typeName: String): Bool {
		return _built.exists(typeName);
	}

	/** Whether a declaration of `typeName` is one the language constructs from a literal. */
	public inline function constructsFromLiteral(typeName: String): Bool {
		return _constructedFromLiteral.exists(typeName);
	}

	/** Whether a declaration of `typeName` brings static extensions in wherever a value of it is (Haxe `@:using`). */
	public inline function bringsExtensions(typeName: String): Bool {
		return _extended.exists(typeName);
	}

	/**
	 * The underlying type a `@:forward` abstract `typeName` routes `member` to — a member it does not declare
	 * itself, and one its `@:forward(...)` names when it names any — or null.
	 */
	public function forwardedTo(typeName: String, member: String): Null<String> {
		final only: Null<Array<String>> = _forwardedOnly[typeName];
		return only != null && !only.contains(member) ? null : _forwards[typeName];
	}

	/**
	 * The head path of the underlying type each declaration of the `@:forward` abstract `typeName` writes, with the file
	 * writing it — where the name is read (`CallGraphImports.keyedWhereWritten`); none for a `#if`-guarded declaration.
	 */
	public inline function forwardsWritten(typeName: String): Array<{ path: String, file: String }> {
		return _forwardsWritten[typeName] ?? [];
	}

	/** Fold the modifiers and metadata of one declaration, of the file keyed `file`. */
	public function record(t: TypeDeclInfo, file: String): Void {
		if (t.isExtern) _externs[t.name] = true;
		if (_classKinds.contains(t.kind)) _classes[t.name] = true;
		if (_enumKinds.contains(t.kind))
			_enums[t.name] = true
		else
			_nonEnums[t.name] = true;
		if (t.hasBuild || t.hasAutoBuild) _built[t.name] = true;
		if (t.constructsFromLiteral) _constructedFromLiteral[t.name] = true;
		if (t.bringsExtensions) _extended[t.name] = true;
		final forward: Null<String> = t.abstractForwardUnderlying;
		if (forward != null && forward != t.name) _forwards[t.name] = forward;
		final underlying: Null<String> = forward == null ? null : t.underlyingRaw;
		if (underlying != null) {
			final under: String = underlying;
			final written: Array<{ path: String, file: String }> = _forwardsWritten[t.name] ?? [];
			if (!written.exists(w -> w.path == under && w.file == file)) written.push({ path: under, file: file });
			_forwardsWritten[t.name] = written;
		}
		final only: Null<Array<String>> = t.forwardedMembers;
		if (only != null) _forwardedOnly[t.name] = only;
	}

}
