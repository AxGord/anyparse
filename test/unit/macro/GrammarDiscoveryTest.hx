package unit.macro;

import anyparse.macro.GrammarDiscovery;
import haxe.macro.Expr.Position;
import haxe.macro.Type;
import unit.cli.CliFixture;

/**
 * `GrammarDiscovery`: which files under the classpath roots are grammar plugin modules, in what order, and which claims clash.
 */
@:nullSafety(Strict)
class GrammarDiscoveryTest extends Test {

	/** The position of every hand-built typed expression. */
	private static final POS: Position = { file: '', min: 0, max: 0 };

	/**
	 * Only a `*QueryPlugin.hx` outside every dot-entry is a plugin module, named by its path under the root; a root
	 * given twice yields each module once, the result is sorted by module path, and an empty root is skipped.
	 */
	@:killer('M-GRAMMAR-DISCOVERY-DOT-ENTRIES')
	@:pin('control')
	public function testOnlyAVisibleQueryPluginFileIsAModule(): Void {
		final root: String = CliFixture.writeTree('grammar_discovery', [
			{ name: 'a/b/YQueryPlugin.hx', source: '' },
			{ name: '.hidden/XQueryPlugin.hx', source: '' },
			{ name: '.WQueryPlugin.hx', source: '' },
			{ name: 'c/ZQueryPluginTest.hx', source: '' },
			{ name: 'c/VQueryPlugin.txt', source: '' },
			{ name: 'AQueryPlugin.hx', source: '' }
		]);
		CliFixture.always(
			CliFixture.removeDir.bind(root),
			() -> Assert.same(['AQueryPlugin', 'a.b.YQueryPlugin'], GrammarDiscovery.pluginModules(['', root, root]))
		);
	}

	/** Two plugins declaring one `LANG` are a clash naming both modules, the earlier one first. */
	@:killer('M-GRAMMAR-CLASH-LANG-IGNORED')
	@:pin('control')
	public function testTwoPluginsOfOneLangClash(): Void {
		Assert.equals(
			'grammar plugins a.AQueryPlugin and b.BQueryPlugin both declare LANG "x", so the CLI cannot tell which one it dispatches',
			GrammarDiscovery.clash([
				{ module: 'a.AQueryPlugin', lang: 'x', extensions: ['.a'] },
				{ module: 'b.BQueryPlugin', lang: 'x', extensions: ['.b'] }
			])
		);
	}

	/** Two plugins declaring one file extension are a clash naming both modules, whatever their other extensions. */
	@:killer('M-GRAMMAR-CLASH-EXTENSION-IGNORED')
	@:pin('control')
	public function testTwoPluginsOfOneExtensionClash(): Void {
		Assert.equals(
			'grammar plugins a.AQueryPlugin and b.BQueryPlugin both declare the extension ".s",'
			+ ' so the CLI cannot tell which one a file of it goes to',
			GrammarDiscovery.clash([
				{ module: 'a.AQueryPlugin', lang: 'a', extensions: ['.a', '.s'] },
				{ module: 'b.BQueryPlugin', lang: 'b', extensions: ['.b', '.s'] }
			])
		);
	}

	/**
	 * A claim's initialiser is read as a string literal or an array literal of them, through parentheses, metadata and
	 * unchecked casts.
	 */
	@:killer('M-GRAMMAR-LITERAL-NO-WRAPPERS')
	@:pin('control')
	public function testLiteralClaimsAreReadThroughWrappers(): Void {
		Assert.same(['x'], GrammarDiscovery.strings(typed(TConst(TString('x')))));
		Assert.same(
			['.a', '.b'],
			GrammarDiscovery.strings(typed(TParenthesis(typed(TArrayDecl([typed(TConst(TString('.a'))), typed(TConst(TString('.b')))])))))
		);
		Assert.same(
			['y'], GrammarDiscovery.strings(typed(TMeta({ name: ':m', pos: POS }, typed(TCast(typed(TConst(TString('y'))), null)))))
		);
	}

	/** An initialiser holding anything but string literals is no claim at all — never a list shortened to its literals. */
	@:killer('M-GRAMMAR-LITERAL-PARTIAL')
	@:pin('control')
	public function testANonLiteralClaimIsRefused(): Void {
		Assert.isNull(GrammarDiscovery.strings(typed(TArrayDecl([typed(TConst(TString('.a'))), typed(TConst(TInt(1)))]))));
		Assert.isNull(GrammarDiscovery.strings(typed(TConst(TInt(1)))));
	}

	/** Distinct claims are no clash, and neither is one plugin naming its own extension twice. */
	@:killer('M-GRAMMAR-CLASH-OWN-EXTENSION')
	@:pin('control')
	public function testDistinctClaimsDoNotClash(): Void {
		Assert.isNull(GrammarDiscovery.clash([
			{ module: 'a.AQueryPlugin', lang: 'a', extensions: ['.a', '.a'] },
			{ module: 'b.BQueryPlugin', lang: 'b', extensions: ['.b'] }
		]));
	}

	/** A typed expression of `def` with no position or type a reader of literals looks at. */
	private static function typed(def: TypedExprDef): TypedExpr {
		return { expr: def, pos: POS, t: TDynamic(null) };
	}

}
