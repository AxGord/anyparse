package unit.check;

/**
 * A fixture build that counts its own compiles, whichever class spawned them: `SOURCE` is a `Counter.hx` whose init
 * macro appends a line to `compiles.log` in the compile's directory, `MACRO` is the hxml line that runs it, and `count`
 * reads the tally back.
 */
@:nullSafety(Strict)
final class CompileCounter {

	/** The hxml line that runs the counting macro in every compile of the build. */
	public static inline final MACRO: String = '--macro Counter.hit()\n';

	/** `Counter.hx`: `hit` appends one line to `compiles.log`. */
	public static final SOURCE: String = 'class Counter {\n\tpublic static function hit():Void {\n'
		+ '\t\tfinal out = sys.io.File.append(\'compiles.log\', false);\n\t\tout.writeString(\'x\\n\');\n\t\tout.close();\n\t}\n}\n';

	/** How many compiles of the build in `dir` ran. */
	public static function count(dir: String): Int {
		#if (sys || nodejs)
		final log: String = '$dir/compiles.log';
		return sys.FileSystem.exists(log) ? sys.io.File.getContent(log).split('\n').length - 1 : 0;
		#else
		return 0;
		#end
	}

}
