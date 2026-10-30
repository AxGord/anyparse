package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr.ExprOf;
#end

/**
 * A file of the class path, read or located while compiling: the text a runtime writes out for another compile to run,
 * or the path of a file the runtime reads.
 */
@:nullSafety(Strict)
final class EmbeddedSource {

	/** The content of `path`, resolved against the class path; the compile depends on the file, so an edit rebuilds. */
	public static macro function text(path: String): ExprOf<String> {
		final resolved: String = Context.resolvePath(path);
		Context.registerModuleDependency(Context.getLocalModule(), resolved);
		return macro $v{sys.io.File.getContent(resolved)};
	}

	/**
	 * The absolute path of `path`, resolved against the class path while compiling: a file the runtime reads where the
	 * engine was built from rather than carries in its own bytes. The compile fails when the file is not there.
	 */
	public static macro function located(path: String): ExprOf<String> {
		final resolved: String = Context.resolvePath(path);
		return macro $v{sys.FileSystem.fullPath(resolved)};
	}

}
