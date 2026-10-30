package unit.check;

import anyparse.check.RuleIndex;
import anyparse.check.common.literals.MagicNumber;
import anyparse.check.haxe.literals.PreferLpad;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.ExitCode;
import unit.cli.CliFixture;

using StringTools;
using Lambda;

/**
 * The language axis of the rule registry: a `LanguageBound` check runs only on the grammars it names, an unbound one on
 * every grammar, an explicit `--rule` naming a bound rule on another grammar is refused, and every listing says which
 * grammars a rule runs on.
 */
@:nullSafety(Strict)
class LanguageBoundTest extends Test {

	@:pin('control') @:killer('M-LANGUAGE-BOUND-RUNS-EVERYWHERE')
	public function testABoundCheckRunsOnlyOnTheGrammarsItNames(): Void {
		final probe: LanguageBoundProbe = new LanguageBoundProbe(HaxeQueryPlugin.LANG);
		final haxe: Array<{ file: String, source: String }> = [{ file: 'Probe.hx', source: 'class Probe {}\n' }];
		Assert.equals(1, Linter.collect(haxe, new HaxeQueryPlugin(), [probe]).length, 'the grammar it names runs it');
		final json: Array<{ file: String, source: String }> = [{ file: 'probe.json', source: '{"a": 1}\n' }];
		Assert.equals(0, Linter.collect(json, new JsonQueryPlugin(), [probe]).length, 'another grammar never hands it a file');
		Assert.isTrue(Linter.runsOn(new MagicNumber(), JsonQueryPlugin.LANG), 'an unbound check runs on every grammar');
	}

	@:pin('control') @:killer('M-FOREIGN-RULE-ANSWERED')
	public function testAnExplicitRuleOfAnotherGrammarIsRefused(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.writeAs('languagebound', 'json', '{"a": 1}\n');
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['lint', '--lang', 'json', '--rule', 'prefer-lpad', file]));
		sys.FileSystem.deleteFile(file);
		Assert.equals((ExitCode.EXIT_USAGE: Int), code, err);
		Assert.stringContains('rule "prefer-lpad" runs on haxe only, and this run reads json', err);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-FOREIGN-RULE-ALWAYS')
	public function testADefaultSelectionOnAnotherGrammarIsNotRefused(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.writeAs('languagebound', 'json', '{"a": 1}\n');
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['lint', '--lang', 'json', file]));
		sys.FileSystem.deleteFile(file);
		Assert.equals((ExitCode.EXIT_OK: Int), code, err);
		Assert.isFalse(err.indexOf('runs on haxe only') >= 0, 'a bound rule the selection drops is no refusal: $err');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-SCOPED-LISTING-UNFILTERED')
	public function testTheListingsLeaveOutOrMarkARuleOfAnotherGrammar(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.writeAs('languagebound', 'json', '{"a": 1}\n');
		final scoped: String = CliFixture.captureStdout(() -> Cli.run(['lint', '--list-rules', '--lang', 'json', file]));
		sys.FileSystem.deleteFile(file);
		Assert.isFalse(scoped.indexOf('prefer-lpad') >= 0, 'a scope of another grammar never runs prefer-lpad: $scoped');
		Assert.stringContains('magic-number', scoped, 'an unbound rule stays listed');
		final registry: String = CliFixture.captureStdout(() -> Cli.run(['lint', '--list-rules']));
		final line: Null<String> = registry.split('\n').find(l -> l.startsWith('prefer-lpad '));
		Assert.isTrue(line != null && line.endsWith(' [haxe only]'), 'the registry line says it: $line');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-LANGUAGE-COLUMN-ANY')
	public function testEveryListingNamesTheGrammarsARuleRunsOn(): Void {
		Assert.equals('haxe', RuleIndex.languageOf(new PreferLpad()));
		Assert.equals('any', RuleIndex.languageOf(new MagicNumber()));
		final markdown: String = RuleIndex.markdown([new PreferLpad(), new MagicNumber()]);
		Assert.stringContains('| `prefer-lpad` | haxe | off |', markdown);
		Assert.stringContains('| `magic-number` | any | on |', markdown);
		final records: Array<{ id: String, languages: Array<String> }> =
			haxe.Json.parse(RuleIndex.json([new PreferLpad(), new MagicNumber()]));
		Assert.same([['haxe'], []], [for (r in records) r.languages], 'an unbound rule lists no grammar');
	}

}
