package unit.grammar.haxe;

import anyparse.format.MetadataLineEndPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Under `fit` a lone simple metadata measures the line it lands on: the declaration's first line
 * after the declaration's own break, never the whole declaration header laid flat.
 */
class MetadataFitFirstLineTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	/** A class header that breaks before `extends` keeps its metadata on the first line. */
	@:pin('control')
	@:killer('M-META-FIT-LATER-LINE-BREAK-UNSEEN')
	public function testAWrappedExtendsKeepsTheMetadata(): Void {
		Assert.equals(
			'@:nullSafety final class Cls\n\textends Base<Array<ItemWithAVeryLongName>, ResponseWithAnotherVeryLongName, '
			+ '{timestamp:String, description:String, identifier:Int}> {}\n',
			fit(
				'@:nullSafety final class Cls\n\textends Base<Array<ItemWithAVeryLongName>, ResponseWithAnotherVeryLongName, '
				+ '{ timestamp:String, description:String, identifier:Int }> {\n}\n'
			)
		);
	}

	/** A function whose parameters wrap keeps its metadata on the first line. */
	@:pin('control')
	@:killer('M-META-FIT-FILL-WRAP-UNSEEN')
	public function testWrappedParametersKeepTheMetadata(): Void {
		Assert.equals(
			'class C {\n\t@:a public function f(aaaaaaaaaaaaaaaaaaaaaaaa:String, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:String, '
			+ 'cccccccccccccccccccccccccccc:String,\n\t\tdddddddddddddddddddd:String):Void {}\n}\n',
			fit(
				'class C {\n\t@:a public function f(aaaaaaaaaaaaaaaaaaaaaaaa:String, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:String, '
				+ 'cccccccccccccccccccccccccccc:String, dddddddddddddddddddd:String):Void {}\n}\n'
			)
		);
	}

	/** A first line of exactly the maximum keeps its metadata; one column more sends it to its own line. */
	@:pin('control')
	@:killer('M-META-FIT-ONE-OFF-BY-ONE')
	public function testAFirstLineOfExactlyTheMaximumKeepsTheMetadata(): Void {
		final ext: String = 'extends Base<Array<ItemWithAVeryLongName>, ResponseWithAnotherVeryLongName, '
			+ '{timestamp:String, description:String, identifier:Int}> {}\n';
		Assert.equals(
			'@:xml(\'${run(116)}\') final class Y0\n\t$ext\n@:xml(\'${run(117)}\')\nfinal class Y1\n\t$ext',
			fit('@:xml(\'${run(116)}\') final class Y0 $ext\n@:xml(\'${run(117)}\') final class Y1 $ext')
		);
	}

	/** Several simple metadata still share a row of their own above a header that wraps. */
	public function testSeveralMetadataKeepTheirOwnRow(): Void {
		final src: String = '@:a @:b final class Cls\n\textends Base<Array<ItemWithAVeryLongName>, ResponseWithAnotherVeryLongName, '
			+ '{timestamp:String, description:String, identifier:Int}> {}\n';
		Assert.equals(
			'@:a @:b\nfinal class Cls\n\textends Base<Array<ItemWithAVeryLongName>, ResponseWithAnotherVeryLongName, '
			+ '{timestamp:String, description:String, identifier:Int}> {}\n',
			fit(src)
		);
	}

	/** A second write of a kept metadata changes nothing. */
	public function testASecondWriteChangesNothing(): Void {
		for (src in [
			'@:nullSafety final class Cls\n\textends Base<Array<ItemWithAVeryLongName>, ResponseWithAnotherVeryLongName, '
			+ '{timestamp:String, description:String, identifier:Int}> {}\n',
			'class C {\n\t@:a public function f(aaaaaaaaaaaaaaaaaaaaaaaa:String, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:String, '
			+ 'cccccccccccccccccccccccccccc:String, dddddddddddddddddddd:String):Void {}\n}\n'
		]) {
			final once: String = fit(src);
			Assert.equals(once, fit(once));
		}
	}

	/** A header that fits alone but not after its metadata keeps the metadata on its own line and stays unbroken. */
	@:pin('control')
	@:killer('M-META-FIT-LINE-END-WITH-META')
	public function testAHeaderOnlyTheMetadataWouldBreakStaysWhole(): Void {
		final header: String = 'final class Cls extends Base<Array<ItemWithAVeryLongName>, ResponseName, '
			+ '{timestamp:String, description:String, identifier:Int}> {}\n';
		Assert.equals('@:nullSafety\n$header', fit('@:nullSafety $header'));
	}

	/** Parameters that fit alone but not after their metadata keep the metadata on its own line and stay unwrapped. */
	@:pin('guard')
	public function testParametersOnlyTheMetadataWouldWrapStayWhole(): Void {
		final fn: String = 'public function f(aaaaaaaaaaaaaaaaaaaaaa:String, bbbbbbbbbbbbbbbbbbbbbbbb:String, cccccccccccccccccc:String, '
			+ 'dddddddddddd:Int):Void {}\n';
		Assert.equals('class C {\n\t@:a\n\t$fn}\n', fit('class C {\n\t@:a $fn}\n'));
	}

	private static function fit(src: String): String {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		opt.lineWidth = 140;
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataTypeLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataVarLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataOtherLineEnd = MetadataLineEndPolicy.Fit;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opt);
	}

	/** A run of `n` letters, the filler that puts a line at a chosen width. */
	private static function run(n: Int): String {
		return [for (_ in 0...n) 'a'].join('');
	}

}
