package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `extract-interface` and `extract-superclass` GENERATE a whole module and hand
 * it to `writeFiles`, so a destination that already holds a file is overwritten
 * rather than merged — and the default destination is `<TypeName>.hx` beside the
 * source, so no flag is needed to hit it.
 *
 * Measured on the base commit: with a sibling `Helper.hx` present,
 * `apq extract-interface C.hx Helper` replaced that class, its doc and its
 * members with the generated interface, reported `wrote 2 file(s)` at rc 0, and
 * the preview had called the same file `created`. `--out <srcFile>` was worse
 * still: two atomic writes raced on one path, so the op died on a raw ENOENT
 * from `rename` AFTER the source had already been given its `implements` clause.
 *
 * The rule asserted here is the create-only one `apq new` already states. These
 * two ops were the only file-generating ops that did not go through it; merging
 * into an existing module is a different feature with its own spelling
 * (`extract-constant --into`, which reads the destination first).
 */
class ExtractDestinationCollisionCliTest extends Test {

	/**
	 * The class the two ops extract from — one public instance method, type and member documented.
	 */
	private static final SRC: String = 'package;\n\n/** Doc for C. */\nclass C {\n\n\tpublic function new() {}\n\n\t/** Doc for go. */\n'
		+ '\tpublic function go():Int {\n\t\treturn 1;\n\t}\n}\n';

	/**
	 * The module already sitting at the default destination path `<TypeName>.hx`.
	 */
	private static final OCCUPANT: String = 'package;\n\n/** Doc for Helper. */\nclass Helper {\n\n\tpublic function new() {}\n\n'
		+ '\t/** Doc for keep. */\n\tpublic function keep():Int {\n\t\treturn 42;\n\t}\n}\n';

	public function testExtractInterfaceRefusesAnOccupiedSibling(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		Assert.equals(1, Cli.run(['extract-interface', '$dir/C.hx', 'Helper', '--write']), 'an occupied default destination is refused');
		final occupant: String = File.getContent('$dir/Helper.hx');
		final src: String = File.getContent('$dir/C.hx');
		Assert.equals(OCCUPANT, occupant, 'the occupant is byte-identical — doc, members and all');
		Assert.isTrue(src.indexOf('implements') == -1, 'and the source keeps no half-applied clause');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExtractSuperclassRefusesAnOccupiedSibling(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		Assert.equals(
			1, Cli.run(['extract-superclass', '$dir/C.hx', 'Helper', '--members', 'go', '--write']),
			'an occupied default destination is refused'
		);
		final occupant: String = File.getContent('$dir/Helper.hx');
		final src: String = File.getContent('$dir/C.hx');
		Assert.equals(OCCUPANT, occupant, 'the occupant is byte-identical');
		Assert.isTrue(src.indexOf('extends') == -1, 'and the source keeps no half-applied clause');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDestinationEqualToTheSourceIsRefused(): Void {
		#if (sys || nodejs)
		// The shape that used to die on a raw `ENOENT … rename` from the atomic write,
		// having already modified the source. One refusal covers it because the source
		// file is, trivially, a path that already exists.
		final dir: String = fixture();
		Assert.equals(1, Cli.run(['extract-interface', '$dir/C.hx', 'IF', '--out', '$dir/C.hx', '--write']), 'out == src is refused');
		Assert.equals(SRC, File.getContent('$dir/C.hx'), 'the source is byte-identical');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testPreviewRefusesBeforeItCanClaimCreated(): Void {
		#if (sys || nodejs)
		// The preview printed `<path>: created` for a file it would have destroyed, so the
		// refusal has to precede the work, not gate the write. The occupant is asserted
		// here too: an `rc == 1` alone cannot tell THIS refusal from any other failure.
		final dir: String = fixture();
		Assert.equals(1, Cli.run(['extract-interface', '$dir/C.hx', 'Helper']), 'the preview refuses too');
		Assert.equals(OCCUPANT, File.getContent('$dir/Helper.hx'), 'and the occupant it would have called "created" is byte-identical');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAFreeDestinationStillGenerates(): Void {
		#if (sys || nodejs)
		// CONTROL — green at base BY CONSTRUCTION, and the arm that kills it is a refusal
		// that does not read the filesystem (one that answers "occupied" unconditionally).
		final dir: String = fixture();
		Assert.equals(0, Cli.run(['extract-interface', '$dir/C.hx', 'IFaceFree', '--write']), 'a free path still generates');
		Assert.isTrue(FileSystem.exists('$dir/IFaceFree.hx'), 'the interface file was created');
		Assert.isTrue(File.getContent('$dir/IFaceFree.hx').indexOf('function go():Int;') >= 0, 'and it carries the extracted signature');
		Assert.isTrue(File.getContent('$dir/C.hx').indexOf('implements IFaceFree') >= 0, 'and the class implements it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function fixture(): String {
		return CliFixture.writeDir('extractdest', [{ name: 'C.hx', source: SRC }, { name: 'Helper.hx', source: OCCUPANT }]);
	}
	#end

}
