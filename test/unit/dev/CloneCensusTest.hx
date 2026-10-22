package unit.dev;

import dev.CloneCensus;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev clone-census` over a hand-made tree whose AST is already in the `--cache` directory, so no `hxq` runs: the report
 * formats, the regex reading of a run, and the census and comparison lines, byte for byte.
 */
@:nullSafety(Strict)
final class CloneCensusTest extends Test {

	/** Four statements: two bare declarations, a call, a bare assignment. */
	private static inline final SOURCE: String = 'var a = 1;\nvar b = 2;\nfoo(a);\nx.y = \'q\';\n';

	/** The `hxq ast --json` of `SOURCE`, as far as a census reads it. */
	private static inline final AST: String = '{"file":"A.hx","tree":{"kind":"module","children":['
		+ '{"kind":"VarStmt","children":[],"span":{"start":[1,1],"end":[1,11]}},'
		+ '{"kind":"VarStmt","children":[],"span":{"start":[2,1],"end":[2,11]}},'
		+ '{"kind":"ExprStmt","children":[],"span":{"start":[3,1],"end":[3,8]}},'
		+ '{"kind":"ExprStmt","children":[],"span":{"start":[4,1],"end":[4,11]}}]}}';

	/** A type-2 report in `--flat` text: a bare run, a cross-file logic run, a bare assignment, an unresolved position. */
	private static inline final T2: String = 'A.hx:1:1: [info] 2 statements duplicated from line 9 — x (duplicate-code-renamed)\n'
		+ 'A.hx:2:1: [info] 2 statements duplicated from B.hx:5 — x (duplicate-code-renamed)\n'
		+ 'A.hx:4:1: [info] 1 statements duplicated from line 9 — x (duplicate-code-renamed)\n'
		+ 'A.hx:7:1: [info] 2 statements duplicated from line 1 — x (duplicate-code-renamed)\n' + 'A.hx:3:1: [warning] something else\n';

	/** The same type-2 report without its cross-file finding, plus one new finding, as `--format json`. */
	private static inline final T2_AFTER: String = ' [{"file":"A.hx","line":1,"col":1,"message":"2 statements duplicated from line 9 — x"},'
		+ '{"file":"A.hx","line":4,"col":1,"message":"1 statements duplicated from line 9 — x"},'
		+ '{"file":"A.hx","line":7,"col":1,"message":"2 statements duplicated from line 1 — x"},'
		+ '{"file":"A.hx","line":3,"col":1,"message":"1 statements duplicated from line 9 — x"}]';

	private static inline final T1: String = 'A.hx:1:1: [info] 2 statements duplicated from line 9 — x (duplicate-code)\n';

	public function testBothReportFormatsReadTheSameFindings(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('t2.txt'), T2);
			File.saveContent(dir.file('t2.json'), T2_AFTER);
			final text: Array<Finding> = CloneCensus.parseReport(dir.file('t2.txt'));
			Assert.equals(4, text.length, 'a line of another severity is no finding');
			Assert.same({
				file: 'A.hx',
				line: 2,
				col: 1,
				n: 2,
				origFile: 'B.hx',
				origLine: 5,
				cross: true
			}, text[1]);
			Assert.same({
				file: 'A.hx',
				line: 1,
				col: 1,
				n: 2,
				origFile: 'A.hx',
				origLine: 9,
				cross: false
			}, text[0]);
			final json: Array<Finding> = CloneCensus.parseReport(dir.file('t2.json'));
			Assert.same([text[0], text[2], text[3]], json.slice(0, 3));
		});
	}

	public function testCensusAndComparisonLines(): Void {
		TempDir.with(dir -> {
			final root: String = dir.file('tree');
			final cache: String = dir.file('cache');
			FileSystem.createDirectory(root);
			FileSystem.createDirectory(cache);
			File.saveContent('$root/A.hx', SOURCE);
			File.saveContent('$cache/L__A.hx.json', AST);
			for (name => text in ['t2.txt' => T2, 't1.txt' => T1, 't2.json' => T2_AFTER]) File.saveContent(dir.file(name), text);
			final runs: Runs = new Runs('L', root, cache);
			final t2: Array<Finding> = CloneCensus.parseReport(dir.file('t2.txt'));
			final t1: Array<Finding> = CloneCensus.parseReport(dir.file('t1.txt'));
			Assert.same([
				'[L] type-2 findings=4 families=3 occurrences=7 purely-renamed findings=1 purely-renamed families=1 '
				+ 'cross-file=1 same-file=3',
				'[L] type-1 findings=1 families=1 occurrences=2 cross-file=0',
				'[L] containment: type-1 families whose anchor is also a type-2 anchor=1 of 1',
				'[L] type-2 findings by run kind (regex): {\'bare-assign\': 1, \'bare-decl\': 1, \'logic\': 1, \'unresolved\': 1} '
				+ 'bare share=2/4 findings, 0/3 families',
				'[L] type-1 findings by run kind (regex): {\'bare-decl\': 1} bare share=1/1 findings, 1/1 families'
			], CloneCensus.census('L', t2, t1, runs));
			final removed: String = dir.file('removed.txt');
			final later: Array<Finding> = CloneCensus.parseReport(dir.file('t2.json'));
			Assert.same([
				'[L] type-2 removed=1 findings / 1 families, added=1, kept=3; '
				+ 'regex agrees: removed&bare=0 removed&logic=1 kept&bare=2 kept&logic=1',
				'[L] type-2 ADDED A.hx:3 n=1 from A.hx:9',
				'[L] type-1 removed=0 findings / 0 families, added=0, kept=1; '
				+ 'regex agrees: removed&bare=0 removed&logic=0 kept&bare=1 kept&logic=0'
			], CloneCensus.compare('L', [t2, t1], [later, t1], runs, removed));
			Assert.equals('L type-2 B.hx:5 x1 n=2 regex-logic\n', File.getContent(removed));
		});
	}

	/** Python's `str.strip` whitespace, wider than ASCII's. */
	public function testPyStripMatchesPython(): Void {
		Assert.equals('a b', CloneCensus.pyStrip(' \t a b　\x1C\n'));
		Assert.equals('a ', CloneCensus.pyStrip(' a ', true, false));
	}

}
