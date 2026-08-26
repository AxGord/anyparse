package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.PreferStaticExtension;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-static-extension` check: a static utility call on a configured
 * module (`Ext.deco(w, 1)`) is flagged `Info` and rewritten to extension style
 * (`w.deco(1)`), with a `using Ext;` inserted when the file lacks one. The
 * soundness gates — instance / supertype member SHADOWING, an unresolvable
 * member closure, an unresolved or `Dynamic` receiver, a conflicting second
 * `using`, a value-shadowed type name, and a comment in a dropped region — are
 * each pinned by their own fixture.
 */
class PreferStaticExtensionCheckTest extends Test {

	/** The project-local static-utility fixture the receiver / arity gates resolve through. */
	private static inline final EXT_SOURCE: String =
		'class Ext {\n\tpublic static function deco(w: Widget, n: Int): Widget return w;\n\n\tpublic static function pad(w: Widget, a: Int, b: Int): Widget return w;\n\n\tpublic static function now(): Int return 0;\n}\n';

	/** A `Widget` with no members of its own — every extension name is provably absent from it. */
	private static inline final WIDGET_SOURCE: String = 'class Widget {}\n';

	/** The default injected config: `Ext` is the one static-extension module. */
	private static inline final EXT_CONFIG: String = '{"rules": {"prefer-static-extension": {"types": ["Ext"]}}}';

	/** The `StringTools`-only config, for the known-extension-table gate. */
	private static inline final STRINGTOOLS_CONFIG: String = '{"rules": {"prefer-static-extension": {"types": ["StringTools"]}}}';

	/** A config declaring no rule options at all — the `types` / `addUsing` defaults then apply. */
	private static inline final EMPTY_CONFIG: String = '{"rules": {}}';

	/** A `String`-receiver static utility, for the tabled-static-call iterable fixtures. */
	private static inline final STREXT_SOURCE: String =
		'class StrExt {\n\tpublic static function deco(s: String, n: Int): String return s;\n}\n';

	/** The `StrExt`-only config, paired with `strExtFiles`. */
	private static inline final STREXT_CONFIG: String = '{"rules": {"prefer-static-extension": {"types": ["StrExt"]}}}';

	public function testFixableRewriteWithUsingPresent(): Void {
		final vs: Array<Violation> = violationsOf(fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);')));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-static-extension', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('w.deco(1)') != -1);
		final out: String = fixResultOf(fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);')));
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('Ext.deco(') == -1, out);
	}

	public function testFixInsertsUsingAfterImports(): Void {
		final out: String = fixResultOf(importingFiles());
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
		Assert.isTrue(out.indexOf('import sub.Widget;') < out.indexOf('using Ext;'), out);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
	}

	public function testFixInsertsUsingInsideConditionalWrapper(): Void {
		// The whole module body is guarded by one `#if`, so the import run — and every call the
		// rewrite touches — lives inside it. The insert belongs with those imports, not above the
		// `#if` on its own island between `package` and the guard.
		final out: String = fixResultOf(conditionalFiles());
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
		Assert.isTrue(out.indexOf('#if FLAG') < out.indexOf('using Ext;'), out);
		Assert.isTrue(out.indexOf('import sub.Widget;') < out.indexOf('using Ext;'), out);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
	}

	public function testGuardedUsingSuppressesInsert(): Void {
		// A `using` inside the guard is in scope for the guarded code, so a second one is pure
		// noise — the presence test has to see through the `#if` the same way the insert does.
		final out: String = fixResultOf(conditionalFiles('using Ext;\n\n'));
		Assert.equals(out.indexOf('using Ext;'), out.lastIndexOf('using Ext;'));
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
	}

	public function testAddUsingFalseReportsButDoesNotFix(): Void {
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["Ext"], "addUsing": false}}}';
		Assert.equals(1, violationsOf(importingFiles(), config).length);
		Assert.equals(0, editsOf(importingFiles(), config).length);
	}

	public function testInstanceShadowNotFlagged(): Void {
		// Haxe gives an instance member priority over an extension, so the rewrite would
		// silently dispatch elsewhere — the heart of the rule.
		Assert.equals(
			0,
			violationsOf(fileSet(
				user('using Ext;\n\n', 'Ext.deco(w, 1);'), 'class Widget {\n\tpublic function deco(n: Int): Widget return this;\n}\n'
			)).length
		);
	}

	public function testSupertypeShadowNotFlagged(): Void {
		Assert.equals(
			0,
			violationsOf(fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);'), 'class Widget extends Base {}\n', [
				{ file: 'Base.hx', source: 'class Base {\n\tpublic function deco(n: Int): Widget return this;\n}\n' }
			])).length
		);
	}

	/**
	 * A supertype whose SIMPLE name is shared by another package resolves through the referring
	 * file's imports, so the receiver's closure is provable and the rewrite lands — the same
	 * collision used to degrade every such site to report-only.
	 */
	public function testAmbiguousSimpleSupertypeNameStillFixable(): Void {
		final files: Array<{ file: String, source: String }> =
			fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);'), 'import a.Base;\n\nclass Widget extends Base {}\n', [
				{ file: 'a/Base.hx', source: 'package a;\nclass Base {}\n' },
				{ file: 'b/Base.hx', source: 'package b;\nclass Base {}\n' }
			]);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('Ext.deco(') == -1, out);
	}

	/**
	 * A `Reflect.field` receiver is `Dynamic`, and an extension dispatches no method on a
	 * `Dynamic` value at runtime — so the site is DROPPED, not reported as unresolvable. Without
	 * the `Reflect.field` entry in `staticMethodReturns` the receiver read as untyped and the
	 * check emitted a report-only "verify the receiver type" advisory instead.
	 */
	public function testDynamicReflectFieldReceiverNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = fileSet(user('using Ext;\n\n', 'Ext.deco(Reflect.field(o, name), 1);'));
		Assert.equals(0, violationsOf(files).length);
	}

	public function testUnresolvableClosureReportedOnly(): Void {
		final files: Array<{ file: String, source: String }> = fileSet(
			user('using Ext;\n\n', 'Ext.deco(w, 1);'), 'class Widget extends Unknown {}\n'
		);
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('verify the receiver type declares no same-name member') != -1, vs[0].message);
		Assert.equals(0, editsOf(files).length);
	}

	/**
	 * An UNQUALIFIED call resolves too: a bare `make()` whose name binds to the enclosing type's own
	 * method has that method's declared return type (`NominalTypes.unqualifiedCallNominal`).
	 */
	public function testUnqualifiedCallReceiverResolves(): Void {
		final source: String = 'using Ext;\n\nclass C {\n\tfunction make():Widget\n\t\treturn null;\n\n\tfunction f():Void {\n'
			+ '\t\tExt.deco(make(), 1);\n\t}\n}\n';
		final vs: Array<Violation> = violationsOf(fileSet(source));
		Assert.equals(1, vs.length);
		Assert.equals(-1, vs[0].message.indexOf('receiver type unresolved'), vs[0].message);
		Assert.isTrue(fixResultOf(fileSet(source)).indexOf('make().deco(1);') != -1, 'expected the rewrite');
	}

	/**
	 * The same shape whose callee binds to a LOCAL instead — a stored closure, whose return type no
	 * index can name, so the receiver stays unresolved and the site report-only.
	 */
	public function testLocalClosureReceiverReportedOnly(): Void {
		final source: String =
			'using Ext;\n\nclass C {\n\tfunction f():Void {\n\t\tfinal make = () -> new Widget();\n\t\tExt.deco(make(), 1);\n\t}\n}\n';
		assertUnresolvedReceiver(fileSet(source));
	}

	public function testDynamicReceiverNotFlagged(): Void {
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(d:Dynamic):Void {\n\t\tExt.deco(d, 1);\n\t}\n}\n';
		Assert.equals(0, violationsOf(fileSet(source)).length);
	}

	public function testConflictingUsingNotFlagged(): Void {
		Assert.equals(
			0,
			violationsOf(fileSet(user('using Ext;\nusing Other;\n\n', 'Ext.deco(w, 1);'), WIDGET_SOURCE, [
				{ file: 'Other.hx', source: 'class Other {\n\tpublic static function deco(w: Widget, n: Int): Widget return w;\n}\n' }
			])).length
		);
	}

	/**
	 * A `using` whose module's SIMPLE name another package reuses no longer reads as an
	 * unresolvable conflict: the scan forwards the full module path, which pins one decl. `p.Other`
	 * declares no `deco`, so the rewrite lands despite `q.Other` existing.
	 */
	public function testUsingWithAmbiguousSimpleModuleNameStillFlagged(): Void {
		Assert.equals(
			1, violationsOf(fileSet(user('using Ext;\nusing p.Other;\n\n', 'Ext.deco(w, 1);'), WIDGET_SOURCE, [
				{
					file: 'p/Other.hx',
					source: 'package p;\n\nclass Other {\n\tpublic static function tag(w: Widget): Widget return w;\n}\n'
				},
				{
					file: 'q/Other.hx',
					source: 'package q;\n\nclass Other {\n\tpublic static function deco(w: Widget, n: Int): Widget return w;\n}\n'
				}
			])).length
		);
	}

	public function testNonConflictingUsingStillFlagged(): Void {
		Assert.equals(
			1,
			violationsOf(fileSet(user('using Ext;\nusing Other;\n\n', 'Ext.deco(w, 1);'), WIDGET_SOURCE, [
				{ file: 'Other.hx', source: 'class Other {\n\tpublic static function tag(w: Widget): Widget return w;\n}\n' }
			])).length
		);
	}

	public function testTypeNameValueShadowedNotFlagged(): Void {
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(Ext:Widget, w:Widget):Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n';
		Assert.equals(0, violationsOf(fileSet(source)).length);
	}

	public function testMultiArgRestRewritten(): Void {
		final out: String = fixResultOf(fileSet(user('using Ext;\n\n', 'Ext.pad(w, 1, 2);')));
		Assert.isTrue(out.indexOf('w.pad(1, 2);') != -1, out);
	}

	public function testNestedArgumentCompositionRewritesBoth(): Void {
		final source: String =
			'using Ext;\n\nclass C {\n\tfunction f(w:Widget, w2:Widget):Void {\n\t\tExt.deco(w, Ext.deco(w2, 1));\n\t}\n}\n';
		Assert.equals(2, violationsOf(fileSet(source)).length);
		final out: String = fixResultOf(fileSet(source));
		Assert.isTrue(out.indexOf('w.deco(w2.deco(1));') != -1, out);
	}

	/**
	 * A nested pair now rewrites WHOLE in one pass: the outer receiver is itself an `Ext.deco(…)`
	 * call, and a type-qualified static call is a shape the resolution walk answers, so both
	 * findings carry a fix. It used to take two passes — the outer waited for the inner rewrite to
	 * turn its receiver into an identifier — which is the same end state one round later.
	 */
	public function testNestedReceiverRewritesWhole(): Void {
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(w:Widget):Void {\n\t\tExt.deco(Ext.deco(w, 1), 2);\n\t}\n}\n';
		Assert.equals(2, violationsOf(fileSet(source)).length);
		final out: String = fixResultOf(fileSet(source));
		Assert.isTrue(out.indexOf('w.deco(1).deco(2);') != -1, out);
	}

	public function testCommentInDroppedRegionNotFixed(): Void {
		final files: Array<{ file: String, source: String }> = fileSet(user('using Ext;\n\n', 'Ext.deco(/* c */ w, 1);'));
		Assert.equals(1, violationsOf(files).length);
		Assert.equals(0, editsOf(files).length);
	}

	public function testZeroArgStaticNotFlagged(): Void {
		Assert.equals(0, violationsOf(fileSet(user('using Ext;\n\n', 'Ext.now();'))).length);
	}

	public function testQualifiedConfigEntryRewritesWithoutSecondInsert(): Void {
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["p.Ext"]}}}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: user('using p.Ext;\n\n', 'Ext.deco(w, 1);') },
			{ file: 'p/Ext.hx', source: 'package p;\n\n$EXT_SOURCE' },
			{ file: 'Widget.hx', source: WIDGET_SOURCE }
		];
		final out: String = fixResultOf(files, config);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('using p.Ext;') != -1, out);
		Assert.equals(out.indexOf('using p.Ext;'), out.lastIndexOf('using p.Ext;'));
		Assert.isTrue(out.indexOf('using Ext;') == -1, out);
	}

	public function testKnownExtensionMethodReported(): Void {
		final config: String = STRINGTOOLS_CONFIG;
		final vs: Array<Violation> = violationsOf([{ file: 'C.hx', source: stringToolsUser('urlEncode') }], config);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('s.urlEncode()') != -1, vs[0].message);
	}

	public function testUnknownStdMethodNotFlagged(): Void {
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: stringToolsUser('notAMethod') }], STRINGTOOLS_CONFIG).length);
	}

	public function testDefaultTypesActiveWithoutConfig(): Void {
		// An explicitly EMPTY rule config, so the assertion pins the `types` default rather than
		// the absence of an `apqlint.json` anywhere above the test's working directory.
		Assert.equals(1, violationsOf([{ file: 'C.hx', source: stringToolsUser('urlEncode') }], EMPTY_CONFIG).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: 'class Bad { function f() { Ext.deco(w,' }]).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-static-extension'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-static-extension'));
	}

	public function testTypedefAliasShadowNotFixable(): Void {
		// `typedef Alias = Widget` indexes as a MEMBER-LESS decl, so a naive closure proof reads
		// every name as absent from it — while the alias target's `deco` really would win.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(a:Alias):Void {\n\t\tExt.deco(a, 1);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(
			source, 'class Widget {\n\tpublic function deco(n: Int): Widget return this;\n}\n',
			[{ file: 'Alias.hx', source: 'typedef Alias = Widget;\n' }]
		);
		Assert.equals(0, editsOf(files).length);
		for (violation in violationsOf(files))
			Assert.isTrue(violation.message.indexOf('verify the receiver type') != -1, violation.message);
	}

	public function testTypedefAliasWithoutShadowStillFixable(): Void {
		// The positive control: following the alias must not blanket-refuse every typedef.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(a:Alias):Void {\n\t\tExt.deco(a, 1);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(
			source, WIDGET_SOURCE, [{ file: 'Alias.hx', source: 'typedef Alias = Widget;\n' }]
		);
		Assert.isTrue(fixResultOf(files).indexOf('a.deco(1);') != -1);
	}

	public function testConditionalAliasNotFixableEitherBranchOrder(): Void {
		// Both `#if` branches project under ONE `Conditional`, and the index keeps the FIRST
		// declaration of a name — so an alias followed from one branch would commit to whichever
		// branch happened to be indexed, and silently retarget the other compilation.
		for (order in [
			'#if js\ntypedef X = Widget;\n#else\ntypedef X = Plain;\n#end\n',
			'#if js\ntypedef X = Plain;\n#else\ntypedef X = Widget;\n#end\n'
		]) {
			final source: String = 'using Ext;\n\nclass C {\n\tfunction f(a:X):Void {\n\t\tExt.deco(a, 1);\n\t}\n}\n';
			final files: Array<{ file: String, source: String }> =
				fileSet(source, 'class Widget {\n\tpublic function deco(n: Int): Widget return this;\n}\n', [
					{ file: 'X.hx', source: order },
					{ file: 'Plain.hx', source: 'class Plain {}\n' }
				]);
			Assert.equals(0, editsOf(files).length, order);
		}
	}

	public function testSelfAliasCycleNotFixable(): Void {
		// An alias CYCLE never reaches a member host, so it proves nothing — unlike a supertype
		// cycle, whose closure is still fully enumerated.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(a:SelfAlias):Void {\n\t\tExt.deco(a, 1);\n\t}\n}\n';
		Assert.equals(
			0, editsOf(fileSet(source, WIDGET_SOURCE, [{ file: 'SelfAlias.hx', source: 'typedef SelfAlias = SelfAlias;\n' }])).length
		);
	}

	public function testFunctionTypeAliasNotFixable(): Void {
		// `typedef F = Holder<Int> -> String` is a FUNCTION type; reading its head as the nominal
		// `Holder` would prove absence against the wrong type entirely.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(a:F):Void {\n\t\tExt.deco(a, 1);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(source, WIDGET_SOURCE, [
			{ file: 'F.hx', source: 'typedef F = Holder<Int> -> String;\n' },
			{ file: 'Holder.hx', source: 'class Holder {}\n' }
		]);
		Assert.equals(0, editsOf(files).length);
	}

	public function testFixFallsBackToPassedIndexWithoutResolutionScope(): Void {
		// The `?? index` arm: a bare plugin hosts no resolution scope, so the index the caller
		// passes is the only one — and must still drive the gates to a real edit.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isNull(RefactorSupport.resolutionIndexOf(plugin));
		Assert.equals(2, editsOf(fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);'))).length);
	}

	public function testForwardAbstractShadowNotFixable(): Void {
		// A `@:forward` abstract exposes its UNDERLYING's members through a link no `extends`
		// clause records, so its own empty member list proves nothing.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(w:Fwd):Void {\n\t\tExt.pad(w, 1, 2);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> =
			fileSet(source, 'class Widget {\n\tpublic function pad(a: Int, b: Int): Widget return this;\n}\n', [
				{ file: 'Fwd.hx', source: '@:forward abstract Fwd(Widget) from Widget to Widget {}\n' }
			]);
		Assert.equals(0, editsOf(files).length);
	}

	public function testInsertedUsingLandsAboveExistingUsings(): Void {
		// Haxe resolves static extensions in REVERSE declaration order, so an insert placed after
		// the existing run would outrank `using Other;` and hijack its `tag` calls.
		final source: String =
			'using Other;\n\nclass C {\n\tfunction f(w:Widget, v:Widget):Void {\n\t\tv.tag();\n\t\tExt.deco(w, 1);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(source, WIDGET_SOURCE, [
			{ file: 'Other.hx', source: 'class Other {\n\tpublic static function tag(w: Widget): Widget return w;\n}\n' }
		]);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
		Assert.isTrue(out.indexOf('using Ext;') < out.indexOf('using Other;'), out);
		Assert.isTrue(out.indexOf('v.tag();') != -1, out);
	}

	public function testFixPrefersResolutionScopeOverPassedIndex(): Void {
		// `Cli` hands `fix` the REPORT-scoped index; the receiver's type may only be resolvable
		// through the plugin's wider resolution scope, where `run` already proved the gates.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(w:Widget):Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n';
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		final library: Array<{ file: String, source: String }> = [
			{ file: 'Ext.hx', source: EXT_SOURCE },
			{ file: 'Widget.hx', source: WIDGET_SOURCE }
		];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(library) } });
		final check: PreferStaticExtension = new PreferStaticExtension();
		check.setConfigResolver(_ -> LintConfig.parse(EXT_CONFIG));
		final violations: Array<Violation> = check.run(report, scoped);
		Assert.equals(1, violations.length);
		// The index argument sees the report file ONLY — the wider scope must win.
		Assert.equals(2, check.fix(source, violations, scoped, SymbolIndex.build(report, scoped)).length);
	}

	public function testNoAnchorInsertsUsingAtFileHead(): Void {
		final source: String = 'class C {\n\tfunction f(w:Widget):Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n';
		final out: String = fixResultOf(fileSet(source));
		Assert.isTrue(out.indexOf('using Ext;') == 0, out);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
	}

	public function testTwoModulesMergeIntoOneInsert(): Void {
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["Ext", "Ext2"]}}}';
		final source: String = 'class C {\n\tfunction f(w:Widget):Void {\n\t\tExt.deco(w, 1);\n\t\tExt2.tint(w, 2);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(source, WIDGET_SOURCE, [
			{ file: 'Ext2.hx', source: 'class Ext2 {\n\tpublic static function tint(w: Widget, n: Int): Widget return w;\n}\n' }
		]);
		Assert.equals(5, editsOf(files, config).length);
		final out: String = fixResultOf(files, config);
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
		Assert.isTrue(out.indexOf('using Ext2;') != -1, out);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('w.tint(2);') != -1, out);
	}

	public function testCommentAfterReceiverNotFixed(): Void {
		final files: Array<{ file: String, source: String }> = fileSet(user('using Ext;\n\n', 'Ext.deco(w /* keep */, 1);'));
		Assert.equals(1, violationsOf(files).length);
		Assert.equals(0, editsOf(files).length);
	}

	public function testCommentInSingleArgTailNotFixed(): Void {
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["Ext1"]}}}';
		final source: String = 'using Ext1;\n\nclass C {\n\tfunction f(w:Widget):Void {\n\t\tExt1.solo(w /* keep */);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(source, WIDGET_SOURCE, [
			{ file: 'Ext1.hx', source: 'class Ext1 {\n\tpublic static function solo(w: Widget): Widget return w;\n}\n' }
		]);
		Assert.equals(1, violationsOf(files, config).length);
		Assert.equals(0, editsOf(files, config).length);
	}

	public function testMethodCallReceiverRewritten(): Void {
		// The TM shape: `StringTools.ltrim(str.substr(1))`. A method-call receiver carries the
		// method's RETURN type, so the shadow gate has a real type to prove absence against.
		final out: String = fixResultOf(makerFiles('Ext.deco(m.make(), 1);'));
		Assert.isTrue(out.indexOf('m.make().deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('Ext.deco(') == -1, out);
	}

	public function testMethodCallReceiverInstanceShadowNotFlagged(): Void {
		// The safety pin for the widened receiver: the resolved RETURN type shadows `deco`, so the
		// site must DROP exactly as an ident receiver of the same type would.
		final files: Array<{ file: String, source: String }> = makerFiles(
			'Ext.deco(m.make(), 1);', 'class Widget {\n\tpublic function deco(n: Int): Widget return this;\n}\n'
		);
		Assert.equals(0, violationsOf(files).length);
	}

	public function testChainedMethodCallReceiverRewritten(): Void {
		final out: String = fixResultOf(makerFiles('Ext.deco(m.self().make(), 1);'));
		Assert.isTrue(out.indexOf('m.self().make().deco(1);') != -1, out);
	}

	/**
	 * The receiver is itself a `using`-brought extension call whose parameter accepts the
	 * receiver STRUCTURALLY — `Bag` declares `iterator()` but implements nothing, so only
	 * membership can prove `IterExt.pick(it:Iterable<T>)` is what `b.pick()` binds.
	 */
	public function testStructuralIterableExtensionChainRewritten(): Void {
		final out: String = fixResultOf(bagFiles('Ext.deco(b.pick(), 1);'));
		Assert.isTrue(out.indexOf('b.pick().deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('Ext.deco(') == -1, out);
	}

	/** A receiver whose type declares no `iterator()` satisfies nothing, so the chain stays unresolved. */
	public function testNonIterableExtensionChainStaysUnresolved(): Void {
		assertUnresolvedReceiver(bagFiles('Ext.deco(p.pick(), 1);'));
	}

	/**
	 * The type ARGUMENT gate end to end: `IterExt.fixed(it:Iterable<Widget>)` is iterable-shaped,
	 * but a receiver NOMINAL carries no element type to match `Widget` against, so the site stays
	 * report-only rather than being claimed on the container membership alone.
	 */
	public function testConcreteElementTypeExtensionChainStaysUnresolved(): Void {
		assertUnresolvedReceiver(bagFiles('Ext.deco(b.fixed(), 1);'));
	}

	public function testForBinderOverTabledStaticCallResolvesReceiver(): Void {
		// The TM shape: `for (key in Reflect.fields(o)) StringTools.urlEncode(key)`. The iterable is
		// a TABLED stdlib static (`Reflect.fields` -> `Array<String>`), so the binder's element type
		// is `String` and the receiver resolves — the finding drops the unresolved-receiver hedge
		// and becomes fixable.
		final files: Array<{ file: String, source: String }> = strExtFiles('for (key in Reflect.fields(o)) StrExt.deco(key, 1);');
		final vs: Array<Violation> = violationsOf(files, STREXT_CONFIG);
		Assert.equals(1, vs.length);
		Assert.equals(-1, vs[0].message.indexOf('receiver type unresolved'), vs[0].message);
		Assert.isTrue(vs[0].message.indexOf('key.deco(1)') != -1, vs[0].message);
		Assert.isTrue(editsOf(files, STREXT_CONFIG).length > 0);
	}

	public function testForBinderOverTabledStaticCallOfShadowedTypeStaysUnresolved(): Void {
		// An indexed PROJECT type named `Reflect` shadows the stdlib one, so its `fields` may return
		// anything — the table is refused and the binder stays untyped (report-only, hedged).
		final files: Array<{ file: String, source: String }> = strExtFiles('for (key in Reflect.fields(o)) StrExt.deco(key, 1);')
			.concat([
				{
					file: 'Reflect.hx',
					source: 'class Reflect {\n\tpublic static function fields(o: Dynamic): Array<Widget> return null;\n}\n'
				}
			]);
		final vs: Array<Violation> = violationsOf(files, STREXT_CONFIG);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('receiver type unresolved') != -1, vs[0].message);
	}

	public function testUntabledStaticCallIterableStaysUnresolved(): Void {
		// `Reflect.copy` is deliberately absent from the static-return table. A forward pin: the
		// table must stay an enumeration, so a future over-broad entry cannot silently type a binder
		// the return does not justify.
		final files: Array<{ file: String, source: String }> = strExtFiles('for (key in Reflect.copy(o)) StrExt.deco(key, 1);');
		final vs: Array<Violation> = violationsOf(files, STREXT_CONFIG);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('receiver type unresolved') != -1, vs[0].message);
	}

	public function testTabledStaticCallOnValueBoundReceiverStaysUnresolved(): Void {
		// A PARAMETER named `Reflect` shadows the type, so `Reflect.fields(o)` is an INSTANCE field
		// access whose return the table cannot speak for — `receiverRootIsUnboundType` refuses it.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'C.hx',
				source: 'using StrExt;\n\nclass C {\n\tfunction f(Reflect:Holder, o:Dynamic):Void {\n'
					+ '\t\tfor (key in Reflect.fields(o)) StrExt.deco(key, 1);\n\t}\n}\n'
			},
			{ file: 'StrExt.hx', source: STREXT_SOURCE },
			{ file: 'String.hx', source: 'class String {}\n' },
			{ file: 'Holder.hx', source: 'class Holder {\n\tpublic var fields:Widget;\n}\n' },
			{ file: 'Widget.hx', source: WIDGET_SOURCE }
		];
		final vs: Array<Violation> = violationsOf(files, STREXT_CONFIG);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('receiver type unresolved') != -1, vs[0].message);
	}

	public function testTabledStaticCallSurvivesAnIndexedStdDeclaration(): Void {
		// The std-EXEMPTION half of the shadow gate, and the whole reason it is not the sibling
		// arm's "declared at all" test: the std is normally indexed (`StdResolver` joins it), so a
		// `Reflect` declared UNDER the std root must not veto the table. Skipped when no std is
		// discoverable (`APQ_NO_STD`, a machine with no Haxe) — there is nothing to attribute then.
		final stdDir: Null<String> = StdResolver.stdDir();
		if (stdDir == null) {
			Assert.pass();
			return;
		}
		final files: Array<{ file: String, source: String }> = strExtFiles('for (key in Reflect.fields(o)) StrExt.deco(key, 1);')
			.concat([
				{
					file: haxe.io.Path.join([stdDir, 'Reflect.hx']),
					source: 'extern class Reflect {\n\tpublic static function fields(o: Dynamic): Array<String>;\n}\n'
				}
			]);
		final vs: Array<Violation> = violationsOf(files, STREXT_CONFIG);
		Assert.equals(1, vs.length);
		Assert.equals(-1, vs[0].message.indexOf('receiver type unresolved'), vs[0].message);
	}

	/**
	 * A TYPE-qualified static call IS a resolvable receiver: an upper-initial identifier that binds
	 * to no value and names a type the index declares can only be that type, so `Mk.make()` has
	 * `make`'s declared return type and the rewrite is licensed like any other.
	 *
	 * This used to be pinned as the conservative MISS. It stopped being one when the shared
	 * resolution walk learned the shape (`NominalTypes.staticCallNominal`); what still pins the
	 * miss is `testUnknownStaticReceiverReportedOnly` below, where the receiver type is declared
	 * nowhere at all.
	 */
	public function testStaticCallReceiverResolves(): Void {
		final files: Array<{ file: String, source: String }> = fileSet(user('using Ext;\n\n', 'Ext.deco(Mk.make(), 1);'), WIDGET_SOURCE, [
			{ file: 'Mk.hx', source: 'class Mk {\n\tpublic static function make(): Widget return null;\n}\n' }
		]);
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.equals(-1, vs[0].message.indexOf('receiver type unresolved'), vs[0].message);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('Mk.make().deco(1);') != -1, out);
	}

	/** The receiver type the index does not declare at all — nothing to verify the shadow gate against. */
	public function testUnknownStaticReceiverReportedOnly(): Void {
		assertUnresolvedReceiver(fileSet(user('using Ext;\n\n', 'Ext.deco(Unknown.make(), 1);')));
	}

	public function testParenthesizedReceiverUnwrapped(): Void {
		final out: String = fixResultOf(fileSet(user('using Ext;\n\n', 'Ext.deco((w), 1);')));
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
	}

	public function testTernaryReceiverReportedOnly(): Void {
		// Both branches resolve to `Widget`, so the null nominal comes from the TERNARY node itself
		// — and a ternary is exactly the shape whose spliced text would need parentheses, which the
		// rewrite never adds. What refuses it TODAY is the resolution walk, not the kind whitelist
		// in `receiverNominal`: that one is a standing guard for a future widening of the shared
		// walk, and no fixture can discriminate it while the walk itself answers only postfix-safe
		// forms.
		final source: String =
			'using Ext;\n\nclass C {\n\tfunction f(b:Bool, w:Widget, v:Widget):Void {\n\t\tExt.deco(b ? w : v, 1);\n\t}\n}\n';
		assertUnresolvedReceiver(fileSet(source));
	}

	public function testAddUsingFalseWithUsingPresentStillFixes(): Void {
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["Ext"], "addUsing": false}}}';
		final out: String = fixResultOf(fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);')), config);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
	}

	public function testAbstractSelfReceiverRewritten(): Void {
		// Inside an abstract `this` IS the underlying value, and the header names its type one child
		// away — so the shadow gate has a nominal to weigh and the rewrite is proven.
		final files: Array<{ file: String, source: String }> = selfFiles('abstract C(Widget) from Widget to Widget');
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('this.deco(1)') != -1, vs[0].message);
		Assert.isTrue(vs[0].message.indexOf('receiver type unresolved') == -1, vs[0].message);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('this.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('Ext.deco(') == -1, out);
	}

	public function testEnumAbstractSelfReceiverRewritten(): Void {
		final files: Array<{ file: String, source: String }> = selfFiles('enum abstract C(Widget)');
		Assert.equals(1, violationsOf(files).length);
		Assert.isTrue(fixResultOf(files).indexOf('this.deco(1);') != -1);
	}

	public function testAbstractSelfReceiverUnderlyingShadowNotFlagged(): Void {
		// The underlying type is the one the rewritten access lands on, so a member of ITS is the
		// shadow that drops the site.
		final widget: String = 'class Widget {\n\tpublic function deco(n: Int): Widget return this;\n}\n';
		Assert.equals(0, violationsOf(selfFiles('abstract C(Widget) from Widget to Widget', '', widget)).length);
	}

	public function testAbstractOwnMemberDoesNotShadowSelfReceiver(): Void {
		// The mirror of the gate above: an abstract's OWN members are not reachable through `this`
		// (verified against the compiler), so declaring `deco` on the abstract shadows nothing.
		final files: Array<{ file: String, source: String }> = selfFiles(
			'abstract C(Widget) from Widget to Widget', '\tpublic function deco(n:Int):C\n\t\treturn this;\n\n'
		);
		Assert.equals(1, violationsOf(files).length);
		Assert.isTrue(fixResultOf(files).indexOf('this.deco(1);') != -1);
	}

	public function testAbstractNonNominalUnderlyingReportedOnly(): Void {
		assertUnresolvedReceiver(selfFiles('abstract C({w:Widget})'));
	}

	public function testClassSelfReceiverReportedOnly(): Void {
		// Deliberately narrow: inside a class `this` is the enclosing instance, which no configured
		// module's receiver can be — the site stays report-only instead of widening the rewrite.
		assertUnresolvedReceiver(selfFiles('class C'));
	}

	/** A `C.hx` source with `head` before the class and `body` as the sole statement of `f(w: Widget)`. */
	private function user(head: String, body: String): String {
		return '${head}class C {\n\tfunction f(w:Widget):Void {\n\t\t$body\n\t}\n}\n';
	}

	/** A bare-`this` receiver fixture: `head` is the host type's header, `extra` any member before the call site. */
	private function selfFiles(head: String, extra: String = '', widget: String = WIDGET_SOURCE): Array<{ file: String, source: String }> {
		return fileSet('using Ext;\n\n$head {\n$extra\tpublic function f():Void {\n\t\tExt.deco(this, 1);\n\t}\n}\n', widget);
	}

	/** Pins a site as reported but never rewritten, with the unresolved-receiver wording. */
	private function assertUnresolvedReceiver(files: Array<{ file: String, source: String }>): Void {
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('receiver type unresolved') != -1, vs[0].message);
		Assert.equals(0, editsOf(files).length);
	}

	/**
	 * A `C.hx` whose `f(o:Dynamic)` body is `body`, plus the `StrExt` utility and a memberless
	 * `String` fixture — the latter is what lets the closure gate PROVE `String` declares no
	 * `deco`, so a resolved receiver reaches the fixable verdict.
	 */
	private function strExtFiles(body: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: 'using StrExt;\n\nclass C {\n\tfunction f(o:Dynamic):Void {\n\t\t$body\n\t}\n}\n' },
			{ file: 'StrExt.hx', source: STREXT_SOURCE },
			{ file: 'String.hx', source: 'class String {}\n' },
			{ file: 'Widget.hx', source: WIDGET_SOURCE }
		];
	}

	/** The `Maker` fixture the CALL-receiver gates resolve through: `make` returns a `Widget`, `self` chains. */
	private function makerFiles(body: String, widget: String = WIDGET_SOURCE): Array<{ file: String, source: String }> {
		return fileSet('using Ext;\n\nclass C {\n\tfunction f(m:Maker):Void {\n\t\t$body\n\t}\n}\n', widget, [
			{
				file: 'Maker.hx',
				source: 'class Maker {\n\tpublic function make(): Widget return null;\n\n\tpublic function self(): Maker return this;\n}\n'
			}
		]);
	}

	/** The structural-membership fixture set: a `Bag` that only DECLARES `iterator()`, a plain type, and a generic extension module. */
	private function bagFiles(body: String): Array<{ file: String, source: String }> {
		return fileSet(
			'using Ext;\nusing IterExt;\n\nclass C {\n\tfunction f(b:Bag, p:Plain):Void {\n\t\t$body\n\t}\n}\n', WIDGET_SOURCE, [
				{ file: 'Bag.hx', source: 'class Bag {\n\tpublic function iterator(): BagIter return null;\n}\n' },
				{
					file: 'BagIter.hx',
					source: 'class BagIter {\n\tpublic function hasNext(): Bool return false;\n\n'
					+ '\tpublic function next(): Widget return null;\n}\n'
				},
				{ file: 'Plain.hx', source: 'class Plain {}\n' },
				{
					file: 'IterExt.hx',
					source: 'class IterExt {\n\tpublic static function pick<T>(it: Iterable<T>): Widget return null;\n\n'
					+ '\tpublic static function fixed(it: Iterable<Widget>): Widget return null;\n}\n'
				}
			]
		);
	}

	/** A `C.hx` calling `StringTools.<method>` on an UNANNOTATED parameter (an unresolvable receiver). */
	private function stringToolsUser(method: String): String {
		return 'class C {\n\tfunction f(s):Void {\n\t\tStringTools.$method(s);\n\t}\n}\n';
	}

	/** The user file plus the `Ext` utility, a `Widget` (overridable) and any `extra` fixture modules. */
	private function fileSet(
		source: String, widget: String = WIDGET_SOURCE, ?extra: Array<{ file: String, source: String }>
	): Array<{ file: String, source: String }> {
		final out: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: source },
			{ file: 'Ext.hx', source: EXT_SOURCE },
			{ file: 'Widget.hx', source: widget }
		];
		if (extra != null) for (e in extra) out.push(e);
		return out;
	}

	/** The `using`-less fixture set: `C.hx` carries a package + import anchor the insert lands after. */
	private function importingFiles(): Array<{ file: String, source: String }> {
		return [
			{
				file: 'C.hx',
				source: 'package top;\n\nimport sub.Widget;\n\nclass C {\n\tfunction f(w:Widget):Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n'
			},
			{ file: 'Ext.hx', source: EXT_SOURCE },
			{ file: 'sub/Widget.hx', source: 'package sub;\n\n$WIDGET_SOURCE' }
		];
	}

	/**
	 * `importingFiles` with the whole module body — imports, `head` and the class — wrapped in a
	 * single `#if FLAG` guard: the shape a debug-only module has, where the top-level scan sees
	 * nothing but `package` and one `Conditional`.
	 */
	private function conditionalFiles(head: String = ''): Array<{ file: String, source: String }> {
		return [
			{
				file: 'C.hx',
				source: 'package top;\n\n#if FLAG\nimport sub.Widget;\n\n${head}class C {\n\tfunction f(w:Widget):Void {\n'
					+ '\t\tExt.deco(w, 1);\n\t}\n}\n#end\n'
			},
			{ file: 'Ext.hx', source: EXT_SOURCE },
			{ file: 'sub/Widget.hx', source: 'package sub;\n\n$WIDGET_SOURCE' }
		];
	}

	/** The check's findings over `files`, with `config` (default: `Ext` as the single module) injected. */
	private function violationsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<Violation> {
		final check: PreferStaticExtension = new PreferStaticExtension();
		final json: String = config ?? EXT_CONFIG;
		check.setConfigResolver(_ -> LintConfig.parse(json));
		return check.run(files, new HaxeQueryPlugin());
	}

	/** The fix edits for `files[0]`'s own findings, resolved through a `SymbolIndex` over the whole set. */
	private function editsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferStaticExtension = new PreferStaticExtension();
		final json: String = config ?? EXT_CONFIG;
		check.setConfigResolver(_ -> LintConfig.parse(json));
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == files[0].file);
		return check.fix(files[0].source, own, plugin, SymbolIndex.build(files, plugin));
	}

	/**
	 * `files[0]` after its own findings are fixed and the result canonicalized — with
	 * `reformat` FALSE, exactly as `apq lint --fix` does it, so a fixture that is not already
	 * writer-canonical fails loudly here instead of being silently reformatted.
	 */
	private function fixResultOf(files: Array<{ file: String, source: String }>, ?config: String): String {
		final source: String = files[0].source;
		switch RefactorSupport.canonicalize(source, editsOf(files, config), false, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
