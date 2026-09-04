package anyparse.macro;

#if macro
/**
 * Dotted-type-path splitting, shared by every macro pass.
 *
 * `simpleName` and `packOf` answer the same two questions about a
 * fully-qualified type path, and until this module existed each pass
 * carried its own answer: NINE declarations of each across
 * `anyparse.macro` — seven byte-identical private copies, one public
 * pair in `PairedShapeLowering`, and a pair of inline forwarders in
 * `AstPredLowering` that already recorded somebody wanting a single
 * home. There is one now.
 *
 * Reached unqualified through `import anyparse.macro.MacroNames.*;`,
 * so a pass that used to declare its own copy keeps every call site
 * verbatim.
 */
final class MacroNames {

	/**
	 * The last segment of a dotted type path — `pkg.Sub.Type` becomes
	 * `Type`. A path with no dot is returned unchanged.
	 */
	public static function simpleName(typePath: String): String {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	/**
	 * The package segments of a dotted type path — `pkg.Sub.Type`
	 * becomes `['pkg', 'Sub']`. A path with no dot carries no package,
	 * so the result is empty.
	 */
	public static function packOf(typePath: String): Array<String> {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

}
#end
