package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddMeta;
import anyparse.query.Cli;
import anyparse.query.ReplaceNode.ReplaceTarget;
import utest.Assert;
import utest.Test;

using StringTools;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `AddMeta.addMeta` — add one `@:metadata` entry to an existing declaration.
 *
 * The op exists because the two that already reach the position get it wrong, each
 * in a way that reads like the other's failure: `patch` cannot see past a `final`
 * WRAPPER (`FinalDecl(ClassForm X)`) so the searchable slice starts at `class`, and
 * `add-element --before` inserts a SIBLING, so it deliberately clears the leading doc
 * and drops the entry ABOVE it. Every fixture here is writer-canonical under the
 * compiled defaults, which is what the op's canonical gate measures against.
 */
class AddMetaSliceTest extends Test {

	#if (sys || nodejs)
	private static var counter: Int = 0;
	#end

	/**
	 * The entry lands BELOW the declaration's doc comment — the position `add-element
	 * --before` cannot reach, because clearing the doc is right for a sibling and wrong
	 * for an annotation. Killed by arm M6.
	 */
	public function testTypeEntryLandsBelowTheDoc(): Void {
		assertMeta(
			'/**\n * About C.\n */\nclass C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), '@:keep',
			'/**\n * About C.\n */\n@:keep\nclass C {\n\n\tfunction f():Void {}\n\n}\n'
		);
	}

	/**
	 * A `final class` — the shape whose `FinalDecl` wrapper made every other op emit
	 * `final @:keep class C`, which does not parse. Killed by arm M7.
	 */
	public function testFinalClassWrapperIsLifted(): Void {
		assertMeta(
			'final class C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), '@:nullSafety(Strict)',
			'@:nullSafety(Strict)\nfinal class C {\n\n\tfunction f():Void {}\n\n}\n'
		);
	}

	/** A member entry lands below the member's own doc and above its modifiers. */
	public function testMemberEntryLandsAboveTheModifiers(): Void {
		assertMeta(
			'class C {\n\n\t/**\n\t * About f.\n\t */\n\tpublic static function f():Void {}\n\n}\n', BySelector('FnMember:f'),
			'@:noCompletion', 'class C {\n\n\t/**\n\t * About f.\n\t */\n\t@:noCompletion\n\tpublic static function f():Void {}\n\n}\n'
		);
	}

	/** The entry APPENDS to the run already there, keeping the file's own order. */
	public function testAppendsToAnExistingRun(): Void {
		assertMeta(
			'@:keep\nclass C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), '@:nullSafety(Strict)',
			'@:keep\n@:nullSafety(Strict)\nclass C {\n\n\tfunction f():Void {}\n\n}\n'
		);
	}

	/**
	 * Addressing an existing annotation means the declaration it prefixes — the only
	 * thing it can mean for this op, where `declGroupSpan`'s refusal to walk forward off
	 * an annotation (right for `remove-element`) would leave no target at all.
	 */
	public function testAnnotationAddressMeansItsDeclaration(): Void {
		assertMeta(
			'@:keep\nfinal class C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('Meta:@:keep'), '@:nullSafety(Strict)',
			'@:keep\n@:nullSafety(Strict)\nfinal class C {\n\n\tfunction f():Void {}\n\n}\n'
		);
	}

