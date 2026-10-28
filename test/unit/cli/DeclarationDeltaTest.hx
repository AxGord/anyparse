package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.cli.DeclarationDelta;

using StringTools;

/**
 * `DeclarationDelta.compare`: a file's change classed as layout, imports, a rename or declarations, and declarations
 * matched by name — an insertion in the middle changes no neighbour, an inserted record leaves every other matched.
 */
@:nullSafety(Strict)
class DeclarationDeltaTest extends Test {

	private static final BASE: String = 'package p;\n\nimport a.B;\n\nclass C {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n\n'
		+ '\tpublic function g(): Int {\n\t\treturn 2;\n\t}\n\n\tpublic function h(): Int {\n\t\treturn 3;\n' + '\t}\n}\n';
	private static final BRACE: String = 'package p;\n\nimport a.B;\n\nclass C {\n\tpublic function f(a: Bool): Void {\n\t\tif (a) {\n'
		+ '\t\t\tfoo();\n\t\t}\n\t\tbar();\n\t}\n\n\tpublic function g(): Void {}\n}\n';

	public function testTheSameTextUnderAnotherLayoutIsLayout(): Void {
		final relaid: String = BASE.replace('public function g(): Int {\n\t\treturn 2;\n\t}', 'public function g():Int { return 2; }');
		Assert.equals(ChangeClass.Layout, compareHaxe(BASE, relaid).change);
	}

	public function testAnImportAloneIsImports(): Void {
		final delta: FileDelta = compareHaxe(BASE, BASE.replace('import a.B;\n', 'import a.B;\nimport a.D;\n'));
		Assert.equals(ChangeClass.Imports, delta.change);
		Assert.same(['import a.D;'], delta.headerAdded);
		Assert.same([], delta.headerRemoved);
		Assert.same([], delta.declarations);
	}

	public function testOneConsistentSubstitutionIsARename(): Void {
		final delta: FileDelta = compareHaxe(BASE, BASE.replace('function g()', 'function renamed()'));
		Assert.equals(ChangeClass.Renamed, delta.change);
		Assert.same([{ from: 'g', to: 'renamed' }], delta.renames);
	}

	public function testAnIdentifierKeptAtOnePlaceIsNoRename(): Void {
		Assert.isNull(DeclarationDelta.renamings('a(x); b(x);', 'a(y); b(x);'));
		Assert.isNull(DeclarationDelta.renamings('a(x); b(y);', 'a(z); b(z);'));
		Assert.same([{ from: 'x', to: 'y' }], DeclarationDelta.renamings('a(x); b(x);', 'a(y); b(y);'));
	}

	public function testAWordOfACommentNamesNoRename(): Void {
		final delta: FileDelta = compareHaxe(BASE, BASE.replace('\tpublic function h()', '\t// helper\n\tpublic function h()'));
		final reworded: FileDelta = compareHaxe(
			BASE.replace('\tpublic function h()', '\t// helper\n\tpublic function h()'),
			BASE.replace('\tpublic function h()', '\t// worker\n\tpublic function h()')
		);
		Assert.equals(ChangeClass.Declarations, delta.change);
		Assert.equals(ChangeClass.Declarations, reworded.change);
		Assert.same(['~ FnMember:h +1-1'], summary(reworded));
	}

	/**
	 * A member inserted between two others is the one declaration that changed: matched by name, the members below it
	 * keep their counterparts, where a positional walk reports every one of them as differing.
	 * Killed by arm `M-DECLARATION-DELTA-BY-POSITION`.
	 */
	@:pin('control')
	@:killer('M-DECLARATION-DELTA-BY-POSITION')
	public function testAnInsertedMemberShiftsNoOtherOne(): Void {
		final inserted: String = BASE.replace(
			'\tpublic function g(): Int {', '\tpublic function e(): Int {\n\t\treturn 0;\n\t}\n\n\tpublic function g(): Int {'
		);
		final delta: FileDelta = compareHaxe(BASE, inserted);
		Assert.equals(ChangeClass.Declarations, delta.change);
		Assert.same(['+ FnMember:e 3'], summary(delta));
	}

	public function testAChangedBodyAndARemovedMemberAreTheirOwn(): Void {
		final edited: String = BASE.replace('return 2;', 'return 20;').replace('\n\tpublic function h(): Int {\n\t\treturn 3;\n\t}\n', '');
		final delta: FileDelta = compareHaxe(BASE, edited);
		Assert.same(['~ FnMember:g +1-1', '- FnMember:h 3'], summary(delta));
		Assert.same(['g', 'h'], DeclarationDelta.namesOf(delta));
	}

	public function testADocCommentCountsTowardItsDeclaration(): Void {
		final documented: String = BASE.replace('\tpublic function h()', '\t/** The third. */\n\tpublic function h()');
		Assert.same(['~ FnMember:h +1-0'], summary(compareHaxe(BASE, documented)));
	}

