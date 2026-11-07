package unit.dev;

import dev.LintNew;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `dev.LintNew`: the lint row of the slice gate run alone against a base commit, over a scratch git tree whose `hxq` is a
 * stand-in reporting each `FIXME` comment as a finding and comparing two reports as the engine's multiset does - only a finding
 * the base does not hold is new, whatever line it stands on.
 */
@:nullSafety(Strict)
final class LintNewTest extends Test {

	private static inline final MODULE: String =
		'class A {\n\tvar a: Int;\n\tvar b: Int;\n\tvar c: Int;\n\tvar d: Int;\n\tfunction f(x) { return x; } // FIXME one\n}\n';

	/** The stand-in engine: `lint` reports a `FIXME` per line, `lint-diff` the multiset difference of two reports. */
	private static final FAKE_ENGINE: Array<String> = [
		'const fs = require("fs");',
		'const a = process.argv.slice(2);',
		'fs.appendFileSync(process.env.LINT_NEW_ARGS, a.join(" ") + "\\n");',
		'if (a[0] === "lint") {',
		'  const out = [];',
		'  for (const f of a.slice(1).filter(x => !x.startsWith("--") && x !== "json")) {',
		'    fs.readFileSync(f, "utf8").split("\\n").forEach((l, i) => {',
		'      const m = /FIXME (.*)/.exec(l);',
		'      if (m) out.push({ file: f, line: i + 1, col: 1, severity: "info", rule: "fake", message: "fixme " + m[1] });',
		'    });',
		'  }',
		'  console.log(JSON.stringify(out, null, 1));',
		'} else if (a[0] === "lint-diff") {',
		'  const read = o => JSON.parse(fs.readFileSync(a[a.indexOf(o) + 1], "utf8"));',
		'  const count = rs => { const m = new Map(); rs.forEach(r => { const k = r.file + " " + r.rule + " " + r.message; m.set(k, ('
			+ 'm.get(k) || 0) + 1); }); return m; };',
		'  const o = count(read("--old")), n = count(read("--new")), add = [], rem = [];',
		'  n.forEach((c, k) => { for (let i = o.get(k) || 0; i < c; i++) add.push(k); });',
		'  o.forEach((c, k) => { for (let i = n.get(k) || 0; i < c; i++) rem.push(k); });',
		'  console.log("lint-diff: " + add.length + " added / " + rem.length + " removed");',
		'  add.forEach(k => console.log("  + " + k));',
		'  rem.forEach(k => console.log("  - " + k));',
		'}'
	];

