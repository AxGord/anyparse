package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.OwnedTypes;
import anyparse.check.OwnedTypesDeclaration.TypeOwnership;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `owned-types` check: a mention of a declared type, or a read or call of a declared member, outside the code the
 * `ownedTypes` declaration names as its owner. Each position a type can be written in, each way a member is reached,
 * each owner form, and the resolution verdicts that decide what a written name means, is pinned by its own fixture.
 */
class OwnedTypesCheckTest extends Test {

	private static final OWNED: String = 'package a;\n\nclass Owned {\n\tpublic static function make(): Owned {\n'
		+ '\t\treturn new Owned();\n\t}\n\n\tpublic function new() {}\n\n\tpublic function run(): Void {}\n}\n';
	private static final SUB: String = 'package a;\n\nclass Sub extends Owned {}\n';
	private static final OTHER: String = 'package other;\n\nclass Owned {\n\tpublic static function make(): Owned {\n'
		+ '\t\treturn new Owned();\n\t}\n\n\tpublic function new() {}\n\n\tpublic function run(): Void {}\n}\n';
	private static final INSIDER: String = 'package own;\n\nimport a.Owned;\n\nclass Insider {\n\tvar f: Owned;\n}\n';
	private static final DEEPER: String = 'package own.deep;\n\nimport a.Owned;\n\nclass Deeper {\n\tvar f: Owned;\n}\n';
	private static final TYPE_CONFIG: String = '{"ownedTypes":[{"types":["a.Owned"],"owners":["own.**"],"why":"the a layer owns it"}]}';
	private static final ALL_CONFIG: String = '{"ownedTypes":[{"types":["a.Owned"],"members":["a.Owned.make","a.Owned.run",'
		+ '"a.Owned.new"],"owners":["own.**"],"why":"the a layer owns it"}]}';

	public function testEveryTypePositionIsReported(): Void {
		final user: String = 'package b;\n\nimport a.Owned;\n\nclass User {\n\tvar f: Owned;\n\tvar g: Array<Owned>;\n\n'
			+ '\tfunction m(p: Owned): Owned {\n\t\tfinal l: Owned = new Owned();\n\t\tfinal c: Dynamic = cast(p, Owned);\n'
			+ '\t\tfinal i: Bool = p is Owned;\n\t\tfinal s: Owned = Owned.make();\n\t\tfinal q: Dynamic = a.Owned.make();\n'
			+ '\t\treturn l;\n\t}\n}\n';
		Assert.same([3, 6, 7, 9, 9, 10, 10, 11, 12, 13, 13, 14], linesIn(user, TYPE_CONFIG));
	}

