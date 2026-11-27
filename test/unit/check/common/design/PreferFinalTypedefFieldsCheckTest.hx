package unit.check.common.design;

import anyparse.check.Check.FixEdit;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.PreferFinalTypedefFields;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.ReachLiveness.ReachConfiguration;

/**
 * The `prefer-final-typedef-fields` check: a typedef of a structure whose fields no file of the run writes is flagged `Info` and
 * rewritten to the class notation with `final` fields. A write of the name (assignment, compound assignment, `++`, an
 * index or reflective write with a literal key) keeps the field; in `wholeType` mode the whole typedef, in `perField` mode only
 * that field, which stays a `var`. A typedef with metadata, under `#if`, extending a structure or mixing the two forms is left
 * alone, and the rewritten form is never re-shortened by `anon-short-fields`.
 */
class PreferFinalTypedefFieldsCheckTest extends Test {

	private static inline final ID: String = 'prefer-final-typedef-fields';
	private static inline final PT_FILE: String = 'src/pkg/Pt.hx';
	private static final PT: String = 'package pkg;\n\ntypedef Pt = { x:Int, y:Int }\n';
	private static final PER_FIELD: String = '{"rules": {"prefer-final-typedef-fields": {"mode": "perField"}}}';
	private static final takes: String = '\tstatic function take(w:{x:Int, y:Int}):Void {}';

	@:pin('control')
	@:killer('M-PFTF-NO-FIX')
	public function testShortFieldsNeverWrittenBecomeFinalInTheClassNotation(): Void {
		final files: Array<SourceEntry> = [pt(PT)];
		Assert.same(['Pt'], reported(files));
		Assert.equals('package pkg;\n\ntypedef Pt = { final x:Int; final y:Int; }\n', fixed(files));
	}

