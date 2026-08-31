package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * `move` is a VERBATIM span splice — `MoveSymbol` cuts the declaration out and pastes it in,
 * and the writer never runs — so a file that was writer-canonical before the move could come
 * back with whitespace the writer would never emit. The op's own gate only re-parses, and a
 * stray blank line parses fine, so nothing reported it.
 *
 * Measured at base over the first 60 modules of a real Pony tree: 15 moves succeeded and 1 of
 * them left a file `fmt --list` then flagged — `src/pony/db/TableMacro.hx`, whose class was the
 * last thing inside a `#if macro … #end` region, cut to `}` + blank + `#end`. Cutting the FIRST
 * declaration out of a region is the mirror (`#if macro` + blank). Re-running the same census
 * against the fix moved that one arm to clean and left the other 14 byte-identical.
 *
 * The gate is canonical-in / canonical-out, decided PER FILE against that file's own discovered
 * config: a file already non-canonical on disk is left exactly as the splice produced it, so a
 * move inside a repo whose layout another formatter owns rewrites nothing it was not asked to.
 * That is also what makes the fix a provable no-op wherever the spliced result is already
 * canonical — every case the census measured green.
 *
 * The assertions are FIXED-POINT rather than hardcoded bytes: format the file the move wrote and
 * require the content not to move. Each is paired with a claim about the move itself, so a test
 * that quietly stopped moving anything cannot pass on the canonicality half alone.
 */
@:nullSafety(Strict)
final class MoveCanonicalOutputSliceTest extends Test {

	#if (sys || nodejs)
	/** The destination every fixture moves into — canonical as written. */
	private static final DEST: String = 'class Dest {\n\n\tpublic function new() {}\n\n}\n';
	#end

	/** The Pony shape: the cut declaration is the LAST element of a `#if … #end` region. */
	public function testMoveOutOfTheEndOfARegionLeavesTheSourceCanonical(): Void {
		#if (sys || nodejs)
		final region: String =
			'#if macro\nclass Keep {\n\n\tpublic function new() {}\n\n}\n\nclass Gone {\n\n\tpublic function new() {}\n\n}\n#end\n';
		assertMoveKeepsCanonical(region);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The mirror: the cut declaration is the FIRST element, so the orphaned blank lands under `#if`. */
	public function testMoveOutOfTheStartOfARegionLeavesTheSourceCanonical(): Void {
		#if (sys || nodejs)
		final region: String =
			'#if macro\nclass Gone {\n\n\tpublic function new() {}\n\n}\n\nclass Keep {\n\n\tpublic function new() {}\n\n}\n#end\n';
		assertMoveKeepsCanonical(region);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * CONTROL: a source file that was ALREADY non-canonical is left exactly as the splice
	 * produced it. Dropping the was-canonical half of the gate — canonicalising every written
	 * file unconditionally, the obvious simpler spelling — flips this and nothing else, and it
	 * is what keeps a move inside a foreign repo from reformatting code it did not touch.
	 */
	public function testMoveLeavesANonCanonicalSourceUnformatted(): Void {
		#if (sys || nodejs)
		final drifted: String =
			'#if macro\nclass Keep {\n    public function new() {}\n}\n\nclass Gone {\n    public function new() {}\n}\n#end\n';
		final dir: String = CliFixture.writeDir('movecanonctl', [{ name: 'Src.hx', source: drifted }, { name: 'Dest.hx', source: DEST }]);
		Assert.equals(0, Cli.run([
			'move',
			'$dir/Src.hx',
			'--select',
			'ClassDecl:Gone',
			'$dir/Dest.hx',
			'--scope',
			dir,
			'--write'
		]));
		final after: String = File.getContent('$dir/Src.hx');
		Assert.isTrue(
			after.indexOf('    public function new() {}') >= 0, 'the four-space body was reformatted by a move that was not asked to'
		);
		Assert.isTrue(after.indexOf('class Gone') < 0, 'the move did not actually cut the declaration');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * Move `Gone` out of `source` and require BOTH halves: the declaration really left the file,
	 * and formatting what the move wrote changes nothing. The fixture is formatted first, so
	 * "was canonical before" is true by construction rather than by the author's eye.
	 */
	private function assertMoveKeepsCanonical(source: String): Void {
		final dir: String = CliFixture.writeDir('movecanon', [{ name: 'Src.hx', source: source }, { name: 'Dest.hx', source: DEST }]);
		Assert.equals(0, Cli.run(['fmt', dir, '--write']));
		Assert.equals(0, Cli.run([
			'move',
			'$dir/Src.hx',
			'--select',
			'ClassDecl:Gone',
			'$dir/Dest.hx',
			'--scope',
			dir,
			'--write'
		]));
		final moved: String = File.getContent('$dir/Src.hx');
		final pasted: String = File.getContent('$dir/Dest.hx');
		Assert.isTrue(moved.indexOf('class Gone') < 0, 'the move did not actually cut the declaration');
		Assert.isTrue(pasted.indexOf('class Gone') >= 0, 'the move did not actually paste the declaration');
		Assert.equals(0, Cli.run(['fmt', '$dir/Src.hx', '--write']));
		Assert.equals(moved, File.getContent('$dir/Src.hx'), 'the move left the source file non-canonical');
		Assert.equals(0, Cli.run(['fmt', '$dir/Dest.hx', '--write']));
		Assert.equals(pasted, File.getContent('$dir/Dest.hx'), 'the move left the destination file non-canonical');
		CliFixture.removeDir(dir);
	}
	#end

}
