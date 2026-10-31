package unit.devkit;

import devkit.Cmd.cmd;
import devkit.CmdTemplate;
import devkit.Command;
import utest.Assert;
import utest.Test;

/**
 * `Cmd.cmd` — a template read into an argument vector at compile time. What these pin is the reason the macro exists:
 * an interpolated value is never re-split or re-quoted, whatever characters it carries, and only an array filling a
 * whole word becomes several arguments.
 */
@:nullSafety(Strict)
final class CmdTest extends Test {

	public function testLiteralWordsSplitOnWhitespace(): Void {
		Assert.same(['git', 'log', '--oneline', '-3'], cmd('git  log	--oneline -3').argv);
	}

	public function testAValueIsOneArgumentWhateverItHolds(): Void {
		final repo: String = '/tmp/a b';
		final range: String = 'x..y';
		Assert.same(['git', '-C', '/tmp/a b', 'log', '--format=%h', 'x..y'], cmd('git -C $repo log --format=%h $range').argv);
		final hostile: String = 'a "b" \'c\'; rm -rf $$HOME `x` | y > z';
		Assert.same(['echo', hostile], cmd('echo $hostile').argv);
		final empty: String = '';
		Assert.same(['echo', '', 'x'], cmd('echo $empty x').argv, 'an empty value is still one argument');
	}

	public function testAnArrayFillingAWordSplicesOneArgumentPerElement(): Void {
		final files: Array<String> = ['a b', 'c'];
		Assert.same(['ls', 'a b', 'c', '-l'], cmd('ls $files -l').argv);
		final none: Array<String> = [];
		Assert.same(['ls', '-l'], cmd('ls $none -l').argv, 'an empty array adds no argument');
	}

	public function testAValueInsideAWordJoinsItsText(): Void {
		final dir: String = 'out dir';
		final n: Int = 2;
		Assert.same(['cp', '--target=out dir/x', 'v3'], cmd('cp --target=$dir/x v${n + 1}').argv);
	}

	public function testQuotesGroupLiteralTextAndAreDropped(): Void {
		Assert.same(['git', 'log', '--format=%h %s'], cmd('git log "--format=%h %s"').argv);
		Assert.same(['echo', '', 'b'], cmd('echo "" b').argv, '`""` is one empty argument');
		final who: String = 'x y';
		Assert.same(['echo', 'hi x y!'], cmd('echo "hi $who!"').argv);
	}

	public function testDoubleDollarIsALiteralDollar(): Void {
		Assert.same(['echo', '$$HOME', 'a$'], cmd('echo $$HOME a$').argv);
	}

	public function testANullValueThrowsWhenTheCommandIsBuilt(): Void {
		final missing: Null<String> = null;
		Assert.raises(() -> cmd('echo $missing'));
		final nothing: Null<Array<String>> = null;
		Assert.raises(() -> cmd('echo $nothing'));
	}

	public function testMalformedTemplatesAreRefusedWithTheirOffset(): Void {
		// double-quoted: a Haxe single-quoted string would read `${` as its own interpolation
		for (bad in ['echo "open', "echo ${open", "echo ${ }"]) {
			final error: Null<TemplateError> = try {
				Assert.fail('read as ${CmdTemplate.parse(bad).length} word(s)');
				null;
			} catch (e: TemplateError) {
				e;
			};
			Assert.notNull(error, bad);
			if (error != null) Assert.equals(5, error.offset, bad);
		}
	}

	public function testTemplatePartsSeparateTextFromValues(): Void {
		Assert.same([[Text('a')], [Text('b='), Value('x', 5), Text('/c')], [Value('y + 1', 11)]], CmdTemplate.parse("a b=$x/c ${y + 1}"));
	}

	public function testToStringQuotesForAReaderNeverForAShell(): Void {
		final odd: String = 'it\'s here';
		Assert.equals('git -C \'it\'\\\'\'s here\' log \'\'', cmd('git -C $odd log ""').toString());
		Assert.equals('a | b', cmd('a').pipe(cmd('b')).toString());
	}

	public function testACommandIsImmutable(): Void {
		final base: Command = cmd('echo a');
		final changed: Command = base.at('/tmp').env('X', '1').timeout(5).input('i');
		Assert.notEquals(base, changed);
		Assert.same(['echo', 'a'], changed.argv);
		Assert.raises(() -> Command.of([]));
	}

	public function testADynamicOrAnyValueIsOneArgument(): Void {
		final dyn: Dynamic = 'a b'; // noqa: avoid-dynamic
		Assert.same(['echo', 'a b'], cmd('echo $dyn').argv, 'a Dynamic value is never split into characters');
		final any: Any = 'q r';
		Assert.same(['echo', 'q r'], cmd('echo $any').argv, 'an Any value is never split into characters');
	}

}
