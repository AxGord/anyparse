package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr.ExprOf;
#end

/** A source file of the class path, read while compiling: the text a runtime writes out for another compile to run. */
@:nullSafety(Strict)
final class EmbeddedSource {

	/** The content of `path`, resolved against the class path; the compile depends on the file, so an edit rebuilds. */
	public static macro function text(path: String): ExprOf<String> {
		final resolved: String = Context.resolvePath(path);
		Context.registerModuleDependency(Context.getLocalModule(), resolved);
		return macro $v{sys.io.File.getContent(resolved)};
	}

}
