package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MisplacedTypeDoc;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * A `#if … #end` region holding nothing but metadata is part of a type's LEADING RUN, not a
 * declaration standing between the doc and the type.
 *
 * Counting it as an ordinary top-level declaration put it in the "first import" slot, so
 * `/** *\/` written directly above it read as stranded between the package statement and the
 * imports — and the fix then moved it BELOW the metadata, which is exactly where the compiler
 * stops attaching a doc (`haxe -D dox -xml` emits no `haxe_doc` for that shape). The
 * documentation silently stopped existing: no writer, linter or compiler diagnostic.
 */
class MisplacedTypeDocGuardedMetaTest extends Test {

	public function testDocAboveAGuardedMetaRunIsNotStranded(): Void {
		Assert.equals(0, run('package p;\n\n/**\n * Doc\n */\n#if !macro\n@:keep\n#end\nclass C {}\n').length);
	}

	public function testAGenuinelyStrandedDocIsStillFlagged(): Void {
		Assert.equals(1, run('package p;\n\n/**\n * Doc\n */\nimport p.Other;\n\n#if !macro\n@:keep\n#end\nclass C {}\n').length);
	}

	public function testTheFixAnchorsAboveTheGuardedMetaRun(): Void {
		// The doc has to land above `#if`, not between the region and the class: the compiler
		// attaches a type's doc only when nothing but whitespace separates the two.
		final source: String = 'package p;\n\n/**\n * Doc\n */\nimport p.Other;\n\n#if !macro\n@:keep\n#end\nclass C {}\n';
		final edits: Array<{ span: anyparse.runtime.Span, text: String }> = new MisplacedTypeDoc().fix(
			source, run(source), new HaxeQueryPlugin()
		);
		final insertion: Null<{ span: anyparse.runtime.Span, text: String }> = edits.length == 2 ? edits[1] : null;
		Assert.notNull(insertion);
		if (insertion != null) Assert.equals(source.indexOf('#if !macro'), insertion.span.from);
	}

	/** An EMPTY region guards nothing, so it must not read as annotation trivia the doc may sit above. */
	public function testAnEmptyGuardedRegionIsNotAnAnnotationRun(): Void {
		Assert.equals(1, run('package p;\n\n/**\n * Doc\n */\n#if !macro\n#end\nimport p.Other;\n\nclass C {}\n').length);
	}

	private function run(source: String): Array<Violation> {
		return new MisplacedTypeDoc().run([{ file: 'p/C.hx', source: source }], new HaxeQueryPlugin());
	}

}
