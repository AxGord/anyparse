package anyparse.query;

/**
 * The one answer to "which module, and which type inside it, does a mutation arm's `type` address": `pack.Module` is the
 * module's main type, `pack.Module.Sub` a type declared beside it in the same file. Packages are lower-initial and types
 * upper-initial, so the split needs no filesystem; a path that is neither shape is read as a plain module path and left to
 * the caller's own "no such module" complaint.
 *
 * Macro code reads this class, so it holds no parser: only names and selectors.
 */
@:nullSafety(Strict)
final class ArmTypePath {

	/** The node kind a sub-module type's declaration projects as. */
	public static inline final SUB_KIND: String = 'ClassForm';

	/** The module path of `type`: the file `pack/Module.hx` holds it. `type` itself unless it names a sub-module type. */
	public static function moduleOf(type: String): String {
		final sub: Null<String> = subTypeOf(type);
		return sub == null ? type : type.substring(0, type.length - sub.length - 1);
	}

	/** The sub-module type `type` names (`Sub` of `pack.Module.Sub`), or null for a module's own main type. */
	public static function subTypeOf(type: String): Null<String> {
		final segments: Array<String> = type.split('.');
		final packageLength: Int = PackageDocuments.packageOf(type).split('.').filter(s -> s != '').length;
		return segments.length - packageLength == 2 ? segments[segments.length - 1] : null;
	}

	/** The `hxq --select` address of the member selector `member` of `type`: inside the sub-module type when it names one. */
	public static function select(type: String, member: String): String {
		final sub: Null<String> = subTypeOf(type);
		return sub == null ? member : '$SUB_KIND:$sub >> $member';
	}

	/**
	 * The name `hxq graph` gives the member `method` of `type`: `<package>.<Sub>.<method>` for a sub-module type, the type path
	 * and the method for a module's main type.
	 */
	public static function graphMember(type: String, method: String): String {
		final sub: Null<String> = subTypeOf(type);
		if (sub == null) return '$type.$method';
		final pack: String = PackageDocuments.packageOf(type);
		return pack == '' ? '$sub.$method' : '$pack.$sub.$method';
	}

}
