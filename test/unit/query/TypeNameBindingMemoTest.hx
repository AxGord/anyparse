package unit.query;

import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeRefIndex;
import haxe.Exception;
import unit.CheckFixture;

/**
 * The RUN-scoped memos of `TypeNameBinding` (`tierOf`, the package tier) and the file-name table of `TypeRefIndex`
 * (`fileNamed`). None of them changes an answer, so only the MECHANISM can tell a live memo from a dead one: the very
 * same declaration array comes back on the second ask, and a question the memo must not answer is asked afresh.
 */
@:nullSafety(Strict)
class TypeNameBindingMemoTest extends Test {

	/** A second ask of one (file, name, offset) hands back the same declarations; another index is another run. */
	@:pin('control')
	@:killer('M-BINDING-TIER-NOMEMO')
	public function testATierIsAnsweredOncePerFileNameAndOffset(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/X.hx', source: 'package a;\n\nclass X {}\n' },
			{ file: 'Main.hx', source: 'import a.X;\n\nclass Main {}\n' }
		];
		final index: SymbolIndex = indexOf(files);
		final fi: FileInfo = fileOf(index, 'Main.hx');
		final names: TypeNameBinding = index.refs.names;
		final first: Array<ResolvedType> = declsOf(names.tierOf('X', fi));
		Assert.equals(1, first.length);
		Assert.isTrue(declsOf(names.tierOf('X', fi)) == first, 'the second ask reads the memo');
		Assert.isTrue(declsOf(names.tierOf('X', fi, 3)) != first, 'an offset is part of the question');
		final other: SymbolIndex = indexOf(files);
		Assert.isTrue(declsOf(other.refs.names.tierOf('X', fileOf(other, 'Main.hx'))) != first, 'a second index is a second run');
	}

	/** A question about a file with one of its statements deleted is never answered from, nor stored in, the memo. */
	@:pin('control')
	@:killer('M-BINDING-TIER-WITHOUT-MEMO')
	public function testAnAskWithoutAStatementBypassesTheMemo(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'a/X.hx', source: 'package a;\n\nclass X {}\n' },
			{ file: 'Main.hx', source: 'import a.X;\n\nclass Main {}\n' }
		]);
		final fi: FileInfo = fileOf(index, 'Main.hx');
		final names: TypeNameBinding = index.refs.names;
		Assert.equals(1, declsOf(names.tierOf('X', fi)).length);
		Assert.isTrue(names.tierOf('X', fi, null, fi.imports[0]).match(Free), 'without its only import the name binds nothing');
		Assert.equals(1, declsOf(names.tierOf('X', fi)).length, 'the plain answer stands');
	}

	/** The same path arriving as another `FileInfo` is never answered from the first one's memo. */
	@:pin('control')
	@:killer('M-BINDING-TIER-FILE-GUARD')
	public function testAnotherFileInfoOfOnePathReadsNoStaleAnswer(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'a/X.hx', source: 'package a;\n\nclass X {}\n' },
			{ file: 'Main.hx', source: 'import a.X;\n\nclass Main {}\n' }
		]);
		final bare: SymbolIndex = indexOf([{ file: 'Main.hx', source: 'class Main {}\n' }]);
		final names: TypeNameBinding = index.refs.names;
		Assert.equals(1, declsOf(names.tierOf('X', fileOf(index, 'Main.hx'))).length);
		Assert.isTrue(names.tierOf('X', fileOf(bare, 'Main.hx')).match(Free), 'the other file text imports nothing');
	}

	/** Two files of one package asking one name share the package tier's answer. */
	@:pin('control')
	@:killer('M-BINDING-PACKAGE-NOMEMO')
	public function testAPackageTierIsAnsweredOncePerPackageAndName(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'p/X.hx', source: 'package p;\n\nclass X {}\n' },
			{ file: 'p/One.hx', source: 'package p;\n\nclass One {}\n' },
			{ file: 'p/Two.hx', source: 'package p;\n\nclass Two {}\n' }
		]);
		final one: Array<ResolvedType> = declsOf(index.refs.names.tierOf('X', fileOf(index, 'p/One.hx')));
		Assert.equals(1, one.length);
		Assert.isTrue(declsOf(index.refs.names.tierOf('X', fileOf(index, 'p/Two.hx'))) == one, 'the package answer is read once');
	}

	/** The file table answers the FIRST entry of a path, as the scan it replaces did, and nothing for an unknown path. */
	@:pin('control')
	@:killer('M-FILENAMED-FIRST')
	public function testTheFileTableAnswersTheFirstEntryOfAPath(): Void {
		final index: SymbolIndex = indexOf([{ file: 'Main.hx', source: 'class Main {}\n' }]);
		final again: SymbolIndex = indexOf([{ file: 'Main.hx', source: 'class Main {}\n' }]);
		final first: FileInfo = fileOf(index, 'Main.hx');
		final second: FileInfo = fileOf(again, 'Main.hx');
		final refs: TypeRefIndex = new TypeRefIndex([first, second], [], [], new HaxeQueryPlugin());
		Assert.isTrue(refs.fileNamed('Main.hx') == first);
		Assert.isNull(refs.fileNamed('Other.hx'));
		Assert.isTrue(index.fileInfo('Main.hx') == first);
	}

	private static function indexOf(files: Array<{ file: String, source: String }>): SymbolIndex {
		return CheckFixture.index(files, new HaxeQueryPlugin());
	}

	private static function fileOf(index: SymbolIndex, file: String): FileInfo {
		final fi: Null<FileInfo> = index.fileInfo(file);
		if (fi == null) throw new Exception('the fixture must index $file');
		return fi;
	}

	private static function declsOf(tier: Tier): Array<ResolvedType> {
		return switch tier {
			case Bound(decls): decls;
			case Unknown, Free: [];
		};
	}

}
