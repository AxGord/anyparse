package unit.query;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The doc-ownership census of the MOVE / EXTRACT family — measured, because the
 * brief that ordered it had the membership wrong, and so did the body comment in
 * `RefactorSupport.canonicalize` that this commit corrects alongside it.
 *
 * THREE ops build their result with `RefactorSupport.applyEdits` and so never
 * reach the `docSplittingEdit` guard: `MoveMember` (`move-member`), `MoveSymbol`
 * (`move`) and `InheritanceMove` (`pull-up` / `push-down`). The other three the
 * brief named DO reach it — `ExtractInterface`, `ExtractSuperclass` and
 * `IntroduceParameterObject` all go through `RefactorSupport.editKeepingCanonical`,
 * whose body is `canonicalize(source, edits, false, …)` — and `NewFile` has no
 * edit list at all, it round-trips a whole file.
 *
 * The guard finds nothing on either side, and the reason is the OFFSETS rather
 * than the routing: every insertion the family makes lands at the END of a member
 * list (the byte after it is the closing brace of the type) or at the END of the
 * module (the byte after it is EOF), its header splices (` extends X`,
 * ` implements X`) carry no line break, and a carried `import` is seated above the
 * first declaration and its leading trivia — while `docSplittingEdit` refuses only
 * a zero-width, newline-carrying insert whose FOLLOWING byte opens a declaration.
 * That is a property of the offsets, so it is pinned by outcome here rather than
 * argued: a future offset change that starts landing between a doc and its owner
 * flips one of these.
 *
 * The probe backing the cells (`docAbove`) is itself checked by
 * `testTheDocOwnerProbeDiscriminates`, which feeds it the historical
 * `add-element --before` corruption and requires it to report the stolen
 * ownership — without that, the green cells would prove nothing.
 *
 * Each cell is green at base BY CONSTRUCTION; the arm that kills it is a family op
 * whose cut or insert offset stops clearing the neighbouring doc.
 */
class MoveExtractDocCensusTest extends Test {

	/**
	 * A member-level source: the mover framed by a documented neighbour above and below.
	 */
	private static final SRC: String = 'package;\n\nclass Src {\n\t/** Doc for above. */\n\tpublic static function above():Int {\n'
		+ '\t\treturn 0;\n\t}\n\n\t/** Doc for mover. */\n\tpublic static function mover():Int {\n\t\treturn 1;\n'
		+ '\t}\n\n\t/** Doc for below. */\n\tpublic static function below():Int {\n\t\treturn 2;\n\t}\n}\n';

	/**
	 * A member-level destination whose last member is documented, so an append lands under a doc.
	 */
	private static final DST: String = 'package;\n\nclass Dst {\n\t/** Doc for first. */\n\tpublic static function first():Int {\n'
		+ '\t\treturn 10;\n\t}\n\n\t/** Doc for last. */\n\tpublic static function last():Int {\n' + '\t\treturn 11;\n\t}\n}\n';

	/** Three module-level typedefs: their spans are GREEDY, so A's span ends AFTER Mover's doc. */
	private static final MODULE: String = 'package;\n\n/** Doc for A. */\ntypedef A = {\n\tfinal a:Int;\n}\n\n/** Doc for Mover. */\n'
		+ 'typedef Mover = {\n\tfinal m:Int;\n}\n\n/** Doc for Z. */\ntypedef Z = {\n\tfinal z:Int;\n}\n';

	/**
	 * A module-level destination whose only type is documented.
	 */
	private static final MODULE_DEST: String = 'package;\n\n/** Doc for D1. */\ntypedef D1 = {\n\tfinal d:Int;\n}\n';

	/**
	 * The pull-up target: one documented member, so the pulled one is appended under a doc.
	 */
	private static final BASE: String =
		'package;\n\n/** Doc for Base. */\nclass Base {\n\t/** Doc for bLast. */\n\tpublic function bLast():Int {\n\t\treturn 2;\n\t}\n}\n';

	/**
	 * The pull-up source: the mover framed by a documented neighbour above and below.
	 */
	private static final SUB: String = 'package;\n\n/** Doc for Sub. */\nclass Sub extends Base {\n\t/** Doc for sFirst. */\n'
		+ '\tpublic function sFirst():Int {\n\t\treturn 3;\n\t}\n\n\t/** Doc for mover. */\n'
		+ '\tpublic function mover():Int {\n\t\treturn 4;\n\t}\n\n\t/** Doc for sLast. */\n'
		+ '\tpublic function sLast():Int {\n\t\treturn 5;\n\t}\n}\n';

	/**
	 * The extract-superclass source, framed the same way.
	 */
	private static final EXTRACT_SRC: String = 'package;\n\n/** Doc for E. */\nclass E {\n\t/** Doc for above. */\n'
		+ '\tpublic function above():Int {\n\t\treturn 0;\n\t}\n\n\t/** Doc for mover. */\n'
		+ '\tpublic function mover():Int {\n\t\treturn 1;\n\t}\n\n\t/** Doc for below. */\n'
		+ '\tpublic function below():Int {\n\t\treturn 2;\n\t}\n}\n';

