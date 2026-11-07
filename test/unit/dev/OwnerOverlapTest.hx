package unit.dev;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.OwnerIndex;
import dev.OwnerOverlap;
import devkit.Args.UsageError;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `dev owner-overlap`: which declarations repeat a question another component already answers — the grade of one overlap,
 * what is no rival, the census over a hand-made tree, the allow-list, and the report's grouping.
 */
@:nullSafety(Strict)
final class OwnerOverlapTest extends Test {

	private static final LINES: String = 'package a;\n\nfinal class Lines {\n'
		+ '\t/** The one answer to "which line holds an offset of a text": counted from the start. */\n'
		+ '\tpublic static function lineOf(text:String, offset:Int):Int { return 1; }\n}\n';
	private static final SCANNER: String = 'package b;\n\nfinal class Scanner {\n\t/** Which line holds an offset in a text? */\n'
		+ '\tprivate static function lineNumber(text:String, offset:Int):Int { return 1; }\n'
		+ '\t/** Reads the next token from a stream of characters. */\n\tpublic static function next():Int { return 0; }\n}\n';
	private static final TABLE: String = 'package c;\n\nfinal class Table {\n'
		+ '\t/** The width of a column of a table in cells. */\n\tpublic function first():Int { return 1; }\n'
		+ '\t/** The width of a column of a table in cells. */\n\tpublic function second():Int { return 1; }\n}\n';
	private static final TWIN_A: String = 'package d;\n\nfinal class Alpha {\n'
		+ '\t/** Counts the rows of a grid held by a buffer. */\n\tpublic function count():Int { return 1; }\n}\n';
	private static final TWIN_B: String = 'package e;\n\nfinal class Beta {\n'
		+ '\t/** Counts the rows of a grid held by a buffer. */\n\tpublic function count():Int { return 1; }\n}\n';
	private static final CONFIG: OverlapConfig = OwnerOverlap.DEFAULTS;

	/**
	 * An overlap is graded by its owner: one stating the question it owns
	 * is `High`, the same wording without is `Medium`, looser wording `Low`.
	 */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-OWNED-NOT-HIGH')
	public function testAnOverlapIsGradedByTheOwnedQuestionAndTheWording(): Void {
		final mine: OwnerEntry = entry('Mine', 'f', 'Counts the lines of a text.', null);
		final owned: OwnerEntry = entry('Counter', 'count', 'Counts the lines of a text.', 'counts the lines of a text');
		final plain: OwnerEntry = entry('Plain', 'count', 'Counts the lines of a text.', null);
		final loose: OwnerEntry = entry('Loose', 'count', 'Counts the lines of a text twice.', null);
		final index: OwnerIndex = new OwnerIndex([mine, owned, plain, loose]);
		Assert.equals('high', grade(index, mine, [owned]));
		Assert.equals('medium', grade(index, mine, [plain]));
		Assert.equals('low', grade(index, mine, [loose]));
	}

