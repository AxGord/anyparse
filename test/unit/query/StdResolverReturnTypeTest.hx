package unit.query;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * Verifies item 3(b): the derivable `staticMethodReturns` values are ANSWERED by the
 * resolution index itself once std is joined — `MemberLookup.returnNominalOf` resolves
 * `Date.now` → `Date` and `Context.resolvePath` → `String` straight from the std
 * declarations, so the T36 table is redundant when std is indexed (it stays only as
 * the import-safe config-less fallback). Skips when no std is installed.
 */
class StdResolverReturnTypeTest extends Test {

	public function testIndexResolvesTabledStaticReturns(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = StdResolver.stdDir();
		if (dir == null) {
			Assert.pass('no installed Haxe std — index return-type verification skipped');
			return;
		}
		final datePath: String = haxe.io.Path.join([dir, 'Date.hx']);
		final ctxPath: String = haxe.io.Path.join([dir, 'haxe/macro/Context.hx']);
		final files: Array<{ file: String, source: String }> = [
			{ file: datePath, source: File.getContent(datePath) },
			{ file: ctxPath, source: File.getContent(ctxPath) }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(
			'Date', index.members.returnNominalOf('Date', 'now'), 'the index resolves Date.now -> Date, so the tabled entry is derivable'
		);
		Assert.equals(
			'String', index.members.returnNominalOf('Context', 'resolvePath'), 'the index resolves Context.resolvePath -> String'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