	/**
	 * Records of one list share their name paths, so they are matched by content before order: the record inserted
	 * first is the one addition, and every record after it is matched to itself.
	 * Killed by arm `M-DECLARATION-DELTA-RECORDS-IN-ORDER`.
	 */
	@:pin('control')
	@:killer('M-DECLARATION-DELTA-RECORDS-IN-ORDER')
	public function testAnInsertedRecordLeavesEveryOtherMatched(): Void {
		final base: String = '{\n\t"arms": [\n\t\t{\n\t\t\t"name": "B",\n\t\t\t"note": "b"\n\t\t},\n\t\t{\n\t\t\t"name": "C",\n'
			+ '\t\t\t"note": "c"\n\t\t}\n\t]\n}\n';
		final now: String = base.replace(
			'\t\t{\n\t\t\t"name": "B"', '\t\t{\n\t\t\t"name": "A",\n\t\t\t"note": "a"\n\t\t},\n\t\t{\n\t\t\t"name": "B"'
		);
		final delta: FileDelta = DeclarationDelta.compare(new JsonQueryPlugin(), base, now);
		Assert.equals(ChangeClass.Declarations, delta.change);
		// the list itself gains the record's braces; no record already there changed
		Assert.same(['~', '+', '+'], [for (change in delta.declarations) (change.status: String)]);
		Assert.same(['arms', 'arms.name', 'arms.note'], [for (change in delta.declarations) change.key]);
	}

	public function testAFileNoGrammarReadsIsCountedInLines(): Void {
		final delta: FileDelta = DeclarationDelta.compareText('a\nb\nc\n', 'a\nB\nc\nd\n');
		Assert.equals(ChangeClass.Text, delta.change);
		Assert.equals(2, delta.added);
		Assert.equals(1, delta.removed);
	}

	/** A closing brace moved past a statement changes the writer's output, so it is never layout. */
	public function testAMovedBraceIsNoLayout(): Void {
		final delta: FileDelta = compareHaxe(BRACE, movedBrace(BRACE));
		Assert.equals(ChangeClass.Declarations, delta.change);
		Assert.same(['~ FnMember:f +1-1'], summary(delta));
	}

	/**
	 * A brace moved beside an added import is no imports-only change: a line of punctuation counts like any other, and
	 * a line's indentation with it.
	 * Killed by arm `M-DECLARATION-DELTA-BODY-TRIMMED`.
	 */
	@:pin('control')
	@:killer('M-DECLARATION-DELTA-BODY-TRIMMED')
	public function testAMovedBraceBesideAnImportIsNoImportsChange(): Void {
		final delta: FileDelta = compareHaxe(BRACE, movedBrace(BRACE.replace('import a.B;\n', 'import a.B;\nimport a.D;\n')));
		Assert.equals(ChangeClass.Declarations, delta.change);
		Assert.same(['import a.D;'], delta.headerAdded);
	}

	/**
	 * A brace moved beside a rename is no rename: the tokens a rename must explain include the punctuation.
	 * Killed by arm `M-DECLARATION-DELTA-BODY-FILTERED`.
	 */
	@:pin('control')
	@:killer('M-DECLARATION-DELTA-BODY-FILTERED')
	public function testAMovedBraceBesideARenameIsNoRename(): Void {
		final delta: FileDelta = compareHaxe(BRACE, movedBrace(BRACE).replace('function g()', 'function h()'));
		Assert.equals(ChangeClass.Declarations, delta.change);
	}

	/**
	 * `pop` renamed to `shift` at its declaration AND at `items.pop()` is no rename: that call names a method of
	 * `Array`, which a rename of the member never reaches.
	 * Killed by arm `M-DECLARATION-DELTA-RENAME-UNBOUND`.
	 */
	@:pin('control')
	@:killer('M-DECLARATION-DELTA-RENAME-UNBOUND')
	public function testAMemberAccessOfTheNameIsNoRename(): Void {
		final base: String =
			'class C {\n\tvar items: Array<Int> = [];\n\n\tpublic function pop(): Int {\n\t\treturn items.pop();\n\t}\n}\n';
		Assert.equals(ChangeClass.Declarations, compareHaxe(base, base.replace('pop', 'shift')).change);
	}

	public function testALocalRenamedAtEveryReferenceIsARename(): Void {
		final base: String = 'class C {\n\tpublic function f(): Int {\n\t\tvar x: Int = 1;\n\t\treturn x + x;\n\t}\n}\n';
		final delta: FileDelta = compareHaxe(base, base.replace('x', 'y'));
		Assert.equals(ChangeClass.Renamed, delta.change);
		Assert.same([{ from: 'x', to: 'y' }], delta.renames);
	}

	/** Two imports swapped are an imports change: of two imports of one simple name the later one binds it. */
	public function testSwappedImportsAreAnImportsChange(): Void {
		final base: String = BASE.replace('import a.B;\n', 'import a.B;\nimport c.B;\n');
		final delta: FileDelta = compareHaxe(base, BASE.replace('import a.B;\n', 'import c.B;\nimport a.B;\n'));
		Assert.equals(ChangeClass.Imports, delta.change);
		Assert.isTrue(delta.headerReordered);
		Assert.same([], delta.headerAdded);
	}

	private static function compareHaxe(base: String, now: String): FileDelta {
		return DeclarationDelta.compare(new HaxeQueryPlugin(), base, now);
	}

	/** `source` with the `if`'s closing brace moved past the call after it. */
	private static function movedBrace(source: String): String {
		return source.replace('\t\t\tfoo();\n\t\t}\n\t\tbar();\n', '\t\t\tfoo();\n\t\t\tbar();\n\t\t}\n');
	}

	/** `<status> <selector> <lines>`: `+added-removed` for a changed declaration, the lines spanned for any other. */
	private static function summary(delta: FileDelta): Array<String> {
		return [
			for (change in delta.declarations) '${change.status} ${change.selector} ${linesOf(change)}'
		];
	}

	private static function linesOf(change: DeclarationChange): String {
		return change.status == Changed ? '+${change.added}-${change.removed}' : '${change.spanLines}';
	}

}
