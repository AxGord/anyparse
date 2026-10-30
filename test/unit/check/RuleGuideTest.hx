package unit.check;

import anyparse.check.RuleCategory;
import anyparse.check.RuleIndex;

using StringTools;

/**
 * Every builtin rule has its prose section in `docs/guide/lint/<category>.md` of its own category, and every section
 * there names a builtin of that category — so a rule cannot ship, move category or be removed without its prose
 * following it, the way `RuleCategoryTest` holds the generated index to the registry.
 */
class RuleGuideTest extends Test {

	public function testEveryRuleHasItsSectionAndEverySectionNamesARule(): Void {
		#if (sys || nodejs)
		final dir: String = 'docs/guide/lint';
		final pages: Array<String> = sys.FileSystem.readDirectory(dir).filter(f -> f.endsWith('.md'));
		pages.sort(Reflect.compare);
		final expectedPages: Array<String> = [for (c in RuleCategory.ALL) '$c.md'];
		expectedPages.sort(Reflect.compare);
		Assert.same(expectedPages, pages, 'one page per category and no other');
		for (category in RuleCategory.ALL) {
			final expected: Array<String> = [for (c in Linter.builtins()) if (c.category() == category) c.id()];
			expected.sort(Reflect.compare);
			final lines: Array<String> = sys.io.File.getContent('$dir/$category.md').split('\n');
			final headings: Array<String> = lines.filter(l -> l.startsWith('## '));
			final sections: Array<String> = [
				for (h in headings) if (h.startsWith('## `') && h.endsWith('`')) h.substring(4, h.length - 1)
			];
			Assert.equals(headings.length, sections.length, '$category.md: every second-level heading is a rule section');
			Assert.same(expected, sections, '$category.md: one section per rule of the category, by id');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testIndexLinksEachRuleToItsGuideSection(): Void {
		#if (sys || nodejs)
		final index: String = RuleIndex.markdown(Linter.builtins());
		for (c in Linter.builtins()) {
			final link: String = '[`${c.id()}`](guide/lint/${c.category()}.md#${c.id()})';
			Assert.isTrue(index.contains('| $link |'), '${c.id()}: its index row links its guide section');
			final page: String = sys.io.File.getContent('docs/guide/lint/${c.category()}.md');
			Assert.isTrue(page.contains('\n## `${c.id()}`\n'), '${c.id()}: the linked section exists');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

}