	/** A candidate saying something else is no overlap, however many words it happens to share. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-THRESHOLD-BLIND')
	public function testADocSayingSomethingElseIsNoOverlap(): Void {
		final mine: OwnerEntry = entry('Mine', 'f', 'Counts the lines of a text.', null);
		final far: OwnerEntry = entry('Other', 'count', 'Reads the next token from a stream of characters, counts nothing.', null);
		final index: OwnerIndex = new OwnerIndex([mine, far]);
		Assert.isNull(OwnerOverlap.overlapOf(index, mine, [far], CONFIG.similarity));
	}

	/** A declaration of the same file is its own surroundings, never a second implementation. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-SAME-FILE-COUNTS')
	public function testADeclarationOfTheSameFileIsNoRival(): Void {
		final mine: OwnerEntry = entry('Mine', 'f', 'Counts the lines of a text.', null);
		final sibling: OwnerEntry = entry('Mine', 'g', 'Counts the lines of a text.', null);
		Assert.isFalse(OwnerOverlap.rivals(mine, sibling));
		Assert.isTrue(OwnerOverlap.rivals(mine, entry('Plain', 'g', 'Counts the lines of a text.', null)));
	}

	/** A declaration with no doc answers no question, whatever its name matched. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-UNDOCUMENTED-RIVAL')
	public function testAnUndocumentedDeclarationIsNoRival(): Void {
		final mine: OwnerEntry = entry('Mine', 'f', 'Counts the lines of a text.', null);
		Assert.isFalse(OwnerOverlap.rivals(mine, entry('Plain', 'lines', '', null)));
	}

	/** A doc naming the other's type points at a delegate or a consumer, from either end, so the pair is no rival. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-MENTION-BLIND')
	public function testADocNamingTheOtherTypeIsNoRival(): Void {
		final mine: OwnerEntry = entry('Mine', 'f', 'Counts the lines of a text, as `PlainReader` reads them.', null);
		final plain: OwnerEntry = entry('PlainReader', 'count', 'Counts the lines of a text.', null);
		Assert.isFalse(OwnerOverlap.rivals(mine, plain));
		Assert.isFalse(OwnerOverlap.rivals(plain, mine));
		Assert.isTrue(OwnerOverlap.rivals(
			entry('Mine', 'f', 'Counts the lines of a text, as `Plain` reads them.', null), entry('Plain', 'g', 'Counts lines.', null)
		));
	}

	/**
	 * A second implementation worded differently is reported against the
	 * component that owns the question; an unrelated one and a sibling are not.
	 */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-CENSUS-DROPS-ALL')
	public function testTheCensusFindsASecondImplementationInOtherWords(): Void {
		final result: Census = OwnerOverlap.census(ownersOf([LINES, SCANNER, TABLE]), [], CONFIG);
		final found: Array<String> = result.overlaps.map(o -> '${OwnerIndex.nameOf(o.entry)} -> ${OwnerIndex.nameOf(o.owner)}');
		Assert.contains('Scanner.lineNumber -> Lines.lineOf', found);
		for (name in found) {
			Assert.isFalse(name.startsWith('Scanner.next'), name);
			Assert.isFalse(name.startsWith('Table.'), name);
		}
	}

