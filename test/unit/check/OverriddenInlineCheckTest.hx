package unit.check;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.OverriddenInline;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The `overridden-inline` check: an `inline` instance method a subtype overrides, and the override itself — reported at
 * both ends, `Severity.Error`, `--fix` dropping `inline` at the inline end. The
 * compiler rejects the pair only in a build that compiles the override, so a
 * superclass reached through ONE `#if` branch of an `extends` clause is the shape no single build's oracle sees.
 */
class OverriddenInlineCheckTest extends Test {

	@:pin('control')
	@:killer('M-OVERRIDDEN-DECLS-FIRST-LINK')
	public function testOverrideThroughALaterExtendsBranchFlagsBothEnds(): Void {
		final vs: Array<Violation> = CheckFixture.violationsIn(new OverriddenInline(), branchedFiles());
		Assert.equals('a/Client.hx:inline,b/Client.hx:inline,net/Client.hx:override', summary(vs));
		Assert.isTrue(vs.foreach(v -> v.severity == Severity.Error && v.rule == 'overridden-inline'));
		final over: Null<Violation> = vs.find(v -> v.file == 'net/Client.hx');
		Assert.isTrue(over != null && over.message.indexOf('a.Client') >= 0 && over.message.indexOf('b.Client') >= 0, over?.message);
	}

	public function testPlainOverrideOfInlineFlagsBothEnds(): Void {
		final vs: Array<Violation> = CheckFixture.violationsIn(new OverriddenInline(), [
			{ file: 'B.hx', source: 'class B {\n\tpublic function new() {}\n\n\tpublic inline function f():Int return 1;\n}' },
			{ file: 'S.hx', source: 'class S extends B {\n\toverride public function f():Int return 2;\n}' }
		]);
		Assert.equals('B.hx:inline,S.hx:override', summary(vs));
	}

	public function testOverrideOfAPlainMethodIsClean(): Void {
		Assert.equals(
			0, CheckFixture.violationsIn(new OverriddenInline(), [
				{ file: 'B.hx', source: 'class B {\n\tpublic function new() {}\n\n\tpublic function f():Int return 1;\n}' },
				{ file: 'S.hx', source: 'class S extends B {\n\toverride public inline function f():Int return 2;\n}' }
			]).length,
			'an inline OVERRIDE of a plain method is legal; only overriding the inline one is not'
		);
	}

	public function testStaticNamesakeIsNoOverride(): Void {
		Assert.equals(
			0, CheckFixture.violationsIn(new OverriddenInline(), [
				{ file: 'B.hx', source: 'class B {\n\tpublic static inline function f():Int return 1;\n}' },
				{ file: 'S.hx', source: 'class S extends B {\n\tpublic static function f():Int return 2;\n}' }
			]).length
		);
	}

	public function testOverrideBindsToTheNearestDeclaration(): Void {
		final vs: Array<Violation> = CheckFixture.violationsIn(new OverriddenInline(), [
			{ file: 'B.hx', source: 'class B {\n\tpublic function new() {}\n\n\tpublic inline function f():Int return 1;\n}' },
			{ file: 'M.hx', source: 'class M extends B {\n\toverride public function f():Int return 2;\n}' },
			{ file: 'S.hx', source: 'class S extends M {\n\toverride public function f():Int return 3;\n}' }
		]);
		Assert.equals('B.hx:inline,M.hx:override', summary(vs), 'S overrides the plain M.f, not the inline B.f');
	}

	public function testAnotherPackagesNamesakeIsNotTheSupertype(): Void {
		Assert.equals(
			0, CheckFixture.violationsIn(new OverriddenInline(), [
				{
					file: 'p/Base.hx',
					source: 'package p;\n\nclass Base {\n\tpublic function new() {}\n\n\tpublic inline function f():Int return 1;\n}'
				},
				{
					file: 'q/Base.hx',
					source: 'package q;\n\nclass Base {\n\tpublic function new() {}\n\n\tpublic function f():Int return 1;\n}'
				},
				{ file: 'q/Sub.hx', source: 'package q;\n\nclass Sub extends q.Base {\n\toverride public function f():Int return 2;\n}' }
			]).length
		);
	}

