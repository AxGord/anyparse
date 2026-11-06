package unit.dev;

import dev.RuleScope;
import dev.SuiteImpact.ImpactSource;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.RuleScope`: the rule ids a diff of rule-code files can move, or null when only the whole tree can say. */
@:nullSafety(Strict)
final class RuleScopeTest extends Test {

	private static inline final DIR: String = 'src/anyparse/check/common/imports/';
	private static inline final DIFF_HEAD: String = 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n';
	private static final WALK: ImpactSource = {
		path: 'src/anyparse/check/scan/Walk.hx',
		text: 'package anyparse.check.scan;\n\nfinal class Walk {\n\tpublic static function go(): Void {}\n}\n'
	};

	@:pin('guard')
	public function testOneRuleFileRunsItsIdOnly(): Void {
		Assert.same(['alpha'], RuleScope.idsOf(tree(['Alpha', 'Beta']), [at('Alpha')], null));
	}

	@:pin('guard')
	public function testTwoRuleFilesRunBothIdsSorted(): Void {
		Assert.same(['alpha', 'beta'], RuleScope.idsOf(tree(['Alpha', 'Beta']), [at('Beta'), at('Alpha')], null));
	}

	@:pin('guard')
	public function testASharedFileRunsAll(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha']).concat([WALK, outside('anyparse.check.scan.Walk', 'Walk.go()')]);
		Assert.isNull(RuleScope.idsOf(sources, [WALK.path], null));
		Assert.isNull(RuleScope.idsOf(sources, [at('Alpha'), WALK.path], null));
		Assert.isNull(RuleScope.idsOf(sources, ['src/anyparse/query/Other.hx'], null));
	}

	public function testAHelperRunsTheRulesThatNameIt(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha', 'Beta']).concat([WALK]);
		sources[0] = rule('Alpha', "'alpha'", 'anyparse.check.scan.Walk', 'Walk.go()');
		Assert.same(['alpha'], RuleScope.idsOf(sources, [WALK.path], null));
	}

	public function testAnIdInAConstantOfTheFileIsRead(): Void {
		final text: String = rule(
			'Alpha', 'RULE_ID'
		).text.replace('{\n\tpublic', "{\n\tprivate static inline final RULE_ID: String = 'alpha';\n\tpublic");
		Assert.same(['alpha'], RuleScope.idsOf(withText(tree(['Alpha']), 'Alpha', text), [at('Alpha')], null));
	}

	public function testAnIdTheFileDoesNotSpellIsNoBound(): Void {
		Assert.isNull(RuleScope.idsOf(withText(tree(['Alpha']), 'Alpha', rule('Alpha', 'OTHER.ID').text), [at('Alpha')], null));
	}

	public function testEveryRuleIdAFindingCarriesIsCompared(): Void {
		final text: String = rule('Alpha', "'alpha'").text.replace('}\n}', "var v = { rule: 'alpha-sub' };\n}\n}");
		Assert.same(['alpha', 'alpha-sub'], RuleScope.idsOf(withText(tree(['Alpha']), 'Alpha', text), [at('Alpha')], null));
	}

	@:pin('guard')
	public function testARuleAnotherSourceCallsRunsAll(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha']).concat([outside('anyparse.check.common.imports.Alpha', 'Alpha.helper()')]);
		Assert.isNull(RuleScope.idsOf(sources, [at('Alpha')], null));
	}

	public function testARuleAnotherRuleCallsRunsBoth(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha', 'Beta']);
		sources[1] = rule('Beta', "'beta'", 'anyparse.check.common.imports.Alpha', 'Alpha.helper()');
		Assert.same(['alpha', 'beta'], RuleScope.idsOf(sources, [at('Alpha')], null));
	}

	public function testAMentionInAnotherSourcesCommentOrTheRegistryOrItselfIsNoCall(): Void {
		final prose: ImpactSource = {
			path: 'src/anyparse/query/Other.hx',
			text: 'package anyparse.query;\n\n// see Alpha\nfinal class Other {}\n'
		};
		Assert.same(['alpha'], RuleScope.idsOf(tree(['Alpha']).concat([prose]), [at('Alpha')], null));
	}

	public function testMoreRulesThanTheCapRunAll(): Void {
		final names: Array<String> = [for (i in 0...60) 'R$i'];
		final sources: Array<ImpactSource> = names.map(name ->
			rule(name, quoted(name.toLowerCase()), 'anyparse.check.scan.Walk', 'Walk.go()')
		)
			.concat([registry(names), WALK]);
		Assert.isNull(RuleScope.idsOf(sources, [WALK.path], null));
	}

	public function testARuleReplacingAnotherRunsAll(): Void {
		final text: String = rule('Alpha', "'alpha'").text.replace('{\n', '{\n\t// implements Supersedes\n');
		Assert.isNull(RuleScope.idsOf(withText(tree(['Alpha']), 'Alpha', text), [at('Alpha')], null));
	}

	@:pin('guard')
	public function testANewRuleFileRegisteredByTheRegistryRunsItsId(): Void {
		final edit: String = diff('+import anyparse.check.common.imports.Alpha;\n+new Alpha(),');
		Assert.same(['alpha'], RuleScope.idsOf(tree(['Alpha']), [at('Alpha'), RuleScope.REGISTRY], edit));
	}

	@:pin('guard')
	public function testARegistryEditBeyondTheTouchedRulesRunsAll(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha']);
		final touched: Array<String> = [at('Alpha'), RuleScope.REGISTRY];
		Assert.isNull(RuleScope.idsOf(sources, touched, diff('+new Beta(),')));
		Assert.isNull(RuleScope.idsOf(sources, touched, diff('-new Alpha(),')));
		Assert.isNull(RuleScope.idsOf(sources, touched, diff('+var x = 1;')));
		Assert.isNull(RuleScope.idsOf(sources, touched, null));
		Assert.isNull(RuleScope.idsOf(sources, [RuleScope.REGISTRY], diff('+import a.B;')));
	}

	public function testOnlyTheScopedRulesFindingsAreKept(): Void {
		final report: String = '[{"file":"a","rule":"alpha"},{"file":"b","rule":"beta"},{"file":"c"}]';
		Assert.equals('[\n  {\n    "file": "a",\n    "rule": "alpha"\n  }\n]', RuleScope.keep(report, ['alpha']));
	}

	public function testATreeIsReadFromDiskForItsTouchedRuleFilesAndTheSourcesThatCallThem(): Void {
		TempDir.with(dir -> {
			final root: String = dir.file('tree');
			for (source in tree(['Alpha'])) put(root, source.path, source.text);
			Assert.same(['alpha'], RuleScope.ofTree(root, 'HEAD', [at('Alpha'), 'test/T.hx', 'docs/x.md']));
			put(root, 'tools/Free.hx', outside('anyparse.check.common.imports.Alpha', 'Alpha.x()').text);
			Assert.same(['alpha'], RuleScope.ofTree(root, 'HEAD', [at('Alpha')]));
			final caller: ImpactSource = outside('anyparse.check.common.imports.Alpha', 'Alpha.x()');
			put(root, caller.path, caller.text);
			Assert.isNull(RuleScope.ofTree(root, 'HEAD', [at('Alpha')]));
		});
	}

	public function testAnEngineInputBeyondTheRulesRunsAll(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha']);
		for (other in [
			'src/anyparse/grammar/haxe/X.hx',
			'src/anyparse/query/cli/X.hx',
			'src/anyparse/macro/X.hx'
		]) Assert.isNull(RuleScope.idsOf(sources, [at('Alpha'), other], null), other);
		TempDir.with(dir -> {
			final root: String = dir.file('tree');
			for (source in sources) put(root, source.path, source.text);
			for (other in [
				'src/anyparse/grammar/haxe/X.hx',
				'src/anyparse/query/cli/X.hx',
				'bin/apq-js.hxml',
				'apq.json'
			]) {
				put(root, other, 'x');
				Assert.isNull(RuleScope.ofTree(root, 'HEAD', [at('Alpha'), other]), other);
			}
		});
	}

	public function testAHelperTheRegistryNamesBeyondItsListingRunsAll(): Void {
		final sources: Array<ImpactSource> = tree(['Alpha']).concat([WALK]);
		final lines: Array<String> = [
			'import anyparse.check.scan.Walk;',
			'final class Linter {',
			'\tpublic function builtins() {',
			'\t\tWalk.go();',
			'\t\treturn [new Alpha()];',
			'\t}',
			'}',
			''
		];
		Assert.isNull(RuleScope.idsOf(withPath(sources, RuleScope.REGISTRY, lines.join('\n')), [WALK.path], null));
	}

	private static function rule(name: String, id: String, ?imported: String, ?call: String): ImpactSource {
		final constructor: String = '\tpublic function new() {\n\t\tsuper($id, "d", RuleCategory.Imports);\n\t}\n';
		final use: String = call == null ? '' : '\tpublic function run(): Void {\n\t\t$call;\n\t}\n';
		final imports: String = imported == null ? '' : 'import $imported;\n\n';
		return {
			path: at(name),
			text: 'package anyparse.check.common.imports;\n\n${imports}final class $name extends RuleBase {\n$constructor$use}\n'
		};
	}

	private static function put(root: String, file: String, text: String): Void {
		final path: String = Path.join([root, file]);
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}

	private static function registry(classes: Array<String>): ImpactSource {
		final lines: Array<String> = ['package anyparse.check;', ''].concat(
			classes.map(name -> 'import anyparse.check.common.imports.$name;')
		)
			.concat([
				'',
				'final class Linter {',
				'\tpublic static function builtins() {',
				'\t\treturn ['
			])
			.concat([classes.map(name -> '\t\t\tnew $name()').join(',\n')])
			.concat(['\t\t];', '\t}', '}', '']);
		return { path: RuleScope.REGISTRY, text: lines.join('\n') };
	}

	private static function at(name: String): String {
		return '$DIR$name.hx';
	}

	private static function diff(lines: String): String {
		return '$DIFF_HEAD$lines\n';
	}

	private static function called(source: ImpactSource, call: String): String {
		return '${source.text}\nvar used = $call;';
	}

	/** A tree of the registry listing `names` and a rule class for each, each spelling the id its name lowercased. */
	private static function tree(names: Array<String>): Array<ImpactSource> {
		return names.map(name -> rule(name, quoted(name.toLowerCase()))).concat([registry(names)]);
	}

	private static function withText(sources: Array<ImpactSource>, name: String, text: String): Array<ImpactSource> {
		return sources.map(s -> s.path == at(name) ? {path: s.path, text: text } : s);
	}

	/** A source of the query package that names `imported` and runs `call`. */
	private static function outside(imported: String, call: String): ImpactSource {
		final lines: Array<String> = [
			'package anyparse.query;',
			'',
			'import $imported;',
			'',
			'final class Other {',
			'\tpublic static function go(): Void {',
			'\t\t$call;',
			'\t}',
			'}',
			''
		];
		return { path: 'src/anyparse/query/Other.hx', text: lines.join('\n') };
	}

	private static function withPath(sources: Array<ImpactSource>, path: String, text: String): Array<ImpactSource> {
		return sources.map(s -> s.path == path ? {path: path, text: text } : s);
	}

	private static function quoted(id: String): String {
		return '\'$id\'';
	}

}
