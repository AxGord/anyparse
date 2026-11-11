package unit.query;

import anyparse.query.SymbolIndex;

using Lambda;

/**
 * An enum constructor inside a `#if` region, on either branch, is one of the enum's members of the index, so every reader
 * that asks the index for an enum's constructors (exhaustiveness proofs, references, import use) sees it.
 */
class SymbolIndexEnumRegionTest extends Test {

	@:pin('guard')
	public function testEnumConstructorInRegionIsAMember(): Void {
		final source: String = 'package pkg;\nenum Col {\n\tRed;\n\t#if foo\n\tBlue(x:Int, y:String);\n\t#else\n\tGreen;\n\t#end\n}\n';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'src/pkg/Col.hx', source: source }], new HaxeQueryPlugin());
		final info: Null<FileInfo> = index.fileInfo('src/pkg/Col.hx');
		Assert.notNull(info);
		final col: Null<TypeDeclInfo> = (info: FileInfo).types.find(t -> t.name == 'Col');
		Assert.notNull(col);
		final members: Array<MemberInfo> = (col: TypeDeclInfo).members;
		Assert.same(['Red', 'Blue', 'Green'], members.map(m -> m.name));
		Assert.equals(2, members[1].paramTypeSources.length);
		Assert.equals(0, members[2].paramTypeSources.length);
	}

}