	/**
	 * A module whose LAST declaration is documented — what the appended typedef follows.
	 */
	private static final IPO: String = 'package;\n\n/** Doc for Ipo. */\nclass Ipo {\n\t/** Doc for f. */\n'
		+ '\tpublic static function f(x:Int, y:Int, z:Int):Int {\n\t\treturn x + y + z;\n\t}\n}\n\n'
		+ '/** Doc for Tail. */\ntypedef Tail = {\n\tfinal t:Int;\n}\n';

	/** The historical `add-element --before` corruption: the insert took R's doc. */
	private static final STOLEN: String = 'package;\n\n/** Doc for R. */\nusing StringTools;\n\nclass R {}\n';

	/** The same file with the insert placed above the doc, where it belongs. */
	private static final INTACT: String = 'package;\n\nusing StringTools;\n\n/** Doc for R. */\nclass R {}\n';

	/** A PLAIN block comment above the declaration — a close on that line that is not a doc close. */
	private static final PLAIN_BLOCK: String = 'package;\n\n/** earlier doc */\nclass Q {}\n\n/* plain */\nclass R {}\n';

	public function testTheDocOwnerProbeDiscriminates(): Void {
		// DETECTION PROOF for the five cells below: fed a file whose doc was re-attributed
		// by an insert, the probe must report the theft in BOTH directions — the doc found
		// on the insert, and none left on the declaration it belonged to. A probe that
		// answered null everywhere, or matched anything, would make every other assertion
		// in this class vacuous.
		Assert.equals('/** Doc for R. */', docAbove(STOLEN, 'using StringTools'), 'the probe sees a doc that landed on the insert');
		Assert.isNull(docAbove(STOLEN, 'class R'), 'and sees that the declaration it documented now has none');
		Assert.equals('/** Doc for R. */', docAbove(INTACT, 'class R'), 'and reads the sound arrangement correctly');
		// A plain `/* … */` closes on the line above too. Without the intervening-close
		// test the probe walked back past `class Q {}` to an EARLIER doc and answered a
		// span covering both — a WRONG owner rather than no owner, the failure mode that
		// makes a census cell lie instead of fail.
		Assert.isNull(docAbove(PLAIN_BLOCK, 'class R'), 'a plain block comment above a declaration is not its doc');
		Assert.equals('/** earlier doc */', docAbove(PLAIN_BLOCK, 'class Q'), 'and the earlier doc still reads against its own owner');
	}

