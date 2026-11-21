package unit.check.common.design;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.ExtractTypedef;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

using Lambda;

private typedef Done = { final slices: Array<CrossFileEdits>; final rewritten: Int; final skipped: Array<String>; };

/**
 * `ExtractTypedef`, the engine of `apq extract-typedef`: the structure written at an address becomes a typedef module, and
 * every occurrence of the same type in the scope is rewritten to its name. Same type is the equality of
 * `prefer-existing-typedef` — fields in any order, every type name denoting the same declaration, no type parameter among
 * them — and an occurrence failing a part is left as written and listed, never rewritten.
 */
class ExtractTypedefTest extends Test {

	/** The structure the tests name: `one` writes it, `two` reorders it. */
	private static inline final LINE_ONE: Int = 6;

	@:pin('control')
	@:killer('M-XTD-ORDER')
	public function testEqualOccurrencesInAnyFieldOrderBecomeTheName(): Void {
		final done: Done = taken(extract(project(), 'src/app/A.hx', LINE_ONE, null, 'model.Rec'));
		Assert.equals(2, done.rewritten);
		final text: String = applied(project(), done.slices)['src/app/A.hx'] ?? '';
		Assert.isTrue(text.contains('one(): Rec return null') && text.contains('two(p: Rec)') && text.contains('import model.Rec;'), text);
		Assert.isTrue(!text.contains('item: Item }'), text);
	}

	@:pin('control')
	@:killer('M-XTD-NESTED-ORDER')
	public function testANestedStructureInAnotherFieldOrderIsLeftAsWrittenAndListed(): Void {
		final source: String = 'package app;\n\nclass N {\n\tpublic var v: { id: Int, inner: { x: Int, y: Int } };\n'
			+ '\tpublic var w: { inner: { y: Int, x: Int }, id: Int };\n\tpublic var u: { inner: { x: Int, y: Int }, id: Int };\n}\n';
		final files: Array<SourceEntry> = [{ file: 'src/app/N.hx', source: source }];
		final done: Done = taken(extract(files, 'src/app/N.hx', 4, source.split('\n')[3].indexOf('id') + 1, 'model.Rec'));
		Assert.equals(2, done.rewritten);
		Assert.isTrue(
			done.skipped.length == 1 && done.skipped[0].startsWith('src/app/N.hx:5') && done.skipped[0].contains('another order'),
			done.skipped.join('\n')
		);
		final text: String = applied(files, done.slices)['src/app/N.hx'] ?? '';
		Assert.isTrue(
			text.contains('var v: Rec') && text.contains('var u: Rec') && text.contains('var w: { inner: { y: Int, x: Int }, id: Int }'),
			text
		);
	}

	public function testTheModuleHoldsTheStructureAsWrittenWithItsImports(): Void {
		final done: Done = taken(extract(project(), 'src/app/A.hx', LINE_ONE, null, 'model.Rec'));
		final created: Null<CrossFileEdits> = done.slices.find(s -> s.file == 'src/model/Rec.hx');
		final text: String = created?.create ?? '';
		Assert.isTrue(
			text.contains('package model;')
			&& text.contains('import lib.Item;')
			&& text.contains('typedef Rec')
			&& text.contains('id:Int')
			&& text.contains('item:Item'),
			text
		);
	}

	@:pin('control')
	@:killer('M-XTD-DENOTES')
	public function testANameDenotingAnotherDeclarationIsLeftAsWritten(): Void {
		final done: Done = taken(extract(project(), 'src/app/A.hx', LINE_ONE, null, 'model.Rec'));
		Assert.isTrue(
			done.skipped.exists(s -> s.startsWith('src/app/B.hx:6') && s.contains('another declaration')), done.skipped.join('\n')
		);
		Assert.isTrue(done.slices.exists(s -> s.file == 'src/app/A.hx'));
		Assert.isFalse(done.slices.exists(s -> s.file == 'src/app/B.hx'));
	}

	@:pin('control')
	@:killer('M-XTD-PARAM')
	public function testATypeParameterIsLeftAsWritten(): Void {
		final done: Done = taken(extract(project(), 'src/app/A.hx', LINE_ONE, null, 'model.Rec'));
		Assert.isTrue(done.skipped.exists(s -> s.startsWith('src/app/C.hx:6') && s.contains('type parameter')), done.skipped.join('\n'));
		Assert.isFalse(done.slices.exists(s -> s.file == 'src/app/C.hx'));
	}

	@:pin('control')
	@:killer('M-XTD-ADDRESSED-PARAM')
	public function testAnAddressedStructureNamingATypeParameterIsDeclined(): Void {
		final reason: String = declined(extract(project(), 'src/app/C.hx', 6, null, 'model.Rec'));
		Assert.isTrue(reason.contains('type parameter'), reason);
	}

	@:pin('control')
	@:killer('M-XTD-NAME-TAKEN')
	public function testATypeOfThatNameIsNotRedeclared(): Void {
		final reason: String = declined(extract(project(), 'src/app/A.hx', LINE_ONE, null, 'lib.Item'));
		Assert.equals('the type lib.Item already exists', reason);
	}