	/** An entry of the same name already there is refused, the way `AddImport` refuses a duplicate. */
	public function testDuplicateNameRefused(): Void {
		assertRefused('@:keep\nclass C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), '@:keep', 'already annotated');
	}

	/**
	 * A duplicate is judged by NAME, not by the whole entry: two `@:access` clauses with
	 * different arguments are legal Haxe, but the shape this refusal exists for — a
	 * re-run adding what is already there — spells the same name.
	 */
	public function testDuplicateNameWithDifferentArgsRefused(): Void {
		assertRefused(
			'@:access(foo.Bar)\nclass C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), '@:access(baz.Qux)',
			'already annotated'
		);
	}

	/** A string that is not a metadata entry is refused before anything is parsed. */
	public function testNonMetadataRefused(): Void {
		assertRefused('class C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), 'nullSafety', 'is not a metadata entry');
	}

	/** An entry whose ARGUMENT list is malformed is rejected by the re-parse, not by a hand-rolled expression check. */
	public function testMalformedArgumentsRejectedByTheReparse(): Void {
		switch AddMeta.addMeta('class C {\n\n\tfunction f():Void {}\n\n}\n', BySelector('ClassDecl:C'), '@:keep(', false, plugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				// `Assert.pass()` on any `Err` could not tell the two rejections apart, so
				// teaching `metaName` to vet the argument list would leave this green while
				// its own claim went false. Name the gate that must have answered.
				Assert.stringContains('does not parse', message);
				Assert.isFalse(message.contains('is not a metadata entry'), 'rejected by the re-parse, not by metaName');
		}
	}

	/**
	 * A type guarded by `#if` takes its entry INSIDE the guard.
	 *
	 * The wrapper climb used to accept any single-child parent whose span started
	 * earlier, which a `#if` region wrapping one type also is — so the entry landed
	 * above the `#if` line, and on a target where the condition is false it annotated
	 * whatever declaration follows `#end`. rc 0, past the parse gate, silently the wrong
	 * type. Killed by arm M15.
	 */
	public function testGuardedTypeKeepsTheEntryInsideTheGuard(): Void {
		assertMeta(
			'#if sys\nfinal class C {\n\n\tfunction f():Void {}\n\n}\n#end\n\nfinal class After {\n\n\tfunction g():Void {}\n\n}\n',
			BySelector('ClassDecl:C'), '@:keep',
			'#if sys\n@:keep\nfinal class C {\n\n\tfunction f():Void {}\n\n}\n#end\n\nfinal class After {\n\n\tfunction g():Void {}\n\n}\n'
		);
	}

	/** An enum and a typedef take an entry too — the op is not class-only. */
	public function testEnumAndTypedef(): Void {
		assertMeta('enum E {\n\n\tX;\n\n}\n', BySelector('EnumDecl:E'), '@:keep', '@:keep\nenum E {\n\n\tX;\n\n}\n');
		assertMeta('typedef T = {\n\tvar a:Int;\n}\n', BySelector('TypedefDecl:T'), '@:keep', '@:keep\ntypedef T = {\n\tvar a:Int;\n}\n');
	}

	/** `Ok` with the exact canonical result. */
	private function assertMeta(source: String, target: ReplaceTarget, meta: String, expected: String): Void {
		switch AddMeta.addMeta(source, target, meta, false, plugin()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** `Err` whose message carries `needle`. */
	private function assertRefused(source: String, target: ReplaceTarget, meta: String, needle: String): Void {
		switch AddMeta.addMeta(source, target, meta, false, plugin()) {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(message):
				Assert.stringContains(needle, message);
		}
	}

	private function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	#if (sys || nodejs)
	/**
	 * The CLI end of the op: dispatch, argument parsing, `hxformat.json` discovery and
	 * `--write`. The pure tests above cannot see a missing `case 'add-meta'`. Killed by
	 * arm M10.
	 */
	public function testCliWritesTheEntry(): Void {
		final dir: String = tmpDir();
		final p: String = '$dir/Target.hx';
		File.saveContent(p, 'package;\n\nfinal class Target {\n\n\tfunction f():Void {}\n\n}\n');
		Assert.equals(0, Cli.run(['add-meta', p, '--select', 'ClassDecl:Target', '@:nullSafety(Strict)', '--write']));
		Assert.equals('package;\n\n@:nullSafety(Strict)\nfinal class Target {\n\n\tfunction f():Void {}\n\n}\n', File.getContent(p));
		// Idempotence is a REFUSAL, not a silent second entry — and the file is untouched.
		Assert.equals(1, Cli.run(['add-meta', p, '--select', 'ClassDecl:Target', '@:nullSafety(Strict)', '--write']));
		Assert.equals('package;\n\n@:nullSafety(Strict)\nfinal class Target {\n\n\tfunction f():Void {}\n\n}\n', File.getContent(p));
		CliFixture.removeDir(dir);
	}

	/** Without `--write` the op is a preview: stdout only, the file untouched. */
	public function testCliPreviewLeavesTheFileAlone(): Void {
		final dir: String = tmpDir();
		final p: String = '$dir/Target.hx';
		final before: String = 'package;\n\nfinal class Target {\n\n\tfunction f():Void {}\n\n}\n';
		File.saveContent(p, before);
		Assert.equals(0, Cli.run(['add-meta', p, '--select', 'ClassDecl:Target', '@:keep']));
		Assert.equals(before, File.getContent(p));
		CliFixture.removeDir(dir);
	}

	private static function tmpDir(): String {
		counter++;
		final raw: Null<String> = Sys.getEnv('TMPDIR');
		final env: String = raw ?? '';
		final base: String = if (env.length <= 0)
			'/tmp'
		else if (env.endsWith('/'))
			env.substr(0, env.length - 1)
		else
			env;
		final dir: String = '$base/tmp_apq_add_meta_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		return dir;
	}
	#end

}