	/** A line a finding stands on may change, a finding the base held is still not new. */
	@:pin('control')
	@:killer('M-LINT-NEW-BASE-BLIND')
	public function testAFindingOnAChangedLineThatTheBaseHeldIsNotNew(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			File.saveContent(scratch.file('src/A.hx'), MODULE.replace('f(x) { return x; }', 'f(y) { return y; }'));
			Assert.equals(0, scratch.lintNew(['HEAD'], true));
		});
	}

	/** A finding the base does not hold is refused, and the report names it. */
	@:pin('control')
	@:killer('M-LINT-NEW-ADDED-IGNORED')
	public function testAFindingTheBaseDidNotHoldIsNew(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			File.saveContent(scratch.file('src/A.hx'), '$MODULE// FIXME two\n');
			Assert.equals(1, scratch.lintNew(['HEAD'], true));
			Assert.stringContains('fixme two', File.getContent(Path.join([scratch.logs, 'lint-touched.txt'])));
		});
	}

	/** A moved file is compared with the findings it had at its old path. */
	@:pin('control')
	@:killer('M-LINT-NEW-MOVE-BLIND')
	public function testAMovedFilesFindingsAreComparedAtItsOldPath(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			cmd('git mv src/A.hx src/B.hx').at(scratch.tree).check();
			File.saveContent(scratch.file('src/B.hx'), MODULE.replace('return x;', 'return x + 0;'));
			Assert.equals(0, scratch.lintNew(['HEAD'], true));
		});
	}

	/** The base is the commit named: a finding a commit added is new against its parent and not against itself. */
	@:pin('control')
	@:killer('M-LINT-NEW-BASE-IGNORED')
	public function testTheBaseIsTheCommitNamed(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			File.saveContent(scratch.file('src/A.hx'), '$MODULE// FIXME two\n');
			cmd('git add -A').at(scratch.tree).check();
			cmd('git -c user.name=t -c user.email=t@t commit -q -m slice').at(scratch.tree).check();
			Assert.equals(1, scratch.lintNew(['HEAD~1'], true));
			Assert.equals(0, scratch.lintNew(['HEAD'], true));
		});
	}

	/** `--no-oracle` reaches both lints, the tree's and the base's; without it neither is told. */
	@:pin('control')
	@:killer('M-LINT-NEW-ORACLE-ALWAYS')
	public function testNoOracleReachesBothLints(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			File.saveContent(scratch.file('src/A.hx'), MODULE.replace('return x;', 'return x + 0;'));
			for (cheap in [true, false]) {
				File.saveContent(scratch.argsLog, '');
				Assert.equals(0, scratch.lintNew(['HEAD'], cheap));
				final lints: Array<String> = File.getContent(scratch.argsLog).split('\n').filter(l -> l.startsWith('lint '));
				Assert.equals(2, lints.length);
				Assert.isTrue(lints.foreach(l -> l.contains('--no-oracle') == cheap), '$cheap: $lints');
			}
		});
	}

	/** A move not yet staged (a filesystem move) is compared with the findings the file had at its old path, as after the commit. */
	@:pin('control')
	@:killer('M-LINT-NEW-UNSTAGED-MOVE-BLIND')
	public function testAnUnstagedMoveIsComparedAtItsOldPath(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			FileSystem.rename(scratch.file('src/A.hx'), scratch.file('src/B.hx'));
			File.saveContent(scratch.file('src/B.hx'), MODULE.replace('return x;', 'return x + 0;'));
			Assert.equals(0, scratch.lintNew(['HEAD'], true));
		});
	}

	/** Reading a tree's changes leaves the caller's index as it was: nothing the caller had not staged is staged afterwards. */
	@:pin('control')
	@:killer('M-LINT-NEW-OWN-INDEX-STAGED')
	public function testTheCallersIndexIsLeftAlone(): Void {
		TempDir.with(dir -> {
			final scratch: Scratch = scratchOf(dir);
			FileSystem.rename(scratch.file('src/A.hx'), scratch.file('src/B.hx'));
			Assert.equals(0, scratch.lintNew(['HEAD'], true));
			Assert.equals('', cmd('git diff --cached --name-only').at(scratch.tree).check().out.trim());
			Assert.stringContains('src/B.hx', cmd('git ls-files --others --exclude-standard').at(scratch.tree).check().out);
		});
	}

	/**
	 * A git tree holding `src/A.hx` (`MODULE`, one finding) as its base
	 * commit, the files `LintNew` wants of a tree, and the stand-in `hxq`.
	 */
	private static function scratchOf(dir: TempDir): Scratch {
		final tree: String = dir.file('tree');
		final logs: String = dir.file('logs');
		final argsLog: String = dir.file('args.log');
		final fake: String = dir.file('engine.js');
		File.saveContent(fake, FAKE_ENGINE.join('\n'));
		for (sub in ['src', 'bin', 'tools']) FileSystem.createDirectory(Path.join([tree, sub]));
		File.saveContent(Path.join([tree, 'tools/dev.hxml']), '');
		for (hxml in ['bin/apq-js-common.hxml', 'bin/apq-js.hxml']) File.saveContent(Path.join([tree, hxml]), '');
		File.saveContent(Path.join([tree, 'src/A.hx']), MODULE);
		File.saveContent(Path.join([tree, 'bin/hxq']), 'LINT_NEW_ARGS=$argsLog exec node $fake "$$@"\n');
		cmd('git init -q -b main').at(tree).check();
		cmd('git add -A').at(tree).check();
		cmd('git -c user.name=t -c user.email=t@t commit -q -m base').at(tree).check();
		return {
			tree: tree,
			logs: logs,
			argsLog: argsLog,
			file: name -> Path.join([tree, name]),
			lintNew: (args, cheap) -> LintNew.main(args.concat(['--tree', tree, '--logs', logs]).concat(cheap ? ['--no-oracle'] : []))
		};
	}

}

/** A scratch tree of `LintNewTest`: where it is, where its lints report, what its `hxq` was asked, and `dev lint-new` over it. */
typedef Scratch = {
	var tree: String;
	var logs: String;
	var argsLog: String;
	var file: String -> String;
	var lintNew: (Array<String>, Bool) -> Int;
}
