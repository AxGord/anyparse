package unit.dev;

import dev.LintNew;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev.LintNew` over a tree an oracle lint stored builds for: the stand-in `hxq` judges a rule that only builds can vouch for
 * when the directory it runs in holds the `stored.marker` file (the builds stored for that exact input), and holds it otherwise,
 * as the engine's `--no-oracle` run does. The tip run finds the marker and the base checkout never does, so the two runs answer
 * the rule differently unless the step makes both hold it.
 */
@:nullSafety(Strict)
final class LintNewStoredBuildsTest extends utest.Test {

	private static final MODULE: String = 'class A {\n\tvar a: Int;\n\tfunction f(x) { return x; } // HOIST one\n}\n';

	/** The stand-in engine: a `HOIST` line is a finding of `builds` only when the run judges it, a `FIXME` line always one. */
	private static final FAKE_ENGINE: Array<String> = [
		'const fs = require("fs");',
		'const a = process.argv.slice(2);',
		'if (a[0] === "lint") {',
		'  const judges = fs.existsSync("stored.marker") && !a.includes("--no-stored-builds");',
		'  const out = [];',
		'  for (const f of a.slice(1).filter(x => !x.startsWith("--") && x !== "json")) {',
		'    fs.readFileSync(f, "utf8").split("\\n").forEach((l, i) => {',
		'      if (judges && /HOIST/.test(l)) out.push({ file: f, line: i + 1, col: 1, severity: "info", rule: "builds", message: l });',
		'      if (/FIXME/.test(l)) out.push({ file: f, line: i + 1, col: 1, severity: "info", rule: "fake", message: l });',
		'    });',
		'  }',
		'  console.log(JSON.stringify(out, null, 1));',
		'} else if (a[0] === "lint-diff") {',
		'  const read = o => JSON.parse(fs.readFileSync(a[a.indexOf(o) + 1], "utf8"));',
		'  const key = r => r.file + " " + r.rule + " " + r.message;',
		'  const o = read("--old").map(key), n = read("--new").map(key);',
		'  const add = n.filter(k => !o.includes(k)), rem = o.filter(k => !n.includes(k));',
		'  console.log("lint-diff: " + add.length + " added / " + rem.length + " removed");',
		'  add.forEach(k => console.log("  + " + k));',
		'  rem.forEach(k => console.log("  - " + k));',
		'}'
	];

	/** A fix round that changed no `.hx` finds the tip's stored builds and the base's checkout none: no finding is new for it. */
	@:pin('control')
	@:killer('M-LINT-NEW-STORED-BUILDS-READ')
	public function testAFindingOnlyTheStoredBuildsJudgeIsNotNew(): Void {
		devkit.TempDir.with(dir -> {
			final tree: String = dir.file('tree');
			final fake: String = dir.file('engine.js');
			File.saveContent(fake, FAKE_ENGINE.join('\n'));
			for (sub in ['src', 'bin', 'tools']) FileSystem.createDirectory(Path.join([tree, sub]));
			File.saveContent(Path.join([tree, 'tools/dev.hxml']), '');
			for (hxml in ['bin/apq-js-common.hxml', 'bin/apq-js.hxml']) File.saveContent(Path.join([tree, hxml]), '');
			File.saveContent(Path.join([tree, 'src/A.hx']), MODULE);
			File.saveContent(Path.join([tree, 'bin/hxq']), 'exec node $fake "$$@"\n');
			cmd('git init -q -b main').at(tree).check();
			cmd('git add -A').at(tree).check();
			cmd('git -c user.name=t -c user.email=t@t commit -q -m base').at(tree).check();
			File.saveContent(Path.join([tree, 'src/A.hx']), MODULE.replace('return x;', 'return x + 0;'));
			File.saveContent(Path.join([tree, 'stored.marker']), '');
			utest.Assert.equals(0, LintNew.main(['HEAD', '--tree', tree, '--logs', dir.file('logs'), '--no-oracle']));
		});
	}

}
