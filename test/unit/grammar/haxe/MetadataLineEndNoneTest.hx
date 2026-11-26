package unit.grammar.haxe;

import anyparse.format.MetadataLineEndPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * The `none` value of the four `lineEnds.metadata*` keys adds no break after a metadata: a break the
 * source has between two entries of a run stays, and the declaration line follows the source.
 */
class MetadataLineEndNoneTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	/** A type's run written one entry per line keeps its lines, the last entry glued to the declaration as written. */
	@:pin('control')
	@:killer('M-META-NONE-DROPS-SOURCE-BREAK')
	public function testATypeRunKeepsItsBreaks(): Void {
		final src: String = '@SuppressWarnings("x")\n@:forward(a, b)\n@:nullSafety(Strict) abstract X(Int) {}\n';
		Assert.equals(src, none(src));
	}

	/** A member's run keeps the breaks between its entries and before the declaration. */
	@:pin('control')
	@:killer('M-META-NONE-DROPS-SOURCE-BREAK')
	public function testAMemberRunKeepsItsBreaks(): Void {
		final src: String = 'class X {\n\t@:a\n\t@:b\n\tpublic function f():Void {}\n\n\t@:c\n\t@:d public var v:Int;\n}\n';
		Assert.equals(src, none(src));
	}

	/** An enum constructor's run keeps its breaks. */
	@:pin('control')
	@:killer('M-META-NONE-DROPS-SOURCE-BREAK')
	public function testAnOtherRunKeepsItsBreaks(): Void {
		final src: String = 'enum E {\n\t@:a\n\t@:b\n\tA;\n}\n';
		Assert.equals(src, none(src));
	}

	/** A local var's run keeps its breaks. */
	@:pin('control')
	@:killer('M-META-NONE-CHAIN-JOINS')
	public function testALocalRunKeepsItsBreaks(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b var z = 1;\n\t\t@:a @:b\n\t\tfinal q = 1;\n\t}\n}\n';
		Assert.equals(src, none(src));
	}

	/** A run written on one line stays on it: `none` adds no break. */
	public function testAOneLineRunStaysOnItsLine(): Void {
		final src: String = '@:a @:b class X {\n\t@:c @:d public function f():Void {}\n}\n';
		Assert.equals(src, none(src));
	}

	/** A blank line between two entries is not kept: the break stays, the blank goes, as under `after`. */
	public function testABlankBetweenEntriesIsDropped(): Void {
		Assert.equals('@:a\n@:b\nclass X {}\n', none('@:a\n\n@:b\nclass X {}\n'));
	}

	/** A run inside a declaration never breaks, whatever the source: the break would split the declaration. */
	@:pin('control')
	@:killer('M-META-NONE-BREAKS-INLINE')
	public function testARunInsideADeclarationJoins(): Void {
		Assert.equals('class C<@:a @:b T> {\n\tvar @:a @:b x:Int;\n}\n', none('class C<@:a\n@:b T> {\n\tvar @:a\n\t@:b x:Int;\n}\n'));
	}

	/** The trivia writer with every metadata knob at `None`. */
	private static function none(src: String): String {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.None;
		opt.metadataTypeLineEnd = MetadataLineEndPolicy.None;
		opt.metadataVarLineEnd = MetadataLineEndPolicy.None;
		opt.metadataOtherLineEnd = MetadataLineEndPolicy.None;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opt);
	}

}
