package unit.check.common.design;

import anyparse.check.Check.FixEdit;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.PreferReadOnlyArray;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-read-only-array` check: a field, typedef field, parameter, return type or annotated local of type `Array<T>`
 * nothing mutates through is flagged `Info` and retyped `haxe.ds.ReadOnlyArray<T>`. A mutation through the name, a cast and
 * a reflective key keep the array; extern, kept and reflected declarations, signatures shared with an override or an
 * interface, names in conditional code no build compiles, members under `#if`, and public positions in an open world (a
 * public member, or any member of a class a subclass may extend) are refused.
 */
class PreferReadOnlyArrayCheckTest extends Test {

	private static inline final ID: String = 'prefer-read-only-array';
	private static inline final FILE: String = 'src/app/Panel.hx';
	private static inline final READ_ONLY: String = 'haxe.ds.ReadOnlyArray';
	private static final CLOSED: String = '{"rules": {"prefer-read-only-array": {"closedWorld": true}}}';
	private static final PANEL: String = 'package app;\n\nfinal class Panel {\n\tfinal items:Array<Item> = [];\n\n'
		+ '\tfunction draw(list:Array<Item>):Void {\n\t\tfor (i in list) paint(i);\n\t}\n\n'
		+ '\tpublic function all():Array<Item>\n\t\treturn items;\n\n\tfunction paint(i:Item):Void {}\n}\n';

	@:pin('control')
	@:killer('M-PROA-NO-FIX')
	public function testTheFieldTheParameterAndTheReturnTypeNothingMutatesBecomeReadOnly(): Void {
		Assert.same(['items', 'list', 'all'], reported([at(PANEL)], CLOSED));
		Assert.equals(PANEL.split('Array<Item>').join('$READ_ONLY<Item>'), fixed([at(PANEL)], CLOSED));
	}

	@:pin('guard')
	public function testTheMessageSaysTheTypeIsAViewAndNotACopy(): Void {
		final message: String = violations([at(PANEL)])[0].message;
		Assert.isTrue(message.contains('VIEW') && message.contains('not a copy') && message.contains('elements stay mutable'), message);
	}

	@:pin('control')
	@:killer('M-PROA-OPEN-WORLD')
	public function testAPublicPositionIsRefusedUnlessTheWorldIsClosed(): Void {
		Assert.same(['items', 'list'], reported([at(PANEL)]));
		Assert.same(['xs'], reported([
			at('package app;\n\nprivate class Hidden {\n\tpublic var xs:Array<Int> = [];\n}\n')
		]));
		final bag: SourceEntry = at('package app;\n\ntypedef Bag = { xs:Array<Int> }\n');
		Assert.same([], reported([bag]));
		Assert.same(['xs'], reported([bag], CLOSED));
	}

	@:pin('control')
	@:killer('M-PROA-SUBCLASS-REACH')
	public function testAMemberASubclassCanReachIsRefusedUnlessTheClassIsFinalOrTheWorldClosed(): Void {
		final body: String =
			' {\n\tvar items:Array<Int> = [];\n\n\tfunction draw(list:Array<Int>):Void {\n\t\ttrace(list.length + items.length);\n\t}\n}\n';
		final open: SourceEntry = at('package app;\n\nclass Base$body');
		Assert.same([], reported([open]));
		Assert.same(['items', 'list'], reported([open], CLOSED));
		Assert.same(['items', 'list'], reported([at('package app;\n\nfinal class Base$body')]));
		Assert.same(['items', 'list'], reported([at('package app;\n\n@:final class Base$body')]));
	}

	@:pin('guard')
	public function testAMemberDeclaredUnderIfIsNotJudged(): Void {
		final source: String = 'package app;\n\nfinal class Holder {\n\t#if js\n\tvar ys:Array<Int> = [];\n\t#end\n\n'
			+ '\tvar xs:Array<Int> = [];\n\n\tfunction f():Void {\n\t\ttrace(xs.length + ys.length);\n\t}\n}\n';
		Assert.same(['xs'], reported([at(source)], CLOSED));
	}

