package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.SetModifier;

using StringTools;

/**
 * Probe for `apq set-modifier` — the safe modifier flip (replacing the
 * `replace-node --at <modifier>` footgun that overwrote the whole decl). Drives
 * `SetModifier.setModifier` directly on in-memory sources (pure, JS-native,
 * `reformat = true`): visibility flips, a boolean modifier is added / removed,
 * a bare declaration gains a visibility, and a `final` / unknown change is an
 * `Err`. The declaration body must survive every flip.
 */
class SetModifierSliceTest extends Test {

	private static inline final PRIVATE_FN: String = 'package p;\nclass C {\n\tprivate function f(): Int return 1;\n}';

	/** private → public, body intact, old visibility gone. */
	public function testFlipVisibility(): Void {
		final text: String = okText(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public function f'));
		Assert.isFalse(text.contains('private'));
		Assert.isTrue(text.contains('return 1'));
	}

	/** Visibility flip + a boolean modifier added in one call. */
	public function testFlipAndAddStatic(): Void {
		final text: String = okText(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['public', '+static'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public static function f'));
	}

	/** A boolean modifier is removed. */
	public function testRemoveInline(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic inline function f(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['-inline'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public function f'));
		Assert.isFalse(text.contains('inline'));
	}

	/** A bare (no-modifier) declaration gains a visibility. */
	public function testAddVisibilityToBare(): Void {
		final src: String = 'package p;\nclass C {\n\tfunction f(): Int return 1;\n}';
		final text: String = okText(SetModifier.setModifier(src, 3, 2, ['public'], true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('public function f'));
	}

	/** A `final` change is rejected (it wraps the declaration). */
	public function testFinalChangeRejected(): Void {
		Assert.isTrue(isErr(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['+final'], true, new HaxeQueryPlugin())));
	}

	/** An unknown modifier is rejected. */
	public function testUnknownRejected(): Void {
		Assert.isTrue(isErr(SetModifier.setModifier(PRIVATE_FN, 3, 2, ['+frobnicate'], true, new HaxeQueryPlugin())));
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: EditResult): Bool {
		return switch res {
			case Ok(_): false;
			case Err(_): true;
		};
	}

}
