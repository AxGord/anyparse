package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end tests for `apq rename` WITHOUT `--scope` when the cursor sits on a MEMBER
 * declaration.
 *
 * `Rename` resolves through the VALUE namespace, which binds a name lexically and never
 * through a receiver's type - so on a member it rewrote the declaration alone and left
 * every `obj.member` access on the old name, emitting a file that does not compile. The
 * in-file path now routes a member cursor through the same `CrossRenameMember` op
 * `--scope` uses, with the cursor file as the whole scope.
 *
 * Every assertion spans the DECLARATION and a USE in one string, so an untransformed
 * input cannot satisfy it: the old behaviour rewrote the decl alone and would still fail
 * each of these.
 */
class RenameMemberInFileCliTest extends Test {

	/** A method plus the call through a locally-bound receiver. */
	public function testMethodRenamesDeclAndReceiverCall(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_member_method',
			'class B {\n\tpublic function new() {}\n\n\tpublic function greet(): String {\n\t\treturn "hi";\n\t}\n}\n\nclass Use {\n'
			+ '\tpublic function new() {}\n\n\tpublic function call(): String {\n\t\tfinal b: B = new B();\n\t\treturn b.greet();\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'FnMember:greet', 'hello', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('public function hello(): String') >= 0 && out.indexOf('return b.hello();') >= 0);
		Assert.equals(-1, out.indexOf('greet'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A field read through ANOTHER instance of the same type. `this.size` alone was
	 * already bound by the value namespace - `o.size` is what it cannot see.
	 */
	public function testFieldRenamesDeclAndForeignInstanceRead(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_member_field',
			'class B {\n\tpublic final size: Int = 1;\n\n\tpublic function new() {}\n\n\tpublic function sum(o: B): Int {\n'
			+ '\t\treturn this.size + o.size;\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'FinalMember:size', 'width', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('public final width: Int = 1;') >= 0 && out.indexOf('return this.width + o.width;') >= 0);
		Assert.equals(-1, out.indexOf('size'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `new T()` receiver names its own type and binds nothing, so it was not even
	 * offered for resolution - the declaration was renamed and the access left behind.
	 */
	public function testConstructorCallReceiverIsRewritten(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_member_newrecv',
			'class B {\n\tpublic function new() {}\n\n\tpublic function tag(): String {\n\t\treturn "b";\n\t}\n}\n\nclass Use {\n'
			+ '\tpublic function new() {}\n\n\tpublic function call(): String {\n\t\treturn new B().tag();\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'FnMember:tag', 'label', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('public function label(): String') >= 0 && out.indexOf('return new B().label();') >= 0);
		Assert.equals(-1, out.indexOf('tag'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A constructor has no member name to rewrite - renaming it leaves the type without one. */
	public function testConstructorIsRefused(): Void {
		#if (sys || nodejs)
		final source: String = 'class B {\n\tpublic final size: Int = 1;\n\n\tpublic function new() {}\n}\n';
		final path: String = CliFixture.write('rn_member_ctor', source);
		final rc: Int = Cli.run(['rename', path, '--select', 'FnMember:new', 'make', '--write']);
		Assert.notEquals(0, rc);
		Assert.equals(source, File.getContent(path));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An implementation of an `abstract` method carries NO `override` modifier in Haxe,
	 * so the keyword-based guard could not see it and the base kept the old name.
	 */
	public function testAbstractMethodImplementationIsRefused(): Void {
		#if (sys || nodejs)
		final source: String = 'abstract class Base {\n\tabstract public function area(): Int;\n}\n\nclass Impl extends Base {\n'
			+ '\tpublic function new() {}\n\n\tpublic function area(): Int {\n\t\treturn 7;\n\t}\n}\n';
		final path: String = CliFixture.write('rn_member_absimpl', source);
		final rc: Int = Cli.run(['rename', path, '--select', 'ClassDecl:Impl >> FnMember:area', 'size', '--write']);
		Assert.notEquals(0, rc);
		Assert.equals(source, File.getContent(path));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The BARE line number a lint or compiler diagnostic prints. It snaps to the line's
	 * first non-whitespace character, which for a member is its `public` modifier - a
	 * sibling node before the declaration, so every op refused the documented address.
	 */
	public function testBareLineNumberOnModifierPrefixAddressesTheMember(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_member_bareline',
			'class B {\n\tpublic function new() {}\n\n\tpublic function greet(): String {\n\t\treturn "hi";\n\t}\n}\n\nclass Use {\n'
			+ '\tpublic function new() {}\n\n\tpublic function call(): String {\n\t\tfinal b: B = new B();\n\t\treturn b.greet();\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '4', 'hello', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('public function hello(): String') >= 0 && out.indexOf('return b.hello();') >= 0);
		Assert.equals(-1, out.indexOf('greet'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A same-named LOCAL in an unrelated type is not a member access and must stay verbatim. */
	public function testSameNamedLocalInAnotherTypeIsUntouched(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_member_localctl',
			'class A {\n\tpublic function new() {}\n\n\tpublic function total(): Int {\n\t\treturn 1;\n\t}\n}\n\nclass B {\n'
			+ '\tpublic function new() {}\n\n\tpublic function f(): Int {\n\t\tfinal total: Int = 2;\n\t\tfinal a: A = new A();\n'
			+ '\t\treturn total + a.total();\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'ClassDecl:A >> FnMember:total', 'sum', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(
			out.indexOf('public function sum(): Int') >= 0 && out.indexOf('final total: Int = 2;') >= 0
			&& out.indexOf('return total + a.sum();') >= 0
		);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
