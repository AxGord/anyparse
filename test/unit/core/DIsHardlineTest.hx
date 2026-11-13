package unit.core;

import anyparse.core.D;
import anyparse.core.Doc;

/**
 * `D.isHardline` — the flat text of `D.hardline()` answers true and the flat text of `D.line()` / `D.softline()` false, so a
 * reader of `Line(flat)` never tests the hardline encoding itself.
 */
@:nullSafety(Strict)
final class DIsHardlineTest extends Test {

	public function new(): Void {
		super();
	}

	public function testHardlineFlatTextIsHardline(): Void {
		Assert.isTrue(D.isHardline(flatOf(D.hardline())));
	}

	public function testSoftBreaksAreNot(): Void {
		Assert.isFalse(D.isHardline(flatOf(D.line())));
		Assert.isFalse(D.isHardline(flatOf(D.softline())));
	}

	private static function flatOf(d: Doc): String {
		return switch d {
			case Line(flat): flat;
			case _: throw 'not a Line';
		};
	}

}
