package anyparse.query;

#if (sys || nodejs)
import haxe.io.Path;
import sys.FileSystem;
#end

/**
 * The one answer to "which files does a declared registry path name": a file names itself, a directory names the
 * `.json` files directly inside it, sorted by name — so a registry may be one document or a directory of them, and every
 * reader (rule, op, build) sees the same files in the same order.
 */
@:nullSafety(Strict)
final class RegistryFiles {

	/** The ending of a document that belongs to a registry directory. */
	public static inline final EXTENSION: String = '.json';

	/** The files `path` names; none when it does not exist (or on a target without a file system). */
	public static function of(path: String): Array<String> {
		#if (sys || nodejs)
		if (!FileSystem.exists(path)) return [];
		if (!FileSystem.isDirectory(path)) return [path];
		final names: Array<String> = FileSystem.readDirectory(path).filter(name -> name.endsWith(EXTENSION));
		names.sort(Reflect.compare);
		return [for (name in names) Path.join([path, name])];
		#else
		return [];
		#end
	}

}
