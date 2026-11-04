package unit.query;

import anyparse.query.MoveSymbol;
import haxe.Exception;

using StringTools;
using Lambda;

/** What a module statement still binds once `move` took a type out of its module: it stays for any name its file reads through it. */
class MoveBoundNamesTest extends Test {

	private static final MODULE: String = 'package p;\n\nfunction helper(): Int {\n\treturn 1;\n}\n\nclass Mod {\n\tpublic function '
		+ 'new() {}\n}\n\nenum abstract Kind(Int) {\n\tvar First = 1;\n}\n\nprivate class Hidden {}\n\n'
		+ 'abstract Plain(Int) {\n\tpublic var span(get, never): Int;\n\n\tfunction get_span(): Int {\n\t\treturn 1;\n\t}\n}\n\n'
		+ 'private function secret(): Int {\n\treturn 1;\n}\n\nfunction after(): Int {\n\treturn 1;\n}\n';
	private static final KEPT: String = 'import p.Mod;';
	private static final REPOINTED: String = 'import q.Mod;';

	@:pin('control') @:killer('M-BOUND-BESIDES-NO-FIELDS')
	public function testAModuleStatementStaysForAFieldItsFileReads(): Void {
		final user: String = movedUser('trace(helper());');
		Assert.isTrue(user.contains(KEPT), user);
		Assert.isTrue(user.contains(REPOINTED), user);
	}

	@:pin('control') @:killer('M-BOUND-BESIDES-NO-VALUES')
	public function testAModuleStatementStaysForAValueItsFileReads(): Void {
		final user: String = movedUser('trace(First);');
		Assert.isTrue(user.contains(KEPT), user);
		Assert.isTrue(user.contains(REPOINTED), user);
	}

	@:pin('control') @:killer('M-BOUND-BESIDES-THE-MOVED')
	public function testAModuleStatementGoesWhenItsFileReadsOnlyTheMovedType(): Void {
		final user: String = movedUser('trace(new Mod());');
		Assert.isFalse(user.contains(KEPT), user);
		Assert.isTrue(user.contains(REPOINTED), user);
	}

	@:pin('control') @:killer('M-BOUND-BESIDES-PRIVATE')
	public function testAPrivateTypeKeepsNoStatement(): Void {
		final user: String = movedUser('final own: Hidden = new Mod();\n\t\ttrace(own);');
		Assert.isFalse(user.contains(KEPT), user);
	}

	@:pin('control') @:killer('M-BOUND-BESIDES-NO-FIELDS')
	public function testTheDestinationKeepsAStatementForAFieldItReads(): Void {
		final dest: String = 'package q;\n\nimport p.Mod;\n\nclass Host {\n\tstatic function go(): Int {\n\t\treturn helper();\n\t}\n}\n';
		final moved: String = changed('q/Mod.hx', [{ file: 'q/Mod.hx', source: dest }]);
		Assert.isTrue(moved.contains(KEPT), moved);
	}

	@:pin('control') @:killer('M-BOUND-BY-TYPE-NO-VALUES')
	public function testAValueOfTheMovedEnumAbstractEarnsAStatement(): Void {
		final user: String = movedSecondary(11, 15, 'q/Kind.hx', 'trace(First);');
		Assert.isTrue(user.contains('import q.Kind;'), user);
	}

	@:pin('control') @:killer('M-BOUND-BY-TYPE-EVERY-ABSTRACT')
	public function testAVarOfTheMovedPlainAbstractEarnsNoStatement(): Void {
		final user: String = movedSecondary(17, 10, 'q/Plain.hx', 'trace(span);');
		Assert.isFalse(user.contains('import q.Plain;'), user);
	}

	@:pin('control') @:killer('M-MODULE-FIELD-PRIVATE-BOUND', 'M-MODULE-FIELD-NEVER-PRIVATE')
	public function testAPrivateFieldKeepsNoStatement(): Void {
		final user: String = movedUser('final secret: Int = 1;\n\t\ttrace(secret);');
		Assert.isFalse(user.contains(KEPT), user);
	}

	@:pin('control') @:killer('M-MODULE-FIELD-PRIVATE-STICKS')
	public function testAFieldAfterAPrivateOneKeepsItsStatement(): Void {
		final user: String = movedUser('trace(after());');
		Assert.isTrue(user.contains(KEPT), user);
	}

	@:pin('control') @:killer('M-STATEMENTLESS-SCANS-BOUND-NAMES')
	public function testAValueNameAnotherStatementBindsEarnsNoImportOfTheMovedEnumAbstract(): Void {
		final reader: String = movedOutOfP('package p;\n\nenum abstract Kind(String) to String {\n\tvar First = "kind";\n}\n');
		Assert.isFalse(reader.contains('import q.Kind;'), reader);
	}

	@:pin('control') @:killer('M-STATEMENTLESS-SCANS-BOUND-NAMES')
	public function testAConstructorNameAnotherStatementBindsEarnsNoImportOfTheMovedEnum(): Void {
		final reader: String = movedOutOfP('package p;\n\nenum Kind {\n\tFirst;\n}\n');
		Assert.isFalse(reader.contains('import q.Kind;'), reader);
	}

	/** Moves `Kind` out of `p` past a same-package file whose bare `First` is bound by its own `import a.Other;`, and answers that file. */
	private static function movedOutOfP(kind: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final reader: String = 'package p;\n\nimport a.Other;\n\nclass Reader {\n\tstatic function main() {\n\t\ttrace(First);\n\t}\n}\n';
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'p/Kind.hx', source: kind },
			{ file: 'p/Reader.hx', source: reader },
			{ file: 'a/Other.hx', source: 'package a;\n\nenum Other {\n\tFirst;\n}\n' },
			{ file: 'q/Kind.hx', source: 'package q;\n' }
		];
		final at: Int = kind.split('\n')[2].indexOf('Kind') + 1;
		return switch MoveSymbol.moveType('p/Kind.hx', 3, at, 'q/Kind.hx', scope, plugin, plugin.typeRefShape()) {
			case Ok(changes, _): changes.find(c -> c.file == 'p/Reader.hx')?.newSource ?? '';
			case Err(message): throw new Exception(message);
		};
	}

	private static function movedUser(body: String): String {
		final user: String = 'package u;\n\nimport p.Mod;\n\nclass User {\n\tstatic function main() {\n\t\t$body\n\t}\n}\n';
		return changed('u/User.hx', [
			{ file: 'u/User.hx', source: user },
			{ file: 'q/Mod.hx', source: 'package q;\n' }
		]);
	}

	private static function changed(file: String, others: Array<{ file: String, source: String }>): String {
		return movedFrom(7, 7, 'q/Mod.hx', file, others);
	}

	private static function movedFrom(
		line: Int, col: Int, dest: String, file: String, others: Array<{ file: String, source: String }>
	): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final scope: Array<{ file: String, source: String }> = [{ file: 'p/Mod.hx', source: MODULE }].concat(others);
		return switch MoveSymbol.moveType('p/Mod.hx', line, col, dest, scope, plugin, plugin.typeRefShape()) {
			case Ok(changes, _): changes.find(c -> c.file == file)?.newSource ?? '';
			case Err(message): throw new Exception(message);
		};
	}

	private static function movedSecondary(line: Int, col: Int, dest: String, body: String): String {
		final user: String = 'package u;\n\nimport p.Mod;\n\nclass User {\n\tstatic function main() {\n\t\t$body\n\t}\n}\n';
		return movedFrom(line, col, dest, 'u/User.hx', [{ file: 'u/User.hx', source: user }, { file: dest, source: 'package q;\n' }]);
	}

}
