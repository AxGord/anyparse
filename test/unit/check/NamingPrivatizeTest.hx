package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle;
import anyparse.check.Naming;
import anyparse.check.NamingPrivatize;
import anyparse.check.NamingRenames.RenameRefusal;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.ImplicitReach;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import unit.CheckFixture;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `naming`'s PRIVATIZE arm (`NamingPrivatize`): a public `_x` that nothing outside its type and
 * subtypes reads is made `private` - its name kept - instead of being renamed to `x`; with an
 * outside reader the rename stays. The arm is a `RiskyArm`, so its edit is applied only through the
 * compiler oracle; the CLI fixtures at the end drive that path, the rest read the verdict off the
 * check directly.
 *
 * Every refusal fixture below is the CONTROL fixture with one thing added, so a refusal there is
 * about that one thing.
 */
@:nullSafety(Strict)
final class NamingPrivatizeTest extends Test {

	/** The declaring type: a public `_label` read only inside it. */
	private static final OWNER: String = 'package pkg;\n\nclass C {\n\tpublic final _label:Int = 1;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function read():Int {\n\t\treturn _label;\n\t}\n}\n';

	/** A sibling type that holds a `C` and never names the field. */
	private static final SILENT_USER: String =
		'package pkg;\n\nclass D {\n\tpublic function new() {}\n\n\tpublic function f(c:C):Int {\n\t\treturn c.read();\n\t}\n}\n';

	/** A sibling type that reads the field from outside. */
	private static final OUTSIDE_READER: String = 'package pkg;\nclass D {\n\tpublic function f(c:C):Int {\n\t\treturn c._label;\n\t}\n}\n';

