package unit.dev;

import dev.Squash;
import utest.Assert;
import utest.Test;

/**
 * `dev.Squash`: a whitespace run holding one newline becomes one space, and nothing the engine reads as a string, a regex, a
 * comment, a directive line, a blank line or an `@formatter:off` region is touched.
 */
@:nullSafety(Strict)
final class SquashTest extends Test {

	public function testASingleBreakBecomesOneSpace(): Void {
		Assert.equals('class A { function f() { return 1; } }\n', Squash.haxe('class A {\n\tfunction f() {\n\t\treturn 1;\n\t}\n}\n'));
	}

	@:pin('control')
	@:killer('M-SQUASH-STRING-BLIND')
	public function testAStringKeepsItsBreaks(): Void {
		Assert.equals("var s = 'a\nb'; var t = 1;", Squash.haxe("var s = 'a\nb';\nvar t = 1;"));
	}

	@:pin('control')
	@:killer('M-SQUASH-COMMENT-NEIGHBOUR')
	public function testABreakBesideACommentStays(): Void {
		Assert.equals('var a = 1; // c\nvar b = 2;\n/* x */\nvar c = 3;', Squash.haxe('var a = 1; // c\nvar b = 2;\n/* x */\nvar c = 3;'));
		Assert.equals('var a = 1; var d = 4; // c\nvar b = 2;', Squash.haxe('var a = 1;\nvar d = 4; // c\nvar b = 2;'));
	}

	@:pin('control')
	@:killer('M-SQUASH-DIRECTIVE-LINE')
	public function testABreakBesideADirectiveLineStays(): Void {
		Assert.equals(
			'class A {\n#if sys\nvar a: Int;\n#end\nvar b: Int; var c: Int; }\n',
			Squash.haxe('class A {\n#if sys\nvar a: Int;\n#end\nvar b: Int;\nvar c: Int;\n}\n')
		);
	}

	@:pin('guard')
	public function testAHashInAStringOrARegexIsNoDirective(): Void {
		Assert.equals("var color = '#fff'; var x = 1;", Squash.haxe("var color = '#fff';\nvar x = 1;"));
		Assert.equals('var r = ~/a#b/; var x = 1;', Squash.haxe('var r = ~/a#b/;\nvar x = 1;'));
	}

	@:pin('control')
	@:killer('M-SQUASH-BLANK-LINE')
	public function testABlankLineStays(): Void {
		Assert.equals('var a = 1;\n\nvar b = 2; var c = 3;', Squash.haxe('var a = 1;\n\nvar b = 2;\nvar c = 3;'));
	}

	@:pin('control')
	@:killer('M-SQUASH-FORMATTER-OFF')
	public function testAFormatterOffRegionIsKeptByteForByte(): Void {
		final kept: String = '// @formatter:off\nvar m = [\n\t1, 2,\n\t3, 4\n];\n// @formatter:on\nvar a = 1; var b = 2;\n';
		Assert.equals(kept, Squash.haxe('// @formatter:off\nvar m = [\n\t1, 2,\n\t3, 4\n];\n// @formatter:on\nvar a = 1;\nvar b = 2;\n'));
	}

	@:pin('control')
	@:killer('M-SQUASH-FORMATTER-OFF-EDGE')
	public function testABreakTouchingTheRegionStays(): Void {
		final source: String = 'var z = 0;\nvar y = 1; // @formatter:off\nvar q = [\n1 ];\n// @formatter:on\n';
		Assert.equals(source, Squash.haxe(source));
	}

	@:pin('control')
	@:killer('M-SQUASH-FILE-EDGE')
	public function testTheBreaksAtTheFileEdgesStay(): Void {
		Assert.equals('\nvar a = 1;\n', Squash.haxe('\nvar a = 1;\n'));
	}

	@:pin('control')
	@:killer('M-SQUASH-ERROR-DIRECTIVE')
	public function testABreakBesideAnErrorDirectiveStays(): Void {
		Assert.equals(
			'class A {\n#error "x"\nvar a: Int; var b: Int; }\n', Squash.haxe('class A {\n#error "x"\nvar a: Int;\nvar b: Int;\n}\n')
		);
	}

	public function testASourceThatDoesNotParseIsSquashedWithoutErrorDirectives(): Void {
		Assert.equals('class A { var a: Int; var = ;\n', Squash.haxe('class A {\nvar a: Int;\nvar = ;\n'));
	}

}