	@:pin('control')
	@:killer('M-ANON-EXISTING-TARGET')
	public function testAModuleAlreadyInTheScopeIsNotOverwritten(): Void {
		final files: Array<SourceEntry> = project().concat([{ file: 'src/model/Rec.hx', source: 'package model;\n\nclass Other {}\n' }]);
		final reason: String = declined(extract(files, 'src/app/A.hx', LINE_ONE, null, 'model.Rec'));
		Assert.isTrue(reason.contains('already exists') && reason.contains('src/model/Rec.hx'), reason);
	}

	public function testAPathThatIsNotPackageAndNameIsDeclined(): Void {
		for (path in ['model.rec', 'model.', 'Model.Rec.x', '', 'a b.C'])
			Assert.isTrue(declined(extract(project(), 'src/app/A.hx', LINE_ONE, null, path)).contains('not a type path'), path);
	}

	public function testNoStructureAtTheAddressIsDeclined(): Void {
		Assert.isTrue(declined(extract(project(), 'src/app/A.hx', 5, null, 'model.Rec')).contains('no anonymous structure'));
		Assert.isTrue(declined(extract(project(), 'src/app/A.hx', LINE_ONE, 1, 'model.Rec')).contains('no anonymous structure'));
		Assert.isTrue(declined(extract(project(), 'src/app/Missing.hx', 1, null, 'model.Rec')).contains('not in the scope'));
	}

	public function testSeveralStructuresOnALineNeedAColumn(): Void {
		final files: Array<SourceEntry> = [two('src/app/D.hx')];
		final reason: String = declined(extract(files, 'src/app/D.hx', 4, null, 'model.Rec'));
		Assert.isTrue(reason.contains('2 structures start on line 4'), reason);
		final column: Int = two('x').source.split('\n')[3].indexOf('{') + 1;
		Assert.equals(2, taken(extract(files, 'src/app/D.hx', 4, column, 'model.Rec')).rewritten);
	}

	public function testTheColumnPicksTheInnermostStructureHoldingIt(): Void {
		final source: String = 'package app;\n\nclass N {\n\tpublic var v: { id: Int, inner: { x: Int, y: Int } };\n}\n';
		final files: Array<SourceEntry> = [{ file: 'src/app/N.hx', source: source }];
		final line: String = source.split('\n')[3];
		final inner: Int = line.indexOf('{', line.indexOf('{') + 1) + 1;
		final done: Done = taken(extract(files, 'src/app/N.hx', 4, inner, 'model.Inner'));
		final text: String = done.slices.find(s -> s.file == 'src/model/Inner.hx')?.create ?? '';
		Assert.isTrue(text.contains('x:Int') && text.contains('y:Int') && !text.contains('inner'), text);
		final outer: Done = taken(extract(files, 'src/app/N.hx', 4, line.indexOf('id') + 1, 'model.Outer'));
		Assert.isTrue((outer.slices.find(s -> s.file == 'src/model/Outer.hx')?.create ?? '').contains('inner'));
	}

	private static function two(file: String): SourceEntry {
		return {
			file: file,
			source: 'package app;\n\nclass D {\n'
				+ '\tpublic function f(a: { id: Int, label: String }, b: { id: Int, label: String }): Void {}\n}\n'
		};
	}

	private static function project(): Array<SourceEntry> {
		return [
			{ file: 'src/lib/Item.hx', source: 'package lib;\n\nclass Item {}\n' },
			{ file: 'src/other/Item.hx', source: 'package other;\n\nclass Item {}\n' },
			{
				file: 'src/app/A.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass A {\n\tpublic function one(): { id: Int, item: Item } return null;\n'
					+ '\tpublic function two(p: { item: Item, id: Int }): Void {}\n}\n'
			},
			{
				file: 'src/app/B.hx',
				source: 'package app;\n\nimport other.Item;\n\nclass B {\n\tpublic function three(p: { id: Int, item: Item }): Void {}\n}\n'
			},
			{
				file: 'src/app/C.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass C<Item> {\n\tpublic var v: { id: Int, item: Item };\n}\n'
			}
		];
	}

	private static function extract(files: Array<SourceEntry>, file: String, line: Int, col: Null<Int>, path: String): Extraction {
		return ExtractTypedef.extract(files, new CachingGrammarPlugin(new HaxeQueryPlugin()), file, line, col, path);
	}

	private static function taken(result: Extraction): Done {
		return switch result {
			case Done(slices, rewritten, skipped): { slices: slices, rewritten: rewritten, skipped: skipped };
			case Declined(reason): throw 'declined: $reason';
		};
	}

	private static function declined(result: Extraction): String {
		return switch result {
			case Done(_, rewritten, _): 'done: $rewritten';
			case Declined(reason): reason;
		};
	}

	private static function applied(files: Array<SourceEntry>, slices: Array<CrossFileEdits>): Map<String, String> {
		final out: Map<String, String> = [ for (f in files) f.file => f.source ];
		for (slice in slices) {
			final created: Null<String> = slice.create;
			out[slice.file] = created ?? CanonicalEdit.applyEdits(out[slice.file] ?? '', slice.edits);
		}
		return out;
	}

}
