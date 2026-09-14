package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * The node-kind VOCABULARY gate at the CLI boundary: a kind no rule of the grammar projects is
 * a user error, and every command that lets one be typed now names it and exits non-zero.
 *
 * The walkers used to fail OPEN. `apq lit 'needle' F.hx --kind Literaal` printed `0 hits`,
 * never mentioned `Literaal`, and exited 0 — the same answer a correctly spelled kind gives
 * over code that genuinely holds none, so an empty run read as evidence about the code rather
 * than about the spelling. `search --kind` and `symbols --kind` did the same; `ast --select`
 * named the bad kind but still exited 0, so no script could tell the two apart.
 *
 * Driven through `Cli.run` IN PROCESS rather than as a child process: a child-process fixture
 * skips wherever `bin/apq.js` is not built, the mutation tracks included, and these assertions
 * are precisely what the declared arms have to be able to kill.
 */
class ApqKindVocabularyCliTest extends Test {

	#if (sys || nodejs)
	/** A string literal to look for, so a `--kind` that IS valid has something to find. */
	private static final FIXTURE: String = 'class C {\n\tfunction f():String {\n\t\tfinal s:String = \'needle\';\n\t\treturn s;\n\t}\n}\n';

	/** The two shapes `apq lit` reaches with kinds it mints itself: a comment body and a directive line. */
	private static final TRIVIA_FIXTURE: String =
		'// needle in a comment\nclass D {\n\t#if js\n\tfunction g():Int\n\t\treturn 1;\n\t#end\n}\n';
	#end

