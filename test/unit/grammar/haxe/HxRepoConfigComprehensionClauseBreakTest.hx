package unit.grammar.haxe;

import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * Under this repository's `hxformat.json` a comprehension whose head chain is too wide for one line breaks between its
 * clauses, one indent deeper each, with `[` and `]` on their own lines; a short iterable call is never wrapped to keep
 * the chain glued.
 */
@:nullSafety(Strict)
final class HxRepoConfigComprehensionClauseBreakTest extends Test {

	private static final CHAIN: String = 'for (outline in ProjectOutlines.symbols(files, plugin)) for (symbol in outline.symbols) '
		+ 'if (kindFilter == null || symbol.kind == kindFilter) {';

	public function new(): Void {
		super();
	}

	/** The head chain breaks between its clauses, the short iterable call stays whole, and the body hugs the last clause. */
	@:pin('control')
	@:killer('M-STRICT-CHAIN-GATE')
	public function testWideChainBreaksBetweenClauses(): Void {
		final expected: String = inMethod([
			'return [',
			'\tfor (outline in ProjectOutlines.symbols(files, plugin))',
			'\t\tfor (symbol in outline.symbols)',
			'\t\t\tif (kindFilter == null || symbol.kind == kindFilter) {',
			'\t\t\t\ta;',
			'\t\t\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(inMethod(['return [', '\t$CHAIN', '\t\ta;', '\t}', '];'])));
		Assert.equals(expected, repoWrite(expected));
	}

	/** The same chain on a `return [` that the writer produced itself on the old layout settles on the clause break. */
	@:pin('control')
	@:killer('M-STRICT-CHAIN-GATE')
	public function testWrappedIterableCallIsNotAKeptShape(): Void {
		final expected: String = inMethod([
			'return [',
			'\tfor (outline in ProjectOutlines.symbols(files, plugin))',
			'\t\tfor (symbol in outline.symbols)',
			'\t\t\tif (kindFilter == null || symbol.kind == kindFilter) {',
			'\t\t\t\ta;',
			'\t\t\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'return [',
			'\tfor (outline in ProjectOutlines.symbols(',
			'\t\tfiles, plugin',
			'\t)) for (symbol in outline.symbols) if (kindFilter == null || symbol.kind == kindFilter) {',
			'\t\ta;',
			'\t}',
			'];'
		])));
	}

	/** A nested for/for/if comprehension that fits stays on one line. */
	@:pin('guard')
	public function testFittingChainStaysOnOneLine(): Void {
		final fitting: String = inMethod([
			'final xs = [ for (o in files) for (s in o.symbols) if (kindFilter == null || s.kind == kindFilter) s ];'
		]);
		Assert.equals(fitting, repoWrite(fitting));
	}

	/** A single iterable call too wide on its own still wraps its arguments: the chain has no clause to break at. */
	@:pin('guard')
	public function testWideIterableCallStillWrapsItsArguments(): Void {
		final expected: String = inMethod([
			'return [',
			'\tfor (o in ProjectOutlines.symbolsOfEverythingInTheProjectWithAVeryLongName(',
			'\t\tfilesToScanForSymbols, pluginToUseForScanning, anotherArgument, yetAnotherArgument, moreArguments',
			'\t)) {',
			'\t\ta;',
			'\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(expected));
	}

	/** A chain whose head fits the bracket line hugs the brackets and only the body breaks. */
	@:pin('control')
	@:killer('M-STRICT-CHAIN-ALWAYS-BREAK')
	public function testFittingChainHeadHugsABlockBody(): Void {
		final hugged: String = inMethod([
			'final out: Array<Int> = [ for (o in files) for (s in o.symbols) if (s.ok) {',
			'\tfinal y = s;',
			'\ty;',
			'} ];'
		]);
		Assert.equals(hugged, repoWrite(hugged));
	}

	/** A head of two clauses keeps the iterable call whole and opens its own condition instead of wrapping the call. */
	@:pin('guard')
	public function testShortIterableCallStaysWholeBesideAWideCondition(): Void {
		final expected: String = inMethod([
			'return [',
			'\tfor (outline in ProjectOutlines.symbols(files, plugin)) if (',
			'\t\tkindFilterOfTheOutlineSymbols == null || symbol.kind == kindFilterOfTheOutlineSymbols || symbol.name == '
			+ 'aaaaaaaaaaaaaaaaaaa',
			'\t) {',
			'\t\ta;',
			'\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(expected));
	}

	/** A head of four clauses breaks after every clause, not after the first only. */
	@:pin('control')
	@:killer('M-STRICT-CHAIN-GATE')
	public function testFourClauseChainBreaksEveryClause(): Void {
		final expected: String = inMethod([
			'return [',
			'\tfor (outline in ProjectOutlines.symbols(files, plugin))',
			'\t\tfor (symbol in outline.symbols)',
			'\t\t\tfor (z in symbol.children)',
			'\t\t\t\tif (kindFilter == null || z.kind == kindFilter) {',
			'\t\t\t\t\ta;',
			'\t\t\t\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(expected));
		Assert.equals(expected, repoWrite(inMethod([
			'return [',
			'\tfor (outline in ProjectOutlines.symbols(files, plugin)) for (symbol in outline.symbols) for (z in symbol.children) '
			+ 'if (kindFilter == null || z.kind == kindFilter) {',
			'\t\ta;',
			'\t}',
			'];'
		])));
	}

	/** The chain head landing exactly on the line limit breaks every clause; one column less stays on one line. */
	@:pin('control')
	@:killer('M-STRICT-CHAIN-LIMIT-OFF-BY-ONE')
	public function testChainHeadAtTheLimitBreaksEveryClause(): Void {
		final atLimit: String = inMethod([
			'return [',
			'\tfor (o in P.s(files, plugin))',
			'\t\tfor (s in o.symbols)',
			'\t\t\tif (kindFilter == null || s.kind == ${wideName(37)}) {',
			'\t\t\t\ta;',
			'\t\t\t}',
			'];'
		]);
		Assert.equals(atLimit, repoWrite(inMethod(chainHead(37))));
		Assert.equals(atLimit, repoWrite(atLimit));
		Assert.equals(inMethod(chainHead(36)), repoWrite(inMethod(chainHead(36))));
	}

	private function repoWrite(src: String): String {
		return #if (sys || nodejs) HxWriteFixture.triviaWrite(src, File.getContent('hxformat.json')) #else src #end;
	}

	private static function inMethod(lines: Array<String>): String {
		return 'class C {\n\n\tfunction test() {\n\t\t${lines.join('\n\t\t')}\n\t}\n\n}';
	}

	private static function wideName(width: Int): String {
		return 'K' + [ for (_ in 0...width) 'x' ].join('');
	}

	private static function chainHead(width: Int): Array<String> {
		return [
			'return [',
			'\tfor (o in P.s(files, plugin)) for (s in o.symbols) if (kindFilter == null || s.kind == ${wideName(width)}) {',
			'\t\ta;',
			'\t}',
			'];'
		];
	}

}
