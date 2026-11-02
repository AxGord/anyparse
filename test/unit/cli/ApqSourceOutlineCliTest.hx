package unit.cli;

import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq source` size discipline beyond the whole-file refusal: `--outline` answers signatures
 * and line windows instead of bodies, and a `--select` / `--at` node longer than the read
 * budget prints its first lines only, naming how to get the rest.
 *
 * Both exist because a reader asking for one fact used to receive a whole body. Every case
 * runs through `Cli.run` on a scratch module whose `big` member is 150 lines, past the
 * 120-line default budget.
 */
@:nullSafety(Strict)
class ApqSourceOutlineCliTest extends Test {

	private static inline final BIG_LINES: Int = 150;

	/** The whole-file outline names the type and its members with their windows, and no body line. */
	public function testWholeFileOutlineListsSignaturesAndNoBodies(): Void {
		#if (sys || nodejs)
		final path: String = writeModule();
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['source', path, '--outline']));
		FileSystem.deleteFile(path);
		Assert.equals(0, code);
		#if nodejs
		Assert.stringContains('ClassDecl:Sample  class Sample implements Marker', out);
		Assert.isFalse(out.indexOf('Named:Marker') >= 0, 'a type on the header line is not a member: $out');
		Assert.stringContains('FnMember:small  public static function small(a: Int, b: Int): Int', out);
		Assert.stringContains('FnMember:big  public function big(): Int', out);
		Assert.stringContains('VarMember:field  private var field: Int = 5', out);
		Assert.isFalse(out.indexOf('return a + b') >= 0, 'no body line: $out');
		Assert.isFalse(
			out.indexOf('PackageDecl') >= 0 || out.indexOf('ImportDecl') >= 0, 'one-line package / import rows are dropped: $out'
		);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A selected type lists its members; a selected member answers its own signature alone. */
	public function testOutlineOfASelectionIsItsMembersOrItsSignatureAlone(): Void {
		#if (sys || nodejs)
		final path: String = writeModule();
		var typeCode: Int = -1;
		var memberCode: Int = -1;
		final typeOut: String = CliFixture.captureStdout(() ->
			typeCode = Cli.run(['source', path, '--select', 'ClassDecl:Sample', '--outline'])
		);
		final memberOut: String = CliFixture.captureStdout(() ->
			memberCode = Cli.run(['source', path, '--select', 'FnMember:small', '--outline'])
		);
		FileSystem.deleteFile(path);
		Assert.equals(0, typeCode);
		Assert.equals(0, memberCode);
		#if nodejs
		Assert.stringContains('FnMember:big', typeOut);
		Assert.stringContains('FnMember:small', typeOut);
		Assert.equals(1, memberOut.split('\n').filter(line -> line != '').length, 'one row for a member: $memberOut');
		Assert.stringContains('small(a: Int, b: Int): Int', memberOut);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** An outline is not a raw read: asking for both is a usage error. */
	public function testOutlineWithARangeIsAUsageError(): Void {
		#if (sys || nodejs)
		final path: String = writeModule();
		var code: Int = -1;
		CliFixture.captureStderr(() -> code = Cli.run(['source', path, '--outline', '--range', '1:3']));
		FileSystem.deleteFile(path);
		Assert.equals(2, code);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * A node past the budget prints its first `budget` lines at exit 0, and stderr says how many
	 * are left; `--full` prints it whole. The cut firing at all is shown only here; the
	 * range and short-node cases pass the same way with no cap.
	 */
	public function testALongNodeIsCutAndFullLiftsTheCut(): Void {
		#if (sys || nodejs)
		final path: String = writeModule();
		var cutCode: Int = -1;
		var fullCode: Int = -1;
		var cutOut: String = '';
		var fullOut: String = '';
		final err: String = CliFixture.captureStderr(
			() -> cutOut = CliFixture.captureStdout(() -> cutCode = Cli.run(['source', path, '--select', 'FnMember:big']))
		);
		CliFixture.captureStdout(
			() -> fullOut = CliFixture.captureStdout(() -> fullCode = Cli.run(['source', path, '--select', 'FnMember:big', '--full']))
		);
		FileSystem.deleteFile(path);
		Assert.equals(0, cutCode);
		Assert.equals(0, fullCode);
		#if nodejs
		Assert.stringContains('more lines', err);
		Assert.stringContains('--full', err);
		Assert.stringContains('--range', err);
		Assert.isFalse(cutOut.indexOf('step ${BIG_LINES - 1}') >= 0, 'the tail is cut');
		Assert.stringContains('step 0', cutOut);
		Assert.stringContains('step ${BIG_LINES - 1}', fullOut);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** An explicit `--range` is a size the reader chose, and a short node is never cut. */
	public function testARangeAndAShortNodeAreNeverCut(): Void {
		#if (sys || nodejs)
		final path: String = writeModule();
		var rangeOut: String = '';

		final err: String = CliFixture.captureStderr(() ->
			rangeOut = CliFixture.captureStdout(() -> Cli.run(['source', path, '--range', '1:200']))
		);
		final smallErr: String = CliFixture.captureStderr(() ->
			CliFixture.captureStdout(() -> Cli.run(['source', path, '--select', 'FnMember:small']))
		);
		FileSystem.deleteFile(path);
		#if nodejs
		Assert.stringContains('step ${BIG_LINES - 1}', rangeOut);
		Assert.equals('', err);
		Assert.equals('', smallErr);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A module-level function lists itself and none of its body's or parameters' named nodes. */
	public function testAModuleLevelFunctionOutlineHasNoBodyNodes(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nfunction topFn(a: Int): Int {\n\tvar local: Int = a;\n\ttrace(local);\n\treturn local;\n}\n'
		);
		#if nodejs
		Assert.stringContains('FnDecl:topFn', out);
		Assert.isFalse(out.indexOf('local') >= 0, 'no body identifier is a member: $out');
		Assert.isFalse(out.indexOf('Required:') >= 0, 'nor a parameter: $out');
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** An annotation on its own line belongs to the declaration below it and is not a member row. */
	public function testAnOwnLineAnnotationIsNotAMemberRow(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nclass Note {\n\t@:keep\n\t@:pin(\'x\')\n\tpublic function noted(): Int {\n\t\treturn 1;\n\t}\n}\n'
		);
		#if nodejs
		Assert.stringContains('FnMember:noted', out);
		Assert.isFalse(out.indexOf('Meta') >= 0, 'an annotation is not a member: $out');
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** Two declarations on one line each print their own header, not the first one's. */
	public function testTwoDeclarationsOnOneLineEachPrintTheirOwnHeader(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nclass Pair {\n\tvar a: Int; var b: String;\n\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n'
		);
		#if nodejs
		Assert.stringContains('VarMember:a  var a: Int', out);
		Assert.stringContains('VarMember:b  var b: String', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A brace inside an anonymous structure type or a type-parameter constraint does not end the header. */
	public function testABraceInsideATypeDoesNotCutTheHeader(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nclass Shapes {\n\tvar cache: Map<String, {a: Int}> = new Map();\n\n'
			+ '\tpublic function gen<T:{x: Int}>(v: T): T {\n\t\treturn v;\n\t}\n}\n'
		);
		#if nodejs
		Assert.stringContains('var cache: Map<String, {a: Int}> = new Map()', out);
		Assert.stringContains('function gen<T:{x: Int}>(v: T): T', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A `;` or `{` inside a string default does not end the header. */
	public function testPunctuationInAStringDefaultDoesNotCutTheHeader(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nclass Text {\n\tvar label: String = \'p;q\';\n\n\tpublic function s(a: String = \'x;y{z\', b: Int = 0): Int {\n'
			+ '\t\treturn b;\n\t}\n}\n'
		);
		#if nodejs
		Assert.stringContains('var label: String = \'p;q\'', out);
		Assert.stringContains('b: Int = 0): Int', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A doc block between a type's brace and its first member is not part of the type's header. */
	public function testADocBlockAfterTheBraceIsNotPartOfTheHeader(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nclass Doc {\n\t/** first member doc */\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n'
		);
		#if nodejs
		Assert.stringContains('ClassDecl:Doc  class Doc\n', out);
		Assert.isFalse(out.indexOf('first member doc') >= 0, 'a doc block is not a header: $out');
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** One line left over is `1 more line`, not `1 more lines`. */
	public function testASingleLeftOverLineIsSingular(): Void {
		#if (sys || nodejs)
		final path: String = writeModule();
		final saved: Null<String> = Sys.getEnv('HXQ_SOURCE_MAX_LINES');
		Sys.putEnv('HXQ_SOURCE_MAX_LINES', '${BIG_LINES + 3}');
		final err: String = CliFixture.captureStderr(() ->
			CliFixture.captureStdout(() -> Cli.run(['source', path, '--select', 'FnMember:big']))
		);
		Sys.putEnv('HXQ_SOURCE_MAX_LINES', saved ?? '');
		FileSystem.deleteFile(path);
		#if nodejs
		Assert.stringContains('… 1 more line (', err);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** An annotation on the same line as its declaration stays in that declaration's header. */
	public function testASameLineAnnotationStaysInTheHeader(): Void {
		#if (sys || nodejs)
		final out: String = outlineOf(
			'package;\n\nclass Tag {\n\tvar a: Int;\n\t@:keep public static inline function f(): Int {\n\t\treturn 1;\n\t}\n'
			+ '\tvar b: String; @:keep var c: Int;\n}\n'
		);
		#if nodejs
		Assert.stringContains('FnMember:f  @:keep public static inline function f(): Int', out);
		Assert.stringContains('VarMember:c  @:keep var c: Int', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** The outline of `source` as the command prints it. */
	private function outlineOf(source: String): String {
		final path: String = CliFixture.writeAs('apq_source_outline_case', 'hx', source);
		var out: String = '';
		CliFixture.captureStderr(() -> out = CliFixture.captureStdout(() -> Cli.run(['source', path, '--outline'])));
		FileSystem.deleteFile(path);
		return out;
	}

	#if (sys || nodejs)
	/** A parseable module: a one-line member, a field, and `big` with `BIG_LINES` body lines. */
	private function writeModule(): String {
		final buf: StringBuf = new StringBuf();
		buf.add('package;\n\nimport haxe.Exception;\n\nclass Sample implements Marker {\n');
		buf.add('\tpublic static function small(a: Int, b: Int): Int {\n\t\treturn a + b;\n\t}\n\n');
		buf.add('\tprivate var field: Int = 5;\n\n');
		buf.add('\tpublic function big(): Int {\n\t\tvar total: Int = 0;\n');
		for (i in 0...BIG_LINES) buf.add('\t\ttotal += $i; // step $i\n');
		buf.add('\t\treturn total;\n\t}\n\n}\n');
		return CliFixture.writeAs('apq_source_outline', 'hx', buf.toString());
	}
	#end

}