	/** A pair found from both ends is one finding, kept at the end whose owner has the smaller name. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-ECHO-KEPT')
	public function testAPairFoundFromBothEndsIsOneFinding(): Void {
		final result: Census = OwnerOverlap.census(ownersOf([TWIN_A, TWIN_B]), [], CONFIG);
		Assert.same(
			['Beta.count -> Alpha.count'], result.overlaps.map(o -> '${OwnerIndex.nameOf(o.entry)} -> ${OwnerIndex.nameOf(o.owner)}')
		);
	}

	/** An allow-list row excuses the declaration against that owner, by name or by an end-glob, and the tally counts it. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-ALLOW-BLIND')
	public function testAnAllowListRowExcusesTheDeclaredPair(): Void {
		final owners: OwnerIndex = ownersOf([LINES, SCANNER]);
		final named: Array<Allowed> =
			OwnerOverlap.parseAllowed('# independent\nScanner.lineNumber\tLines.lineOf\ta hand scanner by design\n');
		final result: Census = OwnerOverlap.census(owners, named, CONFIG);
		Assert.isFalse(result.overlaps.exists(o -> OwnerIndex.nameOf(o.entry) == 'Scanner.lineNumber'));
		Assert.equals(1, result.excused);
		final glob: Census = OwnerOverlap.census(owners, OwnerOverlap.parseAllowed('Scan*\t*\tall of it\n'), CONFIG);
		Assert.isFalse(glob.overlaps.exists(o -> o.entry.type == 'Scanner'));
		final other: Census = OwnerOverlap.census(
			owners, OwnerOverlap.parseAllowed('Scanner.lineNumber\tOther.*\tnot this owner\n'), CONFIG
		);
		Assert.equals(0, other.excused);
	}

	/** A row naming no reason is refused, naming its line. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-ALLOW-REASON-OPTIONAL')
	public function testAnAllowListRowWithoutAReasonIsRefused(): Void {
		var message: String = '';
		try {
			OwnerOverlap.parseAllowed('# header\nA.f\tB.g\t \n');
		} catch (exception: UsageError) {
			message = exception.message;
		}
		Assert.stringContains('line 2', message);
	}

	/** A member name many types declare is an interface or registry hook, so its lookalikes are set aside and counted. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-INTERFACE-BLIND')
	public function testAMemberNameManyTypesDeclareIsSetAside(): Void {
		final narrow: OverlapConfig = {
			similarity: CONFIG.similarity,
			top: CONFIG.top,
			minTerms: CONFIG.minTerms,
			interfaceWidth: 1
		};
		final result: Census = OwnerOverlap.census(ownersOf([TWIN_A, TWIN_B]), [], narrow);
		Assert.isTrue(result.interfaceShaped > 0);
		Assert.equals(0, result.overlaps.length);
	}

	/** The report names each owner once with every declaration repeating it beneath, strongest first. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-RENDER-FORGETS-GROUP')
	public function testTheReportGroupsTheOverlapsByOwner(): Void {
		final owner: OwnerEntry = entry('Counter', 'lineOf', 'The line of an offset.', 'which line holds an offset');
		final strong: Overlap = overlap(entry('Scanner', 'lineNumber', 'The line of an offset.', null), owner, 0.9);
		final weak: Overlap = overlap(entry('Cursor', 'row', 'The line of an offset.', null), owner, 0.7);
		final lines: Array<String> = OwnerOverlap.render({
			considered: 5,
			interfaceShaped: 0,
			excused: 0,
			overlaps: [weak, strong]
		});
		Assert.equals(1, lines.filter(l -> l.startsWith('owner ')).length);
		final at: Int = [for (i in 0...lines.length) if (lines[i].startsWith('owner Counter.lineOf')) i][0];
		Assert.stringContains('[high 0.9] Scanner.lineNumber', lines[at + 1]);
		Assert.stringContains('[high 0.7] Cursor.row', lines[at + 2]);
	}

	/** A similarity floor that is no number from 0 to 1 is refused before anything is read: NaN would let every lookalike through. */
	@:pin('control')
	@:killer('M-OWNER-OVERLAP-SIMILARITY-UNCHECKED')
	public function testASimilarityThatIsNoNumberFromZeroToOneIsRefused(): Void {
		for (bad in ['x', '1.5', '-0.1']) Assert.raises(() -> OwnerOverlap.main(['/no/such/root', '--similarity', bad]), UsageError);
	}

	private static function grade(index: OwnerIndex, mine: OwnerEntry, candidates: Array<OwnerEntry>): String {
		final found: Null<Overlap> = OwnerOverlap.overlapOf(index, mine, candidates, 0.5);
		return found == null ? 'none' : found.confidence.label();
	}

	private static function overlap(entry: OwnerEntry, owner: OwnerEntry, similarity: Float): Overlap {
		return {
			entry: entry,
			owner: owner,
			similarity: similarity,
			confidence: Confidence.High
		};
	}

	private static function entry(type: String, member: String, summary: String, question: Null<String>): OwnerEntry {
		return {
			type: type,
			member: member,
			file: 'src/$type.hx',
			line: 1,
			summary: summary,
			question: question,
			nameTerms: OwnerIndex.terms(member),
			questionTerms: OwnerIndex.terms(question ?? ''),
			summaryTerms: OwnerIndex.terms(summary),
			docTerms: OwnerIndex.terms(summary),
			mentions: 0
		};
	}

	private static function ownersOf(sources: Array<String>): OwnerIndex {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [for (i => source in sources) { file: 'src/f$i.hx', source: source }];
		return OwnerIndex.build(IndexScope.over(files, plugin), plugin);
	}

}
