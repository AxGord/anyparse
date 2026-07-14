package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.InheritanceMove;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;

/**
 * `InheritanceMove.pullUp` / `pushDown` — move an instance member along
 * the inheritance axis without rewriting call sites. Each test drives the
 * PURE op with an in-memory scope, asserts the member left the source
 * type and landed on the target, and re-parses both. Refusal cases assert
 * `Err`.
 */
class InheritanceMoveSliceTest extends Test {

	private static final ANIMAL: String = 'package pkg;\n\nclass Animal {\n\tpublic var name:String;\n\tpublic function new(n:String) { name = n; }\n}';

	/** Pull an instance method up to its superclass; no call sites change. */
	public function testPullUpMethod(): Void {
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new(n:String) { super(n); }\n\tpublic function describe():String return name + \' dog\';\n}';
		final changes: Array<MoveChange> = okChanges(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'describe', 'Animal', [
			{ file: 'pkg/Animal.hx', source: ANIMAL },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
		Assert.equals(2, changes.length);
		Assert.isTrue(StringTools.contains(changeFor(changes, 'pkg/Animal.hx').newSource, 'function describe'), 'lands on Animal');
		Assert.isFalse(StringTools.contains(changeFor(changes, 'pkg/Dog.hx').newSource, 'function describe'), 'leaves Dog');
	}

	/** An instance field pulls up too. */
	public function testPullUpField(): Void {
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic var breed:String = \'mutt\';\n\tpublic function new(n:String) { super(n); }\n}';
		final changes: Array<MoveChange> = okChanges(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'breed', 'Animal', [
			{ file: 'pkg/Animal.hx', source: ANIMAL },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
		Assert.isTrue(StringTools.contains(changeFor(changes, 'pkg/Animal.hx').newSource, 'var breed'), 'field lands on Animal');
	}

	/** Pull-up is refused when the body references a subclass-only member. */
	public function testPullUpStrandedRefused(): Void {
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new(n:String) { super(n); }\n\tpublic function bark():String return \'woof\';\n\tpublic function describe():String return bark();\n}';
		assertErr(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'describe', 'Animal', [
			{ file: 'pkg/Animal.hx', source: ANIMAL },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
	}

	/** Push an instance method down to a subclass. */
	public function testPushDownMethod(): Void {
		final sup: String = 'package pkg;\n\nclass Sup {\n\tpublic function new() {}\n\tpublic function only():String return \'x\';\n}';
		final sub: String = 'package pkg;\n\nclass Sub extends Sup {\n\tpublic function new() { super(); }\n}';
		final changes: Array<MoveChange> = okChanges(InheritanceMove.pushDown('pkg/Sup.hx', 'Sup', 'only', 'Sub', [
			{ file: 'pkg/Sup.hx', source: sup },
			{ file: 'pkg/Sub.hx', source: sub },
		], plugin()));
		Assert.isTrue(StringTools.contains(changeFor(changes, 'pkg/Sub.hx').newSource, 'function only'), 'lands on Sub');
		Assert.isFalse(StringTools.contains(changeFor(changes, 'pkg/Sup.hx').newSource, 'function only'), 'leaves Sup');
	}

	/** A member moved between UNRELATED classes is refused. */
	public function testNotSubclassRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic function new() {}\n\tpublic function m():Void {}\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {}\n}';
		assertErr(InheritanceMove.pullUp('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		], plugin()));
	}

	/** A static member is refused (statics are not inherited the same way). */
	public function testStaticRefused(): Void {
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new(n:String) { super(n); }\n\tpublic static function make():Dog return new Dog(\'x\');\n}';
		assertErr(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'make', 'Animal', [
			{ file: 'pkg/Animal.hx', source: ANIMAL },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
	}

	/** An override member is refused. */
	public function testOverrideRefused(): Void {
		final animal: String = 'package pkg;\n\nclass Animal {\n\tpublic function new() {}\n\tpublic function speak():String return \'?\';\n}';
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new() { super(); }\n\toverride public function speak():String return \'woof\';\n}';
		assertErr(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'speak', 'Animal', [
			{ file: 'pkg/Animal.hx', source: animal },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
	}

	/** A constructor is refused. */
	public function testConstructorRefused(): Void {
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new(n:String) { super(n); }\n}';
		assertErr(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'new', 'Animal', [
			{ file: 'pkg/Animal.hx', source: ANIMAL },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
	}

	/** A member the target already declares is refused. */
	public function testTargetCollisionRefused(): Void {
		final animal: String = 'package pkg;\n\nclass Animal {\n\tpublic function new() {}\n\tpublic function tag():String return \'a\';\n}';
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new() { super(); }\n\tpublic function tag():String return \'d\';\n}';
		assertErr(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'tag', 'Animal', [
			{ file: 'pkg/Animal.hx', source: animal },
			{ file: 'pkg/Dog.hx', source: dog },
		], plugin()));
	}

	/** A target class absent from the scope is refused. */
	public function testNoSuchTargetRefused(): Void {
		final dog: String = 'package pkg;\n\nclass Dog extends Animal {\n\tpublic function new(n:String) { super(n); }\n\tpublic function d():Void {}\n}';
		assertErr(InheritanceMove.pullUp('pkg/Dog.hx', 'Dog', 'd', 'Missing', [{ file: 'pkg/Dog.hx', source: dog },], plugin()));
	}

	private function okChanges(result: MoveResult): Array<MoveChange> {
		switch result {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed: Bool = true;
					try
						plugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result: MoveResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<MoveChange>, file: String): MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '' };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
