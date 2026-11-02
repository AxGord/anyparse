package unit.query;

import anyparse.query.StdResolver;
import anyparse.query.StdTypes;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeNameBinding;

using Lambda;

/**
 * The one table of std toplevel names (`StdTypes.toplevelPath`) against the std of the compiler: every name it lists the
 * std declares at its toplevel and denotes the path the table maps it to, and every name the std's `StdTypes` module
 * declares is in it.
 */
@:nullSafety(Strict)
@:access(anyparse.query.StdTypes)
class StdTypesTest extends Test {

	@:pin('guard')
	public function testEveryToplevelNameIsOneTheStdDeclares(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		for (name => path in StdTypes.TOPLEVEL) {
			Assert.isTrue(StdTypes.declaresToplevel(plugin, name), '`$name` is a type the std declares at its toplevel');
			Assert.isTrue(path == name || aliasTarget(plugin, name) == path, '`$name` denotes `$path`');
		}
	}

	@:pin('guard')
	public function testEveryNameOfTheStdTypesModuleIsInTheTable(): Void {
		for (name in TypeNameBinding.STD_TYPE_NAMES)
			Assert.equals(name, StdTypes.toplevelPath(name), '`$name` reaches every module bare, as itself');
	}

	/** What the root module `name` re-points its own type at, when that type is an alias. */
	private static function aliasTarget(plugin: HaxeQueryPlugin, name: String): Null<String> {
		final types: Array<TypeDeclInfo> = StdTypes.moduleTypes(plugin, name) ?? [];
		final own: Null<TypeDeclInfo> = types.find(t -> t.name == name);
		return own?.aliasTargetRaw;
	}

}
