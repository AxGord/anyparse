package unit.cli;

import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture.CliRun;

using Lambda;
using StringTools;

/**
 * `apq extract-typedef <file>:<line>[:<col>] <pkg.Name>`: the structure written at the address becomes the typedef module,
 * and the occurrences of the same type in the scope are rewritten to it. The preview names what would change and writes
 * nothing; `--write` applies; the scope is the addressed file unless `--scope` widens it; a path that already holds a file is
 * refused with nothing written.
 */
class ExtractTypedefCliTest extends Test {

	private static final STRUCTURE: String = 'public function one(): { id: Int, item: Item } return null;';

	public function testThePreviewNamesTheFilesAndWritesNothing(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final before: String = File.getContent('$dir/src/app/A.hx');
			final run: CliRun = CliFixture.runIn(dir, ['extract-typedef', address(dir, 'A'), 'model.Rec', '--scope', 'src']);
			Assert.equals(0, run.code);
			Assert.isTrue(
				run.out.contains('src/model/Rec.hx: created')
				&& run.out.contains('src/app/A.hx: updated')
				&& run.out.contains('src/app/B.hx: updated'),
				run.out
			);
			Assert.equals(before, File.getContent('$dir/src/app/A.hx'));
			Assert.isFalse(FileSystem.exists('$dir/src/model/Rec.hx'));
		});
	}

	public function testWriteCreatesTheModuleAndRewritesTheScopeWithImports(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final run: CliRun = CliFixture.runIn(dir, ['extract-typedef', address(dir, 'A'), 'model.Rec', '--scope', 'src', '--write']);
			Assert.equals(0, run.code);
			final created: String = File.getContent('$dir/src/model/Rec.hx');
			Assert.isTrue(
				created.contains('package model;') && created.contains('import lib.Item;') && created.contains('typedef Rec'), created
			);
			for (name in ['A', 'B']) {
				final text: String = File.getContent('$dir/src/app/$name.hx');
				Assert.isTrue(text.contains('import model.Rec;') && text.contains(':Rec') && !text.contains('id:Int'), text);
			}
		});
	}

	@:pin('control')
	@:killer('M-XTD-DEFAULT-SCOPE')
	public function testWithoutScopeOnlyTheAddressedFileIsRewritten(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final other: String = File.getContent('$dir/src/app/B.hx');
			Assert.equals(0, CliFixture.runIn(dir, ['extract-typedef', address(dir, 'A'), 'model.Rec', '--write']).code);
			Assert.isTrue(File.getContent('$dir/src/app/A.hx').contains('import model.Rec;'));
			Assert.equals(other, File.getContent('$dir/src/app/B.hx'));
		});
	}

	@:pin('control')
	@:killer('M-XTD-CLI-OCCUPIED')
	public function testAPathHoldingAFileOutsideTheScopeIsRefusedWithNothingWritten(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			FileSystem.createDirectory('$dir/src/model');
			File.saveContent('$dir/src/model/Rec.hx', 'package model;\n\nclass Rec {}\n');
			final before: String = File.getContent('$dir/src/app/A.hx');
			var code: Int = -1;
			final said: String = CliFixture.captureStderr(() -> code = CliFixture.runIn(dir, [
				'extract-typedef',
				address(dir, 'A'),
				'model.Rec',
				'--scope',
				'src/app',
				'--write'
			])
				.code);
			Assert.equals(1, code);
			Assert.isTrue(said.contains('already exists') && said.contains('is taken'), said);
			Assert.equals(before, File.getContent('$dir/src/app/A.hx'));
			Assert.equals('package model;\n\nclass Rec {}\n', File.getContent('$dir/src/model/Rec.hx'));
		});
	}

	public function testADeclinedExtractionExitsNonZeroAndWritesNothing(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			var code: Int = -1;
			final said: String = CliFixture.captureStderr(() -> {
				code = CliFixture.runIn(dir, ['extract-typedef', address(dir, 'A'), 'lib.Item', '--scope', 'src', '--write']).code;
			});
			Assert.equals(1, code);
			Assert.isTrue(said.contains('apq extract-typedef: the type lib.Item already exists'), said);
			Assert.isFalse(said.contains('wrote'));
			Assert.isTrue(File.getContent('$dir/src/app/A.hx').contains('item:Item'), 'the addressed file is untouched');
		});
	}

	public function testAnAddressWithoutAPositionIsAUsageError(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			Assert.equals(2, CliFixture.runIn(dir, ['extract-typedef', 'src/app/A.hx', 'model.Rec']).code);
			Assert.equals(2, CliFixture.runIn(dir, ['extract-typedef', 'src/app/A.hx:0', 'model.Rec']).code);
			Assert.equals(2, CliFixture.runIn(dir, ['extract-typedef', 'src/app/A.hx:3:0', 'model.Rec']).code);
		});
	}

	public function testFixIsAcceptedBehindAWrite(): Void {
		final dir: String = tree();
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final run: CliRun = CliFixture.runIn(dir, ['extract-typedef', address(dir, 'A'), 'model.Rec', '--write', '--fix']);
			Assert.equals(0, run.code);
			Assert.isTrue(File.getContent('$dir/src/app/A.hx').contains('import model.Rec;'));
		});
	}

	/** The address of the structure in `name`'s file, as the line the writer put it on. */
	private static function address(dir: String, name: String): String {
		final lines: Array<String> = File.getContent('$dir/src/app/$name.hx').split('\n');
		final found: Int = [ for (i => l in lines) if (~/\bid\s*:\s*Int/.match(l)) i ][0];
		return 'src/app/$name.hx:${found + 1}';
	}

	/** A project of two files writing one structure, in the writer's own layout. */
	private static function tree(): String {
		final dir: String = CliFixture.writeTree('extract-typedef', [
			{ name: 'src/lib/Item.hx', source: 'package lib;\n\nclass Item {}\n' },
			{ name: 'src/app/A.hx', source: 'package app;\n\nimport lib.Item;\n\nclass A {\n\t$STRUCTURE\n}\n' },
			{
				name: 'src/app/B.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass B {\n\tpublic function two(p: { item: Item, id: Int }): Void {}\n}\n'
			}
		]);
		Assert.equals(0, CliFixture.runIn(dir, ['fmt', '--write', 'src']).code);
		return dir;
	}

}
