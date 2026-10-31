package unit.query;

import anyparse.query.GrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.OwnerIndex;
import anyparse.query.cli.CliArgs;
import unit.cli.CliFixture;

/**
 * `OwnerIndex`: which declaration answers a question asked in words — its terms, the sentence and the owned question it
 * reads off a doc, the ranking, and the campaign's duplicated questions answered by their owners in the project's own source.
 */
class OwnerIndexTest extends Test {

	/** How far down the ranking an owner may sit and still be found. */
	private static inline final TOP: Int = 3;

	/** A duplicated question, worded as its owner's doc states it, and the type that owns its answer. */
	private static final OWNED: Array<{ question: String, owner: String }> = [
		{ question: 'the identity path of a file, so two spellings key alike', owner: 'FileIdentity' },
		{ question: 'can a call or a region change what a local reads', owner: 'UnchangedLocal' },
		{ question: 'a warm compiler server pool for the typechecks of one run', owner: 'OracleServerPool' },
		{ question: 'is a call effect-free', owner: 'StdlibPurity' },
		{ question: 'which declaration does a simple type name bind', owner: 'TypeNameBinding' },
		{ question: 'is the value of a block\'s last statement used', owner: 'TailValueScan' }
	];

	/** Identifiers split at case and digit edges, stop words drop, and a plural or `-ing` form meets its base word. */
	public function testTermsSplitIdentifiersAndMeetTheBaseWord(): Void {
		Assert.same(['fil', 'identity', 'real', 'path'], OwnerIndex.terms('FileIdentity.realPath'));
		Assert.same(['http', 'server', '64'], OwnerIndex.terms('HTTPServer64'));
		Assert.same(OwnerIndex.terms('read path'), OwnerIndex.terms('the reading of the paths'));
	}

	/** A sentence ends at a stop a space follows, never inside a backquoted span or after `e.g`. */
	public function testFirstSentenceSkipsCodeAndAbbreviations(): Void {
		Assert.equals('Reads `a.b`, e.g. the head.', OwnerIndex.firstSentence('Reads `a.b`, e.g. the head. Then more.'));
		Assert.equals('No stop at all', OwnerIndex.firstSentence('No stop at all'));
	}

	@:pin('control') @:killer('M-OWNER-QUESTION-UNREAD')
	public function testTheOwnedQuestionIsTheQuotedTextAfterThePhrase(): Void {
		Assert.equals('which file is this path?', OwnerIndex.ownedQuestion('The one answer to "which file is this path?": all ask.'));
		Assert.isNull(OwnerIndex.ownedQuestion('The one answer to `which`, unquoted.'));
		Assert.isNull(OwnerIndex.ownedQuestion('Answers nothing in particular.'));
	}

	/** `owned` lists every declaration whose doc states its question, ordered by the question. */
	@:pin('control') @:killer('M-OWNER-QUESTION-UNREAD')
	public function testOwnedListsTheStatedQuestionsInOrder(): Void {
		final owners: OwnerIndex = ownersOf([
			{ file: 'src/a/Z.hx', source: 'package a;\n\n/** The one answer to "which zone is this?". */\nclass Z {}\n' },
			{
				file: 'src/a/Y.hx',
				source: 'package a;\n\nclass Y {\n\t/** The one answer to "are all keys alike?". */\n\tpublic function keys():Void {}\n}\n'
			},
			{ file: 'src/a/X.hx', source: 'package a;\n\n/** Plain prose, no question. */\nclass X {}\n' }
		]);
		Assert.same(['Y.keys', 'Z'], [for (entry in owners.owned()) OwnerIndex.nameOf(entry)]);
		Assert.same(['are all keys alike?', 'which zone is this?'], [for (entry in owners.owned()) entry.question]);
	}

	/** A declaration whose NAME shares no word with the question is still found by what its doc says, with its line. */
	@:pin('control') @:killer('M-OWNER-DOC-BLIND')
	public function testTheDocAloneFindsADeclaration(): Void {
		final owners: OwnerIndex = ownersOf([
			{
				file: 'src/a/Resolver.hx',
				source: 'package a;\n\nclass Resolver {\n\t/**\n\t * Keys every file by its identity path.\n\t * Second sentence.\n\t */\n'
				+ '\tpublic static function canon():Void {}\n}\n'
			},
			{ file: 'src/a/Other.hx', source: 'package a;\n\nclass Other {}\n' }
		]);
		final hits: Array<OwnerHit> = owners.rank('the identity path of a file', 5);
		Assert.equals(1, hits.length);
		if (hits.length == 0) return;
		Assert.equals('Resolver.canon', OwnerIndex.nameOf(hits[0].entry));
		Assert.equals(8, hits[0].entry.line);
		Assert.equals('Keys every file by its identity path.', hits[0].entry.summary);
	}

