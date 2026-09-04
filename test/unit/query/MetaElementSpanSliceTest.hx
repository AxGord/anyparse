package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.RemoveElement;
import anyparse.query.ReplaceNode;
import utest.Assert;
import utest.Test;

/**
 * A `@:meta` is an element in its OWN right — `--select 'MetaCall:@:access'`
 * names it, `apq source --select` prints its seventeen bytes alone, and the
 * mutation ops echo it back as their target. `declGroupSpan` used to walk
 * FORWARD off it to the declaration it decorates, so the span every op COMPUTED was the whole `[@:meta modifiers… decl]` group: `remove-element`
 * on a module-level `@:access` deleted the annotation AND the entire class
 * (137 lines to 12 on the file that found this), at rc 0, reporting
 * `wrote <file>`, and leaving a file that still parses — invisible to the
 * re-parse gate by construction.
 *
 * A bare modifier keyword is NOT such an element (its own op is
 * `set-modifier`), and the position convention makes it the first token of
 * the declaration it precedes, so a cursor there still targets that
 * declaration — the controls below pin that half, at BOTH levels.
 */
@:nullSafety(Strict)
final class MetaElementSpanSliceTest extends Test {

	/** Module level, `@:name(args)`: the annotation goes, the type stays. */
	public function testRemoveModuleMetaCallKeepsTheType(): Void {
		final source: String = '@:access(foo.Bar)\nclass C {\n\tfunction f():Void {}\n}\n';
		assertRemove(source, 1, 1, 'class C {\n\tfunction f():Void {}\n}\n');
	}

	/** Module level, paren-less `@:name` — the other meta projection. */
	public function testRemoveModuleMetaKeepsTheType(): Void {
		final source: String = '@:keep\nclass C {\n\tfunction f():Void {}\n}\n';
		assertRemove(source, 1, 1, 'class C {\n\tfunction f():Void {}\n}\n');
	}

	/**
	 * Member level: the annotation goes, its method and the method after it stay.
	 * The blank line between the two survivors is the WRITER's own re-emit and not
	 * the deletion's — removing a plain `var z:Int;` member from the same shape
	 * produces byte-identical output.
	 */
	public function testRemoveMemberMetaKeepsTheMember(): Void {
		final source: String = 'class C {\n\t@:noCompletion\n\tpublic function f():Void {}\n\tpublic function g():Void {}\n}\n';
		assertRemove(source, 2, 2, 'class C {\n\tpublic function f():Void {}\n\n\tpublic function g():Void {}\n}\n');
	}

	/** One meta of a RUN goes alone — the sibling annotation and the type stay. */
	public function testRemoveOneOfAMetaRun(): Void {
		final source: String = '@:keep\n@:access(foo.Bar)\nclass C {\n\tfunction f():Void {}\n}\n';
		assertRemove(source, 2, 1, '@:keep\nclass C {\n\tfunction f():Void {}\n}\n');
	}

	/** `replace-node` spliced the same over-wide span — the whole class became one annotation. */
	public function testReplaceModuleMetaKeepsTheType(): Void {
		final source: String = '@:access(foo.Bar)\nclass C {\n\tfunction f():Void {}\n}\n';
		assertReplace(source, 'MetaCall:@:access', '@:access(baz.Qux)', '@:access(baz.Qux)\nclass C {\n\tfunction f():Void {}\n}\n');
	}

	/** …and at member level it took the method with it. */
	public function testReplaceMemberMetaKeepsTheMember(): Void {
		final source: String = 'class C {\n\t@:noCompletion\n\tpublic function f():Void {}\n}\n';
		assertReplace(source, 'Meta:@:noCompletion', '@:noDoc', 'class C {\n\t@:noDoc\n\tpublic function f():Void {}\n}\n');
	}

	/**
	 * CONTROL, green at base BY CONSTRUCTION: a cursor on a bare modifier
	 * keyword still targets the declaration it precedes — and carries that
	 * declaration's leading annotation with it.
	 */
	public function testRemoveModifierStillTakesTheMemberAndItsMeta(): Void {
		final source: String = 'class C {\n\t@:noCompletion\n\tpublic function f():Void {}\n\tpublic function g():Void {}\n}\n';
		assertRemove(source, 3, 2, 'class C {\n\tpublic function g():Void {}\n}\n');
	}