	@:pin('control')
	@:killer('M-PROA-IGNORE-MUTATIONS')
	public function testAMutationThroughTheNameKeepsTheArray(): Void {
		for (use in [
			'xs.push(1);',
			'this.xs.sort((a, b) -> a - b);',
			'(xs).splice(0, 1);',
			'xs[0] = 2;',
			'xs[0]++;',
			'xs.length = 0;',
			'trace(cast xs);',
			'trace(cast(xs, Array<Dynamic>));',
			'Reflect.setField(this, "xs", []);'
		]) Assert.same([], reported([holder(use)]), use);
		Assert.same(['xs'], reported([holder('trace(xs.indexOf(1) + xs.length);')]));
	}

	@:pin('control')
	@:killer('M-PROA-IGNORE-CALL-MUTATIONS')
	public function testAMutationOfWhatACallReturnsKeepsTheReturnType(): Void {
		final source: String = 'package app;\n\nfinal class Holder {\n\tvar xs:Array<Int> = [];\n\n'
			+ '\tfunction all():Array<Int>\n\t\treturn xs;\n\n\tfunction f():Void {\n\t\tall().push(1);\n\t}\n}\n';
		Assert.same(['xs'], reported([at(source)]));
	}

	@:pin('control')
	@:killer('M-PROA-RUN-WIDE-SCOPE')
	public function testAParameterIsJudgedInItsOwnFunction(): Void {
		final source: String = 'package app;\n\nfinal class Sink {\n\tfunction a(out:Array<Int>):Void {\n\t\tout.push(1);\n\t}\n\n'
			+ '\tfunction b(out:Array<Int>):Void {\n\t\ttrace(out.length);\n\t}\n}\n';
		final found: Array<Violation> = violations([at(source)]);
		Assert.same(['out'], found.map(nameOf));
		Assert.equals(source.lastIndexOf('Array<Int>'), found[0].span?.from);
	}

	@:pin('control')
	@:killer('M-PROA-UNPINNED')
	public function testExternKeptAndReflectedDeclarationsAreRefused(): Void {
		for (decl in [
			'extern final class E {\n\tvar xs:Array<Int>;\n}',
			'final class X {\n\textern var xs:Array<Int>;\n}',
			'@:keep final class K {\n\tvar xs:Array<Int> = [];\n}',
			'final class R {\n\t@:rtti var xs:Array<Int> = [];\n}'
		]) Assert.same([], reported([at('package app;\n\n$decl\n')]), decl);
	}

	@:pin('control')
	@:killer('M-PROA-NO-CONTRACT')
	public function testAnOverrideOrInterfaceSignatureIsRefusedAndItsLocalsAreNot(): Void {
		final source: String = 'package app;\n\ninterface Shape {\n\tfunction points(xs:Array<Int>):Void;\n}\n\nclass Base {\n'
			+ '\tfunction draw(xs:Array<Int>):Void {}\n}\n\nclass Sub extends Base {\n\toverride function draw(xs:Array<Int>):Void {\n'
			+ '\t\tfinal loc:Array<Int> = [1];\n\t\ttrace(loc);\n\t}\n}\n\nclass Impl implements Shape {\n'
			+ '\tpublic function points(xs:Array<Int>):Void {}\n}\n';
		Assert.same(['loc'], reported([at(source)], CLOSED));
	}

	@:pin('control')
	@:killer('M-PROA-UNVERIFIED-PASSES')
	public function testANameInConditionalCodeNoBuildCompilesIsRefused(): Void {
		Assert.same([], reported([holder('#if js\n\t\ttrace(xs);\n\t\t#end')]));
		Assert.same(['xs'], reported([holder('trace(xs);')]));
	}

