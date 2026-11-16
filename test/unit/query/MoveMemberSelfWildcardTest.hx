package unit.query;

import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol;

using Lambda;
using StringTools;

/**
 * `MoveMember.move` of a member whose body reads a name the source's `import a.Names.*;` binds, into the
 * very module that wildcard points at: the name the destination declares is the declaration the body
 * already reads, so it is no rebind and the destination imports nothing.
 */
@:nullSafety(Strict)
final class MoveMemberSelfWildcardTest extends Test {

	private static final SCOPE: Array<{ file: String, source: String }> = [
		{
			file: 'a/Names.hx',
			source: 'package a;\n\nclass Names {\n\tpublic static function packOf(s:String):String return s + \'-A\';\n}'
		},
		{
			file: 'a/Src.hx',
			source: 'package a;\n\nimport a.Names.*;\n\nclass Src {\n\tpublic static function label(s:String):String return packOf(s);\n}'
		}
	];

	@:pin('control')
	@:killer('M-WILDCARD-SELF-MODULE-ASKED')
	public function testAWildcardPointingAtTheDestinationIsNotARebind(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch MoveMember.move('a/Src.hx', 'Src', ['label'], 'Names', null, false, false, SCOPE, plugin, plugin.typeRefShape()) {
			case Ok(changes, _):
				final names: Null<String> = changes.find(c -> c.file == 'a/Names.hx')?.newSource;
				Assert.notNull(names);
				Assert.isTrue((names ?? '').contains('return packOf(s)'), 'the moved body should keep reaching packOf bare');
				Assert.isFalse((names ?? '').contains('import a.Names.*;'), 'the destination must not import its own module');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	@:pin('control')
	@:killer('M-WILDCARD-SELF-MODULE-ANY-TYPE')
	public function testASubTypeOfTheWildcardsModuleStillRefuses(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Names.hx',
				source: 'package a;\n\nclass Names {\n\tpublic static function packOf(s:String):String return s + \'-A\';\n}\n\n'
					+ 'class Other {\n\tpublic static function x():Int return 1;\n}'
			},
			SCOPE[1]
		];
		switch MoveMember.move('a/Src.hx', 'Src', ['label'], 'Other', null, false, false, scope, plugin, plugin.typeRefShape()) {
			case Ok(_, _):
				Assert.fail('a sub-type cannot read the main type static bare, so the move must refuse');
			case Err(message):
				Assert.stringContains('packOf', message);
		}
	}

	@:pin('control')
	@:killer('M-WILDCARD-SELF-MODULE-ANY-TYPE')
	public function testATypeMovedIntoTheWildcardsModuleStillRefuses(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch MoveSymbol.moveType('a/Src.hx', 5, 7, 'a/Names.hx', SCOPE, plugin, plugin.typeRefShape()) {
			case Ok(_, _):
				Assert.fail('a moved-in type is a sub-type that cannot read the main type static bare, so the move must refuse');
			case Err(message):
				Assert.stringContains('packOf', message);
		}
	}

}