	/** CONTROL, green at base BY CONSTRUCTION: the same at module level — `private` still takes its type. */
	public function testRemoveModuleModifierStillTakesTheType(): Void {
		final source: String = 'private class C {\n\tfunction f():Void {}\n}\nclass D {}\n';
		assertRemove(source, 1, 1, 'class D {}\n');
	}

	/** CONTROL, green at base BY CONSTRUCTION: the BACKWARD fold — a cursor on the decl keyword still eats the whole prefix run. */
	public function testRemoveDeclKeywordStillFoldsItsPrefixRun(): Void {
		final source: String = 'class C {\n\t@:noCompletion\n\tpublic function f():Void {}\n\tpublic function g():Void {}\n}\n';
		assertRemove(source, 3, 9, 'class C {\n\tpublic function g():Void {}\n}\n');
	}

	/**
	 * The doc block above an annotation documents the DECLARATION under it, which
	 * is staying — so the delete must not extend back over it. Found by dogfooding
	 * on a real 79-line Pony class, after the span fix above already had the type
	 * surviving: `remove-element --select 'MetaCall:@:access'` still deleted the
	 * class's own doc block, because the doc extension is unconditional for every
	 * other target and a declaration is the only thing that can orphan one.
	 */
	public function testRemoveModuleMetaKeepsTheTypeDoc(): Void {
		final source: String = '/**\n * Doc.\n */\n@:access(foo.Bar)\nclass C {\n\tfunction f():Void {}\n}\n';
		assertRemove(source, 4, 1, '/**\n * Doc.\n */\nclass C {\n\tfunction f():Void {}\n}\n');
	}

	/** CONTROL, green at base BY CONSTRUCTION: removing the DECLARATION still takes its doc, annotation included. */
	public function testRemoveModuleDeclStillTakesItsDocAndMeta(): Void {
		final source: String = '/**\n * Doc.\n */\n@:access(foo.Bar)\nclass C {\n\tfunction f():Void {}\n}\nclass D {}\n';
		assertRemove(source, 5, 1, 'class D {}\n');
	}

	/**
	 * CONTROL: pointing at a bare MODIFIER still removes the declaration, so its doc
	 * must still travel — the doc exception is for annotations only. Without this the
	 * exception could be widened to every prefix sibling and nothing would notice.
	 */
	public function testRemoveModifierStillTakesTheMemberDoc(): Void {
		final source: String = 'class C {\n\t/**\n\t * Doc.\n\t */\n\tpublic function f():Void {}\n\tpublic function g():Void {}\n}\n';
		assertRemove(source, 5, 2, 'class C {\n\tpublic function g():Void {}\n}\n');
	}

	/**
	 * A `#if … #end` region holding nothing but annotations IS an annotation — the
	 * grammar's own `HxMetadata` enum counts `Conditional` among its four metadata
	 * forms. Addressing one emptied the WHOLE FILE at rc 0, the same signature as
	 * the plain-annotation case; the first correction pass covered three of the four
	 * ctors and disclosed this one as a mutation-testing gap, which understated it.
	 */
	public function testRemoveConditionalAnnotationRegionKeepsTheType(): Void {
		final source: String = '#if debug\n@:access(foo.Bar)\n#end\nclass C {\n\tfunction f():Void {}\n}\n';
		assertRemove(source, 1, 1, 'class C {\n\tfunction f():Void {}\n}\n');
	}

	/**
	 * CONTROL: a region holding a MODIFIER is not an annotation — `#if debug public
	 * #end` reads as the declaration's first token exactly like a bare `public`, so
	 * it still takes its member. Widening the exception to every conditional
	 * modifier region, which is the obvious over-fix, flips this and nothing else.
	 */
	public function testRemoveConditionalModifierRegionStillTakesTheMember(): Void {
		final source: String = 'class C {\n#if debug\n\tpublic\n#end\n\tfunction f():Void {}\n\tpublic function g():Void {}\n}\n';
		assertRemove(source, 2, 1, 'class C {\n\tpublic function g():Void {}\n}\n');
	}

	private function assertRemove(source: String, line: Int, col: Int, expected: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch RemoveElement.removeElement(source, line, col, true, plugin) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertReplace(source: String, selector: String, newSource: String, expected: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final result: EditResult = ReplaceNode.replaceNode(source, ReplaceTarget.BySelector(selector), newSource, true, plugin);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}
