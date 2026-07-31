package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.PreferStaticExtension;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

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
		Assert.equals(0, violationsOf(fileSet(user('using Ext;\n\n', 'Ext.deco(w, 1);'), 'class Widget extends Base {}\n', [
			{ file: 'Base.hx', source: 'class Base {\n\tpublic function deco(n: Int): Widget return this;\n}\n' }
		])).length);
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

	public function testUnresolvedReceiverReportedOnly(): Void {
		final source: String =
			'using Ext;\n\nclass C {\n\tfunction make(): Widget return null;\n\n\tfunction f(): Void {\n\t\tExt.deco(make(), 1);\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = fileSet(source);
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('receiver type unresolved') != -1, vs[0].message);
		Assert.equals(0, editsOf(files).length);
	}

	public function testDynamicReceiverNotFlagged(): Void {
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(d: Dynamic): Void {\n\t\tExt.deco(d, 1);\n\t}\n}\n';
		Assert.equals(0, violationsOf(fileSet(source)).length);
	}

	public function testConflictingUsingNotFlagged(): Void {
		Assert.equals(0, violationsOf(fileSet(user('using Ext;\nusing Other;\n\n', 'Ext.deco(w, 1);'), WIDGET_SOURCE, [
			{ file: 'Other.hx', source: 'class Other {\n\tpublic static function deco(w: Widget, n: Int): Widget return w;\n}\n' }
		])).length);
	}

	public function testNonConflictingUsingStillFlagged(): Void {
		Assert.equals(1, violationsOf(fileSet(user('using Ext;\nusing Other;\n\n', 'Ext.deco(w, 1);'), WIDGET_SOURCE, [
			{ file: 'Other.hx', source: 'class Other {\n\tpublic static function tag(w: Widget): Widget return w;\n}\n' }
		])).length);
	}

	public function testTypeNameValueShadowedNotFlagged(): Void {
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(Ext: Widget, w: Widget): Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n';
		Assert.equals(0, violationsOf(fileSet(source)).length);
	}

	public function testMultiArgRestRewritten(): Void {
		final out: String = fixResultOf(fileSet(user('using Ext;\n\n', 'Ext.pad(w, 1, 2);')));
		Assert.isTrue(out.indexOf('w.pad(1, 2);') != -1, out);
	}

	public function testNestedArgumentCompositionRewritesBoth(): Void {
		final source: String =
			'using Ext;\n\nclass C {\n\tfunction f(w: Widget, w2: Widget): Void {\n\t\tExt.deco(w, Ext.deco(w2, 1));\n\t}\n}\n';
		Assert.equals(2, violationsOf(fileSet(source)).length);
		final out: String = fixResultOf(fileSet(source));
		Assert.isTrue(out.indexOf('w.deco(w2.deco(1));') != -1, out);
	}

	public function testNestedReceiverInnerOnlyRewritten(): Void {
		// The OUTER receiver is a call — an unresolved receiver type, so it stays report-only
		// while the inner ident-receiver call rewrites in the same pass.
		final source: String = 'using Ext;\n\nclass C {\n\tfunction f(w: Widget): Void {\n\t\tExt.deco(Ext.deco(w, 1), 2);\n\t}\n}\n';
		Assert.equals(2, violationsOf(fileSet(source)).length);
		final out: String = fixResultOf(fileSet(source));
		Assert.isTrue(out.indexOf('Ext.deco(w.deco(1), 2);') != -1, out);
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
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["StringTools"]}}}';
		final vs: Array<Violation> = violationsOf([{ file: 'C.hx', source: stringToolsUser('urlEncode') }], config);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('s.urlEncode()') != -1, vs[0].message);
	}

	public function testUnknownStdMethodNotFlagged(): Void {
		final config: String = '{"rules": {"prefer-static-extension": {"types": ["StringTools"]}}}';
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: stringToolsUser('notAMethod') }], config).length);
	}

	public function testDefaultTypesActiveWithoutConfig(): Void {
		// No resolver injected: the `['Lambda', 'StringTools']` default is what matches here.
		final check: PreferStaticExtension = new PreferStaticExtension();
		Assert.equals(1, check.run([{ file: 'C.hx', source: stringToolsUser('urlEncode') }], new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: 'class Bad { function f() { Ext.deco(w,' }]).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-static-extension'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-static-extension'));
	}

	/** A `C.hx` source with `head` before the class and `body` as the sole statement of `f(w: Widget)`. */
	private function user(head: String, body: String): String {
		return '${head}class C {\n\tfunction f(w: Widget): Void {\n\t\t$body\n\t}\n}\n';
	}

	/** A `C.hx` calling `StringTools.<method>` on an UNANNOTATED parameter (an unresolvable receiver). */
	private function stringToolsUser(method: String): String {
		return 'class C {\n\tfunction f(s): Void {\n\t\tStringTools.$method(s);\n\t}\n}\n';
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
				source: 'package top;\n\nimport sub.Widget;\n\nclass C {\n\tfunction f(w: Widget): Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n'
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

	/** `files[0]` after its own findings are fixed and the result canonicalized. */
	private function fixResultOf(files: Array<{ file: String, source: String }>, ?config: String): String {
		final source: String = files[0].source;
		switch RefactorSupport.canonicalize(source, editsOf(files, config), true, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
