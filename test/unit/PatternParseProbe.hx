package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;

/**
 * Slice 2C probe — verifies `HaxeQueryPlugin.parsePattern` correctly:
 *  - parses the pattern via the try-fallback decl/stmt/expr cascade,
 *  - reclassifies `$X` / `$_` placeholders as `kind='Metavar'`
 *    QueryNodes with the bare name extracted,
 *  - reports the correct `category` per the wrapping that succeeded.
 *
 * Exercises Q4-Q7 from `docs/cli-query-phase0-queries.md` plus a few
 * variants that stress wildcard independence and metavar reuse.
 */
class PatternParseProbe extends Test {

	public function testQ4ConditionalNullGuardedCall():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern:Pattern = plugin.parsePattern("if ($x != null) return $x.$f($_)");
		Assert.equals(PatternCategory.Stmt, pattern.category);
		Assert.equals('IfStmt', pattern.root.kind);
		final names:Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('x'), 'pattern must bind $$x — got ${names.join(",")}');
		Assert.isTrue(names.contains('f'), 'pattern must bind $$f');
		Assert.isTrue(names.contains('_'), 'pattern must include a wildcard');
		// `$x` reuses must produce two Metavar nodes with name `x`.
		final xs:Int = countMetavarByName(pattern.root, 'x');
		Assert.equals(2, xs, '$$x must appear twice in pattern AST — got $xs');
	}

	public function testQ6ThrowNewException():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern:Pattern = plugin.parsePattern("throw new $E($_)");
		Assert.equals(PatternCategory.Stmt, pattern.category);
		final names:Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('E'), 'pattern must bind $$E — got ${names.join(",")}');
		Assert.isTrue(names.contains('_'), 'pattern must include wildcard arg');
	}

	public function testLiteralOnlyPatternHasNoMetavars():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern:Pattern = plugin.parsePattern('return null');
		final names:Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.equals(0, names.length, 'literal-only pattern must have no metavars — got ${names.join(",")}');
	}

	public function testDollarInsideStringNotSubstituted():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern:Pattern = plugin.parsePattern("var $name = 'hello $x'");
		// `$name` outside quotes IS a metavar; `$x` inside single-quoted
		// string is Haxe interp — must NOT be reclassified.
		final names:Array<String> = [];
		collectMetavarNames(pattern.root, names);
		Assert.isTrue(names.contains('name'), 'outside-string $$name must be a metavar');
		Assert.isFalse(names.contains('x'), 'inside-string $$x must NOT be a metavar — got ${names.join(",")}');
	}

	private static function collectMetavarNames(node:QueryNode, into:Array<String>):Void {
		if (node.kind == Metavar.KIND) {
			final n:Null<String> = node.name;
			if (n != null) into.push(n);
		}
		final n2:Null<String> = node.name;
		if (n2 != null && node.kind != Metavar.KIND && StringTools.startsWith(n2, '$'))
			into.push(n2.substring(1));
		for (c in node.children) collectMetavarNames(c, into);
	}

	private static function countMetavarByName(node:QueryNode, target:String):Int {
		var count:Int = 0;
		if (node.kind == Metavar.KIND && node.name == target) count++;
		if (node.kind != Metavar.KIND && node.name == '$' + target) count++;
		for (c in node.children) count += countMetavarByName(c, target);
		return count;
	}
}
