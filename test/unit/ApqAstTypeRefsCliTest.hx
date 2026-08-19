package unit;

import utest.Assert;
import utest.Test;
import haxe.Exception;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.format.Text;
#if nodejs
import js.Node;
#end

using StringTools;

/**
 * `apq ast --type-refs` — the type-position projection, exposed.
 *
 * `GrammarPlugin.parseFileTypeRefs` (field/var annotations, parameter and
 * return types, enum-ctor parameters, type parameters) used to be reachable
 * only through `uses` / `blast`, so "list every dotted type reference in this
 * file" had no answer inside hxq. The flag renders that tree through the very
 * same S-expr / JSON path the default `ast` uses.
 *
 * The dump is deliberately RAW — `testAnonStructInTypeParamProjects` pins
 * the anonymous-structure shape it renders, names excluded.
 *
 * Output is observed by swapping `process.stdout.write`, which is a nodejs-only
 * capability; the non-nodejs arms fall back to exit codes plus the
 * target-agnostic `Text.render` twin.
 */
@:nullSafety(Strict)
class ApqAstTypeRefsCliTest extends Test {

	private static inline final MIXED_SOURCE: String =
		'class C { var a: Int; final b: Map<String, Foo>; function f(p: haxe.io.Bytes): Null<Bar> return null; }';
	private static inline final ANON_SOURCE: String = 'class C { function f(?d: Array<{ node: Doc, crosses: Bool }>): Void {} }';
	private static inline final INT_FIELD_SOURCE: String = 'class C { var a: Int; }';
	private static final MIXED_TYPE_REFS: String = '(module\n  (ClassDecl\n    C\n    (VarMember a (TypeRef Int))\n'
		+ '    (FinalMember b (TypeRef Map) (TypeRef String) (TypeRef Foo))\n    (FnMember\n      f\n'
		+ '      (Required p (TypeRef haxe.io.Bytes))\n      (Named Null (TypeRef Bar))\n      (ExprBody (ReturnExpr (NullLit))))))\n';
	private static final MIXED_DEFAULT: String = '(module\n  (ClassDecl\n    C\n    (VarMember a)\n    (FinalMember b)\n'
		+ '    (FnMember f (Required p) (Named Null) (ExprBody (ReturnExpr (NullLit))))))\n';

	/**
	 * `Array<{ node: Doc, crosses: Bool }>` projects the anonymous structure's
	 * field TYPES as siblings of the enclosing `Array`, and its field NAMES
	 * not at all — a name reaching the projection would be read as a type
	 * reference by every consumer of it.
	 */
	private static final ANON_TYPE_REFS: String = '(module\n  (ClassDecl\n    C\n'
		+ '    (FnMember f (Optional d (TypeRef Array) (TypeRef Doc) (TypeRef Bool)) (Named Void) (BlockBody))))\n';

	public function testTypeRefsDumpsEveryTypePosition(): Void {
		#if nodejs
		Assert.equals(MIXED_TYPE_REFS, captureStdout(['ast', '--code', MIXED_SOURCE, '--type-refs']));
		#else
		Assert.equals(0, Cli.run(['ast', '--code', MIXED_SOURCE, '--type-refs']));
		#end
	}

	public function testDefaultDumpStillDropsTypePositions(): Void {
		#if nodejs
		Assert.equals(MIXED_DEFAULT, captureStdout(['ast', '--code', MIXED_SOURCE]));
		#else
		Assert.equals(0, Cli.run(['ast', '--code', MIXED_SOURCE]));
		#end
	}

	/**
	 * Target-agnostic twin of the CLI dump: the flag prints exactly
	 * `Text.render(plugin.parseFileTypeRefs(source))`, so the projection format
	 * stays pinned even where stdout capture is unavailable.
	 */
	public function testProjectionRendersTheDumpedSExpr(): Void {
		Assert.equals(MIXED_TYPE_REFS, Text.render(new HaxeQueryPlugin().parseFileTypeRefs(MIXED_SOURCE)));
	}

