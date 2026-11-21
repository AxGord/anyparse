package unit.grammar.haxe;

import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * This repository's `hxformat.json` lays its comprehensions out by width (`wrapping.comprehensionFit: true`): one that
 * fits stays on one line, beside another literal argument it is one unit of the call's literal run, the construct
 * around it breaks first, and a sole block body hugs the brackets only while every generator head fits the bracket
 * line.
 */
@:nullSafety(Strict)
final class HxRepoConfigComprehensionShapeTest extends Test {

	private static final LONG_LITERAL: String =
		"' — taken inside a hold of D._l every caller keeps, whose warning at D.outer is long through the call into this one'";
	private static final FITTING: String = "[ for (v in found) if (v.family == 'B') v.message.substring(v.message.indexOf(' — ')) ]";
	private static final TAIL: String = "(builds.length == 0 ? '' : ',\"builds\":' + arr(builds)) + (";

	public function new(): Void {
		super();
	}

	/** Beside a literal too wide for one line a comprehension is one unit with it: one literal per line. */
	@:pin('control')
	@:killer('M-COMPR-RUN-GLUED')
	public function testComprehensionBesideAWideLiteralTakesItsOwnLine(): Void {
		final expected: String = inMethod(['same(', '\t[', '\t\t$LONG_LITERAL', '\t],', '\t$FITTING', ');']);
		Assert.equals(expected, repoWrite(inMethod(['same([', '\t$LONG_LITERAL', '], $FITTING);'])));
		Assert.equals(expected, repoWrite(expected));
	}

	/** A comprehension call argument that fits stays on one line; the `+` chain's last paren opens instead. */
	@:pin('control')
	@:killer('M-COMPR-FIT-NO-YIELD')
	public function testFittingComprehensionInAChainStaysWhole(): Void {
		final expected: String = inMethod([
			'return \',"meta":\' + arr([ for (m in meta) q(m.name) ]) + $TAIL',
			"\tcode.length == 0 ? '' : ',\"code\":' + arr(code)",
			');'
		]);
		final broken: String = inMethod([
			"return ',\"meta\":' + arr([",
			'\tfor (m in meta) q(m.name)',
			"]) + (builds.length == 0 ? '' : ',\"builds\":' + arr(builds)) + (code.length == 0 ? '' : ',\"code\":' + arr(code));"
		]);
		Assert.equals(expected, repoWrite(broken));
		Assert.equals(expected, repoWrite(expected));
	}

	/** The same for a chain operand: the paren after the comprehension is the seam its line breaks at. */
	@:pin('control')
	@:killer('M-YIELD-PAREN-NO-SEAM')
	public function testFittingComprehensionOperandYieldsToTheParen(): Void {
		final expected: String = inMethod([
			'return \',"meta":\' + [ for (m in meta) q(m.name) ] + $TAIL',
			"\tcode.length == 0 ? '' : ',\"code\":' + arr(code)",
			');'
		]);
		Assert.equals(expected, repoWrite(expected));
	}

	/** A head too wide for the bracket line keeps the brackets on their own lines and the head flat below `[`. */
	@:pin('control')
	@:killer('M-COMPR-HUG-HEAD-UNMEASURED')
	public function testHeadPastTheBracketLineDropsTheHug(): Void {
		final expected: String = inMethod([
			'final candidates: Array<MemberGroup> = [',
			'\tfor (sibling in membersOf(prep.srcDecl, prep.srcSource, prep.shape, plugin.lexicalRegions)) {',
			'\t\tfinal name: Null<String> = sibling.member.name;',
			'\t\tsibling;',
			'\t}',
			'];'
		]);
		final hugged: String = inMethod([
			'final candidates: Array<MemberGroup> = [ for (sibling in membersOf(',
			'\tprep.srcDecl, prep.srcSource, prep.shape, plugin.lexicalRegions',
			')) {',
			'\tfinal name: Null<String> = sibling.member.name;',
			'\tsibling;',
			'} ];'
		]);
		Assert.equals(expected, repoWrite(hugged));
		Assert.equals(expected, repoWrite(expected));
	}