	@:pin('control')
	@:killer('M-PRIVATIZE-NO-CANDIDATE', 'M-NAMING-PRIVATIZE-NOT-DECLINED', 'M-NAMING-RISKYFIX-EMPTY')
	public function testAPublicUnderscoreFieldReadOnlyInsideIsPrivatized(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: OWNER },
			{ file: 'pkg/D.hx', source: SILENT_USER }
		];
		final plugin: GrammarPlugin = scoped(files, []);
		final check: Naming = new Naming();
		final vs: Array<Violation> = findingsOnLabel(check, files, plugin);
		Assert.equals(1, vs.length);
		Assert.stringContains('nothing outside C reads it, so the fix makes it private', vs[0].message);
		Assert.equals(1, check.riskyArmFindings(vs).length, 'the finding belongs to the privatize arm');
		final edits: Array<{ span: anyparse.runtime.Span, text: String }> = check.riskyFix(OWNER, vs, plugin);
		Assert.equals(1, edits.length);
		Assert.equals('public', OWNER.substring(edits[0].span.from, edits[0].span.to), 'the edit replaces the `public` keyword');
		Assert.equals('private', edits[0].text);
		Assert.equals(0, check.crossFileFix(files, vs, plugin, CheckFixture.index(files, plugin)).length, 'the rename steps aside');
		Assert.equals(RenameRefusal.PRIVATIZE_ARM, vs[0].declineReason);
	}

	@:pin('control')
	@:killer('M-NAMING-RISKY-FINDINGS-ALL', 'M-PRIVATIZE-TOKENS-UNCHECKED')
	public function testAnOutsideReaderKeepsTheRename(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: OWNER },
			{ file: 'pkg/D.hx', source: OUTSIDE_READER }
		];
		final plugin: GrammarPlugin = scoped(files, []);
		final check: Naming = new Naming();
		final vs: Array<Violation> = findingsOnLabel(check, files, plugin);
		Assert.equals(1, vs.length);
		Assert.equals('camelCase public field: \'_label\'', vs[0].message, 'the message is the rename arm\'s, unchanged');
		Assert.equals(0, check.riskyArmFindings(vs).length);
		Assert.equals(1, check.crossFileFix(files, vs, plugin, CheckFixture.index(files, plugin)).length, 'the rename runs as before');
	}

	/** Haxe `private` is visible to a subclass, so a subtype's read keeps the arm. */
	@:pin('control')
	@:killer('M-PRIVATIZE-NO-SUBTYPE-REGION')
	public function testASubtypeReaderStillPrivatizes(): Void {
		final sub: String = 'package pkg;\nclass D extends C {\n\tpublic function f():Int {\n\t\treturn _label + this._label;\n\t}\n}\n';
		Assert.isTrue(privatizes([{ file: 'pkg/C.hx', source: OWNER }, { file: 'pkg/D.hx', source: sub }], []));
	}

	/**
	 * An `@:autoBuild` ANCESTOR generates INTO this type, where a private member stays visible, so it
	 * does not refuse the arm - every display class of an openfl project has one (`Sprite`). The type's
	 * OWN `@:build` still refuses (see `testEachGateRefusesTheArm`).
	 */
	@:pin('control')
	@:killer('M-PRIVATIZE-AUTOBUILD-COUNTS')
	public function testAnAutoBuildAncestorDoesNotRefuse(): Void {
		final base: String = 'package pkg;\n@:autoBuild(pkg.Macro.build())\nclass B {\n\tpublic function new() {}\n}\n';
		final owner: String = OWNER.replace('class C {', 'class C extends B {')
			.replace('public function new() {}', 'public function new() {\n\t\tsuper();\n\t}');
		Assert.isTrue(privatizes([{ file: 'pkg/C.hx', source: owner }, { file: 'pkg/B.hx', source: base }], []));
	}

	/**
	 * The lint-fix-scope incident shape: the outside reader sits in a project file the run does not
	 * lint. The declared scope's token map still sees it, so the narrowed run refuses exactly as the
	 * whole-project one does.
	 */
	@:pin('control')
	@:killer('M-PRIVATIZE-TOKENS-UNCHECKED')
	public function testANarrowedRunSeesAReaderOutsideItsScope(): Void {
		Assert.isFalse(privatizes([{ file: 'pkg/C.hx', source: OWNER }], [{ file: 'pkg/D.hx', source: OUTSIDE_READER }]));
		Assert.isTrue(privatizes([{ file: 'pkg/C.hx', source: OWNER }], [{ file: 'pkg/D.hx', source: SILENT_USER }]), 'control');
	}

	/**
	 * Without a DECLARED resolution scope the only evidence is the report set, which a narrowed run
	 * narrows, so the arm stays off and the finding keeps the rename it always had.
	 */
	@:pin('control')
	@:killer('M-PRIVATIZE-INCOMPLETE-PROJECT')
	public function testNoDeclaredScopeLeavesTheRename(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: OWNER },
			{ file: 'pkg/D.hx', source: SILENT_USER }
		];
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final check: Naming = new Naming();
		final vs: Array<Violation> = findingsOnLabel(check, files, plugin);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.riskyArmFindings(vs).length);
		Assert.equals(1, check.crossFileFix(files, vs, plugin, CheckFixture.index(files, plugin)).length);
		// A declared scope one of whose roots matched nothing is not the whole project either.
		final partial: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		partial.setResolutionScope({
			declared: true,
			sources: () -> {
				report: files,
				projectRoots: [],
				library: new LibrarySources([]),
				rootsMatched: true,
				rootsAllMatched: false
			}
		});
		final again: Naming = new Naming();
		Assert.equals(0, again.riskyArmFindings(findingsOnLabel(again, files, partial)).length, 'a root matched nothing');
	}

	/** Each gate, alone on the control fixture, refuses the arm. */
	@:pin('control')
	@:killer('M-PRIVATIZE-UNCERTAIN-RUN', 'M-PRIVATIZE-TYPE-REACH', 'M-PRIVATIZE-CHAIN', 'M-PRIVATIZE-ACCESS-GRANT',
		'M-PRIVATIZE-FRAGMENT', 'M-PRIVATIZE-TOKENS-UNCHECKED')
	public function testEachGateRefusesTheArm(): Void {
		final user: { file: String, source: String } = { file: 'pkg/D.hx', source: SILENT_USER };
		final refusals: Array<{ what: String, files: Array<{ file: String, source: String }> }> = [
			{
				what: 'metadata on the member',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('\tpublic final _label', '\t@:keep public final _label') },
					user
				]
			},
			{
				what: '@:keep on the type',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('class C {', '@:keep\nclass C {') },
					user
				]
			},
			{
				what: '@:build on the type',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('class C {', '@:build(pkg.M.b())\nclass C {') },
					user
				]
			},
			{
				what: 'an RTTI type',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('class C {', '@:rtti\nclass C {') },
					user
				]
			},
			{
				what: 'an unresolved supertype',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('class C {', 'class C extends Missing {') },
					user
				]
			},
			{
				what: 'an interface declaring the name',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('class C {', 'class C implements I {') },
					{ file: 'pkg/I.hx', source: 'package pkg;\ninterface I {\n\tfinal _label:Int;\n}\n' },
					user
				]
			},
			{
				what: 'an @:access grant naming the type',
				files: [
					{ file: 'pkg/C.hx', source: OWNER },
					{ file: 'pkg/D.hx', source: SILENT_USER.replace('class D {', '@:access(pkg.C)\nclass D {') }
				]
			},
			{
				what: 'a structure that spells the field',
				files: [
					{ file: 'pkg/C.hx', source: OWNER },
					{ file: 'pkg/D.hx', source: '${SILENT_USER}typedef S = {\n\tfinal _label:Int;\n};\n' }
				]
			},
			{
				what: 'an interpolation fragment that may spell the name',
				files: [
					{ file: 'pkg/C.hx', source: OWNER },
					{
						file: 'pkg/D.hx',
						source: 'package pkg;\nclass D {\n\tpublic function f(c:C, s:String):Dynamic {\n'
							+ '\t\treturn Reflect.field(c, \'_lab$$s\');\n\t}\n}\n'
					}
				]
			},
			{
				what: 'a comment outside the type',
				files: [
					{ file: 'pkg/C.hx', source: OWNER },
					{ file: 'pkg/D.hx', source: '// _label\n$SILENT_USER' }
				]
			},
			{
				what: 'metadata only some builds see',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('\tpublic final _label', '\t#if js @:keep #end public final _label') },
					user
				]
			},
			{
				what: 'a modifier only some builds see',
				files: [
					{ file: 'pkg/C.hx', source: OWNER.replace('\tpublic final _label', '\t#if js inline #end public final _label') },
					user
				]
			},
			{
				what: 'an inherited RTTI hierarchy',
				files: [
					{
						file: 'pkg/C.hx',
						source: OWNER.replace('class C {', 'class C extends B {')
							.replace('public function new() {}', 'public function new() {\n\t\tsuper();\n\t}')
					},
					{ file: 'pkg/B.hx', source: 'package pkg;\n@:rtti\nclass B {\n\tpublic function new() {}\n}\n' },
					user
				]
			}
		];
		for (r in refusals) Assert.isFalse(privatizes(r.files, []), r.what);
	}

	/** A finding the arm cannot fix is not a candidate: the name the PRIVATE rule would govern must pass it. */
	@:pin('control')
	@:killer('M-PRIVATIZE-RULE-UNCHECKED')
	public function testANameThePrivateRuleRejectsIsNotACandidate(): Void {
		final upper: String = OWNER.replace('_label', '_Label');
		Assert.isFalse(privatizes([{ file: 'pkg/C.hx', source: upper }, { file: 'pkg/D.hx', source: SILENT_USER }], [], '_Label'));
		final staticField: String = OWNER.replace('public final _label:Int = 1;', 'public static var _label:Int = 1;');
		Assert.isFalse(privatizes([
			{ file: 'pkg/C.hx', source: staticField },
			{ file: 'pkg/D.hx', source: SILENT_USER }
		], []), 'static');
	}

	/**
	 * The candidate test, asked directly under a policy PERMISSIVE enough that the private rule
	 * accepts every spelling below - so each refusal is the positive list's own gate, not the rule's.
	 */
	@:pin('control')
	@:killer('M-PRIVATIZE-METHOD-CANDIDATE', 'M-PRIVATIZE-NO-UNDERSCORE', 'M-PRIVATIZE-NOT-PUBLIC', 'M-PRIVATIZE-NO-OWNER',
		'M-PRIVATIZE-IMPLICIT-REACH', 'M-PRIVATIZE-RENAME-UNSAFE')
	public function testTheCandidateTestIsAPositiveList(): Void {
		final permissive: NamingPolicy = [
			{
				category: NamingCategory.Field,
				requireMods: [],
				forbidMods: ['public'],
				format: new EReg('^_?[a-z][a-zA-Z0-9]*$', ''),
				label: 'f'
			},
			{
				category: NamingCategory.Method,
				requireMods: [],
				forbidMods: [],
				format: new EReg('^_?[a-z][a-zA-Z0-9]*$', ''),
				label: 'm'
			}
		];
		final field: NamedDecl = {
			span: null,
			name: '_label',
			category: NamingCategory.Field,
			mods: ['public'],
			enclosingType: 'C'
		};
		Assert.isTrue(NamingPrivatize.isCandidate(field, permissive), 'control');
		Assert.isTrue(NamingPrivatize.isCandidate(field, HaxeNamingSupport.defaults()), 'control under the built-in policy');
		final refused: Array<{ what: String, decl: NamedDecl }> = [
			{
				what: 'a method',
				decl: {
					span: null,
					name: '_label',
					category: NamingCategory.Method,
					mods: ['public'],
					enclosingType: 'C'
				}
			},
			{
				what: 'no underscore',
				decl: {
					span: null,
					name: 'label',
					category: NamingCategory.Field,
					mods: ['public'],
					enclosingType: 'C'
				}
			},
			{
				what: 'not public',
				decl: {
					span: null,
					name: '_label',
					category: NamingCategory.Field,
					mods: [],
					enclosingType: 'C'
				}
			},
			{
				what: 'no enclosing type',
				decl: {
					span: null,
					name: '_label',
					category: NamingCategory.Field,
					mods: ['public'],
					enclosingType: null
				}
			},
			{
				what: 'implicitly reached',
				decl: {
					span: null,
					name: '_label',
					category: NamingCategory.Field,
					mods: ['public'],
					enclosingType: 'C',
					implicitReach: ImplicitReach.Annotation
				}
			},
			{
				what: 'rename-unsafe',
				decl: {
					span: null,
					name: '_label',
					category: NamingCategory.Field,
					mods: ['public'],
					enclosingType: 'C',
					renameUnsafe: true
				}
			}
		];
		for (r in refused) Assert.isFalse(NamingPrivatize.isCandidate(r.decl, permissive), r.what);
	}

	/**
	 * End to end through `lint --fix` with a compiler oracle: the field turns private and keeps its name.
	 * On the engine before the arm the same command renamed it to `label`.
	 */
	@:pin('control')
	@:killer('M-RISKYARM-NOT-VERIFIED', 'M-FIXVERIFY-RISKYARM-FIX')
	public function testTheOracleRunPrivatizes(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeProject('{"compilerOracle":"check.hxml","resolutionRoots":["."]}');
		Cli.run(['lint', '--fix', '--rule', 'naming', '$dir/pkg']);
		final onDisk: String = File.getContent('$dir/pkg/C.hx');
		CliFixture.removeDir(dir);
		Assert.stringContains('private final _label:Int = 1;', onDisk);
		Assert.isFalse(onDisk.contains('final label'), 'not renamed');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Without an oracle the arm is report-only: nothing is written, and the rename does not take its place. */
	public function testWithoutAnOracleTheArmIsReportOnly(): Void {
		#if (sys || nodejs)
		final dir: String = writeProject('{"resolutionRoots":["."]}');
		Cli.run(['lint', '--fix', '--rule', 'naming', '$dir/pkg']);
		final onDisk: String = File.getContent('$dir/pkg/C.hx');
		CliFixture.removeDir(dir);
		Assert.equals(OWNER, onDisk);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Whether `naming` over `report` (with `roots` as unlinted project files) gives the `name` finding to the privatize arm. */
	private function privatizes(
		report: Array<{ file: String, source: String }>, roots: Array<{ file: String, source: String }>, name: String = '_label'
	): Bool {
		final check: Naming = new Naming();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, report, scoped(report, roots))
			.filter(v -> v.message.contains('\'$name\''));
		return check.riskyArmFindings(vs).length > 0;
	}

	/** `naming`'s findings on `_label` over `files`. */
	private function findingsOnLabel(
		check: Naming, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Array<Violation> {
		return CheckFixture.violationsIn(check, files, plugin).filter(v -> v.message.contains('\'_label\''));
	}

	/** A run host indexing the whole project: a declared scope, every root matched, `roots` its files outside `report`. */
	private function scoped(
		report: Array<{ file: String, source: String }>, roots: Array<{ file: String, source: String }>
	): GrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: roots,
				library: new LibrarySources(roots),
				rootsMatched: true,
				rootsAllMatched: true
			}
		});
		return plugin;
	}

	#if (sys || nodejs)
	/** A project directory: `pkg/C.hx`, `pkg/D.hx`, a `Main` the oracle compiles, and `config` as its `apqlint.json`. */
	private function writeProject(config: String): String {
		final dir: String = CliFixture.writeDir('privatize', [
			{ name: 'apqlint.json', source: config },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' }
		]);
		sys.FileSystem.createDirectory('$dir/pkg');
		File.saveContent('$dir/pkg/C.hx', OWNER);
		File.saveContent('$dir/pkg/D.hx', SILENT_USER);
		File.saveContent('$dir/Main.hx', 'class Main {\n\tstatic function main() {\n\t\ttrace(new pkg.D().f(new pkg.C()));\n\t}\n}\n');
		return dir;
	}

	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('privatizeoracle', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {}\n}\n' },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' }
		]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
