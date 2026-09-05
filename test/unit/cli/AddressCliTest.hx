package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * End-to-end tests for the shared addressing flags on the mutation ops:
 * `--select` / `--match` / `--nth`, the `--kind` lift, valueless
 * `--after` / `--before` / `--append` mode flags, and line-only positions.
 * Each drives `Cli.run` against a temp fixture with `--write` and asserts
 * the resulting file content.
 */
class AddressCliTest extends Test {

	#if (sys || nodejs)
	private static final FIXTURE: String = 'class C {\n\tfunction f():Int {\n\t\tvar x:Int = 1;\n\t\ttrace(x);\n\t\treturn x;\n\t}\n}\n';

	/**
	 * A MEMBER fixture for the `remove-member` address tests: one plain method, a
	 * second the removal must not touch, and a name declared once per
	 * conditional-compilation branch — the shape that proves an address SPELLS the
	 * (type, member) pair rather than narrowing the removal to one branch.
	 */
	private static final MEMBER_FIXTURE: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(1);\n\t\treturn 1;\n\t}\n\n'
		+ '\tfunction g():Int\n' + '\t\treturn 2;\n\n\t#if js\n\tfunction h():Int\n\t\treturn 3;\n\t#else\n\tfunction h():Int\n'
		+ '\t\treturn 4;\n\t#end\n}\n';

	/**
	 * A MODULE-LEVEL fixture for the modifier-address tests: a main type and a module-private
	 * helper beside it. Line 3 is the `private` keyword — the same byte offset `--select 'Private'`
	 * resolves to, which is what makes the two addresses collide. Writer-canonical, since these ops
	 * are canonical-gated and a drifted fixture is refused before any of them decides anything.
	 */
	private static final MODULE_PRIVATE_FIXTURE: String = 'class C {}\n\nprivate typedef Helper = {\n\tvar n:Int;\n}\n';
	#end

	public function testAddElementAfterSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_ae', FIXTURE);
		final rc: Int = Cli.run([
			'add-element',
			path,
			'--after',
			'--select',
			'FnMember:f >> VarStmt:x',
			'trace(2);',
			'--write'
		]);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('var x:Int = 1;\n\t\ttrace(2);') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRemoveElementSelectDescendant(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_re', 'class C {\n\tfunction f():Int {\n\t\tvar dead:Int = 1;\n\t\treturn 2;\n\t}\n}\n');
		final rc: Int = Cli.run(['remove-element', path, '--select', 'FnMember:f >> VarStmt:dead', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('dead') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRemoveElementLineOnly(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_lo', 'class C {\n\tfunction f():Int {\n\t\tvar dead:Int = 1;\n\t\treturn 2;\n\t}\n}\n');
		// Line 3 with no column — snaps past the leading tabs to `var`.
		final rc: Int = Cli.run(['remove-element', path, '3', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('dead') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReplaceNodeMatchKindLift(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rn', FIXTURE);
		final rc: Int = Cli.run([
			'replace-node',
			path,
			'--match',
			'trace(x)',
			'--kind',
			'ExprStmt',
			'trace(x);\ntrace(x + 1);',
			'--write'
		]);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('trace(x + 1);') >= 0);
		// The lift replaced the whole statement — no stray `;;` artifact.
		Assert.isTrue(out.indexOf(';;') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSetModifierSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_sm', FIXTURE);
		final rc: Int = Cli.run(['set-modifier', path, '--select', 'FnMember:f', 'public', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('public function f') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSetDocSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_sd', FIXTURE);
		final rc: Int = Cli.run(['set-doc', path, '--select', 'FnMember:f', 'Returns one.', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('Returns one.') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAmbiguousSelectFailsWithCandidates(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_amb', 'class C {\n\tfunction f():Void {\n\t\ttrace(1);\n\t\ttrace(2);\n\t}\n}\n');
		final before: String = File.getContent(path);
		final rc: Int = Cli.run(['remove-element', path, '--select', 'ExprStmt', '--write']);
		Assert.isTrue(rc != 0);
		Assert.equals(before, File.getContent(path));
		// --nth resolves the ambiguity.
		final rc2: Int = Cli.run(['remove-element', path, '--select', 'ExprStmt', '--nth', '2', '--write']);
		Assert.equals(0, rc2);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('trace(1);') >= 0);
		Assert.isTrue(out.indexOf('trace(2);') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAddElementAppendSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_ap', 'class C {\n\tfunction f():Void {}\n}\n');
		// Valueless --append + --select of the empty body container.
		final rc: Int = Cli.run([
			'add-element',
			path,
			'--append',
			'--select',
			'FnMember:f > BlockBody',
			'trace(1);',
			'--write'
		]);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('trace(1);') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRenameSelectLocal(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rn2', FIXTURE);
		final rc: Int = Cli.run(['rename', path, '--select', 'FnMember:f >> VarStmt:x', 'renamed', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('var renamed:Int = 1;') >= 0);
		Assert.isTrue(out.indexOf('return renamed;') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testChangeSigSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'addr_cs', 'class C {\n\tfunction g(a:Int, b:String):Void {}\n\tfunction f():Void {\n\t\tg(1, "s");\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['change-sig', path, '--select', 'FnMember:g', '1,0', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function g(b:String, a:Int)') >= 0);
		Assert.isTrue(out.indexOf('g("s", 1)') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRemoveParamSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'addr_rp',
			'class C {\n\tfunction g(a:Int, unused:String):Void {\n\t\ttrace(a);\n\t}\n\tfunction f():Void {\n\t\tg(1, "s");\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['remove-param', path, '--select', 'FnMember:g', '1', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function g(a:Int)') >= 0);
		Assert.isTrue(out.indexOf('g(1)') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExtractVarMatch(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_ev', 'class C {\n\tfunction f(a:Int):Int {\n\t\treturn a * 2 + 1;\n\t}\n}\n');
		final rc: Int = Cli.run(['extract-var', path, '--match', 'a * 2', 'doubled', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('final doubled = a * 2;') >= 0);
		Assert.isTrue(out.indexOf('return doubled + 1;') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRemoveMemberSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rm', MEMBER_FIXTURE);
		final rc: Int = Cli.run(['remove-member', path, '--select', 'ClassDecl:C >> FnMember:f', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function f(') < 0);
		// The by-name form's other members are untouched — the address named ONE pair.
		Assert.isTrue(out.indexOf('function g(') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRemoveMemberMatchLiftsToItsMember(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rmm', MEMBER_FIXTURE);
		// The pattern hits a STATEMENT inside f — the lift names the member holding it.
		final rc: Int = Cli.run(['remove-member', path, '--match', 'trace(1)', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function f(') < 0);
		Assert.isTrue(out.indexOf('function g(') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRemoveMemberSelectTakesEveryConditionalTwin(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rmc', MEMBER_FIXTURE);
		// An address resolves ONE node; the removal is still by NAME, so the `#else` twin
		// goes too and the region that held both takes its directives with it.
		final rc: Int = Cli.run(['remove-member', path, '--select', 'FnMember:h', '--nth', '1', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function h(') < 0);
		Assert.isTrue(out.indexOf('#if js') < 0);
		Assert.isTrue(out.indexOf('function g(') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRemoveMemberSelectRefusesANonMember(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rmn', MEMBER_FIXTURE);
		// A type is not a member: the refusal names the resolved kind and points at
		// remove-element rather than removing something else.
		final rc: Int = Cli.run(['remove-member', path, '--select', 'ClassDecl:C', '--write']);
		Assert.notEquals(0, rc);
		Assert.equals(MEMBER_FIXTURE, File.getContent(path));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRemoveMemberRefusesBothAddressForms(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rmb', MEMBER_FIXTURE);
		final rc: Int = Cli.run(['remove-member', path, '--select', 'FnMember:f', '--type', 'C', 'g', '--write']);
		Assert.notEquals(0, rc);
		Assert.equals(MEMBER_FIXTURE, File.getContent(path));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}


	public function testRemoveMemberByNameStillWorks(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rmt', MEMBER_FIXTURE);
		final rc: Int = Cli.run(['remove-member', path, '--type', 'C', 'g', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function g(') < 0);
		Assert.isTrue(out.indexOf('function f(') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--select '<Modifier>'` is not an element address, and `remove-element` refuses it.
	 *
	 * `--select 'Private'` and a position on that same keyword resolve to the SAME byte offset;
	 * `resolveAddressPos` hands both on as a bare position, and `ElementSpan.declGroupSpan` then
	 * walks forward to the declaration the modifier precedes. Asked to remove a MODIFIER, the op
	 * removed the whole `private typedef Helper` DECLARATION and reported `wrote <file>` at rc 0 —
	 * silent work destruction, and the reason S90 had to route around it with `patch`.
	 *
	 * The leading assertions are the reachability proof: the fixture's declaration is present
	 * before the call, and still byte-for-byte present after it.
	 */
	public function testRemoveElementRefusesAModifierSelector(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_mod', MODULE_PRIVATE_FIXTURE);
		Assert.isTrue(File.getContent(path).indexOf('private typedef Helper') >= 0, 'the fixture declares it');
		var rc: Int = 0;
		final err: String = CliFixture.captureStderr(() -> rc = Cli.run(['remove-element', path, '--select', 'Private', '--write']));
		Assert.notEquals(0, rc, 'a modifier address must not be served');
		Assert.equals(MODULE_PRIVATE_FIXTURE, File.getContent(path), 'the file must be untouched');
		#if nodejs
		Assert.isTrue(err.indexOf('MODIFIER') >= 0, 'the refusal must name what the address is: $err');
		Assert.isTrue(err.indexOf('set-modifier') >= 0, 'and must name the op that drops a keyword: $err');
		#end
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The POSITION form on the same keyword still removes the declaration — the cursor convention
	 * says `<line>[:<col>]` points at an element's FIRST TOKEN, and a modified declaration's first
	 * token is its leading keyword. That is why the refusal above is gated on the address MODE and
	 * not on the resolved node's kind: the two addresses mean different things at one offset.
	 * Pre-existing behaviour, pinned because the fix could have been written to break it: a guard on
	 * the resolved node KIND alone refuses this too, and the suite stayed green until the fixture
	 * spelled the column.
	 */
	public function testRemoveElementByPositionOnAModifierStillRemovesTheDeclaration(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_modpos', MODULE_PRIVATE_FIXTURE);
		// The COLUMN is the discriminator, and it has to be spelled: a bare `<line>` never resolves to
		// a modifier at all (`Address.declAfterModifierPrefix` skips the prefix run and hands back the
		// declaration), so a mode-blind guard would leave it alone and the test would prove nothing.
		// `3:1` is the byte `--select 'Private'` resolves to, and at base both spellings deleted the
		// declaration — the second one after echoing `target Private`.
		final rc: Int = Cli.run(['remove-element', path, '3:1', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('Helper') < 0, 'the declaration goes with its modifier run');
		Assert.isTrue(out.indexOf('class C') >= 0, 'and nothing else does');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `@:meta` selector is NOT caught by the modifier refusal: `declGroupSpan` treats an
	 * annotation as an element in its own right, so `--select 'Meta:@:keep'` already addresses the
	 * annotation and only it. The control that keeps the refusal off the rest of the prefix run.
	 */
	public function testRemoveElementStillRemovesAMetaBySelector(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_meta', 'class C {\n\t@:keep\n\tprivate function f():Int\n\t\treturn 1;\n}\n');
		final rc: Int = Cli.run(['remove-element', path, '--select', 'Meta:@:keep', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('@:keep') < 0, 'the annotation is removed');
		Assert.isTrue(out.indexOf('private function f') >= 0, 'and the declaration it annotated is not');
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
