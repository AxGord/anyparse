package unit.lowering;

import anyparse.macro.RegexScanPlan;
import anyparse.macro.RegexScanReader;
import anyparse.macro.ScanNode;
import anyparse.runtime.StringInput;

using StringTools;

/**
 * The compiled scan a `@:re` terminal runs on the static targets, against the regex it stands in for. Every shipped
 * terminal under `anyparse.grammar` and `anyparse.format` is compiled here with the generated parsers' own lowering
 * (`ScanMatchers`), and each one the plan accepts must end every probe where the regex ends it, or miss where the regex
 * misses. The probes sit behind a word character too, so a pattern that looks behind its start fails here.
 */
@:nullSafety(Strict)
final class RegexScanPlanTest extends Test {

	/** Probes per pattern beyond the empty one. */
	private static inline final PROBES: Int = 1500;

	/** The most units one probe strings together. */
	private static inline final MAX_UNITS: Int = 6;

	/** The most extra iterations a sampled loop takes. */
	private static inline final MAX_REPEAT: Int = 3;

	/** The highest code a probe unit taken from a pattern may have. */
	private static inline final MAX_ASCII: Int = 0x7E;

	private static inline final LCG_MULTIPLIER: Float = 48271.0;
	private static inline final LCG_MODULUS: Float = 2147483647.0;

	public function testEveryShippedScanMatchesItsRegex(): Void {
		var scanned: Int = 0;
		for (matcher in shipped()) {
			final scan: Null<(input:anyparse.runtime.Input, start:Int) -> Int> = matcher.scan;
			if (scan == null) continue;
			scanned++;
			final re: EReg = new EReg('^(?:${matcher.pattern})', '');
			var hits: Int = 0;
			var mismatch: String = '';
			for (probe in probesFor(matcher.pattern)) {
				final want: Int = re.match(probe) ? re.matched(0).length : -1;
				if (want >= 0) hits++;
				final got: Int = scan(new StringInput(probe), 0);
				final shifted: Int = scan(new StringInput('x$probe'), 1);
				if (got == want && shifted == (want < 0 ? -1 : want + 1)) continue;
				mismatch = '"$probe": scan $got (behind a word character $shifted), regex $want';
				break;
			}
			Assert.equals('', mismatch, '${matcher.name} /${matcher.pattern}/');
			Assert.isTrue(hits > 0, 'no probe matched ${matcher.name}, so its comparison checked nothing');
		}
		Assert.isTrue(scanned > 0, 'no shipped terminal compiled to a scan');
	}

	/** The terminals a document is mostly made of compile to a scan; the ones the plan cannot prove stay on the regex. */
	public function testTheHotTerminalsScan(): Void {
		final scanned: Map<String, Bool> = [for (m in shipped()) m.name => m.scan != null];
		for (name in [
			'JStringLit',
			'JNumberLit',
			'JIntLit',
			'JBoolLit',
			'HxIdentLit',
			'HxDoubleStringLit',
			'HxTypeName',
			'BlockCommentLineBody',
			'BlockCommentLineWs'
		]) Assert.isTrue(scanned[name] == true, '$name should scan');
		for (name in ['HxIntLit', 'HxFloatLit', 'HxCondSigRaw']) Assert.isTrue(scanned[name] == false, '$name should stay on the regex');
	}

	public function testAcceptedShapes(): Void {
		for (pattern in [
			'[a-z][a-z0-9]*',
			'"(?:[^"\\\\]|\\\\.)*"',
			'(?!(?:if|in)\\b)[a-z]+',
			'a(?=b)',
			'[0-9]+(?:\\.[0-9]+)?',
			'(?:(?!\\*/)[^\\n])*'
		]) Assert.notNull(RegexScanPlan.of(pattern), pattern);
	}

	/** Committing to the first branch that holds is wrong when a later one could match too. */
	@:pin('control')
	@:killer('M-SCAN-ALT-OVERLAP-IGNORED')
	public function testAnOverlappingAlternationIsRefused(): Void {
		Assert.isNull(RegexScanPlan.of('a|ab'));
		Assert.isNull(RegexScanPlan.of('(?:in|if)x'));
	}

