package dev;

import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.LexicalRegions.LexRegionKind;
import dev.SuiteImpact.ImpactModule;
import dev.SuiteImpact.ImpactSource;

using anyparse.util.Groups;
using Lambda;
using StringTools;

/**
 * The one answer to "which test classes read the whole test tree, so a change to any test file reaches them": a class that
 * names the directory walker the tree guards share and holds the test root as a string literal. No text dependency leads
 * from a touched test file to such a guard, which only lists what the directory holds.
 */
@:nullSafety(Strict)
final class TestTreeReaders {

	/** The directory walker the whole-tree test guards share. */
	private static final WALKER: String = 'SourceTree';

	/** The root a guard hands the walker to read the test tree. */
	private static final ROOT: String = 'test';

	/** Adds to `classes` the qualified names of those classes of `sources` when `touched` holds a `.hx` file under the test root. */
	public static function addTo(classes: Array<String>, sources: Array<ImpactSource>, touched: Array<String>): Void {
		if (!touched.exists(path -> SuiteImpact.isTest(path) && path.endsWith('.hx'))) return;
		for (source in sources) {
			final module: Null<ImpactModule> = SuiteImpact.isTestClass(source.path) ? SuiteImpact.moduleOf(source.path) : null;
			if (module != null && SuiteImpact.names(SuiteImpact.uncommented(source.text), WALKER) && holdsRoot(source.text))
				classes.pushUnique(module.qualified);
		}
	}

	private static function holdsRoot(text: String): Bool {
		return new HaxeQueryPlugin().lexicalRegions(text)
			.exists(region -> region.kind == LexRegionKind.StringLit && text.substring(region.from + 1, region.to - 1) == ROOT);
	}

}