	/**
	 * The defect itself: a misspelled `--kind` on a walker is a usage error, and the message
	 * names the spelling that was rejected plus the nearest one that exists.
	 *
	 * KILLED by arm `M-KIND-GATE-FAIL-OPEN`, which makes the shared gate answer "known" for
	 * every kind — the exact fail-open state this pin was written against.
	 */
	@:pin('control')
	@:killer('M-KIND-GATE-FAIL-OPEN')
	public function testLitRejectsAnUnprojectedKind(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_lit', FIXTURE);
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['lit', 'needle', path, '--kind', 'Literaal']));
		Assert.equals(2, rc, 'a kind no grammar projects is a usage error, not an empty result');
		#if nodejs
		Assert.stringContains('"Literaal" is not a node kind this grammar projects', err);
		Assert.stringContains('did you mean', err);
		Assert.stringContains('Literal', err);
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `search` shares the gate; the message is the same sentence under its own command prefix. */
	public function testSearchRejectsAnUnprojectedKind(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_search', FIXTURE);
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['search', '--kind', 'FnMembr', '\'needle\'', path]));
		Assert.equals(2, rc, 'search must refuse a kind no grammar projects');
		#if nodejs
		Assert.stringContains('apq search: --kind "FnMembr" is not a node kind this grammar projects', err);
		Assert.stringContains('FnMember', err);
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** And `symbols`, whose `--kind` is a decl kind — the same vocabulary, narrowed by the command. */
	public function testSymbolsRejectsAnUnprojectedKind(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_symbols', FIXTURE);
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['symbols', path, '--kind', 'ClassDeclz']));
		Assert.equals(2, rc, 'symbols must refuse a kind no grammar projects');
		#if nodejs
		Assert.stringContains('apq symbols: --kind "ClassDeclz" is not a node kind this grammar projects', err);
		Assert.stringContains('ClassDecl', err);
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `apq meta`'s `--on` is `--kind` under a different flag name — a decl-host kind — and it
	 * failed open in exactly the same way, so it reads the same vocabulary through the same gate.
	 */
	public function testMetaOnRejectsAnUnprojectedDeclKind(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_meta', FIXTURE);
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['meta', '@:keep', path, '--on', 'ClassDeclz']));
		Assert.equals(2, rc, 'meta --on must refuse a kind no grammar projects');
		#if nodejs
		Assert.stringContains('apq meta: --on "ClassDeclz" is not a node kind this grammar projects', err);
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `apq lit` mints `Comment` and `Directive` itself — no grammar projects either, they are a
	 * separate scan over the raw source — so a gate that asked the grammar alone would have
	 * rejected the two documented spellings and broken every TODO hunt in the project.
	 *
	 * The did-you-mean pool has to carry them for the same reason: `Coment` is a typo whose fix
	 * exists, and a suggestion list built from the grammar alone cannot name it.
	 *
	 * KILLED by arm `M-LIT-SYNTHETIC-KINDS-EMPTY`, which empties the declaration the gate reads
	 * them from.
	 */
	@:pin('control')
	@:killer('M-LIT-SYNTHETIC-KINDS-EMPTY')
	public function testLitAcceptsTheKindsItMintsItself(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_trivia', TRIVIA_FIXTURE);
		Assert.equals(0, Cli.run(['lit', 'needle', path, '--kind', 'Comment']), 'the comment scan is reached by its own kind');
		Assert.equals(0, Cli.run(['lit', 'js', path, '--kind', 'Directive']), 'so is the directive scan');
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['lit', 'needle', path, '--kind', 'Coment']));
		Assert.equals(2, rc, 'a typo against a minted kind is still a usage error');
		#if nodejs
		Assert.stringContains('did you mean Comment?', err);
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The complement, and the reason the gate cannot simply refuse every `--kind` it does not
	 * recognise from the default set: a kind that IS projected runs and returns its hits.
	 */
	@:pin('guard')
	public function testAProjectedKindStillRuns(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_ok', FIXTURE);
		Assert.equals(0, Cli.run(['lit', 'needle', path, '--kind', 'Literal']), 'a projected kind must be served');
		Assert.equals(0, Cli.run(['symbols', path, '--kind', 'ClassDecl']), 'and so must a projected decl kind');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The edit ops' `--kind` reads the same vocabulary. It always failed CLOSED, but blamed the
	 * tree for a typo: `--at` answered `position 1:1 is not on a "ClassDeclz" node` and the lift
	 * answered `the resolved FnMember node has no enclosing "Fooo" node`, both of which send the
	 * reader to check the cursor.
	 */
	public function testAnEditOpNamesAnUnprojectedLiftKind(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_patch', FIXTURE);
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() ->
			rc = Cli.run(['replace-node', path, '--at', '1:1', '--kind', 'ClassDeclz', 'class C {}'])
		);
		Assert.notEquals(0, rc, 'an unprojected lift kind is refused');
		Assert.equals(FIXTURE, sys.io.File.getContent(path), 'and nothing is written');
		#if nodejs
		Assert.stringContains('"ClassDeclz" is not a node kind this grammar projects', err);
		Assert.stringContains('ClassDecl', err);
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `ast --select` on a kind no rule of the grammar projects: the message came first and
	 * left it at exit 0, so a script driving `ast` still could not tell a typo from an absence.
	 *
	 * KILLED by arm `M-AST-SELECT-UNKNOWN-KIND-EXIT-OK`, which drops the usage return and puts
	 * the miss back on exit 0.
	 */
	@:pin('control')
	@:killer('M-AST-SELECT-UNKNOWN-KIND-EXIT-OK')
	public function testAstSelectUnprojectedKindIsAUsageError(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_ast', FIXTURE);
		Assert.equals(2, Cli.run(['ast', path, '--select', 'Fooo']), 'no file can ever match it — that is a usage error');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The half that must NOT move: `DoWhileStmt` is a kind this grammar projects and this fixture
	 * simply has none, so the walk found nothing and that IS the answer. Exit 0, and the per-file
	 * `Kinds present here` listing rather than the vocabulary clause.
	 */
	@:pin('guard')
	public function testAstSelectProjectedButAbsentKindStaysOk(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_ast_absent', FIXTURE);
		var rc: Int = -1;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['ast', path, '--select', 'DoWhileStmt']));
		Assert.equals(0, rc, 'a legitimately empty walk is an answer, not a mistake');
		#if nodejs
		Assert.stringContains('Kinds present here', err);
		Assert.isTrue(err.indexOf('is not a node kind') < 0, 'no typo claim on a real kind: $err');
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The `ast` miss message itself, which no test covered when it was written: the vocabulary
	 * clause AND the cross-project pointer, which is orthogonal to it — a TypeName typed into
	 * `--select` is the commonest way to reach a kind no grammar projects, and `ast` is
	 * single-file, so the walkers that would find the declaration have to be named.
	 *
	 * KILLED by arm `M-AST-SELECT-NO-CROSS-PROJECT-HINT`, which silences the pointer and leaves
	 * the reader of a single-file miss with nowhere to go.
	 */
	@:pin('control')
	@:killer('M-AST-SELECT-NO-CROSS-PROJECT-HINT')
	public function testAstSelectMissKeepsTheCrossProjectPointer(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('kindvocab_ast_msg', FIXTURE);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['ast', path, '--select', 'Fooo']));
		#if nodejs
		Assert.stringContains('"Fooo" is not a node kind this grammar projects', err);
		Assert.stringContains('ast is single-file', err);
		Assert.stringContains('apq refs Fooo src/ --decls', err);
		Assert.stringContains('apq uses Fooo src/', err);
		Assert.stringContains('apq blast Fooo src/', err);
		#else
		Assert.pass('stderr capture is a nodejs fixture');
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
