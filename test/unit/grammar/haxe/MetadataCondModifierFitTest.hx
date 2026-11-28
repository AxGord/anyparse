package unit.grammar.haxe;

import anyparse.format.MetadataLineEndPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import utest.Assert;
import utest.Test;

/**
 * Under the `fit` value of `lineEnds.metadata*` a lone simple metadata shares its line with a conditional modifier
 * region after it only when the region is simple: one test, no `#elseif`, one keyword per branch, a simple metadata
 * allowed in `#else`, no comment. Any other region sends the metadata to a line of its own.
 */
class MetadataCondModifierFitTest extends Test {

	private static final MAX_LINE: Int = 140;

	/** A simple region rides the line of the lone metadata before it, wherever the source put it. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-ALWAYS-COMPLEX')
	public function testASimpleRegionRidesTheLoneMetadataLine(): Void {
		Assert.equals(
			'class C {\n\t@:op(A && B) #if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic inline function f():Void {}\n\n'
			+ '\t@:from #if !sys inline #end\n\tpublic static function g():Void {}\n\n'
			+ '\t@:a #if sys extern #else inline #end\n\tfunction h():Void {}\n}\n',
			fit(
				'class C {\n\t@:op(A && B)\n\t#if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic inline function f():Void {}\n\n'
				+ '\t@:from #if !sys inline #end\n\tpublic static function g():Void {}\n\n'
				+ '\t@:a\n\t#if sys extern #else inline #end\n\tfunction h():Void {}\n}\n'
			)
		);
	}

	/** A region with an `#elseif` branch takes its own line. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-ELSEIF-IGNORED', 'M-COND-MOD-GLUE-TRIVIA-UNWIRED', 'M-COND-MOD-GLUE-FIT-IGNORES-BREAK')
	public function testAnElseifRegionTakesItsOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\t#if sys extern #elseif js inline #end\n\tfunction f():Void {}\n}\n',
			fit('class C {\n\t@:a #if sys extern #elseif js inline #end\n\tfunction f():Void {}\n}\n')
		);
	}

	/** A condition joining two tests with `&&` or `||` takes its own line. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-COMPOUND-IGNORED')
	public function testACompoundConditionTakesItsOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\t#if (sys && !js) extern #end\n\tfunction f():Void {}\n\n\t@:a\n\t#if (sys || js) extern #end\n'
			+ '\tfunction g():Void {}\n}\n',
			fit(
				'class C {\n\t@:a #if (sys && !js) extern #end\n\tfunction f():Void {}\n\n\t@:a #if (sys || js) extern #end\n'
				+ '\tfunction g():Void {}\n}\n'
			)
		);
	}

	/** A negated or nested-parenthesised condition is read through: `!(a || b)` joins two tests, `((a))` is one. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-NOT-UNWALKED')
	public function testANegatedCompoundConditionTakesItsOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\t#if !(sys || js) extern #end\n\tfunction g():Void {}\n\n\t@:a #if ((sys)) extern #end\n'
			+ '\tfunction h():Void {}\n}\n',
			fit(
				'class C {\n\t@:a #if !(sys || js) extern #end\n\tfunction g():Void {}\n\n\t@:a #if ((sys)) extern #end\n'
				+ '\tfunction h():Void {}\n}\n'
			)
		);
	}

	/** Two modifiers in the `#if` branch send the region to its own line. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-BODY-COUNT-IGNORED')
	public function testTwoModifiersInTheIfBranchTakeTheirOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\t#if sys extern inline #end\n\tfunction f():Void {}\n}\n',
			fit('class C {\n\t@:a #if sys extern inline #end\n\tfunction f():Void {}\n}\n')
		);
	}

	/** Two elements, or a complex metadata, in the `#else` branch send the region to its own line. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-ELSE-COUNT-IGNORED', 'M-COND-MOD-GLUE-ELSE-META-UNCHECKED')
	public function testAComplexElseBranchTakesItsOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\t#if sys extern #else inline dynamic #end\n\tfunction f():Void {}\n\n\t@:a\n'
			+ '\t#if sys extern #else @:b({x: 1}) #end\n\tfunction g():Void {}\n}\n',
			fit(
				'class C {\n\t@:a #if sys extern #else inline dynamic #end\n\tfunction f():Void {}\n\n'
				+ '\t@:a #if sys extern #else @:b({x: 1}) #end\n\tfunction g():Void {}\n}\n'
			)
		);
	}

	/** A comment on an element of the region sends it to its own line; the comment keeps a line of its own inside it. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-COMMENT-IGNORED')
	public function testACommentInTheRegionTakesItsOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\t#if sys\n\t/* c */\n\textern #end\n\tfunction f():Void {}\n}\n',
			fit('class C {\n\t@:a #if sys /* c */ extern #end\n\tfunction f():Void {}\n}\n')
		);
	}

	/** After a run of two metadata even a simple region takes its own line: only a lone metadata is ridden. */
	@:pin('control')
	@:killer('M-META-FIT-RUN-BREAK-UNWIRED', 'M-META-FIT-PLAIN-RUN-BREAK-UNWIRED')
	public function testARunOfTwoMetadataLeavesTheRegionOnItsOwnLine(): Void {
		Assert.equals(
			'class C {\n\t@:a @:b\n\t#if sys extern #end\n\tfunction f():Void {}\n}\n',
			fit('class C {\n\t@:a\n\t@:b #if sys extern #end\n\tfunction f():Void {}\n}\n')
		);
		Assert.equals(
			'class C {\n\t@:a @:b\n\t#if sys extern #end function f():Void {}\n}\n',
			plain('class C {\n\t@:a\n\t@:b #if sys extern #end function f():Void {}\n}\n')
		);
	}

	/** A short metadata alone on its line after a long one is read as a lone one: it rides a simple region, never a complex one. */
	@:pin('control')
	@:killer('M-META-FIT-ALONE-LAST-RUN-BREAK', 'M-META-FIT-ALONE-LAST-IGNORES-COMPLEX')
	public function testAShortMetadataAloneAfterALongOneRidesASimpleRegion(): Void {
		Assert.equals(
			'class C {\n\t@:build(a())\n\t@:op(A -= B) #if sys extern #end\n\tfunction f():Void {}\n\n\t@:build(a())\n\t@:op(A -= B)\n'
			+ '\t#if (sys && !js) extern #end\n\tfunction g():Void {}\n}\n',
			fit(
				'class C {\n\t@:build(a()) @:op(A -= B) #if sys extern #end\n\tfunction f():Void {}\n\n'
				+ '\t@:build(a()) @:op(A -= B) #if (sys && !js) extern #end\n\tfunction g():Void {}\n}\n'
			)
		);
	}

	/** A simple region whose joined line passes the maximum takes its own line. */
	@:pin('guard')
	public function testAJoinedLinePastTheMaximumTakesItsOwnLine(): Void {
		final meta: String = '@:a(\'${run(MAX_LINE - 20)}\')';
		Assert.equals(
			'class C {\n\t$meta\n\t#if sys extern #end\n\tfunction f():Void {}\n}\n',
			fit('class C {\n\t$meta #if sys extern #end\n\tfunction f():Void {}\n}\n')
		);
	}

	/** Under `None` the author's layout stays, a complex region glued and a simple one on its own line alike. */
	@:pin('guard')
	public function testNoneKeepsTheAuthorsBreak(): Void {
		final opt: HxModuleWriteOptions = options();
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.None;
		final src: String = 'class C {\n\t@:a #if sys extern inline #end\n\tfunction f():Void {}\n\n\t@:a\n\t#if sys extern #end\n'
			+ '\tfunction g():Void {}\n}\n';
		Assert.equals(src, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opt));
	}

	/** The plain writer reads the same rule. */
	@:pin('control')
	@:killer('M-COND-MOD-GLUE-PLAIN-UNWIRED')
	public function testThePlainWriterReadsTheRule(): Void {
		Assert.equals(
			'class C {\n\t@:a #if sys extern #end function f():Void {}\n\t@:a\n\t#if sys extern inline #end function g():Void {}\n}\n',
			plain('class C {\n\t@:a #if sys extern #end function f():Void {}\n\n\t@:a #if sys extern inline #end function g():Void {}\n}\n')
		);
	}

	/** A second write over any fixture's output changes nothing. */
	@:pin('guard')
	public function testASecondWriteChangesNothing(): Void {
		for (src in [
			'class C {\n\t@:op(A && B)\n\t#if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic inline function f():Void {}\n}\n',
			'class C {\n\t@:a #if sys extern #elseif js inline #end\n\tfunction f():Void {}\n}\n',
			'class C {\n\t@:a #if (sys && !js) extern #end\n\tfunction f():Void {}\n}\n',
			'class C {\n\t@:a #if sys extern #else @:b({x: 1}) #end\n\tfunction g():Void {}\n}\n'
		]) {
			final once: String = fit(src);
			Assert.equals(once, fit(once));
		}
	}

	/** A run of `n` letters, the filler that puts a line at a chosen width. */
	private static function run(n: Int): String {
		return [ for (_ in 0...n) 'a' ].join('');
	}

	/** The trivia writer with every metadata knob at `Fit` and the maximum at `MAX_LINE`. */
	private static function fit(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), options());
	}

	private static function plain(src: String): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), options());
	}

	private static function options(): HxModuleWriteOptions {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		opt.lineWidth = MAX_LINE;
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataTypeLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataVarLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataOtherLineEnd = MetadataLineEndPolicy.Fit;
		return opt;
	}

}
