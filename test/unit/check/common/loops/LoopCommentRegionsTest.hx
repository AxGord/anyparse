package unit.check.common.loops;

import anyparse.check.common.loops.LoopGuard;

/**
 * The loops/ fix gates read a comment from the file's lexical regions: a `//` inside a string
 * literal is not a comment and refuses no rewrite.
 */
class LoopCommentRegionsTest extends Test {

	public function testLoopGuardStringSlashesFixed(): Void {
		final src: String = 'class C {\n\tfunction f(ss:Array<String>):Void {\n\t\tfor (s in ss) {\n\t\t\tif (s == "a//b") continue;\n'
			+ '\t\t\ttrace(s);\n\t\t}\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f(ss:Array<String>):Void {\n\t\tfor (s in ss) if (s != "a//b") {\n\t\t\ttrace(s);\n\t\t}\n\t}\n}',
			CheckFixture.fixedSource(new LoopGuard(), src)
		);
	}

}
