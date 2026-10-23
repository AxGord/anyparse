package unit.devkit;

import devkit.Args;
import utest.Assert;
import utest.Test;

/** `Args` — flags and options taken from anywhere on the line, in either `--name value` or `--name=value` form. */
@:nullSafety(Strict)
final class ArgsTest extends Test {

	public function testFlagsAndOptionsAnywhereThenPositionals(): Void {
		final args: Args = new Args(['a', '--quiet', '--list=x', 'b', '--range', 'r', '--quiet']);
		Assert.isTrue(args.flag('--quiet'));
		Assert.isFalse(args.flag('--loud'));
		Assert.equals('x', args.option('--list'));
		Assert.equals('r', args.option('--range'));
		Assert.isNull(args.option('--cache'));
		Assert.same(['a', 'b'], args.positionals(['<a>', '<b>']));
	}

	public function testValuesTakeSeveralAndTheLastOccurrenceWins(): Void {
		final args: Args = new Args(['--after', 'x', 'y', 'p', '--list', 'a', '--list', 'b']);
		Assert.same(['x', 'y'], args.values('--after', 2));
		Assert.equals('b', args.option('--list'));
		Assert.same(['p'], args.positionals(['<p>']));
	}

	public function testARepeatableOptionAnswersEveryOccurrenceInOrder(): Void {
		final args: Args = new Args(['--root', 'a', 'p', '--root=b', '--root', 'c']);
		Assert.same(['a', 'b', 'c'], args.options('--root'));
		Assert.same([], args.options('--root'), 'every occurrence is taken');
		Assert.same(['p'], args.positionals(['<p>']));
		Assert.raises(() -> new Args(['--root']).options('--root'), UsageError, 'an occurrence without its value');
	}

	public function testRefusals(): Void {
		Assert.raises(() -> new Args(['--list']).option('--list'), UsageError, 'an option without its value');
		Assert.raises(() -> new Args(['--after', 'x']).values('--after', 2), UsageError);
		Assert.raises(() -> new Args(['--bogus']).done(), UsageError, 'an option nobody took');
		Assert.raises(() -> new Args(['a']).done(), UsageError, 'a positional where none is taken');
		Assert.raises(() -> new Args([]).positionals(['<a>']), UsageError);
		Assert.raises(() -> new Args(['a', 'b']).positionals(['<a>']), UsageError);
	}

	public function testEverythingAfterADoubleDashIsPositional(): Void {
		Assert.same(['-', '--weird'], new Args(['-', '--', '--weird']).positionals(['<a>', '<b>']));
	}

}
