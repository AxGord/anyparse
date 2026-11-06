package devkit;

using StringTools;

/**
 * The one answer to "which test classes a narrow test build registers": the define a build carries to register only
 * the classes it lists, written by `dev mutation-check` and read by `testkit.TestDiscovery`, which then types those
 * classes and nothing else of the test tree. A build without the define registers every class.
 */
@:nullSafety(Strict)
final class NarrowBuild {

	/** The define a narrow build carries; its value is the comma-separated class list. */
	public static inline final DEFINE: String = 'anyparse_narrow';

	/** The `-D` argument that narrows a build to `classes`. */
	public static function define(classes: Array<String>): String {
		return '$DEFINE=${classes.join(',')}';
	}

	/** The classes the define value `value` lists, in order, each once; a blank entry is dropped. */
	public static function classes(value: Null<String>): Array<String> {
		final names: Array<String> = [];
		for (entry in (value ?? '').split(',')) {
			final name: String = entry.trim();
			if (name != '' && !names.contains(name)) names.push(name);
		}
		return names;
	}

}
