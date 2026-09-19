package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The private-constructor shield under an AMBIENT import source, end to end through `unused-private`.
 *
 * An ambient `import pkg.Exception;` outranks the `lib.Exception` of the reader's own package, so a
 * `lib.Sub extends Exception` subtypes the IMPORTED one. Reading the wrong one un-shields a
 * constructor that a real subtype's `super()` calls, and the fix for this rule DELETES it — which is
 * why both halves are asserted: the type that is really subtyped keeps its finding withheld, the
 * namesake that is not loses it.
 *
 * The second pin puts the ambient source OUTSIDE the analysed set. The chain is a fact about the
 * tree, not about the scope a run was given, so a narrow run has to answer the same.
 */
@:nullSafety(Strict)
class AmbientImportSubtypeShieldTest extends Test {

	/** The subject tree: a namesake pair, an ambient source naming one of them, and a control with no namesake. */
	private static final TREE: Array<{ name: String, source: String }> = [
		{ name: 'lib/import.hx', source: 'import pkg.Exception;\n' },
		{ name: 'lib/Exception.hx', source: utilityClass('lib', 'Exception') },
		{ name: 'pkg/Exception.hx', source: utilityClass('pkg', 'Exception') },
		{ name: 'other/Zzzunique.hx', source: utilityClass('other', 'Zzzunique') },
		{
			name: 'lib/Sub.hx',
			source: 'package lib;\n\nclass Sub extends Exception {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n'
		}
	];

	/** A WILDCARD namesake tree: the compiler resolves `Sub`'s supertype through the explicit ambient import. */
	private static final WILD_TREE: Array<{ name: String, source: String }> = [
		{ name: 'lib/import.hx', source: 'import a.T;\n' },
		{ name: 'a/T.hx', source: utilityClass('a', 'T') },
		{ name: 'b/T.hx', source: utilityClass('b', 'T') },
		{
			name: 'lib/Sub.hx',
			source: 'package lib;\n\nimport b.*;\n\nclass Sub extends T {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n'
		}
	];

	/** An ALIAS namesake tree: the written `U` is bound by the ambient alias, which this layer does not resolve. */
	private static final ALIAS_TREE: Array<{ name: String, source: String }> = [
		{ name: 'lib/import.hx', source: 'import a.T as U;\n' },
		{ name: 'a/T.hx', source: utilityClass('a', 'T') },
		{ name: 'lib/U.hx', source: utilityClass('lib', 'U') },
		{ name: 'other/U.hx', source: utilityClass('other', 'U') },
		{
			name: 'lib/Sub.hx',
			source: 'package lib;\n\nclass Sub extends U {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n'
		}
	];

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-BAND')
	public function testTheAmbientlyImportedTypeKeepsTheShieldAndTheNamesakeLosesIt(): Void {
		#if (sys || nodejs)
		Assert.equals(
			'lib/Exception.hx,other/Zzzunique.hx', constructorFindings(TREE, false),
			'the subtype resolves to the ambiently imported `pkg.Exception`, so only the same-package namesake is reported'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-BAND')
	public function testTheChainIsReadEvenWhenItsFileIsOutsideTheAnalysedSet(): Void {
		#if (sys || nodejs)
		Assert.equals(
			'lib/Exception.hx,other/Zzzunique.hx', constructorFindings(TREE, true),
			'an ambient source the run was not given still decides what the subtype references'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-BAND')
	public function testTheWildcardTierShieldsTheTypeTheSupertypeReallyNames(): Void {
		#if (sys || nodejs)
		Assert.equals(
			'b/T.hx', constructorFindings(WILD_TREE, false),
			'the supertype resolves through the ambient EXPLICIT import, so `a.T` keeps its shield and only the wildcard namesake loses one'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-ALIAS-PINNED')
	public function testAWrittenAliasIsPinnedToNothingRatherThanToItsNamesake(): Void {
		#if (sys || nodejs)
		// The written `U` is bound by an ALIAS this layer does not follow, so no declaration of `U` may
		// be claimed as the supertype's owner — every namesake keeps its shield instead of one being
		// picked at random by package proximity.
		Assert.equals('', constructorFindings(ALIAS_TREE, false), 'an unresolvable alias withholds the edge from every namesake');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The tree-relative names of the files `unused-private` reports a constructor on, comma-joined in
	 * report order. `withoutAmbient` withholds the ambient source itself from the analysed set.
	 */
	private function constructorFindings(tree: Array<{ name: String, source: String }>, withoutAmbient: Bool): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_ambient_shield', tree);
		final analysed: Array<{ name: String, source: String }> = withoutAmbient ? tree.filter(e -> !e.name.endsWith('import.hx')) : tree;
		final files: Array<{ file: String, source: String }> = [
			for (entry in analysed) { file: '$root/${entry.name}', source: entry.source }
		];
		final reported: Array<String> = [];
		try {
			final violations: Array<Violation> = new UnusedPrivate().run(files, new HaxeQueryPlugin());
			for (v in violations) if (v.message.contains('constructor')) reported.push(v.file.substr(root.length + 1));
		} catch (exception: haxe.Exception) {
			CliFixture.removeDir(root);
			throw exception;
		}
		CliFixture.removeDir(root);
		return reported.join(',');
		#else
		return '';
		#end
	}

	/** A class whose only private member is its constructor — the shape `unused-private` reports. */
	private static function utilityClass(pkg: String, name: String): String {
		return 'package $pkg;\n\nclass $name {\n\n\tpublic static final K: Int = 1;\n\n\tprivate function new() {}\n\n}\n';
	}

}
