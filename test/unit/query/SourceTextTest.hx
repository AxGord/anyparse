package unit.query;

import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.runtime.Span;

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

	@:pin('control')
	@:killer('M-LOWER-CAMEL-FIRST-ONLY')
	public function testLowerCamelLowersTheLeadingCapitalRun(): Void {
		Assert.equals('point', SourceText.lowerCamel('Point'));
		Assert.equals('sidebarTabEvent', SourceText.lowerCamel('SidebarTabEvent'));
		Assert.equals('urlLoader', SourceText.lowerCamel('URLLoader'));
		Assert.equals('io', SourceText.lowerCamel('IO'));
		Assert.equals('md5Hash', SourceText.lowerCamel('MD5Hash'));
		Assert.equals('already', SourceText.lowerCamel('already'));
	}

	public function testTrimNewlineEdgesKeepsInteriorBreaksAndIndentation(): Void {
		Assert.equals('\tfunction f() {}\n\n\tvar x: Int;', SourceText.trimNewlineEdges('\n\r\n\tfunction f() {}\n\n\tvar x: Int;\n\n'));
		Assert.equals('a', SourceText.trimNewlineEdges('a'));
		Assert.equals('', SourceText.trimNewlineEdges('\n\n'));
		Assert.equals(' a ', SourceText.trimNewlineEdges('\n a \n'));
	}

}