	/** A greedy loop that swallows what the rest needs has to give it back, which a committed pass cannot. */
	@:pin('control')
	@:killer('M-SCAN-LOOP-FOLLOW-IGNORED')
	public function testALoopOverlappingWhatFollowsIsRefused(): Void {
		Assert.isNull(RegexScanPlan.of('[a-z]*[a-z0-9]'));
		Assert.isNull(RegexScanPlan.of('a*(?!b)'));
	}

	public function testShapesOutsideTheReaderAreRefused(): Void {
		for (pattern in ['(a)', 'a*?', 'a{2}', '(?:a?)*', 'a|', '(?:a)\\1', '^a', 'a$', '\\x41', 'é'])
			Assert.isNull(RegexScanPlan.of(pattern), pattern);
	}

	/**
	 * Probes from a fixed seed: every ASCII character and every word the pattern spells, strung together at random, and
	 * strings sampled from the pattern's own tree, kept whole, cut short, extended or with one unit swapped in.
	 */
	private static function probesFor(pattern: String): Array<String> {
		final units: Array<String> = [' ', '\n', '\t', 'a', 'Z', '_', '0', '9', '.', '"', '\'', '\\', '}', ')', '('];
		for (i in 0...pattern.length) {
			final c: String = pattern.charAt(i);
			if (pattern.fastCodeAt(i) <= MAX_ASCII && !units.contains(c)) units.push(c);
		}
		final word: EReg = ~/[A-Za-z_]{2,}/;
		var rest: String = pattern;
		while (word.match(rest)) {
			units.push(word.matched(0));
			rest = word.matchedRight();
		}
		var seed: Float = pattern.length + 1;
		final next: (bound:Int) -> Int = bound -> {
			seed = (seed * LCG_MULTIPLIER) % LCG_MODULUS;
			return Std.int(seed) % bound;
		};
		final tree: Null<ScanNode> = RegexScanReader.read(pattern);
		final probes: Array<String> = [''];
		for (i in 0...PROBES) {
			final buf: StringBuf = new StringBuf();
			if (tree == null || i % 2 == 0) {
				for (_ in 0...next(MAX_UNITS + 1)) buf.add(units[next(units.length)]);
				probes.push(buf.toString());
				continue;
			}
			sample(tree, next, buf);
			final sampled: String = buf.toString();
			final at: Int = next(sampled.length + 1);
			probes.push( switch next(4) {
				case 0: sampled;
				case 1: sampled.substr(0, at);
				case 2: sampled + units[next(units.length)];
				case _: sampled.substr(0, at) + units[next(units.length)] + sampled.substr(at + 1);
			});
		}
		return probes;
	}

	/** Appends a string `node` consumes, its lookaheads unchecked, each character a printable one when its set has one. */
	private static function sample(node: ScanNode, next: (bound:Int) -> Int, buf: StringBuf): Void {
		switch node {
			case Chars(set):
				final printable: Array<Int> = [];
				for (range in set.ranges) for (code in range.lo ... range.hi + 1) {
					if (code > MAX_ASCII) break;
					if (code >= ' '.code || code == '\n'.code || code == '\t'.code) printable.push(code);
				}
				buf.addChar(printable.length > 0 ? printable[next(printable.length)] : set.ranges[0].lo);
			case Seq(items):
				for (item in items) sample(item, next, buf);
			case Alt(branches):
				sample(branches[next(branches.length)], next, buf);
			case Repeat(body, min, many):
				for (_ in 0...min + next(many ? MAX_REPEAT + 1 : 2)) sample(body, next, buf);
			case Ahead(_, _), WordBoundary:
		}
	}

	/** Every shipped `@:re` terminal: the grammars' own and the core trivia terminals every grammar's comments parse with. */
	private static function shipped(): Array<ScanMatcher> {
		return ScanMatchers.under('anyparse.grammar').concat(ScanMatchers.under('anyparse.format'));
	}

}
