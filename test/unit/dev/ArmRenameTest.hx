package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JValueWriter;
import anyparse.query.Cli;
import dev.ArmRegistry;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A member rename over a scratch repo with the project's REAL registry declaration: the records naming the member follow it,
 * and `dev mutation-arm --apply-only`, the applier itself, still applies every arm afterwards.
 */
@:nullSafety(Strict)
final class ArmRenameTest extends Test {

	private static final BASE: String = 'package p;\n\nclass Base {\n\n\tpublic function new() {}\n\n\tpublic function walk(): Int {\n'
		+ '\t\treturn 1;\n\t}\n\n\tpublic function other(): Int {\n\t\tfinal a: Int = 2;\n'
		+ '\t\tif (a > 1) return walk();\n\t\treturn a;\n\t}\n\n}\n';
	private static final SUB: String =
		'package p;\n\nclass Sub extends Base {\n\n\toverride public function walk(): Int {\n\t\treturn 2;\n\t}\n\n}\n';
	private static final CALLER: String =
		'package p;\n\nclass Caller {\n\n\tpublic static function run(b: Base): Int {\n\t\treturn b.walk();\n\t}\n\n}\n';
	private static final SHADOW: String = 'package p;\n\nclass Shadow {\n\n\tpublic function walk(): Int {\n\t\treturn 1;\n\t}\n\n'
		+ '\tpublic function local(o: Other): Int {\n\t\tfinal walk: Int = o.walk;\n\t\treturn walk;\n\t}\n\n}\n\n'
		+ 'class Other {\n\n\tpublic var walk: Int = 0;\n\n\tpublic function helper(): Int {\n\t\treturn walk;\n\t}\n\n}\n';
	private static final ARMS: String = '{"arms": [\n'
		+ '\t{"name": "M-OWNER", "type": "p.Base", "method": "walk", "find": "return 1;", "replace": "return 2;", "note": ""},\n\t{"name": '
		+ '"M-FORCED", "type": "p.Base", "method": "walk", "force": "1", "note": ""},\n\t{"name": "M-ESCAPED", "type": "p.Base", "method": '
		+ '"other", "find": "final a: Int = 2;\\n\\t\\tif (a > 1) return walk();", "replace": "final a: Int = 3;\\n\\t\\tif (a > 1) '
		+ 'return walk();", "note": ""},\n\t{"name": "M-ARRAY", "type": "p.Base", "method": "other", "find": ["return walk();", "return '
		+ 'a;"], "replace": ["return walk() + 1;", "return a + walk();"], "note": ""},\n\t{"name": "M-OVERRIDE", "type": "p.Sub", '
		+ '"method": "walk", "find": "return 2;", "replace": "return 3;", "note": ""},\n\t{"name": "M-FOREIGN", "type": "p.Caller", '
		+ '"method": "run", "find": "b.walk()", "replace": "b.walk() + 1", "note": ""},\n\t{"name": "M-SHADOW", "type": "p.Shadow", '
		+ '"method": "local", "find": "final walk: Int = o.walk;", "replace": "final walk: Int = o.walk + 1;", "note": ""},\n\t{"name": '
		+ '"M-SECONDARY", "type": "p.Shadow", "method": "helper", "find": "return walk;", "replace": "return walk + 1;", "note": ""}\n]}\n';

	public function testEveryArmStillAppliesAfterTheMemberItNamesIsRenamed(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			final arms: String = Path.join([repo, ArmRegistry.DIRECTORY]);
			FileSystem.createDirectory(arms);
			FileSystem.createDirectory(Path.join([repo, 'src/p']));
			File.saveContent(Path.join([arms, 'p.json']), ARMS);
			File.saveContent(Path.join([repo, 'hxformat.json']), File.getContent('hxformat.json'));
			// A force arm's cut reads its member through the repo's own shims, which the pinned engine then answers.
			FileSystem.createDirectory(Path.join([repo, 'bin']));
			for (shim in ['hxq', 'apq']) File.copy('bin/$shim', Path.join([repo, 'bin/$shim']));
			File.saveContent(Path.join([repo, 'src/p/Base.hx']), BASE);
			File.saveContent(Path.join([repo, 'src/p/Sub.hx']), SUB);
			File.saveContent(Path.join([repo, 'src/p/Caller.hx']), CALLER);
			File.saveContent(Path.join([repo, 'src/p/Shadow.hx']), SHADOW);
			File.saveContent(Path.join([repo, 'apq.json']), '{"move": {"scope": ["src"], "registries": [${declaredEntry()}]}}\n');
			final printed: String = CliFixture.captureStderr(() -> Assert.equals(0, Cli.run([
				'rename',
				Path.join([repo, 'src/p/Base.hx']),
				'--select',
				'FnMember:walk',
				'step',
				'--scope',
				Path.join([repo, 'src']),
				'--write'
			])));
			final document: String = File.getContent(Path.join([arms, 'p.json']));
			Assert.isTrue(document.contains('"type": "p.Base", "method": "step", "find": "return 1;"'), '$printed\n$document');
			Assert.isTrue(document.contains('"type": "p.Sub", "method": "step"'), document);
			Assert.isTrue(document.contains('"find": "b.step()"'), document);
			Assert.isTrue(document.contains('"find": "final walk: Int = o.walk;"'), document);
			Assert.isTrue(document.contains('"find": "return walk;"'), document);
			Assert.equals(0, ArmApply.applyOnly(repo, [
				'M-OWNER',
				'M-FORCED',
				'M-ESCAPED',
				'M-ARRAY',
				'M-OVERRIDE',
				'M-FOREIGN',
				'M-SHADOW',
				'M-SECONDARY'
			]));
		});
	}

	/** The project's own `apq.json` entry for the arm registry, so this test also proves the declaration itself. */
	private static function declaredEntry(): String {
		final registries: Null<JValue> = JValueTools.field(
			JValueTools.field(JValueParser.parse(File.getContent('apq.json')), 'move'), 'registries'
		);
		switch registries {
			case JArray(items):
				for (item in items) switch JValueTools.field(item, 'file') {
					case JString(file) if ((file: String) == ArmRegistry.DIRECTORY):
						return JValueWriter.write(item);
					case _:
				}
			case _:
		}
		throw 'apq.json declares no move registry for ${ArmRegistry.DIRECTORY}';
	}

}