	@:pin('control')
	@:killer('M-PROA-SOURCES-FIRST')
	public function testTheDeclarationsThatReceiveAValueAreEditedFirst(): Void {
		final edits: Array<FixEdit> = CheckFixture.fixRun(
			new PreferReadOnlyArray(), [at(PANEL)], null, null, _ -> LintConfig.parse(CLOSED)
		)
			.edits;
		Assert.same([PANEL.indexOf('list:') + 5, PANEL.indexOf('all():') + 6, PANEL.indexOf('items:') + 6], edits.map(e -> e.span.from));
	}

	@:pin('control')
	@:killer('M-PROA-ALWAYS-FULL-PATH')
	public function testAFileThatSeesTheShortNameGetsIt(): Void {
		final source: String = 'package app;\n\nimport haxe.ds.ReadOnlyArray;\n\nfinal class Holder {\n\tvar xs:Array<Int> = [];\n}\n';
		Assert.equals(source.replace('xs:Array<Int>', 'xs:ReadOnlyArray<Int>'), fixed([at(source)]));
	}

	@:pin('control')
	@:killer('M-PROA-SHORT-FUNCTION-TYPE')
	public function testATypedefFieldOfEitherFormButNotAFunctionType(): Void {
		final short: String = 'package app;\n\nprivate typedef Bag = { xs:Array<Int>, f:Array<Int>->Void, ?ys:Array<String> }\n';
		Assert.same(['xs', 'ys'], reported([at(short)]));
		Assert.equals(short.split('s:Array<').join('s:$READ_ONLY<'), fixed([at(short)]));
		Assert.same(['xs', 'ys'], reported([
			at('package app;\n\nprivate typedef Bag = {\n\tvar xs:Array<Int>;\n\tfinal ys:Array<Int>;\n}\n')
		]));
	}

	public function testRegisteredAndOffByDefault(): Void {
		Assert.notNull(Linter.byId(ID));
		final files: Array<SourceEntry> = [at(PANEL)];
		final off: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> LintConfig.parse('{}'), true);
		Assert.equals(0, off.filter(v -> v.rule == ID).length);
		final on: LintConfig = LintConfig.parse('{"rules": {"$ID": {"enabled": true}}}');
		Assert.equals(2, Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true).filter(v -> v.rule == ID).length);
	}

	public function testClosedWorldIsTheOnlyAcceptedKey(): Void {
		Assert.same(['closedWorld'], new PreferReadOnlyArray().acceptedOptions());
	}

	private function violations(files: Array<SourceEntry>, ?json: String): Array<Violation> {
		final config: Null<LintConfig> = json == null ? null : LintConfig.parse(json);
		final check: PreferReadOnlyArray = new PreferReadOnlyArray();
		if (config != null) check.setConfigResolver(_ -> config);
		return CheckFixture.violationsIn(check, files, null, config == null ? null : _ -> config);
	}

	/** The names of the declarations the check reports in `files`. */
	private function reported(files: Array<SourceEntry>, ?json: String): Array<String> {
		return violations(files, json).map(nameOf);
	}

	/** The source of the first file with every fix of the check applied. */
	private function fixed(files: Array<SourceEntry>, ?json: String): String {
		final config: Null<LintConfig> = json == null ? null : LintConfig.parse(json);
		final edits: Array<FixEdit> = CheckFixture.fixRun(
			new PreferReadOnlyArray(), files, null, null, config == null ? null : _ -> config
		)
			.edits;
		return CanonicalEdit.applyEdits(files[0].source, edits);
	}

	private static function nameOf(v: Violation): String {
		return v.message.split('\'')[1];
	}

	private static function at(source: String): SourceEntry {
		return { file: FILE, source: source };
	}

	/** A class whose array field `xs` the one method `f` uses through `body`. */
	private static function holder(body: String): SourceEntry {
		return at('package app;\n\nfinal class Holder {\n\tvar xs:Array<Int> = [];\n\n\tfunction f():Void {\n\t\t$body\n\t}\n}\n');
	}

}
