package dev;

import anyparse.util.Compare;
import haxe.Exception;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

/** One `apq.json` key as the typed schema declares it. */
typedef ConfigKey = { var name: String; var type: String; }

/**
 * The one answer to "which top-level keys does the typed `apq.json` schema declare": the fields of the `ApqLintConfig`
 * typedef, by name with their type spelled by simple names, read when the caller compiles. Kept apart from its consumer
 * because a macro types its whole class in the macro context, where a class built by `@:build` cannot load.
 */
@:nullSafety(Strict)
final class ConfigKeys {

	/** The declared keys of `ApqLintConfig`, by name. */
	public static macro function declared(): Expr {
		final fields: Array<ClassField> = switch Context.follow(Context.getType('anyparse.check.config.ApqLintConfig')) {
			case TAnonymous(anon): anon.get().fields;
			case _: throw new Exception('ApqLintConfig is not a structure');
		};
		fields.sort((a, b) -> Compare.compareString(a.name, b.name));
		return macro $v{[ for (field in fields) { name: field.name, type: typeName(field.type) } ]};
	}

	#if macro
	/** A type as a reader of `apq.json` meets it: simple names, a key's `Null` wrapper dropped. */
	private static function typeName(type: Type): String {
		return switch type {
			case TAbstract(ref, [inner]) if (ref.get().name == 'Null'): typeName(inner);
			case TAbstract(ref, params): spelled(ref.get().name, params);
			case TInst(ref, params): spelled(ref.get().name, params);
			case TEnum(ref, params): spelled(ref.get().name, params);
			case TType(ref, params): spelled(ref.get().name, params);
			case _: Std.string(type);
		};
	}

	/** `name` with its type parameters spelled the same way. */
	private static function spelled(name: String, params: Array<Type>): String {
		return params.length == 0 ? name : '$name<${params.map(typeName).join(', ')}>';
	}
	#end

}