	public function testOverrideInTheResolutionScopeFlagsTheReportedInline(): Void {
		final report: Array<{ file: String, source: String }> = [
			{
				file: 'a/Client.hx',
				source: 'package a;\n\nclass Client {\n\tpublic function new() {}\n\n\tpublic inline function send():Void {}\n}'
			}
		];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: [],
				library: new LibrarySources([
					{
						file: 'net/Client.hx',
						source: 'package net;\n\nclass Client #if js extends a.Client #end {\n\toverride public function send():Void {}\n}'
					}
				])
			}
		});
		Assert.equals('a/Client.hx:inline', summary(CheckFixture.violationsIn(new OverriddenInline(), report, scoped)));
	}

	@:pin('control')
	@:killer('M-OVERRIDDEN-INLINE-FIX-NONE')
	public function testFixDropsInlineOnTheOverriddenEndOnly(): Void {
		final files: Array<{ file: String, source: String }> = branchedFiles();
		final check: OverriddenInline = new OverriddenInline();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files);
		final fixed: Array<String> = [];
		for (f in files) {
			final mine: Array<Violation> = vs.filter(v -> v.file == f.file);
			final edits: Array<FixEdit> = mine.length == 0 ? [] : CheckFixture.fixIn(check, files, mine, f.file);
			if (edits.length == 0) continue;
			switch CanonicalEdit.canonicalize(f.source, edits, true, new HaxeQueryPlugin()) {
				case Ok(text):
					fixed.push('${f.file}=${text.indexOf('public function send(') >= 0 && text.indexOf('inline') < 0}');
				case Err(message):
					Assert.fail('fix canonicalize Err: $message');
			}
		}
		Assert.equals('a/Client.hx=true,b/Client.hx=true', fixed.join(','), 'the inline end loses its modifier; the override is untouched');
	}

	public function testExternInlineIsReportedButNotFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'B.hx', source: 'extern class B {\n\tpublic function new():Void;\n\n\tpublic inline function f():Int return 1;\n}' },
			{ file: 'S.hx', source: 'class S extends B {\n\toverride public function f():Int return 2;\n}' }
		];
		final check: OverriddenInline = new OverriddenInline();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files).filter(v -> v.file == 'B.hx');
		Assert.equals(1, vs.length);
		Assert.equals(0, CheckFixture.fixIn(check, files, vs, 'B.hx').length);
	}

	/** The library shape: one subtype naming a different superclass per `#if` branch, the first of which declares nothing. */
	private static function branchedFiles(): Array<{ file: String, source: String }> {
		return [
			{ file: 'x/Other.hx', source: 'package x;\n\nclass Other {\n\tpublic function new() {}\n}' },
			{
				file: 'a/Client.hx',
				source: 'package a;\n\nclass Client {\n\tpublic function new() {}\n\n'
					+ '\tpublic inline function send(s:String):Void trace(s);\n}'
			},
			{
				file: 'b/Client.hx',
				source: 'package b;\n\nclass Client {\n\tpublic function new() {}\n\n'
					+ '\tpublic inline function send(s:String):Void trace(s);\n}'
			},
			{
				file: 'net/Client.hx',
				source: 'package net;\n\nclass Client #if node extends x.Other #elseif flash extends a.Client #elseif openfl extends '
					+ 'b.Client #end {\n\toverride public function send(s:String):Void {}\n}'
			}
		];
	}

	/** Each finding as `file:end`, sorted, `end` naming which side of the pair it sits on. */
	private static function summary(vs: Array<Violation>): String {
		final out: Array<String> = [
			for (v in vs) '${v.file}:${v.message.indexOf('inline method') == 0 ? 'inline' : 'override'}'
		];
		out.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return out.join(',');
	}

}
