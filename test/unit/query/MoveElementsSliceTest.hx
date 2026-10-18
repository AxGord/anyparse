package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Address.AddressSpec;
import anyparse.query.MoveElements;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `MoveElements.moveElements` — `move-elements`: a contiguous slice of one array literal's elements moves into
 * another array literal, in another member or module, in order and with its text. Accepted cases assert the
 * whole canonical texts; refusals assert the reason they name; `verify` is driven directly with a result that
 * breaks each promise.
 */
class MoveElementsSliceTest extends Test {

	/** The source module: one list of four. */
	private static final A: String = "class A {\n\tpublic static final XS:Array<String> = ['a', 'b', 'c', 'd'];\n}\n";

	/** The destination module: one list of one. */
	private static final B: String = "class B {\n\tpublic static final YS:Array<String> = ['z'];\n}\n";

	/** Elements 2..3 leave A and are appended to B, in order; the digest is the MD5 of the entries joined by newlines. */
	public function testASliceIsAppendedToAnotherModule(): Void {
		final result: Result = ok(request(A, 2, 3, B, { select: 'FinalMember:YS' }));
		Assert.equals("class A {\n\tpublic static final XS:Array<String> = ['a', 'd'];\n}\n", result.source);
		Assert.equals("class B {\n\tpublic static final YS:Array<String> = ['z', 'b', 'c'];\n}\n", result.dest);
		Assert.same(["'b'", "'c'"], result.entries);
		Assert.equals(MoveElements.digestOf(["'b'", "'c'"]), result.digest);
		Assert.equals(32, result.digest.length);
	}

	/** `--sorted` puts each entry at its place in a sorted target. */
	public function testSortedEntriesLandAtTheirPlaces(): Void {
		final target: String = "class B {\n\tpublic static final YS:Array<String> = ['a', 'bb', 'e'];\n}\n";
		final result: Result = ok(request(A, 2, 4, target, { select: 'FinalMember:YS' }, true));
		Assert.equals("class B {\n\tpublic static final YS:Array<String> = ['a', 'b', 'bb', 'c', 'd', 'e'];\n}\n", result.dest);
		Assert.equals("class A {\n\tpublic static final XS:Array<String> = ['a'];\n}\n", result.source);
	}

	/** Two arrays of one file: the slice moves between members, one text comes back. */
	public function testASliceMovesBetweenMembersOfOneFile(): Void {
		final source: String =
			"class A {\n\tpublic static final XS:Array<String> = ['a', 'b', 'c'];\n\n\tpublic static final YS:Array<String> = ['z'];\n}\n";
		final result: Result = ok(request(source, 1, 2, null, { select: 'FinalMember:YS' }));
		Assert.equals(
			"class A {\n\tpublic static final XS:Array<String> = ['c'];\n\n\tpublic static final YS:Array<String> = ['z', 'a', 'b'];\n}\n",
			result.source
		);
		Assert.isNull(result.destOrNull);
	}

	/** The whole list may move, leaving `[]`. */
	public function testTheWholeListLeavesAnEmptyArray(): Void {
		final result: Result = ok(request(A, 1, 4, B, { select: 'FinalMember:YS' }));
		Assert.equals('class A {\n\tpublic static final XS:Array<String> = [];\n}\n', result.source);
		Assert.equals("class B {\n\tpublic static final YS:Array<String> = ['z', 'a', 'b', 'c', 'd'];\n}\n", result.dest);
	}

	/** A one-per-line list gives back the lines the slice held, and no blank one. */
	@:pin('control')
	@:killer('M-REMOVE-COMMA-LINE-KEPT')
	public function testAOnePerLineSliceTakesItsLines(): Void {
		final result: Result = ok(request(tall(['first', 'second', 'third', 'fourth']), 2, 3, B, { select: 'FinalMember:YS' }));
		Assert.equals(tall(['first', 'fourth']), result.source);
	}

