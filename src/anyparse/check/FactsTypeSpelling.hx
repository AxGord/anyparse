package anyparse.check;

import anyparse.check.Check.OracleType;
import anyparse.check.FactsTypeTree.FactsArgument;
import anyparse.check.FactsTypeTree.FactsField;
import anyparse.check.FactsTypeTree.FactsType;

/** The type parameters a spelled type may name: those of the type `owner` (an id) and of the method `method`. */
typedef TypeScope = {
	final owner: Null<String>;
	final method: Null<String>;
}

/**
 * A type in the facts type grammar (`TypedFactsProbe`) spelled as Haxe source: the type read (`FactsTypeTree`), then
 * written part by part, `_failure` saying why it stopped. `spell` is the entry.
 */
@:nullSafety(Strict)
final class FactsTypeSpelling {

	private var _failure: Null<String> = null;

	private final _scope: TypeScope;

	private function new(scope: TypeScope) {
		_scope = scope;
	}

	/**
	 * `type` spelled as Haxe source — `(Int,?String)->Bool` as `(Int, ?String) -> Bool`, a type parameter `$pack.Box.T`
	 * as `pack.Box.T` — or `Declined` when no source can write it: an unknown anywhere in it, a type parameter `scope`
	 * does not hold (`inScope`), an abstract's statics (`Abstract<…>`) or implementation class.
	 */
	public static function spell(type: String, scope: TypeScope): OracleType {
		final read: Null<FactsType> = FactsTypeTree.read(type);
		if (read == null) return Declined(FactsTypeOracle.DECLINE_NO_FACT);
		final writer: FactsTypeSpelling = new FactsTypeSpelling(scope);
		final spelled: Null<String> = writer.type(read);
		final failure: Null<String> = writer._failure;
		return failure != null || spelled == null ? Declined(failure ?? FactsTypeOracle.DECLINE_NO_FACT) : Typed(spelled);
	}

	/** Whether the type parameter `path` (`<owner>.<name>`) is one `scope` holds: its owner is the scope's type or method. */
	public static function inScope(path: String, scope: TypeScope): Bool {
		final dot: Int = path.lastIndexOf('.');
		final owner: String = dot < 0 ? '' : path.substr(0, dot);
		return owner != '' && (owner == scope.owner || owner == scope.method);
	}

	/** `t` spelled; null once `_failure` is set. */
	public function type(t: FactsType): Null<String> {
		if (_failure != null) return null;
		return switch t {
			case Unknown: fail(FactsTypeOracle.DECLINE_UNKNOWN);
			case Function(args, result): functionType(args, result);
			case Structure(fields): structure(fields);
			case Parameter(path): typeParameter(path);
			case Named(name, args): nominal(name, args);
		};
	}

	private function functionType(args: Array<FactsArgument>, result: FactsType): Null<String> {
		final spelled: Array<String> = [];
		for (a in args) {
			final arg: Null<String> = type(a.type);
			if (arg == null) return null;
			spelled.push((a.optional ? '?' : '') + arg);
		}
		final out: Null<String> = type(result);
		return out == null ? null : '(${spelled.join(', ')}) -> $out';
	}

	private function structure(fields: Array<FactsField>): Null<String> {
		final spelled: Array<String> = [];
		for (f in fields) {
			final field: Null<String> = type(f.type);
			if (field == null) return null;
			spelled.push((f.optional ? '?' : '') + '${f.name}:$field');
		}
		return '{${spelled.join(', ')}}';
	}

	private function typeParameter(path: String): Null<String> {
		return inScope(path, _scope) ? path : fail('its type names the type parameter `$path`, which is not in scope at the declaration');
	}

	private function nominal(name: String, args: Array<FactsType>): Null<String> {
		if (name == 'Abstract' || name.indexOf('_Impl_') >= 0) return fail(FactsTypeOracle.DECLINE_UNSPELLABLE);
		if (args.length == 0) return name;
		final spelled: Array<String> = [];
		for (a in args) {
			final arg: Null<String> = type(a);
			if (arg == null) return null;
			spelled.push(arg);
		}
		return '$name<${spelled.join(', ')}>';
	}

	private function fail(reason: String): Null<String> {
		if (_failure == null) _failure = reason;
		return null;
	}

}