	@:pin('guard')
	public function testTheWriterLaysTheClassNotationOut(): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final edits: Array<FixEdit> = CheckFixture.fixRun(new PreferFinalTypedefFields(), [pt(PT)], null, plugin).edits;
		switch CanonicalEdit.canonicalize(PT, edits, true, plugin) {
			case Ok(text, _):
				Assert.isTrue(text.contains('final x:Int;') && text.contains('final y:Int;'), text);
				Assert.isTrue(CanonicalEdit.isWriterCanonical(text, plugin), text);
			case Err(message):
				Assert.fail(message);
		}
	}

	@:pin('guard')
	public function testAnOptionalFieldKeepsItsMark(): Void {
		Assert.equals(
			'package pkg;\n\ntypedef Pt = { final x:Int; final ?y:Int; }\n', fixed([pt('package pkg;\n\ntypedef Pt = { x:Int, ?y:Int }\n')])
		);
	}

	@:pin('guard')
	public function testALongFormFieldSwapsItsKeyword(): Void {
		final source: String = 'package pkg;\n\ntypedef Pt = {\n\tvar x:Int;\n\t@:optional var y:Int;\n\tpublic var z:Int;\n}\n';
		Assert.equals(
			'package pkg;\n\ntypedef Pt = {\n\tfinal x:Int;\n\t@:optional final y:Int;\n\tpublic final z:Int;\n}\n', fixed([pt(source)])
		);
	}

	@:pin('control')
	@:killer('M-PFTF-IGNORE-WRITES')
	public function testAWriteOfTheNameInAnotherFileKeepsTheTypedef(): Void {
		for (write in ['p.x = 3;', 'p.x += 3;', 'p.x++;', '--p.x;', 'p.x ??= 3;', 'untyped p.x = 3;'])
			Assert.same([], reported([pt(PT), user('p:Pt', write)]), write);
		Assert.same(['Pt'], reported([pt(PT), user('p:Pt', 'p.z = 3; final a = p.x + p.y;')]));
	}

	@:pin('control')
	@:killer('M-PFTF-WHOLE-TYPE')
	public function testOneWrittenFieldKeepsTheWholeTypedefInTheDefaultMode(): Void {
		Assert.same([], reported([pt(PT), user('p:Pt', 'p.y = 3;')]));
	}

	@:pin('control')
	@:killer('M-PFTF-PER-FIELD-VAR')
	public function testPerFieldMakesOnlyTheUnwrittenFieldsFinal(): Void {
		Assert.equals('package pkg;\n\ntypedef Pt = { final x:Int; var y:Int; }\n', fixed([pt(PT), user('p:Pt', 'p.y = 3;')], PER_FIELD));
		final long: String = 'package pkg;\n\ntypedef Pt = {\n\tvar x:Int;\n\tvar y:Int;\n}\n';
		Assert.equals(
			'package pkg;\n\ntypedef Pt = {\n\tvar x:Int;\n\tfinal y:Int;\n}\n', fixed([pt(long), user('p:Pt', 'p.x = 3;')], PER_FIELD)
		);
		Assert.same([], reported([pt(PT), user('p:Pt', 'p.x = 1; p.y = 2;')], PER_FIELD));
	}

	@:pin('control')
	@:killer('M-PFTF-REFLECT-KEY')
	public function testAReflectiveWriteWithTheLiteralNameKeepsTheField(): Void {
		for (write in [
			'Reflect.setField(p, "x", 3);',
			'Reflect.setProperty(p, "x", 3);',
			'Reflect.deleteField(p, "x");',
			'p.setField("x", 3);'
		]) Assert.same([], reported([pt(PT), user('p:Pt', write)]), write);
		Assert.same(['Pt'], reported([pt(PT), user('p:Pt', 'Reflect.setField(p, "z", 3);')]));
	}

	@:pin('control')
	@:killer('M-PFTF-INDEX-KEY')
	public function testAnIndexWriteWithTheLiteralNameKeepsTheField(): Void {
		Assert.same([], reported([pt(PT), user('p:Pt', 'final o:Dynamic = p; o["x"] = 3;')]));
	}

	@:pin('control')
	@:killer('M-PFTF-THIS-IN-CLASS')
	@:killer('M-PFTF-THIS-IN-ABSTRACT')
	public function testThisWriteInAClassIsItsOwnFieldButInAnAbstractIsTheTypedefs(): Void {
		final own: SourceEntry = {
			file: 'src/pkg/Own.hx',
			source: 'package pkg;\n\nclass Own {\n\tvar x:Int = 0;\n\tvar y:Int = 0;\n\n\tpublic function f():Void {\n\t\tthis.x = 1;\n'
				+ '\t\tthis.y++;\n\t}\n}\n'
		};
		Assert.same(['Pt'], reported([pt(PT), own]));
		final over: SourceEntry = {
			file: 'src/pkg/Over.hx',
			source: 'package pkg;\n\nabstract Over(Pt) {\n\tpublic function f():Void {\n\t\tthis.x = 1;\n\t}\n}\n'
		};
		Assert.same([], reported([pt(PT), over]));
	}

	@:pin('control')
	@:killer('M-PFTF-META')
	public function testMetadataAndAConditionalKeepTheTypedefAsWritten(): Void {
		for (lead in ['@:structInit\n', '@:schema(Fmt)\n', '#if !macro\n@:keep\n#end\n'])
			Assert.same([], reported([pt('package pkg;\n\n${lead}typedef Pt = { x:Int, y:Int }\n')]), lead);
		Assert.same([], reported([pt('package pkg;\n\n#if neko\ntypedef Pt = { x:Int, y:Int }\n#end\n')]));
		Assert.same(['Pt'], reported([pt('package pkg;\n\nprivate typedef Pt = { x:Int, y:Int }\n')]));
	}

	@:pin('control')
	@:killer('M-PFTF-MEMBER-KINDS')
	public function testAnExtensionAndAFunctionFieldKeepTheTypedefAsWritten(): Void {
		final extended: String = 'package pkg;\n\ntypedef Pt = { > Base, x:Int }\n\ntypedef Base = { b:Int }\n';
		Assert.same(['Base'], reported([pt(extended)]));
		Assert.same([], reported([pt('package pkg;\n\ntypedef Pt = {\n\tvar x:Int;\n\tfunction f():Void;\n}\n')]));
	}

	@:pin('control')
	@:killer('M-PFTF-MIXED-FORMS')
	public function testAMixOfShortAndLongFieldsKeepsTheTypedefAsWritten(): Void {
		Assert.same([], reported([pt('package pkg;\n\ntypedef Pt = {\n\tx:Int,\n\tvar y:Int;\n}\n')]));
	}

	@:pin('guard')
	public function testAnAccessorFieldAndACommentedKeywordStayVars(): Void {
		final accessor: String = 'package pkg;\n\ntypedef Pt = {\n\tvar x(default, null):Int;\n\tvar y:Int;\n}\n';
		Assert.same([], reported([pt(accessor)]));
		Assert.equals('package pkg;\n\ntypedef Pt = {\n\tvar x(default, null):Int;\n\tfinal y:Int;\n}\n', fixed([pt(accessor)], PER_FIELD));
		Assert.same([], reported([pt('package pkg;\n\ntypedef Pt = {\n\tvar /* why */ x:Int;\n}\n')]));
	}

	@:pin('guard')
	public function testAFinalFieldAloneIsLeftAndTheRestIsRewritten(): Void {
		Assert.same([], reported([pt('package pkg;\n\ntypedef Pt = {\n\tfinal x:Int;\n}\n')]));
		Assert.equals(
			'package pkg;\n\ntypedef Pt = {\n\tfinal x:Int;\n\tfinal y:Int;\n}\n',
			fixed([pt('package pkg;\n\ntypedef Pt = {\n\tfinal x:Int;\n\tvar y:Int;\n}\n')])
		);
	}

	@:pin('control')
	@:killer('M-PFTF-STALE-BODY')
	public function testAnEditIsDroppedWhenTheTypedefChangedSinceTheFinding(): Void {
		final check: PreferFinalTypedefFields = new PreferFinalTypedefFields();
		final found: Array<Violation> = CheckFixture.violationsIn(check, [pt(PT)]);
		Assert.equals(1, found.length);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, check.fix(PT.replace('y:Int', 'y:Float'), found, plugin).length);
		Assert.isTrue(check.fix(PT, found, plugin).length > 0);
	}

	@:pin('guard')
	public function testTheRewrittenFormIsNotReshortenedAndIsNotFlaggedAgain(): Void {
		final both: LintConfig = LintConfig.parse('{"rules": {"anon-short-fields": {"enabled": true}, "$ID": {"enabled": true}}}');
		final long: String = 'package pkg;\n\ntypedef Pt = {\n\tvar x:Int;\n\tvar y:Int;\n}\n';
		for (source in [PT, long]) {
			final settled: SourceEntry = pt(fixed([pt(source)]));
			final found: Array<Violation> = Linter.run([settled], new HaxeQueryPlugin(), null, _ -> both, true);
			Assert.same([], [ for (v in found) if (v.rule == 'anon-short-fields' || v.rule == ID) v.message ]);
		}
	}

	public function testRegisteredAndOffByDefault(): Void {
		Assert.notNull(Linter.byId(ID));
		final files: Array<SourceEntry> = [pt(PT)];
		final off: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> LintConfig.parse('{}'), true);
		Assert.equals(0, off.filter(v -> v.rule == ID).length);
		final on: LintConfig = LintConfig.parse('{"rules": {"$ID": {"enabled": true}}}');
		final found: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true);
		Assert.equals(1, found.filter(v -> v.rule == ID).length);
	}

	public function testTheModeIsTheOnlyAcceptedKeyAndAnUnknownValueReadsAsTheDefault(): Void {
		Assert.same(['mode'], new PreferFinalTypedefFields().acceptedOptions());
		Assert.same(['Pt'], reported([pt(PT)], '{"rules": {"$ID": {"mode": "bogus"}}}'));
		Assert.same([], reported([pt(PT), user('p:Pt', 'p.y = 3;')], '{"rules": {"$ID": {"mode": "bogus"}}}'));
	}

	@:pin('control')
	@:killer('M-PFTF-UNVERIFIED-REGION')
	public function testNamesInConditionalCodeNoBuildIsKnownToTakeKeepTheTypedef(): Void {
		for (region in [guarded('never_defined', 'final q:Pt = p;'), guarded('js', 'final q:Pt = p;')])
			Assert.same([], reported([pt(PT), region]), region.source);
		for (region in [
			guarded('never_defined', 'take({x: 1, y: 2});', takes),
			guarded('js', 'take({x: 1, y: 2});', takes)
		]) Assert.same([], reported([pt(PT), region]), region.source);
		Assert.same(['Pt'], reported([pt(PT), guarded('js', 'final n:Int = 1;')]));
	}

	@:pin('control')
	@:killer('M-PFTF-DEAD-BRANCH-LIVE')
	@:killer('M-PFTF-LIVE-BRANCH-DEAD')
	public function testTheDeclaredBuildsDecideWhichConditionalCodeIsUnverified(): Void {
		final web: ReachConfiguration = {
			name: 'web',
			defined: ['js'],
			everDefined: ['js'],
			values: [],
			compiled: [],
			types: []
		};
		for (region in [
			guarded('never_defined', 'final q:Pt = p;'),
			guarded('never_defined', 'take({x: 1, y: 2});', takes)
		]) {
			final files: Array<SourceEntry> = [pt(PT), region];
			Assert.same([], violationsOver(files, QueryTestHelpers.projectPlugin(files, null, true, true, [web])), region.source);
		}
		for (region in [guarded('js', 'final q:Pt = p;'), guarded('js', 'take({x: 1, y: 2});', takes)]) {
			final files: Array<SourceEntry> = [pt(PT), region];
			Assert.same(['Pt'], violationsOver(files, QueryTestHelpers.projectPlugin(files, null, true, true, [web])), region.source);
		}
	}

	private function violations(files: Array<SourceEntry>, ?json: String): Array<Violation> {
		final config: Null<LintConfig> = json == null ? null : LintConfig.parse(json);
		final check: PreferFinalTypedefFields = new PreferFinalTypedefFields();
		if (config != null) check.setConfigResolver(_ -> config);
		return CheckFixture.violationsIn(check, files, null, config == null ? null : _ -> config);
	}

	/** The names of the typedefs the check reports in `files`. */
	private function reported(files: Array<SourceEntry>, ?json: String): Array<String> {
		return violations(files, json).map(v -> v.message.split('\'')[1]);
	}

	/** The source of the first file with every fix of the check applied. */
	private function fixed(files: Array<SourceEntry>, ?json: String): String {
		final config: Null<LintConfig> = json == null ? null : LintConfig.parse(json);
		final edits: Array<FixEdit> = CheckFixture.fixRun(
			new PreferFinalTypedefFields(), files, null, null, config == null ? null : _ -> config
		)
			.edits;
		return CanonicalEdit.applyEdits(files[0].source, edits);
	}

	/** The names of the typedefs the check reports in `files` when the run is hosted by `plugin`. */
	private function violationsOver(files: Array<SourceEntry>, plugin: CachingGrammarPlugin): Array<String> {
		return CheckFixture.violationsIn(new PreferFinalTypedefFields(), files, plugin).map(v -> v.message.split('\'')[1]);
	}

	private static function pt(source: String): SourceEntry {
		return { file: PT_FILE, source: source };
	}

	/** A class of package `app` whose one method takes `params` and runs `body`. */
	private static function user(params: String, body: String): SourceEntry {
		return {
			file: 'src/app/User.hx',
			source: 'package app;\n\nimport pkg.Pt;\n\nclass User {\n\tpublic static function f($params):Void {\n\t\t$body\n\t}\n}\n'
		};
	}

	/** A class of package `app` whose `f(p:Pt)` holds `body` under `#if $define`, and `extra` as a member under the same. */
	private static function guarded(define: String, body: String, ?extra: String): SourceEntry {
		final member: String = extra == null ? '' : '\n\t#if $define\n$extra\n\t#end\n';
		final head: String = 'package app;\n\nimport pkg.Pt;\n\nclass Guarded {\n\tpublic static function f(p:Pt):Void {\n';
		return { file: 'src/app/Guarded.hx', source: '$head\t\t#if $define\n\t\t$body\n\t\t#end\n\t}\n$member}\n' };
	}

}
