package anyparse.query;

#if sys
import sys.FileSystem;
#end

/**
 * Minimal input-path expander for `apq search`.
 *
 * Supports:
 *  - A single file path → returns `[path]`.
 *  - A directory path → recursively walks and returns every regular
 *    file whose name ends in `extension` (e.g. `.hx`).
 *
 * Phase 2 keeps glob handling deliberately small — `{src,test}/**`
 * compound patterns and brace expansion are deferred until a real
 * user-driven need surfaces. Non-sys targets get an empty result;
 * callers handle the empty case as a configuration / target mismatch.
 */
@:nullSafety(Strict)
final class Glob {

	public static function expand(spec:String, extension:String):Array<String> {
		final out:Array<String> = [];
		#if sys
		if (!FileSystem.exists(spec)) return out;
		if (FileSystem.isDirectory(spec)) {
			collect(spec, extension, out);
		} else {
			out.push(spec);
		}
		out.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
		#end
		return out;
	}

	#if sys
	private static function collect(dir:String, extension:String, into:Array<String>):Void {
		for (name in FileSystem.readDirectory(dir)) {
			final path:String = dir + '/' + name;
			if (FileSystem.isDirectory(path)) {
				collect(path, extension, into);
			} else if (StringTools.endsWith(name, extension)) {
				into.push(path);
			}
		}
	}
	#end
}