	/** A leading doc travels with the slice's first element. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-DOC-STAYS')
	public function testALeadingDocTravelsWithTheSlice(): Void {
		final source: String = tall(['first', 'second', 'third'])
			.replace("\t\t'unit.second", "\t\t/** The second group. */\n\t\t'unit.second");
		final result: Result = ok(request(source, 2, 2, B, { select: 'FinalMember:YS' }));
		Assert.isFalse(result.source.contains('second group'), 'the doc left the source');
		Assert.isTrue(result.dest.contains('/** The second group. */'), 'and arrived with its element: ${result.dest}');
	}

	/** A range outside the array is refused. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-RANGE-UNCHECKED')
	public function testARangeOutsideTheArrayIsRefused(): Void {
		refused(request(A, 3, 5, B, { select: 'FinalMember:YS' }), 'outside the 4 element(s)');
		refused(request(A, 3, 2, B, { select: 'FinalMember:YS' }), 'outside');
	}

	/** An element reading a local is refused, named by its index. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-READS-UNCHECKED')
	public function testAnElementReadingANameIsRefused(): Void {
		final source: String = "class A {\n\tstatic function f(p:String):Array<String> {\n\t\treturn ['a', p];\n\t}\n}\n";
		refused(request(source, 2, 2, B, { select: 'FinalMember:YS' }, false, { match: "['a', p]" }), 'element 2 reads `p`');
	}

	/** Across modules, an element naming a project type is refused; a std type moves. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-UNSEEN-TYPE')
	public function testAnElementNamingAProjectTypeIsRefusedAcrossModules(): Void {
		final source: String = 'class A {\n\tpublic static final XS:Array<Dynamic> = [new Foo(), new StringBuf()];\n}\n';
		final target: String = 'class B {\n\tpublic static final YS:Array<Dynamic> = [];\n}\n';
		refused(request(source, 1, 1, target, { select: 'FinalMember:YS' }), '`Foo`');
		final result: Result = ok(request(source, 2, 2, target, { select: 'FinalMember:YS' }));
		Assert.isTrue(result.dest.contains('[new StringBuf()]'), 'a std type moves');
	}

	/** The source and target may not be one array. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-NESTS-UNCHECKED')
	public function testOneArrayIsRefused(): Void {
		refused(request(A, 1, 1, null, { select: 'FinalMember:XS' }), 'nests');
	}

	/** A target address by position cannot survive the cut. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-TARGET-POSITION')
	public function testATargetPositionIsRefused(): Void {
		refused(request(A, 1, 1, B, { at: '2:40' }), 'does not survive the cut');
	}

	/** An address naming no array is refused with what it names. */
	public function testANonArrayAddressIsRefused(): Void {
		refused(request(A, 1, 1, B, { select: 'ClassDecl:B' }), 'not an array literal');
	}

	/** `--sorted` keeps that mode's refusals: a non-string entry. */
	public function testSortedKeepsItsRefusals(): Void {
		final source: String = 'class A {\n\tpublic static final XS:Array<Int> = [1, 2];\n}\n';
		refused(request(source, 1, 1, B, { select: 'FinalMember:YS' }, true), 'not a constant string');
	}

	/** `verify` refuses a source that does not lose exactly the slice. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-SOURCE-UNVERIFIED')
	public function testVerifyCatchesASourceThatKeptTheSlice(): Void {
		final check: MoveCheck = {
			oldSource: ["'a'", "'b'"],
			oldTarget: ["'z'"],
			sourceFrom: 0,
			targetFrom: 0
		};
		final req: MoveElementsRequest = request(A, 2, 2, B, { select: 'FinalMember:YS' });
		final unchanged: String = "class A {\n\tpublic static final XS:Array<String> = ['a', 'b'];\n}\n";
		final failure: Null<String> = MoveElements.verify(
			req, check, ["'b'"], unchanged, "class B {\n\tpublic static final YS:Array<String> = ['z', 'b'];\n}\n", new HaxeQueryPlugin()
		);
		Assert.isTrue(failure != null && failure.contains('source array'), 'named: $failure');
	}

	/** `verify` refuses an append that lost the slice's order. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-ORDER-UNVERIFIED')
	public function testVerifyCatchesAnAppendOutOfOrder(): Void {
		final check: MoveCheck = {
			oldSource: ["'a'", "'b'", "'c'"],
			oldTarget: ["'z'"],
			sourceFrom: 0,
			targetFrom: 0
		};
		final req: MoveElementsRequest = request(A, 2, 3, B, { select: 'FinalMember:YS' });
		final cut: String = "class A {\n\tpublic static final XS:Array<String> = ['a'];\n}\n";
		final swapped: String = "class B {\n\tpublic static final YS:Array<String> = ['z', 'c', 'b'];\n}\n";
		final failure: Null<String> = MoveElements.verify(req, check, ["'b'", "'c'"], cut, swapped, new HaxeQueryPlugin());
		Assert.isTrue(failure != null && failure.contains('in order'), 'named: $failure');
	}

	/** A one-per-line class list of `names`, each spelled `'unit.<name>'`, too long for one line. */
	private static function tall(names: Array<String>): String {
		final lines: String = [
			for (n in names) "\t\t'unit." + n + ".AVeryLongTestClassNameThatKeepsTheListOnSeveralLines'"
		].join(',\n');
		return 'class A {\n\tpublic static final XS:Array<String> = [\n$lines\n\t];\n}\n';
	}

	private static function request(
		source: String, first: Int, last: Int, dest: Null<String>, target: AddressSpec, sorted: Bool = false, ?address: AddressSpec
	): MoveElementsRequest {
		return {
			source: source,
			sourceFile: 'A.hx',
			address: address ?? { select: 'FinalMember:XS' },
			first: first,
			last: last,
			destSource: dest,
			target: target,
			sorted: sorted,
			reformat: false,
			optsJson: null,
			destOptsJson: null
		};
	}

	private static function ok(request: MoveElementsRequest): Result {
		return switch MoveElements.moveElements(request, new HaxeQueryPlugin()) {
			case Ok(source, dest, entries, digest): {
				source: source,
				dest: dest ?? '',
				destOrNull: dest,
				entries: entries,
				digest: digest
			};
			case Err(message):
				Assert.fail('expected the slice to move, got: $message');
				{
					source: '',
					dest: '',
					destOrNull: null,
					entries: [],
					digest: ''
				};
		};
	}

	private static function refused(request: MoveElementsRequest, reason: String): Void {
		switch MoveElements.moveElements(request, new HaxeQueryPlugin()) {
			case Ok(source, _, _, _):
				Assert.fail('expected a refusal naming "$reason", got:\n$source');
			case Err(message):
				Assert.isTrue(message.contains(reason), 'refusal "$message" should name "$reason"');
		}
	}

}

/** What a successful move hands back, `dest` empty when it is the source file. */
private typedef Result = {
	final source: String;
	final dest: String;
	final destOrNull: Null<String>;
	final entries: Array<String>;
	final digest: String;
}