	/** A word few declarations carry outranks a common one, so the rare `identity` beats the everywhere `node`. */
	@:pin('control') @:killer('M-OWNER-RARITY-BLIND')
	public function testARareWordOutranksACommonOne(): Void {
		final owners: OwnerIndex = ownersOf([
			{ file: 'src/a/A.hx', source: 'package a;\n\nclass NodeHolder {}\n' },
			{ file: 'src/a/B.hx', source: 'package a;\n\nclass IdentityMap {}\n' },
			{ file: 'src/a/C.hx', source: 'package a;\n\n/** A node visitor. */\nclass C {}\n' },
			{ file: 'src/a/D.hx', source: 'package a;\n\n/** A node printer. */\nclass D {}\n' },
			{ file: 'src/a/E.hx', source: 'package a;\n\n/** A node counter. */\nclass E {}\n' }
		]);
		final hits: Array<OwnerHit> = owners.rank('node identity', 2);
		Assert.same(['IdentityMap', 'NodeHolder'], [for (hit in hits) OwnerIndex.nameOf(hit.entry)]);
	}

	/** Of two equal matches, the type other files name in their code ranks first; a name in a comment counts for nothing. */
	@:pin('control') @:killer('M-OWNER-MENTIONS-UNCOUNTED') @:killer('M-OWNER-MENTIONS-IN-COMMENTS')
	public function testATypeOtherFilesNameOutranksAnEqualMatch(): Void {
		final owners: OwnerIndex = ownersOf([
			{ file: 'src/a/A.hx', source: 'package a;\n\nclass PathAlpha {}\n' },
			{ file: 'src/a/B.hx', source: 'package a;\n\nclass PathBeta {}\n' },
			{ file: 'src/a/C.hx', source: 'package a;\n\nclass User {\n\tvar p:PathBeta;\n}\n' },
			{
				file: 'src/a/D.hx',
				source: 'package a;\n\n// PathAlpha, named in a comment only.\nclass Prose {\n\tvar s:String = "PathAlpha";\n}\n'
			}
		]);
		Assert.same(['PathBeta', 'PathAlpha'], [for (hit in owners.rank('path', 2)) OwnerIndex.nameOf(hit.entry)]);
	}

	/** Of two equal matches, the declaration whose doc states the question it owns ranks first. */
	@:pin('control') @:killer('M-OWNER-OWNED-UNBONUSED')
	public function testAnOwnedQuestionOutranksAnEqualMatch(): Void {
		final owners: OwnerIndex = ownersOf([
			{ file: 'src/a/A.hx', source: 'package a;\n\nclass ZoneBeta {}\n' },
			{ file: 'src/a/B.hx', source: 'package a;\n\n/** The one answer to "zone". */\nclass ZoneAlpha {}\n' }
		]);
		Assert.same(['ZoneAlpha', 'ZoneBeta'], [for (hit in owners.rank('zone', 2)) OwnerIndex.nameOf(hit.entry)]);
	}

	/**
	 * Each question a review found answered twice — a copy written beside the component that owned it — finds that owner,
	 * the type or one of its members, among the first few declarations the project's `src` ranks.
	 */
	@:pin('control') @:killer('M-OWNER-TERMS-EMPTY')
	public function testEachDuplicatedQuestionFindsItsOwnerOnThisTree(): Void {
		#if (sys || nodejs)
		final io: ResolvedInputs = CliArgs.resolveInputPaths('haxe', ['${CliFixture.repoRoot()}/src']);
		final files: Array<{ file: String, source: String }> = [
			for (path in io.paths)
				{
					file: path,
					source: sys.io.File.getContent(path)
				}
		];
		final owners: OwnerIndex = OwnerIndex.build(IndexScope.over(files, io.plugin), io.plugin);
		for (asked in OWNED) {
			final top: Array<String> = [for (hit in owners.rank(asked.question, TOP)) hit.entry.type];
			Assert.isTrue(top.contains(asked.owner), '"${asked.question}" ranks ${top.join(', ')}, not ${asked.owner}');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function ownersOf(files: Array<{ file: String, source: String }>): OwnerIndex {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		return OwnerIndex.build(IndexScope.over(files, plugin), plugin);
	}

}
