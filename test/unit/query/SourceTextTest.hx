package unit.query;

import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `SourceText.nodeText` and `SourceText.trimNewlineEdges` — the text under a node's span or null for a
 * spanless node, and a cut block stripped of its leading and trailing line breaks only. Green at base by
 * construction: both restate what their adopters spelled inline.
 */
@:nullSafety(Strict)
class SourceTextTest extends Test {

	public function testNodeTextReadsTheSpan(): Void {
		final source: String = 'final x: Int = 42;';
		Assert.equals('42', SourceText.nodeText(new QueryNode('IntLit', null, [], new Span(15, 17)), source));
		Assert.isNull(SourceText.nodeText(new QueryNode('IntLit', null, []), source));
	}

	public function testTrimNewlineEdgesKeepsInteriorBreaksAndIndentation(): Void {
		Assert.equals('\tfunction f() {}\n\n\tvar x: Int;', SourceText.trimNewlineEdges('\n\r\n\tfunction f() {}\n\n\tvar x: Int;\n\n'));
		Assert.equals('a', SourceText.trimNewlineEdges('a'));
		Assert.equals('', SourceText.trimNewlineEdges('\n\n'));
		Assert.equals(' a ', SourceText.trimNewlineEdges('\n a \n'));
	}

}
