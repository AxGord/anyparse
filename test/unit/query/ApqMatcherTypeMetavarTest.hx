package unit.query;

import anyparse.query.Matcher;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;

using StringTools;

/**
 * A type metavariable in a pattern's type slot stands for any type the grammar parses there:
 * a function type, an anonymous structure and a parameterized type bind like a plain name.
 */
class ApqMatcherTypeMetavarTest extends Test {

	private static final SOURCE: String = 'class A {
		function f() {
			final cb:Void->Void = () -> {};
			final n:Int = 1;
			final s:{x:Int} = null;
			final a:Array<Int> = [];
		}
	}';

	@:pin('control')
	@:killer('M-MATCH-TYPE-METAVAR-KIND-BOUND')
	public function testTypeMetavariableBindsEveryTypeForm(): Void {
		final matches: Array<Match> = search('final $$l:$$t = $$f;');
		Assert.equals(4, matches.length);
		Assert.same(['Void->Void', 'Int', '{x:Int}', 'Array<Int>'], matches.map(m -> text(m.bindings.get('t'))));
	}

	private static function text(node: Null<QueryNode>): String {
		final span: Null<anyparse.runtime.Span> = node?.span;
		return node?.kind == 'NameOnly' || span == null ? node?.name ?? '' : SOURCE.substring(span.from, span.to).trim();
	}

	private static function search(patternSource: String): Array<Match> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern(patternSource);
		final tree: QueryNode = plugin.parseFile(SOURCE);
		return Matcher.search(pattern, tree);
	}

}
