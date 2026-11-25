package unit.grammar.haxe;

import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * Under this repository's `hxformat.json` (`wrapping.comprehensionFit: true`) a fitting comprehension that is the
 * receiver of a call whose sole argument is an arrow lambda stays on one line: the lambda's body takes the next line
 * after the arrow instead of the comprehension opening its brackets.
 */
@:nullSafety(Strict)
final class HxRepoConfigComprehensionReceiverLambdaTest extends Test {

	public function new(): Void {
		super();
	}

	/** The comprehension receiver stays whole and the arrow lambda's body breaks onto its own line. */
	@:pin('control')
	@:killer('M-FLAT-ASKER-ARROW-FLAT')
	public function testFittingComprehensionReceiverYieldsToTheLambdaArrow(): Void {
		final expected: String = inMethod([
			'return [ for (depth in fromDepth ... segments.length + 1) depth ].exists(depth ->',
			'\tFiles.exists(Path.join([root].concat(segments.slice(0, depth)).concat([moduleFile])))',
			');'
		]);
		final broken: String = inMethod([
			'return [',
			'\tfor (depth in fromDepth ... segments.length + 1) depth',
			'].exists(depth -> Files.exists(Path.join([root].concat(segments.slice(0, depth)).concat([moduleFile]))));'
		]);
		Assert.equals(expected, repoWrite(broken));
		Assert.equals(expected, repoWrite(expected));
	}

	private function repoWrite(src: String): String {
		return #if (sys || nodejs) HxWriteFixture.triviaWrite(src, File.getContent('hxformat.json')) #else src #end;
	}

	private static function inMethod(lines: Array<String>): String {
		return 'class C {\n\n\tfunction test() {\n\t\t${lines.join('\n\t\t')}\n\t}\n\n}';
	}

}
