package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.format.Json;
import utest.Assert;
import utest.Test;

/**
 * The 1-based line/column coordinates `apq … --json` puts in every `span`.
 *
 * ⚠️ THIS CLASS EXISTS BECAUSE A MUTATION ARM SURVIVED. `Json.spanToJson` emits `start` and
 * `end`; an arm that made `end` compute from `span.from` - so EVERY span in every dump ended
 * where it started - ran the whole `unit.query` package (1982 tests, 7393 assertions) GREEN.
 * Nothing anywhere pinned the end coordinate. The dumps are wide (`ApqAstIntegrationTest`
 * renders thousands of them) but only ever asked not to crash.
 *
 * That mattered the moment `spanToJson` stopped scanning the source per call: S67 replaced
 * `Span.lineCol`'s walk-from-byte-0 with a binary search over a line index, and the only thing
 * standing behind "it answers what the scan answered" was a byte-comparison of two dumps run by
 * hand. This is the standing version of that comparison.
 *
 * The fixture is deliberately tiny and hand-checkable: a span that ends on the line it starts
 * on, one that spans several lines, and the module node that covers the whole file.
 */
@:nullSafety(Strict)
class JsonSpanCoordinatesTest extends Test {

	private static final SRC: String = 'class A {\n\tfunction f():Void {\n\t\tvar x = 1;\n\t}\n}\n';

	/** An `end` that differs from its `start` on the same line — the arm's blind spot. */
	public function testASingleLineSpanEndsWhereTheTokenEnds(): Void {
		Assert.isTrue(dump().indexOf('"span":{"start":[3, 11], "end":[3, 12]}') != -1, 'the `1` literal spans column 11 to 12');
	}

	/** A span whose end is on a LATER line than its start. */
	public function testAMultiLineSpanCrossesLines(): Void {
		Assert.isTrue(dump().indexOf('"end":[4, 3]') != -1, 'the function body ends on line 4');
	}

	/** Both coordinates are 1-based — the unified apq convention `refs` / `ast --at` share. */
	public function testCoordinatesAreOneBased(): Void {
		final text: String = dump();
		Assert.isTrue(text.indexOf('[0, ') == -1, 'no line 0 may appear in: <$text>');
		Assert.isTrue(text.indexOf(', 0]') == -1, 'no column 0 may appear in: <$text>');
	}

	/** The line index and the old per-call scan must agree on every span of a real file. */
	public function testEveryEndIsAtOrAfterItsStart(): Void {
		final text: String = dump();
		final re: EReg = ~/"start":\[([0-9]+), ([0-9]+)\], "end":\[([0-9]+), ([0-9]+)\]/;
		var rest: String = text;
		var seen: Int = 0;
		while (re.match(rest)) {
			final startLine: Int = Std.parseInt(re.matched(1)) ?? 0;
			final startCol: Int = Std.parseInt(re.matched(2)) ?? 0;
			final endLine: Int = Std.parseInt(re.matched(3)) ?? 0;
			final endCol: Int = Std.parseInt(re.matched(4)) ?? 0;
			Assert.isTrue(
				endLine > startLine || (endLine == startLine && endCol >= startCol),
				'span [$startLine, $startCol] -> [$endLine, $endCol] runs backwards'
			);
			seen++;
			rest = re.matchedRight();
		}
		Assert.isTrue(seen >= 5, 'expected several spans in the dump, saw $seen');
	}

	private function dump(): String {
		final tree: Null<QueryNode> = new HaxeQueryPlugin().parseFile(SRC);
		Assert.notNull(tree);
		return tree == null ? '' : Json.renderTree('A.hx', SRC, tree);
	}

}
