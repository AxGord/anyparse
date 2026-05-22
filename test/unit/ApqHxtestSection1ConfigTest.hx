package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `.hxtest` section-1 (writer config JSON) auto-apply through the
 * writer entry points (`ast --writer-output*` / `writer-equals` /
 * `writer-probe`). The fork's `hxformat.json`-shaped payload is
 * extracted from section 1 of a `.hxtest`, fed into
 * `HaxeFormatConfigLoader.loadHxFormatJson`, and drives
 * `HxModuleWriteOptions` for that one call.
 *
 * Style mirrors the recon-CLI tests: exit-code-only assertions, no
 * stdout text comparison. The byte-equality check via
 * `writer-equals` IS the observable — when section-1 IS applied,
 * `writer-equals fixtureB fixtureB` passes (input bytes from
 * section-2 + config from section-1 → emitted bytes that match
 * section-3). When section-1 is dropped, the same call fails because
 * the writer uses different defaults.
 */
@:nullSafety(Strict)
class ApqHxtestSection1ConfigTest extends Test {

	public function testEmptyConfigOnHxtestIsNoOp():Void {
		#if sys
		// `loadHxFormatJson('{}')` is byte-identical to defaults per the
		// loader's docstring. So writer-equals against an .hxtest whose
		// section-1 is `{}` is byte-equal whenever section-3 matches the
		// default writer's output — there's no special path here.
		final src:String = 'class C { var x:Int = 0; }';
		final expected:String = 'class C {\n\tvar x:Int = 0;\n}';
		final fixture:String = makeHxtest('{}', src, expected);
		final path:String = writeFixture('apq_h1_empty', fixture);
		Assert.equals(0, Cli.run(['writer-equals', '--plain', path, path]),
			'empty section-1 config → defaults → byte-equal vs section-3');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSpaceIndentConfigOverridesDefaults():Void {
		#if sys
		// Defaults are tab+1. Section-1 requests 4-space indent — IF
		// section-1 routes through the writer, section-3 (4-space body)
		// matches; if it's dropped, the writer emits tab-indented bytes
		// and writer-equals fails.
		final src:String = 'class C { var x:Int = 0; }';
		final expected:String = 'class C {\n    var x:Int = 0;\n}';
		final fixture:String = makeHxtest('{"indentation": {"character": "    "}}', src, expected);
		final path:String = writeFixture('apq_h1_space', fixture);
		Assert.equals(0, Cli.run(['writer-equals', '--plain', path, path]),
			'section-1 4-space config overrides default tab indent');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testInlineProbeIgnoresSection1():Void {
		#if sys
		// `apq probe '<code>'` has no path → no section-1 to extract,
		// always plugin defaults. Smoke-checking the CLI exit; the
		// real "no section-1 wired" assertion is covered by writer-
		// equals above (a divergent config doesn't trip a path-less
		// probe).
		Assert.equals(0, Cli.run(['probe', 'class C { var x:Int = 0; }', '--writer-output-plain']),
			'inline probe exits clean regardless of section-1 (no path)');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static inline function makeHxtest(config:String, source:String, expected:String):String {
		return '$config\n---\n\n$source\n\n---\n\n$expected\n';
	}

	private static function writeFixture(prefix:String, content:String):String {
		final dir:String = tempDir();
		final path:String = '$dir/${prefix}_${Sys.time()}.hxtest';
		File.saveContent(path, content);
		return path;
	}

	private static function tempDir():String {
		final tmp:Null<String> = Sys.getEnv('TMPDIR');
		if (tmp != null && tmp.length > 0) return stripTrailingSlash((tmp : String));
		return '/tmp';
	}

	private static inline function stripTrailingSlash(p:String):String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}
	#end
}