	/** The message names the owned path, its owners and the declared reason; the finding is a warning. */
	public function testTheMessageNamesTheOwnersAndTheReason(): Void {
		final user: String = 'package b;\n\nclass User {\n\tvar f: a.Owned;\n}\n';
		final vs: Array<Violation> = violationsOf(user, TYPE_CONFIG);
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals('owned-types', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('a.Owned belongs to own.** — the a layer owns it', vs[0].message);
	}

	@:pin('control') @:killer('M-OWNED-IMPORTS-IGNORED') @:killer('M-OWNED-ALIAS-IGNORED')
	public function testAnImportAndAnAliasAreMentions(): Void {
		final user: String = 'package b;\n\nimport a.Owned as Alias;\n\nclass User {\n\tvar f: Alias;\n}\n';
		Assert.same([3, 6], linesIn(user, TYPE_CONFIG));
	}

	/** `a.Owned.make` is a field import: the owned type is its parent path. */
	public function testAFieldImportMentionsItsType(): Void {
		Assert.same([3], linesIn('package b;\n\nimport a.Owned.make;\n\nclass User {}\n', TYPE_CONFIG));
	}

	@:pin('control') @:killer('M-OWNED-QUALIFIED-EXPR-IGNORED')
	public function testAQualifiedExpressionIsAMention(): Void {
		final user: String = 'package b;\n\nclass User {\n\tfunction m(): Void {\n\t\ta.Owned.make();\n\t}\n}\n';
		Assert.same([5], linesIn(user, TYPE_CONFIG));
	}

	@:pin('control') @:killer('M-OWNED-BOUND-BY-NAME')
	public function testASameNamedTypeOfAnotherPackageIsNotReported(): Void {
		final user: String = 'package b;\n\nimport other.Owned;\n\nclass User {\n\tvar f: Owned;\n\n'
			+ '\tfunction m(o: Owned): Void {\n\t\tOwned.make();\n\t\tnew Owned();\n\t\to.run();\n\t}\n}\n';
		Assert.same([], linesIn(user, ALL_CONFIG));
	}

	/** An import of a module the index does not hold may bind the name: both the import and the use are reported. */
	@:pin('control') @:killer('M-OWNED-UNKNOWN-SILENT')
	public function testAnUnresolvableMentionIsReported(): Void {
		final user: String = 'package b;\n\nimport gone.Owned;\n\nclass User {\n\tvar f: Owned;\n}\n';
		Assert.same([3, 6], linesIn(user, TYPE_CONFIG));
	}

	/** No resolution tier binds the name, so only a built-in could: it is not the owned type. */
	@:pin('control') @:killer('M-OWNED-FREE-REPORTED')
	public function testANameNoTierBindsIsNotReported(): Void {
		Assert.same([], linesIn('package b;\n\nclass User {\n\tvar f: Owned;\n}\n', TYPE_CONFIG));
	}

	@:pin('control') @:killer('M-OWNED-VALUE-IS-TYPE')
	public function testAValueNamedLikeTheTypeIsNotReported(): Void {
		final user: String = 'package b;\n\nimport a.Owned;\n\nclass User {\n\tfunction m(Owned: Int): Void {\n\t\ttrace(Owned);\n\t}\n}\n';
		Assert.same([3], linesIn(user, TYPE_CONFIG));
	}

	/** `own.**` reaches every package under `own`; `own.*` only its direct modules. */
	@:pin('control') @:killer('M-OWNED-OWNERS-IGNORED')
	public function testOwnersArePackageGlobs(): Void {
		final deep: Array<{ file: String, source: String }> = [
			{ file: 'own/Insider.hx', source: INSIDER },
			{ file: 'own/deep/Deeper.hx', source: DEEPER }
		];
		Assert.same([], filesUnder('own/', deep, TYPE_CONFIG));
		Assert.same(['own/deep/Deeper.hx', 'own/deep/Deeper.hx'], filesUnder('own/', deep, TYPE_CONFIG.replace('own.**', 'own.*')));
	}

	/** An owner naming a sub-type owns that type's body, not the module's main type beside it. */
	@:pin('control') @:killer('M-OWNED-ENCLOSING-TYPE')
	public function testAnOwnerTypeOwnsItsOwnBody(): Void {
		final user: String = 'package b;\n\nimport a.Owned;\n\nclass User {\n\tvar f: Owned;\n}\n\nclass Inner {\n\tvar g: Owned;\n}\n';
		Assert.same([3, 6], linesIn(user, TYPE_CONFIG.replace('own.**', 'b.User.Inner')));
	}

	@:pin('control') @:killer('M-OWNED-DECLARING-MODULE')
	public function testTheDeclaringModuleOwnsItsType(): Void {
		Assert.same([], filesUnder('a/Owned', [], ALL_CONFIG));
	}

	public function testConditionalBranchesAreMentions(): Void {
		final user: String = 'package b;\n\n#if js\nimport a.Owned;\n#end\n\nclass User {\n\t#if js\n\tvar f: Owned;\n\t#else\n'
			+ '\tvar g: Array<Owned>;\n\t#end\n}\n';
		Assert.same([4, 9, 11], linesIn(user, TYPE_CONFIG));
	}

	/** A static is reached through its own type, plain or qualified — never through a value, nor a subtype, which Haxe rejects. */
	@:pin('control') @:killer('M-OWNED-STATIC-THROUGH-SUBTYPE')
	public function testAStaticMemberIsReachedThroughItsType(): Void {
		final user: String = 'package b;\n\nimport a.Owned;\nimport a.Sub;\n\nclass User {\n\tfunction m(o: Owned): Void {\n\t\tOwned.make();\n'
			+ '\t\ta.Owned.make();\n\t\to.make();\n\t\tSub.make();\n\t}\n}\n';
		Assert.same([8, 9], linesIn(user, memberConfig('a.Owned.make')));
	}

	/** An instance member is reached through a receiver the shared typer types — a subtype included — and only there. */
	@:pin('control') @:killer('M-OWNED-NO-SUPERTYPE-WALK')
	public function testAnInstanceMemberIsReachedThroughATypedReceiver(): Void {
		final user: String = 'package b;\n\nimport a.Owned;\nimport a.Sub;\n\nclass User {\n'
			+ '\tfunction m(o: Owned, s: Sub, d: Dynamic): Void {\n\t\to.run();\n\t\ts.run();\n\t\td.run();\n\t}\n}\n';
		Assert.same([8, 9], linesIn(user, memberConfig('a.Owned.run')));
	}

	/** A receiver whose meaning is unknown reaches a static by name; an instance member is never matched by name alone. */
	@:pin('control') @:killer('M-OWNED-STATIC-UNKNOWN-SILENT') @:killer('M-OWNED-UNKNOWN-SILENT') @:killer('M-OWNED-INSTANCE-BY-NAME')
	public function testAnUnknownReceiverIsReportedForAStaticOnly(): Void {
		final user: String =
			'package b;\n\nimport gone.Thing;\n\nclass User {\n\tfunction m(): Void {\n\t\tThing.make();\n\t\tThing.run();\n\t}\n}\n';
		Assert.same([7], linesIn(user, memberConfig('a.Owned.make", "a.Owned.run')));
	}

	@:pin('control') @:killer('M-OWNED-CTOR-ANY-TYPE')
	public function testConstructionIsTheNewMember(): Void {
		final user: String = 'package b;\n\nimport a.Owned;\n\nclass User {\n\tfunction m(): Void {\n\t\tnew Owned();\n'
			+ '\t\tnew other.Owned();\n\t\tnew a.Owned();\n\t}\n}\n';
		Assert.same([7, 9], linesIn(user, memberConfig('a.Owned.new')));
	}

	@:pin('control') @:killer('M-OWNED-SKIP-REASON-NULL')
	public function testNoDeclarationIsInert(): Void {
		Assert.same([], linesIn('package b;\n\nimport a.Owned;\n\nclass User {}\n', '{}'));
		Assert.equals('needs-config', new OwnedTypes().skipReason('b/User.hx', LintConfig.parse('{}')));
		Assert.isNull(new OwnedTypes().skipReason('b/User.hx', LintConfig.parse(TYPE_CONFIG)));
	}

	/** Every entry the reader cannot keep, and every value it ignores, says so. */
	@:pin('control') @:killer('M-OWNED-READER-NO-OWNERS') @:killer('M-OWNED-PARSE')
	public function testTheReaderNamesEveryDrop(): Void {
		final config: LintConfig = LintConfig.parse(
			'{"ownedTypes":[1,{"types":["a.T"],"why":"w"},{"owners":["o"],"why":"w"},{"types":["a.T"],"owners":["o"]},'
			+ '{"types":["a.T"],"members":["nodot",2],"owners":["o"],"why":"w","extra":true},{"types":"a.T","owners":["o"],"why":"w"}]}'
		);
		Assert.same([
			'ownedTypes[0] is not an object — dropped',
			'ownedTypes[1] declares no "owners" — dropped',
			'ownedTypes[2] declares neither "types" nor "members" — dropped',
			'ownedTypes[3] declares no "why" — dropped',
			'ownedTypes[4] "members" ignored 1 value(s) that are not strings',
			'ownedTypes[4] declares unknown key "extra" — ignored',
			'ownedTypes[4] member "nodot" is not a Type.member path — ignored',
			'ownedTypes[5] "types" is not an array of strings — ignored',
			'ownedTypes[5] declares neither "types" nor "members" — dropped'
		], config.drops());
		final kept: Array<TypeOwnership> = config.ownedTypes();
		Assert.equals(1, kept.length);
		Assert.same(['a.T'], kept[0].types);
		Assert.same([], kept[0].members);
		Assert.same(['o'], kept[0].owners);
	}

	/** An empty list declares nothing, and a reason is kept without its surrounding blanks. */
	public function testAnEmptyListDeclaresNothingAndTheReasonIsTrimmed(): Void {
		Assert.same([], LintConfig.parse('{"ownedTypes":[]}').ownedTypes());
		Assert.equals('w', LintConfig.parse('{"ownedTypes":[{"types":["a.T"],"owners":["o"],"why":" w "}]}').ownedTypes()[0].why);
	}

	/** The fixture project — the owned type, a subtype of it, a same-named type elsewhere — plus `extra`. */
	private static function project(extra: Array<{ file: String, source: String }>): Array<{ file: String, source: String }> {
		return [
			{ file: 'a/Owned.hx', source: OWNED },
			{ file: 'a/Sub.hx', source: SUB },
			{ file: 'other/Owned.hx', source: OTHER }
		].concat(extra);
	}

	private static function memberConfig(members: String): String {
		return '{"ownedTypes":[{"members":["$members"],"owners":["own.**"],"why":"w"}]}';
	}

	/** Every finding of the rule over the fixture project plus `extra`, under `config`, through the linter's own gates. */
	private static function collected(extra: Array<{ file: String, source: String }>, config: String): Array<Violation> {
		final parsed: LintConfig = LintConfig.parse(config);
		final resolve: (String) -> LintConfig = _ -> parsed;
		final rule: OwnedTypes = new OwnedTypes();
		rule.setConfigResolver(resolve);
		return Linter.collect(project(extra), new HaxeQueryPlugin(), [rule], resolve);
	}

	private static function violationsOf(user: String, config: String): Array<Violation> {
		return collected([{ file: 'b/User.hx', source: user }], config).filter(v -> v.file == 'b/User.hx');
	}

	/** The 1-based line of every finding in `user`, in report order. */
	private static function linesIn(user: String, config: String): Array<Int> {
		return [for (v in violationsOf(user, config)) lineOf(user, v.span?.from ?? 0)];
	}

	private static function lineOf(source: String, offset: Int): Int {
		return source.substr(0, offset).split('\n').length;
	}

	private static function filesOf(vs: Array<Violation>): Array<String> {
		return [for (v in vs) v.file];
	}

	/** The file of every finding over the fixture project plus `extra` whose path starts with `prefix`. */
	private static function filesUnder(prefix: String, extra: Array<{ file: String, source: String }>, config: String): Array<String> {
		return filesOf(collected(extra, config)).filter(f -> f.startsWith(prefix));
	}

	private static function messages(vs: Array<Violation>): String {
		return [for (v in vs) '${v.file} ${v.message}'].join('\n');
	}

}
