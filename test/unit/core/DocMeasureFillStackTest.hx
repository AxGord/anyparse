package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import utest.Assert;
import utest.Test;

/**
 * `DocMeasure.pushFillReversed` — a fill's items land on the flat-walk stack last first with the
 * separator between neighbours, so popping yields item, separator, item in source order; an empty
 * or single-item fill pushes no separator. Green at base by construction: the six flat walks
 * spelled this loop themselves.
 */
@:nullSafety(Strict)
final class DocMeasureFillStackTest extends Test {

	public function new(): Void {
		super();
	}

	public function testItemsPopInSourceOrderWithSeparatorsBetween(): Void {
		final stack: Array<Doc> = [Text('below')];
		DocMeasure.pushFillReversed(stack, [Text('a'), Text('b'), Text('c')], Text(','));
		Assert.same(['below', 'c', ',', 'b', ',', 'a'], stack.map(label));
		Assert.same(['a', ',', 'b', ',', 'c', 'below'], [for (i in 0...stack.length) label(stack[stack.length - 1 - i])]);
	}

	public function testASingleItemOrNonePushesNoSeparator(): Void {
		final one: Array<Doc> = [];
		DocMeasure.pushFillReversed(one, [Text('a')], Text(','));
		Assert.same(['a'], one.map(label));
		final none: Array<Doc> = [];
		DocMeasure.pushFillReversed(none, [], Text(','));
		Assert.equals(0, none.length);
	}

	private static function label(d: Doc): String {
		return switch d {
			case Text(s): s;
			case _: '?';
		};
	}

}
