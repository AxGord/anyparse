package unit.cli;

import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/**
 * `apq move` end to end: a reference to a moved type inside a metadata argument is re-spelled with its full path, since
 * the macro reads that argument in another module where an import of the referencing file does not reach; a reference
 * in code keeps its import.
 */
@:nullSafety(Strict)
class MoveMetaArgSpellingTest extends Test {

	@:pin('control')
	@:killer('M-MOVE-META-ARG-READ-AS-CODE')
	public function testAMetadataArgumentIsRespelledFullyQualifiedWithoutAnImport(): Void {
		#if nodejs
		final root: String = scratch('apq_meta_arg_path');
		final run: CliRun = CliFixture.runIn(root, ['move', 'src/p/Mover.hx', '--to', 'src/q', '--write']);
		final meta: String = File.getContent('$root/src/p/Meta.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(meta.indexOf('@:fmt(preWrite(q.Mover.f))') >= 0, meta);
		Assert.isTrue(meta.indexOf('import q.Mover;') < 0, meta);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-MOVE-CODE-READ-AS-META-ARG')
	public function testAReferenceInCodeKeepsItsImport(): Void {
		#if nodejs
		final root: String = scratch('apq_meta_arg_code');
		final run: CliRun = CliFixture.runIn(root, ['move', 'src/p/Mover.hx', '--to', 'src/q', '--write']);
		final code: String = File.getContent('$root/src/p/Code.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(code.indexOf('import q.Mover;') >= 0, code);
		Assert.isTrue(code.indexOf('return Mover.f();') >= 0, code);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-MOVE-META-ARG-READ-AS-CODE')
	public function testANameWrittenInBothGetsAnImportForTheCodeAndAFullPathForTheArgument(): Void {
		#if nodejs
		final root: String = scratch('apq_meta_arg_both');
		final run: CliRun = CliFixture.runIn(root, ['move', 'src/p/Mover.hx', '--to', 'src/q', '--write']);
		final both: String = File.getContent('$root/src/p/Both.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(both.indexOf('@:build(q.Mover.f())') >= 0, both);
		Assert.isTrue(both.indexOf('import q.Mover;') >= 0, both);
		Assert.isTrue(both.indexOf('return Mover.f();') >= 0, both);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-MOVE-META-ARG-NEVER-RE-ASKED')
	public function testAnArgumentNameTheImportForTheCodeWouldRebindRefusesTheMove(): Void {
		#if nodejs
		final priv: String = 'package p;\n\n@:fmt(preWrite(Mover.f), other(Sub.make))\nclass Priv {\n\tpublic static function g():Int {\n'
			+ '\t\treturn Mover.f();\n\t}\n}\n';
		final root: String = CliFixture.writeTree('apq_meta_arg_rebound', [
			{ name: 'apq.json', source: '{"move":{"scope":["src"]}}\n' },
			{
				name: 'src/p/Mover.hx',
				source: 'package p;\n\nclass Mover {\n\tpublic static function f():Int {\n\t\treturn 1;\n\t}\n}\n\nclass Sub {\n'
				+ '\tpublic static function h():Int {\n\t\treturn 2;\n\t}\n}\n'
			},
			{ name: 'src/p/Sub.hx', source: 'package p;\n\nclass Sub {\n\tpublic static function make():Int {\n\t\treturn 3;\n\t}\n}\n' },
			{ name: 'src/p/Priv.hx', source: priv }
		]);
		final run: CliRun = CliFixture.runIn(root, ['move', 'src/p/Mover.hx', '--to', 'src/q', '--write']);
		final after: String = File.getContent('$root/src/p/Priv.hx');
		CliFixture.removeDir(root);
		Assert.notEquals(0, run.code);
		Assert.equals(priv, after);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	#if nodejs
	private static function scratch(name: String): String {
		return CliFixture.writeTree(name, [
			{ name: 'apq.json', source: '{"move":{"scope":["src"]}}\n' },
			{ name: 'src/p/Mover.hx', source: 'package p;\n\nclass Mover {\n\tpublic static function f():Int {\n\t\treturn 1;\n\t}\n}\n' },
			{ name: 'src/p/Meta.hx', source: 'package p;\n\n@:fmt(preWrite(Mover.f))\nclass Meta {}\n' },
			{
				name: 'src/p/Code.hx',
				source: 'package p;\n\nclass Code {\n\tpublic static function g():Int {\n\t\treturn Mover.f();\n\t}\n}\n'
			},
			{
				name: 'src/p/Both.hx',
				source: 'package p;\n\n@:build(Mover.f())\nclass Both {\n\tpublic static function g():Int {\n\t\treturn Mover.f();\n\t}\n'
				+ '}\n'
			}
		]);
	}
	#end

}
