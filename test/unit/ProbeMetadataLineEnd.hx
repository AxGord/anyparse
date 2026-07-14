package unit;

import utest.Test;
import utest.Assert;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-metadata-line-end-function — verify each
 * `metadataFunctionLineEnd` policy emits the expected member-meta
 * gap shape on the same source input.
 */
class ProbeMetadataLineEnd extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	private static final SRC: String = 'class Main {\n' + '\t@Test @doc("a") function main() {}\n\n'
		+ '\t@Test\n\t@doc("b") function main() {}\n}\n';

	public function testNonePreservesSource(): Void {
		final out: String = render(MetadataLineEndPolicy.None);
		final expected: String = 'class Main {\n' + '\t@Test @doc("a") function main() {}\n\n'
			+ '\t@Test\n\t@doc("b") function main() {}\n}\n';
		Assert.equals(expected, out);
	}

	public function testAfterForcesOnePerLine(): Void {
		final out: String = render(MetadataLineEndPolicy.After);
		final expected: String = 'class Main {\n' + '\t@Test\n\t@doc("a")\n\tfunction main() {}\n\n'
			+ '\t@Test\n\t@doc("b")\n\tfunction main() {}\n}\n';
		Assert.equals(expected, out);
	}

	public function testAfterLastPreservesInterButForcesTrailing(): Void {
		final out: String = render(MetadataLineEndPolicy.AfterLast);
		final expected: String = 'class Main {\n' + '\t@Test @doc("a")\n\tfunction main() {}\n\n'
			+ '\t@Test\n\t@doc("b")\n\tfunction main() {}\n}\n';
		Assert.equals(expected, out);
	}

	public function testForceAfterLastCollapsesInterAndForcesTrailing(): Void {
		final out: String = render(MetadataLineEndPolicy.ForceAfterLast);
		final expected: String = 'class Main {\n' + '\t@Test @doc("a")\n\tfunction main() {}\n\n'
			+ '\t@Test @doc("b")\n\tfunction main() {}\n}\n';
		Assert.equals(expected, out);
	}

	private static function render(policy: MetadataLineEndPolicy): String {
		final m: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(SRC);
		final opt: HxModuleWriteOptions = Reflect.copy(HaxeFormat.instance.defaultWriteOptions);
		opt.metadataFunctionLineEnd = policy;
		return HaxeModuleTriviaWriter.write(m, opt);
	}

}
