package anyparse.check.haxe.expressions;

import anyparse.grammar.json.JValue;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

/**
 * A static function a project names to compare two values of one type; `nullable` when it takes the type as `Null<T>`, so it
 * answers for a `null` operand itself.
 */
typedef NamedCompare = { final typePath: String; final member: String; final nullable: Bool; }

/**
 * The compare functions one config chain names, each checked against the resolution index: the one answer to "which
 * function compares two values of this type in this file". A name the index cannot find, or whose signature is not
 * `(T, T): Int` or `(Null<T>, Null<T>): Int`, is a `problems` line and not an entry, so a caller never falls back silently.
 */
@:nullSafety(Strict)
final class CompareFunctions {

	/** A compare function takes exactly this many parameters. */
	private static inline final OPERANDS: Int = 2;

	private static final PUBLIC_VISIBILITY: String = 'public';

	/** What is wrong with the option as written; empty for a usable one. */
	public final problems: Array<String> = [];

	private final _named: Map<String, NamedCompare> = [];

	/** The function named for each of the `types` `option` spells; a qualified path means the same from every file. */
	public function new(
		option: Null<JValue>, key: String, types: Array<String>, intType: String, nullableWrapper: Null<String>,
		typeSyntax: TypeSyntaxReader, index: () -> Null<SymbolIndex>
	) {
		if (option == null) return;
		switch option {
			case JObject(fields):
				for (field in fields) {
					final type: String = field.key;
					if (!types.contains(type)) {
						problems.push('$key.$type: the types a function can be named for are ${types.join(', ')}');
						continue;
					}
					switch field.value {
						case JString(path): read(key, type, path, intType, nullableWrapper, typeSyntax, index);
						case _: problems.push('$key.$type is not a string');
					}
				}
			case _:
				problems.push('$key is not an object of a type name to a function path');
		}
	}

	public inline function isEmpty(): Bool {
		return !_named.iterator().hasNext();
	}

	/** The function named for `type`, or null when the project names none. */
	public function of(type: Null<String>): Null<NamedCompare> {
		return type == null ? null : _named[type];
	}

	private function read(
		key: String, type: String, path: String, intType: String, nullableWrapper: Null<String>, typeSyntax: TypeSyntaxReader,
		index: () -> Null<SymbolIndex>
	): Void {
		final dot: Int = path.lastIndexOf('.');
		if (dot <= 0 || dot == path.length - 1) {
			problems.push('$key.$type: "$path" is not a path of the form a.b.C.fn');
			return;
		}
		final typePath: String = path.substring(0, dot);
		final member: String = path.substring(dot + 1);
		final idx: Null<SymbolIndex> = index();
		final types: Array<ResolvedType> = idx == null ? [] : idx.refs.resolveQualifiedRefAll(typePath);
		if (types.length != 1) {
			problems.push(
				types.length == 0
					? '$key.$type: "$path" names no type: the resolution index declares no "$typePath"'
					: '$key.$type: "$path" is ambiguous: "$typePath" names ${types.length} types in the resolution index'
			);
			return;
		}
		if (types[0].type.isPrivate) {
			problems.push('$key.$type: "$path" names a private type, which no other file can call');
			return;
		}
		final found: Array<MemberInfo> = types[0].type.members.filter(m -> m.name == member);
		final plain: Bool = found.length == 1 && isCompareOf(found[0], type, intType, null, typeSyntax);
		final nullable: Bool = !plain
			&& found.length == 1
			&& nullableWrapper != null
			&& isCompareOf(found[0], type, intType, nullableWrapper, typeSyntax);
		final named: NamedCompare = { typePath: typePath, member: member, nullable: nullable };
		if (found.length == 0)
			problems.push('$key.$type: the resolution index declares no "$path"');
		else if (plain || nullable)
			_named[type] = named;
		else
			problems.push('$key.$type: "$path" is not one public static function ($type, $type): $intType');
	}

	/** `wrapper` set asks for both parameters as `wrapper<type>`, null for both as the bare `type`. */
	private static function isCompareOf(
		m: MemberInfo, type: String, intType: String, wrapper: Null<String>, typeSyntax: TypeSyntaxReader
	): Bool {
		return m.isStatic
			&& m.visibility == PUBLIC_VISIBILITY
			&& !m.guarded
			&& !m.isMacro
			&& !m.isDynamic
			&& !m.isOverload
			&& !m.hasOverloadMeta
			&& !m.paramRest
			&& m.paramSkippableFrom == OPERANDS
			&& m.paramTypeSources.length == OPERANDS
			&& m.paramTypeSources.foreach(source -> spells(source, type, wrapper, typeSyntax))
			&& spells(m.returnSource, intType, null, typeSyntax);
	}

	private static function spells(source: Null<String>, type: String, wrapper: Null<String>, typeSyntax: TypeSyntaxReader): Bool {
		if (source == null) return false;
		final bare: String = wrapper == null ? source : NominalTypes.unwrapNullable(source, [wrapper], typeSyntax);
		return (wrapper == null || bare != source) && NominalTypes.outerNominalOf(bare, typeSyntax) == type;
	}

}
