package unit.check.common.control;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import unit.cli.CliFixture;

/**
 * `prefer-ternary-return --fix` on a pair with a boolean-literal branch writes the form no other rule
 * rewrites: one `--fix` of that rule alone is the fixed point, so `simplify-boolean-ternary` and
 * `mixed-logical-parens` find nothing to do on its output.
 */
class PreferTernaryReturnOnePassTest extends Test {

	@:pin('control')
	@:killer('M-PTR-REDUCE-OFF')
	public function testLiteralBranchPairsReachFixedPointInOnePass(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f(c:Bool, x:Bool):Bool {\n\t\tif (c) return true;\n'
			+ '\t\treturn x;\n\t}\n\n\tpublic function g(c:Bool, x:Bool):Bool {\n\t\tif (c) return false;\n\t\treturn x;\n'
			+ '\t}\n\n\tpublic function h(c:Bool, x:Bool):Bool {\n\t\tif (c) return x;\n\t\treturn true;\n\t}\n\n'
			+ '\tpublic function i(c:Bool, x:Bool):Bool {\n\t\tif (c) return x;\n\t\treturn false;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('?') == -1, 'no ternary is left to simplify: $once');
		Assert.isTrue(once.indexOf('return c || x;') != -1, 'true/x reads as `c || x`: $once');
		Assert.isTrue(once.indexOf('return !c && x;') != -1, 'false/x reads as `!c && x`: $once');
		Assert.isTrue(once.indexOf('return !c || x;') != -1, 'x/true reads as `!c || x`: $once');
		Assert.isTrue(once.indexOf('return c && x;') != -1, 'x/false reads as `c && x`: $once');
		for (rule in ['prefer-ternary-return', 'simplify-boolean-ternary']) {
			Assert.equals(0, Cli.run(['lint', '--rule', rule, '--fix', path]), '$rule --fix exits ok');
			Assert.equals(once, File.getContent(path), '$rule has nothing left to write');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-PTR-PARENS-OFF')
	public function testMixedLogicalOperandsComeParenthesised(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f(a:Bool, b:Bool, x:Bool):Bool {\n\t\tif (a && b) return true;\n'
			+ '\t\treturn x;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [
			{ name: 'Foo.hx', source: src },
			{ name: 'apq.json', source: '{ "rules": { "mixed-logical-parens": true } }\n' }
		]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('return (a && b) || x;') != -1, 'the mixed operand is parenthesised in the same edit: $once');
		Assert.equals(0, Cli.run(['lint', '--rule', 'mixed-logical-parens', '--fix', path]), 'mixed-logical-parens --fix exits ok');
		Assert.equals(once, File.getContent(path), 'mixed-logical-parens has nothing left to write');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-PTR-PARENS-FORCED')
	public function testMixedLogicalOperandsStayBareWhenTheRuleIsOff(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f(a:Bool, b:Bool, x:Bool):Bool {\n\t\tif (a && b) return true;\n'
			+ '\t\treturn x;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('return a && b || x;') != -1, 'no parentheses are written unasked: $once');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-PTR-COMMENT-DROPPED')
	public function testCommentInTheRegionKeepsTheTernaryForm(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f(c:Bool, x:Bool):Bool {\n'
			+ '\t\tif (c) return true; // already linked\n\t\treturn x;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('// already linked') != -1, 'the comment is re-placed, not dropped: $once');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-PTR-SBT-GATE-OFF')
	public function testDisabledSimplifyRuleKeepsTheTernary(): Void {
		#if (sys || nodejs)
		final src: String =
			'package p;\n\nclass C {\n\tpublic function f(c:Bool, x:Bool):Bool {\n\t\tif (c) return true;\n\t\treturn x;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [
			{ name: 'Foo.hx', source: src },
			{ name: 'apq.json', source: '{ "rules": { "simplify-boolean-ternary": false } }\n' }
		]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('return c ? true : x;') != -1, 'a rule the project turned off is not applied for it: $once');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-PTR-QUOTED-REDUCED')
	public function testPairInsideAQuotationKeepsTheTernary(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nimport haxe.macro.Expr;\n\nclass C {\n\tpublic static function f(cond:Expr, other:Expr):Expr {\n'
			+ '\t\treturn macro function():Bool {\n\t\t\tif ($$cond) return true;\n\t\t\treturn $$other;\n\t\t};\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('return $$cond ? true : $$other;') != -1, 'simplify-boolean-ternary stays out of a quotation: $once');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-PTR-TYPES-BLIND')
	public function testOrderedComparisonFlipFollowsTheOperandType(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f(x:Int, p:Bool):Bool {\n\t\tif (x < 0) return false;\n\t\treturn '
			+ 'p;\n\t}\n\n\tpublic function g(x:Float, p:Bool):Bool {\n\t\tif (x < 0) return false;\n\t\treturn p;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('onepass', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-ternary-return', '--fix', path]), 'lint --fix exits ok');
		final once: String = File.getContent(path);
		Assert.isTrue(once.indexOf('return x >= 0 && p;') != -1, 'an Int comparison flips: $once');
		Assert.isTrue(once.indexOf('return !(x < 0) && p;') != -1, 'a Float comparison keeps the negation (NaN): $once');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
