package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * Fixture scaffolding shared by the `trivial-getter` check test parts: class-source
 * assembly, a single violation run, and the fix assertions.
 */
class TrivialGetterCheckTestBase extends Test {

	private function cls(members: String): String {
		return 'class C {\n\t$members\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new TrivialGetter().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final r: { vs: Array<Violation>, check: TrivialGetter } = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixContains(src: String, present: String): Void {
		final r: { vs: Array<Violation>, check: TrivialGetter } = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r: { vs: Array<Violation>, check: TrivialGetter } = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): { check: TrivialGetter, vs: Array<Violation> } {
		return runFilesAndExpectOne([{ file: 'C.hx', source: src }]);
	}

	/**
	 * The multi-file arm of `runAndExpectOne`: run the check over a whole file set (an interface,
	 * a subtype, an owner) and assert exactly one finding, handing back the check so the caller can
	 * drive `fix` / `crossFileFix` with the same instance.
	 */
	private function runFilesAndExpectOne(files: Array<{ file: String, source: String }>): {
		check: TrivialGetter,
		vs: Array<Violation>
	} {
		final check: TrivialGetter = new TrivialGetter();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

	private function fixedText(src: String): String {
		final r: { vs: Array<Violation>, check: TrivialGetter } = runAndExpectOne(src);
		return switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
				'';
		}
	}

}
