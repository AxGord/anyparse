package unit.dev;

import dev.ArmRegistry;
import utest.Assert;
import utest.Test;

/**
 * `ArmRegistry` over synthetic registries: a registry it cannot key is refused.
 */
@:nullSafety(Strict)
final class ArmRegistryTest extends Test {

	public function testANameDeclaredTwiceIsRefused(): Void {
		Assert.raises(() -> ArmRegistry.parse(file([arm('A', '1'), arm('A', '2')])), ArmRegistryError);
	}

	/** A registry holding `records`, laid out as the real one is. */
	private static function file(records: Array<String>): String {
		return '{\n\t"$$comment": ["the registry"],\n\t"arms": [\n\t\t${records.join(',\n\t\t')}\n\t]\n}\n';
	}

	private static function arm(name: String, note: String): String {
		return '{\n\t\t\t"name": "$name",\n\t\t\t"note": "$note"\n\t\t}';
	}

}