	public function testMoveMemberCarriesTheMemberDocAndLeavesNeighbours(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('doccensus', [{ name: 'Src.hx', source: SRC }, { name: 'Dst.hx', source: DST }]);
		Assert.equals(0, Cli.run(['move-member', '$dir/Src.hx', 'mover', '--to', 'Dst', '--scope', dir, '--write']), 'the move lands');
		final src: String = File.getContent('$dir/Src.hx');
		final dst: String = File.getContent('$dir/Dst.hx');
		Assert.equals('/** Doc for mover. */', docAbove(dst, 'function mover'), 'the moved member arrives with its own doc');
		Assert.equals('/** Doc for last. */', docAbove(dst, 'function last'), 'the destination member it was appended after keeps its doc');
		Assert.equals('/** Doc for above. */', docAbove(src, 'function above'), 'the source neighbour above keeps its doc');
		Assert.equals('/** Doc for below. */', docAbove(src, 'function below'), 'the source neighbour below keeps its doc');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMoveTypeCarriesItsDocAcrossTheGreedyModuleSpan(): Void {
		#if (sys || nodejs)
		// The span asymmetry that hid the `add-element --after` trap for so long lives
		// here: at module level `typedef A`'s span ENDS AFTER `Mover`'s doc comment, so a
		// cut or an insert measured off a raw span boundary re-attributes it.
		final dir: String = CliFixture.writeDir('doccensus', [{ name: 'M.hx', source: MODULE }, { name: 'D.hx', source: MODULE_DEST }]);
		Assert.equals(0, Cli.run([
			'move',
			'$dir/M.hx',
			'--select',
			'TypedefDecl:Mover',
			'$dir/D.hx',
			'--scope',
			dir,
			'--write'
		]), 'the move lands');
		final m: String = File.getContent('$dir/M.hx');
		final d: String = File.getContent('$dir/D.hx');
		Assert.equals('/** Doc for Mover. */', docAbove(d, 'typedef Mover'), 'the moved type arrives with its own doc');
		Assert.equals('/** Doc for D1. */', docAbove(d, 'typedef D1'), 'the destination type it was appended after keeps its doc');
		Assert.equals('/** Doc for A. */', docAbove(m, 'typedef A'), 'the source neighbour whose span swallowed the doc keeps its own');
		Assert.equals('/** Doc for Z. */', docAbove(m, 'typedef Z'), 'and the neighbour below keeps its own');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testInheritanceMoveCarriesTheMemberDoc(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('doccensus', [{ name: 'Base.hx', source: BASE }, { name: 'Sub.hx', source: SUB }]);
		Assert.equals(0, Cli.run(['pull-up', '$dir/Sub.hx', 'mover', '--to', 'Base', '--scope', dir, '--write']), 'the pull-up lands');
		final base: String = File.getContent('$dir/Base.hx');
		final sub: String = File.getContent('$dir/Sub.hx');
		Assert.equals('/** Doc for mover. */', docAbove(base, 'function mover'), 'the pulled member arrives with its own doc');
		Assert.equals(
			'/** Doc for bLast. */', docAbove(base, 'function bLast'), 'the superclass member it was appended after keeps its doc'
		);
		Assert.equals('/** Doc for sFirst. */', docAbove(sub, 'function sFirst'), 'the subclass neighbour above keeps its doc');
		Assert.equals('/** Doc for sLast. */', docAbove(sub, 'function sLast'), 'the subclass neighbour below keeps its doc');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExtractSuperclassCarriesTheCutMemberDoc(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('doccensus', [{ name: 'E.hx', source: EXTRACT_SRC }]);
		Assert.equals(0, Cli.run(['extract-superclass', '$dir/E.hx', 'SupE', '--members', 'mover', '--write']), 'the extract lands');
		final e: String = File.getContent('$dir/E.hx');
		final sup: String = File.getContent('$dir/SupE.hx');
		Assert.equals('/** Doc for mover. */', docAbove(sup, 'function mover'), 'the cut member arrives with its own doc');
		Assert.equals('/** Doc for above. */', docAbove(e, 'function above'), 'the source neighbour above keeps its doc');
		Assert.equals('/** Doc for below. */', docAbove(e, 'function below'), 'the source neighbour below keeps its doc');
		Assert.equals(
			'/** Doc for E. */', docAbove(e, 'class E extends SupE'),
			'and the type doc still documents the type the header rewrite touched'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testIntroduceParameterObjectAppendsBelowTheLastDoc(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('doccensus', [{ name: 'Ipo.hx', source: IPO }]);
		Assert.equals(0, Cli.run([
			'introduce-parameter-object',
			'$dir/Ipo.hx',
			'--select',
			'FnMember:f',
			'--params',
			'x,y',
			'--as',
			'Pair',
			'--write'
		]), 'the fold lands');
		final ipo: String = File.getContent('$dir/Ipo.hx');
		// Every prefix here has to name something only the fold can produce, or be paired
		// with one that does: `function f(` and `typedef Tail` both match the UNTRANSFORMED
		// fixture, and `docAbove` answers null for an absent prefix as well as for a
		// doc-less one — so the first draft of this cell passed with the op doing nothing.
		Assert.equals(
			'/** Doc for f. */', docAbove(ipo, 'function f(pair:Pair'),
			'the folded signature — which exists only after the op — keeps its doc'
		);
		Assert.isTrue(ipo.indexOf('typedef Pair =') >= 0, 'the generated typedef is present');
		Assert.isNull(docAbove(ipo, 'typedef Pair ='), 'and it took no doc');
		Assert.equals(
			'/** Doc for Tail. */', docAbove(ipo, 'typedef Tail'), 'the last module type keeps the doc the appended typedef followed'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The doc-comment block that ends on the line directly above the first line
	 * carrying `declPrefix`, or null when that line is not the close of one.
	 *
	 * Deliberately TEXTUAL rather than a tree walk: the question these cells ask
	 * is what a reader sees, and a re-attributed doc is by construction one the
	 * tree now agrees belongs to whatever follows it.
	 */
	private static function docAbove(source: String, declPrefix: String): Null<String> {
		final at: Int = source.indexOf(declPrefix);
		if (at < 0) return null;
		final lineStart: Int = source.lastIndexOf('\n', at) + 1;
		if (lineStart <= 1) return null;
		final prevEnd: Int = lineStart - 1;
		final prevStart: Int = source.lastIndexOf('\n', prevEnd - 1) + 1;
		if (!source.substring(prevStart, prevEnd).trim().endsWith('*/')) return null;
		final close: Int = source.lastIndexOf('*/', prevEnd);
		final open: Int = source.lastIndexOf('/**', close);
		// A PLAIN `/* … */` above the declaration also closes on that line, and its
		// opener is not a doc opener — so the nearest `/**` is some EARLIER block and
		// everything between the two is code. An intervening `*/` is what tells the two
		// apart; without this test the probe answered a span covering whole
		// declarations, which would make a census cell LIE rather than fail.
		return open < 0 || source.substring(open, close).indexOf('*/') >= 0 ? null : source.substring(open, prevEnd).trim();
	}

}
