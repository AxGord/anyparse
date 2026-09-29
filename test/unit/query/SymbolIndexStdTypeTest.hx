package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `SymbolIndex.resolvesToStdType` answers false for what it cannot see — the clauses a rule-level
 * fixture does not reach: a file the index does not hold, and an ambient `import.hx` chain that
 * could not be bounded (one of its members does not parse, so it may import anything).
 */
class SymbolIndexStdTypeTest extends Test {

	public function testAFileTheIndexDoesNotHoldIsNoProof(): Void {
		final index: Null<SymbolIndex> = stdIndex([{ file: 'C.hx', source: 'class C {}' }]);
		if (index == null) return;
		Assert.isTrue(index.resolvesToStdType('List', 'C.hx'), 'control: the indexed file resolves the std List');
		Assert.isFalse(index.resolvesToStdType('List', 'Missing.hx'));
	}

	public function testAnUnboundedAmbientChainIsNoProof(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no installed Haxe std on this machine');
			return;
		}
		Assert.isTrue(resolvesInTree('import lib.Other;\n'), 'control: a chain that parses is bounded');
		Assert.isFalse(resolvesInTree('import a.T; ){{ not haxe\n'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `resolvesToStdType('List', …)` for `src/lib/C.hx` in an on-disk tree whose `src/lib/import.hx` reads `ambient`. */
	private function resolvesInTree(ambient: String): Bool {
		var answer: Bool = true;
		#if (sys || nodejs)
		final names: Array<String> = ['src/lib/Other.hx', 'src/lib/C.hx'];
		final root: String = CliFixture.writeTree('apq_std_type_ambient', [
			{ name: 'src/lib/import.hx', source: ambient },
			{ name: names[0], source: 'package lib;\n\nclass Other {}\n' },
			{ name: names[1], source: 'package lib;\n\nclass C {}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = names.map(name -> readEntry(root, name));
			final index: Null<SymbolIndex> = stdIndex(files);
			if (index != null) answer = index.resolvesToStdType('List', '$root/src/lib/C.hx');
		});
		#end
		return answer;
	}

	/** `files` indexed beside a std `List` stub filed under the discovered std root; null (and passed) without one. */
	private function stdIndex(files: Array<{ file: String, source: String }>): Null<SymbolIndex> {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.pass('no installed Haxe std on this machine');
			return null;
		}
		final stub: String = Path.join([std, 'List.hx']);
		return SymbolIndex.build(files.concat([{ file: stub, source: 'class List<T> {}' }]), new HaxeQueryPlugin(), [stub]);
	}

	/** The index entry for `name` under `root`, read off disk. */
	private static function readEntry(root: String, name: String): { file: String, source: String } {
		return #if (sys || nodejs) {
			file: '$root/$name',
			source: sys.io.File.getContent('$root/$name')
		} #else { file: '$root/$name', source: '' } #end;
	}

}