	public function testAnonStructInTypeParamProjects(): Void {
		#if nodejs
		final dump: String = captureStdout(['ast', '--code', ANON_SOURCE, '--type-refs']);
		Assert.equals(ANON_TYPE_REFS, dump);
		Assert.isTrue(dump.contains('(TypeRef Doc)'), 'the anon field type must reach the projection, got: $dump');
		Assert.isFalse(dump.contains('node'), 'the anon field NAME must stay out of the projection, got: $dump');
		#else
		Assert.equals(ANON_TYPE_REFS, Text.render(new HaxeQueryPlugin().parseFileTypeRefs(ANON_SOURCE)));
		#end
	}

	public function testSelectAddressesTypeRefNodes(): Void {
		#if nodejs
		Assert.equals('(TypeRef Int)\n', captureStdout(['ast', '--code', INT_FIELD_SOURCE, '--type-refs', '--select', 'TypeRef']));
		#else
		Assert.equals(0, Cli.run(['ast', '--code', INT_FIELD_SOURCE, '--type-refs', '--select', 'TypeRef']));
		#end
	}

	public function testJsonModeCarriesTypeRefNodes(): Void {
		#if nodejs
		final withFlag: String = captureStdout(['ast', '--code', INT_FIELD_SOURCE, '--type-refs', '--json']);
		Assert.isTrue(withFlag.contains('"kind":"TypeRef"'), 'json --type-refs must carry TypeRef nodes, got: $withFlag');
		Assert.isTrue(withFlag.contains('"name":"Int"'), 'json --type-refs must name the referenced type, got: $withFlag');
		Assert.isFalse(
			captureStdout(['ast', '--code', INT_FIELD_SOURCE, '--json']).contains('"kind":"TypeRef"'),
			'the default json projection must stay free of TypeRef nodes'
		);
		#else
		Assert.equals(0, Cli.run(['ast', '--code', INT_FIELD_SOURCE, '--type-refs', '--json']));
		#end
	}

	/**
	 * `--type-refs` must also sit in `AST_BOOL_FLAGS` so `probe`'s argv walker
	 * knows it consumes no value — hence the trailing `--depth 9`: an
	 * unregistered flag would swallow `--depth` and leave `9` as a second
	 * positional (EXIT_USAGE), which a trailing-flag probe cannot detect.
	 */
	public function testProbeForwardsTheFlag(): Void {
		#if nodejs
		Assert.equals(MIXED_TYPE_REFS, captureStdout(['probe', MIXED_SOURCE, '--type-refs', '--depth', '9']));
		#else
		Assert.equals(0, Cli.run(['probe', MIXED_SOURCE, '--type-refs', '--depth', '9']));
		#end
	}

	public function testHelpDocumentsTheFlag(): Void {
		#if nodejs
		Assert.isTrue(captureStdout(['ast', '--help']).contains('--type-refs'), 'ast help must list --type-refs');
		#else
		Assert.equals(0, Cli.run(['ast', '--help']));
		#end
	}

	public function testWriterOutputCombinationIsRefused(): Void {
		Assert.equals(2, Cli.run(['ast', '--code', 'class C {}', '--type-refs', '--writer-output']));
	}

	#if nodejs
	/**
	 * Run `argv` through the CLI with `process.stdout.write` swapped for a
	 * buffer and return everything the command printed. `Sys.print` compiles to
	 * a direct `process.stdout.write` property read on hxnodejs, so the swap
	 * intercepts every `sysPrint`; stderr is left alone.
	 */
	private static function captureStdout(argv: Array<String>, expectedExit: Int = 0): String {
		final buffer: StringBuf = new StringBuf();
		final stdout: Dynamic = Node.process.stdout;
		final original: Dynamic = Reflect.field(stdout, 'write');
		Reflect.setField(stdout, 'write', (chunk: Dynamic) -> {
			buffer.add('$chunk');
			return true;
		});
		final code: Int = try Cli.run(argv) catch (exception: Exception) {
			Reflect.setField(stdout, 'write', original);
			throw exception;
		}
		Reflect.setField(stdout, 'write', original);
		Assert.equals(expectedExit, code, 'apq ${argv.join(' ')}');
		return buffer.toString();
	}
	#end

}