	/** The hug measures the heads up to the body's `{` alone, so a fitting head hugs whatever width the body's lines take. */
	@:pin('control')
	@:killer('M-HUG-HEAD-PAST-BREAKS')
	public function testFittingHeadHugsAWideBody(): Void {
		final hugged: String = inMethod([
			'final out: Array<String> = [ for (v in found) {',
			'\tfinal data: Null<FindingData> = v.data;',
			"\tif (data != null && data.family == 'B')",
			"\t\t'${v.severity.label()} B ${data.member} | ${data.subject} | ${data.family} | ${v.message}';",
			'} ];'
		]);
		Assert.equals(hugged, repoWrite(hugged));
	}

	/** A sole call argument that fits on its own line takes that line whole rather than hugging the parentheses. */
	@:pin('control')
	@:killer('M-COMPR-SOLE-ARG-FIT-HUGS')
	public function testFittingSoleArgumentTakesItsOwnLine(): Void {
		final expected: String = inMethod([
			'final calls: Array<String> = (execution?.blockingLibraryCalls ?? []).concat(',
			"\t[ for (t in execution?.blockingLibraryTypes ?? []) '$t.*' ]",
			');'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'final calls: Array<String> = (execution?.blockingLibraryCalls ?? []).concat([',
			"\tfor (t in execution?.blockingLibraryTypes ?? []) '$t.*'",
			']);'
		])));
		Assert.equals(expected, repoWrite(expected));
	}

	/** The comprehension takes its own argument line, so the ternary argument after it stays flat and keeps the arguments after it. */
	@:pin('control')
	@:killer('M-COMPR-SOLE-ARG-FIT-HUGS')
	public function testTernaryArgumentAfterAFittingComprehensionStaysFlat(): Void {
		final expected: String = inMethod([
			'final runs: PendingRuns = ProcessSpawn.startAll([ for (a in asked) { args: a.args, cwd: a.oracle.dir } ].concat(',
			'\t[ for (b in baselines) { args: OracleCoverage.probeArgs(b.hxml, b.defines), cwd: b.dir } ]',
			'), carried ? ReachDefinesProbe.BUFFER : BUFFER, ProcessSpawn.parallelism());'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'final runs: PendingRuns = ProcessSpawn.startAll([',
			'\tfor (a in asked) { args: a.args, cwd: a.oracle.dir }',
			'].concat([ for (b in baselines) { args: OracleCoverage.probeArgs(b.hxml, b.defines), cwd: b.dir } ]), carried',
			'\t? ReachDefinesProbe.BUFFER',
			'\t: BUFFER, ProcessSpawn.parallelism());'
		])));
		Assert.equals(expected, repoWrite(expected));
	}

	/** A sole comprehension argument too wide for its own line hugs the parentheses and breaks inside its brackets. */
	@:pin('control')
	@:killer('M-COMPR-SOLE-ARG-NEVER-HUGS')
	public function testWideSoleArgumentHugsTheParen(): Void {
		final expected: String = inMethod([
			'final calls: Array<String> = (execution?.blockingLibraryCalls ?? []).concat([',
			'\tfor (t in execution?.blockingLibraryTypes ?? [])',
			'\t\tfor (u in someOtherCollection(t))',
			"\t\t\tfor (v in u.items) '$t.*$u and some more text so it does not fit'",
			']);'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'final calls: Array<String> = (execution?.blockingLibraryCalls ?? []).concat([ for (t in execution?.blockingLibraryTypes ?? '
			+ "[]) for (u in someOtherCollection(t)) for (v in u.items) '$t.*$u and some more text so it does not fit' ]);"
		])));
		Assert.equals(expected, repoWrite(expected));
	}

	/** A ternary stays glued (`c ? [] : [`) when breaking it would not let its comprehension branch fit either. */
	@:pin('control')
	@:killer('M-TERNARY-FIT-HUG-OFF')
	public function testTernaryStaysGluedForAComprehensionThatCannotFit(): Void {
		final expected: String = inMethod([
			'return seams == null ? [] : [',
			'\tfor (entry in files) for ('
			+ 'm in collect(plugin, entry.source, seams, FormatConfigDiscovery.discover(entry.file, _configNotes))) m',
			'];'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'return seams == null',
			'\t? []',
			'\t: [ for (entry in files) for ('
			+ 'm in collect(plugin, entry.source, seams, FormatConfigDiscovery.discover(entry.file, _configNotes))) m ];'
		])));
		Assert.equals(expected, repoWrite(expected));
		// It breaks when that lets the branch fit its own line.
		Assert.equals(
			inMethod([
				'return seams == null',
				'\t? []',
				'\t: [ for (entry in files) for (m in collect(plugin, entry.source, seams, FormatConfig.discover(entry.file))) m ];'
			]),
			repoWrite(inMethod([
				'return seams == null ? [] : [',
				'\tfor (entry in files) for (m in collect(plugin, entry.source, seams, FormatConfig.discover(entry.file))) m',
				'];'
			]))
		);
	}

	/** The same for a block-body comprehension whose head does not fit the bracket line: the ternary glues to its `[`. */
	@:pin('control')
	@:killer('M-TERNARY-HUG-WIDTH-ARM')
	public function testTernaryStaysGluedForABlockBodyComprehension(): Void {
		final expected: String = inMethod([
			'return seams == null ? [] : [',
			'\tfor (entry in files)',
			'\t\tfor (m in collect(plugin, entry.source, seams, FormatConfigDiscovery.discover(entry.file, _configNotes))) {',
			'\t\t\tfile: entry.file,',
			'\t\t\tspan: m.span,',
			'\t\t\trule: RULE_ID,',
			'\t\t\tseverity: Severity.Info,',
			"\t\t\tmessage: 'this single-statement lambda body can be an expression body'",
			'\t\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'return seams == null',
			'\t? []',
			'\t: [',
			'\t\tfor (entry in files) for (m in collect(',
			'\t\t\tplugin, entry.source, seams, FormatConfigDiscovery.discover(entry.file, _configNotes)',
			'\t\t)) {',
			'\t\t\tfile: entry.file,',
			'\t\t\tspan: m.span,',
			'\t\t\trule: RULE_ID,',
			'\t\t\tseverity: Severity.Info,',
			"\t\t\tmessage: 'this single-statement lambda body can be an expression body'",
			'\t\t}',
			'\t];'
		])));
		Assert.equals(expected, repoWrite(expected));
	}

	/** A head line ending exactly at the limit hugs; one column more takes `[` / the head / `]`. */
	@:pin('control')
	@:killer('M-HUG-HEAD-BOUNDARY')
	public function testHugHoldsUpToTheLineLimit(): Void {
		final expected: String = inMethod([
			'final xs: Array<Int> = [',
			'\tfor (v in foo(alpha, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {',
			'\t\tfinal y = v;',
			'\t\ty;',
			'\t}',
			'];'
		]);
		Assert.equals(expected, repoWrite(inMethod([
			'final xs: Array<Int> = [ for ('
			+ 'v in foo(alpha, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {',
			'\tfinal y = v;',
			'\ty;',
			'} ];'
		])));
		Assert.equals(expected, repoWrite(expected));
		final limit: String = inMethod([
			'final xs: Array<Int> = [ for ('
			+ 'v in foo(alpha, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {',
			'\tfinal y = v;',
			'\ty;',
			'} ];'
		]);
		Assert.equals(limit, repoWrite(inMethod([
			'final xs: Array<Int> = [',
			'\tfor (v in foo(alpha, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {',
			'\t\tfinal y = v;',
			'\t\ty;',
			'\t}',
			'];'
		])));
		Assert.equals(limit, repoWrite(limit));
	}

	private function repoWrite(src: String): String {
		return #if (sys || nodejs) HxWriteFixture.triviaWrite(src, File.getContent('hxformat.json')) #else src #end;
	}

	private static function inMethod(lines: Array<String>): String {
		return 'class C {\n\n\tfunction test() {\n\t\t${lines.join('\n\t\t')}\n\t}\n\n}';
	}

}
