package anyparse.check;

#if macro
import haxe.Json;
import haxe.macro.Type;

using StringTools;

/**
 * The PRINTING half of the facts type grammar (`TypedFactsProbe` specifies it, `FactsTypeTree` reads it back): a
 * compiler `Type` as the type string a facts record carries, plus the two JSON spellings every record line is built
 * from (`q`, `arr`).
 *
 * Its own module rather than more of `TypedFactsMacro` because it is a pure function of the type it prints — the
 * writer decides which records a compile produces, this decides how a type reads in them — and both the type writer
 * and the body walk (`TypedFactsWalk`) print through it. The one state it keeps is what printing ran into: the
 * typedefs a string named (`printedTypedefs`), which the writer then records, and a per-path memo of which classes are
 * type parameters.
 */
@:nullSafety(Strict)
final class TypedFactsTypeStrings {

	/** Deeper type nesting prints as unknown, so a recursive structure cannot grow a line without bound. */
	private static inline final TYPE_DEPTH: Int = 8;

	/** Whether each class path names a type parameter, decided once per path: reading a `Ref` decodes the whole class. */
	private static final typeParams: Map<String, Bool> = [];

	/**
	 * Every typedef a type string printed, by id and declaration: an import alias (`import pack.T as U`) is one no module
	 * lists, so the compile's records are closed over them once the module types are written (`run`). Two aliases of one
	 * name of one module share an id, and each gets a record: the table holds every target an id names.
	 */
	public static final printedTypedefs: Map<String, Ref<DefType>> = [];

	/** `s` as a JSON string. Names, paths and type strings carry no control character, so only a quote or a backslash needs the printer. */
	public static function q(s: String): String {
		return s.indexOf('"') < 0 && s.indexOf('\\') < 0 ? '"$s"' : Json.stringify(s);
	}

	/** `items`, each already JSON, as a JSON array. */
	public static function arr(items: Array<String>): String {
		return '[' + items.join(',') + ']';
	}

	/** The id of a type: its package, then its name, which is how the compiler names it — a private type's package ends in its module. */
	public static function typeId(pack: Array<String>, name: String): String {
		return pack.length == 0 ? name : pack.join('.') + '.$name';
	}

	/** `t` in the facts type grammar (`TypedFactsProbe`). */
	public static function typeString(t: Null<Type>, depth: Int): String {
		if (t == null || depth > TYPE_DEPTH) return '?';
		return switch t {
			case TMono(r):
				final bound: Null<Type> = r.get();
				bound == null ? '?' : typeString(bound, depth);
			case TLazy(f): typeString(f(), depth);
			case TInst(c, params): instString(c, params, depth);
			case TEnum(e, params): e.toString() + paramString(params, depth);
			case TType(d, params):
				// the compiler names the typedef of a type's statics after it (`Enum<pack.E>`), which carries no arguments of its own
				final name: String = d.toString();
				if (!name.endsWith('>')) printedTypedefs['$name@${d.get().pos}'] = d;
				name.endsWith('>') ? name : name + paramString(params, depth);
			case TAbstract(a, params): a.toString() + paramString(params, depth);
			case TDynamic(null): 'Dynamic';
			case TDynamic(inner): 'Dynamic<${typeString(inner, depth + 1)}>';
			case TFun(args, ret):
				'(' + [for (a in args) (a.opt ? '?' : '') + typeString(a.t, depth + 1)].join(',') + ')->' + typeString(ret, depth + 1);
			case TAnonymous(a):
				final anon: AnonType = a.get();
				switch anon.status {
					case AClassStatics(c): 'Class<' + c.toString() + '>';
					case AEnumStatics(e): 'Enum<' + e.toString() + '>';
					case AAbstractStatics(ab): 'Abstract<' + ab.toString() + '>';
					case _:
						final fields: Array<ClassField> = anon.fields.copy();
						fields.sort((x, y) -> if (x.name < y.name)
							-1
						else if (x.name > y.name)
							1
						else
							0);
						'{'
							+ [
								for (f in fields) (f.meta.has(':optional') ? '?' : '') + f.name + ':' + typeString(f.type, depth + 1)
							].join(',') + '}';
				}
		};
	}

	public static function instString(c: Ref<ClassType>, params: Array<Type>, depth: Int): String {
		final path: String = c.toString();
		var isParam: Null<Bool> = typeParams[path];
		if (isParam == null) {
			isParam = c.get().kind.match(KTypeParameter(_));
			typeParams[path] = isParam;
		}
		return isParam ? '$$$path' : path + paramString(params, depth);
	}

	private static function paramString(params: Array<Type>, depth: Int): String {
		return params.length == 0 ? '' : '<' + [for (p in params) typeString(p, depth + 1)].join(',') + '>';
	}

	public static function typeList(list: Array<Type>): String {
		return arr([for (t in list) q(typeString(t, 0))]);
	}

}
#end
