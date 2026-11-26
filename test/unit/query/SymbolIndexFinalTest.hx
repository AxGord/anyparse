package unit.query;

import anyparse.query.SymbolIndex;

/** `TypeDeclInfo.isFinal`: only a `final class` is recorded final, and a `#if` pair of declarations agrees only when both are. */
class SymbolIndexFinalTest extends Test {

	public function testIsFinalMarksOnlyAFinalClass(): Void {
		final source: String = 'package pkg;\nfinal class Sealed {}\nclass Plain {}\n#if js\nfinal class Both {}\n#else\n'
			+ 'final class Both {}\n#end\n#if js\nfinal class Half {}\n#else\nclass Half {}\n#end\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/F.hx', source: source }], new HaxeQueryPlugin());
		final info: Null<FileInfo> = index.fileInfo('src/pkg/F.hx');
		Assert.notNull(info);
		final finals: Map<String, Bool> = [ for (t in (info: FileInfo).types) t.name => t.isFinal ];
		Assert.isTrue(finals['Sealed']);
		Assert.isFalse(finals['Plain']);
		Assert.isTrue(finals['Both']);
		Assert.isFalse(finals['Half']);
	}

}
