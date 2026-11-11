package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.IndentChar;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * `HxWriteOptionsKit` and the typed configuration of `HxWriteFixture.triviaWrite` / `plainWrite`: the two baselines a typed edit starts
 * from differ where a config document re-baselines, a typed write reaches the writer exactly as the equivalent document does without
 * touching the caller's options, and `strictJson` refuses a document whose setting the loader would ignore.
 */
@:nullSafety(Strict)
final class HxWriteOptionsKitTest extends Test {

	private static final IF_SOURCE: String = 'class A {\n\tfunction f() {\n\t\tif (a) b();\n\t}\n}';

	@:pin('control')
	@:killer('M-KIT-FORK-STARTS-RAW')
	public function testForkBaselineIsWhatAnEmptyConfigLoads(): Void {
		Assert.equals(BodyPolicy.Next, HxWriteOptionsKit.forkWith(_ -> {}).ifBody);
		Assert.equals(40, HxWriteOptionsKit.forkWith(opts -> opts.lineWidth = 40).lineWidth);
	}

	@:pin('control')
	@:killer('M-KIT-RAW-STARTS-FORK')
	public function testRawBaselineKeepsTheCompiledDefaults(): Void {
		Assert.equals(BodyPolicy.FitLine, HxWriteOptionsKit.rawWith(_ -> {}).ifBody);
		Assert.equals(40, HxWriteOptionsKit.rawWith(opts -> opts.lineWidth = 40).lineWidth);
	}

	public function testTheBaselinesWriteAnIfBodyDifferently(): Void {
		Assert.equals(
			'class A {\n\tfunction f() {\n\t\tif (a)\n\t\t\tb();\n\t}\n}',
			HxWriteFixture.triviaWrite(IF_SOURCE, HxWriteOptionsKit.forkWith(_ -> {}))
		);
		Assert.equals(IF_SOURCE, HxWriteFixture.triviaWrite(IF_SOURCE, HxWriteOptionsKit.rawWith(_ -> {})));
	}

	@:pin('control')
	@:killer('M-FIXTURE-TYPED-OPTIONS-IGNORED')
	public function testATypedWriteReachesTheWriterAsTheDocumentDoes(): Void {
		final typed: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(opts -> {
			opts.indentChar = IndentChar.Space;
			opts.indentSize = 2;
		});
		final json: String = '{"indentation": {"character": "  "}}';
		final source: String = 'class A {\n\tvar x:Int;\n}';
		final written: String = HxWriteFixture.triviaWrite(source, typed);
		Assert.isTrue(written.indexOf('\n  var') != -1, 'the typed indent must reach the writer in: <$written>');
		Assert.equals(HxWriteFixture.triviaWrite(source, json), written);
		Assert.equals(HxWriteFixture.plainWrite(source, json), HxWriteFixture.plainWrite(source, typed));
	}

	@:pin('control')
	@:killer('M-FIXTURE-TYPED-OPTIONS-ALIASED')
	public function testATypedWriteLeavesTheCallersOptionsAlone(): Void {
		final typed: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(_ -> {});
		Assert.equals(HxWriteFixture.triviaWrite(IF_SOURCE, typed), HxWriteFixture.triviaWrite(IF_SOURCE, typed));
		Assert.equals(HxWriteFixture.plainWrite(IF_SOURCE, typed), HxWriteFixture.plainWrite(IF_SOURCE, typed));
		Assert.isTrue(typed.finalNewline);
	}

	@:pin('control')
	@:killer('M-KIT-STRICT-NO-REFUSAL')
	public function testStrictJsonRefusesAKeyTheLoaderIgnores(): Void {
		var refusal: Null<String> = null;
		try {
			HxWriteOptionsKit.strictJson('{"wrapping": {"maxLineLenght": 40}}');
		} catch (exception: String) {
			refusal = exception;
		}
		Assert.notNull(refusal);
		Assert.isTrue(refusal != null && refusal.indexOf('maxLineLenght') != -1, 'the refusal must name the key: <$refusal>');
	}

	public function testStrictJsonLoadsADocumentTheLoaderUnderstands(): Void {
		Assert.equals(40, HxWriteOptionsKit.strictJson('{"wrapping": {"maxLineLength": 40}}').lineWidth);
	}

}
